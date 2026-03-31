extends SceneTree

const BATTLEFIELD_SCENE: PackedScene = preload("res://scenes/battle/battlefield_scene.tscn")
const RUNTIME_PROBE_SCRIPT: Script = preload("res://scripts/infra/runtime_probe.gd")

const SINGLETON_SCRIPT_PATHS: Dictionary = {
	"EventBus": "res://scripts/core/event_bus.gd",
	"ObjectPool": "res://scripts/core/object_pool.gd",
	"DataManager": "res://scripts/data/data_manager.gd",
	"ModLoader": "res://scripts/core/mod_loader.gd",
	"UnitAugmentManager": "res://scripts/unit_augment/unit_augment_manager.gd"
}

const ALLY_COUNT: int = 50
const ENEMY_COUNT: int = 200
const CAPTURE_SECONDS: float = 8.0
const HARD_TIMEOUT_SECONDS: float = 20.0
const STRESS_SEED: int = 20260329
const RENDER_MODE_ENV: String = "M5_RENDER_MODE"
const DEEP_PROBE_ENV: String = "M5_DEEP_RUNTIME_PROBE"

var _battlefield: Node = null
var _scene_refs: Node = null
var _session_state: RefCounted = null
var _coordinator: Node = null
var _combat_manager: Node = null
var _unit_deploy_manager: Node = null
var _unit_factory: Node = null
var _world_controller: Node = null
var _hud_presenter: Node = null
var _unit_augment_manager: Node = null

var _runtime_services: ServiceRegistry = null
var _runtime_probe = null
var _created_singletons: Array[Node] = []
var _shutdown_started: bool = false
var _battle_done: bool = false
var _battle_summary: Dictionary = {}
var _battle_winner_team: int = 0


func _init() -> void:
	await _run()


func _run() -> void:
	print("[stress_50v200] bootstrap begin")
	await _ensure_runtime_singletons()
	var data_manager: Node = _runtime_services.data_repository if _runtime_services != null else null
	if data_manager == null:
		await _abort("DataManager runtime service is missing.")
		return

	data_manager.call("load_base_data")
	var mod_loader: Node = _runtime_services.mod_loader if _runtime_services != null else null
	if mod_loader != null and mod_loader.has_method("load_and_apply_mods"):
		mod_loader.call("load_and_apply_mods")
	_unit_augment_manager = _runtime_services.unit_augment_manager if _runtime_services != null else null
	if _unit_augment_manager != null and _unit_augment_manager.has_method("reload_from_data"):
		_unit_augment_manager.call("reload_from_data")
	if _unit_augment_manager != null:
		var deep_probe_enabled: bool = _get_deep_runtime_probe_enabled()
		_unit_augment_manager.set("deep_runtime_probe_enabled", deep_probe_enabled)
		if deep_probe_enabled and _runtime_probe != null:
			_runtime_probe.sample_interval_frames = 1
	await process_frame
	await process_frame

	_runtime_probe = RUNTIME_PROBE_SCRIPT.new()
	_runtime_probe.sample_interval_frames = 10
	_rebind_runtime_services_with_probe(_runtime_probe)
	_battlefield = BATTLEFIELD_SCENE.instantiate()
	_battlefield.bind_app_services(_build_battlefield_services(_runtime_probe))
	root.add_child(_battlefield)
	await process_frame
	await process_frame

	if not _capture_battlefield_refs():
		await _abort("Battlefield dependencies are not ready for stress test.")
		return
	_connect_runtime_signals()
	_cleanup_scene_runtime()

	if not _deploy_stress_units():
		await _abort("Failed to deploy 50v200 units.")
		return

	if _runtime_probe != null and _runtime_probe.has_method("reset"):
		_runtime_probe.reset()
	var started: bool = false
	if _coordinator != null and _coordinator.has_method("start_battle_from_session"):
		var coordinator_api: Variant = _coordinator
		started = bool(await coordinator_api.start_battle_from_session(STRESS_SEED, false))
	if not started:
		await _abort("BattlefieldCoordinator failed to start 50v200 stress battle.")
		return

	print("[stress_50v200] battle started")
	_apply_render_mode_from_env()
	var capture_begin_us: int = Time.get_ticks_usec()
	var hard_timeout_us: int = int(HARD_TIMEOUT_SECONDS * 1000000.0)
	var capture_target_us: int = int(CAPTURE_SECONDS * 1000000.0)
	while true:
		await process_frame
		var elapsed_us: int = Time.get_ticks_usec() - capture_begin_us
		if _battle_done:
			break
		if elapsed_us >= capture_target_us:
			break
		if elapsed_us >= hard_timeout_us:
			break

	if _combat_manager != null and bool(_combat_manager.is_battle_running()):
		_combat_manager.call("stop_battle", "stress_capture_complete", 0)
		await process_frame
		await process_frame

	_emit_report()
	await _shutdown_and_quit(0)


