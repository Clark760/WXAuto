extends PanelContainer
class_name BattleSlotDropTarget

# ===========================
# 详情槽位（拖放接收器）
# ===========================
# 说明：
# 1. 每个槽位绑定 category 与 key，用于做类型匹配。
# 2. 是否接受拖放只在这里判定，业务层只接收结果信号。
signal item_dropped(slot_category: String, slot_key: String, item_id: String)

var slot_category: String = ""
var slot_key: String = ""
var drop_enabled: bool = true
var _default_modulate: Color = Color(1, 1, 1, 1)
var _reject_icon: Label = null


# 节点就绪后缓存默认显色，并绑定固定的拒绝图标节点。
func _ready() -> void:
	_default_modulate = modulate
	_ensure_reject_icon()


# 写入槽位分类与 key，后续拖拽判定只依赖这两个标识。
func setup_slot(category: String, key: String) -> void:
	slot_category = category
	slot_key = key


# 外层可临时禁用拖放能力，但不改变槽位的分类信息。
func set_drop_enabled(enabled: bool) -> void:
	drop_enabled = enabled


# 只负责判断当前载荷能否放下，并同步刷新高亮或拒绝态。
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary):
		_reset_drop_visual()
		return false
	var payload: Dictionary = data as Dictionary
	var accepted: bool = _is_payload_accepted(payload)
	_apply_drop_visual(accepted)
	return accepted


# 真正放下时只抛出标准化信号，不在这里承担装备或功法业务逻辑。
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


# 监听拖拽开始和结束，确保鼠标不悬停也能及时看到槽位接受状态。
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_reset_drop_visual()
	elif what == NOTIFICATION_DRAG_BEGIN:
		var drag_data: Variant = get_viewport().gui_get_drag_data()
		if not (drag_data is Dictionary):
			_reset_drop_visual()
			return
		var payload: Dictionary = drag_data as Dictionary
		var accepted: bool = _is_payload_accepted(payload)
		_apply_drop_visual(accepted)


# 绑定 RejectIcon 子节点，并把缺失场景结构视为配置错误而不是兼容处理。
func _ensure_reject_icon() -> void:
	if _reject_icon != null and is_instance_valid(_reject_icon):
		return
	_reject_icon = get_node_or_null("RejectIcon") as Label
	assert(_reject_icon != null, "BattleSlotDropTarget requires a RejectIcon child node.")
	_reject_icon.text = "X"
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


# 清空拖放反馈，恢复默认色并隐藏拒绝标记。
func _reset_drop_visual() -> void:
	modulate = _default_modulate
	_reject_icon.visible = false


# 根据槽位分类与 payload 类型做最小职责的接受判断。
func _is_payload_accepted(payload: Dictionary) -> bool:
	if not drop_enabled:
		return false
	var item_type: String = str(payload.get("type", "")).strip_edges()
	var slot_type: String = str(payload.get("slot_type", "")).strip_edges()
	if slot_category == "gongfa":
		return item_type == "gongfa" and slot_type == slot_key
	if slot_category == "equipment":
		return item_type == "equipment"
	return false


# 统一维护接受与拒绝的视觉反馈，避免各个槽位子类分散定义颜色规则。
func _apply_drop_visual(accepted: bool) -> void:
	modulate = Color(0.86, 1.0, 0.86, 1.0) if accepted else Color(1.0, 0.84, 0.84, 1.0)
	_reject_icon.visible = not accepted
