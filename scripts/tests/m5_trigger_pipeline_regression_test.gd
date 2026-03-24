extends SceneTree

const GONGFA_MANAGER_SCRIPT: Script = preload("res://scripts/gongfa/gongfa_manager.gd")

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2


class MockUnit:
	extends Node2D
	var team_id: int = TEAM_ALLY
	var unit_id: String = ""
	var unit_name: String = ""
	var runtime_stats: Dictionary = {}

	func set_team(next_team: int) -> void:
		team_id = next_team

	func play_anim_state(_state: int, _params: Dictionary = {}) -> void:
		return

	func enter_combat() -> void:
		return

	func leave_combat() -> void:
		return

	func set_on_bench_state(_on_bench: bool, _index: int = -1) -> void:
		return


class MockUnitCombat:
	extends Node
	var is_alive: bool = true
	var current_hp: float = 1000.0
	var max_hp: float = 1000.0
	var current_mp: float = 300.0
	var max_mp: float = 300.0

	func add_mp(amount: float) -> void:
		current_mp = clampf(current_mp + amount, 0.0, max_mp)

	func add_shield(_amount: float) -> void:
		return

	func get_external_modifiers() -> Dictionary:
		return {}


class MockAliveCounter:
	extends Node
	var counts: Dictionary = {
		TEAM_ALLY: 0,
		TEAM_ENEMY: 0
	}

	func set_counts(ally_count: int, enemy_count: int) -> void:
		counts[TEAM_ALLY] = maxi(ally_count, 0)
		counts[TEAM_ENEMY] = maxi(enemy_count, 0)

	func get_team_alive_count(team_id: int, _exclude_unit: Node = null) -> int:
		if team_id == TEAM_ALLY or team_id == TEAM_ENEMY:
			return int(counts.get(team_id, 0))
		return int(counts.get(TEAM_ALLY, 0)) + int(counts.get(TEAM_ENEMY, 0))


var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 trigger pipeline regression tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 trigger pipeline regression tests passed.")
	quit(0)


func _run() -> void:
	_test_event_trigger_pipeline()
	_test_p0_p1_trigger_pipeline()
	_test_trigger_param_filters()
	_test_team_alive_condition_variants()
	_test_last_ally_stun_enemy_5s()


func _test_event_trigger_pipeline() -> void:
	var manager: Node = _build_manager_with_buff_defs()

	var attacker: MockUnit = _make_unit("attacker", TEAM_ALLY, true)
	var ally_survivor: MockUnit = _make_unit("ally_survivor", TEAM_ALLY, true)
	var ally_dead: MockUnit = _make_unit("ally_dead", TEAM_ALLY, false)
	var defender: MockUnit = _make_unit("defender", TEAM_ENEMY, true)

	_setup_runtime_state(
		manager,
		[attacker, ally_survivor, ally_dead, defender],
		{
			"attacker": [
				_build_entry(manager, "gf_start", {
					"trigger": "on_combat_start",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_hit", {
					"trigger": "on_attack_hit",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_kill", {
					"trigger": "on_kill",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				})
			],
			"ally_survivor": [
				_build_entry(manager, "gf_ally_death", {
					"trigger": "on_ally_death",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				})
			],
			"defender": [
				_build_entry(manager, "gf_attacked", {
					"trigger": "on_attacked",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				})
			]
		}
	)

	manager.call("_on_battle_started", 2, 1)
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_combat_start"), 1, "on_combat_start should trigger once")

	manager.call("_on_damage_resolved", {
		"source_id": attacker.get_instance_id(),
		"target_id": defender.get_instance_id(),
		"is_environment": false,
		"is_dodged": false,
		"is_crit": false,
		"shield_broken": false
	})
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_attack_hit"), 1, "on_attack_hit should trigger once")
	_assert_eq_int(_get_trigger_count(manager, defender, "on_attacked"), 1, "on_attacked should trigger once")

	manager.call("_on_unit_died", defender, attacker, TEAM_ENEMY)
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_kill"), 1, "on_kill should trigger once")

	manager.call("_on_unit_died", ally_dead, defender, TEAM_ALLY)
	_assert_eq_int(_get_trigger_count(manager, ally_survivor, "on_ally_death"), 1, "on_ally_death should trigger once")


