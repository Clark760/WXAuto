extends SceneTree

const BATTLEFIELD_SCENE: PackedScene = preload("res://scenes/battle/battlefield.tscn")
const SINGLETON_SCRIPT_PATHS: Dictionary = {
	"EventBus": "res://scripts/core/event_bus.gd",
	"ObjectPool": "res://scripts/core/object_pool.gd",
	"DataManager": "res://scripts/data/data_manager.gd",
	"ModLoader": "res://scripts/core/mod_loader.gd",
	"GameManager": "res://scripts/core/game_manager.gd",
	"GongfaManager": "res://scripts/gongfa/gongfa_manager.gd"
}

const ALLY_UNIT_IDS: Array[String] = [
	"unit_m5_test_ally_poison",
	"unit_m5_test_ally_fire",
	"unit_m5_test_ally_ice",
	"unit_m5_test_ally_heal",
	"unit_m5_test_ally_mark"
]

const ENEMY_UNIT_IDS: Array[String] = [
	"unit_m5_test_enemy_poison",
	"unit_m5_test_enemy_thunder",
	"unit_m5_test_enemy_ice",
	"unit_m5_test_enemy_tank",
	"unit_m5_test_enemy_mark"
]

const ALLY_CELLS: Array[Vector2i] = [
	Vector2i(14, 5),
	Vector2i(14, 6),
	Vector2i(14, 7),
	Vector2i(13, 6),
	Vector2i(13, 7)
]

const ENEMY_CELLS: Array[Vector2i] = [
	Vector2i(17, 5),
	Vector2i(17, 6),
	Vector2i(17, 7),
	Vector2i(18, 6),
	Vector2i(18, 7)
]

const REQUIRED_GONGFA_IDS: Array[String] = [
	"gongfa_wudu_shou",
	"gongfa_lie_yan_zhang",
	"gongfa_han_bing_jue",
	"gongfa_cihang_jian",
	"gongfa_poying_jian",
	"gongfa_shixiang_ban",
	"gongfa_kuanglei_zhang",
	"gongfa_xuanming_shen",
	"gongfa_gui_xi_gong"
]

const REQUIRED_EQUIPMENT_IDS: Array[String] = [
	"eq_bixie_sword",
	"eq_duchangjian",
	"eq_hanbingmian",
	"eq_liuhuoyi",
	"eq_pojia_chuizi",
	"eq_xixue_jie",
	"eq_huiqi_zhu",
	"eq_zhanshen_kai",
	"eq_zhanshazhui",
	"eq_guiyuan_zhen",
	"eq_fenglei_huan",
	"eq_dihuo_jia",
	"eq_fenix_yu"
]

const TEST_TIMEOUT_SECONDS: float = 70.0

var _battlefield: Node = null
var _combat_manager: Node = null
var _gongfa_manager: Node = null
var _unit_factory: Node = null
var _hex_grid: Node = null

var _battle_done: bool = false
var _failed: bool = false
var _result: Dictionary = {
	"battle_started": false,
	"battle_ended": false,
	"winner_team": 0,
	"battle_summary": {},
	"damage_events": 0,
	"environment_damage_events": 0,
	"skill_triggers": 0,
	"skill_effect_damage_events": 0,
	"skill_effect_heal_events": 0,
	"buff_events": 0,
	"terrain_max_instances": 0,
	"terrain_max_cells": 0,
	"trigger_counts": {},
	"buff_apply_counts": {},
	"data_summary": {}
}


func _init() -> void:
	print("[m5_replay] init")
	await _run()


