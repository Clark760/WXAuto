extends Node
class_name BossMechanicRunner

# ===========================
# Boss 机制运行器（M5）
# ===========================
# 职责：
# 1. 读取当前关卡 boss_mechanics 配置并实例化策略；
# 2. 在战斗进行时驱动 tick；
# 3. 分发战斗事件（damage_resolved / unit_died）到各机制。

const PHASE_SHIELD_MECHANIC_SCRIPT: Script = preload("res://scripts/stage/mechanics/phase_shield_mechanic.gd")
const SUMMON_WAVE_MECHANIC_SCRIPT: Script = preload("res://scripts/stage/mechanics/summon_wave_mechanic.gd")
const HAZARD_ZONES_MECHANIC_SCRIPT: Script = preload("res://scripts/stage/mechanics/hazard_zones_mechanic.gd")
const ENRAGE_TIMER_MECHANIC_SCRIPT: Script = preload("res://scripts/stage/mechanics/enrage_timer_mechanic.gd")

var _context: Dictionary = {}
var _active_mechanics: Array[BaseMechanic] = []
var _running: bool = false
var _connected_combat_manager: Node = null


func configure_context(
	battlefield: Node,
	combat_manager: Node,
	unit_factory: Node,
	hex_grid: Node,
	enemy_team_id: int = 2
) -> void:
	_context = {
		"battlefield": battlefield,
		"combat_manager": combat_manager,
		"unit_factory": unit_factory,
		"hex_grid": hex_grid,
		"enemy_team_id": enemy_team_id
	}
	_bind_combat_signals(combat_manager)


func start_stage_mechanics(stage_config: Dictionary) -> void:
	stop_all_mechanics()
	var mechanics_rows: Array[Dictionary] = _normalize_mechanics(stage_config.get("boss_mechanics", []))
	if mechanics_rows.is_empty():
		return
	for row in mechanics_rows:
		var mechanic_type: String = str(row.get("type", "")).strip_edges().to_lower()
		var mechanic: BaseMechanic = _create_mechanic(mechanic_type)
		if mechanic == null:
			continue
		var row_config: Dictionary = {}
		if row.get("config", null) is Dictionary:
			row_config = (row.get("config", {}) as Dictionary).duplicate(true)
		mechanic.setup(row_config, _context)
		_active_mechanics.append(mechanic)
	_running = not _active_mechanics.is_empty()


func stop_all_mechanics() -> void:
	for mechanic in _active_mechanics:
		if mechanic == null:
			continue
		mechanic.cleanup()
	_active_mechanics.clear()
	_running = false


func _process(delta: float) -> void:
	if not _running:
		return
	var combat_manager: Node = _context.get("combat_manager", null)
	if combat_manager == null or not is_instance_valid(combat_manager):
		return
	if not combat_manager.has_method("is_battle_running"):
		return
	if not bool(combat_manager.call("is_battle_running")):
		return
	for mechanic in _active_mechanics:
		if mechanic == null or not mechanic.is_active:
			continue
		mechanic.tick(delta, _context)


func _bind_combat_signals(combat_manager: Node) -> void:
	if _connected_combat_manager != null and is_instance_valid(_connected_combat_manager):
		_unbind_combat_signals(_connected_combat_manager)
	_connected_combat_manager = combat_manager
	if combat_manager == null or not is_instance_valid(combat_manager):
		return
	var damage_cb: Callable = Callable(self, "_on_damage_resolved")
	if combat_manager.has_signal("damage_resolved") and not combat_manager.is_connected("damage_resolved", damage_cb):
		combat_manager.connect("damage_resolved", damage_cb)
	var dead_cb: Callable = Callable(self, "_on_unit_died")
	if combat_manager.has_signal("unit_died") and not combat_manager.is_connected("unit_died", dead_cb):
		combat_manager.connect("unit_died", dead_cb)
	var end_cb: Callable = Callable(self, "_on_battle_ended")
	if combat_manager.has_signal("battle_ended") and not combat_manager.is_connected("battle_ended", end_cb):
		combat_manager.connect("battle_ended", end_cb)


func _unbind_combat_signals(combat_manager: Node) -> void:
	var damage_cb: Callable = Callable(self, "_on_damage_resolved")
	if combat_manager.has_signal("damage_resolved") and combat_manager.is_connected("damage_resolved", damage_cb):
		combat_manager.disconnect("damage_resolved", damage_cb)
	var dead_cb: Callable = Callable(self, "_on_unit_died")
	if combat_manager.has_signal("unit_died") and combat_manager.is_connected("unit_died", dead_cb):
		combat_manager.disconnect("unit_died", dead_cb)
	var end_cb: Callable = Callable(self, "_on_battle_ended")
	if combat_manager.has_signal("battle_ended") and combat_manager.is_connected("battle_ended", end_cb):
		combat_manager.disconnect("battle_ended", end_cb)


func _on_damage_resolved(event: Dictionary) -> void:
	if not _running:
		return
	for mechanic in _active_mechanics:
		if mechanic == null or not mechanic.is_active:
			continue
		mechanic.on_damage_resolved(event, _context)


func _on_unit_died(unit: Node, killer: Node, team_id: int) -> void:
	if not _running:
		return
	for mechanic in _active_mechanics:
		if mechanic == null or not mechanic.is_active:
			continue
		mechanic.on_unit_died(unit, killer, team_id, _context)


func _on_battle_ended(_winner_team: int, _summary: Dictionary) -> void:
	stop_all_mechanics()


func _normalize_mechanics(value: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var rows: Array = []
	if value is Array:
		rows = value
	elif value is Dictionary:
		rows = [value]
	else:
		return out
	for row_value in rows:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value
		var mechanic_type: String = str(row.get("type", "")).strip_edges().to_lower()
		if mechanic_type.is_empty():
			continue
		var mechanic_config: Dictionary = {}
		if row.get("config", null) is Dictionary:
			mechanic_config = (row.get("config", {}) as Dictionary).duplicate(true)
		out.append({
			"type": mechanic_type,
			"config": mechanic_config
		})
	return out


func _create_mechanic(mechanic_type: String) -> BaseMechanic:
	match mechanic_type:
		"phase_shield":
			return PHASE_SHIELD_MECHANIC_SCRIPT.new() as BaseMechanic
		"summon_wave":
			return SUMMON_WAVE_MECHANIC_SCRIPT.new() as BaseMechanic
		"hazard_zones":
			return HAZARD_ZONES_MECHANIC_SCRIPT.new() as BaseMechanic
		"enrage_timer":
			return ENRAGE_TIMER_MECHANIC_SCRIPT.new() as BaseMechanic
		_:
			return null

