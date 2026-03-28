extends PanelContainer

# 回收出售区（拖放接收器）
# 说明：
# 1. 只负责回收区视觉、拖放判定和 sell_requested 信号抛出。
# 2. 不做经济结算，出售逻辑由 coordinator/economy support 承接。
signal sell_requested(payload: Dictionary, price: int)

const QUALITY_SELL_PRICE: Dictionary = {
	"white": 1,
	"green": 2,
	"blue": 3,
	"purple": 5,
	"orange": 8
}

const DEFAULT_HINT_TEXT: String = "拖入出售"
const DEFAULT_PRICE_TEXT: String = "💰 ?"

var drop_enabled: bool = true
var _default_modulate: Color = Color(1, 1, 1, 1)
var _manual_preview_active: bool = false
var _view_model: Dictionary = {}
var _actions: Dictionary = {}

var _hint_label: Label = null
var _price_label: Label = null
var _reject_icon: Label = null


# 节点就绪后绑定子节点并复位初始显示。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_default_modulate = modulate
	_bind_nodes()
	_apply_panel_style()
	_apply_view_model()
	_reset_visual()


# scene-first 统一入口：写入回收区 view_model。
func setup(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	else:
		_view_model = {}
	refresh(_view_model)


# scene-first 统一入口：刷新回收区文案。
func refresh(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	_apply_view_model()


# scene-first 统一入口：预留动作绑定参数。
func bind(actions: Variant) -> void:
	if actions is Dictionary:
		_actions = (actions as Dictionary).duplicate(true)
	else:
		_actions = {}


# 设置回收区是否允许接收拖放。
func set_drop_enabled(enabled: bool) -> void:
	drop_enabled = enabled
	if not drop_enabled:
		_reset_visual()


# 为外部拖拽（非 Godot 原生 GUI 拖拽）提供手动预览入口。
func set_external_preview(payload: Dictionary, accepted: bool) -> void:
	_manual_preview_active = true
	_apply_drop_visual(accepted)
	if accepted:
		_set_hint_text("松手出售")
		_set_price_text("💰 +%d" % _calc_price(payload))
		return
	_set_hint_text("⛔ 仅可出售备战角色")
	_set_price_text(DEFAULT_PRICE_TEXT)


# 清理外部拖拽预览态。
func clear_external_preview() -> void:
	_manual_preview_active = false
	_reset_visual()


# Godot GUI 拖拽判定：只在这里决定可否放下。
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not drop_enabled:
		_reset_visual()
		return false
	var payload: Dictionary = _normalize_payload(data)
	if payload.is_empty():
		_reset_visual()
		return false
	var accepted: bool = _is_payload_supported(payload)
	_apply_drop_visual(accepted)
	if accepted:
		_set_hint_text("松手出售")
		_set_price_text("💰 +%d" % _calc_price(payload))
		return true
	_set_hint_text("不可出售")
	_set_price_text(DEFAULT_PRICE_TEXT)
	return false


# 放下拖拽条目后，抛出统一出售信号。
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var payload: Dictionary = _normalize_payload(data)
	if payload.is_empty():
		_reset_visual()
		return
	if not _is_payload_supported(payload):
		_reset_visual()
		return
	sell_requested.emit(payload, _calc_price(payload))
	_manual_preview_active = false
	_reset_visual()


# 拖拽结束时清理视觉状态。
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and not _manual_preview_active:
		_reset_visual()


# 绑定场景内节点引用。
func _bind_nodes() -> void:
	_hint_label = get_node_or_null("RootVBox/HintLabel") as Label
	_price_label = get_node_or_null("RootVBox/PriceLabel") as Label
	_reject_icon = get_node_or_null("RejectIcon") as Label


# 应用回收区样式兜底，确保深色战场上可读。
func _apply_panel_style() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.18, 0.14, 0.14, 0.9)
	panel_style.border_color = Color(0.82, 0.42, 0.42, 0.95)
	panel_style.border_width_left = 2
	panel_style.border_width_top = 2
	panel_style.border_width_right = 2
	panel_style.border_width_bottom = 2
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	add_theme_stylebox_override("panel", panel_style)


# 把 view_model 投影到提示文案。
func _apply_view_model() -> void:
	if _view_model.is_empty():
		return
	var hint_text: String = str(_view_model.get("hint_text", "")).strip_edges()
	var price_text: String = str(_view_model.get("price_text", "")).strip_edges()
	if not hint_text.is_empty():
		_set_hint_text(hint_text)
	if not price_text.is_empty():
		_set_price_text(price_text)


# 复位回收区视觉与文案。
func _reset_visual() -> void:
	modulate = _default_modulate
	_set_hint_text(DEFAULT_HINT_TEXT)
	_set_price_text(DEFAULT_PRICE_TEXT)
	if _reject_icon != null:
		_reject_icon.visible = false


# 根据接收结果切换高亮与拒绝图标。
func _apply_drop_visual(accepted: bool) -> void:
	modulate = Color(1.0, 0.84, 0.84, 1.0) if accepted else Color(0.86, 0.86, 0.86, 1.0)
	if _reject_icon != null:
		_reject_icon.visible = not accepted


# 把拖拽数据标准化成字典。
func _normalize_payload(data: Variant) -> Dictionary:
	if data is Dictionary:
		return (data as Dictionary).duplicate(true)
	return {}


# 判定回收区是否支持该条目类型。
func _is_payload_supported(payload: Dictionary) -> bool:
	var item_type: String = str(payload.get("type", "")).strip_edges()
	return item_type == "unit" or item_type == "gongfa" or item_type == "equipment"


# 计算回收价格（角色按 cost，物品按品质）。
func _calc_price(payload: Dictionary) -> int:
	var item_type: String = str(payload.get("type", "")).strip_edges()
	if item_type == "unit":
		if payload.has("cost"):
			return maxi(int(payload.get("cost", 0)), 0)
		var unit_node: Node = payload.get("unit_node", null)
		if unit_node != null and is_instance_valid(unit_node):
			var cost_value: Variant = unit_node.get("cost")
			if cost_value == null:
				cost_value = 0
			return maxi(int(cost_value), 0)
		return 0
	var item_data: Dictionary = {}
	var raw_item_data: Variant = payload.get("item_data", {})
	if raw_item_data is Dictionary:
		item_data = (raw_item_data as Dictionary).duplicate(true)
	var quality_key: String = str(
		payload.get(
			"quality",
			item_data.get("quality", "white")
		)
	).strip_edges().to_lower()
	return int(QUALITY_SELL_PRICE.get(quality_key, 1))


# 安全设置提示文案。
func _set_hint_text(text: String) -> void:
	if _hint_label != null:
		_hint_label.text = text


# 安全设置价格文案。
func _set_price_text(text: String) -> void:
	if _price_label != null:
		_price_label.text = text
