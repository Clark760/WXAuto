extends Node
class_name StageManager

# ===========================
# 关卡流程管理器（M5）
# ===========================
# 说明：
# 1. 负责“关卡序列读取 + 当前关卡状态推进 + 结算奖励分发”；
# 2. 不直接实现战斗逻辑，战斗结束结果由外部回调 on_battle_ended；
# 3. 统一通过信号与 EventBus 对外广播关卡生命周期事件。

signal stage_loaded(config: Dictionary)
signal stage_prepare_started(config: Dictionary)
signal stage_combat_started(config: Dictionary)
signal stage_completed(config: Dictionary, rewards: Dictionary)
signal stage_failed(config: Dictionary)
signal all_stages_cleared()

const TEAM_ALLY: int = 1

var _stage_data: StageData = StageData.new()
var _reward_manager: RewardManager = RewardManager.new()

var _stage_map: Dictionary = {} # stage_id -> normalized config
var _ordered_stage_ids: Array[String] = []
var _current_stage_id: String = ""
var _current_stage_order_index: int = -1
var _player_team: int = TEAM_ALLY

# 运行时上下文：由战场层注入，供奖励器使用。
var _economy_manager: Node = null
var _bench_ui: Node = null
var _battlefield: Node = null
var _unit_factory: Node = null


func configure_runtime_context(
	economy_manager: Node,
	bench_ui: Node,
	battlefield: Node,
	unit_factory: Node,
	player_team: int = TEAM_ALLY
) -> void:
	_economy_manager = economy_manager
	_bench_ui = bench_ui
	_battlefield = battlefield
	_unit_factory = unit_factory
	_player_team = player_team


func load_stage_sequence(data_manager: Node, sequence_id: String = "stage_sequence") -> void:
	_stage_map.clear()
	_ordered_stage_ids.clear()
	_current_stage_id = ""
	_current_stage_order_index = -1
	if data_manager == null or not is_instance_valid(data_manager):
		return
	if not data_manager.has_method("get_record"):
		return

	var sequence_record_id: String = sequence_id.strip_edges()
	if sequence_record_id.is_empty():
		sequence_record_id = "stage_sequence"

	var sequence_ids: Array[String] = []
	var sequence_raw: Variant = data_manager.call("get_record", "stages", sequence_record_id)
	if sequence_raw is Dictionary:
		var sequence_record: Dictionary = _stage_data.normalize_stage_sequence_record(sequence_raw as Dictionary)
		sequence_ids = _stage_data.flatten_sequence_stage_ids(sequence_record)
	if sequence_ids.is_empty() and data_manager.has_method("get_all_records"):
		var all_stage_rows: Variant = data_manager.call("get_all_records", "stages")
		if all_stage_rows is Array:
			var sequence_records: Array[Dictionary] = []
			for row_value in all_stage_rows:
				if not (row_value is Dictionary):
					continue
				var row: Dictionary = row_value as Dictionary
				if not row.has("chapters"):
					continue
				var normalized_seq: Dictionary = _stage_data.normalize_stage_sequence_record(row)
				var flatten_ids: Array[String] = _stage_data.flatten_sequence_stage_ids(normalized_seq)
				if flatten_ids.is_empty():
					continue
				sequence_records.append({
					"id": str(normalized_seq.get("id", "")).strip_edges(),
					"stage_ids": flatten_ids
				})
			if not sequence_records.is_empty():
				sequence_records.sort_custom(
					func(a: Dictionary, b: Dictionary) -> bool:
						return str(a.get("id", "")) < str(b.get("id", ""))
				)
				var picked_stage_ids: Variant = (sequence_records[0] as Dictionary).get("stage_ids", [])
				if picked_stage_ids is Array:
					for stage_id_value in picked_stage_ids:
						var fallback_stage_id: String = str(stage_id_value).strip_edges()
						if fallback_stage_id.is_empty():
							continue
						sequence_ids.append(fallback_stage_id)

	for stage_id in sequence_ids:
		if _stage_map.has(stage_id):
			continue
		var stage_raw: Variant = data_manager.call("get_record", "stages", stage_id)
		if not (stage_raw is Dictionary):
			continue
		var stage_config: Dictionary = _stage_data.normalize_stage_record(stage_raw as Dictionary)
		if stage_config.is_empty():
			continue
		_stage_map[stage_id] = stage_config
		_ordered_stage_ids.append(stage_id)


func start_first_stage() -> bool:
	if _ordered_stage_ids.is_empty():
		return false
	return start_stage(_ordered_stage_ids[0])


func start_stage(stage_id: String) -> bool:
	var target_id: String = stage_id.strip_edges()
	if target_id.is_empty():
		return false
	if not _stage_map.has(target_id):
		return false

	_current_stage_id = target_id
	_current_stage_order_index = _ordered_stage_ids.find(target_id)
	var config: Dictionary = (_stage_map[target_id] as Dictionary).duplicate(true)
	stage_loaded.emit(config.duplicate(true))
	stage_prepare_started.emit(config.duplicate(true))
	_emit_stage_event_to_bus("emit_stage_loaded", [config])
	_emit_stage_event_to_bus("emit_stage_prepare_started", [config])
	_emit_global_trigger_to_bus("on_preparation_started", {
		"stage_id": target_id,
		"config": config.duplicate(true)
	})
	return true


