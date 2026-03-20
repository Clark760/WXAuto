extends PanelContainer
class_name BattleInventoryItemCard

# ===========================
# 仓库卡片（拖放源）
# ===========================
# 说明：
# 1. 卡片同时支持“点击”与“拖动”两种交互。
# 2. 当鼠标移动超过阈值时，交由 Godot 拖放系统发起拖拽；
#    未超过阈值时，左键释放视为点击。

signal card_clicked(item_id: String, item_data: Dictionary)

const DRAG_THRESHOLD: float = 6.0

var item_id: String = ""
var item_data: Dictionary = {}
var drag_payload: Dictionary = {}
var drag_enabled: bool = true

var _press_pos: Vector2 = Vector2.ZERO
var _pressing_left: bool = false
var _moved_enough_for_drag: bool = false


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


func _get_drag_data(_at_position: Vector2) -> Variant:
	if not drag_enabled:
		return null
	if drag_payload.is_empty():
		return null

	# 拖影使用简化文本卡片，避免依赖外部图集资源。
	var preview := PanelContainer.new()
	preview.custom_minimum_size = Vector2(120, 52)
	preview.modulate = Color(1.0, 1.0, 1.0, 0.8)
	var label := Label.new()
	label.text = str(item_data.get("name", item_id))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview.add_child(label)
	set_drag_preview(preview)
	return drag_payload.duplicate(true)
