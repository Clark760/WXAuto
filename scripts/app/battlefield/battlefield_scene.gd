extends Node2D
class_name BattlefieldScene

# ===========================
# 战场组合入口
# ===========================
# 说明：
# 1. 根场景只负责收集引用、创建状态、初始化协作者、暴露只读 getter。
# 2. Phase 2 中根场景只做输入/绘制转发，不再把世界交互塞回入口脚本。

const BATTLEFIELD_SESSION_STATE_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_session_state.gd"
)

# 组合对象显式挂在场景树上，根场景只持有引用，不继续吞掉实现。
@onready var _scene_refs: Node = $BattlefieldSceneRefs
@onready var _coordinator: Node = $BattlefieldCoordinator
@onready var _world_controller: Node = $BattlefieldWorldController
@onready var _hud_presenter: Node = $BattlefieldHudPresenter

# `RefCounted` 足够承接会话状态；这里不对外暴露可写字段。
var _session_state: RefCounted = null
var _batch1_ready: bool = false
var _batch2_world_ready: bool = false


# 这里是新入口唯一允许的初始化顺序：
# 1. 创建状态
# 2. 采集显式引用
# 3. 初始化协作者
# 4. 对外暴露只读结构状态
func _ready() -> void:
	_session_state = BATTLEFIELD_SESSION_STATE_SCRIPT.new()
	_scene_refs.bind_from_scene(self)
	_coordinator.initialize(self, _scene_refs, _session_state)
	_hud_presenter.initialize(self, _scene_refs, _session_state)
	_world_controller.initialize(self, _scene_refs, _session_state)
	if _coordinator.has_method("start_session"):
		_coordinator.start_session()
	_session_state.mark_scene_ready()
	_batch1_ready = (
		_scene_refs.has_required_scene_nodes()
		and _scene_refs.has_required_runtime_nodes()
		and _coordinator.is_initialized()
		and _world_controller.is_initialized()
		and _hud_presenter.is_initialized()
	)
	_batch2_world_ready = _world_controller.is_batch2_ready()


# 根场景只转发输入，不在这里重新写世界交互分支。
func _input(event: InputEvent) -> void:
	if _hud_presenter != null and _hud_presenter.has_method("handle_input"):
		if bool(_hud_presenter.handle_input(event)):
			return
	_world_controller.handle_input(event)


# 键盘补充输入同样交给 world controller，避免根场景重新长出阶段逻辑。
func _unhandled_input(event: InputEvent) -> void:
	if _hud_presenter != null and _hud_presenter.has_method("handle_unhandled_input"):
		if bool(_hud_presenter.handle_unhandled_input(event)):
			return
	_world_controller.handle_unhandled_input(event)


# 世界控制器在这里获得逐帧驱动，根场景不直接维护世界态。
func _process(delta: float) -> void:
	_world_controller.process_world(delta)
	if _coordinator != null and _coordinator.has_method("process_runtime"):
		_coordinator.process_runtime(delta)
	if _hud_presenter != null and _hud_presenter.has_method("process_hud"):
		_hud_presenter.process_hud(delta)


# 拖拽落点描边仍由根节点绘制，但绘制决策完全交给 world controller。
func _draw() -> void:
	_world_controller.draw_overlay(self)


# 读取 refs 的场景和测试都应该走这个入口，避免直接持有子节点路径。
func get_scene_refs() -> Node:
	return _scene_refs


# 会话状态只读暴露给测试和过渡层，实际迁移时仍由根场景持有。
func get_session_state() -> RefCounted:
	return _session_state


# 编排协调器通过 getter 暴露，后续测试不再依赖根场景私有字段。
func get_coordinator() -> Node:
	return _coordinator


# 世界控制器通过 getter 暴露，便于后续 smoke test 与批次迁移校验。
func get_world_controller() -> Node:
	return _world_controller


# HUD presenter 通过 getter 暴露，避免测试直接写死子节点路径。
func get_hud_presenter() -> Node:
	return _hud_presenter


# Batch 1 只回答“组合骨架是否就位”，不承担玩法正确性的验收。
func is_batch1_ready() -> bool:
	return _batch1_ready


# Batch 2 只回答世界控制器是否接管了交互骨架，不代表 HUD/编排已迁完。
func is_batch2_world_ready() -> bool:
	return _batch2_world_ready
