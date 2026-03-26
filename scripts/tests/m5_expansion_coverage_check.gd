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
	var terrain_data_text: String = _join_texts(_collect_files_under_dir(TERRAIN_DATA_DIR, ".json"))
	var project_text: String = _read_text("res://project.godot")

	_assert_none_missing("passive_ops", EXPECTED_PASSIVE_OPS, effect_engine_text)
	_assert_none_missing("active_ops", EXPECTED_ACTIVE_OPS, effect_engine_text)
	_assert_none_missing("triggers", EXPECTED_TRIGGERS, unit_augment_text)
	_assert_none_missing("terrain_markers", EXPECTED_TERRAIN_MARKERS, terrain_data_text)

	_check_data_counts()
	_check_effect_engine_cleanup(project_text, active_scripts_text, test_scripts_text)
	_check_combat_split(combat_manager_text, active_scripts_text)
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
		project_text.find('UnitAugmentManager="*res://scripts/unit_augment/unit_augment_manager.gd"') != -1,
		"project autoload should point to UnitAugmentManager"
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
