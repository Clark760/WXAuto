extends Node
class_name AppRoot

# AppRoot 负责装配全局服务并切入首个主场景。
# 这里不承载业务逻辑，只负责启动期依赖拼装。
# 所有服务节点都挂在 Services 容器下，便于统一释放。

const DEFAULT_MAIN_SCENE_PATH: String = "res://scenes/main/main.tscn"

const EVENT_BUS_SCRIPT: Script = preload("res://scripts/core/event_bus.gd")
const OBJECT_POOL_SCRIPT: Script = preload("res://scripts/core/object_pool.gd")
const DATA_MANAGER_SCRIPT: Script = preload("res://scripts/data/data_manager.gd")
const MOD_LOADER_SCRIPT: Script = preload("res://scripts/core/mod_loader.gd")
const UNIT_AUGMENT_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_manager.gd")

@onready var _services_host: Node = $Services
@onready var _scene_host: Node = $SceneHost

var _services: ServiceRegistry = ServiceRegistry.new()
var _bootstrapped: bool = false
var _owned_provider_nodes: Array[Node] = []


# 首次入树时延迟启动，确保子节点结构已经稳定。
func _ready() -> void:
	if _bootstrapped:
		return
	call_deferred("_bootstrap")


# 退出树时回收自建服务节点，并断开导航器引用。
func _exit_tree() -> void:
	if _services != null and _services.scene_navigator != null:
		_services.scene_navigator.shutdown()
		_services.register_scene_navigator(null)
	_services = null
	for node in _owned_provider_nodes:
		if node != null and is_instance_valid(node) and node.get_parent() != null:
			node.queue_free()
	_owned_provider_nodes.clear()


# 暴露服务注册表，供测试和场景脚本读取依赖。
func get_services() -> ServiceRegistry:
	return _services


# 创建全局服务、绑定依赖并进入默认主场景。
func _bootstrap() -> void:
	if _bootstrapped:
		return

	# 先实例化基础服务，再交由注册表统一暴露。
	var event_bus: Node = _instantiate_service_node("EventBus", EVENT_BUS_SCRIPT)
	var object_pool: Node = _instantiate_service_node("ObjectPool", OBJECT_POOL_SCRIPT)
	var data_repository: Node = _instantiate_service_node("DataManager", DATA_MANAGER_SCRIPT)
	var mod_loader: Node = _instantiate_service_node("ModLoader", MOD_LOADER_SCRIPT)
	var unit_augment_manager: Node = _instantiate_service_node(
		"UnitAugmentManager",
		UNIT_AUGMENT_MANAGER_SCRIPT
	)

	var app_session := AppSessionState.new()
	app_session.bind_event_bus(event_bus)

	_services.register_event_bus(event_bus)
	_services.register_object_pool(object_pool)
	_services.register_data_repository(data_repository)
	_services.register_mod_loader(mod_loader)
	_services.register_unit_augment_manager(unit_augment_manager)
	_services.register_app_session(app_session)

	# 所有 Node 型服务都挂到同一容器，生命周期由 AppRoot 托管。
	for service_node in [event_bus, object_pool, data_repository, mod_loader, unit_augment_manager]:
		_mount_service_node(service_node)

	if object_pool != null:
		object_pool.bind_runtime_services(_services)
	if data_repository != null:
		data_repository.bind_runtime_services(_services)
	if mod_loader != null:
		mod_loader.bind_runtime_services(_services)
	if unit_augment_manager != null:
		unit_augment_manager.bind_runtime_services(_services)

	var scene_navigator := SceneNavigator.new()
	_services.register_scene_navigator(scene_navigator)
	scene_navigator.configure(_scene_host, _services)

	_bootstrapped = true
	app_session.set_phase(AppSessionState.GamePhase.BOOT)
	scene_navigator.reload_runtime_data()

	if not scene_navigator.change_scene_to_file(DEFAULT_MAIN_SCENE_PATH):
		push_error("AppRoot: failed to enter main scene.")


# 优先复用现有服务节点，避免测试和热重载重复创建。
func _instantiate_service_node(node_name: String, script: Script) -> Node:
	if _services_host == null:
		return null

	var existing: Node = _services_host.get_node_or_null(node_name)
	if existing != null:
		return existing

	var instance_value: Variant = script.new()
	if not (instance_value is Node):
		push_error("AppRoot: service script is not Node-based: %s" % script.resource_path)
		return null

	var service_node: Node = instance_value as Node
	service_node.name = node_name
	_owned_provider_nodes.append(service_node)
	return service_node


# 将服务节点安全挂到 Services 容器下。
func _mount_service_node(service_node: Node) -> void:
	if service_node == null or _services_host == null:
		return
	if service_node.get_parent() == _services_host:
		return
	_services_host.add_child(service_node)
