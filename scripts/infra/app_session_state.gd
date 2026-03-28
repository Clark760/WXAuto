extends RefCounted
class_name AppSessionState


enum GamePhase {
	BOOT,
	MAIN_MENU,
	PREPARATION,
	COMBAT,
	RESULT,
	PAUSED
}


var current_phase: int = GamePhase.BOOT
var current_scene_path: String = ""
var requested_stage_sequence_id: String = ""
var last_load_summary: Dictionary = {}

var _event_bus: Node = null


# 绑定事件总线，用于广播阶段变化。
func bind_event_bus(event_bus: Node) -> void:
	_event_bus = event_bus


# 切换游戏阶段，并在阶段变化时发出事件。
func set_phase(next_phase: int) -> void:
	if current_phase == next_phase:
		return

	var previous_phase: int = current_phase
	current_phase = next_phase

	if _event_bus != null and is_instance_valid(_event_bus):
		_event_bus.emit_phase_changed(previous_phase, current_phase)


# 返回阶段名，方便 UI 和测试输出统一文案。
func get_phase_name(phase: int = -1) -> String:
	var target_phase: int = current_phase if phase < 0 else phase
	match target_phase:
		GamePhase.BOOT:
			return "BOOT"
		GamePhase.MAIN_MENU:
			return "MAIN_MENU"
		GamePhase.PREPARATION:
			return "PREPARATION"
		GamePhase.COMBAT:
			return "COMBAT"
		GamePhase.RESULT:
			return "RESULT"
		GamePhase.PAUSED:
			return "PAUSED"
		_:
			return "UNKNOWN"


# 记录当前已进入的场景路径。
func set_current_scene_path(scene_path: String) -> void:
	current_scene_path = scene_path.strip_edges()


# 保存最近一次运行时重载摘要。
func set_last_load_summary(summary: Dictionary) -> void:
	last_load_summary = summary.duplicate(true)


# 写入准备阶段想进入的关卡序列 id。
func set_requested_stage_sequence_id(sequence_id: String) -> void:
	requested_stage_sequence_id = sequence_id.strip_edges()


# 取出并清空待消费的关卡序列 id。
func consume_requested_stage_sequence_id() -> String:
	var sequence_id: String = requested_stage_sequence_id.strip_edges()
	requested_stage_sequence_id = ""
	return sequence_id


# 兼容旧接口，内部仍走 sequence id 存储。
func set_requested_stage_id(stage_id: String) -> void:
	set_requested_stage_sequence_id(stage_id)


# 兼容旧接口，读取后同样立即清空。
func consume_requested_stage_id() -> String:
	return consume_requested_stage_sequence_id()