func _test_p0_p1_trigger_pipeline() -> void:
	var manager: Node = _build_manager_with_buff_defs()
	var attacker: MockUnit = _make_unit("p1_attacker", TEAM_ALLY, true)
	var defender: MockUnit = _make_unit("p1_defender", TEAM_ENEMY, true)
	var mover: MockUnit = _make_unit("p1_mover", TEAM_ALLY, true)

	_setup_runtime_state(
		manager,
		[attacker, defender, mover],
		{
			"p1_attacker": [
				_build_entry(manager, "gf_attack_fail", {
					"trigger": "on_attack_fail",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_move_success", {
					"trigger": "on_unit_move_success",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_move_failed", {
					"trigger": "on_unit_move_failed",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_terrain_created", {
					"trigger": "on_terrain_created",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_terrain_enter", {
					"trigger": "on_terrain_enter",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_terrain_tick", {
					"trigger": "on_terrain_tick",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_terrain_exit", {
					"trigger": "on_terrain_exit",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_terrain_expire", {
					"trigger": "on_terrain_expire",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_spawned", {
					"trigger": "on_unit_spawned_mid_battle",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_alive_changed", {
					"trigger": "on_team_alive_count_changed",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				})
			],
			"p1_defender": [
				_build_entry(manager, "gf_damage_received", {
					"trigger": "on_damage_received",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_heal_received", {
					"trigger": "on_heal_received",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_shield_broken", {
					"trigger": "on_shield_broken",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_on_attacked_guard", {
					"trigger": "on_attacked",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				})
			],
			"p1_mover": [
				_build_entry(manager, "gf_thorns", {
					"trigger": "on_thorns_triggered",
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				})
			]
		}
	)

	manager.call("_on_battle_started", 2, 1)
	manager.call("_on_attack_failed", attacker, defender, "cooldown", {"performed": false, "reason": "cooldown"})
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_attack_fail"), 1, "on_attack_fail should trigger once")

	manager.call("_on_damage_received_detail", defender, attacker, {"damage": 120.0, "shield_absorbed": 0.0})
	_assert_eq_int(_get_trigger_count(manager, defender, "on_damage_received"), 1, "on_damage_received should trigger once")
	_assert_eq_int(_get_trigger_count(manager, defender, "on_attacked"), 0, "detail damage path should not auto-trigger on_attacked")

	manager.call("_on_heal_received", attacker, defender, 88.0, "skill")
	_assert_eq_int(_get_trigger_count(manager, defender, "on_heal_received"), 1, "on_heal_received should trigger once")

	manager.call("_on_shield_broken", defender, attacker, {"damage": 40.0, "shield_broken": true})
	_assert_eq_int(_get_trigger_count(manager, defender, "on_shield_broken"), 1, "on_shield_broken should trigger once")

	manager.call("_on_thorns_triggered", mover, attacker, {"damage": 35.0})
	_assert_eq_int(_get_trigger_count(manager, mover, "on_thorns_triggered"), 1, "on_thorns_triggered should trigger once")

	manager.call("_on_unit_move_success", attacker, Vector2i(1, 1), Vector2i(2, 1), 1)
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_unit_move_success"), 1, "on_unit_move_success should trigger once")

	manager.call("_on_unit_move_failed", attacker, "conflict", {})
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_unit_move_failed"), 1, "on_unit_move_failed should trigger once")

	manager.call("_on_terrain_created", {"terrain_id": "t_fire", "tags": ["fire", "hazard"]}, "add_temporary")
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_terrain_created"), 1, "on_terrain_created should trigger once")

	var terrain_event_base: Dictionary = {
		"terrain_id": "t_fire",
		"terrain_tags": ["fire", "hazard"],
		"target": attacker
	}
	var event_enter: Dictionary = terrain_event_base.duplicate(true)
	event_enter["phase"] = "enter"
	manager.call("_on_terrain_phase_tick", event_enter)
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_terrain_enter"), 1, "on_terrain_enter should trigger once")
	var event_tick: Dictionary = terrain_event_base.duplicate(true)
	event_tick["phase"] = "tick"
	manager.call("_on_terrain_phase_tick", event_tick)
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_terrain_tick"), 1, "on_terrain_tick should trigger once")
	var event_exit: Dictionary = terrain_event_base.duplicate(true)
	event_exit["phase"] = "exit"
	manager.call("_on_terrain_phase_tick", event_exit)
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_terrain_exit"), 1, "on_terrain_exit should trigger once")
	var event_expire: Dictionary = terrain_event_base.duplicate(true)
	event_expire["phase"] = "expire"
	manager.call("_on_terrain_phase_tick", event_expire)
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_terrain_expire"), 1, "on_terrain_expire should trigger once")

	manager.call("_on_unit_spawned_mid_battle", attacker, TEAM_ALLY)
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_unit_spawned_mid_battle"), 1, "on_unit_spawned_mid_battle should trigger once")

	manager.call("_on_team_alive_count_changed", TEAM_ALLY, 2)
	_assert_eq_int(_get_trigger_count(manager, attacker, "on_team_alive_count_changed"), 1, "on_team_alive_count_changed should trigger once")

	# 旧链路回归：on_damage_resolved 仍应只触发一次 on_attacked。
	manager.call("_on_damage_resolved", {
		"source_id": attacker.get_instance_id(),
		"target_id": defender.get_instance_id(),
		"is_environment": false,
		"is_dodged": false,
		"is_crit": false,
		"shield_broken": false
	})
	_assert_eq_int(_get_trigger_count(manager, defender, "on_attacked"), 1, "on_attacked should only trigger once on damage_resolved")