func _capture_battlefield_refs() -> bool:
	if _battlefield == null:
		return false
	if not _battlefield.has_method("get_scene_refs") or not _battlefield.has_method("get_session_state"):
		return false
	_scene_refs = _battlefield.get_scene_refs()
	_session_state = _battlefield.get_session_state()
	_coordinator = _battlefield.get_coordinator()
	_world_controller = _battlefield.get_world_controller()
	_hud_presenter = _battlefield.get_hud_presenter()
	if _scene_refs == null:
		return false
	_combat_manager = _scene_refs.get("combat_manager") as Node
	_unit_deploy_manager = _scene_refs.get("runtime_unit_deploy_manager") as Node
	_unit_factory = _scene_refs.get("unit_factory") as Node
	return (
		_session_state != null
		and _coordinator != null
		and _world_controller != null
		and _hud_presenter != null
		and _combat_manager != null
		and _unit_deploy_manager != null
		and _unit_factory != null
	)


func _connect_runtime_signals() -> void:
	if _combat_manager == null:
		return
	var end_cb: Callable = Callable(self, "_on_battle_ended")
	if _combat_manager.has_signal("battle_ended") and not _combat_manager.is_connected("battle_ended", end_cb):
		_combat_manager.connect("battle_ended", end_cb)


func _disconnect_runtime_signals() -> void:
	if _combat_manager != null and is_instance_valid(_combat_manager):
		var end_cb: Callable = Callable(self, "_on_battle_ended")
		if _combat_manager.has_signal("battle_ended") and _combat_manager.is_connected("battle_ended", end_cb):
			_combat_manager.disconnect("battle_ended", end_cb)


func _cleanup_scene_runtime() -> void:
	var bench_ui: Node = _scene_refs.get("bench_ui") as Node
	if bench_ui != null and bench_ui.has_method("get_all_units") and bench_ui.has_method("remove_unit"):
		var bench_units: Array = bench_ui.call("get_all_units")
		for unit_value in bench_units:
			var unit: Node = unit_value as Node
			if unit == null or not is_instance_valid(unit):
				continue
			bench_ui.call("remove_unit", unit)
			_unit_factory.call("release_unit", unit)

	_clear_map_units(_session_state.ally_deployed)
	if _unit_deploy_manager != null and _unit_deploy_manager.has_method("clear_enemy_wave"):
		_unit_deploy_manager.call("clear_enemy_wave")
	else:
		_clear_map_units(_session_state.enemy_deployed)
	if _world_controller != null and _world_controller.has_method("refresh_world_layout"):
		_world_controller.call("refresh_world_layout")
	if _hud_presenter != null and _hud_presenter.has_method("refresh_ui"):
		_hud_presenter.call("refresh_ui")


func _clear_map_units(deployed_map: Dictionary) -> void:
	if deployed_map.is_empty():
		return
	var deployed_units: Array = deployed_map.values().duplicate()
	for unit_value in deployed_units:
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		if _unit_deploy_manager != null and _unit_deploy_manager.has_method("remove_unit_from_map"):
			_unit_deploy_manager.call("remove_unit_from_map", deployed_map, unit)
		if _unit_factory != null:
			_unit_factory.call("release_unit", unit)
	deployed_map.clear()


