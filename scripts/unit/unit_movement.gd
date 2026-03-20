extends Node

# ===========================
# 角色移动组件
# ===========================
# 说明：
# 1. 组件保留“目标点移动”接口，统一处理拖拽归位与战场位移。
# 2. 支持“流场方向输入”，供 CombatManager 在逻辑帧里推送群体移动意图。
# 3. 真实位移仍在渲染帧执行，形成“逻辑决策低频 + 渲染平滑高频”的分层。

var owner_unit: Node = null
var move_target: Vector2 = Vector2.ZERO
var has_target: bool = false
var move_speed: float = 140.0

var _flow_direction: Vector2 = Vector2.ZERO
var _flow_step_distance: float = 28.0


func bind_unit(unit: Node) -> void:
	owner_unit = unit
	_notify_owner_process_state()


func reset_from_stats(runtime_stats: Dictionary) -> void:
	move_speed = maxf(float(runtime_stats.get("mov", 90.0)), 10.0)
	move_target = Vector2.ZERO
	has_target = false
	_flow_direction = Vector2.ZERO
	_flow_step_distance = 28.0
	_notify_owner_process_state()


func refresh_runtime_stats(runtime_stats: Dictionary) -> void:
	# 动态属性更新时仅刷新移速，不重置当前移动目标，避免战斗中抽搐。
	move_speed = maxf(float(runtime_stats.get("mov", move_speed)), 10.0)


func set_target(target_position: Vector2) -> void:
	move_target = target_position
	has_target = true
	_flow_direction = Vector2.ZERO
	_notify_owner_process_state()


func set_flow_direction(direction: Vector2, step_distance: float = 28.0) -> void:
	if owner_unit == null or not is_instance_valid(owner_unit):
		return

	var dir: Vector2 = direction.normalized()
	if dir.is_zero_approx():
		clear_target()
		return

	_flow_direction = dir
	_flow_step_distance = maxf(step_distance, 4.0)

	var unit_node: Node2D = owner_unit as Node2D
	# 战场统一使用 WorldContainer 本地坐标，避免全局坐标与 UI 缩放耦合。
	move_target = unit_node.position + _flow_direction * _flow_step_distance
	has_target = true
	_notify_owner_process_state()


func clear_target() -> void:
	has_target = false
	_flow_direction = Vector2.ZERO
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
