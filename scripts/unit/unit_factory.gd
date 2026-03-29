extends Node

# 角色工厂入口
const UNIT_SCENE_PATH := "res://scenes/units/unit_base.tscn"
const UNIT_DATA_SCRIPT: Script = preload("res://scripts/domain/unit/unit_data.gd")
const PROBE_SCOPE_UNIT_FACTORY_ACQUIRE: String = "unit_factory_acquire"
const PROBE_SCOPE_UNIT_FACTORY_CONFIGURE: String = "unit_factory_configure"

var _unit_scene: PackedScene = null
var _unit_records: Dictionary = {}         # unit_id -> normalized record
var _registered_pool_keys: Dictionary = {} # pool_key -> true
var _texture_cache: Dictionary = {}        # asset_path -> Texture2D
var _placeholder_cache: Dictionary = {}    # quality -> Texture2D
var _services: ServiceRegistry = null


# 绑定运行时服务
func bind_runtime_services(services: ServiceRegistry) -> void:
	_services = services
	if not is_inside_tree():
		return
	reload_from_data()
	_connect_event_bus()


# 初始化单位场景
func _ready() -> void:
	_unit_scene = load(UNIT_SCENE_PATH) as PackedScene
	reload_from_data()
	_connect_event_bus()


# 重建单位缓存
func reload_from_data() -> void:
	_unit_records.clear()
	_registered_pool_keys.clear()
	_texture_cache.clear()

	var data_manager: Variant = _get_data_manager()
	if data_manager == null:
		push_warning("UnitFactory: DataManager 未就绪，跳过角色数据加载。")
		return

	var records_variant: Variant = data_manager.get_all_records("units")
	if not (records_variant is Array):
		return

	for raw_record in records_variant:
		if not (raw_record is Dictionary):
			continue

		var normalized: Dictionary = UNIT_DATA_SCRIPT.normalize_unit_record(raw_record)
		var unit_id: String = str(normalized.get("id", ""))
		if unit_id.is_empty():
			continue

		_unit_records[unit_id] = normalized
		_register_pool_for_unit(unit_id)


# 列出全部单位
func get_unit_ids() -> Array[String]:
	var ids: Array[String] = []
	for unit_id in _unit_records.keys():
		ids.append(str(unit_id))
	ids.sort()
	return ids


# 判断单位是否存在
func has_unit(unit_id: String) -> bool:
	return _unit_records.has(unit_id)


# 返回单位配置副本
func get_unit_record(unit_id: String) -> Dictionary:
	if not _unit_records.has(unit_id):
		return {}
	return (_unit_records[unit_id] as Dictionary).duplicate(true)


# 借出单位实例
func acquire_unit(unit_id: String, forced_star: int = -1, parent_override: Node = null) -> Node:
	var object_pool: Variant = _get_object_pool()
	if object_pool == null:
		push_error("UnitFactory: ObjectPool 未就绪，无法获取角色实例。")
		return null

	if not _unit_records.has(unit_id):
		push_warning("UnitFactory: 未找到角色数据：%s" % unit_id)
		return null

	var pool_key: String = _pool_key_of(unit_id)
	if not _registered_pool_keys.has(pool_key):
		_register_pool_for_unit(unit_id)

	var acquire_begin_us: int = _probe_begin_timing()
	var unit_node: Variant = object_pool.acquire(pool_key, parent_override)
	if unit_node == null:
		_probe_commit_timing(PROBE_SCOPE_UNIT_FACTORY_ACQUIRE, acquire_begin_us)
		return null

	_configure_unit_node(unit_node, unit_id, forced_star, pool_key)
	_probe_commit_timing(PROBE_SCOPE_UNIT_FACTORY_ACQUIRE, acquire_begin_us)
	return unit_node as Node


# 回收单位实例
func release_unit(unit_node: Node) -> bool:
	if unit_node == null:
		return false

	var pool_key: String = str(unit_node.get("pool_key"))
	if pool_key.is_empty():
		return false

	var object_pool: Variant = _get_object_pool()
	if object_pool == null:
		return false
	return bool(object_pool.release(pool_key, unit_node))


func prewarm_unit_assets(unit_ids: Array[String]) -> int:
	var warmed_count: int = 0
	for unit_id in _collect_unique_unit_ids(unit_ids):
		if not _unit_records.has(unit_id):
			continue
		_prewarm_unit_texture(unit_id)
		warmed_count += 1
	return warmed_count


