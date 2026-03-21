extends Node

# ===========================
# 功法总管理器
# ===========================
# 说明：
# 1. 统一管理“功法被动、技能触发、Buff、联动”四块逻辑。
# 2. 对外只暴露简洁接口，战场层只负责在合适时机调用 prepare_battle。
# 3. 本脚本可作为 AutoLoad 使用，跨场景保持接口一致。

signal linkage_changed(active_linkages: Array)
signal gongfa_data_reloaded(summary: Dictionary)
signal skill_triggered(unit: Node, gongfa_id: String, trigger: String)
signal skill_effect_damage(event: Dictionary)
signal skill_effect_heal(event: Dictionary)
signal buff_event(event: Dictionary)

@export var trigger_poll_interval: float = 0.12
@export var linkage_refresh_interval: float = 1.0

const ALLOWED_SLOTS: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa", "qishu"]
const ALLOWED_EQUIP_SLOTS: Array[String] = ["weapon", "armor", "accessory"]
const DEFAULT_SKILL_CAST_RANGE_CELLS: float = 2.0

var _registry = preload("res://scripts/gongfa/gongfa_registry.gd").new()
var _effect_engine = preload("res://scripts/gongfa/effect_engine.gd").new()
var _buff_manager = preload("res://scripts/gongfa/buff_manager.gd").new()
var _linkage_detector = preload("res://scripts/gongfa/linkage_detector.gd").new()
var _unit_data_script: Script = load("res://scripts/data/unit_data.gd")

var _bound_combat_manager: Node = null
var _bound_hex_grid: Node = null
var _bound_vfx_factory: Node = null

var _battle_units: Array[Node] = []
var _unit_lookup: Dictionary = {} # instance_id -> unit
var _unit_states: Dictionary = {} # instance_id -> state

var _battle_running: bool = false
var _battle_elapsed: float = 0.0
var _trigger_accum: float = 0.0
var _linkage_accum: float = 0.0
var _linkages_dirty: bool = false

var _active_linkages: Array[Dictionary] = []
var _active_linkage_names_cache: Array[String] = []
var _active_linkage_summary_text: String = "当前联动：无"


func _ready() -> void:
	reload_from_data()
	_connect_event_bus()
	set_process(true)


func _process(delta: float) -> void:
	if not _battle_running:
		return

	_battle_elapsed += delta
	_trigger_accum += delta
	_linkage_accum += delta

	var buff_tick: Dictionary = _buff_manager.tick(delta)
	_execute_buff_tick_requests(buff_tick.get("tick_requests", []))
	_reapply_changed_units(buff_tick.get("changed_unit_ids", []))

	if _trigger_accum >= maxf(trigger_poll_interval, 0.05):
		_trigger_accum = 0.0
		_poll_auto_triggers()

	if _linkages_dirty and _linkage_accum >= maxf(linkage_refresh_interval, 0.2):
		_linkage_accum = 0.0
		_linkages_dirty = false
		_refresh_linkages(true)


func reload_from_data() -> Dictionary:
	var data_manager: Node = _get_data_manager()
	var summary: Dictionary = _registry.reload_from_data_manager(data_manager)
	_buff_manager.set_buff_definitions(_registry.get_buff_map_snapshot())
	gongfa_data_reloaded.emit(summary)
	return summary


func bind_combat_context(combat_manager: Node, hex_grid: Node, vfx_factory: Node) -> void:
	if _bound_combat_manager == combat_manager and _bound_hex_grid == hex_grid and _bound_vfx_factory == vfx_factory:
		return

	_disconnect_combat_signals()
	_bound_combat_manager = combat_manager
	_bound_hex_grid = hex_grid
	_bound_vfx_factory = vfx_factory
	_connect_combat_signals()


func prepare_battle(
	ally_units: Array[Node],
	enemy_units: Array[Node],
	hex_grid: Node,
	vfx_factory: Node,
	combat_manager: Node
) -> void:
	bind_combat_context(combat_manager, hex_grid, vfx_factory)

	_battle_units.clear()
	_unit_lookup.clear()
	_unit_states.clear()
	_active_linkages.clear()
	_active_linkage_names_cache.clear()
	_active_linkage_summary_text = "当前联动：无"
	_battle_elapsed = 0.0
	_trigger_accum = 0.0
	_linkage_accum = 0.0
	_battle_running = false
	_linkages_dirty = false
	_buff_manager.clear_all()

	for unit in ally_units:
		_register_battle_unit(unit)
	for unit in enemy_units:
		_register_battle_unit(unit)

	for unit in _battle_units:
		apply_gongfa(unit, true)

	_refresh_linkages(false)


