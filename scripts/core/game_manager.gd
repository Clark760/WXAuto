extends Node

# ===========================
# 游戏总管理器（AutoLoad）
# ===========================
# 职责：
# 1. 管理全局游戏阶段状态机。
# 2. 负责启动流程（基础数据 -> Mod 数据 -> 进入主场景）。
# 3. 统一提供场景切换入口，避免业务脚本直接操作 SceneTree。

enum GamePhase {
	BOOT,
	MAIN_MENU,
	PREPARATION,
	COMBAT,
	RESULT,
	PAUSED
}

const DEFAULT_MAIN_SCENE_PATH := "res://scenes/main/main.tscn"

var current_phase: int = GamePhase.BOOT
var current_scene_path: String = ""
var is_initialized: bool = false
var requested_stage_sequence_id: String = ""

# 记录最近一次数据重载摘要，方便 UI 或调试工具读取。
var last_load_summary: Dictionary = {}


func _ready() -> void:
	_connect_event_bus()
	initialize_game()


func initialize_game() -> void:
	# 防止重复初始化导致重复加载数据与重复切场景。
	if is_initialized:
		return

	set_phase(GamePhase.BOOT)
	var base_summary: Dictionary = {}
	var mod_summary: Dictionary = {}

	var data_manager: Node = _get_data_manager()
	if data_manager != null:
		var base_value: Variant = data_manager.call("load_base_data")
		if base_value is Dictionary:
			base_summary = base_value

	var mod_loader: Node = _get_mod_loader()
	if mod_loader != null:
		var mod_value: Variant = mod_loader.call("load_and_apply_mods")
		if mod_value is Dictionary:
			mod_summary = mod_value

	last_load_summary = {
		"base": base_summary,
		"mods": mod_summary,
		"phase": get_phase_name(current_phase)
	}

	# AutoLoad 的 _ready 阶段，场景树仍在构建中，立即切场景会触发
	# “Parent node is busy adding/removing children” 错误。
	# 这里延迟到下一帧执行，确保切场景时机安全。
	call_deferred("_enter_initial_scene")
	is_initialized = true


func reload_game_data() -> Dictionary:
	# 统一的数据重载入口，主场景按 F5 调用，便于反复验证 JSON 与 Mod 覆盖逻辑。
	var base_summary: Dictionary = {}
	var mod_summary: Dictionary = {}

	var data_manager: Node = _get_data_manager()
	if data_manager != null:
		var base_value: Variant = data_manager.call("load_base_data")
		if base_value is Dictionary:
			base_summary = base_value

	var mod_loader: Node = _get_mod_loader()
	if mod_loader != null:
		var mod_value: Variant = mod_loader.call("load_and_apply_mods")
		if mod_value is Dictionary:
			mod_summary = mod_value

	last_load_summary = {
		"base": base_summary,
		"mods": mod_summary,
		"phase": get_phase_name(current_phase),
		"scene": current_scene_path
	}

	var event_bus: Node = _get_event_bus()
	if event_bus != null and data_manager != null:
		event_bus.call("emit_data_reloaded", true, data_manager.call("get_summary"))

	return last_load_summary


func set_phase(next_phase: int) -> void:
	if current_phase == next_phase:
		return

	var previous_phase: int = current_phase
	current_phase = next_phase

	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_phase_changed", previous_phase, current_phase)


func request_scene_change(scene_path: String) -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_scene_change_requested", scene_path)


func set_requested_stage_sequence_id(sequence_id: String) -> void:
	requested_stage_sequence_id = sequence_id.strip_edges()


func consume_requested_stage_sequence_id() -> String:
	var sequence_id: String = requested_stage_sequence_id.strip_edges()
	requested_stage_sequence_id = ""
	return sequence_id


# 兼容旧调用：保留同义接口，内部统一映射到 sequence_id。
func set_requested_stage_id(stage_id: String) -> void:
	set_requested_stage_sequence_id(stage_id)


func consume_requested_stage_id() -> String:
	return consume_requested_stage_sequence_id()


func change_scene(scene_path: String) -> bool:
	if scene_path.is_empty():
		push_error("GameManager: 场景路径为空，拒绝切换")
		return false

	if not ResourceLoader.exists(scene_path):
		push_error("GameManager: 场景不存在，路径=%s" % scene_path)
		return false

	var previous_scene: String = current_scene_path
	var result: Error = get_tree().change_scene_to_file(scene_path)
	if result != OK:
		push_error("GameManager: 场景切换失败，error=%d, path=%s" % [result, scene_path])
		return false

	current_scene_path = scene_path
	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_scene_changed", previous_scene, current_scene_path)
	return true


func get_phase_name(phase: int) -> String:
	match phase:
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


func _connect_event_bus() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null:
		return

	var on_scene_change_requested: Callable = Callable(self, "_on_scene_change_requested")
	if not event_bus.is_connected("scene_change_requested", on_scene_change_requested):
		event_bus.connect("scene_change_requested", on_scene_change_requested)


func _on_scene_change_requested(scene_path: String) -> void:
	change_scene(scene_path)


func _enter_initial_scene() -> void:
	change_scene(DEFAULT_MAIN_SCENE_PATH)
	set_phase(GamePhase.MAIN_MENU)


func _get_event_bus() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("EventBus")


func _get_data_manager() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("DataManager")


func _get_mod_loader() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("ModLoader")
