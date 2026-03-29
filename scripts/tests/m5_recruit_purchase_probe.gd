extends SceneTree

const BATTLEFIELD_SCENE: PackedScene = preload("res://scenes/battle/battlefield_scene.tscn")
const EVENT_BUS_SCRIPT: Script = preload("res://scripts/core/event_bus.gd")
const OBJECT_POOL_SCRIPT: Script = preload("res://scripts/core/object_pool.gd")
const DATA_MANAGER_SCRIPT: Script = preload("res://scripts/data/data_manager.gd")
const MOD_LOADER_SCRIPT: Script = preload("res://scripts/core/mod_loader.gd")
const UNIT_AUGMENT_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_manager.gd")
const RUNTIME_PROBE_SCRIPT: Script = preload("res://scripts/infra/runtime_probe.gd")

const INITIAL_BASE_BENCH_UNITS: int = 35
const PURCHASE_COUNT: int = 5
const SETTLE_FRAMES_PER_PURCHASE: int = 4
const DUPLICATE_COPIES_PER_VISIBLE_OFFER: int = 2

var _runtime_probe = null


func _init() -> void:
	await _run()


func _run() -> void:
	var unit_augment_manager: Node = UNIT_AUGMENT_MANAGER_SCRIPT.new()
	var runtime_probe = RUNTIME_PROBE_SCRIPT.new()
	runtime_probe.sample_interval_frames = 1
	_runtime_probe = runtime_probe
	var ctx: Dictionary = await _create_battlefield(unit_augment_manager, runtime_probe)
	var battlefield: Node = ctx.get("battlefield", null)
	if battlefield == null:
		push_error("recruit purchase probe: battlefield bootstrap failed")
		quit(1)
		return

	var refs: Node = battlefield.get_scene_refs()
	var coordinator: Node = battlefield.get_coordinator()
	var unit_factory: Node = refs.unit_factory
	var bench_ui: Node = refs.bench_ui
	var economy_manager: Node = refs.runtime_economy_manager
	var shop_manager: Node = refs.runtime_shop_manager

	economy_manager.add_silver(99999)
	var seeded_offer_ids: Array[String] = _prime_bench_for_recruit_purchases(
		unit_factory,
		bench_ui,
		refs.unit_layer,
		shop_manager
	)
	await process_frame
	await process_frame

	if _runtime_probe != null and _runtime_probe.has_method("reset"):
		_runtime_probe.reset()

	var purchased: int = 0
	var purchase_reports: Array[Dictionary] = []
	for _index in range(PURCHASE_COUNT):
		var offer_index: int = _find_first_available_recruit_offer(shop_manager)
		if offer_index < 0:
			coordinator.refresh_shop_from_button()
			await process_frame
			offer_index = _find_first_available_recruit_offer(shop_manager)
		if offer_index < 0:
			break
		var offer: Dictionary = shop_manager.get_offer("recruit", offer_index)
		var offer_unit_id: String = str(offer.get("item_id", "")).strip_edges()
		var bench_before: int = int(bench_ui.get_unit_count()) if bench_ui != null else 0
		var purchase_begin_us: int = Time.get_ticks_usec()
		coordinator.purchase_shop_offer("recruit", offer_index)
		purchased += 1
		for _frame in range(SETTLE_FRAMES_PER_PURCHASE):
			await process_frame
		var bench_after: int = int(bench_ui.get_unit_count()) if bench_ui != null else 0
		purchase_reports.append({
			"offer_unit_id": offer_unit_id,
			"bench_before": bench_before,
			"bench_after": bench_after,
			"bench_delta": bench_after - bench_before,
			"wall_ms": float(Time.get_ticks_usec() - purchase_begin_us) / 1000.0
		})

	_emit_report(bench_ui, purchased, seeded_offer_ids, purchase_reports)
	await _cleanup_battlefield(ctx)
	quit(0)