func apply_gongfa(unit: Node, defer_apply: bool = false) -> void:
	if unit == null or not is_instance_valid(unit):
		return

	var iid: int = unit.get_instance_id()
	var baseline_stats: Dictionary = _build_unit_baseline_stats(unit)

	# ===== 第 1 层：功法来源 =====
	var equipped_ids: Array[String] = _resolve_equipped_gongfa_ids(unit)
	var passive_effects: Array[Dictionary] = []
	var triggers: Array[Dictionary] = []
	var linkage_tags: Dictionary = {}
	var elements: Dictionary = {}

	for gongfa_id in equipped_ids:
		var gongfa_data: Dictionary = _registry.get_gongfa(gongfa_id)
		if gongfa_data.is_empty():
			continue

		var pfx: Variant = gongfa_data.get("passive_effects", [])
		if pfx is Array:
			for effect_value in pfx:
				if effect_value is Dictionary:
					# 被动效果只读，浅拷贝即可。
					passive_effects.append((effect_value as Dictionary).duplicate(false))

		for tag in _to_string_array(gongfa_data.get("linkage_tags", [])):
			linkage_tags[tag] = true
		var element: String = str(gongfa_data.get("element", "none")).strip_edges()
		if not element.is_empty():
			elements[element] = true

		var skill_value: Variant = gongfa_data.get("skill", {})
		if skill_value is Dictionary:
			var skill: Dictionary = skill_value
			triggers.append({
				"gongfa_id": gongfa_id,
				"trigger": str(skill.get("trigger", "")),
				"chance": clampf(float(skill.get("chance", 1.0)), 0.0, 1.0),
				"mp_cost": maxf(float(skill.get("mp_cost", 0.0)), 0.0),
				"cooldown": maxf(float(skill.get("cooldown", 0.0)), 0.0),
				"next_ready_time": 0.0,
				"trigger_count": 0,
				"max_trigger_count": maxi(int(skill.get("max_trigger_count", 0)), 0),
				# 浅拷贝即可，skill_data 内部字段只读。
				"skill_data": skill.duplicate(false)
			})

	# ===== 第 2 层：装备来源 =====
	var equipped_equip_ids: Array[String] = _resolve_equipped_equip_ids(unit)
	var equipment_effects: Array[Dictionary] = []
	var equip_triggers: Array[Dictionary] = []

	for equip_id in equipped_equip_ids:
		var equip_data: Dictionary = _registry.get_equipment(equip_id)
		if equip_data.is_empty():
			continue

		# 1) 装备被动效果与功法被动格式一致，直接复用 EffectEngine。
		var passive_value: Variant = equip_data.get("passive_effects", [])
		if passive_value is Array:
			for effect_value in passive_value:
				if effect_value is Dictionary:
					# 装备被动效果只读，浅拷贝即可。
					equipment_effects.append((effect_value as Dictionary).duplicate(false))

		# 2) 装备联动标签直接并入角色 runtime_linkage_tags，参与联动检测。
		for tag in _to_string_array(equip_data.get("linkage_tags", [])):
			linkage_tags[tag] = true

		# 3) 装备触发器使用 trigger 字段，转换为与功法触发器同结构统一执行。
		var trigger_value: Variant = equip_data.get("trigger", {})
		if trigger_value is Dictionary and not (trigger_value as Dictionary).is_empty():
			var trigger_data: Dictionary = trigger_value
			equip_triggers.append({
				"gongfa_id": equip_id, # 复用字段名，便于统一 signal 与日志结构。
				"trigger": str(trigger_data.get("type", "")),
				"chance": clampf(float(trigger_data.get("chance", 1.0)), 0.0, 1.0),
				"mp_cost": maxf(float(trigger_data.get("mp_cost", 0.0)), 0.0),
				"cooldown": maxf(float(trigger_data.get("cooldown", 0.0)), 0.0),
				"next_ready_time": 0.0,
				"trigger_count": 0,
				"max_trigger_count": maxi(int(trigger_data.get("max_trigger_count", 0)), 0),
				"skill_data": trigger_data.duplicate(false)
			})

	# 装备触发器与功法触发器共享同一轮询与事件触发链路。
	triggers.append_array(equip_triggers)

	_unit_states[iid] = {
		"unit": unit,
		"baseline_stats": baseline_stats,
		"equipped_gongfa_ids": equipped_ids,
		"equipped_equip_ids": equipped_equip_ids,
		"passive_effects": passive_effects,
		"equipment_effects": equipment_effects,
		"linkage_effects": [],
		"triggers": triggers,
		"runtime_linkage_tags": _dict_keys_to_string_array(linkage_tags),
		"runtime_elements": _dict_keys_to_string_array(elements)
	}

	if not defer_apply:
		_apply_state_to_unit(iid, false)