func _test_trigger_param_filters() -> void:
	var manager: Node = _build_manager_with_buff_defs()
	var owner: MockUnit = _make_unit("filter_owner", TEAM_ALLY, true)

	_setup_runtime_state(
		manager,
		[owner],
		{
			"filter_owner": [
				_build_entry(manager, "gf_attack_fail_filter", {
					"trigger": "on_attack_fail",
					"trigger_params": {"reasons": ["cooldown"]},
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_move_fail_filter", {
					"trigger": "on_unit_move_failed",
					"trigger_params": {"reasons": ["conflict"]},
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_damage_min", {
					"trigger": "on_damage_received",
					"trigger_params": {"min_damage": 50},
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_heal_min", {
					"trigger": "on_heal_received",
					"trigger_params": {"min_heal": 30},
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_thorns_min", {
					"trigger": "on_thorns_triggered",
					"trigger_params": {"min_reflect": 20},
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_terrain_tag_any", {
					"trigger": "on_terrain_enter",
					"trigger_params": {"terrain_tags_any": ["poison", "water"]},
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				}),
				_build_entry(manager, "gf_terrain_tag_all", {
					"trigger": "on_terrain_tick",
					"trigger_params": {"terrain_tags_all": ["fire", "hazard"]},
					"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
				})
			]
		}
	)

	manager.call("_on_battle_started", 1, 0)

	manager.call("_on_attack_failed", owner, null, "stunned", {"reason": "stunned"})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_attack_fail"), 0, "on_attack_fail should be blocked by reasons filter")
	manager.call("_on_attack_failed", owner, null, "cooldown", {"reason": "cooldown"})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_attack_fail"), 1, "on_attack_fail should pass reasons filter")

	manager.call("_on_unit_move_failed", owner, "block", {})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_unit_move_failed"), 0, "on_unit_move_failed should be blocked by reasons filter")
	manager.call("_on_unit_move_failed", owner, "conflict", {})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_unit_move_failed"), 1, "on_unit_move_failed should pass reasons filter")

	manager.call("_on_damage_received_detail", owner, null, {"damage": 30.0})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_damage_received"), 0, "on_damage_received should fail min_damage")
	manager.call("_on_damage_received_detail", owner, null, {"damage": 80.0})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_damage_received"), 1, "on_damage_received should pass min_damage")

	manager.call("_on_heal_received", null, owner, 20.0, "regen")
	_assert_eq_int(_get_trigger_count(manager, owner, "on_heal_received"), 0, "on_heal_received should fail min_heal")
	manager.call("_on_heal_received", null, owner, 45.0, "skill")
	_assert_eq_int(_get_trigger_count(manager, owner, "on_heal_received"), 1, "on_heal_received should pass min_heal")

	manager.call("_on_thorns_triggered", owner, null, {"damage": 10.0})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_thorns_triggered"), 0, "on_thorns_triggered should fail min_reflect")
	manager.call("_on_thorns_triggered", owner, null, {"damage": 30.0})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_thorns_triggered"), 1, "on_thorns_triggered should pass min_reflect")

	manager.call("_on_terrain_phase_tick", {
		"phase": "enter",
		"target": owner,
		"terrain_tags": ["earth"]
	})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_terrain_enter"), 0, "terrain_tags_any should block unmatched terrain")
	manager.call("_on_terrain_phase_tick", {
		"phase": "enter",
		"target": owner,
		"terrain_tags": ["water"]
	})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_terrain_enter"), 1, "terrain_tags_any should pass matched terrain")

	manager.call("_on_terrain_phase_tick", {
		"phase": "tick",
		"target": owner,
		"terrain_tags": ["fire"]
	})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_terrain_tick"), 0, "terrain_tags_all should block incomplete terrain")
	manager.call("_on_terrain_phase_tick", {
		"phase": "tick",
		"target": owner,
		"terrain_tags": ["fire", "hazard"]
	})
	_assert_eq_int(_get_trigger_count(manager, owner, "on_terrain_tick"), 1, "terrain_tags_all should pass complete terrain")


