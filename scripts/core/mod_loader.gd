extends Node

# ===========================
# Mod 加载器（AutoLoad）
# ===========================
# 目标能力：
# 1. 扫描 Mod 目录并读取 mod.json。
# 2. 按 load_order 排序后依次加载。
# 3. 将 Mod 的 data/* JSON 合并进 DataManager（后加载覆盖先加载）。
# 4. 索引 Mod 的 assets 覆盖映射，供后续资源加载阶段使用。

const USER_MOD_ROOT := "user://mods"
const DEV_MOD_ROOT := "res://mods"

# 已成功加载的 Mod 列表（顺序即实际加载顺序）。
var _loaded_mods: Array[Dictionary] = []

# 资产覆盖映射：
# relative_path -> { "path": "xxx", "mod_id": "xxx" }
var _asset_override_map: Dictionary = {}


func load_and_apply_mods() -> Dictionary:
	_loaded_mods.clear()
	_asset_override_map.clear()

	var discovered_mods: Array[Dictionary] = discover_mods()
	discovered_mods.sort_custom(Callable(self, "_sort_mod_by_order"))

	var applied_count: int = 0
	var total_records: int = 0
	var total_files: int = 0

	for mod_info in discovered_mods:
		var apply_result: Dictionary = _apply_single_mod(mod_info)
		if bool(apply_result.get("applied", false)):
			applied_count += 1
			total_records += int(apply_result.get("records", 0))
			total_files += int(apply_result.get("files", 0))
			_loaded_mods.append(mod_info)

	var summary: Dictionary = {
		"discovered": discovered_mods.size(),
		"applied": applied_count,
		"records": total_records,
		"files": total_files,
		"asset_overrides": _asset_override_map.size()
	}

	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_mod_load_completed", summary)
	return summary


func discover_mods() -> Array[Dictionary]:
	var mods: Array[Dictionary] = []
	_collect_mods_from_root(USER_MOD_ROOT, mods)
	_collect_mods_from_root(DEV_MOD_ROOT, mods)
	return mods


func get_loaded_mods() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for mod_info in _loaded_mods:
		output.append(mod_info.duplicate(true))
	return output


func get_asset_override_map() -> Dictionary:
	return _asset_override_map.duplicate(true)


func resolve_asset_path(asset_relative_path: String) -> String:
	# 统一接受三种输入风格：
	# 1) "sprites/units/xxx.png"
	# 2) "assets/sprites/units/xxx.png"
	# 3) "res://assets/sprites/units/xxx.png"
	var normalized: String = asset_relative_path
	if normalized.begins_with("res://assets/"):
		normalized = normalized.trim_prefix("res://assets/")
	elif normalized.begins_with("assets/"):
		normalized = normalized.trim_prefix("assets/")

	if _asset_override_map.has(normalized):
		return str((_asset_override_map[normalized] as Dictionary).get("path", ""))
	return "res://assets/%s" % normalized


func _collect_mods_from_root(root_path: String, output: Array[Dictionary]) -> void:
	var dir: DirAccess = DirAccess.open(root_path)
	if dir == null:
		return

	dir.list_dir_begin()
	while true:
		var folder_name: String = dir.get_next()
		if folder_name.is_empty():
			break
		if folder_name.begins_with("."):
			continue
		if not dir.current_is_dir():
			continue

		var mod_root_path: String = root_path.path_join(folder_name)
		var mod_manifest_path: String = mod_root_path.path_join("mod.json")
		if not FileAccess.file_exists(mod_manifest_path):
			continue

		var manifest: Variant = _read_json_file(mod_manifest_path)
		if not (manifest is Dictionary):
			push_warning("ModLoader: mod.json 无效，path=%s" % mod_manifest_path)
			continue

		var mod_info: Dictionary = _normalize_mod_manifest(manifest as Dictionary, folder_name, mod_root_path)
		output.append(mod_info)

	dir.list_dir_end()