func remove_gongfa(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	if not _unit_states.has(iid):
		return
	var state: Dictionary = _unit_states[iid]
	state["passive_effects"] = []
	state["linkage_effects"] = []
	state["triggers"] = []
	state["runtime_linkage_tags"] = []
	state["runtime_elements"] = []
	_unit_states[iid] = state
	_apply_state_to_unit(iid, true)


func equip_gongfa(unit: Node, slot: String, gongfa_id: String) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if not ALLOWED_SLOTS.has(slot):
		return false
	if gongfa_id.strip_edges().is_empty():
		return false
	if not _registry.has_gongfa(gongfa_id):
		return false
	# 功法类型必须和目标槽位严格一致，确保“每类功法只占自己的槽位”。
	var gongfa_data: Dictionary = _registry.get_gongfa(gongfa_id)
	var gongfa_type: String = str(gongfa_data.get("type", "")).strip_edges()
	if gongfa_type != slot:
		return false

	var slots: Dictionary = _normalize_slots_dict(_node_prop(unit, "gongfa_slots", {}))
	slots[slot] = gongfa_id

	unit.set("gongfa_slots", slots)
	apply_gongfa(unit)
	_refresh_linkages(true)
	return true


func unequip_gongfa(unit: Node, slot: String) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if not ALLOWED_SLOTS.has(slot):
		return
	var slots: Dictionary = _normalize_slots_dict(_node_prop(unit, "gongfa_slots", {}))
	slots[slot] = ""
	unit.set("gongfa_slots", slots)
	apply_gongfa(unit)
	_refresh_linkages(true)


func get_gongfa_data(gongfa_id: String) -> Dictionary:
	return _registry.get_gongfa(gongfa_id)


func get_all_gongfa() -> Array[Dictionary]:
	return _registry.get_all_gongfa()


func get_equipment_data(equip_id: String) -> Dictionary:
	return _registry.get_equipment(equip_id)


func get_all_equipment() -> Array[Dictionary]:
	return _registry.get_all_equipment()


func equip_equipment(unit: Node, slot: String, equip_id: String) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if not ALLOWED_EQUIP_SLOTS.has(slot):
		return false
	if equip_id.strip_edges().is_empty():
		return false
	if not _registry.has_equipment(equip_id):
		return false

	# 装备类型必须与槽位一一对应，防止“护甲穿到兵器槽”。
	var equip_data: Dictionary = _registry.get_equipment(equip_id)
	var equip_type: String = str(equip_data.get("type", "")).strip_edges()
	if equip_type != slot:
		return false

	var equip_slots: Dictionary = _normalize_equip_slots_dict(_node_prop(unit, "equip_slots", {}))
	equip_slots[slot] = equip_id
	if _count_filled_equip_slots(equip_slots) > int(_node_prop(unit, "max_equip_count", 3)):
		return false

	unit.set("equip_slots", equip_slots)
	apply_gongfa(unit)
	_refresh_linkages(true)
	return true


func unequip_equipment(unit: Node, slot: String) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if not ALLOWED_EQUIP_SLOTS.has(slot):
		return
	var equip_slots: Dictionary = _normalize_equip_slots_dict(_node_prop(unit, "equip_slots", {}))
	equip_slots[slot] = ""
	unit.set("equip_slots", equip_slots)
	apply_gongfa(unit)
	_refresh_linkages(true)


func get_active_linkages() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for item in _active_linkages:
		output.append(item.duplicate(true))
	return output


func get_active_linkage_names() -> Array[String]:
	return _active_linkage_names_cache.duplicate()


func get_active_linkage_summary_text() -> String:
	return _active_linkage_summary_text


func get_unit_buff_ids(unit: Node) -> Array[String]:
	# 提供给 Tooltip/详情面板读取单位当前 Buff 列表。
	return _buff_manager.get_active_buff_ids_for_unit(unit)


func _register_battle_unit(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	_battle_units.append(unit)
	_unit_lookup[iid] = unit


func _build_unit_baseline_stats(unit: Node) -> Dictionary:
	# baseline 必须从“角色基础 + 星级倍率”重建，避免多次重算累计误差。
	var base_stats: Dictionary = (_node_prop(unit, "base_stats", {}) as Dictionary).duplicate(true)
	var star_level: int = int(_node_prop(unit, "star_level", 1))
	var runtime: Dictionary = _unit_data_script.call("build_runtime_stats", base_stats, star_level)
	return runtime


func _resolve_equipped_gongfa_ids(unit: Node) -> Array[String]:
	var ids: Array[String] = []
	var slots: Dictionary = _normalize_slots_dict(_node_prop(unit, "gongfa_slots", {}))
	for slot in ALLOWED_SLOTS:
		var gid: String = str(slots.get(slot, "")).strip_edges()
		if gid.is_empty():
			continue
		if ids.has(gid):
			continue
		ids.append(gid)

	return ids


func _resolve_equipped_equip_ids(unit: Node) -> Array[String]:
	var ids: Array[String] = []
	var max_count: int = clampi(int(_node_prop(unit, "max_equip_count", 3)), 0, 3)
	if max_count <= 0:
		return ids
	var slots: Dictionary = _normalize_equip_slots_dict(_node_prop(unit, "equip_slots", {}))
	for slot in ALLOWED_EQUIP_SLOTS:
		var equip_id: String = str(slots.get(slot, "")).strip_edges()
		if equip_id.is_empty():
			continue
		if ids.has(equip_id):
			continue
		ids.append(equip_id)
		if ids.size() >= max_count:
			break
	return ids


func _apply_state_to_unit(unit_id: int, preserve_health_ratio: bool) -> void:
	if not _unit_states.has(unit_id):
		return
	var state: Dictionary = _unit_states[unit_id]
	var unit: Node = state.get("unit", null)
	if unit == null or not is_instance_valid(unit):
		return

	var runtime_stats: Dictionary = (state.get("baseline_stats", {}) as Dictionary).duplicate(true)
	var modifiers: Dictionary = _effect_engine.create_empty_modifier_bundle()

	# 属性叠加顺序：
	# 1. 功法被动 -> 2. 装备被动 -> 3. 联动效果 -> 4. Buff 效果。
	# 该顺序会影响 stat_percent 的乘算基准，必须保持稳定。
	_effect_engine.apply_passive_effects(runtime_stats, modifiers, state.get("passive_effects", []))
	_effect_engine.apply_passive_effects(runtime_stats, modifiers, state.get("equipment_effects", []))
	_effect_engine.apply_passive_effects(runtime_stats, modifiers, state.get("linkage_effects", []))
	_effect_engine.apply_passive_effects(
		runtime_stats,
		modifiers,
		_buff_manager.collect_passive_effects_for_unit(unit)
	)
	_clamp_runtime_stats(runtime_stats)

	unit.set("runtime_stats", runtime_stats)
	unit.set("runtime_linkage_tags", state.get("runtime_linkage_tags", []))
	unit.set("runtime_gongfa_elements", state.get("runtime_elements", []))
	unit.set("runtime_equipped_gongfa_ids", state.get("equipped_gongfa_ids", []))
	unit.set("runtime_equipped_equip_ids", state.get("equipped_equip_ids", []))

	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat != null:
		if combat.has_method("refresh_runtime_stats"):
			combat.call("refresh_runtime_stats", runtime_stats, preserve_health_ratio)
		else:
			combat.call("reset_from_stats", runtime_stats)
		if combat.has_method("set_external_modifiers"):
			combat.call("set_external_modifiers", modifiers)

	var movement: Node = unit.get_node_or_null("Components/UnitMovement")
	if movement != null:
		if movement.has_method("refresh_runtime_stats"):
			movement.call("refresh_runtime_stats", runtime_stats)
		else:
			movement.call("reset_from_stats", runtime_stats)


func _reapply_changed_units(changed_ids_variant: Variant) -> void:
	if not (changed_ids_variant is Array):
		return
	for iid_value in changed_ids_variant:
		_apply_state_to_unit(int(iid_value), true)


func _poll_auto_triggers() -> void:
	for key in _unit_states.keys():
		var iid: int = int(key)
		var state: Dictionary = _unit_states[iid]
		var unit: Node = state.get("unit", null)
		if unit == null or not is_instance_valid(unit):
			continue
		if not _is_unit_alive(unit):
			continue

		var triggers: Array = state.get("triggers", [])
		for idx in range(triggers.size()):
			var entry: Dictionary = triggers[idx]
			var trigger: String = str(entry.get("trigger", ""))
			if trigger == "auto_mp_full" or trigger == "manual" or trigger == "auto_hp_below" or trigger == "passive_aura":
				if _can_trigger_entry(unit, entry):
					_try_fire_skill(unit, entry, {})
			triggers[idx] = entry
		state["triggers"] = triggers
		_unit_states[iid] = state


func _can_trigger_entry(unit: Node, entry: Dictionary) -> bool:
	if _battle_elapsed < float(entry.get("next_ready_time", 0.0)):
		return false
	var max_trigger_count: int = int(entry.get("max_trigger_count", 0))
	if max_trigger_count > 0 and int(entry.get("trigger_count", 0)) >= max_trigger_count:
		return false

	var trigger: String = str(entry.get("trigger", ""))
	if trigger == "auto_mp_full" or trigger == "manual":
		var mp_cost: float = float(entry.get("mp_cost", 0.0))
		return _get_combat_value(unit, "current_mp") >= mp_cost
	if trigger == "auto_hp_below":
		var threshold: float = 0.3
		var skill_data: Dictionary = entry.get("skill_data", {})
		if skill_data.has("threshold"):
			threshold = clampf(float(skill_data.get("threshold", 0.3)), 0.01, 0.95)
		var hp: float = _get_combat_value(unit, "current_hp")
		var max_hp: float = maxf(_get_combat_value(unit, "max_hp"), 1.0)
		return hp / max_hp <= threshold
	if trigger == "passive_aura":
		# passive_aura 依赖冷却节奏持续刷新，默认可触发。
		return true
	return false


func _try_fire_skill(source: Node, entry: Dictionary, event_context: Dictionary) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if not _is_unit_alive(source):
		return false

	var chance: float = clampf(float(entry.get("chance", 1.0)), 0.0, 1.0)
	if chance < 1.0 and randf() > chance:
		return false

	var skill_data: Dictionary = entry.get("skill_data", {})
	var effects: Variant = skill_data.get("effects", [])
	if not (effects is Array):
		return false

	# 技能目标与射程校验：
	# 1) 只有“指向敌方目标”的技能才要求锁定敌人并做距离判定。
	# 2) 无目标技能（如 buff_self / heal_self / aura）不会因为没有敌人而失败。
	var effect_list: Array = effects as Array
	var requires_enemy_target: bool = _skill_requires_enemy_target(effect_list)
	var skill_range_cells: float = _resolve_skill_cast_range_cells(source, skill_data)

	var target: Node = event_context.get("target", null)
	if requires_enemy_target:
		if not _is_valid_enemy_target(source, target):
			target = null
		if target != null and is_instance_valid(target):
			if not _is_target_in_skill_range(source, target, skill_range_cells):
				target = null
		if target == null:
			target = _pick_nearest_enemy_in_range(source, skill_range_cells)
		# 范围内找不到目标时，本次触发直接失败，不消耗内力、不进入冷却。
		if target == null:
			return false
	else:
		# 让无目标技能也有稳定 target（默认自身），便于事件日志和特效位置统一处理。
		if target == null or not is_instance_valid(target):
			target = source

	var mp_cost: float = float(entry.get("mp_cost", 0.0))
	if mp_cost > 0.0:
		var combat: Node = source.get_node_or_null("Components/UnitCombat")
		if combat == null:
			return false
		if float(combat.get("current_mp")) < mp_cost:
			return false
		combat.call("add_mp", -mp_cost)

	var execution_context: Dictionary = _build_effect_context(source, target, event_context)
	var execution_summary: Dictionary = _effect_engine.execute_active_effects(source, target, effect_list, execution_context)
	_emit_effect_log_events(
		execution_summary,
		source,
		target,
		"skill",
		str(entry.get("gongfa_id", "")),
		str(entry.get("trigger", "")),
		{"event_type": "apply"}
	)

	var skill_vfx: String = str(skill_data.get("vfx_id", "")).strip_edges()
	if not skill_vfx.is_empty() and _bound_vfx_factory != null:
		var from_pos: Vector2 = (source as Node2D).position
		var to_pos: Vector2 = (target as Node2D).position if target != null and is_instance_valid(target) else from_pos
		_bound_vfx_factory.call("play_attack_vfx", skill_vfx, from_pos, to_pos)

	source.call("play_anim_state", 3, {}) # SKILL

	entry["trigger_count"] = int(entry.get("trigger_count", 0)) + 1
	entry["next_ready_time"] = _battle_elapsed + float(entry.get("cooldown", 0.0))
	skill_triggered.emit(source, str(entry.get("gongfa_id", "")), str(entry.get("trigger", "")))
	return true


func _build_effect_context(source: Node, target: Node, event_context: Dictionary) -> Dictionary:
	return {
		"source": source,
		"target": target,
		"event_context": event_context,
		"all_units": _battle_units,
		"hex_size": _bound_hex_grid.get("hex_size") if _bound_hex_grid != null else 26.0,
		"vfx_factory": _bound_vfx_factory,
		"buff_manager": _buff_manager
	}


func _execute_buff_tick_requests(tick_requests_variant: Variant) -> void:
	if not (tick_requests_variant is Array):
		return
	for req_value in tick_requests_variant:
		if not (req_value is Dictionary):
			continue
		var req: Dictionary = req_value
		var source: Node = _unit_lookup.get(int(req.get("source_id", -1)), null)
		var target: Node = _unit_lookup.get(int(req.get("target_id", -1)), null)
		var buff_id: String = str(req.get("buff_id", "")).strip_edges()
		var effects: Variant = req.get("effects", [])
		if not (effects is Array):
			continue
		var context: Dictionary = _build_effect_context(source, target, {"trigger": "buff_tick", "buff_id": buff_id})
		var tick_summary: Dictionary = _effect_engine.execute_active_effects(source, target, effects as Array, context)
		_emit_effect_log_events(
			tick_summary,
			source,
			target,
			"buff_tick",
			"",
			"buff_tick",
			{"buff_id": buff_id, "event_type": "tick"}
		)
		# 即使该次 tick 不造成直接伤害，也要记录“Buff 已触发”这件事。
		if not buff_id.is_empty():
			var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
			var target_team: int = int(target.get("team_id")) if target != null and is_instance_valid(target) else 0
			buff_event.emit({
				"origin": "buff_tick",
				"event_type": "tick",
				"source": source,
				"target": target,
				"source_team": source_team,
				"target_team": target_team,
				"buff_id": buff_id,
				"duration": 0.0,
				"op": "buff_tick",
				"gongfa_id": "",
				"trigger": "buff_tick"
			})


func _emit_effect_log_events(
	summary: Dictionary,
	default_source: Node,
	default_target: Node,
	origin: String,
	gongfa_id: String,
	trigger: String,
	extra_fields: Dictionary = {}
) -> void:
	if summary.is_empty():
		return

	var damage_events: Variant = summary.get("damage_events", [])
	if damage_events is Array:
		for event_value in damage_events:
			if not (event_value is Dictionary):
				continue
			var event_data: Dictionary = event_value
			var source_node: Node = event_data.get("source", default_source)
			var target_node: Node = event_data.get("target", default_target)
			var payload: Dictionary = {
				"origin": origin,
				"source": source_node,
				"target": target_node,
				"source_team": int(source_node.get("team_id")) if source_node != null and is_instance_valid(source_node) else 0,
				"target_team": int(target_node.get("team_id")) if target_node != null and is_instance_valid(target_node) else 0,
				"damage": float(event_data.get("damage", 0.0)),
				"damage_type": str(event_data.get("damage_type", "internal")),
				"op": str(event_data.get("op", "")),
				"gongfa_id": gongfa_id,
				"trigger": trigger
			}
			for k in extra_fields.keys():
				payload[k] = extra_fields[k]
			skill_effect_damage.emit(payload)

	var heal_events: Variant = summary.get("heal_events", [])
	if heal_events is Array:
		for heal_value in heal_events:
			if not (heal_value is Dictionary):
				continue
			var heal_data: Dictionary = heal_value
			var source_node_heal: Node = heal_data.get("source", default_source)
			var target_node_heal: Node = heal_data.get("target", default_target)
			var heal_payload: Dictionary = {
				"origin": origin,
				"source": source_node_heal,
				"target": target_node_heal,
				"source_team": int(source_node_heal.get("team_id")) if source_node_heal != null and is_instance_valid(source_node_heal) else 0,
				"target_team": int(target_node_heal.get("team_id")) if target_node_heal != null and is_instance_valid(target_node_heal) else 0,
				"heal": float(heal_data.get("heal", 0.0)),
				"op": str(heal_data.get("op", "")),
				"gongfa_id": gongfa_id,
				"trigger": trigger
			}
			for k2 in extra_fields.keys():
				heal_payload[k2] = extra_fields[k2]
			skill_effect_heal.emit(heal_payload)

	var buff_events: Variant = summary.get("buff_events", [])
	if buff_events is Array:
		for buff_value in buff_events:
			if not (buff_value is Dictionary):
				continue
			var buff_data: Dictionary = buff_value
			var source_node2: Node = buff_data.get("source", default_source)
			var target_node2: Node = buff_data.get("target", default_target)
			var payload2: Dictionary = {
				"origin": origin,
				"source": source_node2,
				"target": target_node2,
				"source_team": int(source_node2.get("team_id")) if source_node2 != null and is_instance_valid(source_node2) else 0,
				"target_team": int(target_node2.get("team_id")) if target_node2 != null and is_instance_valid(target_node2) else 0,
				"buff_id": str(buff_data.get("buff_id", "")),
				"duration": float(buff_data.get("duration", 0.0)),
				"op": str(buff_data.get("op", "")),
				"gongfa_id": gongfa_id,
				"trigger": trigger,
				"event_type": "apply"
			}
			for key in extra_fields.keys():
				payload2[key] = extra_fields[key]
			buff_event.emit(payload2)


func _refresh_linkages(preserve_health_ratio: bool) -> void:
	_linkages_dirty = false
	# 收集“本轮实际分配到联动效果的单位”，避免对全部 400 单位做 _apply_state_to_unit。
	var affected_unit_ids: Dictionary = {} # iid -> true

	for key in _unit_states.keys():
		var state: Dictionary = _unit_states[key]
		var prev_linkage: Array = state.get("linkage_effects", [])
		if not prev_linkage.is_empty():
			# 上一轮有联动效果的单位需要重算（效果可能已变）。
			affected_unit_ids[key] = true
		state["linkage_effects"] = []
		_unit_states[key] = state

	var linkages: Array[Dictionary] = _registry.get_all_linkages()
	var results: Array[Dictionary] = _linkage_detector.detect_all(linkages, _battle_units, _bound_hex_grid)
	_active_linkages = results
	_active_linkage_names_cache.clear()
	for result in results:
		var linkage_name: String = str((result.get("linkage_data", {}) as Dictionary).get("name", "")).strip_edges()
		if not linkage_name.is_empty():
			_active_linkage_names_cache.append(linkage_name)
	_active_linkage_summary_text = "当前联动：无" if _active_linkage_names_cache.is_empty() else "当前联动：%s" % "、".join(_active_linkage_names_cache)

	for result in results:
		var linkage_data: Dictionary = result.get("linkage_data", {})
		var effects_value: Variant = linkage_data.get("effects", [])
		if not (effects_value is Array):
			continue
		for effect_value in effects_value:
			if not (effect_value is Dictionary):
				continue
			var linkage_effect: Dictionary = (effect_value as Dictionary).duplicate(false)
			var target_mode: String = str(linkage_effect.get("target", "participants"))
			linkage_effect.erase("target")
			for target_unit in _resolve_linkage_targets(target_mode, result):
				if target_unit == null or not is_instance_valid(target_unit):
					continue
				var iid: int = target_unit.get_instance_id()
				if not _unit_states.has(iid):
					continue
				var state2: Dictionary = _unit_states[iid]
				var effect_list: Array = state2.get("linkage_effects", [])
				effect_list.append(linkage_effect.duplicate(false))
				state2["linkage_effects"] = effect_list
				_unit_states[iid] = state2
				affected_unit_ids[iid] = true

	# 只对实际受到联动影响的单位重算属性，避免全量 apply。
	for key in affected_unit_ids.keys():
		_apply_state_to_unit(int(key), preserve_health_ratio)

	linkage_changed.emit(get_active_linkages())


func _resolve_linkage_targets(target_mode: String, result: Dictionary) -> Array[Node]:
	var participants: Array[Node] = []
	var participants_value: Variant = result.get("participants", [])
	if participants_value is Array:
		for unit in participants_value:
			participants.append(unit)

	match target_mode:
		"participants":
			return participants
		"all_allies":
			return _get_alive_team_units(int(result.get("team_id", 0)))
		"random_enemy":
			var enemies: Array[Node] = _get_alive_enemy_units(int(result.get("team_id", 0)))
			if enemies.is_empty():
				return []
			return [enemies[randi() % enemies.size()]]
		"zhenfa_area":
			# 预留：后续接入阵法范围几何检测，当前先作用于参与者。
			return participants
		_:
			return participants


func _get_alive_team_units(team_id: int) -> Array[Node]:
	var output: Array[Node] = []
	for unit in _battle_units:
		if unit == null or not is_instance_valid(unit):
			continue
		if int(unit.get("team_id")) != team_id:
			continue
		if not _is_unit_alive(unit):
			continue
		output.append(unit)
	return output


func _get_alive_enemy_units(team_id: int) -> Array[Node]:
	var output: Array[Node] = []
	for unit in _battle_units:
		if unit == null or not is_instance_valid(unit):
			continue
		if int(unit.get("team_id")) == team_id:
			continue
		if not _is_unit_alive(unit):
			continue
		output.append(unit)
	return output


func _pick_nearest_enemy(source: Node) -> Node:
	if source == null or not is_instance_valid(source):
		return null
	var source_pos: Vector2 = (source as Node2D).position
	var source_team: int = int(source.get("team_id"))
	var best: Node = null
	var best_d2: float = INF
	for unit in _battle_units:
		if unit == null or not is_instance_valid(unit):
			continue
		if unit == source:
			continue
		if int(unit.get("team_id")) == source_team:
			continue
		if not _is_unit_alive(unit):
			continue
		var d2: float = source_pos.distance_squared_to((unit as Node2D).position)
		if d2 < best_d2:
			best_d2 = d2
			best = unit
	return best


func _pick_nearest_enemy_in_range(source: Node, range_cells: float) -> Node:
	if source == null or not is_instance_valid(source):
		return null
	var source_pos: Vector2 = (source as Node2D).position
	var source_team: int = int(source.get("team_id"))
	var max_world: float = _cells_to_world_distance(range_cells)
	var max_d2: float = max_world * max_world
	var best: Node = null
	var best_d2: float = INF
	for unit in _battle_units:
		if unit == null or not is_instance_valid(unit):
			continue
		if unit == source:
			continue
		if int(unit.get("team_id")) == source_team:
			continue
		if not _is_unit_alive(unit):
			continue
		var d2: float = source_pos.distance_squared_to((unit as Node2D).position)
		if d2 > max_d2:
			continue
		if d2 < best_d2:
			best_d2 = d2
			best = unit
	return best


func _skill_requires_enemy_target(effects: Array) -> bool:
	for effect_value in effects:
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value as Dictionary
		var op: String = str(effect.get("op", "")).strip_edges()
		match op:
			"damage_target", "debuff_target", "teleport_behind", "dash_forward", "knockback_target":
				return true
			_:
				continue
	return false


func _resolve_skill_cast_range_cells(source: Node, skill_data: Dictionary) -> float:
	# 优先读 skill.range；未配置时退化为单位基础射程，避免旧数据突然“无限技能”。
	if skill_data.has("range"):
		return clampf(float(skill_data.get("range", DEFAULT_SKILL_CAST_RANGE_CELLS)), 0.0, 12.0)
	if source == null or not is_instance_valid(source):
		return DEFAULT_SKILL_CAST_RANGE_CELLS
	var runtime_stats: Variant = source.get("runtime_stats")
	if runtime_stats is Dictionary:
		return clampf(float((runtime_stats as Dictionary).get("rng", DEFAULT_SKILL_CAST_RANGE_CELLS)), 1.0, 12.0)
	return DEFAULT_SKILL_CAST_RANGE_CELLS


func _is_valid_enemy_target(source: Node, target: Node) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if target == null or not is_instance_valid(target):
		return false
	if target == source:
		return false
	if int(target.get("team_id")) == int(source.get("team_id")):
		return false
	return _is_unit_alive(target)


func _is_target_in_skill_range(source: Node, target: Node, range_cells: float) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if target == null or not is_instance_valid(target):
		return false
	if range_cells <= 0.0:
		return true
	var max_world: float = _cells_to_world_distance(range_cells)
	return (source as Node2D).position.distance_squared_to((target as Node2D).position) <= max_world * max_world


func _cells_to_world_distance(cells: float) -> float:
	var hex_size: float = 26.0
	if _bound_hex_grid != null:
		hex_size = float(_bound_hex_grid.get("hex_size"))
	return maxf(cells, 0.0) * maxf(hex_size, 1.0) * 1.2


func _on_battle_started(_ally_count: int, _enemy_count: int) -> void:
	_battle_running = true
	_battle_elapsed = 0.0
	_trigger_accum = 0.0
	_linkage_accum = 0.0
	_linkages_dirty = false
	_fire_trigger_for_all("on_combat_start", {})


func _on_damage_resolved(event_dict: Dictionary) -> void:
	var source_id: int = int(event_dict.get("source_id", -1))
	var target_id: int = int(event_dict.get("target_id", -1))
	var source: Node = _unit_lookup.get(source_id, null)
	var target: Node = _unit_lookup.get(target_id, null)
	if source == null or not is_instance_valid(source):
		return

	var is_dodged: bool = bool(event_dict.get("is_dodged", false))
	if not is_dodged:
		_fire_trigger_for_unit(source, "on_attack_hit", {"target": target, "event": event_dict})
	if target != null and is_instance_valid(target):
		_fire_trigger_for_unit(target, "on_attacked", {"target": source, "event": event_dict})


func _on_unit_died(dead_unit: Node, killer: Node, team_id: int) -> void:
	if killer != null and is_instance_valid(killer):
		_fire_trigger_for_unit(killer, "on_kill", {"target": dead_unit})

	for ally in _battle_units:
		if ally == null or not is_instance_valid(ally):
			continue
		if ally == dead_unit:
			continue
		if int(ally.get("team_id")) != team_id:
			continue
		if not _is_unit_alive(ally):
			continue
		_fire_trigger_for_unit(ally, "on_ally_death", {"target": dead_unit})

	_buff_manager.remove_all_for_unit(dead_unit)
	_linkages_dirty = true


func _on_battle_ended(_winner_team: int, _summary: Dictionary) -> void:
	_battle_running = false


func _fire_trigger_for_all(trigger: String, context: Dictionary) -> void:
	for unit in _battle_units:
		_fire_trigger_for_unit(unit, trigger, context)


func _fire_trigger_for_unit(unit: Node, trigger: String, context: Dictionary) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	if not _unit_states.has(iid):
		return
	var state: Dictionary = _unit_states[iid]
	var triggers: Array = state.get("triggers", [])
	for idx in range(triggers.size()):
		var entry: Dictionary = triggers[idx]
		if str(entry.get("trigger", "")) != trigger:
			continue
		if _can_trigger_entry(unit, entry):
			_try_fire_skill(unit, entry, context)
		triggers[idx] = entry
	state["triggers"] = triggers
	_unit_states[iid] = state


func _clamp_runtime_stats(runtime_stats: Dictionary) -> void:
	var min_positive_keys: Array[String] = ["hp", "spd", "mov", "rng"]
	for key in runtime_stats.keys():
		runtime_stats[key] = maxf(float(runtime_stats[key]), 0.0)
	for key in min_positive_keys:
		if runtime_stats.has(key):
			runtime_stats[key] = maxf(float(runtime_stats[key]), 1.0)


func _normalize_slots_dict(raw: Variant) -> Dictionary:
	var slots: Dictionary = {
		"neigong": "",
		"waigong": "",
		"qinggong": "",
		"zhenfa": "",
		"qishu": ""
	}
	if raw is Dictionary:
		for slot in ALLOWED_SLOTS:
			slots[slot] = str((raw as Dictionary).get(slot, "")).strip_edges()
	return slots


func _normalize_equip_slots_dict(raw: Variant) -> Dictionary:
	var slots: Dictionary = {
		"weapon": "",
		"armor": "",
		"accessory": ""
	}
	if raw is Dictionary:
		for slot in ALLOWED_EQUIP_SLOTS:
			slots[slot] = str((raw as Dictionary).get(slot, "")).strip_edges()
	return slots


func _count_filled_slots(slots: Dictionary) -> int:
	var count: int = 0
	for slot in ALLOWED_SLOTS:
		if str(slots.get(slot, "")).strip_edges() != "":
			count += 1
	return count


func _count_filled_equip_slots(slots: Dictionary) -> int:
	var count: int = 0
	for slot in ALLOWED_EQUIP_SLOTS:
		if str(slots.get(slot, "")).strip_edges() != "":
			count += 1
	return count


func _node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if node == null or not is_instance_valid(node):
		return fallback
	if not node.has_method("get"):
		return fallback
	var value: Variant = node.get(key)
	if value == null:
		return fallback
	return value


func _to_string_array(value: Variant) -> Array[String]:
	var output: Array[String] = []
	if value is Array:
		for item in value:
			output.append(str(item))
	return output


func _dict_keys_to_string_array(dict_value: Dictionary) -> Array[String]:
	var output: Array[String] = []
	for key in dict_value.keys():
		output.append(str(key))
	return output


func _is_unit_alive(unit: Node) -> bool:
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return false
	return bool(combat.get("is_alive"))


func _get_combat_value(unit: Node, key: String) -> float:
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0
	return float(combat.get(key))


func _connect_event_bus() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null:
		return
	var cb: Callable = Callable(self, "_on_data_reloaded")
	if not event_bus.is_connected("data_reloaded", cb):
		event_bus.connect("data_reloaded", cb)


func _connect_combat_signals() -> void:
	if _bound_combat_manager == null:
		return
	var cb_start: Callable = Callable(self, "_on_battle_started")
	var cb_damage: Callable = Callable(self, "_on_damage_resolved")
	var cb_dead: Callable = Callable(self, "_on_unit_died")
	var cb_end: Callable = Callable(self, "_on_battle_ended")
	if not _bound_combat_manager.is_connected("battle_started", cb_start):
		_bound_combat_manager.connect("battle_started", cb_start)
	if not _bound_combat_manager.is_connected("damage_resolved", cb_damage):
		_bound_combat_manager.connect("damage_resolved", cb_damage)
	if not _bound_combat_manager.is_connected("unit_died", cb_dead):
		_bound_combat_manager.connect("unit_died", cb_dead)
	if not _bound_combat_manager.is_connected("battle_ended", cb_end):
		_bound_combat_manager.connect("battle_ended", cb_end)


func _disconnect_combat_signals() -> void:
	if _bound_combat_manager == null:
		return
	var cb_start: Callable = Callable(self, "_on_battle_started")
	var cb_damage: Callable = Callable(self, "_on_damage_resolved")
	var cb_dead: Callable = Callable(self, "_on_unit_died")
	var cb_end: Callable = Callable(self, "_on_battle_ended")
	if _bound_combat_manager.is_connected("battle_started", cb_start):
		_bound_combat_manager.disconnect("battle_started", cb_start)
	if _bound_combat_manager.is_connected("damage_resolved", cb_damage):
		_bound_combat_manager.disconnect("damage_resolved", cb_damage)
	if _bound_combat_manager.is_connected("unit_died", cb_dead):
		_bound_combat_manager.disconnect("unit_died", cb_dead)
	if _bound_combat_manager.is_connected("battle_ended", cb_end):
		_bound_combat_manager.disconnect("battle_ended", cb_end)


func _on_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	reload_from_data()
	# 数据热重载后，战场中单位按新配置重算一次，便于即时验证 Mod。
	for unit in _battle_units:
		apply_gongfa(unit)
	_refresh_linkages(true)


func _get_event_bus() -> Node:
	var tree: SceneTree = _get_scene_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("EventBus")


func _get_data_manager() -> Node:
	var tree: SceneTree = _get_scene_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("DataManager")


func _get_scene_tree() -> SceneTree:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	return main_loop as SceneTree