func _deploy_stress_units() -> bool:
	var all_unit_ids: Array[String] = []
	var unit_ids_value: Variant = _unit_factory.call("get_unit_ids")
	if unit_ids_value is Array:
		for unit_id_value in unit_ids_value:
			all_unit_ids.append(str(unit_id_value))
	if all_unit_ids.size() < ALLY_COUNT:
		push_error("Stress test requires at least %d unique unit ids, got %d." % [ALLY_COUNT, all_unit_ids.size()])
		return false

	var ally_cells: Array[Vector2i] = []
	var enemy_cells: Array[Vector2i] = []
	var ally_cells_value: Variant = _unit_deploy_manager.call("collect_ally_spawn_cells")
	if ally_cells_value is Array:
		for cell_value in ally_cells_value:
			if cell_value is Vector2i:
				ally_cells.append(cell_value)
	var enemy_cells_value: Variant = _unit_deploy_manager.call("collect_enemy_spawn_cells")
	if enemy_cells_value is Array:
		for cell_value in enemy_cells_value:
			if cell_value is Vector2i:
				enemy_cells.append(cell_value)
	if ally_cells.size() < ALLY_COUNT or enemy_cells.size() < ENEMY_COUNT:
		push_error("Stress test cells are insufficient: ally=%d enemy=%d" % [ally_cells.size(), enemy_cells.size()])
		return false

	var unit_layer: Node = _scene_refs.get("unit_layer") as Node
	var ally_unit_ids: Array[String] = []
	for index in range(ALLY_COUNT):
		ally_unit_ids.append(all_unit_ids[index])
	var enemy_unit_ids: Array[String] = _build_enemy_unit_ids(all_unit_ids, ENEMY_COUNT)

	for ally_index in range(ALLY_COUNT):
		var ally_unit_id: String = ally_unit_ids[ally_index]
		var ally_unit: Node = _unit_factory.call("acquire_unit", ally_unit_id, unit_layer)
		if ally_unit == null:
			push_error("Acquire ally unit failed: %s" % ally_unit_id)
			return false
		_unit_deploy_manager.call("deploy_ally_unit_to_cell", ally_unit, ally_cells[ally_index])

	for enemy_index in range(ENEMY_COUNT):
		var enemy_unit_id: String = enemy_unit_ids[enemy_index]
		var enemy_unit: Node = _unit_factory.call("acquire_unit", enemy_unit_id, unit_layer)
		if enemy_unit == null:
			push_error("Acquire enemy unit failed: %s" % enemy_unit_id)
			return false
		_unit_deploy_manager.call("deploy_enemy_unit_to_cell", enemy_unit, enemy_cells[enemy_index])

	if _world_controller != null and _world_controller.has_method("refresh_world_layout"):
		_world_controller.call("refresh_world_layout")
	if _hud_presenter != null and _hud_presenter.has_method("refresh_ui"):
		_hud_presenter.call("refresh_ui")

	return (
		_session_state.ally_deployed.size() == ALLY_COUNT
		and _session_state.enemy_deployed.size() == ENEMY_COUNT
	)


func _build_enemy_unit_ids(unit_ids: Array[String], required_count: int) -> Array[String]:
	var output: Array[String] = []
	if unit_ids.is_empty():
		return output
	var cursor: int = 0
	while output.size() < required_count:
		output.append(unit_ids[cursor % unit_ids.size()])
		cursor += 1
	return output


