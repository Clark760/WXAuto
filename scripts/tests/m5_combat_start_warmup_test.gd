extends SceneTree

const COMBAT_RUNTIME_SERVICE_SCRIPT: Script = preload(
	"res://scripts/combat/combat_runtime_service.gd"
)


class MockMetrics:
	extends RefCounted

	func reset_all_metrics(_manager) -> void:
		return

	func reset_tick_metrics(_manager) -> void:
		return

	func finalize_tick(
		_manager,
		_tick_begin_us: int,
		_allow_attack_phase: bool,
		_allow_move_phase: bool
	) -> void:
		return


class MockSpatialHash:
	extends RefCounted

	func clear() -> void:
		return


class MockUnit:
	extends Node

	var team_id: int = 0
	var alive: bool = true


class MockManager:
	extends Node

	signal battle_started(ally_count: int, enemy_count: int)
	signal battle_ended(winner_team: int, summary: Dictionary)
	signal battle_ended_detail(winner_team: int, summary: Dictionary)

	const TEAM_ALLY: int = 1
	const TEAM_ENEMY: int = 2

	var logic_fps: float = 10.0
	var logic_max_substeps: int = 6
	var split_attack_move_phase: bool = true
	var shuffle_unit_order_each_tick: bool = false
	var loop_animation_reduce_unit_threshold: int = 180

	var _runtime_probe = null
	var _rng := RandomNumberGenerator.new()
	var _metrics: MockMetrics = MockMetrics.new()
	var _terrain_manager = null
	var _battle_running: bool = false
	var _logic_step: float = 0.0
	var _logic_accumulator: float = 0.0
	var _logic_frame: int = 0
	var _logic_time: float = 0.0
	var _next_attack_phase: bool = true
	var _flow_force_rebuild: bool = false
	var _skip_runtime_cache_refresh_once: bool = false

	var _all_units: Array[Node] = []
	var _unit_by_instance_id: Dictionary = {}
	var _dead_registry: Dictionary = {}
	var _unit_position_cache: Dictionary = {}
	var _combat_cache: Dictionary = {}
	var _movement_cache: Dictionary = {}
	var _target_memory: Dictionary = {}
	var _target_refresh_frame: Dictionary = {}
	var _attack_range_target_memory: Dictionary = {999: 123}
	var _attack_range_target_frame: Dictionary = {999: 9}
	var _follow_anchor_by_unit_id: Dictionary = {}
	var _last_move_from_cell: Dictionary = {}
	var _move_replan_cooldown_frame: Dictionary = {}
	var _side_step_cooldown_frame: Dictionary = {}
	var _target_query_ids_scratch: Array[int] = []
	var _loop_animation_reduced: bool = false
	var _group_focus_target_id: Dictionary = {}
	var _group_center: Dictionary = {}
	var _spatial_hash: MockSpatialHash = MockSpatialHash.new()
	var _alive_by_team: Dictionary = {
		TEAM_ALLY: 0,
		TEAM_ENEMY: 0
	}
	var _team_alive_cache: Dictionary = {
		TEAM_ALLY: [],
		TEAM_ENEMY: []
	}
	var _team_cells_cache: Dictionary = {
		TEAM_ALLY: [],
		TEAM_ENEMY: []
	}
	var _cell_occupancy: Dictionary = {}
	var _unit_cell: Dictionary = {}
	var _neighbor_cells_cache: Dictionary = {}
	var _terrain_blocked_cells: Dictionary = {}
	var _last_terrain_cells: Dictionary = {}

	var pre_tick_scan_calls: int = 0
	var group_focus_calls: int = 0
	var follow_anchor_calls: int = 0
	var flow_rebuild_calls: int = 0
	var emitted_alive_count_events: Array[String] = []

	func _register_units(units: Array[Node], team_id: int) -> void:
		for unit in units:
			if not _is_live_unit(unit):
				continue
			var mock_unit: MockUnit = unit as MockUnit
			if mock_unit != null:
				mock_unit.team_id = team_id
			_all_units.append(unit)
			_unit_by_instance_id[unit.get_instance_id()] = unit

	func _pre_tick_scan() -> void:
		pre_tick_scan_calls += 1
		_alive_by_team[TEAM_ALLY] = 0
		_alive_by_team[TEAM_ENEMY] = 0
		_team_alive_cache[TEAM_ALLY] = []
		_team_alive_cache[TEAM_ENEMY] = []
		_unit_by_instance_id.clear()
		for unit in _all_units:
			if not _is_live_unit(unit):
				continue
			if not _is_unit_alive(unit):
				continue
			var team_id: int = int(unit.get("team_id"))
			_alive_by_team[team_id] = int(_alive_by_team.get(team_id, 0)) + 1
			var alive_list: Array = _team_alive_cache.get(team_id, [])
			alive_list.append(unit)
			_team_alive_cache[team_id] = alive_list
			_unit_by_instance_id[unit.get_instance_id()] = unit

	func _emit_team_alive_count_changed(team_id: int) -> void:
		emitted_alive_count_events.append(
			"%d:%d" % [team_id, int(_alive_by_team.get(team_id, 0))]
		)

	func _update_group_ai_focus() -> void:
		group_focus_calls += 1

	func _rebuild_follow_anchor_cache() -> void:
		follow_anchor_calls += 1

	func _rebuild_flow_fields() -> void:
		flow_rebuild_calls += 1

	func _tick_terrain(_delta: float) -> void:
		return

	func _run_unit_logic(
		_unit: Node,
		_delta: float,
		_allow_attack: bool,
		_allow_move: bool
	) -> void:
		return

	func _cleanup_unit_after_battle(_unit: Node, _winner_team: int) -> void:
		return

	func _is_live_unit(unit: Variant) -> bool:
		if not is_instance_valid(unit):
			return false
		return unit is Node

	func _is_unit_alive(unit: Node) -> bool:
		if not _is_live_unit(unit):
			return false
		return bool(unit.get("alive"))

	func clear_temporary_terrains() -> void:
		return

	func _get_effective_flow_refresh_interval() -> int:
		return 5


