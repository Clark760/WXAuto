extends SceneTree

const ROOT := "res://"

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

const EXPECTED_TERRAIN_TYPES: Array[String] = [
	"fire",
	"ice",
	"poison",
	"heal",
	"barrier",
	"slow",
	"amp_damage"
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
	var effect_engine_text: String = _read_text("res://scripts/gongfa/effect_engine.gd")
	var gongfa_manager_text: String = _read_text("res://scripts/gongfa/gongfa_manager.gd")
	var trigger_engine_text: String = _read_text("res://scripts/gongfa/trigger_engine.gd")
	var terrain_data_text: String = _read_text("res://data/terrains/terrains_core.json") + "\n" + _read_text("res://data/terrains/terrains_m5_expansion.json")

	_assert_none_missing("passive_ops", EXPECTED_PASSIVE_OPS, effect_engine_text)
	_assert_none_missing("active_ops", EXPECTED_ACTIVE_OPS, effect_engine_text)
	_assert_none_missing("triggers", EXPECTED_TRIGGERS, gongfa_manager_text + "\n" + trigger_engine_text)
	_assert_none_missing("terrain_types", EXPECTED_TERRAIN_TYPES, terrain_data_text)

	_check_data_counts()
	_check_linkage_removed()


func _check_data_counts() -> void:
	var buffs: Array = _load_json_array("res://data/buffs/buffs_m5_expansion.json")
	var equips: Array = _load_json_array("res://data/equipment/equipment_m5_expansion.json")
	var gongfa: Array = _load_json_array("res://data/gongfa/gongfa_m5_expansion.json")

	_assert_true(buffs.size() >= 18, "buff_count >= 18 (actual=%d)" % buffs.size())
	_assert_true(equips.size() == 13, "equipment_count == 13 (actual=%d)" % equips.size())
	_assert_true(gongfa.size() == 9, "gongfa_count == 9 (actual=%d)" % gongfa.size())

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
	_assert_true(equip_with_trigger == 13, "equipment_with_trigger == 13 (actual=%d)" % equip_with_trigger)


func _check_linkage_removed() -> void:
	_assert_true(not FileAccess.file_exists("res://scripts/gongfa/linkage_detector.gd"), "linkage_detector.gd removed")
	_assert_true(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://data/linkages")), "data/linkages removed")
	_assert_true(not FileAccess.file_exists("res://data/_schema/linkage.schema.json"), "linkage.schema.json removed")


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


func _read_text(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		_assert_true(false, "cannot open file: %s" % path)
		return ""
	return f.get_as_text()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
