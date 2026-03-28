extends SceneTree

const ROOT := "res://"
const COVERAGE_SELF_PATH := "res://scripts/tests/m5_expansion_coverage_check.gd"
const BUFF_DATA_DIR := "res://mods/base/data/buffs"
const EQUIPMENT_DATA_DIR := "res://mods/base/data/equipment"
const GONGFA_DATA_DIR := "res://mods/base/data/gongfa"
const TERRAIN_DATA_DIR := "res://mods/base/data/terrains"
const EXPECTED_BUFF_COUNT: int = 46
const EXPECTED_EQUIPMENT_COUNT: int = 156
const EXPECTED_GONGFA_COUNT: int = 172
const EXPECTED_TERRAIN_COUNT: int = 8

const EXPECTED_PASSIVE_OPS: Array[String] = [
	"hp_regen_add",
	"vampire",
	"damage_amp_percent",
	"damage_amp_vs_debuffed",
	"crit_damage_bonus",
	"tenacity",
	"thorns_percent",
	"thorns_flat",
	"shield_on_combat_start",
	"execute_threshold",
	"healing_amp",
	"mp_on_kill",
	"conditional_stat"
]

const EXPECTED_ACTIVE_OPS: Array[String] = [
	"damage_target_scaling",
	"damage_if_debuffed",
	"damage_chain",
	"damage_cone",
	"heal_lowest_ally",
	"heal_percent_missing_hp",
	"shield_self",
	"shield_allies_aoe",
	"cleanse_self",
	"cleanse_ally",
	"steal_buff",
	"dispel_target",
	"pull_target",
	"knockback_aoe",
	"swap_position",
	"create_terrain",
	"mark_target",
	"damage_if_marked",
	"execute_target",
	"drain_mp",
	"silence_target",
	"stun_target",
	"fear_aoe",
	"freeze_target",
	"resurrect_self",
	"aoe_percent_hp_damage"
]

const EXPECTED_TRIGGERS: Array[String] = [
	"on_crit",
	"on_dodge",
	"on_hp_below",
	"on_debuff_applied",
	"on_buff_expire",
	"periodic"
]

const EXPECTED_TERRAIN_MARKERS: Array[String] = [
	"bm5.terrain.fire",
	"bm5.terrain.ice",
	"bm5.terrain.heal",
	"bm5.terrain.rock",
	"bm5.terrain.bamboo",
	"bm5.terrain.marsh",
	"terrain.hazard",
	"terrain.beneficial",
	"terrain.obstacle"
]

var _failed: int = 0


func _init() -> void:
	_run_checks()
	if _failed > 0:
		push_error("M5 expansion coverage checks failed: %d" % _failed)
		quit(1)
		return
	print("M5 expansion coverage checks passed.")
	quit(0)