func prewarm_unit_instances(
	unit_ids: Array[String],
	count_per_id: int = 1,
	parent_override: Node = null
) -> int:
	if count_per_id <= 0:
		return 0
	var count_by_unit_id: Dictionary = {}
	for unit_id in _collect_unique_unit_ids(unit_ids):
		count_by_unit_id[unit_id] = count_per_id
	return prewarm_unit_instances_by_count(count_by_unit_id, parent_override)


func prewarm_unit_instances_by_count(
	count_by_unit_id: Dictionary,
	parent_override: Node = null,
	max_instances: int = -1
) -> int:
	var object_pool: Variant = _get_object_pool()
	if object_pool == null:
		return 0

	var warmed_count: int = 0
	var sorted_ids: Array[String] = []
	for raw_key in count_by_unit_id.keys():
		var unit_id: String = str(raw_key).strip_edges()
		if unit_id.is_empty():
			continue
		sorted_ids.append(unit_id)
	sorted_ids.sort()

	for unit_id in sorted_ids:
		if max_instances >= 0 and warmed_count >= max_instances:
			break
		if not _unit_records.has(unit_id):
			continue

		var requested_count: int = maxi(int(count_by_unit_id.get(unit_id, 0)), 0)
		if requested_count <= 0:
			continue

		_register_pool_for_unit(unit_id)
		_prewarm_unit_texture(unit_id)

		var available_count: int = _get_available_pool_count(unit_id)
		var missing_count: int = maxi(requested_count - available_count, 0)
		if max_instances >= 0:
			missing_count = mini(missing_count, max_instances - warmed_count)
		if missing_count <= 0:
			continue

		if object_pool.has_method("ensure_available"):
			warmed_count += int(
				object_pool.ensure_available(
					_pool_key_of(unit_id),
					available_count + missing_count,
					parent_override
				)
			)
			continue

		for _index in range(missing_count):
			var unit_node: Node = acquire_unit(unit_id, -1, parent_override)
			if unit_node == null:
				break
			if release_unit(unit_node):
				warmed_count += 1
				if max_instances >= 0 and warmed_count >= max_instances:
					return warmed_count
	return warmed_count


# 注册单位对象池
func _register_pool_for_unit(unit_id: String) -> void:
	var object_pool: Variant = _get_object_pool()
	if object_pool == null:
		return

	var pool_key: String = _pool_key_of(unit_id)
	if _registered_pool_keys.has(pool_key):
		return

	var factory: Callable = Callable(self, "_create_unit_instance").bind(unit_id)
	var success: bool = bool(object_pool.register_factory(pool_key, factory, 0, null, true))
	if success:
		_registered_pool_keys[pool_key] = true


# 创建单位实例
func _create_unit_instance(unit_id: String) -> Node:
	if _unit_scene == null:
		_unit_scene = load(UNIT_SCENE_PATH) as PackedScene
	if _unit_scene == null:
		push_error("UnitFactory: 加载单位场景失败：%s" % UNIT_SCENE_PATH)
		return null

	var unit_node: Variant = _unit_scene.instantiate()
	if unit_node == null:
		return null

	if _unit_records.has(unit_id):
		_configure_unit_node(unit_node, unit_id, -1, _pool_key_of(unit_id))
	return unit_node as Node


# 写入运行时状态
func _configure_unit_node(unit_node: Variant, unit_id: String, forced_star: int, pool_key: String) -> void:
	if unit_node == null:
		return
	var configure_begin_us: int = _probe_begin_timing()
	if unit_node.has_method("bind_runtime_services"):
		unit_node.bind_runtime_services(_services)
	unit_node.set("pool_key", pool_key)
	unit_node.setup_from_unit_record(_unit_records[unit_id], forced_star)

	var sprite_path: String = str(unit_node.get("sprite_path"))
	var quality: String = str(unit_node.get("quality"))
	var texture: Texture2D = _resolve_unit_texture(sprite_path, quality)
	unit_node.set_display_texture(texture)
	_probe_commit_timing(PROBE_SCOPE_UNIT_FACTORY_CONFIGURE, configure_begin_us)


func _prewarm_unit_texture(unit_id: String) -> void:
	var record: Dictionary = _unit_records.get(unit_id, {})
	if record.is_empty():
		return
	_resolve_unit_texture(
		str(record.get("sprite_path", "")),
		str(record.get("quality", "white"))
	)