func _create_battlefield(
	unit_augment_manager: Node,
	runtime_probe
) -> Dictionary:
	var services: ServiceRegistry = _build_services(unit_augment_manager, runtime_probe)
	var runtime_nodes: Array[Node] = [
		services.event_bus,
		services.object_pool,
		services.data_repository,
		services.mod_loader
	]
	var data_manager: Node = services.data_repository
	if data_manager != null and data_manager.has_method("load_base_data"):
		data_manager.load_base_data()
	var mod_loader: Node = services.mod_loader
	if mod_loader != null and mod_loader.has_method("load_and_apply_mods"):
		mod_loader.load_and_apply_mods()
	if unit_augment_manager.has_method("reload_from_data"):
		unit_augment_manager.reload_from_data()

	var battlefield: Node = BATTLEFIELD_SCENE.instantiate()
	battlefield.bind_app_services(services)
	root.add_child(battlefield)
	await process_frame
	await process_frame

	return {
		"battlefield": battlefield,
		"unit_augment_manager": unit_augment_manager,
		"services": services,
		"runtime_nodes": runtime_nodes
	}


func _cleanup_battlefield(ctx: Dictionary) -> void:
	var battlefield: Node = ctx.get("battlefield", null)
	if battlefield != null:
		battlefield.queue_free()
	var runtime_nodes: Variant = ctx.get("runtime_nodes", [])
	if runtime_nodes is Array:
		for node_value in runtime_nodes:
			if not (node_value is Node):
				continue
			var runtime_node: Node = node_value as Node
			if is_instance_valid(runtime_node):
				runtime_node.free()
	var unit_augment_manager: Node = ctx.get("unit_augment_manager", null)
	if unit_augment_manager != null:
		unit_augment_manager.free()
	await process_frame


func _build_services(
	unit_augment_manager: Node,
	runtime_probe
) -> ServiceRegistry:
	var services := ServiceRegistry.new()
	var event_bus: Node = EVENT_BUS_SCRIPT.new()
	var object_pool: Node = OBJECT_POOL_SCRIPT.new()
	var data_manager: Node = DATA_MANAGER_SCRIPT.new()
	var mod_loader: Node = MOD_LOADER_SCRIPT.new()
	services.register_event_bus(event_bus)
	services.register_object_pool(object_pool)
	services.register_data_repository(data_manager)
	services.register_mod_loader(mod_loader)
	services.register_unit_augment_manager(unit_augment_manager)
	services.register_runtime_probe(runtime_probe)
	services.register_app_session(AppSessionState.new())
	for runtime_node in [
		object_pool,
		data_manager,
		mod_loader,
		unit_augment_manager
	]:
		if runtime_node.has_method("bind_runtime_services"):
			runtime_node.call("bind_runtime_services", services)
	return services


func _prime_bench_for_recruit_purchases(
	unit_factory: Node,
	bench_ui: Node,
	unit_layer: Node,
	shop_manager: Node
) -> Array[String]:
	var seeded_offer_ids: Array[String] = _collect_visible_recruit_offer_unit_ids(shop_manager)
	var target_seed_count: int = INITIAL_BASE_BENCH_UNITS + seeded_offer_ids.size() * DUPLICATE_COPIES_PER_VISIBLE_OFFER
	var slot_limit: int = int(bench_ui.get_slot_count()) - PURCHASE_COUNT if bench_ui != null else target_seed_count
	var target_count: int = mini(target_seed_count, maxi(slot_limit, 0))
	var unit_ids_value: Variant = unit_factory.get_unit_ids()
	if not (unit_ids_value is Array):
		return seeded_offer_ids
	var unit_ids: Array = unit_ids_value
	for offer_unit_id in seeded_offer_ids:
		for _copy in range(DUPLICATE_COPIES_PER_VISIBLE_OFFER):
			if bench_ui != null and bench_ui.get_unit_count() >= target_count:
				return seeded_offer_ids
			_spawn_bench_unit(unit_factory, bench_ui, unit_layer, offer_unit_id)
	for unit_id_value in unit_ids:
		if bench_ui != null and bench_ui.get_unit_count() >= target_count:
			break
		var unit_id: String = str(unit_id_value).strip_edges()
		if unit_id.is_empty() or seeded_offer_ids.has(unit_id):
			continue
		_spawn_bench_unit(unit_factory, bench_ui, unit_layer, unit_id)
	return seeded_offer_ids