func _run() -> void:
	print("[m5_replay] run begin")
	await _ensure_runtime_singletons()
	print("[m5_replay] singletons ready")
	var data_manager: Node = _get_root_node("DataManager")
	if data_manager == null:
		_fail("DataManager autoload is missing.")
		return

	_result["data_summary"] = data_manager.call("load_base_data")
	print("[m5_replay] data loaded")
	_gongfa_manager = _get_root_node("GongfaManager")
	if _gongfa_manager != null and _gongfa_manager.has_method("reload_from_data"):
		_gongfa_manager.call("reload_from_data")
	await process_frame
	print("[m5_replay] gongfa reloaded")

	if not _validate_required_records(data_manager):
		_fail("Required M5 test records are missing after data load.")
		return

	_battlefield = BATTLEFIELD_SCENE.instantiate()
	root.add_child(_battlefield)
	await process_frame
	await process_frame
	print("[m5_replay] battlefield ready")

	_combat_manager = _battlefield.get_node_or_null("CombatManager")
	_unit_factory = _battlefield.get_node_or_null("UnitFactory")
	_hex_grid = _battlefield.get("hex_grid")
	if _combat_manager == null or _unit_factory == null or _hex_grid == null:
		_fail("Battlefield dependencies are not ready.")
		return

	_connect_runtime_signals()
	_cleanup_scene_runtime()

	if not _deploy_test_units():
		_fail("Failed to deploy test units for replay.")
		return
	print("[m5_replay] units deployed")

	var ally_units: Array[Node] = _battlefield.call("_collect_units_from_map", _battlefield.get("_ally_deployed"))
	var enemy_units: Array[Node] = _battlefield.call("_collect_units_from_map", _battlefield.get("_enemy_deployed"))
	if ally_units.is_empty() or enemy_units.is_empty():
		_fail("Deployed unit lists are empty, cannot start replay.")
		return

	if _gongfa_manager != null:
		_gongfa_manager.call(
			"prepare_battle",
			ally_units,
			enemy_units,
			_battlefield.get("hex_grid"),
			_battlefield.get("vfx_factory"),
			_combat_manager
		)

	var started: bool = bool(_combat_manager.call("start_battle", ally_units, enemy_units, 20260322))
	if not started:
		_fail("CombatManager failed to start battle replay.")
		return
	print("[m5_replay] battle started")

	for ally in ally_units:
		if ally != null and is_instance_valid(ally):
			ally.call("enter_combat")
	for enemy in enemy_units:
		if enemy != null and is_instance_valid(enemy):
			enemy.call("enter_combat")
	_battlefield.call("_set_stage", 1) # Stage.COMBAT

	var start_ms: int = Time.get_ticks_msec()
	var timeout_ms: int = int(TEST_TIMEOUT_SECONDS * 1000.0)
	while not _battle_done and (Time.get_ticks_msec() - start_ms) < timeout_ms:
		_sample_terrain_cells()
		await process_frame

	if not _battle_done:
		_result["battle_ended"] = false
		_result["battle_summary"] = {"reason": "timeout"}
		_combat_manager.call("stop_battle", "timeout", 0)
		await process_frame
		print("[m5_replay] timeout stop issued")

	_sample_terrain_cells()
	_emit_report()

	if _evaluate_pass():
		print("M5 replay check passed.")
		quit(0)
		return
	_fail("M5 replay check failed.")


func _validate_required_records(data_manager: Node) -> bool:
	for unit_id in ALLY_UNIT_IDS:
		if (data_manager.call("get_record", "units", unit_id) as Dictionary).is_empty():
			push_error("Missing unit record: %s" % unit_id)
			return false
	for unit_id2 in ENEMY_UNIT_IDS:
		if (data_manager.call("get_record", "units", unit_id2) as Dictionary).is_empty():
			push_error("Missing unit record: %s" % unit_id2)
			return false
	for gongfa_id in REQUIRED_GONGFA_IDS:
		if (data_manager.call("get_record", "gongfa", gongfa_id) as Dictionary).is_empty():
			push_error("Missing gongfa record: %s" % gongfa_id)
			return false
	for equip_id in REQUIRED_EQUIPMENT_IDS:
		if (data_manager.call("get_record", "equipment", equip_id) as Dictionary).is_empty():
			push_error("Missing equipment record: %s" % equip_id)
			return false
	return true


func _connect_runtime_signals() -> void:
	if _combat_manager != null:
		var start_cb: Callable = Callable(self, "_on_battle_started")
		if _combat_manager.has_signal("battle_started") and not _combat_manager.is_connected("battle_started", start_cb):
			_combat_manager.connect("battle_started", start_cb)
		var end_cb: Callable = Callable(self, "_on_battle_ended")
		if _combat_manager.has_signal("battle_ended") and not _combat_manager.is_connected("battle_ended", end_cb):
			_combat_manager.connect("battle_ended", end_cb)
		var damage_cb: Callable = Callable(self, "_on_damage_resolved")
		if _combat_manager.has_signal("damage_resolved") and not _combat_manager.is_connected("damage_resolved", damage_cb):
			_combat_manager.connect("damage_resolved", damage_cb)

	if _gongfa_manager != null:
		var trigger_cb: Callable = Callable(self, "_on_skill_triggered")
		if _gongfa_manager.has_signal("skill_triggered") and not _gongfa_manager.is_connected("skill_triggered", trigger_cb):
			_gongfa_manager.connect("skill_triggered", trigger_cb)
		var skill_damage_cb: Callable = Callable(self, "_on_skill_effect_damage")
		if _gongfa_manager.has_signal("skill_effect_damage") and not _gongfa_manager.is_connected("skill_effect_damage", skill_damage_cb):
			_gongfa_manager.connect("skill_effect_damage", skill_damage_cb)
		var skill_heal_cb: Callable = Callable(self, "_on_skill_effect_heal")
		if _gongfa_manager.has_signal("skill_effect_heal") and not _gongfa_manager.is_connected("skill_effect_heal", skill_heal_cb):
			_gongfa_manager.connect("skill_effect_heal", skill_heal_cb)
		var buff_cb: Callable = Callable(self, "_on_buff_event")
		if _gongfa_manager.has_signal("buff_event") and not _gongfa_manager.is_connected("buff_event", buff_cb):
			_gongfa_manager.connect("buff_event", buff_cb)