# 解析最终贴图
func _resolve_unit_texture(raw_sprite_path: String, quality: String) -> Texture2D:
	var normalized_path: String = _normalize_asset_path(raw_sprite_path)
	var mod_loader: Variant = _get_mod_loader()

	var resolved_path: String = normalized_path
	if mod_loader != null:
		resolved_path = str(mod_loader.resolve_asset_path(normalized_path))

	if _texture_cache.has(resolved_path):
		return _texture_cache[resolved_path]

	var texture: Texture2D = null
	if (
		(resolved_path.begins_with("res://") or resolved_path.begins_with("user://"))
		and ResourceLoader.exists(resolved_path)
	):
		texture = load(resolved_path) as Texture2D

	if texture == null:
		texture = _get_placeholder_texture(quality)

	_texture_cache[resolved_path] = texture
	return texture


# 生成占位贴图
func _get_placeholder_texture(quality: String) -> Texture2D:
	if _placeholder_cache.has(quality):
		return _placeholder_cache[quality]

	var color: Color = _quality_to_color(quality)
	var image: Image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(color)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	_placeholder_cache[quality] = texture
	return texture


# 归一化资源路径
func _normalize_asset_path(path_value: String) -> String:
	var is_res_path: bool = path_value.begins_with("res://")
	var is_user_path: bool = path_value.begins_with("user://")
	if is_res_path or is_user_path:
		return path_value
	if path_value.begins_with("assets/"):
		return "res://%s" % path_value
	return "res://assets/sprites/units/%s.png" % path_value


# 品质转颜色
func _quality_to_color(quality: String) -> Color:
	match quality:
		"white":
			return Color(0.94, 0.94, 0.94, 1.0)
		"green":
			return Color(0.58, 0.88, 0.58, 1.0)
		"blue":
			return Color(0.48, 0.72, 0.96, 1.0)
		"purple":
			return Color(0.76, 0.54, 0.9, 1.0)
		"orange":
			return Color(0.98, 0.7, 0.34, 1.0)
		_:
			return Color(0.8, 0.8, 0.8, 1.0)


# 生成池键
func _pool_key_of(unit_id: String) -> String:
	var pool_key: String = "unit:%s" % unit_id
	return pool_key


func _collect_unique_unit_ids(unit_ids: Array[String]) -> Array[String]:
	var output: Array[String] = []
	var seen: Dictionary = {}
	for raw_unit_id in unit_ids:
		var unit_id: String = str(raw_unit_id).strip_edges()
		if unit_id.is_empty():
			continue
		if seen.has(unit_id):
			continue
		seen[unit_id] = true
		output.append(unit_id)
	return output


func _get_available_pool_count(unit_id: String) -> int:
	var object_pool: Variant = _get_object_pool()
	if object_pool == null or not object_pool.has_method("get_pool_stats"):
		return 0
	var stats_value: Variant = object_pool.get_pool_stats(_pool_key_of(unit_id))
	if not (stats_value is Dictionary):
		return 0
	return maxi(int((stats_value as Dictionary).get("available", 0)), 0)


# 连接数据事件
func _connect_event_bus() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null:
		return
	var cb: Callable = Callable(self, "_on_data_reloaded")
	if not event_bus.is_connected("data_reloaded", cb):
		event_bus.connect("data_reloaded", cb)


# 响应数据重载
func _on_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	reload_from_data()


# 读取事件总线
func _get_event_bus() -> Node:
	if _services == null:
		return null
	return _services.event_bus


# 读取数据仓库
func _get_data_manager() -> Node:
	if _services == null:
		return null
	return _services.data_repository


# 读取模组加载器
func _get_mod_loader() -> Node:
	if _services == null:
		return null
	return _services.mod_loader


# 读取对象池服务
func _get_object_pool() -> Node:
	if _services == null:
		return null
	return _services.object_pool


func _probe_begin_timing() -> int:
	var runtime_probe = _services.runtime_probe if _services != null else null
	if runtime_probe == null or not runtime_probe.has_method("begin_timing"):
		return 0
	return int(runtime_probe.begin_timing())


func _probe_commit_timing(scope_name: String, begin_us: int) -> void:
	var runtime_probe = _services.runtime_probe if _services != null else null
	if runtime_probe == null or not runtime_probe.has_method("commit_timing"):
		return
	runtime_probe.commit_timing(scope_name, begin_us)
