extends RefCounted
class_name SceneNavigator

# SceneNavigator 只负责场景切换和运行时数据重载。
# 它依赖 ServiceRegistry，不直接拥有业务状态。
# 通过 SceneHost 托管当前场景节点，避免多处散落切换逻辑。

const MAIN_SCENE_PATH: String = "res://scenes/main/main.tscn"
const BATTLEFIELD_SCENE_PATH: String = "res://scenes/battle/battlefield_scene.tscn"


var _scene_host: Node = null
var _services: ServiceRegistry = null
var _current_scene: Node = null


# 绑定场景宿主和服务注册表。
func configure(scene_host: Node, services: ServiceRegistry) -> void:
	_scene_host = scene_host
	_services = services
	_connect_event_bus()


# 释放引用，避免旧场景残留外部依赖。
func shutdown() -> void:
	_scene_host = null
	_current_scene = null
	_services = null


# 切换到指定场景文件，并同步 AppSessionState。
func change_scene_to_file(scene_path: String) -> bool:
	var normalized_path: String = scene_path.strip_edges()
	if normalized_path.is_empty():
		push_error("SceneNavigator: scene path is empty.")
		return false
	if _scene_host == null or not is_instance_valid(_scene_host):
		push_error("SceneNavigator: scene host is not ready.")
		return false
	if not ResourceLoader.exists(normalized_path):
		push_error("SceneNavigator: scene does not exist: %s" % normalized_path)
		return false

	var packed_scene: Resource = load(normalized_path)
	if not (packed_scene is PackedScene):
		push_error("SceneNavigator: resource is not a PackedScene: %s" % normalized_path)
		return false

	var next_scene = (packed_scene as PackedScene).instantiate()
	if next_scene == null:
		push_error("SceneNavigator: instantiate failed: %s" % normalized_path)
		return false

	# 所有顶层场景都通过统一入口拿到服务注册表。
	next_scene.bind_app_services(_services)

	var previous_scene_path: String = ""
	if _services != null and _services.app_session != null:
		previous_scene_path = _services.app_session.current_scene_path

	if _current_scene != null and is_instance_valid(_current_scene):
		if _current_scene.get_parent() == _scene_host:
			_scene_host.remove_child(_current_scene)
		_current_scene.queue_free()

	_scene_host.add_child(next_scene)
	_current_scene = next_scene

	if _services != null and _services.app_session != null:
		_services.app_session.set_current_scene_path(normalized_path)
		_services.app_session.set_phase(_resolve_phase_for_scene(normalized_path))

	_emit_scene_changed(previous_scene_path, normalized_path)
	return true


# 重新加载当前场景，常用于热重载或测试回放。
func reload_current_scene() -> bool:
	if _services == null or _services.app_session == null:
		return false
	var scene_path: String = _services.app_session.current_scene_path
	if scene_path.is_empty():
		return false
	return change_scene_to_file(scene_path)


# 顺序执行基础数据、模组数据和增益数据重载。
func reload_runtime_data() -> Dictionary:
	var summary: Dictionary = {
		"base": {},
		"mods": {},
		"unit_augment": {},
		"phase": "",
		"scene": ""
	}
	if _services == null:
		return summary

	# 数据重载顺序固定，避免后续系统读到未覆盖完成的快照。
	var data_repository = _services.data_repository
	if data_repository != null:
		var base_value: Variant = data_repository.load_base_data()
		if base_value is Dictionary:
			summary["base"] = (base_value as Dictionary).duplicate(true)

	var mod_loader = _services.mod_loader
	if mod_loader != null:
		var mod_value: Variant = mod_loader.load_and_apply_mods()
		if mod_value is Dictionary:
			summary["mods"] = (mod_value as Dictionary).duplicate(true)

	var unit_augment_manager = _services.unit_augment_manager
	if unit_augment_manager != null:
		var unit_augment_value: Variant = unit_augment_manager.reload_from_data()
		if unit_augment_value is Dictionary:
			summary["unit_augment"] = (unit_augment_value as Dictionary).duplicate(true)

	if _services.app_session != null:
		summary["phase"] = _services.app_session.get_phase_name()
		summary["scene"] = _services.app_session.current_scene_path
		_services.app_session.set_last_load_summary(summary)

	return summary


# 订阅场景切换请求，供 EventBus 驱动页面跳转。
func _connect_event_bus() -> void:
	if _services == null or _services.event_bus == null:
		return
	var event_bus: Node = _services.event_bus
	var cb: Callable = Callable(self, "_on_scene_change_requested")
	if event_bus.has_signal("scene_change_requested") and not event_bus.is_connected("scene_change_requested", cb):
		event_bus.connect("scene_change_requested", cb)


# 转发事件总线里的场景切换请求。
func _on_scene_change_requested(scene_path: String) -> void:
	change_scene_to_file(scene_path)


# 广播场景切换完成事件，供上层刷新状态。
func _emit_scene_changed(previous_scene_path: String, next_scene_path: String) -> void:
	if _services == null or _services.event_bus == null:
		return
	_services.event_bus.emit_scene_changed(previous_scene_path, next_scene_path)


# 根据目标场景推导阶段，未命中的场景沿用当前阶段。
func _resolve_phase_for_scene(scene_path: String) -> int:
	match scene_path:
		MAIN_SCENE_PATH:
			return AppSessionState.GamePhase.MAIN_MENU
		BATTLEFIELD_SCENE_PATH:
			return AppSessionState.GamePhase.PREPARATION
		_:
			if _services != null and _services.app_session != null:
				return _services.app_session.current_phase
			return AppSessionState.GamePhase.BOOT