func _cleanup_scene_runtime() -> void:
	var bench_ui: Node = _battlefield.get("bench_ui")
	if bench_ui != null and bench_ui.has_method("get_all_units") and bench_ui.has_method("remove_unit"):
		var bench_units: Array = bench_ui.call("get_all_units")
		for unit_value in bench_units:
			if not (unit_value is Node):
				continue
			var unit: Node = unit_value as Node
			bench_ui.call("remove_unit", unit)
			if _unit_factory != null:
				_unit_factory.call("release_unit", unit)

	_clear_map_units("_ally_deployed")
	_clear_map_units("_enemy_deployed")
	_battlefield.call("_refresh_multimesh")
	_battlefield.call("_refresh_all_ui")


func _clear_map_units(map_property: String) -> void:
	var map_value: Variant = _battlefield.get(map_property)
	if not (map_value is Dictionary):
		return
	var deployed_map: Dictionary = map_value
	for unit_value in deployed_map.values():
		if not (unit_value is Node):
			continue
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		if _unit_factory != null:
			_unit_factory.call("release_unit", unit)
	deployed_map.clear()
	_battlefield.set(map_property, deployed_map)


func _deploy_test_units() -> bool:
	if ALLY_UNIT_IDS.size() != ALLY_CELLS.size() or ENEMY_UNIT_IDS.size() != ENEMY_CELLS.size():
		push_error("M5 replay config mismatch: unit ids and deploy cells size mismatch.")
		return false

	var unit_layer: Node = _battlefield.get("unit_layer")
	if unit_layer == null:
		return false

	for i in range(ALLY_UNIT_IDS.size()):
		var unit_id: String = ALLY_UNIT_IDS[i]
		var unit: Node = _unit_factory.call("acquire_unit", unit_id, 1, unit_layer)
		if unit == null:
			push_error("Acquire ally unit failed: %s" % unit_id)
			return false
		_battlefield.call("_deploy_ally_unit_to_cell", unit, ALLY_CELLS[i])

	for j in range(ENEMY_UNIT_IDS.size()):
		var unit_id2: String = ENEMY_UNIT_IDS[j]
		var unit2: Node = _unit_factory.call("acquire_unit", unit_id2, 1, unit_layer)
		if unit2 == null:
			push_error("Acquire enemy unit failed: %s" % unit_id2)
			return false
		_battlefield.call("_deploy_enemy_unit_to_cell", unit2, ENEMY_CELLS[j])

	_battlefield.call("_refresh_multimesh")
	_battlefield.call("_refresh_all_ui")
	return true


func _sample_terrain_cells() -> void:
	if _combat_manager == null or _hex_grid == null:
		return
	var terrain_manager: Variant = _combat_manager.get("_terrain_manager")
	if not (terrain_manager is Node):
		return
	var terrains_value: Variant = (terrain_manager as Node).get("_terrains")
	if terrains_value is Array:
		var max_instances: int = int(_result.get("terrain_max_instances", 0))
		var terrain_count: int = (terrains_value as Array).size()
		if terrain_count > max_instances:
			_result["terrain_max_instances"] = terrain_count
	var cells_value: Variant = (terrain_manager as Node).call("get_visual_cells", _hex_grid)
	if not (cells_value is Dictionary):
		return
	var cell_count: int = (cells_value as Dictionary).size()
	var old_max: int = int(_result.get("terrain_max_cells", 0))
	if cell_count > old_max:
		_result["terrain_max_cells"] = cell_count


func _on_battle_started(_ally_count: int, _enemy_count: int) -> void:
	_result["battle_started"] = true


func _on_battle_ended(winner_team: int, summary: Dictionary) -> void:
	_result["battle_ended"] = true
	_result["winner_team"] = winner_team
	_result["battle_summary"] = summary.duplicate(true)
	_battle_done = true


