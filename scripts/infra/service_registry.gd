extends RefCounted
class_name ServiceRegistry


var event_bus: Node = null
var object_pool: Node = null
var data_repository: Node = null
var mod_loader: Node = null
var unit_augment_manager: Node = null
var app_session: AppSessionState = null
var scene_navigator: SceneNavigator = null
var runtime_probe = null


# 注册事件总线服务。
func register_event_bus(service: Node) -> void:
	event_bus = service


# 注册对象池服务。
func register_object_pool(service: Node) -> void:
	object_pool = service


# 注册数据仓库服务。
func register_data_repository(service: Node) -> void:
	data_repository = service


# 注册模组加载服务。
func register_mod_loader(service: Node) -> void:
	mod_loader = service


# 注册单位养成服务。
func register_unit_augment_manager(service: Node) -> void:
	unit_augment_manager = service


# 注册会话状态服务。
func register_app_session(service: AppSessionState) -> void:
	app_session = service


# 注册场景导航服务。
func register_scene_navigator(service: SceneNavigator) -> void:
	scene_navigator = service


# 注册运行时探针服务。
func register_runtime_probe(service) -> void:
	runtime_probe = service


# 检查启动期所需的服务是否已全部装配完成。
func has_required_services() -> bool:
	return (
		event_bus != null
		and object_pool != null
		and data_repository != null
		and mod_loader != null
		and unit_augment_manager != null
		and app_session != null
		and scene_navigator != null
	)
