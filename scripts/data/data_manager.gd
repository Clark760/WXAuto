extends Node

# ===========================
# 数据总管理器（AutoLoad）
# ===========================
# 核心职责：
# 1. 按目录扫描 JSON 文件。
# 2. 将 JSON 统一标准化为“记录数组”（每条记录必须有 id）。
# 3. 以 category + id 作为主键进行合并，后加载数据覆盖先加载数据。
# 4. 为上层系统提供统一查询接口与加载统计摘要。

const CATEGORY_ORDER: Array[String] = [
	"units",
	"gongfa",
	"equipment",
	"linkages",
	"levels",
	"vfx"
]

const CATEGORY_PATHS: Dictionary = {
	"units": "res://data/units",
	"gongfa": "res://data/gongfa",
	"equipment": "res://data/equipment",
	"linkages": "res://data/linkages",
	"levels": "res://data/levels",
	"vfx": "res://data/vfx"
}

# _database 结构：
# {
#   "units": {
#     "unit_id_xxx": { ...record... },
#   },
#   ...
# }
var _database: Dictionary = {}

# 记录每条数据最终来源，用于调试覆盖顺序。
# key 形式："{category}:{id}" -> "base:xxx" / "mod:xxx"
var _source_index: Dictionary = {}

# 记录本次加载扫描过的 json 文件路径，便于定位问题。
var _loaded_files: Array[String] = []


func _ready() -> void:
	reset_database()


func get_supported_categories() -> Array[String]:
	var output: Array[String] = []
	for category in CATEGORY_ORDER:
		output.append(category)
	return output


func reset_database() -> void:
	_database.clear()
	_source_index.clear()
	_loaded_files.clear()

	for category in CATEGORY_ORDER:
		_database[category] = {}


func load_base_data() -> Dictionary:
	reset_database()

	var files_loaded: int = 0
	var records_loaded: int = 0
	var added_total: int = 0
	var replaced_total: int = 0

	for category in CATEGORY_ORDER:
		var dir_path: String = str(CATEGORY_PATHS[category])
		var result: Dictionary = load_category_from_dir(category, dir_path, "base")

		files_loaded += int(result.get("files", 0))
		records_loaded += int(result.get("records", 0))
		added_total += int(result.get("added", 0))
		replaced_total += int(result.get("replaced", 0))

	var summary: Dictionary = get_summary()
	summary["mode"] = "base"
	summary["files_loaded"] = files_loaded
	summary["records_loaded"] = records_loaded
	summary["added"] = added_total
	summary["replaced"] = replaced_total

	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_data_reloaded", true, summary)
	return summary


func load_category_from_dir(category: String, dir_path: String, source_tag: String) -> Dictionary:
	if not _database.has(category):
		push_warning("DataManager: 不支持的 category=%s" % category)
		return {"files": 0, "records": 0, "added": 0, "replaced": 0}

	var read_result: Dictionary = _read_records_from_dir(dir_path)
	var records: Array = read_result.get("records", [])
	var files: int = int(read_result.get("files", 0))

	var merge_result: Dictionary = _merge_records(category, records, source_tag)
	merge_result["files"] = files
	merge_result["records"] = records.size()
	return merge_result


func get_record(category: String, record_id: String) -> Dictionary:
	var category_map: Dictionary = _database.get(category, {})
	if not category_map.has(record_id):
		return {}
	return (category_map[record_id] as Dictionary).duplicate(true)


func get_all_records(category: String) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var category_map: Dictionary = _database.get(category, {})
	for record in category_map.values():
		if record is Dictionary:
			output.append((record as Dictionary).duplicate(true))
	return output


func get_category_count(category: String) -> int:
	var category_map: Dictionary = _database.get(category, {})
	return category_map.size()


func get_summary() -> Dictionary:
	var category_counts: Dictionary = {}
	var total_records: int = 0
	for category in CATEGORY_ORDER:
		var count: int = get_category_count(category)
		category_counts[category] = count
		total_records += count

	return {
		"categories": category_counts,
		"total_records": total_records,
		"total_files": _loaded_files.size()
	}


func get_summary_text() -> String:
	var lines: Array[String] = []
	lines.append("数据加载统计：")
	lines.append("总记录数: %d" % int(get_summary().get("total_records", 0)))
	lines.append("总文件数: %d" % _loaded_files.size())

	var category_counts: Dictionary = get_summary().get("categories", {})
	for category in CATEGORY_ORDER:
		lines.append("- %s: %d" % [category, int(category_counts.get(category, 0))])

	return "\n".join(lines)


func get_source_of(category: String, record_id: String) -> String:
	return str(_source_index.get("%s:%s" % [category, record_id], "unknown"))