func _on_damage_resolved(event: Dictionary) -> void:
	_result["damage_events"] = int(_result.get("damage_events", 0)) + 1
	if bool(event.get("is_environment", false)):
		_result["environment_damage_events"] = int(_result.get("environment_damage_events", 0)) + 1


func _on_skill_triggered(_unit: Node, gongfa_id: String, _trigger: String) -> void:
	_result["skill_triggers"] = int(_result.get("skill_triggers", 0)) + 1
	_inc_counter("trigger_counts", gongfa_id)


func _on_skill_effect_damage(_event: Dictionary) -> void:
	_result["skill_effect_damage_events"] = int(_result.get("skill_effect_damage_events", 0)) + 1


func _on_skill_effect_heal(_event: Dictionary) -> void:
	_result["skill_effect_heal_events"] = int(_result.get("skill_effect_heal_events", 0)) + 1


func _on_buff_event(event: Dictionary) -> void:
	_result["buff_events"] = int(_result.get("buff_events", 0)) + 1
	_inc_counter("buff_apply_counts", str(event.get("buff_id", "")))


func _inc_counter(counter_key: String, item_key: String) -> void:
	if item_key.strip_edges().is_empty():
		return
	var counters: Dictionary = _result.get(counter_key, {})
	counters[item_key] = int(counters.get(item_key, 0)) + 1
	_result[counter_key] = counters


func _evaluate_pass() -> bool:
	var has_end: bool = bool(_result.get("battle_ended", false))
	var has_skills: bool = int(_result.get("skill_triggers", 0)) > 0
	var has_terrain: bool = int(_result.get("environment_damage_events", 0)) > 0 \
		or int(_result.get("terrain_max_instances", 0)) > 0 \
		or int(_result.get("terrain_max_cells", 0)) > 0
	var has_runtime_effects: bool = int(_result.get("buff_events", 0)) > 0
	var has_m5_trigger: bool = false
	var trigger_counts: Dictionary = _result.get("trigger_counts", {})
	for gid in REQUIRED_GONGFA_IDS:
		if int(trigger_counts.get(gid, 0)) > 0:
			has_m5_trigger = true
			break
	return has_end and has_skills and has_terrain and has_runtime_effects and has_m5_trigger


func _emit_report() -> void:
	print("=== M5 Battle Replay Summary ===")
	print("battle_started=%s" % str(_result.get("battle_started", false)))
	print("battle_ended=%s winner_team=%d" % [str(_result.get("battle_ended", false)), int(_result.get("winner_team", 0))])
	print("damage_events=%d environment_damage_events=%d" % [
		int(_result.get("damage_events", 0)),
		int(_result.get("environment_damage_events", 0))
	])
	print("skill_triggers=%d skill_damage_events=%d skill_heal_events=%d" % [
		int(_result.get("skill_triggers", 0)),
		int(_result.get("skill_effect_damage_events", 0)),
		int(_result.get("skill_effect_heal_events", 0))
	])
	print("buff_events=%d terrain_max_cells=%d" % [
		int(_result.get("buff_events", 0)),
		int(_result.get("terrain_max_cells", 0))
	])
	print("terrain_max_instances=%d" % int(_result.get("terrain_max_instances", 0)))
	print("trigger_counts=%s" % JSON.stringify(_result.get("trigger_counts", {})))
	print("buff_apply_counts=%s" % JSON.stringify(_result.get("buff_apply_counts", {})))
	print("battle_summary=%s" % JSON.stringify(_result.get("battle_summary", {})))
	print("=== End Summary ===")


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("M5 replay check failed: %s" % message)
	quit(1)


func _ensure_runtime_singletons() -> void:
	for singleton_name in SINGLETON_SCRIPT_PATHS.keys():
		if _get_root_node(singleton_name) != null:
			continue
		var script_path: String = str(SINGLETON_SCRIPT_PATHS.get(singleton_name, "")).strip_edges()
		if script_path.is_empty():
			continue
		var script_res: Variant = load(script_path)
		if not (script_res is Script):
			push_error("Unable to load singleton script: %s" % script_path)
			continue
		var singleton_node: Variant = (script_res as Script).new()
		if not (singleton_node is Node):
			push_error("Singleton script is not Node-based: %s" % script_path)
			continue
		var node_instance: Node = singleton_node as Node
		node_instance.name = singleton_name
		root.add_child(node_instance)
	# Ensure all _ready callbacks run before using these services.
	await process_frame


func _get_root_node(node_name: String) -> Node:
	if root == null:
		return null
	return root.get_node_or_null(node_name)
