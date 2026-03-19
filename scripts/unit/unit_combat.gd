extends Node

# ===========================
# 角色战斗组件（M1 占位实现）
# ===========================
# 说明：
# - M1 重点是“角色组件化结构”，战斗细节会在 M2 完整实现。
# - 当前组件只维护最小战斗相关状态，供 UnitBase 和 UI 调试读取。

var owner_unit: Node = null
var is_alive: bool = true
var current_hp: float = 0.0
var current_mp: float = 0.0


func bind_unit(unit: Node) -> void:
	owner_unit = unit


func reset_from_stats(runtime_stats: Dictionary) -> void:
	current_hp = float(runtime_stats.get("hp", 1.0))
	current_mp = float(runtime_stats.get("mp", 0.0))
	is_alive = current_hp > 0.0


func apply_damage(amount: float) -> float:
	if not is_alive:
		return 0.0

	var damage: float = maxf(amount, 0.0)
	current_hp = maxf(current_hp - damage, 0.0)
	if current_hp <= 0.0:
		is_alive = false
	return damage


func restore_hp(amount: float) -> void:
	if owner_unit == null:
		return
	var max_hp: float = float(owner_unit.get("runtime_stats").get("hp", 1.0))
	current_hp = minf(current_hp + maxf(amount, 0.0), max_hp)
	if current_hp > 0.0:
		is_alive = true


func add_mp(amount: float) -> void:
	if owner_unit == null:
		return
	var max_mp: float = float(owner_unit.get("runtime_stats").get("mp", 0.0))
	current_mp = clampf(current_mp + amount, 0.0, max_mp)