var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 combat start warmup test failed: %d" % _failed)
		quit(1)
		return
	print("M5 combat start warmup test passed.")
	quit(0)


func _run() -> void:
	_run_spawned_unit_case()
	_run_unchanged_unit_count_case()


func _run_spawned_unit_case() -> void:
	var runtime_service = COMBAT_RUNTIME_SERVICE_SCRIPT.new()
	var manager: MockManager = MockManager.new()
	var ally: MockUnit = MockUnit.new()
	var enemy: MockUnit = MockUnit.new()
	var spawned_ally: MockUnit = MockUnit.new()
	var ally_units: Array[Node] = [ally]
	var enemy_units: Array[Node] = [enemy]

	ally.team_id = MockManager.TEAM_ALLY
	enemy.team_id = MockManager.TEAM_ENEMY
	spawned_ally.team_id = MockManager.TEAM_ALLY
	manager.connect(
		"battle_started",
		Callable(self, "_on_battle_started_spawn_unit").bind(manager, spawned_ally)
	)

	var started: bool = runtime_service.start_battle(
		manager,
		ally_units,
		enemy_units,
		20260329
	)
	_assert_true(started, "start_battle should succeed with one ally and one enemy")
	_assert_true(manager._battle_running, "battle should be running after start_battle")
	_assert_true(
		manager.pre_tick_scan_calls == 2,
		"battle start should prewarm once before and once after battle_started"
	)
	_assert_true(
		manager.group_focus_calls == 2 and manager.follow_anchor_calls == 2,
		"group focus and follow-anchor caches should both be warmed twice"
	)
	_assert_true(
		manager.flow_rebuild_calls == 2,
		"flow fields should be rebuilt before combat and resynced after battle_started"
	)
	_assert_true(
		int(manager._alive_by_team.get(MockManager.TEAM_ALLY, 0)) == 2,
		"post-start sync should include units added by battle_started listeners"
	)
	_assert_true(
		manager._skip_runtime_cache_refresh_once,
		"first combat tick should reuse startup caches once"
	)
	_assert_true(
		manager._attack_range_target_memory.is_empty()
		and manager._attack_range_target_frame.is_empty(),
		"battle reset should clear same-frame attack-range target caches"
	)

	runtime_service.logic_tick(manager, 0.1)
	_assert_true(
		manager.pre_tick_scan_calls == 2,
		"first attack tick should not rebuild runtime caches again"
	)
	_assert_true(
		not manager._skip_runtime_cache_refresh_once,
		"startup cache skip flag should be consumed by the first refresh-capable tick"
	)

	runtime_service.logic_tick(manager, 0.1)
	_assert_true(
		manager.pre_tick_scan_calls == 2,
		"move phase should keep reusing the previous attack-phase caches"
	)

	runtime_service.logic_tick(manager, 0.1)
	_assert_true(
		manager.pre_tick_scan_calls == 3,
		"the next attack phase should resume normal runtime cache refresh"
	)

	manager.free()
	ally.free()
	enemy.free()
	spawned_ally.free()


func _run_unchanged_unit_count_case() -> void:
	var runtime_service = COMBAT_RUNTIME_SERVICE_SCRIPT.new()
	var manager: MockManager = MockManager.new()
	var ally: MockUnit = MockUnit.new()
	var enemy: MockUnit = MockUnit.new()
	var ally_units: Array[Node] = [ally]
	var enemy_units: Array[Node] = [enemy]

	ally.team_id = MockManager.TEAM_ALLY
	enemy.team_id = MockManager.TEAM_ENEMY

	var started: bool = runtime_service.start_battle(
		manager,
		ally_units,
		enemy_units,
		20260330
	)
	_assert_true(started, "start_battle should succeed when no listeners mutate unit count")
	_assert_true(
		manager.pre_tick_scan_calls == 1,
		"battle start should skip post-warm when battle_started does not add units"
	)
	_assert_true(
		manager.group_focus_calls == 1 and manager.follow_anchor_calls == 1,
		"group focus and follow-anchor caches should only warm once when unit count is unchanged"
	)
	_assert_true(
		manager.flow_rebuild_calls == 1,
		"flow fields should only rebuild once when battle_started leaves unit count unchanged"
	)
	_assert_true(
		not manager._skip_runtime_cache_refresh_once,
		"startup cache skip flag should stay disabled when post-warm is skipped"
	)

	runtime_service.logic_tick(manager, 0.1)
	_assert_true(
		manager.pre_tick_scan_calls == 2,
		"first attack tick should rebuild runtime caches immediately when no startup cache skip is scheduled"
	)

	manager.free()
	ally.free()
	enemy.free()


func _on_battle_started_spawn_unit(
	_ally_count: int,
	_enemy_count: int,
	manager: MockManager,
	spawned_ally: MockUnit
) -> void:
	if manager._all_units.has(spawned_ally):
		return
	manager._all_units.append(spawned_ally)
	manager._unit_by_instance_id[spawned_ally.get_instance_id()] = spawned_ally


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
