extends RefCounted
class_name BaseMechanic

# ===========================
# Boss 机制策略基类（M5）
# ===========================
# 设计目标：
# 1. 提供统一生命周期：setup/tick/cleanup；
# 2. 对外只暴露小而稳的 helper，避免每个机制重复写样板代码；
# 3. 机制内部尽量通过 context 访问战场与战斗管理器，保持低耦合。

var config: Dictionary = {}
var context: Dictionary = {}
var is_active: bool = false


func setup(mechanic_config: Dictionary, mechanic_context: Dictionary) -> void:
	config = mechanic_config.duplicate(true)
	context = mechanic_context
	is_active = true


func tick(_delta: float, _runtime_context: Dictionary) -> void:
	pass


func on_damage_resolved(_event: Dictionary, _runtime_context: Dictionary) -> void:
	pass


func on_unit_died(_unit: Node, _killer: Node, _team_id: int, _runtime_context: Dictionary) -> void:
	pass


func cleanup() -> void:
	is_active = false


func _get_battlefield() -> Node:
	var field_value: Variant = context.get("battlefield", null)
	return field_value as Node


func _get_combat_manager() -> Node:
	var combat_value: Variant = context.get("combat_manager", null)
	return combat_value as Node


func _get_hex_grid() -> Node:
	var grid_value: Variant = context.get("hex_grid", null)
	return grid_value as Node


func _get_unit_factory() -> Node:
	var factory_value: Variant = context.get("unit_factory", null)
	return factory_value as Node


func _get_primary_boss_unit() -> Node:
	var battlefield: Node = _get_battlefield()
	if battlefield == null or not is_instance_valid(battlefield):
		return null
	if battlefield.has_method("get_primary_boss_unit"):
		var candidate: Variant = battlefield.call("get_primary_boss_unit")
		if candidate is Node:
			return candidate as Node
	return null


func _get_logic_time() -> float:
	var combat_manager: Node = _get_combat_manager()
	if combat_manager == null or not is_instance_valid(combat_manager):
		return 0.0
	if combat_manager.has_method("get_logic_time"):
		return float(combat_manager.call("get_logic_time"))
	return 0.0


func _is_unit_alive(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var combat: Node = _get_unit_combat(unit)
	if combat == null:
		return false
	return bool(combat.get("is_alive"))


func _get_unit_combat(unit: Node) -> Node:
	if unit == null or not is_instance_valid(unit):
		return null
	return unit.get_node_or_null("Components/UnitCombat")


func _append_log(message: String) -> void:
	var battlefield: Node = _get_battlefield()
	if battlefield == null or not is_instance_valid(battlefield):
		return
	if battlefield.has_method("_append_battle_log"):
		battlefield.call("_append_battle_log", message, "system")


func _add_external_modifier(unit: Node, key: String, delta: float, min_value: float = -999.0, max_value: float = 999.0) -> void:
	var combat: Node = _get_unit_combat(unit)
	if combat == null:
		return
	if not combat.has_method("get_external_modifiers") or not combat.has_method("set_external_modifiers"):
		return
	var modifiers: Dictionary = combat.call("get_external_modifiers")
	var next_value: float = float(modifiers.get(key, 0.0)) + delta
	modifiers[key] = clampf(next_value, min_value, max_value)
	combat.call("set_external_modifiers", modifiers)


func _add_outgoing_damage_bonus(unit: Node, bonus_delta: float, min_value: float = -0.95, max_value: float = 10.0) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var old_bonus: float = float(unit.get_meta("stage_outgoing_damage_bonus", 0.0))
	unit.set_meta("stage_outgoing_damage_bonus", clampf(old_bonus + bonus_delta, min_value, max_value))


func _set_damage_taken_multiplier(unit: Node, multiplier: float) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	unit.set_meta("stage_damage_taken_multiplier", maxf(multiplier, 0.0))