func _apply_render_mode_from_env() -> void:
	var render_mode: String = _get_render_mode()
	if render_mode == "baseline":
		return

	match render_mode:
		"hide_unit_visuals":
			for unit in _collect_stress_units():
				var visual_root: CanvasItem = unit.get_node_or_null("VisualRoot") as CanvasItem
				if visual_root != null:
					visual_root.visible = false
		"hide_labels":
			for unit in _collect_stress_units():
				var visual_root: Node = unit.get_node_or_null("VisualRoot")
				if visual_root != null:
					visual_root.set("labels_visible", false)
		"hide_vfx":
			_set_canvas_item_visible(_scene_refs.get("vfx_factory") as CanvasItem, false)
		"hide_ui":
			_set_canvas_item_visible(_scene_refs.get("hud_layer") as CanvasItem, false)
			_set_canvas_item_visible(_scene_refs.get("shop_panel_layer") as CanvasItem, false)
			_set_canvas_item_visible(_scene_refs.get("tooltip_layer") as CanvasItem, false)
			_set_canvas_item_visible(_scene_refs.get("detail_layer") as CanvasItem, false)
			_set_canvas_item_visible(_scene_refs.get("bottom_layer") as CanvasItem, false)
			_set_canvas_item_visible(_scene_refs.get("debug_layer") as CanvasItem, false)


func _collect_stress_units() -> Array[Node]:
	var units: Array[Node] = []
	for unit_value in _session_state.ally_deployed.values():
		var unit: Node = unit_value as Node
		if unit != null and is_instance_valid(unit):
			units.append(unit)
	for unit_value in _session_state.enemy_deployed.values():
		var unit: Node = unit_value as Node
		if unit != null and is_instance_valid(unit):
			units.append(unit)
	return units


func _set_canvas_item_visible(item: CanvasItem, visible_value: bool) -> void:
	if item == null:
		return
	item.visible = visible_value


func _get_render_mode() -> String:
	var render_mode: String = OS.get_environment(RENDER_MODE_ENV).strip_edges().to_lower()
	if render_mode.is_empty():
		return "baseline"
	return render_mode


func _get_deep_runtime_probe_enabled() -> bool:
	var raw: String = OS.get_environment(DEEP_PROBE_ENV).strip_edges().to_lower()
	return raw == "1" or raw == "true" or raw == "yes" or raw == "on"


func _on_battle_ended(winner_team: int, summary: Dictionary) -> void:
	_battle_done = true
	_battle_winner_team = winner_team
	_battle_summary = summary.duplicate(true)


func _emit_report() -> void:
	var probe_snapshot: Dictionary = {}
	if _runtime_probe != null and _runtime_probe.has_method("build_snapshot"):
		probe_snapshot = _runtime_probe.build_snapshot()
	var combat_snapshot: Dictionary = {}
	if _combat_manager != null and _combat_manager.has_method("get_runtime_metrics_snapshot"):
		combat_snapshot = _combat_manager.get_runtime_metrics_snapshot()

	var scope_rows: Array = _build_scope_rows(probe_snapshot.get("scopes", {}))
	var top_scopes: Array = []
	for index in range(mini(scope_rows.size(), 20)):
		top_scopes.append(scope_rows[index])

	var samples: Dictionary = probe_snapshot.get("samples", {})
	var avg_wall_fps: float = float(probe_snapshot.get("avg_wall_fps", 0.0))
	var avg_frame_budget_ms: float = 1000.0 / avg_wall_fps if avg_wall_fps > 0.0 else 0.0
	var diagnosis: String = _build_diagnosis(probe_snapshot, combat_snapshot)

	print("=== 50v200 Battlefield Stress Summary ===")
	print("mode=headless_runtime_probe")
	print("render_mode=%s" % _get_render_mode())
	print("captured_frames=%d avg_wall_fps=%.2f avg_frame_budget_ms=%.2f" % [
		int(probe_snapshot.get("frames", 0)),
		avg_wall_fps,
		avg_frame_budget_ms
	])
	print("unit_counts ally=%d enemy=%d avg_total_units=%.2f avg_moving_units=%.2f avg_animator_active=%.2f avg_unit_process_active=%.2f avg_quick_step_tween=%.2f avg_animator_tween=%.2f" % [
		ALLY_COUNT,
		ENEMY_COUNT,
		_sample_avg(samples, "total_units"),
		_sample_avg(samples, "moving_units"),
		_sample_avg(samples, "animator_process_active"),
		_sample_avg(samples, "unit_process_active"),
		_sample_avg(samples, "quick_step_tween_active"),
		_sample_avg(samples, "animator_tween_active")
	])
	print("combat_metrics avg_tick_ms=%.3f avg_units_per_tick=%.2f move_success_rate=%.3f move_blocked_rate=%.3f" % [
		float(combat_snapshot.get("avg_tick_ms", 0.0)),
		float(combat_snapshot.get("avg_units_per_tick", 0.0)),
		float(combat_snapshot.get("move_success_rate", 0.0)),
		float(combat_snapshot.get("move_blocked_rate", 0.0))
	])
	print("top_scopes=%s" % JSON.stringify(top_scopes))
	print("samples=%s" % JSON.stringify(_build_key_sample_subset(samples, [
		"total_units",
		"moving_units",
		"unit_process_active",
		"animator_process_active",
		"quick_step_tween_active",
		"animator_tween_active",
		"vfx_active_texts",
		"vfx_active_particles"
	])))
	print("battle_done=%s winner_team=%d summary=%s" % [
		str(_battle_done),
		_battle_winner_team,
		JSON.stringify(_battle_summary)
	])
	print("diagnosis=%s" % diagnosis)
	print("=== End Stress Summary ===")


