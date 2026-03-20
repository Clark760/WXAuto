extends PanelContainer
class_name BattleSlotDropTarget

# ===========================
# 详情槽位（拖放接收器）
# ===========================
# 说明：
# 1. 每个槽位绑定一个 category + key，用于做类型匹配。
# 2. _can_drop_data 返回匹配结果，Godot 会基于该返回值决定是否允许松手放下。

signal item_dropped(slot_category: String, slot_key: String, item_id: String)

var slot_category: String = "" # "gongfa" / "equipment"
var slot_key: String = ""      # "neigong" / "weapon" ...
var drop_enabled: bool = true
var _default_modulate: Color = Color(1, 1, 1, 1)
var _reject_icon: Label = null


func _ready() -> void:
	_default_modulate = modulate
	_ensure_reject_icon()


func setup_slot(category: String, key: String) -> void:
	slot_category = category
	slot_key = key


func set_drop_enabled(enabled: bool) -> void:
	drop_enabled = enabled


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary):
		_reset_drop_visual()
		return false
	var payload: Dictionary = data as Dictionary
	var accepted: bool = _is_payload_accepted(payload)
	_apply_drop_visual(accepted)
	return accepted


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not _can_drop_data(_at_position, data):
		return
	var payload: Dictionary = data as Dictionary
	var item_id: String = str(payload.get("id", "")).strip_edges()
	if item_id.is_empty():
		_reset_drop_visual()
		return
	item_dropped.emit(slot_category, slot_key, item_id)
	_reset_drop_visual()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_reset_drop_visual()
	elif what == NOTIFICATION_DRAG_BEGIN:
		# 拖拽开始时主动评估一次当前槽位状态，立即给出匹配/拒绝视觉提示。
		# 这样用户无需把鼠标移到每个槽位上，也能立刻看到哪些槽位可放下。
		var drag_data: Variant = get_viewport().gui_get_drag_data()
		if not (drag_data is Dictionary):
			_reset_drop_visual()
			return
		var payload: Dictionary = drag_data as Dictionary
		var accepted: bool = _is_payload_accepted(payload)
		_apply_drop_visual(accepted)


func _ensure_reject_icon() -> void:
	if _reject_icon != null and is_instance_valid(_reject_icon):
		return
	_reject_icon = Label.new()
	_reject_icon.text = "🚫"
	_reject_icon.visible = false
	_reject_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reject_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_reject_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_reject_icon.offset_right = -8.0
	_reject_icon.offset_left = -32.0
	_reject_icon.anchor_left = 1.0
	_reject_icon.anchor_right = 1.0
	_reject_icon.anchor_top = 0.0
	_reject_icon.anchor_bottom = 1.0
	add_child(_reject_icon)


func _reset_drop_visual() -> void:
	modulate = _default_modulate
	if _reject_icon != null:
		_reject_icon.visible = false


func _is_payload_accepted(payload: Dictionary) -> bool:
	if not drop_enabled:
		return false
	var item_type: String = str(payload.get("type", "")).strip_edges()
	var slot_type: String = str(payload.get("slot_type", "")).strip_edges()
	if slot_category == "gongfa":
		return item_type == "gongfa" and slot_type == slot_key
	if slot_category == "equipment":
		return item_type == "equipment" and slot_type == slot_key
	return false


func _apply_drop_visual(accepted: bool) -> void:
	# 统一拖放视觉反馈：
	# - 匹配槽位：浅绿色高亮
	# - 不匹配槽位：浅红色高亮 + 🚫 图标
	modulate = Color(0.86, 1.0, 0.86, 1.0) if accepted else Color(1.0, 0.84, 0.84, 1.0)
	if _reject_icon != null:
		_reject_icon.visible = not accepted