func _run_checks() -> void:
	var effect_engine_text: String = _join_texts([
		"res://scripts/unit_augment/unit_augment_effect_engine.gd",
		"res://scripts/unit_augment/unit_augment_effect_runtime_gateway.gd",
		"res://scripts/domain/unit_augment/effects/active_effect_dispatcher.gd",
		"res://scripts/domain/unit_augment/effects/passive_effect_applier.gd",
		"res://scripts/domain/unit_augment/effects/effect_summary_collector.gd",
		"res://scripts/domain/unit_augment/effects/target_query_service.gd",
		"res://scripts/domain/unit_augment/effects/hex_spatial_service.gd",
		"res://scripts/domain/unit_augment/effects/damage_resource_ops.gd",
		"res://scripts/domain/unit_augment/effects/buff_control_ops.gd",
		"res://scripts/domain/unit_augment/effects/movement_control_ops.gd",
		"res://scripts/domain/unit_augment/effects/summon_terrain_ops.gd",
		"res://scripts/domain/unit_augment/effects/tag_linkage_ops.gd"
	])
	var unit_augment_text: String = _join_texts([
		"res://scripts/unit_augment/unit_augment_manager.gd",
		"res://scripts/unit_augment/unit_augment_trigger_runtime.gd",
		"res://scripts/unit_augment/unit_augment_trigger_condition_service.gd",
		"res://scripts/unit_augment/unit_augment_trigger_execution_service.gd",
		"res://scripts/unit_augment/unit_augment_combat_event_bridge.gd",
		"res://scripts/unit_augment/unit_augment_unit_state_service.gd"
	])
	var active_scripts_text: String = _join_texts(_collect_files_under_dir(
		"res://scripts",
		".gd",
		["res://scripts/tests"]
	))
	var test_script_paths: Array[String] = _collect_files_under_dir("res://scripts/tests", ".gd")
	test_script_paths.erase(COVERAGE_SELF_PATH)
	var test_scripts_text: String = _join_texts(test_script_paths)
	var combat_manager_text: String = _read_text("res://scripts/combat/combat_manager.gd")
	var vfx_factory_text: String = _read_text("res://scripts/vfx/vfx_factory.gd")
	var unit_augment_manager_text: String = _read_text("res://scripts/unit_augment/unit_augment_manager.gd")
	var battlefield_scene_text: String = _read_text("res://scripts/app/battlefield/battlefield_scene.gd")
	var economy_manager_text: String = _read_text("res://scripts/economy/economy_manager.gd")
	var shop_manager_text: String = _read_text("res://scripts/economy/shop_manager.gd")
	var reward_manager_text: String = _read_text("res://scripts/stage/reward_manager.gd")
	var stage_manager_text: String = _read_text("res://scripts/stage/stage_manager.gd")
	var battlefield_coordinator_text: String = _read_text("res://scripts/app/battlefield/battlefield_coordinator.gd")
	var battlefield_economy_support_text: String = _read_text("res://scripts/app/battlefield/battlefield_coordinator_economy_support.gd")
	var battlefield_layout_support_text: String = _read_text("res://scripts/app/battlefield/battlefield_coordinator_layout_support.gd")
	var battlefield_statistics_support_text: String = _read_text("res://scripts/app/battlefield/battlefield_coordinator_statistics_support.gd")
	var battlefield_hud_support_text: String = _read_text("res://scripts/app/battlefield/battlefield_hud_support.gd")
	var battlefield_hud_detail_view_text: String = _read_text("res://scripts/app/battlefield/battlefield_hud_detail_view.gd")
	var battlefield_hud_shop_inventory_view_text: String = _read_text("res://scripts/app/battlefield/battlefield_hud_shop_inventory_view.gd")
	var battlefield_hud_runtime_view_text: String = _read_text("res://scripts/app/battlefield/battlefield_hud_runtime_view.gd")
	var battlefield_hud_presenter_text: String = _read_text("res://scripts/app/battlefield/battlefield_hud_presenter.gd")
	var main_scene_text: String = _read_text("res://scripts/main/main_scene.gd")
	var data_manager_text: String = _read_text("res://scripts/data/data_manager.gd")
	var mod_loader_text: String = _read_text("res://scripts/core/mod_loader.gd")
	var object_pool_text: String = _read_text("res://scripts/core/object_pool.gd")
	var obstacle_manager_text: String = _read_text("res://scripts/stage/obstacle_manager.gd")
	var app_root_text: String = _read_text("res://scripts/infra/app_root.gd")
	var app_session_state_text: String = _read_text("res://scripts/infra/app_session_state.gd")
	var scene_navigator_text: String = _read_text("res://scripts/infra/scene_navigator.gd")
	var battle_stats_panel_text: String = _read_text("res://scripts/ui/battle_stats_panel.gd")
	var battle_statistics_text: String = _read_text("res://scripts/battle/battle_statistics.gd")
	var terrain_data_text: String = _join_texts(_collect_files_under_dir(TERRAIN_DATA_DIR, ".json"))
	var project_text: String = _read_text("res://project.godot")

	_assert_none_missing("passive_ops", EXPECTED_PASSIVE_OPS, effect_engine_text)
	_assert_none_missing("active_ops", EXPECTED_ACTIVE_OPS, effect_engine_text)
	_assert_none_missing("triggers", EXPECTED_TRIGGERS, unit_augment_text)
	_assert_none_missing("terrain_markers", EXPECTED_TERRAIN_MARKERS, terrain_data_text)

	_check_data_counts()
	_check_effect_engine_cleanup(project_text, active_scripts_text, test_scripts_text)
	_check_combat_split(combat_manager_text, active_scripts_text)
	_check_runtime_service_injection(
		combat_manager_text,
		vfx_factory_text,
		unit_augment_manager_text,
		battlefield_scene_text
	)
	_check_runtime_service_calls_removed(
		economy_manager_text,
		shop_manager_text,
		reward_manager_text,
		stage_manager_text,
		battlefield_coordinator_text,
		battlefield_economy_support_text,
		main_scene_text,
		data_manager_text,
		mod_loader_text,
		object_pool_text
	)
	_check_domain_migrations(
		active_scripts_text,
		test_scripts_text,
		economy_manager_text,
		shop_manager_text,
		battle_statistics_text
	)
	_check_phase4_hud_and_infra_calls_removed(
		battlefield_scene_text,
		battlefield_layout_support_text,
		battlefield_statistics_support_text,
		battlefield_hud_support_text,
		battlefield_hud_detail_view_text,
		battlefield_hud_shop_inventory_view_text,
		battlefield_hud_runtime_view_text,
		battlefield_hud_presenter_text,
		obstacle_manager_text,
		app_root_text,
		app_session_state_text,
		scene_navigator_text,
		battle_stats_panel_text
	)
	_check_linkage_removed()