func _spawn_bench_unit(
	unit_factory: Node,
	bench_ui: Node,
	unit_layer: Node,
	unit_id: String
) -> void:
	if bench_ui == null or unit_factory == null:
		return
	var unit: Node = unit_factory.acquire_unit(unit_id, -1, unit_layer)
	if unit == null:
		return
	unit.set_team(1)
	unit.set("is_in_combat", false)
	if not bench_ui.add_unit(unit):
		unit_factory.release_unit(unit)


func _collect_visible_recruit_offer_unit_ids(shop_manager: Node) -> Array[String]:
	var output: Array[String] = []
	var seen: Dictionary = {}
	if shop_manager == null:
		return output
	var offers: Array[Dictionary] = shop_manager.get_offers("recruit")
	for offer in offers:
		var offer_unit_id: String = str(offer.get("item_id", "")).strip_edges()
		if offer_unit_id.is_empty() or seen.has(offer_unit_id):
			continue
		seen[offer_unit_id] = true
		output.append(offer_unit_id)
	return output


func _find_first_available_recruit_offer(shop_manager: Node) -> int:
	if shop_manager == null:
		return -1
	var offers: Array[Dictionary] = shop_manager.get_offers("recruit")
	for index in range(offers.size()):
		var offer: Dictionary = offers[index]
		if offer.is_empty():
			continue
		if bool(offer.get("sold", false)):
			continue
		if str(offer.get("item_id", "")).strip_edges().is_empty():
			continue
		return index
	return -1


func _emit_report(
	bench_ui: Node,
	purchased: int,
	seeded_offer_ids: Array[String],
	purchase_reports: Array[Dictionary]
) -> void:
	var probe_snapshot: Dictionary = {}
	if _runtime_probe != null and _runtime_probe.has_method("build_snapshot"):
		probe_snapshot = _runtime_probe.build_snapshot()
	var scope_rows: Array = _build_scope_rows(probe_snapshot.get("scopes", {}))
	var top_scopes: Array = []
	for index in range(mini(scope_rows.size(), 12)):
		top_scopes.append(scope_rows[index])
	var avg_wall_fps: float = float(probe_snapshot.get("avg_wall_fps", 0.0))
	var avg_frame_budget_ms: float = 1000.0 / avg_wall_fps if avg_wall_fps > 0.0 else 0.0
	var bench_count: int = 0
	if bench_ui != null and bench_ui.has_method("get_unit_count"):
		bench_count = int(bench_ui.get_unit_count())

	print("=== Recruit Purchase Probe Summary ===")
	print("purchased=%d bench_units=%d frames=%d avg_wall_fps=%.2f avg_frame_budget_ms=%.2f" % [
		purchased,
		bench_count,
		int(probe_snapshot.get("frames", 0)),
		avg_wall_fps,
		avg_frame_budget_ms
	])
	print("seeded_offer_ids=%s" % JSON.stringify(seeded_offer_ids))
	print("purchase_reports=%s" % JSON.stringify(purchase_reports))
	print("top_scopes=%s" % JSON.stringify(top_scopes))
	print("shop_scope=%s" % JSON.stringify(_build_key_scope_subset(probe_snapshot.get("scopes", {}), [
		"battlefield_shop_ui_update",
		"battlefield_shop_cards_rebuild",
		"battlefield_inventory_filters_rebuild",
		"battlefield_inventory_items_rebuild",
		"battlefield_inventory_records_build",
		"battlefield_hud_process",
		"battlefield_scene_process"
	])))
	print("samples=%s" % JSON.stringify(_build_key_sample_subset(probe_snapshot.get("samples", {}), [
		"bench_units"
	])))
	print("=== End Recruit Purchase Probe Summary ===")


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


func _build_key_scope_subset(scopes: Dictionary, keys: Array[String]) -> Dictionary:
	var output: Dictionary = {}
	for key in keys:
		if scopes.has(key):
			output[key] = scopes[key]
	return output


func _build_key_sample_subset(samples: Dictionary, keys: Array[String]) -> Dictionary:
	var output: Dictionary = {}
	for key in keys:
		if samples.has(key):
			output[key] = samples[key]
	return output
