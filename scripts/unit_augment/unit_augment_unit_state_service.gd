extends RefCounted
class_name UnitAugmentUnitStateService

const ALLOWED_SLOTS: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa"]
const DEFAULT_EQUIP_SLOTS: Array[String] = ["slot_1", "slot_2"]

var _registry: Variant
var _effect_engine: Variant
var _buff_manager: Variant
var _tag_linkage_scheduler: Variant
var _unit_data_script: Script
var _tag_linkage_tag_to_index: Dictionary = {}
var _tag_linkage_registry_version: int = 0
var _tag_linkage_mask_word_count: int = 0

var _battle_units: Array[Node] = []
var _unit_lookup: Dictionary = {}
var _unit_states: Dictionary = {}
var _poll_trigger_unit_ids: Array[int] = []
var _state_poll_trigger_unit_ids: Array[int] = []
var _passive_aura_trigger_unit_ids: Array[int] = []
var _timed_poll_trigger_unit_ids: Array[int] = []
var _passive_aura_source_ids_by_cell: Dictionary = {}
var _passive_aura_source_cell_by_unit: Dictionary = {}
var _passive_aura_dirty_margin_by_unit: Dictionary = {}
var _passive_aura_max_dirty_margin_cells: int = 0
var _hex_radius_offsets_cache: Dictionary = {}
var _combat_lookup: Dictionary = {}
var _movement_lookup: Dictionary = {}
var _next_trigger_entry_uid: int = 1

# 依赖在构造时固定下来，避免运行时到处抓全局对象。
# `registry`/`effect_engine`/`buff_manager`/`unit_data_script` 共同组成 UnitAugment 的状态投影底座。
func _init(
	registry: Variant,
	effect_engine: Variant,
	buff_manager: Variant,
	tag_linkage_scheduler: Variant,
	unit_data_script: Script
) -> void:
	_registry = registry
	_effect_engine = effect_engine
	_buff_manager = buff_manager
	_tag_linkage_scheduler = tag_linkage_scheduler
	_unit_data_script = unit_data_script

# 新一场战斗开始前必须清空 battle units、lookup 和 runtime state。
# `_next_trigger_entry_uid` 也要回到 1，但单位节点自身的槽位配置不在这里清理。
func reset_battle_state() -> void:
	_battle_units.clear()
	_unit_lookup.clear()
	_unit_states.clear()
	_poll_trigger_unit_ids.clear()
	_state_poll_trigger_unit_ids.clear()
	_passive_aura_trigger_unit_ids.clear()
	_timed_poll_trigger_unit_ids.clear()
	_passive_aura_source_ids_by_cell.clear()
	_passive_aura_source_cell_by_unit.clear()
	_passive_aura_dirty_margin_by_unit.clear()
	_passive_aura_max_dirty_margin_cells = 0
	_hex_radius_offsets_cache.clear()
	_combat_lookup.clear()
	_movement_lookup.clear()
	_next_trigger_entry_uid = 1