func _build_scope_rows(scopes: Dictionary) -> Array:
	var rows: Array = []
	for scope_name in scopes.keys():
		var scope_stats: Dictionary = scopes.get(scope_name, {})
		rows.append({
			"name": str(scope_name),
			"avg_ms_per_frame": float(scope_stats.get("avg_ms_per_frame", 0.0)),
			"avg_ms_per_call": float(scope_stats.get("avg_ms_per_call", 0.0)),
			"max_us": int(scope_stats.get("max_us", 0)),
			"calls": int(scope_stats.get("calls", 0))
		})
	rows.sort_custom(Callable(self, "_compare_scope_rows"))
	return rows


func _compare_scope_rows(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("avg_ms_per_frame", 0.0)) > float(b.get("avg_ms_per_frame", 0.0))


func _build_key_sample_subset(samples: Dictionary, keys: Array[String]) -> Dictionary:
	var output: Dictionary = {}
	for key in keys:
		if samples.has(key):
			output[key] = samples[key]
	return output


func _sample_avg(samples: Dictionary, key: String) -> float:
	return float((samples.get(key, {}) as Dictionary).get("avg", 0.0))


func _scope_avg_ms(scopes: Dictionary, key: String) -> float:
	return float((scopes.get(key, {}) as Dictionary).get("avg_ms_per_frame", 0.0))


func _build_diagnosis(probe_snapshot: Dictionary, combat_snapshot: Dictionary) -> String:
	var scopes: Dictionary = probe_snapshot.get("scopes", {})
	var samples: Dictionary = probe_snapshot.get("samples", {})
	var avg_wall_fps: float = float(probe_snapshot.get("avg_wall_fps", 0.0))
	var animator_ms: float = _scope_avg_ms(scopes, "sprite_animator_process")
	var unit_base_ms: float = _scope_avg_ms(scopes, "unit_base_process")
	var combat_process_ms: float = _scope_avg_ms(scopes, "combat_manager_process")
	var combat_logic_ms: float = float(combat_snapshot.get("avg_tick_ms", 0.0))
	var animator_active: float = _sample_avg(samples, "animator_process_active")
	var moving_units: float = _sample_avg(samples, "moving_units")
	var total_units: float = _sample_avg(samples, "total_units")
	if animator_ms >= maxf(combat_process_ms * 2.0, 2.0) and animator_active >= total_units * 0.9:
		return "Primary bottleneck is SpriteAnimator._process. Nearly every unit keeps loop animation processing active, and its per-frame cost exceeds combat logic."
	if unit_base_ms >= maxf(combat_process_ms * 1.5, 1.0) and moving_units >= total_units * 0.35:
		return "Primary bottleneck is per-unit movement/process overhead in UnitBase._process. Too many units keep movement ticks active in the same frame."
	if combat_process_ms >= maxf(animator_ms, unit_base_ms) and combat_logic_ms >= 5.0:
		return "Primary bottleneck is combat runtime logic itself. CombatManager and logic ticks are already consuming a large part of the frame budget."
	if avg_wall_fps <= 10.0:
		return "Frame rate is low, but no single non-combat scope dominates strongly. Next suspect is remaining unprobed render/UI overhead or cumulative cost across multiple medium hot spots."
	return "No hard bottleneck signature was detected from the current headless probe. If in-game FPS is still much lower than this run, GPU/render cost is the next suspect."


