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


func load_stage_sequence(data_manager: Node) -> void:
	_stage_map.clear()
	_ordered_stage_ids.clear()
	_current_stage_id = ""
	_current_stage_order_index = -1
	if data_manager == null or not is_instance_valid(data_manager):
		return
	if not data_manager.has_method("get_all_records"):
		return

	var all_stage_records_value: Variant = data_manager.call("get_all_records", "stages")
	if not (all_stage_records_value is Array):
		return
	var all_stage_records: Array = all_stage_records_value

	var sequence_record: Dictionary = {}
	for record_value in all_stage_records:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		if _stage_data.is_stage_sequence_record(record):
			# 优先使用 id=stage_sequence 的序列配置；其余作为兜底候选。
			if sequence_record.is_empty() or str(record.get("id", "")).strip_edges() == "stage_sequence":
				sequence_record = _stage_data.normalize_stage_sequence_record(record)
			continue
		var stage_config: Dictionary = _stage_data.normalize_stage_record(record)
		if stage_config.is_empty():
			continue
		_stage_map[str(stage_config.get("id", ""))] = stage_config

	if _stage_map.is_empty():
		return

	if not sequence_record.is_empty():
		var sequence_ids: Array[String] = _stage_data.flatten_sequence_stage_ids(sequence_record)
		for stage_id in sequence_ids:
			if _stage_map.has(stage_id):
				_ordered_stage_ids.append(stage_id)
	if _ordered_stage_ids.is_empty():
		_ordered_stage_ids = _build_fallback_stage_order()


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


func notify_stage_combat_started() -> void:
	var config: Dictionary = get_current_stage_config()
	if config.is_empty():
		return
	stage_combat_started.emit(config.duplicate(true))
	_emit_stage_event_to_bus("emit_stage_combat_started", [config])


func complete_current_stage_without_battle() -> bool:
	var config: Dictionary = get_current_stage_config()
	if config.is_empty():
		return false
	var rewards: Dictionary = _apply_rewards_for_current_stage(config)
	stage_completed.emit(config.duplicate(true), rewards.duplicate(true))
	_emit_stage_event_to_bus("emit_stage_completed", [config, rewards])
	return true


func on_battle_ended(winner_team: int, _summary: Dictionary) -> void:
	var config: Dictionary = get_current_stage_config()
	if config.is_empty():
		return
	if winner_team == _player_team:
		var rewards: Dictionary = _apply_rewards_for_current_stage(config)
		stage_completed.emit(config.duplicate(true), rewards.duplicate(true))
		_emit_stage_event_to_bus("emit_stage_completed", [config, rewards])
		return
	stage_failed.emit(config.duplicate(true))
	_emit_stage_event_to_bus("emit_stage_failed", [config])


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


func _build_fallback_stage_order() -> Array[String]:
	var rows: Array[Dictionary] = []
	for stage_id in _stage_map.keys():
		var config: Dictionary = _stage_map[stage_id]
		rows.append({
			"id": str(config.get("id", stage_id)),
			"chapter": int(config.get("chapter", 1)),
			"index": int(config.get("index", 1))
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var chapter_a: int = int(a.get("chapter", 0))
		var chapter_b: int = int(b.get("chapter", 0))
		if chapter_a != chapter_b:
			return chapter_a < chapter_b
		var index_a: int = int(a.get("index", 0))
		var index_b: int = int(b.get("index", 0))
		if index_a != index_b:
			return index_a < index_b
		return str(a.get("id", "")) < str(b.get("id", ""))
	)
	var ids: Array[String] = []
	for row in rows:
		ids.append(str(row.get("id", "")))
	return ids


func _emit_stage_event_to_bus(method_name: String, args: Array) -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null or not is_instance_valid(event_bus):
		return
	if not event_bus.has_method(method_name):
		return
	event_bus.callv(method_name, args)


func _get_event_bus() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop as SceneTree
	if tree.root == null:
		return null
	return tree.root.get_node_or_null("EventBus")
