extends Node

# ===========================
# 角色工厂
# ===========================
# 职责：
# 1. 从 DataManager 的 units 数据创建 UnitBase 实例。
# 2. 对接 ObjectPool，实现角色实例复用。
# 3. 处理贴图加载与缺图占位，保证原型阶段可稳定显示。

const UNIT_SCENE_PATH := "res://scenes/units/unit_base.tscn"

var _unit_scene: PackedScene = null
var _unit_records: Dictionary = {}         # unit_id -> normalized record
var _registered_pool_keys: Dictionary = {} # pool_key -> true
var _texture_cache: Dictionary = {}        # asset_path -> Texture2D
var _placeholder_cache: Dictionary = {}    # quality -> Texture2D


func _ready() -> void:
	_unit_scene = load(UNIT_SCENE_PATH) as PackedScene
	reload_from_data()
	_connect_event_bus()


func reload_from_data() -> void:
	_unit_records.clear()
	_registered_pool_keys.clear()
	_texture_cache.clear()

	var data_manager: Node = _get_data_manager()
	if data_manager == null:
		push_warning("UnitFactory: DataManager 未就绪，跳过角色数据加载。")
		return

	var unit_data_script: Script = load("res://scripts/data/unit_data.gd")
	var records_variant: Variant = data_manager.call("get_all_records", "units")
	if records_variant is Array:
		for raw_record in records_variant:
			if not (raw_record is Dictionary):
				continue

			var normalized: Dictionary = unit_data_script.call("normalize_unit_record", raw_record)
			var unit_id: String = str(normalized.get("id", ""))
			if unit_id.is_empty():
				continue

			_unit_records[unit_id] = normalized
			_register_pool_for_unit(unit_id)


func get_unit_ids() -> Array[String]:
	var ids: Array[String] = []
	for unit_id in _unit_records.keys():
		ids.append(str(unit_id))
	ids.sort()
	return ids


func has_unit(unit_id: String) -> bool:
	return _unit_records.has(unit_id)


func get_unit_record(unit_id: String) -> Dictionary:
	if not _unit_records.has(unit_id):
		return {}
	return (_unit_records[unit_id] as Dictionary).duplicate(true)


func acquire_unit(unit_id: String, forced_star: int = -1, parent_override: Node = null) -> Node:
	var object_pool: Node = _get_object_pool()
	if object_pool == null:
		push_error("UnitFactory: ObjectPool 未就绪，无法获取角色实例。")
		return null

	if not _unit_records.has(unit_id):
		push_warning("UnitFactory: 未找到角色数据：%s" % unit_id)
		return null

	var pool_key: String = _pool_key_of(unit_id)
	if not _registered_pool_keys.has(pool_key):
		_register_pool_for_unit(unit_id)

	var unit_node: Node = object_pool.call("acquire", pool_key, parent_override)
	if unit_node == null:
		return null

	unit_node.set("pool_key", pool_key)
	unit_node.call("setup_from_unit_record", _unit_records[unit_id], forced_star)

	var texture: Texture2D = _resolve_unit_texture(unit_node.get("sprite_path"), unit_node.get("quality"))
	unit_node.call("set_display_texture", texture)
	return unit_node


func release_unit(unit_node: Node) -> bool:
	if unit_node == null:
		return false

	var pool_key: String = str(unit_node.get("pool_key"))
	if pool_key.is_empty():
		return false

	var object_pool: Node = _get_object_pool()
	if object_pool == null:
		return false
	return bool(object_pool.call("release", pool_key, unit_node))


func _register_pool_for_unit(unit_id: String) -> void:
	var object_pool: Node = _get_object_pool()
	if object_pool == null:
		return

	var pool_key: String = _pool_key_of(unit_id)
	if _registered_pool_keys.has(pool_key):
		return

	var factory: Callable = Callable(self, "_create_unit_instance").bind(unit_id)
	var success: bool = bool(object_pool.call("register_factory", pool_key, factory, 0, null, true))
	if success:
		_registered_pool_keys[pool_key] = true


func _create_unit_instance(unit_id: String) -> Node:
	if _unit_scene == null:
		_unit_scene = load(UNIT_SCENE_PATH) as PackedScene
	if _unit_scene == null:
		push_error("UnitFactory: 加载单位场景失败：%s" % UNIT_SCENE_PATH)
		return null

	var unit_node: Node = _unit_scene.instantiate()
	if unit_node == null:
		return null

	if _unit_records.has(unit_id):
		unit_node.call("setup_from_unit_record", _unit_records[unit_id], -1)
		var texture: Texture2D = _resolve_unit_texture(unit_node.get("sprite_path"), unit_node.get("quality"))
		unit_node.call("set_display_texture", texture)

	return unit_node


func _resolve_unit_texture(raw_sprite_path: String, quality: String) -> Texture2D:
	var normalized_path: String = _normalize_asset_path(raw_sprite_path)
	var mod_loader: Node = _get_mod_loader()

	var resolved_path: String = normalized_path
	if mod_loader != null:
		var mod_path: Variant = mod_loader.call("resolve_asset_path", normalized_path)
		resolved_path = str(mod_path)

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


func _get_placeholder_texture(quality: String) -> Texture2D:
	if _placeholder_cache.has(quality):
		return _placeholder_cache[quality]

	var color: Color = _quality_to_color(quality)
	var image: Image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(color)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	_placeholder_cache[quality] = texture
	return texture


func _normalize_asset_path(path_value: String) -> String:
	if path_value.begins_with("res://") or path_value.begins_with("user://"):
		return path_value
	if path_value.begins_with("assets/"):
		return "res://%s" % path_value
	return "res://assets/sprites/units/%s.png" % path_value


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


func _pool_key_of(unit_id: String) -> String:
	return "unit:%s" % unit_id


func _connect_event_bus() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null:
		return
	var cb: Callable = Callable(self, "_on_data_reloaded")
	if not event_bus.is_connected("data_reloaded", cb):
		event_bus.connect("data_reloaded", cb)


func _on_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	reload_from_data()


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


func _get_mod_loader() -> Node:
	var tree: SceneTree = _get_scene_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("ModLoader")


func _get_object_pool() -> Node:
	var tree: SceneTree = _get_scene_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("ObjectPool")


func _get_scene_tree() -> SceneTree:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	return main_loop as SceneTree
