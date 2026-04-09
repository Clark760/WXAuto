extends Node2D
class_name BattlefieldScene

const BATTLEFIELD_SESSION_STATE_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_session_state.gd"
)
const INK_THEME_BUILDER = preload("res://scripts/ui/ink_theme_builder.gd")
const PROBE_SCOPE_SCENE_PROCESS: String = "battlefield_scene_process"
const PROBE_SCOPE_WORLD_PROCESS: String = "battlefield_world_process"
const PROBE_SCOPE_COORDINATOR_PROCESS: String = "battlefield_coordinator_process"
const PROBE_SCOPE_HUD_PROCESS: String = "battlefield_hud_process"

@onready var _scene_refs: Node = $BattlefieldSceneRefs
@onready var _coordinator: Node = $BattlefieldCoordinator
@onready var _world_controller: Node = $BattlefieldWorldController
@onready var _hud_presenter: Node = $BattlefieldHudPresenter

var _session_state: RefCounted = null
var _services: ServiceRegistry = null
var _runtime_probe = null


# 将全局服务传入战场运行时节点。
func bind_app_services(services: ServiceRegistry) -> void:
	_services = services
	_runtime_probe = services.runtime_probe if services != null else null
	_bind_runtime_services_on_path("UnitFactory")
	_bind_runtime_services_on_path("RuntimeStageManager")
	_bind_runtime_services_on_path("CombatManager")
	_bind_runtime_services_on_path("WorldContainer/VfxLayer/VfxFactory")


# 按节点路径给运行时模块补绑定服务。
func _bind_runtime_services_on_path(node_path: String) -> void:
	var runtime_node = get_node_or_null(node_path)
	if runtime_node != null:
		runtime_node.bind_runtime_services(_services)


# 组装战场状态、引用表和各个子协调器。
func _ready() -> void:
	_apply_ink_theme()
	_session_state = BATTLEFIELD_SESSION_STATE_SCRIPT.new()
	if _scene_refs.has_method("bind_app_services"):
		_scene_refs.bind_app_services(_services)
	if _coordinator.has_method("bind_app_services"):
		_coordinator.bind_app_services(_services)
	_scene_refs.bind_from_scene(self)
	_coordinator.initialize(self, _scene_refs, _session_state)
	_hud_presenter.initialize(self, _scene_refs, _session_state)
	_world_controller.initialize(self, _scene_refs, _session_state)
	if _coordinator.has_method("start_session"):
		_coordinator.start_session()
	_session_state.mark_scene_ready()


# 在场景根脚本中挂载水墨风主题
func _apply_ink_theme() -> void:
	var ink_theme: Theme = INK_THEME_BUILDER.build() as Theme
	if ink_theme == null:
		return
	# 设置根节点 theme，所有子树继承
	# 如果根是 Node2D，需要分别给 CanvasLayer 下的 Control 子树设置
	for layer_name in ["HUDLayer", "ShopPanelLayer", "DetailLayer", "InventoryLayer", "BottomLayer"]:
		var layer: Node = get_node_or_null(layer_name)
		if layer == null:
			continue
		for child in layer.get_children():
			if child is Control:
				(child as Control).theme = ink_theme
	var light_panel_style: StyleBox = INK_THEME_BUILDER.make_light_panel_style() as StyleBox
	if light_panel_style == null:
		return
	for panel_path in [
		"HUDLayer/BattleLogPanel",
		"HUDLayer/UnitTooltip",
		"HUDLayer/TerrainTooltip",
		"DetailLayer/ItemTooltip"
	]:
		var panel: PanelContainer = get_node_or_null(panel_path) as PanelContainer
		if panel != null:
			panel.add_theme_stylebox_override("panel", light_panel_style.duplicate(true))


# 退出战场时关闭 HUD，并释放会话引用。
func _exit_tree() -> void:
	if _hud_presenter != null and _hud_presenter.has_method("shutdown"):
		_hud_presenter.shutdown()
	_runtime_probe = null
	_services = null
	_session_state = null


# 优先交由 HUD 处理输入，再落到世界控制器。
func _input(event: InputEvent) -> void:
	if _hud_presenter != null and _hud_presenter.has_method("handle_input"):
		if bool(_hud_presenter.handle_input(event)):
			return
	_world_controller.handle_input(event)


# 未处理输入同样遵循 HUD 优先的链路。
func _unhandled_input(event: InputEvent) -> void:
	if _hud_presenter != null and _hud_presenter.has_method("handle_unhandled_input"):
		if bool(_hud_presenter.handle_unhandled_input(event)):
			return
	_world_controller.handle_unhandled_input(event)


# 推进世界、协调器和 HUD 的逐帧逻辑。
func _process(delta: float) -> void:
	var scene_begin_us: int = _probe_begin_timing()
	var world_begin_us: int = _probe_begin_timing()
	_world_controller.process_world(delta)
	_probe_commit_timing(PROBE_SCOPE_WORLD_PROCESS, world_begin_us)
	if _coordinator != null and _coordinator.has_method("process_runtime"):
		var coordinator_begin_us: int = _probe_begin_timing()
		_coordinator.process_runtime(delta)
		_probe_commit_timing(PROBE_SCOPE_COORDINATOR_PROCESS, coordinator_begin_us)
	if _hud_presenter != null and _hud_presenter.has_method("process_hud"):
		var hud_begin_us: int = _probe_begin_timing()
		_hud_presenter.process_hud(delta)
		_probe_commit_timing(PROBE_SCOPE_HUD_PROCESS, hud_begin_us)
	_probe_commit_timing(PROBE_SCOPE_SCENE_PROCESS, scene_begin_us)
	if _runtime_probe != null and _runtime_probe.has_method("mark_frame"):
		_runtime_probe.mark_frame(delta, float(Engine.get_frames_per_second()))
		if _runtime_probe.has_method("should_sample_now") and bool(_runtime_probe.should_sample_now()):
			_sample_runtime_probe_counters()