func _check_data_counts() -> void:
	var buffs: Array = _load_json_arrays_from_dir(BUFF_DATA_DIR)
	var equips: Array = _load_json_arrays_from_dir(EQUIPMENT_DATA_DIR)
	var gongfa: Array = _load_json_arrays_from_dir(GONGFA_DATA_DIR)
	var terrains: Array = _load_json_arrays_from_dir(TERRAIN_DATA_DIR)

	_assert_true(buffs.size() == EXPECTED_BUFF_COUNT, "buff_count == %d (actual=%d)" % [EXPECTED_BUFF_COUNT, buffs.size()])
	_assert_true(equips.size() == EXPECTED_EQUIPMENT_COUNT, "equipment_count == %d (actual=%d)" % [EXPECTED_EQUIPMENT_COUNT, equips.size()])
	_assert_true(gongfa.size() == EXPECTED_GONGFA_COUNT, "gongfa_count == %d (actual=%d)" % [EXPECTED_GONGFA_COUNT, gongfa.size()])
	_assert_true(terrains.size() == EXPECTED_TERRAIN_COUNT, "terrain_count == %d (actual=%d)" % [EXPECTED_TERRAIN_COUNT, terrains.size()])

	var equip_with_trigger: int = 0
	for row_value in equips:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value
		var trigger: Dictionary = row.get("trigger", {})
		var trigger_type: String = str(trigger.get("type", "")).strip_edges()
		var effects: Array = trigger.get("effects", [])
		if not trigger_type.is_empty() and not effects.is_empty():
			equip_with_trigger += 1
	_assert_true(
		equip_with_trigger == EXPECTED_EQUIPMENT_COUNT,
		"equipment_with_trigger == %d (actual=%d)" % [EXPECTED_EQUIPMENT_COUNT, equip_with_trigger]
	)


