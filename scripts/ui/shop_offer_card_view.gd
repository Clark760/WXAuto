extends PanelContainer
class_name ShopOfferCardView

# 商店卡片子场景视图
# 说明：
# 1. 只负责商店单卡显示和购买按钮点击转发。
# 2. 不做商店库存结算，业务仍由 coordinator 处理。

signal buy_requested(tab_id: String, index: int)

var _view_model: Dictionary = {}
var _actions: Dictionary = {}

var _color_bar: ColorRect = null
var _name_label: Label = null
var _type_label: Label = null
var _price_label: Label = null
var _buy_button: Button = null


# 节点就绪后完成节点绑定、信号连接与首帧渲染。
func _ready() -> void:
	_bind_nodes()
	_bind_internal_signals()
	_apply_view_model()


# scene-first 统一入口：注入商店卡片展示所需字段。
func setup(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	else:
		_view_model = {}
	refresh(_view_model)


# scene-first 统一入口：按当前 view_model 刷新卡片文案和按钮态。
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
	_buy_button = get_node_or_null("Root/BuyButton") as Button


# 仅绑定一次购买按钮事件，防止重刷时重复回调。
func _bind_internal_signals() -> void:
	if _buy_button == null:
		return
	var callback: Callable = Callable(self, "_on_buy_button_pressed")
	if _buy_button.is_connected("pressed", callback):
		return
	_buy_button.connect("pressed", callback)


# 将 view_model 投影到节点树，保持空位卡也有稳定骨架。
func _apply_view_model() -> void:
	if _color_bar == null or _name_label == null or _type_label == null:
		return
	if _price_label == null or _buy_button == null:
		return
	var is_empty: bool = bool(_view_model.get("is_empty", true))
	_color_bar.color = _view_model.get("quality_color", Color(0.65, 0.65, 0.65, 1.0))
	if is_empty:
		_name_label.text = "空位"
		_type_label.text = "暂无商品"
		_price_label.text = ""
		_buy_button.text = "—"
		_buy_button.disabled = true
		return
	_name_label.text = str(_view_model.get("name", "未知"))
	_type_label.text = str(_view_model.get("type_text", ""))
	_price_label.text = str(_view_model.get("price_text", ""))
	_buy_button.text = str(_view_model.get("buy_text", "购买"))
	_buy_button.disabled = bool(_view_model.get("buy_disabled", true))


# 购买按钮只发出视图事件，不在 view 层直接访问 coordinator。
func _on_buy_button_pressed() -> void:
	buy_requested.emit(
		str(_view_model.get("tab_id", "")),
		int(_view_model.get("index", -1))
	)
