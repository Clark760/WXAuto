extends Node
class_name BattleFlow

# ===========================
# 战斗流程扩展模块
# ===========================
# 设计目标：
# 1. 承接战斗统计采集与结算统计面板能力。
# 2. 通过独立模块监听 CombatManager / GongfaManager 事件，避免把统计逻辑堆回 Battlefield。
# 3. 保持 Battlefield 只负责场景编排，额外战斗流程由该模块集中维护。

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2

const BATTLE_STATISTICS_SCRIPT: Script = preload("res://scripts/battle/battle_statistics.gd")
const BATTLE_STATS_PANEL_SCRIPT: Script = preload("res://scripts/ui/battle_stats_panel.gd")

var _host_scene: Node = null
var _combat_manager: Node = null
var _gongfa_manager: Node = null
var _detail_layer: CanvasLayer = null

var _statistics: Node = null
var _stats_panel: PanelContainer = null
var _capture_running: bool = false
var _unit_lookup: Dictionary = {} # instance_id -> unit


func setup(host_scene: Node, combat_manager: Node, gongfa_manager: Node, detail_layer: CanvasLayer) -> void:
	_host_scene = host_scene
	_combat_manager = combat_manager
	_gongfa_manager = gongfa_manager
	_detail_layer = detail_layer
	_ensure_statistics_created()
	_ensure_stats_panel_created()
	_connect_signals()


func prepare_for_battle_start() -> void:
	_capture_running = false
	hide_stats_panel()


func start_battle_capture(ally_units: Array[Node], enemy_units: Array[Node]) -> void:
	if _statistics == null:
		return
	var all_units: Array[Node] = []
	_unit_lookup.clear()
	for unit in ally_units:
		_remember_unit(unit)
		all_units.append(unit)
	for unit in enemy_units:
		_remember_unit(unit)
		all_units.append(unit)
	_statistics.call("start_battle", all_units)
	_capture_running = true
	refresh_panel()


func refresh_layout() -> void:
	if _stats_panel == null or _host_scene == null:
		return
	var viewport_size: Vector2 = _host_scene.get_viewport().get_visible_rect().size
	_stats_panel.call("relayout", viewport_size)


func refresh_panel() -> void:
	if _stats_panel == null or not is_instance_valid(_stats_panel):
		return
	_stats_panel.call("refresh_content")


func hide_stats_panel() -> void:
	if _stats_panel == null or not is_instance_valid(_stats_panel):
		return
	_stats_panel.call("hide_panel")


func sync_stage(stage_value: int, result_stage: int) -> void:
	# 统计面板只在结算阶段显示；其余阶段统一隐藏。
	if stage_value != result_stage:
		hide_stats_panel()


func _ensure_statistics_created() -> void:
	if _statistics != null and is_instance_valid(_statistics):
		return
	_statistics = BATTLE_STATISTICS_SCRIPT.new() as Node
	_statistics.name = "RuntimeBattleStatistics"
	add_child(_statistics)


func _ensure_stats_panel_created() -> void:
	if _stats_panel != null and is_instance_valid(_stats_panel):
		return
	if _detail_layer == null:
		return
	_stats_panel = BATTLE_STATS_PANEL_SCRIPT.new() as PanelContainer
	if _stats_panel == null:
		return
	_stats_panel.name = "BattleStatsPanel"
	_detail_layer.add_child(_stats_panel)
	_stats_panel.call("bind_statistics", _statistics)
	refresh_layout()