func _test_team_alive_condition_variants() -> void:
	var manager: Node = _build_manager_with_buff_defs()
	var owner: MockUnit = _make_unit("owner", TEAM_ALLY, true)
	var counter: MockAliveCounter = MockAliveCounter.new()
	counter.set_counts(2, 3)
	manager.set("_bound_combat_manager", counter)

	var entry_enemy_min_ok: Dictionary = _build_entry(manager, "gf_enemy_min_ok", {
		"trigger": "manual",
		"trigger_params": {
			"team_scope": "enemy",
			"team_alive_count_min": 3
		},
		"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
	})
	_assert_true(bool(manager.call("_can_trigger_entry", owner, entry_enemy_min_ok, {})), "enemy min should pass when enemy_alive=3")

	var entry_enemy_min_fail: Dictionary = _build_entry(manager, "gf_enemy_min_fail", {
		"trigger": "manual",
		"trigger_params": {
			"team_scope": "enemy",
			"team_alive_count_min": 4
		},
		"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
	})
	_assert_true(not bool(manager.call("_can_trigger_entry", owner, entry_enemy_min_fail, {})), "enemy min should fail when enemy_alive=3")

	var entry_all_max_ok: Dictionary = _build_entry(manager, "gf_all_max_ok", {
		"trigger": "manual",
		"trigger_params": {
			"team_scope": "all",
			"exclude_self": true,
			"team_alive_count_max": 4
		},
		"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
	})
	_assert_true(bool(manager.call("_can_trigger_entry", owner, entry_all_max_ok, {})), "all max should pass for (2+3-1)=4")

	var entry_all_max_fail: Dictionary = _build_entry(manager, "gf_all_max_fail", {
		"trigger": "manual",
		"trigger_params": {
			"team_scope": "all",
			"exclude_self": true,
			"team_alive_count_max": 3
		},
		"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
	})
	_assert_true(not bool(manager.call("_can_trigger_entry", owner, entry_all_max_fail, {})), "all max should fail for (2+3-1)=4")


func _test_last_ally_stun_enemy_5s() -> void:
	var manager: Node = _build_manager_with_buff_defs()
	var counter: MockAliveCounter = MockAliveCounter.new()
	counter.set_counts(1, 2)
	manager.set("_bound_combat_manager", counter)

	var caster: MockUnit = _make_unit("caster", TEAM_ALLY, true)
	var dead_ally: MockUnit = _make_unit("dead_ally", TEAM_ALLY, false)
	var enemy_a: MockUnit = _make_unit("enemy_a", TEAM_ENEMY, true)
	var enemy_b: MockUnit = _make_unit("enemy_b", TEAM_ENEMY, true)

	_setup_runtime_state(
		manager,
		[caster, dead_ally, enemy_a, enemy_b],
		{
			"caster": [
				_build_entry(manager, "gf_last_ally", {
					"trigger": "on_ally_death",
					"trigger_params": {
						"team_scope": "ally",
						"exclude_self": true,
						"team_alive_count_max": 0
					},
					"effects": [
						{"op": "debuff_aoe", "radius": 99, "buff_id": "debuff_stun", "duration": 5.0}
					]
				})
			]
		}
	)

	manager.call("_on_unit_died", dead_ally, enemy_a, TEAM_ALLY)
	_assert_eq_int(_get_trigger_count(manager, caster, "on_ally_death"), 1, "last ally condition should trigger once")

	var buff_manager: Variant = manager.get("_buff_manager")
	var enemy_a_buffs: Array[String] = buff_manager.call("get_active_buff_ids_for_unit", enemy_a)
	var enemy_b_buffs: Array[String] = buff_manager.call("get_active_buff_ids_for_unit", enemy_b)
	_assert_true(enemy_a_buffs.has("debuff_stun"), "enemy A should receive stun debuff")
	_assert_true(enemy_b_buffs.has("debuff_stun"), "enemy B should receive stun debuff")

	# Negative case: ally alive count excludes self -> 1, should fail max=0.
	var manager_fail: Node = _build_manager_with_buff_defs()
	var counter_fail: MockAliveCounter = MockAliveCounter.new()
	counter_fail.set_counts(2, 1)
	manager_fail.set("_bound_combat_manager", counter_fail)

	var caster_fail: MockUnit = _make_unit("caster_fail", TEAM_ALLY, true)
	var alive_ally: MockUnit = _make_unit("alive_ally", TEAM_ALLY, true)
	var dead_ally_fail: MockUnit = _make_unit("dead_ally_fail", TEAM_ALLY, false)
	var enemy_fail: MockUnit = _make_unit("enemy_fail", TEAM_ENEMY, true)
	_setup_runtime_state(
		manager_fail,
		[caster_fail, alive_ally, dead_ally_fail, enemy_fail],
		{
			"caster_fail": [
				_build_entry(manager_fail, "gf_last_ally_fail", {
					"trigger": "on_ally_death",
					"trigger_params": {
						"team_scope": "ally",
						"exclude_self": true,
						"team_alive_count_max": 0
					},
					"effects": [
						{"op": "debuff_aoe", "radius": 99, "buff_id": "debuff_stun", "duration": 5.0}
					]
				})
			]
		}
	)
	manager_fail.call("_on_unit_died", dead_ally_fail, enemy_fail, TEAM_ALLY)
	_assert_eq_int(_get_trigger_count(manager_fail, caster_fail, "on_ally_death"), 0, "alive ally exists, last ally condition should not trigger")


