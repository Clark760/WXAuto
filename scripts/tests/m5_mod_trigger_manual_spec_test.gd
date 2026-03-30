extends SceneTree

const MANUAL_PATH: String = "res://doc/模组触发器与特效手册.md"
const ACTIVE_DISPATCHER_SCRIPT: Script = preload("res://scripts/domain/unit_augment/effects/active_effect_dispatcher.gd")

const CONDITION_SERVICE_PATH: String = "res://scripts/unit_augment/unit_augment_trigger_condition_service.gd"
const TRIGGER_RUNTIME_PATH: String = "res://scripts/unit_augment/unit_augment_trigger_runtime.gd"
const UNIT_STATE_SERVICE_PATH: String = "res://scripts/unit_augment/unit_augment_unit_state_service.gd"
const COMBAT_EVENT_BRIDGE_PATH: String = "res://scripts/unit_augment/unit_augment_combat_event_bridge.gd"
const PASSIVE_EFFECT_APPLIER_PATH: String = "res://scripts/domain/unit_augment/effects/passive_effect_applier.gd"
const STAGE_MANAGER_PATH: String = "res://scripts/stage/stage_manager.gd"

const UNIT_TRIGGERS_FROM_DOC: Array[String] = [
	"auto_mp_full",
	"manual",
	"auto_hp_below",
	"on_hp_below",
	"on_time_elapsed",
	"periodic_seconds",
	"passive_aura",
	"on_combat_start",
	"on_attack_hit",
	"on_attacked",
	"on_kill",
	"on_ally_death",
	"on_crit",
	"on_dodge",
	"on_attack_fail",
	"on_shield_broken",
	"on_unit_spawned_mid_battle",
	"on_damage_received",
	"on_heal_received",
	"on_thorns_triggered",
	"on_unit_move_success",
	"on_unit_move_failed",
	"on_terrain_created",
	"on_terrain_enter",
	"on_terrain_tick",
	"on_terrain_exit",
	"on_terrain_expire",
	"on_team_alive_count_changed",
	"on_debuff_applied",
	"on_buff_expired"
]

const GLOBAL_TRIGGERS_FROM_DOC: Array[String] = [
	"on_preparation_started",
	"on_stage_combat_started",
	"on_stage_completed",
	"on_stage_failed"
]

const PASSIVE_OPS_FROM_DOC: Array[String] = [
	"stat_add",
	"stat_percent",
	"mp_regen_add",
	"hp_regen_add",
	"damage_reduce_flat",
	"damage_reduce_percent",
	"dodge_bonus",
	"crit_bonus",
	"crit_damage_bonus",
	"attack_speed_bonus",
	"range_add",
	"vampire",
	"damage_amp_percent",
	"damage_amp_vs_debuffed",
	"tenacity",
	"thorns_percent",
	"thorns_flat",
	"shield_on_combat_start",
	"execute_threshold",
	"healing_amp",
	"mp_on_kill",
	"conditional_stat"
]

const ACTIVE_OPS_FROM_DOC: Array[String] = [
	"damage_target",
	"damage_aoe",
	"heal_self",
	"heal_self_percent",
	"heal_allies_aoe",
	"heal_target_flat",
	"mp_regen_add",
	"buff_self",
	"buff_allies_aoe",
	"debuff_target",
	"buff_target",
	"debuff_aoe",
	"damage_target_scaling",
	"damage_if_debuffed",
	"damage_chain",
	"damage_cone",
	"heal_lowest_ally",
	"heal_percent_missing_hp",
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
	"aoe_percent_hp_damage",
	"shield_self",
	"immunity_self",
	"summon_units",
	"hazard_zone",
	"spawn_vfx",
	"teleport_behind",
	"dash_forward",
	"knockback_target",
	"summon_clone",
	"revive_random_ally",
	"taunt_aoe",
	"tag_linkage_branch"
]

var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 manual spec tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 manual spec tests passed.")
	quit(0)


func _run() -> void:
	var manual_text: String = _read_text(MANUAL_PATH)
	_assert_true(not manual_text.is_empty(), "manual markdown should be readable")
	if manual_text.is_empty():
		return
	_test_doc_json_blocks_parse(manual_text)
	_test_doc_table_implemented_tokens(manual_text)
	_test_runtime_trigger_support()
	_test_runtime_effect_support()
	_test_doc_example_ops_and_triggers_supported(manual_text)


func _test_doc_json_blocks_parse(manual_text: String) -> void:
	var json_blocks: Array[String] = _extract_json_blocks(manual_text)
	_assert_true(json_blocks.size() >= 30, "manual should contain many JSON examples")
	for idx in range(json_blocks.size()):
		var parser := JSON.new()
		var err: Error = parser.parse(json_blocks[idx])
		_assert_true(err == OK, "manual JSON block parse failed at index=%d" % idx)