func _read_records_from_dir(dir_path: String) -> Dictionary:
	var records: Array = []
	var files: int = 0

	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		# 目录不存在不是致命错误（例如某些 Mod 未提供全部分类），直接返回空结果。
		return {"records": records, "files": files}

	dir.list_dir_begin()
	while true:
		var entry_name: String = dir.get_next()
		if entry_name.is_empty():
			break
		if entry_name.begins_with("."):
			continue

		var next_path: String = dir_path.path_join(entry_name)

		if dir.current_is_dir():
			# 约定 _schema 只放 Schema，不参与运行时数据加载。
			if entry_name == "_schema":
				continue

			var child_result: Dictionary = _read_records_from_dir(next_path)
			var child_records: Array = child_result.get("records", [])
			files += int(child_result.get("files", 0))
			for child_record in child_records:
				records.append(child_record)
			continue

		if entry_name.get_extension().to_lower() != "json":
			continue

		files += 1
		_loaded_files.append(next_path)
		var payload: Variant = _load_json_file(next_path)
		var normalized_records: Array = _normalize_json_payload(payload, next_path)
		for record in normalized_records:
			records.append(record)

	dir.list_dir_end()
	return {"records": records, "files": files}


func _load_json_file(file_path: String) -> Variant:
	if not FileAccess.file_exists(file_path):
		push_warning("DataManager: JSON 文件不存在：%s" % file_path)
		return null

	var raw_text: String = FileAccess.get_file_as_string(file_path)
	var parser := JSON.new()
	var parse_error: Error = parser.parse(raw_text)
	if parse_error != OK:
		push_warning(
			"DataManager: JSON 解析失败，path=%s, line=%d, error=%s"
			% [file_path, parser.get_error_line(), parser.get_error_message()]
		)
		return null

	return parser.data


func _normalize_json_payload(payload: Variant, file_path: String) -> Array:
	var records: Array = []

	# 支持 3 种常见结构：
	# 1) 数组：[{id: ...}, ...]
	# 2) 单对象：{id: ...}
	# 3) 包裹对象：{items: [{id: ...}, ...]}
	if payload is Array:
		for item in payload:
			if item is Dictionary:
				var normalized: Dictionary = _sanitize_record(item, file_path)
				if not normalized.is_empty():
					records.append(normalized)
		return records

	if payload is Dictionary:
		var obj: Dictionary = payload

		if obj.has("id"):
			var one_record: Dictionary = _sanitize_record(obj, file_path)
			if not one_record.is_empty():
				records.append(one_record)
			return records

		if obj.has("items") and obj["items"] is Array:
			for item in obj["items"]:
				if item is Dictionary:
					var normalized_item: Dictionary = _sanitize_record(item, file_path)
					if not normalized_item.is_empty():
						records.append(normalized_item)
			return records

		# 兜底支持：对象映射结构，如 { "id_a": { ... }, "id_b": { ... } }。
		# 若子项没有 id，则自动使用外层 key 填充 id。
		for key in obj.keys():
			var value: Variant = obj[key]
			if value is Dictionary:
				var record_map: Dictionary = (value as Dictionary).duplicate(true)
				if not record_map.has("id"):
					record_map["id"] = str(key)
				var normalized_map: Dictionary = _sanitize_record(record_map, file_path)
				if not normalized_map.is_empty():
					records.append(normalized_map)
		return records

	return records


func _sanitize_record(record: Dictionary, file_path: String) -> Dictionary:
	var copied: Dictionary = record.duplicate(true)
	var record_id: String = str(copied.get("id", "")).strip_edges()
	if record_id.is_empty():
		push_warning("DataManager: 记录缺少 id，已跳过，path=%s" % file_path)
		return {}

	copied["id"] = record_id
	copied["_meta_source_file"] = file_path
	return copied


func _merge_records(category: String, records: Array, source_tag: String) -> Dictionary:
	var category_map: Dictionary = _database.get(category, {})
	var added: int = 0
	var replaced: int = 0

	for record in records:
		if not (record is Dictionary):
			continue

		var record_dict: Dictionary = (record as Dictionary).duplicate(true)
		var record_id: String = str(record_dict.get("id", "")).strip_edges()
		if record_id.is_empty():
			continue

		record_dict["_meta_source_tag"] = source_tag

		if category_map.has(record_id):
			replaced += 1
		else:
			added += 1

		category_map[record_id] = record_dict
		_source_index["%s:%s" % [category, record_id]] = source_tag

	_database[category] = category_map
	return {
		"added": added,
		"replaced": replaced
	}


func _get_event_bus() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("EventBus")