func _build_manager_with_buff_defs() -> Node:
	var manager: Node = GONGFA_MANAGER_SCRIPT.new()
	var buff_manager: Variant = manager.get("_buff_manager")
	buff_manager.call("set_buff_definitions", {
		"buff_test": {
			"id": "buff_test",
			"type": "buff",
			"default_duration": 2.0,
			"effects": []
		},
		"debuff_stun": {
			"id": "debuff_stun",
			"type": "debuff",
			"default_duration": 2.0,
			"effects": []
		}
	})
	return manager


func _setup_runtime_state(manager: Node, units: Array, trigger_map: Dictionary) -> void:
	var battle_units: Array[Node] = []
	var lookup: Dictionary = {}
	var states: Dictionary = {}
	for unit_value in units:
		if not (unit_value is Node):
			continue
		var unit: Node = unit_value as Node
		battle_units.append(unit)
		lookup[unit.get_instance_id()] = unit
		var entries: Array = []
		var unit_id_key: String = str(unit.get("unit_id")).strip_edges()
		if trigger_map.has(unit_id_key):
			entries = (trigger_map[unit_id_key] as Array).duplicate(true)
		states[unit.get_instance_id()] = {
			"unit": unit,
			"triggers": entries,
			"passive_effects": [],
			"equipment_effects": []
		}
	manager.set("_battle_units", battle_units)
	manager.set("_unit_lookup", lookup)
	manager.set("_unit_states", states)


func _build_entry(manager: Node, owner_id: String, skill_data: Dictionary) -> Dictionary:
	return manager.call("_build_trigger_entry", owner_id, skill_data)


func _get_trigger_count(manager: Node, unit: Node, trigger_name: String) -> int:
	var states: Dictionary = manager.get("_unit_states")
	if not states.has(unit.get_instance_id()):
		return 0
	var state: Dictionary = states[unit.get_instance_id()]
	var triggers: Array = state.get("triggers", [])
	for entry_value in triggers:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		if str(entry.get("trigger", "")).strip_edges().to_lower() != trigger_name.strip_edges().to_lower():
			continue
		return int(entry.get("trigger_count", 0))
	return 0


func _make_unit(id_value: String, team_id: int, is_alive: bool) -> MockUnit:
	var unit: MockUnit = MockUnit.new()
	unit.unit_id = id_value
	unit.unit_name = id_value
	unit.team_id = team_id
	var components: Node = Node.new()
	components.name = "Components"
	unit.add_child(components)
	var combat: MockUnitCombat = MockUnitCombat.new()
	combat.name = "UnitCombat"
	combat.is_alive = is_alive
	components.add_child(combat)
	return unit


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)


func _assert_eq_int(actual: int, expected: int, message: String) -> void:
	if actual == expected:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s (actual=%d expected=%d)" % [message, actual, expected])