# 调试绘制统一委托给世界控制器。
func _draw() -> void:
	_world_controller.draw_overlay(self)


# 返回场景引用集合。
func get_scene_refs() -> Node:
	return _scene_refs


# 返回战场会话状态。
func get_session_state() -> RefCounted:
	return _session_state


# 返回主协调器。
func get_coordinator() -> Node:
	return _coordinator


# 返回世界控制器。
func get_world_controller() -> Node:
	return _world_controller


# 返回 HUD 展示层入口。
func get_hud_presenter() -> Node:
	return _hud_presenter


# 统一向 runtime probe 申请计时起点，避免每个调用点重复判空。
func _probe_begin_timing() -> int:
	if _runtime_probe == null or not _runtime_probe.has_method("begin_timing"):
		return 0
	return int(_runtime_probe.begin_timing())


# 统一提交分段耗时，保持场景层探针口径单一。
func _probe_commit_timing(scope_name: String, begin_us: int) -> void:
	if _runtime_probe == null or not _runtime_probe.has_method("commit_timing"):
		return
	_runtime_probe.commit_timing(scope_name, begin_us)


# 低频采样单位/VFX 活跃数量，用于解释帧耗时分布。
func _sample_runtime_probe_counters() -> void:
	if _runtime_probe == null or not _runtime_probe.has_method("record_sample"):
		return
	if _session_state == null:
		return
	var counters: Dictionary = {
		"total_units": 0,
		"visible_units": 0,
		"combat_units": 0,
		"dragging_units": 0,
		"moving_units": 0,
		"unit_process_active": 0,
		"animator_process_active": 0,
		"quick_step_tween_active": 0,
		"animator_tween_active": 0
	}
	_sample_runtime_probe_units(_session_state.ally_deployed.values(), counters)
	_sample_runtime_probe_units(_session_state.enemy_deployed.values(), counters)
	_runtime_probe.record_sample("ally_units", float(_session_state.ally_deployed.size()))
	_runtime_probe.record_sample("enemy_units", float(_session_state.enemy_deployed.size()))
	_runtime_probe.record_sample("bench_units", float(_sample_bench_unit_count()))
	for counter_key in counters.keys():
		_runtime_probe.record_sample(counter_key, float(counters[counter_key]))
	var vfx_factory: Node = null
	if _scene_refs != null:
		vfx_factory = _scene_refs.get("vfx_factory") as Node
	if vfx_factory != null and vfx_factory.has_method("get_runtime_activity_snapshot"):
		var vfx_snapshot: Dictionary = vfx_factory.get_runtime_activity_snapshot()
		_runtime_probe.record_sample("vfx_active_texts", float(vfx_snapshot.get("active_texts", 0)))
		_runtime_probe.record_sample("vfx_active_particles", float(vfx_snapshot.get("active_particles", 0)))


# 逐个统计单位是否可见、是否移动、是否仍在跑动画。
func _sample_runtime_probe_units(units: Array, counters: Dictionary) -> void:
	for unit_value in units:
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		counters["total_units"] = int(counters.get("total_units", 0)) + 1
		if unit.is_processing():
			counters["unit_process_active"] = int(counters.get("unit_process_active", 0)) + 1
		if bool(unit.get("is_in_combat")):
			counters["combat_units"] = int(counters.get("combat_units", 0)) + 1
		if bool(unit.get("is_dragging")):
			counters["dragging_units"] = int(counters.get("dragging_units", 0)) + 1
		var canvas_item: CanvasItem = unit as CanvasItem
		if canvas_item != null and canvas_item.visible:
			counters["visible_units"] = int(counters.get("visible_units", 0)) + 1
		var movement: Node = unit.get_node_or_null("Components/UnitMovement")
		if movement != null and bool(movement.get("has_target")):
			counters["moving_units"] = int(counters.get("moving_units", 0)) + 1
		var animator: Node = unit.get_node_or_null("SpriteAnimator")
		if animator != null and animator.is_processing():
			counters["animator_process_active"] = int(counters.get("animator_process_active", 0)) + 1
		var quick_step_tween: Variant = unit.get("_quick_step_tween")
		if quick_step_tween is Tween and (quick_step_tween as Tween).is_valid():
			counters["quick_step_tween_active"] = int(counters.get("quick_step_tween_active", 0)) + 1
		if animator != null:
			var animator_tween: Variant = animator.get("_tween")
			if animator_tween is Tween and (animator_tween as Tween).is_valid():
				counters["animator_tween_active"] = int(counters.get("animator_tween_active", 0)) + 1


# 备战席数量单独采样，便于确认局内是否还有隐藏单位残留。
func _sample_bench_unit_count() -> int:
	if _scene_refs == null:
		return 0
	var bench_ui: Node = _scene_refs.get("bench_ui") as Node
	if bench_ui == null:
		return 0
	if not bench_ui.has_method("get_all_units"):
		return 0
	var bench_units: Array = bench_ui.get_all_units()
	var count: int = 0
	for unit_value in bench_units:
		if unit_value is Node and is_instance_valid(unit_value):
			count += 1
	return count