func advance_to_next_stage() -> bool:
	if _ordered_stage_ids.is_empty():
		return false
	if _current_stage_order_index < 0:
		return start_first_stage()
	var next_index: int = _current_stage_order_index + 1
	if next_index >= _ordered_stage_ids.size():
		all_stages_cleared.emit()
		_emit_stage_event_to_bus("emit_all_stages_cleared", [])
		return false
	return start_stage(_ordered_stage_ids[next_index])


func get_current_stage_config() -> Dictionary:
	if _current_stage_id.is_empty():
		return {}
	if not _stage_map.has(_current_stage_id):
		return {}
	return (_stage_map[_current_stage_id] as Dictionary).duplicate(true)


func get_current_stage_id() -> String:
	return _current_stage_id


func get_current_chapter() -> int:
	var config: Dictionary = get_current_stage_config()
	return int(config.get("chapter", 0))


func get_current_index() -> int:
	var config: Dictionary = get_current_stage_config()
	return int(config.get("index", 0))


func get_total_stages() -> int:
	return _ordered_stage_ids.size()


func get_ordered_stage_ids() -> Array[String]:
	var output: Array[String] = []
	for stage_id in _ordered_stage_ids:
		output.append(stage_id)
	return output


func notify_stage_combat_started() -> void:
	var config: Dictionary = get_current_stage_config()
	if config.is_empty():
		return
	stage_combat_started.emit(config.duplicate(true))
	_emit_stage_event_to_bus("emit_stage_combat_started", [config])
	_emit_global_trigger_to_bus("on_stage_combat_started", {
		"stage_id": _current_stage_id,
		"config": config.duplicate(true)
	})


func complete_current_stage_without_battle() -> bool:
	var config: Dictionary = get_current_stage_config()
	if config.is_empty():
		return false
	var rewards: Dictionary = _apply_rewards_for_current_stage(config)
	stage_completed.emit(config.duplicate(true), rewards.duplicate(true))
	_emit_stage_event_to_bus("emit_stage_completed", [config, rewards])
	_emit_global_trigger_to_bus("on_stage_completed", {
		"stage_id": _current_stage_id,
		"config": config.duplicate(true),
		"rewards": rewards.duplicate(true),
		"without_battle": true
	})
	return true


func on_battle_ended(winner_team: int, _summary: Dictionary) -> void:
	var config: Dictionary = get_current_stage_config()
	if config.is_empty():
		return
	if winner_team == _player_team:
		var rewards: Dictionary = _apply_rewards_for_current_stage(config)
		stage_completed.emit(config.duplicate(true), rewards.duplicate(true))
		_emit_stage_event_to_bus("emit_stage_completed", [config, rewards])
		_emit_global_trigger_to_bus("on_stage_completed", {
			"stage_id": _current_stage_id,
			"config": config.duplicate(true),
			"rewards": rewards.duplicate(true),
			"winner_team": winner_team,
			"without_battle": false
		})
		return
	stage_failed.emit(config.duplicate(true))
	_emit_stage_event_to_bus("emit_stage_failed", [config])
	_emit_global_trigger_to_bus("on_stage_failed", {
		"stage_id": _current_stage_id,
		"config": config.duplicate(true),
		"winner_team": winner_team
	})


func _apply_rewards_for_current_stage(config: Dictionary) -> Dictionary:
	var rewards_config: Dictionary = config.get("rewards", {})
	if not (rewards_config is Dictionary):
		return {}
	return _reward_manager.apply_stage_rewards(
		rewards_config,
		_economy_manager,
		_bench_ui,
		_battlefield,
		_unit_factory
	)


func _emit_stage_event_to_bus(method_name: String, args: Array) -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null or not is_instance_valid(event_bus):
		return
	if not event_bus.has_method(method_name):
		return
	event_bus.callv(method_name, args)


func _emit_global_trigger_to_bus(trigger_name: String, payload: Dictionary) -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null or not is_instance_valid(event_bus):
		return
	if not event_bus.has_method("emit_global_trigger"):
		return
	event_bus.call("emit_global_trigger", trigger_name, payload)


func _get_event_bus() -> Node:
	if is_inside_tree():
		var tree: SceneTree = get_tree()
		if tree != null and tree.root != null:
			var direct: Node = tree.root.get_node_or_null("EventBus")
			if direct != null:
				return direct
			var recursive: Node = tree.root.find_child("EventBus", true, false)
			if recursive != null:
				return recursive
	var main_loop: MainLoop = Engine.get_main_loop()
	if main_loop is SceneTree:
		var loop_tree: SceneTree = main_loop as SceneTree
		if loop_tree.root != null:
			var direct_loop: Node = loop_tree.root.get_node_or_null("EventBus")
			if direct_loop != null:
				return direct_loop
			return loop_tree.root.find_child("EventBus", true, false)
	return null
