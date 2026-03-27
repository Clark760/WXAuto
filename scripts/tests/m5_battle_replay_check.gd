extends SceneTree

const BATTLEFIELD_SCENE: PackedScene = preload("res://scenes/battle/battlefield_scene.tscn")
const SINGLETON_SCRIPT_PATHS: Dictionary = {
	"EventBus": "res://scripts/core/event_bus.gd",
	"ObjectPool": "res://scripts/core/object_pool.gd",
	"DataManager": "res://scripts/data/data_manager.gd",
	"ModLoader": "res://scripts/core/mod_loader.gd",
	"GameManager": "res://scripts/core/game_manager.gd",
	"UnitAugmentManager": "res://scripts/unit_augment/unit_augment_manager.gd"
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
var _scene_refs: Node = null
var _session_state: RefCounted = null
var _coordinator: Node = null
var _combat_manager: Node = null
var _unit_augment_manager: Node = null
var _unit_deploy_manager: Node = null
var _unit_factory: Node = null
var _hex_grid: Node = null
var _world_controller: Node = null
var _hud_presenter: Node = null

var _battle_done: bool = false
var _failed: bool = false
var _shutdown_started: bool = false
var _created_singletons: Array[Node] = []
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
		await _abort("DataManager autoload is missing.")
		return

	_result["data_summary"] = data_manager.call("load_base_data")
	print("[m5_replay] data loaded")
	var mod_loader: Node = _get_root_node("ModLoader")
	if mod_loader != null and mod_loader.has_method("load_and_apply_mods"):
		_result["mod_summary"] = mod_loader.call("load_and_apply_mods")
		print("[m5_replay] test mods loaded")
	_unit_augment_manager = _get_root_node("UnitAugmentManager")
	if _unit_augment_manager != null and _unit_augment_manager.has_method("reload_from_data"):
		_unit_augment_manager.call("reload_from_data")
	await process_frame
	print("[m5_replay] gongfa reloaded")

	if not _validate_required_records(data_manager):
		await _abort("Required M5 test records are missing after data load.")
		return

	_battlefield = BATTLEFIELD_SCENE.instantiate()
	root.add_child(_battlefield)
	await process_frame
	await process_frame
	print("[m5_replay] battlefield ready")

	if not _battlefield.has_method("get_scene_refs") or not _battlefield.has_method("get_session_state"):
		await _abort("BattlefieldScene getters are not ready for replay.")
		return
	_scene_refs = _battlefield.get_scene_refs()
	_session_state = _battlefield.get_session_state()
	_coordinator = _battlefield.get_coordinator()
	_world_controller = _battlefield.get_world_controller()
	_hud_presenter = _battlefield.get_hud_presenter()
	_combat_manager = _scene_refs.combat_manager
	_unit_deploy_manager = _scene_refs.runtime_unit_deploy_manager
	_unit_factory = _scene_refs.unit_factory
	_hex_grid = _scene_refs.hex_grid
	if _coordinator == null or _world_controller == null or _combat_manager == null or _unit_deploy_manager == null or _unit_factory == null or _hex_grid == null:
		await _abort("Battlefield dependencies are not ready.")
		return

	_connect_runtime_signals()
	_cleanup_scene_runtime()

	if not _deploy_test_units():
		await _abort("Failed to deploy test units for replay.")
		return
	print("[m5_replay] units deployed")

	var ally_units: Array[Node] = _collect_units_from_map(_session_state.ally_deployed)
	var enemy_units: Array[Node] = _collect_units_from_map(_session_state.enemy_deployed)
	if ally_units.is_empty() or enemy_units.is_empty():
		await _abort("Deployed unit lists are empty, cannot start replay.")
		return

	var started: bool = false
	if _coordinator != null and _coordinator.has_method("start_battle_from_session"):
		started = bool(_coordinator.call("start_battle_from_session", 20260322, false))
	if not started:
		await _abort("BattlefieldCoordinator failed to start battle replay.")
		return
	print("[m5_replay] battle started")

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
		await _shutdown_and_quit(0)
		return
	await _abort("M5 replay check failed.")


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

	if _unit_augment_manager != null:
		var trigger_cb: Callable = Callable(self, "_on_skill_triggered")
		if _unit_augment_manager.has_signal("skill_triggered") and not _unit_augment_manager.is_connected("skill_triggered", trigger_cb):
			_unit_augment_manager.connect("skill_triggered", trigger_cb)
		var skill_damage_cb: Callable = Callable(self, "_on_skill_effect_damage")
		if _unit_augment_manager.has_signal("skill_effect_damage") and not _unit_augment_manager.is_connected("skill_effect_damage", skill_damage_cb):
			_unit_augment_manager.connect("skill_effect_damage", skill_damage_cb)
		var skill_heal_cb: Callable = Callable(self, "_on_skill_effect_heal")
		if _unit_augment_manager.has_signal("skill_effect_heal") and not _unit_augment_manager.is_connected("skill_effect_heal", skill_heal_cb):
			_unit_augment_manager.connect("skill_effect_heal", skill_heal_cb)
		var buff_cb: Callable = Callable(self, "_on_buff_event")
		if _unit_augment_manager.has_signal("buff_event") and not _unit_augment_manager.is_connected("buff_event", buff_cb):
			_unit_augment_manager.connect("buff_event", buff_cb)


func _cleanup_scene_runtime() -> void:
	var bench_ui: Node = _scene_refs.bench_ui
	if bench_ui != null and bench_ui.has_method("get_all_units") and bench_ui.has_method("remove_unit"):
		var bench_units: Array = bench_ui.call("get_all_units")
		for unit_value in bench_units:
			if not (unit_value is Node):
				continue
			var unit: Node = unit_value as Node
			bench_ui.call("remove_unit", unit)
			if _unit_factory != null:
				_unit_factory.call("release_unit", unit)

	_clear_map_units(_session_state.ally_deployed)
	if _unit_deploy_manager != null and _unit_deploy_manager.has_method("clear_enemy_wave"):
		_unit_deploy_manager.clear_enemy_wave()
	else:
		_clear_map_units(_session_state.enemy_deployed)
	if _world_controller != null:
		_world_controller.refresh_world_layout()
	if _hud_presenter != null and _hud_presenter.has_method("refresh_ui"):
		_hud_presenter.refresh_ui()


func _clear_map_units(deployed_map: Dictionary) -> void:
	if deployed_map.is_empty():
		return
	var deployed_units: Array = deployed_map.values().duplicate()
	for unit_value in deployed_units:
		if not (unit_value is Node):
			continue
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		if _unit_deploy_manager != null and _unit_deploy_manager.has_method("remove_unit_from_map"):
			_unit_deploy_manager.remove_unit_from_map(deployed_map, unit)
		if _unit_factory != null:
			_unit_factory.call("release_unit", unit)
	deployed_map.clear()


func _deploy_test_units() -> bool:
	if ALLY_UNIT_IDS.size() != ALLY_CELLS.size() or ENEMY_UNIT_IDS.size() != ENEMY_CELLS.size():
		push_error("M5 replay config mismatch: unit ids and deploy cells size mismatch.")
		return false

	var unit_layer: Node = _scene_refs.unit_layer
	if unit_layer == null:
		return false
	var ally_cells: Array[Vector2i] = _resolve_spawn_cells(
		ALLY_CELLS,
		_unit_deploy_manager.collect_ally_spawn_cells(),
		ALLY_UNIT_IDS.size()
	)
	var enemy_cells: Array[Vector2i] = _resolve_spawn_cells(
		ENEMY_CELLS,
		_unit_deploy_manager.collect_enemy_spawn_cells(),
		ENEMY_UNIT_IDS.size()
	)
	if ally_cells.size() != ALLY_UNIT_IDS.size() or enemy_cells.size() != ENEMY_UNIT_IDS.size():
		push_error("Replay deploy cells are insufficient for current stage layout.")
		return false

	for i in range(ALLY_UNIT_IDS.size()):
		var unit_id: String = ALLY_UNIT_IDS[i]
		var unit: Node = _unit_factory.call("acquire_unit", unit_id, 1, unit_layer)
		if unit == null:
			push_error("Acquire ally unit failed: %s" % unit_id)
			return false
		_unit_deploy_manager.deploy_ally_unit_to_cell(unit, ally_cells[i])

	for j in range(ENEMY_UNIT_IDS.size()):
		var unit_id2: String = ENEMY_UNIT_IDS[j]
		var unit2: Node = _unit_factory.call("acquire_unit", unit_id2, 1, unit_layer)
		if unit2 == null:
			push_error("Acquire enemy unit failed: %s" % unit_id2)
			return false
		_unit_deploy_manager.deploy_enemy_unit_to_cell(unit2, enemy_cells[j])

	if _world_controller != null:
		_world_controller.refresh_world_layout()
	if _hud_presenter != null and _hud_presenter.has_method("refresh_ui"):
		_hud_presenter.refresh_ui()
	if _session_state.ally_deployed.size() != ALLY_UNIT_IDS.size():
		push_error("Replay ally deployment count mismatch after world deployment.")
		return false
	if _session_state.enemy_deployed.size() != ENEMY_UNIT_IDS.size():
		push_error("Replay enemy deployment count mismatch after world deployment.")
		return false
	return true


func _collect_units_from_map(deployed_map: Dictionary) -> Array[Node]:
	if _unit_deploy_manager != null and _unit_deploy_manager.has_method("collect_units_from_map"):
		return _unit_deploy_manager.collect_units_from_map(deployed_map)
	var units: Array[Node] = []
	for unit_value in deployed_map.values():
		if unit_value is Node and is_instance_valid(unit_value):
			units.append(unit_value as Node)
	return units


func _resolve_spawn_cells(
	preferred_cells: Array[Vector2i],
	available_cells: Array[Vector2i],
	required_count: int
) -> Array[Vector2i]:
	if available_cells.is_empty() or required_count <= 0:
		return []
	var selected: Array[Vector2i] = []
	var used_cells: Dictionary = {}
	for cell in preferred_cells:
		if not available_cells.has(cell):
			continue
		var cell_key: String = "%d,%d" % [cell.x, cell.y]
		if used_cells.has(cell_key):
			continue
		used_cells[cell_key] = true
		selected.append(cell)
		if selected.size() >= required_count:
			return selected
	for cell in available_cells:
		var cell_key: String = "%d,%d" % [cell.x, cell.y]
		if used_cells.has(cell_key):
			continue
		used_cells[cell_key] = true
		selected.append(cell)
		if selected.size() >= required_count:
			return selected
	return selected


func _sample_terrain_cells() -> void:
	if _combat_manager == null or _hex_grid == null:
		return
	var terrain_manager: Variant = _combat_manager.get("_terrain_manager")
	if terrain_manager == null:
		return
	var terrain_api: Variant = terrain_manager
	var terrains_value: Variant = terrain_api.get("_terrains")
	if terrains_value is Array:
		var max_instances: int = int(_result.get("terrain_max_instances", 0))
		var terrain_count: int = (terrains_value as Array).size()
		if terrain_count > max_instances:
			_result["terrain_max_instances"] = terrain_count
	var cells_value: Variant = terrain_api.call("get_visual_cells", _hex_grid)
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


func _abort(message: String) -> void:
	_fail(message)
	await _shutdown_and_quit(1)


func _shutdown_and_quit(exit_code: int) -> void:
	if _shutdown_started:
		return
	_shutdown_started = true
	_disconnect_runtime_signals()
	_break_hud_helper_cycle()
	await _release_runtime_nodes()
	_clear_runtime_refs()
	quit(exit_code)


func _disconnect_runtime_signals() -> void:
	if _combat_manager != null and is_instance_valid(_combat_manager):
		var start_cb: Callable = Callable(self, "_on_battle_started")
		if _combat_manager.has_signal("battle_started") and _combat_manager.is_connected("battle_started", start_cb):
			_combat_manager.disconnect("battle_started", start_cb)
		var end_cb: Callable = Callable(self, "_on_battle_ended")
		if _combat_manager.has_signal("battle_ended") and _combat_manager.is_connected("battle_ended", end_cb):
			_combat_manager.disconnect("battle_ended", end_cb)
		var damage_cb: Callable = Callable(self, "_on_damage_resolved")
		if _combat_manager.has_signal("damage_resolved") and _combat_manager.is_connected("damage_resolved", damage_cb):
			_combat_manager.disconnect("damage_resolved", damage_cb)
	if _unit_augment_manager == null or not is_instance_valid(_unit_augment_manager):
		return
	var trigger_cb: Callable = Callable(self, "_on_skill_triggered")
	if _unit_augment_manager.has_signal("skill_triggered") and _unit_augment_manager.is_connected("skill_triggered", trigger_cb):
		_unit_augment_manager.disconnect("skill_triggered", trigger_cb)
	var skill_damage_cb: Callable = Callable(self, "_on_skill_effect_damage")
	if _unit_augment_manager.has_signal("skill_effect_damage") and _unit_augment_manager.is_connected("skill_effect_damage", skill_damage_cb):
		_unit_augment_manager.disconnect("skill_effect_damage", skill_damage_cb)
	var skill_heal_cb: Callable = Callable(self, "_on_skill_effect_heal")
	if _unit_augment_manager.has_signal("skill_effect_heal") and _unit_augment_manager.is_connected("skill_effect_heal", skill_heal_cb):
		_unit_augment_manager.disconnect("skill_effect_heal", skill_heal_cb)
	var buff_cb: Callable = Callable(self, "_on_buff_event")
	if _unit_augment_manager.has_signal("buff_event") and _unit_augment_manager.is_connected("buff_event", buff_cb):
		_unit_augment_manager.disconnect("buff_event", buff_cb)


func _break_hud_helper_cycle() -> void:
	if _hud_presenter == null or not is_instance_valid(_hud_presenter):
		return
	if not _hud_presenter.has_method("get_detail_view"):
		return
	if not _hud_presenter.has_method("get_shop_inventory_view"):
		return
	var detail_view = _hud_presenter.get_detail_view()
	var shop_view = _hud_presenter.get_shop_inventory_view()
	if detail_view != null and detail_view.has_method("bind_shop_inventory_view"):
		detail_view.call("bind_shop_inventory_view", null)
	if shop_view != null and shop_view.has_method("bind_detail_view"):
		shop_view.call("bind_detail_view", null)


func _release_runtime_nodes() -> void:
	if _battlefield != null and is_instance_valid(_battlefield):
		_battlefield.queue_free()
		await process_frame
		await process_frame
	for singleton in _created_singletons:
		if singleton != null and is_instance_valid(singleton):
			singleton.queue_free()
	if not _created_singletons.is_empty():
		await process_frame
		await process_frame
	_created_singletons.clear()


func _clear_runtime_refs() -> void:
	_battlefield = null
	_scene_refs = null
	_session_state = null
	_coordinator = null
	_combat_manager = null
	_unit_augment_manager = null
	_unit_deploy_manager = null
	_unit_factory = null
	_hex_grid = null
	_world_controller = null
	_hud_presenter = null


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
		_created_singletons.append(node_instance)
	# Ensure all _ready callbacks run before using these services.
	await process_frame


func _get_root_node(node_name: String) -> Node:
	if root == null:
		return null
	return root.get_node_or_null(node_name)
