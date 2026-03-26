extends RefCounted
class_name UnitAugmentRegistry

# 这个服务只负责“条目数据快照”，不参与战斗态逻辑。
# `gongfa` 仍然表示条目分类，因此这里保留原有分类名。

var _gongfa_map: Dictionary = {}
var _buff_map: Dictionary = {}
var _equipment_map: Dictionary = {}


# 清空运行时缓存，避免全量重载时残留旧记录。
func clear() -> void:
	_gongfa_map.clear()
	_buff_map.clear()
	_equipment_map.clear()


# 从 DataManager 读取三类条目，并返回用于 UI/日志的简短统计摘要。
func reload_from_data_manager(data_manager: Node) -> Dictionary:
	clear()
	if data_manager == null:
		return {
			"gongfa_count": 0,
			"buff_count": 0,
			"equipment_count": 0
		}

	_load_category_into_map(data_manager, "gongfa", _gongfa_map)
	_load_category_into_map(data_manager, "buffs", _buff_map)
	_load_category_into_map(data_manager, "equipment", _equipment_map)

	return {
		"gongfa_count": _gongfa_map.size(),
		"buff_count": _buff_map.size(),
		"equipment_count": _equipment_map.size()
	}


# 条目查询必须返回副本，避免上层误改内部缓存。
func has_gongfa(gongfa_id: String) -> bool:
	return _gongfa_map.has(gongfa_id)


# Buff 查询会被战斗态高频调用，因此这里直接走哈希映射。
func has_buff(buff_id: String) -> bool:
	return _buff_map.has(buff_id)


# 装备条目与功法条目共享同一套“安全副本”读取约束。
func has_equipment(equip_id: String) -> bool:
	return _equipment_map.has(equip_id)


# `gongfa_id` 是条目语义，本轮不改名。
func get_gongfa(gongfa_id: String) -> Dictionary:
	if not _gongfa_map.has(gongfa_id):
		return {}
	return (_gongfa_map[gongfa_id] as Dictionary).duplicate(true)


# Buff 定义会被 BuffManager 持久缓存，所以这里同样返回深拷贝。
func get_buff(buff_id: String) -> Dictionary:
	if not _buff_map.has(buff_id):
		return {}
	return (_buff_map[buff_id] as Dictionary).duplicate(true)


# 装备数据会被 UI 和运行时同时读取，必须保持“读者不可写”。
func get_equipment(equip_id: String) -> Dictionary:
	if not _equipment_map.has(equip_id):
		return {}
	return (_equipment_map[equip_id] as Dictionary).duplicate(true)


# 列表接口主要服务商店与详情面板，返回值允许调用方自由排序和过滤。
func get_all_gongfa() -> Array[Dictionary]:
	return _get_all_from_map(_gongfa_map)


# Buff 列表主要服务运行时定义同步。
func get_all_buffs() -> Array[Dictionary]:
	return _get_all_from_map(_buff_map)


# 装备列表主要服务商店池与详情展示。
func get_all_equipment() -> Array[Dictionary]:
	return _get_all_from_map(_equipment_map)


# BuffManager 需要一份完整定义快照，避免后续 DataManager 变动影响当前战斗。
func get_buff_map_snapshot() -> Dictionary:
	return _buff_map.duplicate(true)


# `category` 只接受 DataManager 中现有的三类定义名，避免静默读错分类。
func _load_category_into_map(data_manager: Node, category: String, output_map: Dictionary) -> void:
	if not data_manager.has_method("get_all_records"):
		return
	var raw_records: Variant = data_manager.get_all_records(category)
	if not (raw_records is Array):
		return

	for record_value in raw_records:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = (record_value as Dictionary).duplicate(true)
		var record_id: String = str(record.get("id", "")).strip_edges()
		if record_id.is_empty():
			continue
		if category == "gongfa" or category == "equipment":
			record["shop_visible"] = bool(record.get("shop_visible", true))
		output_map[record_id] = record


# 这里统一把 Dictionary 映射转换为可自由消费的数组副本。
func _get_all_from_map(source_map: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for item in source_map.values():
		if item is Dictionary:
			output.append((item as Dictionary).duplicate(true))
	return output