func _ensure_runtime_singletons() -> void:
	var runtime_nodes: Dictionary = {}
	for singleton_name in SINGLETON_SCRIPT_PATHS.keys():
		var existing: Node = _get_root_node(singleton_name)
		if existing != null:
			runtime_nodes[singleton_name] = existing
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
		runtime_nodes[singleton_name] = node_instance
	_create_runtime_services(runtime_nodes)
	for singleton_name in SINGLETON_SCRIPT_PATHS.keys():
		if not runtime_nodes.has(singleton_name):
			continue
		var runtime_node: Node = runtime_nodes[singleton_name]
		if runtime_node == null or runtime_node.get_parent() != null:
			continue
		runtime_node.name = singleton_name
		root.add_child(runtime_node)
		_created_singletons.append(runtime_node)
	await process_frame


func _create_runtime_services(runtime_nodes: Dictionary) -> void:
	_runtime_services = ServiceRegistry.new()
	_runtime_services.register_event_bus(runtime_nodes.get("EventBus", null))
	_runtime_services.register_object_pool(runtime_nodes.get("ObjectPool", null))
	_runtime_services.register_data_repository(runtime_nodes.get("DataManager", null))
	_runtime_services.register_mod_loader(runtime_nodes.get("ModLoader", null))
	_runtime_services.register_unit_augment_manager(runtime_nodes.get("UnitAugmentManager", null))
	for node_value in runtime_nodes.values():
		var runtime_node: Node = node_value as Node
		if runtime_node != null and runtime_node.has_method("bind_runtime_services"):
			runtime_node.call("bind_runtime_services", _runtime_services)


func _rebind_runtime_services_with_probe(probe) -> void:
	if _runtime_services == null:
		return
	_runtime_services.register_runtime_probe(probe)
	for singleton in _created_singletons:
		if singleton == null or not is_instance_valid(singleton):
			continue
		if singleton.has_method("bind_runtime_services"):
			singleton.call("bind_runtime_services", _runtime_services)


func _build_battlefield_services(probe) -> ServiceRegistry:
	var services := ServiceRegistry.new()
	if _runtime_services != null:
		services.register_event_bus(_runtime_services.event_bus)
		services.register_object_pool(_runtime_services.object_pool)
		services.register_data_repository(_runtime_services.data_repository)
		services.register_mod_loader(_runtime_services.mod_loader)
		services.register_unit_augment_manager(_runtime_services.unit_augment_manager)
	var app_session := AppSessionState.new()
	services.register_app_session(app_session)
	services.register_runtime_probe(probe)
	return services


func _get_root_node(node_name: String) -> Node:
	if root == null:
		return null
	return root.get_node_or_null(node_name)


func _abort(message: String) -> void:
	push_error(message)
	print("[stress_50v200] failed: %s" % message)
	await _shutdown_and_quit(1)


func _shutdown_and_quit(exit_code: int) -> void:
	if _shutdown_started:
		return
	_shutdown_started = true
	_disconnect_runtime_signals()
	await _release_runtime_nodes()
	_clear_runtime_refs()
	quit(exit_code)


func _release_runtime_nodes() -> void:
	if _battlefield != null and is_instance_valid(_battlefield):
		_battlefield.queue_free()
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
	_unit_deploy_manager = null
	_unit_factory = null
	_world_controller = null
	_hud_presenter = null
	_unit_augment_manager = null
	_runtime_services = null
	_runtime_probe = null