func _connect_signals() -> void:
	if _statistics != null:
		var stat_cb: Callable = Callable(self, "_on_battle_stat_updated")
		if _statistics.has_signal("battle_stat_updated") and not _statistics.is_connected("battle_stat_updated", stat_cb):
			_statistics.connect("battle_stat_updated", stat_cb)

	if _combat_manager != null:
		var damage_cb: Callable = Callable(self, "_on_damage_resolved")
		if _combat_manager.has_signal("damage_resolved") and not _combat_manager.is_connected("damage_resolved", damage_cb):
			_combat_manager.connect("damage_resolved", damage_cb)
		var dead_cb: Callable = Callable(self, "_on_unit_died")
		if _combat_manager.has_signal("unit_died") and not _combat_manager.is_connected("unit_died", dead_cb):
			_combat_manager.connect("unit_died", dead_cb)
		var end_cb: Callable = Callable(self, "_on_battle_ended")
		if _combat_manager.has_signal("battle_ended") and not _combat_manager.is_connected("battle_ended", end_cb):
			_combat_manager.connect("battle_ended", end_cb)

	if _gongfa_manager != null:
		var skill_damage_cb: Callable = Callable(self, "_on_skill_effect_damage")
		if _gongfa_manager.has_signal("skill_effect_damage") and not _gongfa_manager.is_connected("skill_effect_damage", skill_damage_cb):
			_gongfa_manager.connect("skill_effect_damage", skill_damage_cb)
		var skill_heal_cb: Callable = Callable(self, "_on_skill_effect_heal")
		if _gongfa_manager.has_signal("skill_effect_heal") and not _gongfa_manager.is_connected("skill_effect_heal", skill_heal_cb):
			_gongfa_manager.connect("skill_effect_heal", skill_heal_cb)


func _on_damage_resolved(event_dict: Dictionary) -> void:
	if not _capture_running or _statistics == null:
		return
	var damage_value: int = int(round(float(event_dict.get("damage", 0.0))))
	if damage_value <= 0:
		return
	var source_unit: Node = _find_unit_by_instance_id(int(event_dict.get("source_id", -1)))
	var target_unit: Node = _find_unit_by_instance_id(int(event_dict.get("target_id", -1)))
	_statistics.call("record_damage", source_unit, target_unit, damage_value)


func _on_skill_effect_damage(event_dict: Dictionary) -> void:
	if not _capture_running or _statistics == null:
		return
	var damage_value: int = int(round(float(event_dict.get("damage", 0.0))))
	if damage_value <= 0:
		return
	var source_unit: Node = event_dict.get("source", null)
	var target_unit: Node = event_dict.get("target", null)
	_remember_unit(source_unit)
	_remember_unit(target_unit)
	_statistics.call("record_damage", source_unit, target_unit, damage_value)


func _on_skill_effect_heal(event_dict: Dictionary) -> void:
	if not _capture_running or _statistics == null:
		return
	var heal_value: int = int(round(float(event_dict.get("heal", 0.0))))
	if heal_value <= 0:
		return
	var source_unit: Node = event_dict.get("source", null)
	var target_unit: Node = event_dict.get("target", null)
	_remember_unit(source_unit)
	_remember_unit(target_unit)
	_statistics.call("record_healing", source_unit, target_unit, heal_value)


func _on_unit_died(dead_unit: Node, killer: Node, _team_id: int) -> void:
	if not _capture_running or _statistics == null:
		return
	_remember_unit(dead_unit)
	_remember_unit(killer)
	_statistics.call("record_kill", killer, dead_unit)


func _on_battle_ended(_winner_team: int, _summary: Dictionary) -> void:
	_capture_running = false
	refresh_layout()
	if _stats_panel != null and is_instance_valid(_stats_panel):
		_stats_panel.call("show_panel", TEAM_ALLY)


func _on_battle_stat_updated(_unit_instance_id: int, _stat_type: String, _value: int) -> void:
	if _stats_panel == null or not is_instance_valid(_stats_panel):
		return
	if not _stats_panel.visible:
		return
	_stats_panel.call("refresh_content")


func _remember_unit(unit: Variant) -> void:
	if not _is_valid_unit(unit):
		return
	var node: Node = unit as Node
	_unit_lookup[node.get_instance_id()] = node


func _find_unit_by_instance_id(instance_id: int) -> Node:
	if instance_id <= 0:
		return null
	if _unit_lookup.has(instance_id):
		return _unit_lookup[instance_id] as Node
	return null


func _is_valid_unit(unit: Variant) -> bool:
	if not is_instance_valid(unit):
		return false
	return (unit as Node) != null
