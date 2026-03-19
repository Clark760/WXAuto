extends RefCounted
class_name GongfaRegistry

# ===========================
# 功法数据池（M3）
# ===========================
# 职责：
# 1. 从 DataManager 读取 gongfa/linkages/buffs 三类记录。
# 2. 将记录按 id 建立索引，供运行时高频查询。
# 3. 提供“安全副本”接口，避免上层误改内部缓存。

var _gongfa_map: Dictionary = {}   # gongfa_id -> Dictionary
var _linkage_map: Dictionary = {}  # linkage_id -> Dictionary
var _buff_map: Dictionary = {}     # buff_id -> Dictionary


func clear() -> void:
	_gongfa_map.clear()
	_linkage_map.clear()
	_buff_map.clear()


func reload_from_data_manager(data_manager: Node) -> Dictionary:
	clear()
	if data_manager == null:
		return {
			"gongfa_count": 0,
			"linkage_count": 0,
			"buff_count": 0
		}

	_load_category_into_map(data_manager, "gongfa", _gongfa_map)
	_load_category_into_map(data_manager, "linkages", _linkage_map)
	_load_category_into_map(data_manager, "buffs", _buff_map)

	return {
		"gongfa_count": _gongfa_map.size(),
		"linkage_count": _linkage_map.size(),
		"buff_count": _buff_map.size()
	}


func has_gongfa(gongfa_id: String) -> bool:
	return _gongfa_map.has(gongfa_id)


func has_linkage(linkage_id: String) -> bool:
	return _linkage_map.has(linkage_id)


func has_buff(buff_id: String) -> bool:
	return _buff_map.has(buff_id)


func get_gongfa(gongfa_id: String) -> Dictionary:
	if not _gongfa_map.has(gongfa_id):
		return {}
	return (_gongfa_map[gongfa_id] as Dictionary).duplicate(true)


func get_linkage(linkage_id: String) -> Dictionary:
	if not _linkage_map.has(linkage_id):
		return {}
	return (_linkage_map[linkage_id] as Dictionary).duplicate(true)


func get_buff(buff_id: String) -> Dictionary:
	if not _buff_map.has(buff_id):
		return {}
	return (_buff_map[buff_id] as Dictionary).duplicate(true)


func get_all_gongfa() -> Array[Dictionary]:
	return _get_all_from_map(_gongfa_map)


func get_all_linkages() -> Array[Dictionary]:
	return _get_all_from_map(_linkage_map)


func get_all_buffs() -> Array[Dictionary]:
	return _get_all_from_map(_buff_map)


func get_buff_map_snapshot() -> Dictionary:
	return _buff_map.duplicate(true)


func _load_category_into_map(data_manager: Node, category: String, output_map: Dictionary) -> void:
	var raw_records: Variant = data_manager.call("get_all_records", category)
	if not (raw_records is Array):
		return

	for record_value in raw_records:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = (record_value as Dictionary).duplicate(true)
		var record_id: String = str(record.get("id", "")).strip_edges()
		if record_id.is_empty():
			continue
		output_map[record_id] = record


func _get_all_from_map(source_map: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for item in source_map.values():
		if item is Dictionary:
			output.append((item as Dictionary).duplicate(true))
	return output