func _check_linkage_removed() -> void:
	_assert_true(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://scripts/gongfa")), "legacy scripts/gongfa removed")
	_assert_true(not FileAccess.file_exists("res://scripts/gongfa/linkage_detector.gd"), "linkage_detector.gd removed")
	_assert_true(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://data/linkages")), "data/linkages removed")
	_assert_true(not FileAccess.file_exists("res://data/_schema/linkage.schema.json"), "linkage.schema.json removed")


func _check_effect_engine_cleanup(project_text: String, active_scripts_text: String, test_scripts_text: String) -> void:
	_assert_true(
		project_text.find('run/main_scene="res://scenes/app/app_root.tscn"') != -1,
		"project main scene should point to AppRoot"
	)
	_assert_true(
		project_text.find("[autoload]") == -1,
		"project should not keep runtime provider autoloads"
	)
	_assert_true(
		project_text.find("GameManager=") == -1,
		"project should not keep GameManager autoload"
	)
	_assert_true(
		not FileAccess.file_exists("res://scripts/core/game_manager.gd"),
		"legacy game_manager.gd removed"
	)
	_assert_true(
		project_text.find("GongfaManager=") == -1,
		"project should not keep legacy GongfaManager autoload"
	)
	_assert_true(not FileAccess.file_exists("res://scripts/gongfa/effect_engine.gd"), "legacy effect_engine.gd removed")
	_assert_true(
		not FileAccess.file_exists("res://scripts/domain/gongfa/effects/active_effect_dispatcher.gd"),
		"legacy active_effect_dispatcher.gd removed"
	)
	_assert_true(
		not FileAccess.file_exists("res://scripts/domain/gongfa/effects/passive_effect_applier.gd"),
		"legacy passive_effect_applier.gd removed"
	)
	_assert_true(
		not FileAccess.file_exists("res://scripts/domain/gongfa/effects/effect_op_handlers.gd"),
		"legacy effect_op_handlers.gd removed"
	)
	_assert_true(
		not FileAccess.file_exists("res://scripts/gongfa/gongfa_manager.gd"),
		"legacy gongfa_manager.gd removed"
	)
	_assert_true(
		not FileAccess.file_exists("res://scripts/gongfa/buff_manager.gd"),
		"legacy buff_manager.gd removed"
	)
	_assert_true(
		not FileAccess.file_exists("res://scripts/gongfa/tag_linkage_resolver.gd"),
		"legacy tag_linkage_resolver.gd removed"
	)
	_assert_true(
		not FileAccess.file_exists("res://scripts/gongfa/tag_linkage_runtime_scheduler.gd"),
		"legacy tag_linkage_runtime_scheduler.gd removed"
	)
	_assert_true(
		active_scripts_text.find("res://scripts/gongfa/") == -1,
		"active scripts should not reference any legacy scripts/gongfa path"
	)
	_assert_true(
		test_scripts_text.find("res://scripts/gongfa/") == -1,
		"tests should not reference any legacy scripts/gongfa path"
	)
	_assert_true(
		active_scripts_text.find("res://scripts/gongfa/effect_engine.gd") == -1,
		"active scripts should not reference legacy effect_engine.gd"
	)
	_assert_true(
		test_scripts_text.find("res://scripts/gongfa/effect_engine.gd") == -1,
		"tests should not reference legacy effect_engine.gd"
	)
	_assert_true(
		active_scripts_text.find("res://scripts/domain/gongfa/effects/") == -1,
		"active scripts should not reference legacy domain/gongfa effects"
	)
	_assert_true(
		test_scripts_text.find("res://scripts/domain/gongfa/effects/") == -1,
		"tests should not reference legacy domain/gongfa effects"
	)
	_assert_true(
		active_scripts_text.find("res://scripts/gongfa/gongfa_manager.gd") == -1,
		"active scripts should not reference legacy gongfa_manager.gd"
	)
	_assert_true(
		test_scripts_text.find("res://scripts/gongfa/gongfa_manager.gd") == -1,
		"tests should not reference legacy gongfa_manager.gd"
	)
	_assert_true(
		active_scripts_text.find("\"gongfa_manager\"") == -1,
		"active scripts should not emit legacy gongfa_manager context key"
	)
	_assert_true(
		test_scripts_text.find("\"gongfa_manager\"") == -1,
		"tests should not emit legacy gongfa_manager context key"
	)
	_assert_true(
		active_scripts_text.find("gongfa_data_reloaded") == -1,
		"active scripts should not reference legacy gongfa_data_reloaded signal"
	)
	_assert_true(
		test_scripts_text.find("gongfa_data_reloaded") == -1,
		"tests should not reference legacy gongfa_data_reloaded signal"
	)
	_assert_true(
		active_scripts_text.find("class_name GongfaEffectEngine") == -1,
		"legacy GongfaEffectEngine class removed"
	)
	_assert_true(
		active_scripts_text.find("class_name ActiveEffectDispatcher") == -1,
		"legacy ActiveEffectDispatcher class removed"
	)
	_assert_true(
		active_scripts_text.find("class_name PassiveEffectApplier") == -1,
		"legacy PassiveEffectApplier class removed"
	)
	_assert_true(
		active_scripts_text.find("class_name EffectOpHandlers") == -1,
		"legacy EffectOpHandlers class removed"
	)


func _check_combat_split(combat_manager_text: String, active_scripts_text: String) -> void:
	var required_combat_services: Array[String] = [
		"res://scripts/combat/combat_runtime_service.gd",
		"res://scripts/combat/combat_unit_registry.gd",
		"res://scripts/combat/combat_movement_service.gd",
		"res://scripts/combat/combat_attack_service.gd",
		"res://scripts/combat/combat_terrain_service.gd",
		"res://scripts/combat/combat_event_bridge.gd"
	]
	for path in required_combat_services:
		_assert_true(FileAccess.file_exists(path), "combat split file exists: %s" % path)
		_assert_true(
			active_scripts_text.find(path) != -1,
			"active scripts should reference combat split file: %s" % path
		)

	_assert_true(
		combat_manager_text.find("COMBAT_MOVEMENT_SERVICE_SCRIPT") != -1,
		"combat_manager should preload movement service"
	)
	_assert_true(
		combat_manager_text.find("COMBAT_ATTACK_SERVICE_SCRIPT") != -1,
		"combat_manager should preload attack service"
	)
	_assert_true(
		combat_manager_text.find("COMBAT_TERRAIN_SERVICE_SCRIPT") != -1,
		"combat_manager should preload terrain service"
	)
	_assert_true(
		combat_manager_text.find("COMBAT_EVENT_BRIDGE_SCRIPT") != -1,
		"combat_manager should preload event bridge"
	)
	_assert_true(
		combat_manager_text.find("_movement_service.run_unit_logic(self, unit, delta, allow_attack, allow_move)") != -1,
		"combat_manager should forward unit logic to movement service"
	)
	_assert_true(
		combat_manager_text.find("_attack_service.try_execute_attack(self, unit, combat, target)") != -1,
		"combat_manager should forward attack execution to attack service"
	)
	_assert_true(
		combat_manager_text.find("_terrain_service.tick_terrain(self, delta)") != -1,
		"combat_manager should forward terrain tick to terrain service"
	)
	_assert_true(
		combat_manager_text.find("_event_bridge_service.notify_unit_cell_changed(self, unit, from_cell, to_cell)") != -1,
		"combat_manager should forward unit cell events to event bridge"
	)

	# 这些旧实现体片段曾经直接长在 facade 内，收口后不允许回流。
	_assert_true(
		combat_manager_text.find("var attack_dir: Vector2 = (target.position - source.position).normalized()") == -1,
		"combat_manager should not keep inline attack resolved body"
	)
	_assert_true(
		combat_manager_text.find("var phase_events_value: Variant = tick_result.get(\"phase_events\", [])") == -1,
		"combat_manager should not keep inline terrain tick body"
	)
	_assert_true(
		combat_manager_text.find("combat.call(\"tick_logic\", delta)") == -1,
		"combat_manager should not keep inline unit logic body"
	)


func _check_runtime_service_injection(
	combat_manager_text: String,
	vfx_factory_text: String,
	unit_augment_manager_text: String,
	battlefield_scene_text: String
) -> void:
	_assert_true(
		combat_manager_text.find("bind_runtime_services(services: ServiceRegistry)") != -1,
		"combat_manager should expose bind_runtime_services"
	)
	_assert_true(
		combat_manager_text.find("tree.root.get_node_or_null(\"DataManager\")") == -1,
		"combat_manager should not resolve DataManager from root"
	)
	_assert_true(
		combat_manager_text.find("tree.root.get_node_or_null(\"UnitAugmentManager\")") == -1,
		"combat_manager should not resolve UnitAugmentManager from root"
	)
	_assert_true(
		vfx_factory_text.find("bind_runtime_services(services: ServiceRegistry)") != -1,
		"vfx_factory should expose bind_runtime_services"
	)
	_assert_true(
		vfx_factory_text.find("Engine.get_main_loop()") == -1,
		"vfx_factory should not depend on Engine.get_main_loop"
	)
	_assert_true(
		vfx_factory_text.find("tree.root.get_node_or_null(\"EventBus\")") == -1,
		"vfx_factory should not resolve EventBus from root"
	)
	_assert_true(
		vfx_factory_text.find("tree.root.get_node_or_null(\"DataManager\")") == -1,
		"vfx_factory should not resolve DataManager from root"
	)
	_assert_true(
		vfx_factory_text.find("tree.root.get_node_or_null(\"ObjectPool\")") == -1,
		"vfx_factory should not resolve ObjectPool from root"
	)
	_assert_true(
		unit_augment_manager_text.find("Engine.get_main_loop()") == -1,
		"unit_augment_manager should not keep Engine.get_main_loop helper"
	)
	_assert_true(
		battlefield_scene_text.find("_bind_runtime_services_on_path(\"CombatManager\")") != -1,
		"battlefield_scene should inject CombatManager services explicitly"
	)
	_assert_true(
		battlefield_scene_text.find("_bind_runtime_services_on_path(\"WorldContainer/VfxLayer/VfxFactory\")") != -1,
		"battlefield_scene should inject VfxFactory services explicitly"
	)


func _check_runtime_service_calls_removed(
	economy_manager_text: String,
	shop_manager_text: String,
	reward_manager_text: String,
	stage_manager_text: String,
	battlefield_coordinator_text: String,
	battlefield_economy_support_text: String,
	main_scene_text: String,
	data_manager_text: String,
	mod_loader_text: String,
	object_pool_text: String
) -> void:
	_assert_true(
		economy_manager_text.find("data_manager.call(") == -1,
		"economy_manager should not use data_manager.call"
	)
	_assert_true(
		shop_manager_text.find("unit_factory.call(") == -1,
		"shop_manager should not use unit_factory.call"
	)
	_assert_true(
		shop_manager_text.find("unit_augment_manager.call(") == -1,
		"shop_manager should not use unit_augment_manager.call"
	)
	_assert_true(
		reward_manager_text.find("economy_manager.call(") == -1,
		"reward_manager should not use economy_manager.call"
	)
	_assert_true(
		reward_manager_text.find("battlefield.call(") == -1,
		"reward_manager should not use battlefield.call"
	)
	_assert_true(
		reward_manager_text.find("unit_factory.call(") == -1,
		"reward_manager should not keep unit_factory fallback call chain"
	)
	_assert_true(
		stage_manager_text.find("data_manager.call(") == -1,
		"stage_manager should not use data_manager.call"
	)
	_assert_true(
		stage_manager_text.find("event_bus.call(") == -1,
		"stage_manager should not use event_bus.call"
	)
	_assert_true(
		stage_manager_text.find("callv(") == -1,
		"stage_manager should not use callv for stage event dispatch"
	)
	_assert_true(
		battlefield_coordinator_text.find("runtime_economy_manager.call(") == -1,
		"battlefield_coordinator should not use runtime_economy_manager.call"
	)
	_assert_true(
		battlefield_coordinator_text.find("runtime_stage_manager.call(") == -1,
		"battlefield_coordinator should not use runtime_stage_manager.call"
	)
	_assert_true(
		battlefield_economy_support_text.find("runtime_economy_manager.call(") == -1,
		"battlefield_coordinator_economy_support should not use runtime_economy_manager.call"
	)
	_assert_true(
		battlefield_economy_support_text.find("runtime_shop_manager.call(") == -1,
		"battlefield_coordinator_economy_support should not use runtime_shop_manager.call"
	)
	_assert_true(
		battlefield_economy_support_text.find("unit_factory.call(") == -1,
		"battlefield_coordinator_economy_support should not use unit_factory.call"
	)
	_assert_true(
		battlefield_economy_support_text.find("runtime_unit_deploy_manager.call(") == -1,
		"battlefield_coordinator_economy_support should not use runtime_unit_deploy_manager.call"
	)
	_assert_true(
		battlefield_economy_support_text.find("unit_augment_manager.call(") == -1,
		"battlefield_coordinator_economy_support should not use unit_augment_manager.call"
	)
	_assert_true(
		main_scene_text.find("data_manager.call(") == -1,
		"main_scene should not use data_manager.call"
	)
	_assert_true(
		data_manager_text.find("event_bus.call(") == -1,
		"data_manager should not use event_bus.call"
	)
	_assert_true(
		mod_loader_text.find("data_manager.call(") == -1,
		"mod_loader should not use data_manager.call"
	)
	_assert_true(
		mod_loader_text.find("event_bus.call(") == -1,
		"mod_loader should not use event_bus.call"
	)
	_assert_true(
		object_pool_text.find("event_bus.call(") == -1,
		"object_pool should not use event_bus.call"
	)


func _check_domain_migrations(
	active_scripts_text: String,
	test_scripts_text: String,
	economy_manager_text: String,
	shop_manager_text: String,
	battle_statistics_text: String
) -> void:
	var required_domain_files: Array[String] = [
		"res://scripts/domain/unit/unit_data.gd",
		"res://scripts/domain/economy/economy_progression_service.gd",
		"res://scripts/domain/shop/shop_catalog_service.gd",
		"res://scripts/domain/combat/battle_statistics_service.gd"
	]
	for path in required_domain_files:
		_assert_true(FileAccess.file_exists(path), "domain migration file exists: %s" % path)

	_assert_true(
		not FileAccess.file_exists("res://scripts/data/unit_data.gd"),
		"legacy unit_data.gd removed"
	)
	_assert_true(
		active_scripts_text.find("res://scripts/data/unit_data.gd") == -1,
		"active scripts should not reference legacy unit_data.gd"
	)
	_assert_true(
		test_scripts_text.find("res://scripts/data/unit_data.gd") == -1,
		"tests should not reference legacy unit_data.gd"
	)
	_assert_true(
		active_scripts_text.find("res://scripts/domain/unit/unit_data.gd") != -1,
		"active scripts should reference domain unit_data.gd"
	)
	_assert_true(
		economy_manager_text.find("res://scripts/domain/economy/economy_progression_service.gd") != -1,
		"economy_manager should delegate to domain economy_progression_service"
	)
	_assert_true(
		economy_manager_text.find("DEFAULT_LEVEL_ROWS") == -1,
		"economy_manager should not keep level curve rules inline"
	)
	_assert_true(
		shop_manager_text.find("res://scripts/domain/shop/shop_catalog_service.gd") != -1,
		"shop_manager should delegate to domain shop_catalog_service"
	)
	_assert_true(
		shop_manager_text.find("_generate_recruit_offers") == -1,
		"shop_manager should not keep recruit offer generation inline"
	)
	_assert_true(
		shop_manager_text.find("_rebuild_unit_pool") == -1,
		"shop_manager should not keep pool rebuild logic inline"
	)
	_assert_true(
		battle_statistics_text.find("res://scripts/domain/combat/battle_statistics_service.gd") != -1,
		"battle_statistics should delegate to domain battle_statistics_service"
	)
	_assert_true(
		battle_statistics_text.find("_register_fallback_unit") == -1,
		"battle_statistics wrapper should not keep fallback registration rules inline"
	)
	_assert_true(
		battle_statistics_text.find("_unit_stats") == -1,
		"battle_statistics wrapper should not keep statistics state inline"
	)


func _check_phase4_hud_and_infra_calls_removed(
	battlefield_scene_text: String,
	battlefield_layout_support_text: String,
	battlefield_statistics_support_text: String,
	battlefield_hud_support_text: String,
	battlefield_hud_detail_view_text: String,
	battlefield_hud_shop_inventory_view_text: String,
	battlefield_hud_runtime_view_text: String,
	battlefield_hud_presenter_text: String,
	obstacle_manager_text: String,
	app_root_text: String,
	app_session_state_text: String,
	scene_navigator_text: String,
	battle_stats_panel_text: String
) -> void:
	_assert_true(
		battlefield_scene_text.find('runtime_node.call("bind_runtime_services"') == -1,
		"battlefield_scene should not use runtime_node.call for service injection"
	)
	_assert_true(
		battlefield_layout_support_text.find("bench_ui.call(") == -1,
		"battlefield_coordinator_layout_support should not use bench_ui.call"
	)
	_assert_true(
		battlefield_layout_support_text.find("recycle_drop_zone.call(") == -1,
		"battlefield_coordinator_layout_support should not use recycle_drop_zone.call"
	)
	_assert_true(
		battlefield_statistics_support_text.find("battle_stats_panel.call(") == -1,
		"battlefield_coordinator_statistics_support should not use battle_stats_panel.call"
	)
	_assert_true(
		battlefield_statistics_support_text.find("_battle_statistics.call(") == -1,
		"battlefield_coordinator_statistics_support should not use battle_statistics.call"
	)
	_assert_true(
		battlefield_hud_support_text.find("unit_augment_manager.call(") == -1,
		"battlefield_hud_support should not use unit_augment_manager.call"
	)
	_assert_true(
		battlefield_hud_support_text.find("combat_manager.call(") == -1,
		"battlefield_hud_support should not use combat_manager.call"
	)
	_assert_true(
		battlefield_hud_support_text.find("bench_ui.call(") == -1,
		"battlefield_hud_support should not use bench_ui.call"
	)
	_assert_true(
		battlefield_hud_detail_view_text.find("unit_augment_manager.call(") == -1,
		"battlefield_hud_detail_view should not use unit_augment_manager.call"
	)
	_assert_true(
		battlefield_hud_shop_inventory_view_text.find("runtime_economy_manager.call(") == -1,
		"battlefield_hud_shop_inventory_view should not use runtime_economy_manager.call"
	)
	_assert_true(
		battlefield_hud_shop_inventory_view_text.find("runtime_shop_manager.call(") == -1,
		"battlefield_hud_shop_inventory_view should not use runtime_shop_manager.call"
	)
	_assert_true(
		battlefield_hud_shop_inventory_view_text.find("unit_augment_manager.call(") == -1,
		"battlefield_hud_shop_inventory_view should not use unit_augment_manager.call"
	)
	_assert_true(
		battlefield_hud_runtime_view_text.find("combat_manager.call(") == -1,
		"battlefield_hud_runtime_view should not use combat_manager.call"
	)
	_assert_true(
		battlefield_hud_presenter_text.find("battle_stats_panel.call(") == -1,
		"battlefield_hud_presenter should not use battle_stats_panel.call"
	)
	_assert_true(
		obstacle_manager_text.find("hex_grid.call(") == -1,
		"obstacle_manager should not use hex_grid.call"
	)
	_assert_true(
		app_root_text.find("service_node.call(") == -1,
		"app_root should not use service_node.call"
	)
	_assert_true(
		app_session_state_text.find("_event_bus.call(") == -1,
		"app_session_state should not use _event_bus.call"
	)
	_assert_true(
		scene_navigator_text.find("next_scene.call(") == -1,
		"scene_navigator should not use next_scene.call"
	)
	_assert_true(
		scene_navigator_text.find("data_repository.call(") == -1,
		"scene_navigator should not use data_repository.call"
	)
	_assert_true(
		scene_navigator_text.find("mod_loader.call(") == -1,
		"scene_navigator should not use mod_loader.call"
	)
	_assert_true(
		scene_navigator_text.find("unit_augment_manager.call(") == -1,
		"scene_navigator should not use unit_augment_manager.call"
	)
	_assert_true(
		scene_navigator_text.find("event_bus.call(") == -1,
		"scene_navigator should not use event_bus.call"
	)
	_assert_true(
		battle_stats_panel_text.find("_statistics.call(") == -1,
		"battle_stats_panel should not use statistics.call"
	)


func _assert_none_missing(label: String, expected: Array[String], text: String) -> void:
	var missing: Array[String] = []
	for item in expected:
		if text.find("\"%s\"" % item) == -1:
			missing.append(item)
	_assert_true(missing.is_empty(), "%s missing: %s" % [label, ",".join(missing)])


func _load_json_array(path: String) -> Array:
	var raw: String = _read_text(path)
	if raw.is_empty():
		_assert_true(false, "load json empty: %s" % path)
		return []
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Array):
		_assert_true(false, "json is not array: %s" % path)
		return []
	return parsed as Array


func _load_json_arrays_from_dir(root_path: String) -> Array:
	var output: Array = []
	for path in _collect_files_under_dir(root_path, ".json"):
		output.append_array(_load_json_array(path))
	return output


func _read_text(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		_assert_true(false, "cannot open file: %s" % path)
		return ""
	return f.get_as_text()


func _join_texts(paths: Array[String]) -> String:
	var parts: Array[String] = []
	for path in paths:
		parts.append(_read_text(path))
	return "\n".join(parts)


func _collect_files_under_dir(root_path: String, suffix: String, exclude_prefixes: Array[String] = []) -> Array[String]:
	var output: Array[String] = []
	_collect_files_under_dir_recursive(root_path, suffix, exclude_prefixes, output)
	output.sort()
	return output


func _collect_files_under_dir_recursive(
	root_path: String,
	suffix: String,
	exclude_prefixes: Array[String],
	output: Array[String]
) -> void:
	var dir: DirAccess = DirAccess.open(root_path)
	if dir == null:
		_assert_true(false, "cannot open dir: %s" % root_path)
		return

	dir.list_dir_begin()
	while true:
		var entry: String = dir.get_next()
		if entry.is_empty():
			break
		if entry == "." or entry == "..":
			continue

		var child_path: String = "%s/%s" % [root_path, entry]
		var skip_child: bool = false
		for prefix in exclude_prefixes:
			if child_path.begins_with(prefix):
				skip_child = true
				break
		if skip_child:
			continue

		if dir.current_is_dir():
			_collect_files_under_dir_recursive(child_path, suffix, exclude_prefixes, output)
			continue
		if not suffix.is_empty() and not child_path.ends_with(suffix):
			continue

		output.append(child_path)
	dir.list_dir_end()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
