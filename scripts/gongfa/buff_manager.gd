extends RefCounted
class_name GongfaBuffManager

# ===========================
# Buff / Debuff 管理器
# ===========================
# 目标：
# 1. 维护单位身上的 Buff 生命周期（叠加、刷新、过期）。
# 2. 提供“当前生效效果列表”给 GongfaManager 参与属性重算。
# 3. 处理 tick_effects 的定时触发请求（真正执行由 EffectEngine 完成）。

var _buff_defs: Dictionary = {}      # buff_id -> buff_data
var _active_by_unit: Dictionary = {} # unit_instance_id -> Array[Dictionary]


func clear_all() -> void:
	_active_by_unit.clear()


func set_buff_definitions(buff_defs: Dictionary) -> void:
	_buff_defs = buff_defs.duplicate(true)


func apply_buff(target: Node, buff_id: String, duration: float, source: Node = null) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not _buff_defs.has(buff_id):
		push_warning("BuffManager: 未找到 Buff 定义 id=%s" % buff_id)
		return false

	var iid: int = target.get_instance_id()
	var unit_entries: Array = _active_by_unit.get(iid, [])
	var buff_data: Dictionary = (_buff_defs[buff_id] as Dictionary).duplicate(true)

	var stackable: bool = bool(buff_data.get("stackable", false))
	var max_stacks: int = maxi(int(buff_data.get("max_stacks", 1)), 1)
	var final_duration: float = duration
	if final_duration <= 0.0:
		final_duration = float(buff_data.get("default_duration", 3.0))
	# duration < 0 代表永久效果。
	if duration < 0.0:
		final_duration = -1.0

	for i in range(unit_entries.size()):
		var entry: Dictionary = unit_entries[i]
		if str(entry.get("buff_id", "")) != buff_id:
			continue

		if stackable:
			entry["stacks"] = mini(int(entry.get("stacks", 1)) + 1, max_stacks)
		else:
			entry["stacks"] = 1

		entry["remaining"] = final_duration
		entry["tick_accum"] = 0.0
		entry["source_id"] = source.get_instance_id() if source != null and is_instance_valid(source) else -1
		unit_entries[i] = entry
		_active_by_unit[iid] = unit_entries
		return true

	var new_entry: Dictionary = {
		"buff_id": buff_id,
		"data": buff_data,
		"stacks": 1,
		"remaining": final_duration,
		"tick_accum": 0.0,
		"source_id": source.get_instance_id() if source != null and is_instance_valid(source) else -1
	}
	unit_entries.append(new_entry)
	_active_by_unit[iid] = unit_entries
	return true


func remove_all_for_unit(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	_active_by_unit.erase(target.get_instance_id())


func collect_passive_effects_for_unit(target: Node) -> Array[Dictionary]:
	var effects: Array[Dictionary] = []
	if target == null or not is_instance_valid(target):
		return effects

	var iid: int = target.get_instance_id()
	var entries: Array = _active_by_unit.get(iid, [])
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_data: Dictionary = entry.get("data", {})
		var stacks: int = maxi(int(entry.get("stacks", 1)), 1)
		var raw_effects: Variant = buff_data.get("effects", [])
		if not (raw_effects is Array):
			continue
		for effect_value in raw_effects:
			if not (effect_value is Dictionary):
				continue
			var scaled: Dictionary = (effect_value as Dictionary).duplicate(true)
			# 简化约定：有 value 字段的效果按层数线性放大。
			if scaled.has("value"):
				scaled["value"] = float(scaled.get("value", 0.0)) * float(stacks)
			effects.append(scaled)

	return effects


func get_active_buff_ids_for_unit(target: Node) -> Array[String]:
	var ids: Array[String] = []
	if target == null or not is_instance_valid(target):
		return ids
	var iid: int = target.get_instance_id()
	var entries: Array = _active_by_unit.get(iid, [])
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		ids.append(str(entry.get("buff_id", "")))
	return ids


func tick(delta: float) -> Dictionary:
	# 返回值包含两类信息：
	# 1) tick_requests：到点需要触发的周期效果。
	# 2) changed_unit_ids：Buff 状态变化，需要重算属性的单位。
	var changed_units: Dictionary = {}
	var tick_requests: Array[Dictionary] = []

	for key in _active_by_unit.keys():
		var iid: int = int(key)
		var entries: Array = _active_by_unit.get(iid, [])
		var next_entries: Array = []

		for entry_value in entries:
			if not (entry_value is Dictionary):
				continue
			var entry: Dictionary = (entry_value as Dictionary).duplicate(true)
			var buff_data: Dictionary = entry.get("data", {})

			var previous_remaining: float = float(entry.get("remaining", 0.0))
			var remaining: float = previous_remaining
			if remaining >= 0.0:
				remaining -= delta
				entry["remaining"] = remaining

			var tick_interval: float = float(buff_data.get("tick_interval", 0.0))
			var tick_effects: Variant = buff_data.get("tick_effects", [])
			if tick_interval > 0.0 and tick_effects is Array and not (tick_effects as Array).is_empty():
				var tick_accum: float = float(entry.get("tick_accum", 0.0)) + delta
				while tick_accum >= tick_interval:
					tick_accum -= tick_interval
					tick_requests.append({
						"source_id": int(entry.get("source_id", -1)),
						"target_id": iid,
						"buff_id": str(entry.get("buff_id", "")).strip_edges(),
						"effects": (tick_effects as Array).duplicate(true)
					})
				entry["tick_accum"] = tick_accum

			var expired: bool = false
			if previous_remaining >= 0.0 and remaining <= 0.0:
				expired = true

			if expired:
				changed_units[iid] = true
				continue

			next_entries.append(entry)
		_active_by_unit[iid] = next_entries
		if next_entries.size() != entries.size():
			changed_units[iid] = true
		if next_entries.is_empty():
			_active_by_unit.erase(iid)

	var changed_unit_ids: Array[int] = []
	for changed_id in changed_units.keys():
		changed_unit_ids.append(int(changed_id))

	return {
		"changed_unit_ids": changed_unit_ids,
		"tick_requests": tick_requests
	}
