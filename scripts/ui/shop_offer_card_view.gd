extends PanelContainer
class_name ShopOfferCardView

# 商店卡片子场景视图
# 说明：
# 1. 只负责商店单卡显示和点击购买转发。
# 2. 不做商店库存结算，业务仍由 coordinator 处理。

signal buy_requested(tab_id: String, index: int)

var _view_model: Dictionary = {}
var _actions: Dictionary = {}

var _color_bar: ColorRect = null
var _name_label: Label = null
var _type_label: Label = null
var _price_label: Label = null
var _action_label: Label = null

var _pressing_left: bool = false
var _press_pos: Vector2 = Vector2.ZERO
const CLICK_DRIFT_THRESHOLD: float = 6.0


# 节点就绪后完成节点绑定、信号连接与首帧渲染。
func _ready() -> void:
	_bind_nodes()
	_set_children_mouse_filter_ignore()
	mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_view_model()


# scene-first 统一入口：注入商店卡片展示所需字段。
func setup(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	else:
		_view_model = {}
	refresh(_view_model)


# scene-first 统一入口：按当前 view_model 刷新卡片文案和可点击态。
func refresh(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	_apply_view_model()


# scene-first 统一入口：仅保存回调，不在这里做跨层业务调用。
func bind(actions: Variant) -> void:
	if actions is Dictionary:
		_actions = (actions as Dictionary).duplicate()
	else:
		_actions = {}


# 绑定场景节点引用，避免每次 refresh 重新查找路径。
func _bind_nodes() -> void:
	_color_bar = get_node_or_null("Root/ColorBar") as ColorRect
	_name_label = get_node_or_null("Root/NameLabel") as Label
	_type_label = get_node_or_null("Root/TypeLabel") as Label
	_price_label = get_node_or_null("Root/PriceLabel") as Label
	_action_label = get_node_or_null("Root/ActionLabel") as Label


# 将 view_model 投影到节点树，保持空位卡也有稳定骨架。
func _apply_view_model() -> void:
	if _color_bar == null or _name_label == null or _type_label == null:
		return
	if _price_label == null or _action_label == null:
		return
	var is_empty: bool = bool(_view_model.get("is_empty", true))
	var buy_disabled: bool = bool(_view_model.get("buy_disabled", true))
	_color_bar.color = _view_model.get("quality_color", Color(0.65, 0.65, 0.65, 1.0))
	if is_empty:
		_name_label.text = "空位"
		_type_label.text = "暂无商品"
		_price_label.text = ""
		_action_label.text = "—"
		_action_label.modulate = Color(0.7, 0.7, 0.7, 1.0)
		mouse_default_cursor_shape = Control.CURSOR_ARROW
		return
	_name_label.text = str(_view_model.get("name", "未知"))
	_type_label.text = str(_view_model.get("type_text", ""))
	_price_label.text = str(_view_model.get("price_text", ""))
	_action_label.text = str(_view_model.get("buy_text", "点击购买"))
	_action_label.modulate = (
		Color(0.95, 0.95, 0.95, 1.0)
		if not buy_disabled
		else Color(0.72, 0.72, 0.72, 1.0)
	)
	mouse_default_cursor_shape = (
		Control.CURSOR_POINTING_HAND
		if not buy_disabled
		else Control.CURSOR_ARROW
	)


# 点击卡片发出购买事件，不在 view 层直接访问 coordinator。
func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse_event: InputEventMouseButton = event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return
	if mouse_event.pressed:
		if not _is_buy_available():
			_pressing_left = false
			return
		_pressing_left = true
		_press_pos = mouse_event.position
		return
	if not _pressing_left:
		return
	_pressing_left = false
	if mouse_event.position.distance_to(_press_pos) > CLICK_DRIFT_THRESHOLD:
		return
	if not _is_buy_available():
		return
	_emit_buy_requested()


func _is_buy_available() -> bool:
	if bool(_view_model.get("is_empty", true)):
		return false
	return not bool(_view_model.get("buy_disabled", true))


func _emit_buy_requested() -> void:
	buy_requested.emit(
		str(_view_model.get("tab_id", "")),
		int(_view_model.get("index", -1))
	)


func _set_children_mouse_filter_ignore() -> void:
	var root: Node = get_node_or_null("Root")
	if root == null:
		return
	_set_tree_mouse_filter_ignore(root)


func _set_tree_mouse_filter_ignore(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			var control_child: Control = child as Control
			control_child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_set_tree_mouse_filter_ignore(child)