# battle runtime 通过这个入口登记参与单位，避免 manager 自己维护第二套数组。
# `_unit_lookup` 负责 instance_id -> node 映射；重复登记会被忽略，保证 battle_units 不出现重复单位。
func register_battle_unit(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	if _unit_lookup.has(iid):
		return
	_battle_units.append(unit)
	_unit_lookup[iid] = unit
	_cache_components_for_unit(unit)

# `all_units` 会被 effect runtime、trigger runtime 和 tooltip 同时读取。
# 这里返回节点引用数组本体，调用方只读使用，增删统一走 register/reset 两个显式入口。
func get_battle_units() -> Array[Node]:
	return _battle_units

# unit lookup 主要用于 damage/buff/tick 事件回放时按 instance_id 找回节点。
# 外层拿到的是共享映射视图，因此默认只读；真正写入只允许发生在登记和重置阶段。
func get_unit_lookup() -> Dictionary:
	return _unit_lookup

# unit state 只应由 UnitStateService 和 TriggerRuntime 修改。
# 每个 state 都挂着 baseline、passive、equipment 和 trigger 视图；其他系统改 trigger 必须先取副本再回写。
func get_unit_states() -> Dictionary:
	return _unit_states


func get_poll_trigger_unit_ids() -> Array[int]:
	return _poll_trigger_unit_ids


func get_state_poll_trigger_unit_ids() -> Array[int]:
	return _state_poll_trigger_unit_ids


func get_passive_aura_trigger_unit_ids() -> Array[int]:
	return _passive_aura_trigger_unit_ids


func get_timed_poll_trigger_unit_ids() -> Array[int]:
	return _timed_poll_trigger_unit_ids


func configure_tag_linkage_registry(tag_to_index: Dictionary, version: int) -> void:
	var normalized: Dictionary = {}
	for raw_key in tag_to_index.keys():
		var tag: String = str(raw_key).strip_edges().to_lower()
		if tag.is_empty():
			continue
		normalized[tag] = int(tag_to_index[raw_key])
	_tag_linkage_tag_to_index = normalized
	_tag_linkage_registry_version = maxi(version, 0)
	_tag_linkage_mask_word_count = int(ceili(float(_tag_linkage_tag_to_index.size()) / 64.0))

# 运行时状态查询统一走 iid，避免外层重复拼接 get_instance_id 逻辑。
# `unit` 为空或失效时直接回空字典，且返回值仍是副本，避免外层误写内部状态。
func get_state_for_unit(unit: Node) -> Dictionary:
	if unit == null or not is_instance_valid(unit):
		return {}
	return get_state_by_id(unit.get_instance_id())


func get_tag_linkage_provider_cache(unit: Node) -> Dictionary:
	if unit == null or not is_instance_valid(unit):
		return {"available": false, "entries": []}
	var iid: int = unit.get_instance_id()
	if not _unit_states.has(iid):
		return {"available": false, "entries": []}
	var state: Dictionary = _unit_states[iid] as Dictionary
	if not state.has("tag_linkage_provider_entries"):
		return {"available": false, "entries": []}
	if int(state.get("tag_linkage_registry_version", -1)) != _tag_linkage_registry_version:
		return {"available": false, "entries": []}
	var entries_value: Variant = state.get("tag_linkage_provider_entries", [])
	if entries_value is Array:
		return {"available": true, "entries": entries_value}
	return {"available": true, "entries": []}

# 外层只拿副本读状态，写状态必须走显式 setter。
# 深拷贝是为了保护 triggers、baseline_stats 这些嵌套结构不被外层直接篡改。
# 如果没有命中 unit_id，会统一回空字典而不是返回 null。
func get_state_by_id(unit_id: int) -> Dictionary:
	if not _unit_states.has(unit_id):
		return {}
	return (_unit_states[unit_id] as Dictionary).duplicate(true)

# trigger runtime 在更新冷却、次数和边沿状态时，需要显式回写完整 state。
# 这里不做 merge，是因为调用方已经持有完整副本并完成了本次改动。
# 写回粒度保持在整份 state，避免局部字段更新遗漏联动状态。
func set_state_by_id(unit_id: int, state: Dictionary) -> void:
	_refresh_poll_state_metadata(unit_id, state)
	_unit_states[unit_id] = state


func get_unit_battle_cell(unit: Node) -> Vector2i:
	if unit == null or not is_instance_valid(unit):
		return Vector2i(-1, -1)
	var iid: int = unit.get_instance_id()
	if not _unit_states.has(iid):
		return Vector2i(-1, -1)
	var state: Dictionary = _unit_states[iid] as Dictionary
	var cell_value: Variant = state.get("passive_aura_battle_cell", Vector2i(-1, -1))
	if cell_value is Vector2i:
		return cell_value as Vector2i
	return Vector2i(-1, -1)


func set_unit_battle_cell(unit: Node, cell: Vector2i) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if cell.x < 0 or cell.y < 0:
		return
	var iid: int = unit.get_instance_id()
	if not _unit_states.has(iid):
		return
	var state: Dictionary = _unit_states[iid] as Dictionary
	state["passive_aura_battle_cell"] = cell
	_unit_states[iid] = state
	if _passive_aura_dirty_margin_by_unit.has(iid):
		_move_passive_aura_source_in_cell_index(iid, cell)


func sync_battle_cells_from_combat_manager(combat_manager: Node) -> void:
	if combat_manager == null or not is_instance_valid(combat_manager):
		return
	if not combat_manager.has_method("get_unit_cell_of"):
		return
	for unit in _battle_units:
		if unit == null or not is_instance_valid(unit):
			continue
		var cell_value: Variant = combat_manager.get_unit_cell_of(unit)
		if cell_value is Vector2i:
			set_unit_battle_cell(unit, cell_value as Vector2i)


func mark_all_passive_aura_dirty() -> void:
	for iid in _passive_aura_trigger_unit_ids:
		_mark_passive_aura_dirty_by_id(iid)


func mark_passive_aura_dirty_for_cell_change(
	changed_unit: Node,
	from_cell: Vector2i,
	to_cell: Vector2i
) -> void:
	if changed_unit != null and is_instance_valid(changed_unit):
		set_unit_battle_cell(changed_unit, to_cell)
		if not is_unit_alive(changed_unit):
			_remove_passive_aura_source_from_cell_index(changed_unit.get_instance_id())

	var has_from_cell: bool = from_cell.x >= 0 and from_cell.y >= 0
	var has_to_cell: bool = to_cell.x >= 0 and to_cell.y >= 0
	if not has_from_cell and not has_to_cell:
		return

	var candidate_unit_ids: Array[int] = _collect_passive_aura_source_candidates(
		changed_unit,
		from_cell,
		to_cell
	)
	for iid in candidate_unit_ids:
		if not _unit_states.has(iid):
			continue
		var state: Dictionary = _unit_states[iid] as Dictionary
		var source: Node = state.get("unit", null)
		if source == null or not is_instance_valid(source):
			continue
		if source == changed_unit:
			_mark_passive_aura_dirty_state(state)
			_unit_states[iid] = state
			continue
		if not is_unit_alive(source):
			continue

		var source_cell: Vector2i = _read_state_battle_cell(state)
		if source_cell.x < 0 or source_cell.y < 0:
			continue
		var dirty_radius_cells: float = maxf(float(state.get("passive_aura_dirty_radius_cells", 0.0)), 0.0)
		if dirty_radius_cells <= 0.0:
			continue
		var dirty_margin_cells: int = int(ceili(dirty_radius_cells)) + 1
		var affected: bool = false
		if has_from_cell and _hex_distance(source_cell, from_cell) <= dirty_margin_cells:
			affected = true
		elif has_to_cell and _hex_distance(source_cell, to_cell) <= dirty_margin_cells:
			affected = true
		if not affected:
			continue
		_mark_passive_aura_dirty_state(state)
		_unit_states[iid] = state


func finalize_passive_aura_poll(unit_id: int, battle_elapsed: float, keep_dirty: bool) -> void:
	if not _unit_states.has(unit_id):
		return
	var state: Dictionary = _unit_states[unit_id] as Dictionary
	state["passive_aura_dirty"] = keep_dirty
	state["next_passive_aura_dirty_poll_time"] = battle_elapsed + _resolve_passive_aura_dirty_poll_interval(
		state
	)
	state["next_passive_aura_refresh_time"] = battle_elapsed + _resolve_passive_aura_repair_interval(state)
	_unit_states[unit_id] = state

# runtime ids 优先读单位当前 runtime 字段，缺失时才退回配置槽位解析。
# 这样 UI、tooltip 和 trigger runtime 都能先看到“本轮已投影后的实际生效列表”。
# 只有在 runtime 字段尚未建立时，才退回静态槽位解析逻辑。
func get_unit_runtime_gongfa_ids(unit: Node) -> Array[String]:
	if unit == null or not is_instance_valid(unit):
		return []
	var runtime_value: Variant = unit.get("runtime_equipped_gongfa_ids")
	if runtime_value is Array:
		return _normalize_string_array(runtime_value)
	return _resolve_equipped_gongfa_ids(unit)

# 装备 runtime ids 也遵循同一规则，避免 UI 和 trigger 口径不一致。
# 这里的返回值已经考虑 max_equip_count 截断后的真实生效列表。
# 失效节点直接回空数组，不把错误传播给 UI 或 resolver。
func get_unit_runtime_equip_ids(unit: Node) -> Array[String]:
	if unit == null or not is_instance_valid(unit):
		return []
	var runtime_value: Variant = unit.get("runtime_equipped_equip_ids")
	if runtime_value is Array:
		return _normalize_string_array(runtime_value)
	return _resolve_equipped_equip_ids(unit)

# 标签查询只服务 tag linkage provider 收集，不做额外业务推断。
# `gongfa_id` 会先 strip，再走 registry 单一数据源，不扫单位节点。
# 返回值统一经过 normalize，避免大小写差异影响 linkage 查询。
func get_gongfa_tags(gongfa_id: String) -> Array[String]:
	var gid: String = gongfa_id.strip_edges()
	if gid.is_empty():
		return []
	var data: Dictionary = _registry.get_gongfa(gid)
	if data.is_empty():
		return []
	return _normalize_tag_array(data.get("tags", []))

# 装备 tags 也走 registry 单一来源，避免 UI 和 resolver 各查一套。
# `equip_id` 为空时直接回空数组，避免把缺槽位误当成无 tag 的合法条目。
# 这里不读取 runtime 状态，只回答静态装备条目的定义 tags。
func get_equipment_tags(equip_id: String) -> Array[String]:
	var eid: String = equip_id.strip_edges()
	if eid.is_empty():
		return []
	var data: Dictionary = _registry.get_equipment(eid)
	if data.is_empty():
		return []
	return _normalize_tag_array(data.get("tags", []))

# 这是 UnitAugment 的核心入口：从条目配置重建单位当前被动、装备和触发状态。
# `defer_apply` 只决定“是否立刻把状态投影到组件”，不影响 state 本身的重建。
# 所有功法、trait、装备 trigger 都会先汇总成统一 state，再由 apply_state_to_unit 落地。
func apply_unit_augment(unit: Node, defer_apply: bool = false) -> void:
	if unit == null or not is_instance_valid(unit):
		return

	# baseline 和已装备条目先统一解析出来，后面的被动与 trigger 都基于这两份输入生成。
	var iid: int = unit.get_instance_id()
	var baseline_stats: Dictionary = _build_unit_baseline_stats(unit)
	var equipped_ids: Array[String] = _resolve_equipped_gongfa_ids(unit)
	var equipped_equip_ids: Array[String] = _resolve_equipped_equip_ids(unit)
	var passive_effects: Array[Dictionary] = []
	var triggers: Array[Dictionary] = []
	var poll_triggers: Array[Dictionary] = []
	var state_poll_triggers: Array[Dictionary] = []
	var passive_aura_triggers: Array[Dictionary] = []
	var timed_poll_triggers: Array[Dictionary] = []
	var equipment_effects: Array[Dictionary] = []
	var equip_triggers: Array[Dictionary] = []
	var unit_traits: Array[Dictionary] = []

	# 功法条目提供被动效果和 skills；skills 会统一编译成 trigger entries。
	for gongfa_id in equipped_ids:
		var gongfa_data: Dictionary = _registry.get_gongfa(gongfa_id)
		if gongfa_data.is_empty():
			continue
		_collect_passive_effects(passive_effects, gongfa_data.get("passive_effects", []))
		for skill in _extract_skill_entries_from_gongfa(gongfa_data):
			triggers.append(_build_trigger_entry(gongfa_id, skill))

	# trait 走和功法同一套抽取逻辑，只是 owner_id 会换成 trait 级身份。
	var trait_values: Variant = _node_prop(unit, "traits", [])
	if trait_values is Array:
		for trait_value in trait_values:
			if trait_value is Dictionary:
				unit_traits.append((trait_value as Dictionary).duplicate(true))
	for trait_idx in range(unit_traits.size()):
		var trait_data: Dictionary = unit_traits[trait_idx]
		var trait_id: String = str(trait_data.get("id", "trait_%d" % trait_idx)).strip_edges()
		if trait_id.is_empty():
			trait_id = "trait_%d" % trait_idx
		var trait_owner_id: String = "trait_%s_%s" % [str(_node_prop(unit, "unit_id", "unit")), trait_id]
		_collect_passive_effects(passive_effects, trait_data.get("effects", []))
		for skill in _extract_skill_entries_from_gongfa(trait_data):
			triggers.append(_build_trigger_entry(trait_owner_id, skill))

	# 装备条目分成 effects 和 trigger 两部分，最终都并入单位运行时状态。
	for equip_id in equipped_equip_ids:
		var equip_data: Dictionary = _registry.get_equipment(equip_id)
		if equip_data.is_empty():
			continue
		_collect_passive_effects(equipment_effects, equip_data.get("effects", []))
		var trigger_value: Variant = equip_data.get("trigger", {})
		if trigger_value is Dictionary and not (trigger_value as Dictionary).is_empty():
			var trigger_data: Dictionary = (trigger_value as Dictionary).duplicate(true)
			if not trigger_data.has("trigger"):
				trigger_data["trigger"] = str(trigger_data.get("type", ""))
			equip_triggers.append(_build_trigger_entry(equip_id, trigger_data))

	triggers.append_array(equip_triggers)
	for entry in triggers:
		var trigger_name: String = str(entry.get("trigger", "")).strip_edges().to_lower()
		if _is_poll_trigger_name(trigger_name):
			poll_triggers.append(entry)
			if _is_timed_poll_trigger_name(trigger_name):
				timed_poll_triggers.append(entry)
			elif trigger_name == "passive_aura":
				passive_aura_triggers.append(entry)
			else:
				state_poll_triggers.append(entry)

	# 这里写入的是 UnitAugment 自己维护的标准 state 结构，供后续轮询和重算复用。
	_unit_states[iid] = {
		"unit": unit,
		"baseline_stats": baseline_stats,
		"equipped_gongfa_ids": equipped_ids,
		"equipped_equip_ids": equipped_equip_ids,
		"unit_traits": unit_traits,
		"tag_linkage_provider_entries": _build_tag_linkage_provider_entries(
			unit,
			unit_traits,
			equipped_ids,
			equipped_equip_ids
		),
		"tag_linkage_registry_version": _tag_linkage_registry_version,
		"passive_effects": passive_effects,
		"equipment_effects": equipment_effects,
		"triggers": triggers,
		"poll_triggers": poll_triggers,
		"state_poll_triggers": state_poll_triggers,
		"passive_aura_triggers": passive_aura_triggers,
		"passive_aura_dirty": not passive_aura_triggers.is_empty(),
		"passive_aura_dirty_radius_cells": _resolve_passive_aura_dirty_radius_cells(
			passive_aura_triggers
		),
		"passive_aura_battle_cell": _resolve_initial_battle_cell(unit),
		"next_passive_aura_dirty_poll_time": 0.0 if not passive_aura_triggers.is_empty() else INF,
		"next_passive_aura_refresh_time": 0.0 if not passive_aura_triggers.is_empty() else INF,
		"timed_poll_triggers": timed_poll_triggers,
		"next_timed_poll_time": _resolve_next_timed_poll_time(timed_poll_triggers)
	}
	_refresh_poll_state_metadata(iid, _unit_states[iid])

	if not defer_apply:
		apply_state_to_unit(iid, false)
	if _tag_linkage_scheduler != null:
		_tag_linkage_scheduler.notify_unit_tags_changed(unit)

# 卸载所有单位增强时，只清运行时效果，不改底层槽位配置。
# 这条路径主要服务战斗结束或临时禁用，不应该破坏 UI 上原本的槽位选择。
# 被动、装备和 trigger 三类运行时效果会一起清空，避免残留半套状态。
func remove_unit_augment(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	if not _unit_states.has(iid):
		return
	var state: Dictionary = _unit_states[iid]
	state["passive_effects"] = []
	state["equipment_effects"] = []
	state["triggers"] = []
	state["poll_triggers"] = []
	state["state_poll_triggers"] = []
	state["passive_aura_triggers"] = []
	state["passive_aura_dirty"] = false
	state["passive_aura_dirty_radius_cells"] = 0.0
	state["next_passive_aura_dirty_poll_time"] = INF
	state["next_passive_aura_refresh_time"] = INF
	state["timed_poll_triggers"] = []
	state["next_timed_poll_time"] = INF
	_unit_states[iid] = state
	_refresh_poll_state_metadata(iid, state)
	apply_state_to_unit(iid, true)

# 功法装配必须严格校验槽位类型，避免一类功法占错槽。
# `slot` 仍保持四大功法槽旧语义，不在这轮重构里改数据结构。
# 只有 registry 中确实存在且类型匹配的条目才允许写进单位槽位。
func equip_gongfa(unit: Node, slot: String, gongfa_id: String) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if not ALLOWED_SLOTS.has(slot):
		return false
	if gongfa_id.strip_edges().is_empty():
		return false
	if not _registry.has_gongfa(gongfa_id):
		return false

	var gongfa_data: Dictionary = _registry.get_gongfa(gongfa_id)
	var gongfa_type: String = str(gongfa_data.get("type", "")).strip_edges()
	if gongfa_type != slot:
		return false

	var slots: Dictionary = _normalize_slots_dict(_node_prop(unit, "gongfa_slots", {}))
	slots[slot] = gongfa_id
	unit.set("gongfa_slots", slots)
	apply_unit_augment(unit)
	return true

# 卸下功法后要立即重算 runtime stats 和 trigger entries。
# 槽位会被保留但内容清空，保证 UI 仍能看到固定槽位结构。
# 这里不做额外存在性校验之外的业务判断，核心是即时重算。
func unequip_gongfa(unit: Node, slot: String) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if not ALLOWED_SLOTS.has(slot):
		return
	var slots: Dictionary = _normalize_slots_dict(_node_prop(unit, "gongfa_slots", {}))
	slots[slot] = ""
	unit.set("gongfa_slots", slots)
	apply_unit_augment(unit)

# 装备装配要同时满足槽位存在和最大生效数限制。
# `max_equip_count` 会在这里归一化后写回单位，作为后续详情展示和运行时共用口径。
# 即便 equip_slots 配得更多，真正生效的数量也不能超过最大限制。
func equip_equipment(unit: Node, slot: String, equip_id: String) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if equip_id.strip_edges().is_empty():
		return false
	if not _registry.has_equipment(equip_id):
		return false

	var configured_max: int = int(_node_prop(unit, "max_equip_count", 0))
	var equip_slots: Dictionary = _normalize_equip_slots_dict(_node_prop(unit, "equip_slots", {}), configured_max)
	var max_count: int = _resolve_unit_max_equip_count(unit, equip_slots)
	if equip_slots.is_empty():
		return false
	if not equip_slots.has(slot):
		return false

	equip_slots[slot] = equip_id
	if _count_filled_equip_slots(equip_slots) > max_count:
		return false

	unit.set("equip_slots", equip_slots)
	unit.set("max_equip_count", max_count)
	apply_unit_augment(unit)
	return true

# 卸下装备同样会影响 trigger、tags 和 runtime stats。
# 因为 tag_linkage 可能依赖装备 tags，所以这里不能只改 UI 槽位而不重算状态。
# 这条路径和卸下功法一样，核心是尽快回到统一的 apply 流程。
func unequip_equipment(unit: Node, slot: String) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var configured_max: int = int(_node_prop(unit, "max_equip_count", 0))
	var equip_slots: Dictionary = _normalize_equip_slots_dict(_node_prop(unit, "equip_slots", {}), configured_max)
	if not equip_slots.has(slot):
		return
	equip_slots[slot] = ""
	unit.set("equip_slots", equip_slots)
	apply_unit_augment(unit)

# Buff tick、光环移除等局部变化只需要重算受影响单位，不重建整场状态。
# `changed_ids_variant` 来自 BuffManager 的变更集合，允许是 Variant 以兼容旧调用点。
# 这里默认按 preserve_health_ratio=true 重投影，避免血蓝瞬间回满。
func reapply_changed_units(changed_ids_variant: Variant) -> void:
	if not (changed_ids_variant is Array):
		return
	for iid_value in changed_ids_variant:
		apply_state_to_unit(int(iid_value), true)

# 这里统一把 baseline + passive/equipment/buff 三层效果投影到单位 runtime stats。
# `preserve_health_ratio` 只传给 UnitCombat，决定重算后是否保留当前血量比例。
# effect engine 在这里只处理被动修正，不负责主动技能或即时效果执行。
func apply_state_to_unit(unit_id: int, preserve_health_ratio: bool) -> void:
	if not _unit_states.has(unit_id):
		return
	var state: Dictionary = _unit_states[unit_id]
	var unit: Node = state.get("unit", null)
	if unit == null or not is_instance_valid(unit):
		return

	# modifiers 作为 UnitCombat 的外挂修正表单独维护，不直接塞回 runtime_stats。
	var runtime_stats: Dictionary = (state.get("baseline_stats", {}) as Dictionary).duplicate(true)
	var modifiers: Dictionary = _effect_engine.create_empty_modifier_bundle()

	# 被动、装备和 Buff 的 stat_add 都在这里按固定顺序叠加到运行时属性。
	_effect_engine.apply_passive_effects(runtime_stats, modifiers, state.get("passive_effects", []))
	_effect_engine.apply_passive_effects(runtime_stats, modifiers, state.get("equipment_effects", []))
	_effect_engine.apply_passive_effects(
		runtime_stats,
		modifiers,
		_buff_manager.collect_passive_effects_for_unit(unit)
	)
	_clamp_runtime_stats(runtime_stats)

	# runtime 字段是 UI 和 trigger runtime 的直接读取口径，因此要在组件刷新前先写回节点。
	unit.set("runtime_stats", runtime_stats)
	unit.set("runtime_equipped_gongfa_ids", state.get("equipped_gongfa_ids", []))
	unit.set("runtime_equipped_equip_ids", state.get("equipped_equip_ids", []))

	var combat: Node = _get_combat_component(unit)
	if combat != null:
		if combat.has_method("refresh_runtime_stats"):
			combat.refresh_runtime_stats(runtime_stats, preserve_health_ratio)
		else:
			combat.reset_from_stats(runtime_stats)
		if combat.has_method("set_external_modifiers"):
			combat.set_external_modifiers(modifiers)

	var movement: Node = _get_movement_component(unit)
	if movement != null:
		if movement.has_method("refresh_runtime_stats"):
			movement.refresh_runtime_stats(runtime_stats)
		else:
			movement.reset_from_stats(runtime_stats)


# TriggerRuntime 会频繁读取生命和内力，这里统一提供安全的 combat 值读取。
# `key` 对应 UnitCombat 上的公开字段名，例如 current_hp、max_hp、current_mp。
# 缺少 Combat 组件时统一回 0，避免条件服务再到处判空。
func get_combat_value(unit: Node, key: String) -> float:
	var combat: Node = _get_combat_component(unit)
	if combat == null:
		return 0.0
	return float(combat.get(key))


# 活着的定义继续以 UnitCombat.is_alive 为准，避免和场景显示状态混淆。
# 这里不参考节点是否在树上或是否隐藏，统一以战斗组件状态为准。
# 这样 trigger 条件、选敌和 tag_linkage provider 的口径可以保持一致。
func is_unit_alive(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var combat: Node = _get_combat_component(unit)
	if combat == null:
		return false
	return bool(combat.get("is_alive"))


func _cache_components_for_unit(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	_combat_lookup[iid] = unit.get_node_or_null("Components/UnitCombat")
	_movement_lookup[iid] = unit.get_node_or_null("Components/UnitMovement")


func _get_combat_component(unit: Node) -> Node:
	if unit == null or not is_instance_valid(unit):
		return null
	var iid: int = unit.get_instance_id()
	if not _combat_lookup.has(iid) or not is_instance_valid(_combat_lookup[iid]):
		_combat_lookup[iid] = unit.get_node_or_null("Components/UnitCombat")
	return _combat_lookup[iid] as Node


func _get_movement_component(unit: Node) -> Node:
	if unit == null or not is_instance_valid(unit):
		return null
	var iid: int = unit.get_instance_id()
	if not _movement_lookup.has(iid) or not is_instance_valid(_movement_lookup[iid]):
		_movement_lookup[iid] = unit.get_node_or_null("Components/UnitMovement")
	return _movement_lookup[iid] as Node


func refresh_timed_poll_state(unit_id: int) -> void:
	if not _unit_states.has(unit_id):
		return
	var state: Dictionary = _unit_states[unit_id]
	state["next_timed_poll_time"] = _resolve_next_timed_poll_time(
		state.get("timed_poll_triggers", [])
	)
	_unit_states[unit_id] = state


func _refresh_poll_state_metadata(unit_id: int, state: Dictionary) -> void:
	var poll_triggers_value: Variant = state.get("poll_triggers", [])
	var state_poll_triggers_value: Variant = state.get("state_poll_triggers", [])
	var passive_aura_triggers_value: Variant = state.get("passive_aura_triggers", [])
	var timed_poll_triggers_value: Variant = state.get("timed_poll_triggers", [])
	_sync_unit_membership_array(
		_poll_trigger_unit_ids,
		unit_id,
		_variant_array_has_entries(poll_triggers_value)
	)
	_sync_unit_membership_array(
		_state_poll_trigger_unit_ids,
		unit_id,
		_variant_array_has_entries(state_poll_triggers_value)
	)
	_sync_unit_membership_array(
		_passive_aura_trigger_unit_ids,
		unit_id,
		_variant_array_has_entries(passive_aura_triggers_value)
	)
	_sync_unit_membership_array(
		_timed_poll_trigger_unit_ids,
		unit_id,
		_variant_array_has_entries(timed_poll_triggers_value)
	)
	_refresh_passive_aura_source_index(unit_id, state)


func _refresh_passive_aura_source_index(unit_id: int, state: Dictionary) -> void:
	var passive_aura_triggers_value: Variant = state.get("passive_aura_triggers", [])
	if not _variant_array_has_entries(passive_aura_triggers_value):
		_set_passive_aura_dirty_margin(unit_id, 0)
		_remove_passive_aura_source_from_cell_index(unit_id)
		return

	var source_cell: Vector2i = _read_state_battle_cell(state)
	var dirty_radius_cells: float = maxf(float(state.get("passive_aura_dirty_radius_cells", 0.0)), 0.0)
	var dirty_margin_cells: int = int(ceili(dirty_radius_cells)) + 1 if dirty_radius_cells > 0.0 else 0
	_set_passive_aura_dirty_margin(unit_id, dirty_margin_cells)
	if source_cell.x < 0 or source_cell.y < 0:
		_remove_passive_aura_source_from_cell_index(unit_id)
		return
	_move_passive_aura_source_in_cell_index(unit_id, source_cell)


func _set_passive_aura_dirty_margin(unit_id: int, dirty_margin_cells: int) -> void:
	var previous_margin: int = int(_passive_aura_dirty_margin_by_unit.get(unit_id, 0))
	if dirty_margin_cells <= 0:
		_passive_aura_dirty_margin_by_unit.erase(unit_id)
		if previous_margin == _passive_aura_max_dirty_margin_cells:
			_recalculate_passive_aura_max_dirty_margin_cells()
		return

	_passive_aura_dirty_margin_by_unit[unit_id] = dirty_margin_cells
	if dirty_margin_cells > _passive_aura_max_dirty_margin_cells:
		_passive_aura_max_dirty_margin_cells = dirty_margin_cells
	elif previous_margin == _passive_aura_max_dirty_margin_cells and dirty_margin_cells < previous_margin:
		_recalculate_passive_aura_max_dirty_margin_cells()


func _recalculate_passive_aura_max_dirty_margin_cells() -> void:
	_passive_aura_max_dirty_margin_cells = 0
	for margin_value in _passive_aura_dirty_margin_by_unit.values():
		_passive_aura_max_dirty_margin_cells = max(
			_passive_aura_max_dirty_margin_cells,
			int(margin_value)
		)


func _move_passive_aura_source_in_cell_index(unit_id: int, cell: Vector2i) -> void:
	if cell.x < 0 or cell.y < 0:
		_remove_passive_aura_source_from_cell_index(unit_id)
		return
	var current_cell: Vector2i = _read_indexed_passive_aura_source_cell(unit_id)
	if current_cell == cell:
		return
	_remove_passive_aura_source_from_cell_index(unit_id)
	var cell_key: String = _cell_key(cell)
	var slot: Dictionary = _passive_aura_source_ids_by_cell.get(cell_key, {})
	slot[unit_id] = true
	_passive_aura_source_ids_by_cell[cell_key] = slot
	_passive_aura_source_cell_by_unit[unit_id] = cell


func _remove_passive_aura_source_from_cell_index(unit_id: int) -> void:
	if not _passive_aura_source_cell_by_unit.has(unit_id):
		return
	var current_cell_value: Variant = _passive_aura_source_cell_by_unit[unit_id]
	if current_cell_value is Vector2i:
		var cell_key: String = _cell_key(current_cell_value as Vector2i)
		if _passive_aura_source_ids_by_cell.has(cell_key):
			var slot: Dictionary = _passive_aura_source_ids_by_cell[cell_key]
			slot.erase(unit_id)
			if slot.is_empty():
				_passive_aura_source_ids_by_cell.erase(cell_key)
			else:
				_passive_aura_source_ids_by_cell[cell_key] = slot
	_passive_aura_source_cell_by_unit.erase(unit_id)


func _collect_passive_aura_source_candidates(
	changed_unit: Node,
	from_cell: Vector2i,
	to_cell: Vector2i
) -> Array[int]:
	var out: Array[int] = []
	var seen: Dictionary = {}
	if changed_unit != null and is_instance_valid(changed_unit):
		var changed_unit_id: int = changed_unit.get_instance_id()
		if _passive_aura_trigger_unit_ids.has(changed_unit_id):
			seen[changed_unit_id] = true
			out.append(changed_unit_id)

	if _passive_aura_max_dirty_margin_cells <= 0:
		return out
	_append_passive_aura_candidates_from_cell(from_cell, out, seen)
	if to_cell != from_cell:
		_append_passive_aura_candidates_from_cell(to_cell, out, seen)
	return out


func _append_passive_aura_candidates_from_cell(
	center_cell: Vector2i,
	output: Array[int],
	seen: Dictionary
) -> void:
	if center_cell.x < 0 or center_cell.y < 0:
		return
	for offset in _get_hex_radius_offsets(_passive_aura_max_dirty_margin_cells):
		var scan_cell: Vector2i = center_cell + offset
		var cell_key: String = _cell_key(scan_cell)
		if not _passive_aura_source_ids_by_cell.has(cell_key):
			continue
		var slot: Dictionary = _passive_aura_source_ids_by_cell[cell_key]
		for source_unit_id in slot.keys():
			var unit_id: int = int(source_unit_id)
			if seen.has(unit_id):
				continue
			seen[unit_id] = true
			output.append(unit_id)


func _get_hex_radius_offsets(radius_cells: int) -> Array[Vector2i]:
	if radius_cells <= 0:
		return [Vector2i.ZERO]
	if _hex_radius_offsets_cache.has(radius_cells):
		var cached_value: Variant = _hex_radius_offsets_cache[radius_cells]
		if cached_value is Array:
			return cached_value

	var offsets: Array[Vector2i] = []
	for dq in range(-radius_cells, radius_cells + 1):
		var min_dr: int = maxi(-radius_cells, -dq - radius_cells)
		var max_dr: int = mini(radius_cells, -dq + radius_cells)
		for dr in range(min_dr, max_dr + 1):
			offsets.append(Vector2i(dq, dr))
	_hex_radius_offsets_cache[radius_cells] = offsets
	return offsets


func _sync_unit_membership_array(target_ids: Array[int], unit_id: int, should_exist: bool) -> void:
	if should_exist:
		if not target_ids.has(unit_id):
			target_ids.append(unit_id)
		return
	target_ids.erase(unit_id)


func _variant_array_has_entries(value: Variant) -> bool:
	return value is Array and not (value as Array).is_empty()


func _resolve_next_timed_poll_time(timed_poll_triggers_value: Variant) -> float:
	if not (timed_poll_triggers_value is Array):
		return INF

	var next_due_time: float = INF
	for entry_value in (timed_poll_triggers_value as Array):
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value as Dictionary
		var trigger_name: String = str(entry.get("trigger", "")).strip_edges().to_lower()
		var next_ready_time: float = float(entry.get("next_ready_time", 0.0))
		var max_trigger_count: int = int(entry.get("max_trigger_count", 0))
		if max_trigger_count > 0 and int(entry.get("trigger_count", 0)) >= max_trigger_count:
			continue

		var candidate_time: float = INF
		match trigger_name:
			"periodic_seconds", "periodic":
				var trigger_params: Dictionary = {}
				var trigger_params_value: Variant = entry.get("trigger_params", {})
				if trigger_params_value is Dictionary:
					trigger_params = trigger_params_value as Dictionary
				var skill_data: Dictionary = {}
				var skill_data_value: Variant = entry.get("skill_data", {})
				if skill_data_value is Dictionary:
					skill_data = skill_data_value as Dictionary
				var interval: float = maxf(
					float(trigger_params.get("interval", skill_data.get("interval", 0.0))),
					0.05
				)
				candidate_time = float(entry.get("next_periodic_time", interval))
				if candidate_time <= 0.0:
					candidate_time = interval
			"on_time_elapsed":
				if bool(entry.get("time_elapsed_fired", false)):
					continue
				var trigger_params: Dictionary = {}
				var trigger_params_value: Variant = entry.get("trigger_params", {})
				if trigger_params_value is Dictionary:
					trigger_params = trigger_params_value as Dictionary
				var skill_data: Dictionary = {}
				var skill_data_value: Variant = entry.get("skill_data", {})
				if skill_data_value is Dictionary:
					skill_data = skill_data_value as Dictionary
				candidate_time = maxf(
					float(trigger_params.get("at_seconds", skill_data.get("at_seconds", INF))),
					0.0
				)
			_:
				continue

		candidate_time = maxf(candidate_time, next_ready_time)
		if candidate_time < next_due_time:
			next_due_time = candidate_time
	return next_due_time


func _resolve_passive_aura_dirty_radius_cells(passive_aura_triggers_value: Variant) -> float:
	if not (passive_aura_triggers_value is Array):
		return 0.0

	var max_radius_cells: float = 0.0
	for entry_value in (passive_aura_triggers_value as Array):
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value as Dictionary
		var skill_data_value: Variant = entry.get("skill_data", {})
		if not (skill_data_value is Dictionary):
			continue
		var skill_data: Dictionary = skill_data_value as Dictionary
		var effects_value: Variant = skill_data.get("effects", [])
		if not (effects_value is Array):
			continue
		for effect_value in (effects_value as Array):
			if not (effect_value is Dictionary):
				continue
			var effect: Dictionary = effect_value as Dictionary
			max_radius_cells = maxf(
				max_radius_cells,
				float(effect.get("radius", effect.get("range", 0.0)))
			)
		max_radius_cells = maxf(max_radius_cells, float(skill_data.get("range", 0.0)))
	return max_radius_cells


func _resolve_initial_battle_cell(unit: Node) -> Vector2i:
	if unit == null or not is_instance_valid(unit):
		return Vector2i(-1, -1)
	var deployed_cell_value: Variant = unit.get("deployed_cell")
	if deployed_cell_value is Vector2i:
		return deployed_cell_value as Vector2i
	return Vector2i(-1, -1)


func _mark_passive_aura_dirty_by_id(unit_id: int) -> void:
	if not _unit_states.has(unit_id):
		return
	var state: Dictionary = _unit_states[unit_id] as Dictionary
	_mark_passive_aura_dirty_state(state)
	_unit_states[unit_id] = state


func _mark_passive_aura_dirty_state(state: Dictionary) -> void:
	state["passive_aura_dirty"] = true


func _resolve_passive_aura_dirty_poll_interval(state: Dictionary) -> float:
	var passive_aura_triggers_value: Variant = state.get("passive_aura_triggers", [])
	var interval: float = 0.25
	if passive_aura_triggers_value is Array:
		for entry_value in (passive_aura_triggers_value as Array):
			if not (entry_value is Dictionary):
				continue
			var entry: Dictionary = entry_value as Dictionary
			var cooldown: float = maxf(float(entry.get("cooldown", 0.0)), 0.0)
			if cooldown <= 0.0:
				continue
			interval = minf(interval, cooldown)
	return clampf(interval, 0.18, 0.35)


func _resolve_passive_aura_repair_interval(_state: Dictionary) -> float:
	var source_count: int = _passive_aura_trigger_unit_ids.size()
	var base_interval: float = 0.5
	var bucket_count: int = 1
	# dirty 更新仍由 cell_change/death/spawn 事件即时驱动；
	# 这里仅放慢“无脏标记时的兜底修复”，用于高密度战斗下降低全量 aura 自检频率。
	if source_count >= 160:
		base_interval = 0.75
		bucket_count = 6
	elif source_count >= 80:
		base_interval = 0.65
		bucket_count = 5
	elif source_count >= 32:
		base_interval = 0.55
		bucket_count = 3
	return base_interval * float(bucket_count)


func _read_state_battle_cell(state: Dictionary) -> Vector2i:
	var cell_value: Variant = state.get("passive_aura_battle_cell", Vector2i(-1, -1))
	if cell_value is Vector2i:
		return cell_value as Vector2i
	return Vector2i(-1, -1)


func _read_indexed_passive_aura_source_cell(unit_id: int) -> Vector2i:
	if not _passive_aura_source_cell_by_unit.has(unit_id):
		return Vector2i(-1, -1)
	var cell_value: Variant = _passive_aura_source_cell_by_unit[unit_id]
	if cell_value is Vector2i:
		return cell_value as Vector2i
	return Vector2i(-1, -1)


func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	var dq: int = a.x - b.x
	var dr: int = a.y - b.y
	var ds: int = (-a.x - a.y) - (-b.x - b.y)
	return int((absi(dq) + absi(dr) + absi(ds)) / 2)


func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


# `skill_data` 和被动效果条目默认只读，因此这里统一做浅拷贝，避免无谓复制。
# 这里复制的是字典壳，不深拷贝内部嵌套结构，避免对大表做无意义复制。
# 被动效果后续只会读字段，不会在 UnitStateService 内部原地改 effect 内容。
func _collect_passive_effects(output: Array[Dictionary], effects_value: Variant) -> void:
	if not (effects_value is Array):
		return
	for effect_value in (effects_value as Array):
		if effect_value is Dictionary:
			output.append((effect_value as Dictionary).duplicate(false))


# baseline 必须从单位基础属性重新构建，不能在旧 runtime_stats 上累加。
# `star_level` 仍由原有 UnitData 构建脚本决定，不在 UnitAugment 里重复实现成长逻辑。
# 这一步的产物会作为所有被动与装备修正的起点。
func _build_unit_baseline_stats(unit: Node) -> Dictionary:
	var base_stats: Dictionary = (_node_prop(unit, "base_stats", {}) as Dictionary).duplicate(true)
	var star_level: int = int(_node_prop(unit, "star_level", 1))
	return _unit_data_script.build_runtime_stats(base_stats, star_level)


# 技能列表既来自功法条目，也来自 trait 和装备 trigger，因此这里统一做结构提取。
# 提取结果只保留技能字典，不在这里附加 owner_id 或触发状态。
# owner_id 的绑定会在后面的 `_build_trigger_entry` 阶段再补上。
func _extract_skill_entries_from_gongfa(gongfa_data: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var skills_value: Variant = gongfa_data.get("skills", [])
	if skills_value is Array:
		for skill_value in (skills_value as Array):
			if skill_value is Dictionary:
				output.append((skill_value as Dictionary).duplicate(false))
	return output


# trigger entry 是 battle runtime 的稳定数据结构，后续轮询和事件触发都依赖它。
# `owner_id` 可以是功法 id、装备 id，也可以是 trait 级虚拟 owner id。
# 这里统一做 trigger 名兼容归一，避免执行层再关心旧别名。
func _build_trigger_entry(owner_id: String, skill_data: Dictionary) -> Dictionary:
	var trigger_params: Dictionary = {}
	var trigger_params_value: Variant = skill_data.get("trigger_params", {})
	if trigger_params_value is Dictionary:
		trigger_params = (trigger_params_value as Dictionary).duplicate(false)
	var trigger_name: String = str(skill_data.get("trigger", skill_data.get("type", ""))).strip_edges().to_lower()
	if trigger_name == "on_buff_expire":
		trigger_name = "on_buff_expired"
	if trigger_name == "periodic":
		trigger_name = "periodic_seconds"
	var periodic_interval: float = maxf(float(trigger_params.get("interval", skill_data.get("interval", 0.0))), 0.0)

	var entry: Dictionary = {
		"gongfa_id": owner_id,
		"entry_uid": _next_trigger_entry_uid,
		"trigger": trigger_name,
		"trigger_params": trigger_params,
		"chance": clampf(float(skill_data.get("chance", 1.0)), 0.0, 1.0),
		"mp_cost": maxf(float(skill_data.get("mp_cost", 0.0)), 0.0),
		"cooldown": maxf(float(skill_data.get("cooldown", 0.0)), 0.0),
		"next_ready_time": 0.0,
		"trigger_count": 0,
		"max_trigger_count": maxi(int(skill_data.get("max_trigger_count", 0)), 0),
		"last_hp_below_state": false,
		"next_periodic_time": periodic_interval,
		"time_elapsed_fired": false,
		"skill_data": skill_data.duplicate(false)
	}
	_next_trigger_entry_uid += 1
	return entry


# 条目级功法槽仍保留原语义，因此这里继续按四类功法槽读取。
# 返回值会去重，避免同一条目因为脏数据重复挂到运行时列表。
# 解析顺序固定为四大槽顺序，保证 UI 和运行时看到的列表顺序一致。
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


# 装备槽按 max_equip_count 截断，确保运行时生效数和详情展示一致。
# 这里会按槽位排序稳定读取，避免 `slot_10` 排到 `slot_2` 前面。
# 返回的是“真正生效”的装备列表，而不是所有已填槽位的原始列表。
func _resolve_equipped_equip_ids(unit: Node) -> Array[String]:
	var ids: Array[String] = []
	var configured_max: int = int(_node_prop(unit, "max_equip_count", 0))
	var slots: Dictionary = _normalize_equip_slots_dict(_node_prop(unit, "equip_slots", {}), configured_max)
	var max_count: int = _resolve_unit_max_equip_count(unit, slots)
	if max_count <= 0:
		return ids
	for slot in _get_sorted_equip_slot_keys(slots):
		var equip_id: String = str(slots.get(slot, "")).strip_edges()
		if equip_id.is_empty():
			continue
		if ids.has(equip_id):
			continue
		ids.append(equip_id)
		if ids.size() >= max_count:
			break
	return ids


func _build_tag_linkage_provider_entries(
	unit: Node,
	unit_traits: Array[Dictionary],
	equipped_ids: Array[String],
	equipped_equip_ids: Array[String]
) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if unit == null or not is_instance_valid(unit):
		return entries

	var unit_iid: int = unit.get_instance_id()
	var unit_tags: Array[String] = _normalize_tag_array(_node_prop(unit, "tags", []))
	if not unit_tags.is_empty():
		entries.append({
			"key": "unit:%d" % unit_iid,
			"source_type": "unit",
			"tags": unit_tags,
			"tag_mask": _build_tag_linkage_mask(unit_tags)
		})

	for trait_idx in range(unit_traits.size()):
		var trait_data: Dictionary = unit_traits[trait_idx]
		var trait_tags: Array[String] = _normalize_tag_array(trait_data.get("tags", []))
		if trait_tags.is_empty():
			continue
		var trait_id: String = str(trait_data.get("id", "trait_%d" % trait_idx)).strip_edges()
		if trait_id.is_empty():
			trait_id = "trait_%d" % trait_idx
		entries.append({
			"key": "trait:%d:%s:%d" % [unit_iid, trait_id, trait_idx],
			"source_type": "trait",
			"tags": trait_tags,
			"tag_mask": _build_tag_linkage_mask(trait_tags)
		})

	for gongfa_id in equipped_ids:
		var gongfa_tags: Array[String] = get_gongfa_tags(gongfa_id)
		if gongfa_tags.is_empty():
			continue
		entries.append({
			"key": "gongfa:%d:%s" % [unit_iid, gongfa_id],
			"source_type": "gongfa",
			"tags": gongfa_tags,
			"tag_mask": _build_tag_linkage_mask(gongfa_tags)
		})

	for equip_id in equipped_equip_ids:
		var equip_tags: Array[String] = get_equipment_tags(equip_id)
		if equip_tags.is_empty():
			continue
		entries.append({
			"key": "equipment:%d:%s" % [unit_iid, equip_id],
			"source_type": "equipment",
			"tags": equip_tags,
			"tag_mask": _build_tag_linkage_mask(equip_tags)
		})
	return entries


func _build_tag_linkage_mask(tags: Array[String]) -> PackedInt64Array:
	var mask: PackedInt64Array = PackedInt64Array()
	if _tag_linkage_mask_word_count <= 0:
		return mask
	mask.resize(_tag_linkage_mask_word_count)
	for idx in range(_tag_linkage_mask_word_count):
		mask[idx] = 0
	for tag in tags:
		if not _tag_linkage_tag_to_index.has(tag):
			continue
		var index: int = int(_tag_linkage_tag_to_index[tag])
		if index < 0:
			continue
		var word: int = index >> 6
		var bit: int = index & 63
		if word < 0 or word >= mask.size():
			continue
		mask[word] = int(mask[word]) | (1 << bit)
	return mask


# runtime stats 不能出现负值，`hp` 和 `rng` 额外要求正数。
# 这是最后一道安全钳位，防止配表或被动叠加把核心属性压成负数。
# 目前只对 `hp` 和 `rng` 额外要求最小 1，其余属性允许为 0。
func _clamp_runtime_stats(runtime_stats: Dictionary) -> void:
	var min_positive_keys: Array[String] = ["hp", "rng"]
	for key in runtime_stats.keys():
		runtime_stats[key] = maxf(float(runtime_stats[key]), 0.0)
	for key2 in min_positive_keys:
		if runtime_stats.has(key2):
			runtime_stats[key2] = maxf(float(runtime_stats[key2]), 1.0)


# 功法槽位必须完整补齐，避免 UI 和 trigger pipeline 读取到缺键字典。
# 不管原始字典是否缺键，返回结果都会带齐四大功法槽。
# 空槽统一规范成空字符串，避免 null 和空串混用。
func _normalize_slots_dict(raw: Variant) -> Dictionary:
	var slots: Dictionary = {
		"neigong": "",
		"waigong": "",
		"qinggong": "",
		"zhenfa": ""
	}
	if raw is Dictionary:
		for slot in ALLOWED_SLOTS:
			slots[slot] = str((raw as Dictionary).get(slot, "")).strip_edges()
	return slots


# 装备槽位允许按配置动态扩展，但未配置时仍回落到默认两槽。
# `desired_count` 通常来自单位的 max_equip_count，用来补齐至少需要多少个槽。
# 这里既负责清洗旧槽位字典，也负责为新单位生成默认槽位结构。
func _normalize_equip_slots_dict(raw: Variant, desired_count: int = 0) -> Dictionary:
	var slots: Dictionary = {}
	if raw is Dictionary:
		var raw_dict: Dictionary = raw as Dictionary
		for slot in _get_sorted_equip_slot_keys(raw_dict):
			slots[slot] = str(raw_dict.get(slot, "")).strip_edges()
	if slots.is_empty():
		for slot_default in DEFAULT_EQUIP_SLOTS:
			slots[slot_default] = ""
	var target_count: int = maxi(desired_count, 0)
	if target_count > slots.size():
		for idx in range(1, target_count + 1):
			if slots.size() >= target_count:
				break
			var key: String = "slot_%d" % idx
			if not slots.has(key):
				slots[key] = ""
	return slots


# 功法槽位计数只统计非空条目。
# 这个 helper 主要给装配校验和后续调试统计使用。
# 计数口径不关心条目是否有效，只看槽位里是否有非空字符串。
func _count_filled_slots(slots: Dictionary) -> int:
	var count: int = 0
	for slot in ALLOWED_SLOTS:
		if str(slots.get(slot, "")).strip_edges() != "":
			count += 1
	return count


# tags 一律归一化为小写去重数组，供 resolver 和 UI 共用。
# 这里服务的是 registry tags 和单位/trait tags 的统一口径。
# 去重逻辑用字典实现，保证原顺序上的首个命中会被保留。
func _normalize_tag_array(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if raw is Array:
		for item in (raw as Array):
			var text: String = str(item).strip_edges().to_lower()
			if text.is_empty():
				continue
			if seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out


# 字符串数组归一化主要服务 runtime_equipped_* 字段读取。
# 和 tag 归一化不同，这里不做 to_lower，因为条目 id 本身大小写有语义。
# 仍然会去空串和重复值，保证运行时列表稳定。
func _normalize_string_array(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if raw is Array:
		for item in (raw as Array):
			var text: String = str(item).strip_edges()
			if text.is_empty():
				continue
			if seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out


# 装备槽位计数只统计已填充槽，不关心条目品质和来源。
# 这个数字只用于生效数量限制，不等于“装备定义合法且可生效”的数量。
# 后续真正的条目合法性还是要回到 registry 查询。
func _count_filled_equip_slots(slots: Dictionary) -> int:
	var count: int = 0
	for slot in slots.keys():
		if str(slots.get(slot, "")).strip_edges() != "":
			count += 1
	return count


# 最大装备数优先读单位配置，缺失时回退到当前槽位数量。
# 默认至少保留 1，避免出现“单位完全不能装备任何东西”的 0 值口径。
# 这一步只做数量归一化，不负责新增或删除槽位键。
func _resolve_unit_max_equip_count(unit: Node, slots: Dictionary) -> int:
	var configured: int = int(_node_prop(unit, "max_equip_count", 0))
	if configured <= 0:
		configured = slots.size()
	if configured <= 0:
		configured = DEFAULT_EQUIP_SLOTS.size()
	return maxi(configured, 1)


# 槽位排序必须稳定，避免 UI 与运行时对“前几个槽位”的理解不一致。
# 返回结果同时服务 equip 列表截断和界面展示顺序。
# 如果字典本身为空，就回到默认两槽顺序，保证最小可用结构存在。
func _get_sorted_equip_slot_keys(slots_value: Variant) -> Array[String]:
	var keys: Array[String] = []
	if slots_value is Dictionary:
		for raw_key in (slots_value as Dictionary).keys():
			var key: String = str(raw_key).strip_edges()
			if key.is_empty():
				continue
			keys.append(key)
	if keys.is_empty():
		return DEFAULT_EQUIP_SLOTS.duplicate()
	keys.sort_custom(Callable(self, "_compare_equip_slot_key"))
	return keys


# `slot_2` 必须排在 `slot_10` 前面，因此这里不能直接按字符串排序。
# 先按数值序比较，只有数值相同或都不是标准槽位时才退回字符串比较。
# 这样既兼容标准命名，也兼容未来扩展的特殊槽位键。
func _compare_equip_slot_key(a: String, b: String) -> bool:
	var a_index: int = _extract_slot_index(a)
	var b_index: int = _extract_slot_index(b)
	if a_index >= 0 and b_index >= 0:
		if a_index == b_index:
			return a < b
		return a_index < b_index
	if a_index >= 0:
		return true
	if b_index >= 0:
		return false
	return a < b


# 只有 `slot_<number>` 这种标准命名才会被解析成数值序。
# 返回 -1 表示不是标准装备槽位，排序时会被放到数值槽之后。
# 这个 helper 只做语法解析，不检查槽位是否真的存在于当前单位上。
func _extract_slot_index(slot_key: String) -> int:
	var key: String = slot_key.strip_edges().to_lower()
	if not key.begins_with("slot_"):
		return -1
	var tail: String = key.substr(5, key.length() - 5)
	if tail.is_empty() or not tail.is_valid_int():
		return -1
	return int(tail)


# 统一做带 fallback 的节点属性读取，避免每个调用点重复判空。
# `fallback` 用来兼容节点缺属性、值为 null 或节点本身失效三种场景。
# 这里是 UnitStateService 里唯一允许的宽松属性读取入口。
func _node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if node == null or not is_instance_valid(node):
		return fallback
	var value: Variant = node.get(key)
	if value == null:
		return fallback
	return value


# 轮询触发器名单固定在这里编译，避免运行时每次再遍历全部 trigger 做字符串判断。
func _is_poll_trigger_name(trigger_name: String) -> bool:
	return trigger_name == "auto_mp_full" \
		or trigger_name == "manual" \
		or trigger_name == "auto_hp_below" \
		or trigger_name == "passive_aura" \
		or trigger_name == "on_hp_below" \
		or trigger_name == "on_time_elapsed" \
		or trigger_name == "periodic_seconds" \
		or trigger_name == "periodic"


func _is_timed_poll_trigger_name(trigger_name: String) -> bool:
	return trigger_name == "on_time_elapsed" \
		or trigger_name == "periodic_seconds" \
		or trigger_name == "periodic"
