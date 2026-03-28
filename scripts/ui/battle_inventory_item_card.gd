extends PanelContainer
class_name BattleInventoryItemCard

const INVENTORY_DRAG_PREVIEW_SCENE: PackedScene = preload(
	"res://scenes/ui/inventory_drag_preview.tscn"
)

# ===========================
# 仓库卡片（拖放源）
# ===========================
# 说明：
# 1. 卡片同时支持点击与拖拽两种交互。
# 2. 鼠标移动超过阈值后，由 Godot GUI 拖拽系统接管后续流程。
signal card_clicked(item_id: String, item_data: Dictionary)

const DRAG_THRESHOLD: float = 6.0

var item_id: String = ""
var item_data: Dictionary = {}
var drag_payload: Dictionary = {}
var drag_enabled: bool = true

var _press_pos: Vector2 = Vector2.ZERO
var _pressing_left: bool = false
var _moved_enough_for_drag: bool = false


# 写入卡片展示数据和拖拽载荷，避免外层直接改内部状态。
func setup_card(
	p_item_id: String,
	p_item_data: Dictionary,
	p_drag_payload: Dictionary,
	p_drag_enabled: bool
) -> void:
	item_id = p_item_id
	item_data = p_item_data.duplicate(true)
	drag_payload = p_drag_payload.duplicate(true)
	drag_enabled = p_drag_enabled


# 在点击与拖拽之间做阈值分流，短按视为点击，超阈值交给 Godot 拖拽。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_btn: InputEventMouseButton = event as InputEventMouseButton
		if mouse_btn.button_index != MOUSE_BUTTON_LEFT:
			return
		if mouse_btn.pressed:
			_pressing_left = true
			_moved_enough_for_drag = false
			_press_pos = mouse_btn.position
		else:
			if _pressing_left and not _moved_enough_for_drag:
				card_clicked.emit(item_id, item_data.duplicate(true))
			_pressing_left = false
			_moved_enough_for_drag = false
	elif event is InputEventMouseMotion and _pressing_left:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		if motion.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_moved_enough_for_drag = true


# 构建统一的拖拽预览场景，并返回深拷贝后的业务载荷。
func _get_drag_data(_at_position: Vector2) -> Variant:
	if not drag_enabled:
		return null
	if drag_payload.is_empty():
		return null

	var preview = INVENTORY_DRAG_PREVIEW_SCENE.instantiate()
	preview.setup_preview(str(item_data.get("name", item_id)))
	set_drag_preview(preview)
	return drag_payload.duplicate(true)
