extends RefCounted
class_name UnitAugmentUnitStateService

const ALLOWED_SLOTS: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa"]
const DEFAULT_EQUIP_SLOTS: Array[String] = ["slot_1", "slot_2"]

var _registry: Variant
var _effect_engine: Variant
var _buff_manager: Variant
var _tag_linkage_scheduler: Variant
var _unit_data_script: Script

var _battle_units: Array[Node] = []
var _unit_lookup: Dictionary = {}
var _unit_states: Dictionary = {}
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

# 运行时状态查询统一走 iid，避免外层重复拼接 get_instance_id 逻辑。
# `unit` 为空或失效时直接回空字典，且返回值仍是副本，避免外层误写内部状态。
func get_state_for_unit(unit: Node) -> Dictionary:
	if unit == null or not is_instance_valid(unit):
		return {}
	return get_state_by_id(unit.get_instance_id())

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
		if _is_poll_trigger_name(str(entry.get("trigger", ""))):
			poll_triggers.append(entry)

	# 这里写入的是 UnitAugment 自己维护的标准 state 结构，供后续轮询和重算复用。
	_unit_states[iid] = {
		"unit": unit,
		"baseline_stats": baseline_stats,
		"equipped_gongfa_ids": equipped_ids,
		"equipped_equip_ids": equipped_equip_ids,
		"unit_traits": unit_traits,
		"passive_effects": passive_effects,
		"equipment_effects": equipment_effects,
		"triggers": triggers,
		"poll_triggers": poll_triggers
	}

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
	_unit_states[iid] = state
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

	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat != null:
		if combat.has_method("refresh_runtime_stats"):
			combat.refresh_runtime_stats(runtime_stats, preserve_health_ratio)
		else:
			combat.reset_from_stats(runtime_stats)
		if combat.has_method("set_external_modifiers"):
			combat.set_external_modifiers(modifiers)

	var movement: Node = unit.get_node_or_null("Components/UnitMovement")
	if movement != null:
		if movement.has_method("refresh_runtime_stats"):
			movement.refresh_runtime_stats(runtime_stats)
		else:
			movement.reset_from_stats(runtime_stats)


# TriggerRuntime 会频繁读取生命和内力，这里统一提供安全的 combat 值读取。
# `key` 对应 UnitCombat 上的公开字段名，例如 current_hp、max_hp、current_mp。
# 缺少 Combat 组件时统一回 0，避免条件服务再到处判空。
func get_combat_value(unit: Node, key: String) -> float:
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0
	return float(combat.get(key))


# 活着的定义继续以 UnitCombat.is_alive 为准，避免和场景显示状态混淆。
# 这里不参考节点是否在树上或是否隐藏，统一以战斗组件状态为准。
# 这样 trigger 条件、选敌和 tag_linkage provider 的口径可以保持一致。
func is_unit_alive(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return false
	return bool(combat.get("is_alive"))


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
