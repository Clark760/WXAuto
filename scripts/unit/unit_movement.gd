extends Node

# ===========================
# 角色移动组件
# ===========================
# 说明：
# 1. 组件保留“目标点移动”接口，统一处理拖拽归位与战场位移。
# 2. 格子化战斗后，CombatManager 直接下发“目标格心坐标”。
# 3. 真实位移仍在渲染帧执行，形成“逻辑决策低频 + 渲染平滑高频”的分层。

var owner_unit: Node = null
var move_target: Vector2 = Vector2.ZERO
var has_target: bool = false
@export var base_move_speed: float = 140.0
var move_speed: float = 140.0


func bind_unit(unit: Node) -> void:
	owner_unit = unit
	_notify_owner_process_state()


func reset_from_stats(_runtime_stats: Dictionary) -> void:
	# 移动速度统一由组件固定参数控制。
	move_speed = maxf(base_move_speed, 10.0)
	move_target = Vector2.ZERO
	has_target = false
	_notify_owner_process_state()


func refresh_runtime_stats(_runtime_stats: Dictionary) -> void:
	# 刷新时保持固定移速。
	move_speed = maxf(base_move_speed, 10.0)


func set_target(target_position: Vector2) -> void:
	move_target = target_position
	has_target = true
	# 严格六角格模式：target_position 必须是“目标格心”的世界坐标。
	_notify_owner_process_state()


func clear_target() -> void:
	has_target = false
	_notify_owner_process_state()


func tick(delta: float) -> void:
	if owner_unit == null or not is_instance_valid(owner_unit):
		return
	if not has_target:
		return

	var unit_node: Node2D = owner_unit as Node2D
	if unit_node == null:
		return

	var to_target: Vector2 = move_target - unit_node.position
	var distance: float = to_target.length()
	if distance <= 1.0:
		unit_node.position = move_target
		has_target = false
		_notify_owner_process_state()
		return

	var step: float = move_speed * delta
	var direction: Vector2 = to_target / maxf(distance, 0.0001)
	unit_node.position += direction * minf(step, distance)


func _notify_owner_process_state() -> void:
	if owner_unit == null or not is_instance_valid(owner_unit):
		return
	if owner_unit.has_method("refresh_process_state"):
		owner_unit.call("refresh_process_state")