func _test_doc_table_implemented_tokens(manual_text: String) -> void:
	var implemented_tokens: Array[String] = _extract_implemented_tokens(manual_text)
	_assert_true(not implemented_tokens.is_empty(), "manual should expose implemented tokens from tables")
	var expected_union: Dictionary = {}
	for trigger_name in UNIT_TRIGGERS_FROM_DOC:
		expected_union[trigger_name] = true
	for trigger_name in GLOBAL_TRIGGERS_FROM_DOC:
		expected_union[trigger_name] = true
	for op_name in PASSIVE_OPS_FROM_DOC:
		expected_union[op_name] = true
	for op_name in ACTIVE_OPS_FROM_DOC:
		expected_union[op_name] = true
	for token in implemented_tokens:
		_assert_true(expected_union.has(token), "manual implemented token should be covered by test list: %s" % token)


func _test_runtime_trigger_support() -> void:
	var condition_text: String = _read_text(CONDITION_SERVICE_PATH)
	var runtime_text: String = _read_text(TRIGGER_RUNTIME_PATH)
	var state_service_text: String = _read_text(UNIT_STATE_SERVICE_PATH)
	var combat_bridge_text: String = _read_text(COMBAT_EVENT_BRIDGE_PATH)
	var stage_manager_text: String = _read_text(STAGE_MANAGER_PATH)
	var trigger_text_joined: String = "\n".join([
		condition_text,
		runtime_text,
		state_service_text,
		combat_bridge_text
	])
	for trigger_name in UNIT_TRIGGERS_FROM_DOC:
		_assert_true(
			trigger_text_joined.find("\"%s\"" % trigger_name) != -1,
			"runtime should mention unit trigger from manual: %s" % trigger_name
		)
	for trigger_name in GLOBAL_TRIGGERS_FROM_DOC:
		_assert_true(
			stage_manager_text.find("\"%s\"" % trigger_name) != -1,
			"stage manager should emit global trigger from manual: %s" % trigger_name
		)


func _test_runtime_effect_support() -> void:
	var dispatcher = ACTIVE_DISPATCHER_SCRIPT.new({}, {}, {})
	var routes: Dictionary = dispatcher.get("_routes")
	for op_name in ACTIVE_OPS_FROM_DOC:
		_assert_true(routes.has(op_name), "active dispatcher should register op from manual: %s" % op_name)

	var passive_text: String = _read_text(PASSIVE_EFFECT_APPLIER_PATH)
	for op_name in PASSIVE_OPS_FROM_DOC:
		_assert_true(
			passive_text.find("\"%s\"" % op_name) != -1,
			"passive applier should mention op from manual: %s" % op_name
		)


func _test_doc_example_ops_and_triggers_supported(manual_text: String) -> void:
	var all_supported_ops: Dictionary = {}
	for op_name in ACTIVE_OPS_FROM_DOC:
		all_supported_ops[op_name] = true
	for op_name in PASSIVE_OPS_FROM_DOC:
		all_supported_ops[op_name] = true
	var all_supported_triggers: Dictionary = {}
	for trigger_name in UNIT_TRIGGERS_FROM_DOC:
		all_supported_triggers[trigger_name] = true
	for trigger_name in GLOBAL_TRIGGERS_FROM_DOC:
		all_supported_triggers[trigger_name] = true

	for block in _extract_json_blocks(manual_text):
		var parser := JSON.new()
		var err: Error = parser.parse(block)
		if err != OK:
			continue
		_walk_doc_json_node(parser.data, all_supported_ops, all_supported_triggers)


func _walk_doc_json_node(node: Variant, supported_ops: Dictionary, supported_triggers: Dictionary) -> void:
	if node is Dictionary:
		var dict_node: Dictionary = node as Dictionary
		if dict_node.has("op"):
			var op_name: String = str(dict_node.get("op", "")).strip_edges()
			if not op_name.is_empty():
				_assert_true(supported_ops.has(op_name), "manual JSON uses unsupported op: %s" % op_name)
		if dict_node.has("trigger"):
			var trigger_value: Variant = dict_node.get("trigger", "")
			if trigger_value is String:
				var trigger_name: String = str(trigger_value).strip_edges()
				_assert_true(supported_triggers.has(trigger_name), "manual JSON uses unsupported trigger: %s" % trigger_name)
		for key in dict_node.keys():
			_walk_doc_json_node(dict_node[key], supported_ops, supported_triggers)
		return
	if node is Array:
		for item in (node as Array):
			_walk_doc_json_node(item, supported_ops, supported_triggers)


func _extract_json_blocks(markdown_text: String) -> Array[String]:
	var blocks: Array[String] = []
	var re := RegEx.new()
	var err: Error = re.compile("```json\\s*([\\s\\S]*?)```")
	if err != OK:
		return blocks
	for match in re.search_all(markdown_text):
		blocks.append(match.get_string(1).strip_edges())
	return blocks


func _extract_implemented_tokens(markdown_text: String) -> Array[String]:
	var output: Array[String] = []
	var seen: Dictionary = {}
	var re := RegEx.new()
	var err: Error = re.compile("^\\|\\s*`([^`]+)`\\s*\\|\\s*已实现\\s*\\|")
	if err != OK:
		return output
	for line in markdown_text.split("\n"):
		var match: RegExMatch = re.search(line)
		if match == null:
			continue
		var token: String = match.get_string(1).strip_edges()
		if token.is_empty() or seen.has(token):
			continue
		seen[token] = true
		output.append(token)
	return output


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