func _normalize_mod_manifest(raw: Dictionary, folder_name: String, mod_root_path: String) -> Dictionary:
	var mod_id: String = str(raw.get("id", folder_name)).strip_edges()
	if mod_id.is_empty():
		mod_id = folder_name

	return {
		"id": mod_id,
		"name": str(raw.get("name", mod_id)),
		"author": str(raw.get("author", "unknown")),
		"version": str(raw.get("version", "0.0.1")),
		"description": str(raw.get("description", "")),
		"load_order": int(raw.get("load_order", 0)),
		"game_version_min": str(raw.get("game_version_min", "0.0.0")),
		"root_path": mod_root_path,
		"manifest_path": mod_root_path.path_join("mod.json")
	}


func _apply_single_mod(mod_info: Dictionary) -> Dictionary:
	var mod_id: String = str(mod_info.get("id", "unknown_mod"))
	var mod_name: String = str(mod_info.get("name", mod_id))
	var mod_root_path: String = str(mod_info.get("root_path", ""))
	var load_order: int = int(mod_info.get("load_order", 0))

	var records_loaded: int = 0
	var files_loaded: int = 0
	var data_manager: Node = _get_data_manager()
	if data_manager == null:
		push_error("ModLoader: DataManager 未就绪，无法加载 Mod：%s" % mod_id)
		return {
			"applied": false,
			"records": 0,
			"files": 0
		}

	# 按 DataManager 支持分类遍历加载，目录不存在时会自动跳过。
	var supported_categories: Variant = data_manager.call("get_supported_categories")
	if not (supported_categories is Array):
		return {
			"applied": false,
			"records": 0,
			"files": 0
		}

	for category_value in supported_categories:
		var category: String = str(category_value)
		var category_dir: String = mod_root_path.path_join("data").path_join(category)
		var result_value: Variant = data_manager.call(
			"load_category_from_dir",
			category,
			category_dir,
			"mod:%s" % mod_id
		)
		if result_value is Dictionary:
			var result: Dictionary = result_value
			records_loaded += int(result.get("records", 0))
			files_loaded += int(result.get("files", 0))

	var asset_root: String = mod_root_path.path_join("assets")
	_index_asset_overrides(asset_root, "", mod_id)

	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_mod_loaded", mod_id, mod_name, load_order)

	return {
		"applied": true,
		"records": records_loaded,
		"files": files_loaded
	}


func _index_asset_overrides(abs_dir_path: String, relative_dir_path: String, mod_id: String) -> void:
	var dir: DirAccess = DirAccess.open(abs_dir_path)
	if dir == null:
		return

	dir.list_dir_begin()
	while true:
		var entry_name: String = dir.get_next()
		if entry_name.is_empty():
			break
		if entry_name.begins_with("."):
			continue

		var next_abs_path: String = abs_dir_path.path_join(entry_name)
		var next_relative_path: String = entry_name if relative_dir_path.is_empty() else relative_dir_path.path_join(entry_name)

		if dir.current_is_dir():
			_index_asset_overrides(next_abs_path, next_relative_path, mod_id)
		else:
			_asset_override_map[next_relative_path] = {
				"path": next_abs_path,
				"mod_id": mod_id
			}

	dir.list_dir_end()


func _read_json_file(file_path: String) -> Variant:
	if not FileAccess.file_exists(file_path):
		return null

	var content: String = FileAccess.get_file_as_string(file_path)
	var parser := JSON.new()
	var parse_error: Error = parser.parse(content)
	if parse_error != OK:
		push_warning(
			"ModLoader: JSON 解析失败，path=%s, line=%d, error=%s"
			% [file_path, parser.get_error_line(), parser.get_error_message()]
		)
		return null
	return parser.data


func _sort_mod_by_order(a: Dictionary, b: Dictionary) -> bool:
	var order_a: int = int(a.get("load_order", 0))
	var order_b: int = int(b.get("load_order", 0))
	if order_a == order_b:
		return str(a.get("id", "")) < str(b.get("id", ""))
	return order_a < order_b


func _get_event_bus() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("EventBus")


func _get_data_manager() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("DataManager")
