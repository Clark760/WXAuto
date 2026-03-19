extends Node

# ===========================
# 角色移动组件（M1 占位实现）
# ===========================
# 说明：
# - M1 仅做“基础移动目标管理”，用于拖拽部署后的位置过渡。
# - M2 会在此基础上接入战斗寻路（流场/导航）与逻辑帧更新。

var owner_unit: Node = null
var move_target: Vector2 = Vector2.ZERO
var has_target: bool = false
var move_speed: float = 140.0


func bind_unit(unit: Node) -> void:
	owner_unit = unit


func reset_from_stats(runtime_stats: Dictionary) -> void:
	move_speed = maxf(float(runtime_stats.get("mov", 90.0)), 10.0)
	move_target = Vector2.ZERO
	has_target = false


func set_target(target_position: Vector2) -> void:
	move_target = target_position
	has_target = true


func clear_target() -> void:
	has_target = false


func tick(delta: float) -> void:
	if owner_unit == null or not has_target:
		return

	var unit_node: Node2D = owner_unit as Node2D
	if unit_node == null:
		return

	var to_target: Vector2 = move_target - unit_node.global_position
	var distance: float = to_target.length()
	if distance <= 1.0:
		unit_node.global_position = move_target
		has_target = false
		return

	var step: float = move_speed * delta
	var direction: Vector2 = to_target / maxf(distance, 0.0001)
	unit_node.global_position += direction * minf(step, distance)

