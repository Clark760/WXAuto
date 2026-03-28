extends BattleSlotDropTarget
class_name SlotRowView

# 槽位行仅负责展示和交互转发，不做库存结算。
signal unequip_requested(slot_category: String, slot_key: String)

var _view_model: Dictionary = {}
var _actions: Dictionary = {}

var _icon_label: Label = null
var _name_button: LinkButton = null
var _unequip_button: Button = null


# 节点就绪后绑定子节点并投影默认视图模型。
func _ready() -> void:
	super._ready()
	_bind_nodes()
	_bind_internal_signals()
	_apply_view_model()


# scene-first 入口：写入初始视图模型并同步槽位标识。
func setup(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	else:
		_view_model = {}
	var category: String = str(_view_model.get("slot_category", "")).strip_edges()
	var key: String = str(_view_model.get("slot_key", "")).strip_edges()
	if not category.is_empty() and not key.is_empty():
		setup_slot(category, key)
	if _view_model.has("drop_enabled"):
		set_drop_enabled(bool(_view_model.get("drop_enabled", true)))
	refresh(_view_model)


# scene-first 入口：刷新显示文本、禁用态和拖放开关。
func refresh(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	if _view_model.has("drop_enabled"):
		set_drop_enabled(bool(_view_model.get("drop_enabled", true)))
	_apply_view_model()


# scene-first 入口：预留动作绑定参数，便于后续扩展。
func bind(actions: Variant) -> void:
	if actions is Dictionary:
		_actions = (actions as Dictionary).duplicate()
	else:
		_actions = {}


# 返回名称按钮，外层用于绑定 hover 入口。
func get_name_button() -> LinkButton:
	return _name_button


# 返回卸下按钮，外层用于绑定 hover 入口。
func get_unequip_button() -> Button:
	return _unequip_button


# 绑定场景内子节点引用。
func _bind_nodes() -> void:
	_icon_label = get_node_or_null("Row/IconLabel") as Label
	_name_button = get_node_or_null("Row/NameButton") as LinkButton
	_unequip_button = get_node_or_null("Row/UnequipButton") as Button


# 确保内部按钮信号只连接一次，避免重复触发。
func _bind_internal_signals() -> void:
	if _unequip_button == null:
		return
	var callback: Callable = Callable(self, "_on_unequip_button_pressed")
	if _unequip_button.is_connected("pressed", callback):
		return
	_unequip_button.connect("pressed", callback)


# 将 view_model 投影到文本、按钮状态和 item_data。
func _apply_view_model() -> void:
	if _icon_label != null:
		_icon_label.text = str(_view_model.get("icon_text", ""))
	if _name_button != null:
		_name_button.text = str(_view_model.get("name_text", "-"))
		_name_button.disabled = bool(_view_model.get("name_disabled", true))
	if _unequip_button != null:
		_unequip_button.text = str(_view_model.get("unequip_text", "—"))
		_unequip_button.disabled = bool(_view_model.get("unequip_disabled", true))
	var payload: Variant = _view_model.get("item_payload", {})
	if payload is Dictionary:
		set_meta("item_data", (payload as Dictionary).duplicate(true))
	else:
		set_meta("item_data", {})


# 卸下按钮仅发信号，实际业务交由外层协作者处理。
func _on_unequip_button_pressed() -> void:
	unequip_requested.emit(slot_category, slot_key)
