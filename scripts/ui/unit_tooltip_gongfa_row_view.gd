extends PanelContainer
class_name UnitTooltipGongfaRowView

# 功法/特性行只做 tooltip 文本展示和 payload 投影。
var _view_model: Dictionary = {}
var _actions: Dictionary = {}

var _link: LinkButton = null


# 节点就绪后绑定子节点并应用默认文案。
func _ready() -> void:
	_bind_nodes()
	_apply_view_model()


# scene-first 入口：写入初始视图模型。
func setup(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	else:
		_view_model = {}
	refresh(_view_model)


# scene-first 入口：刷新文本、禁用态和 payload。
func refresh(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	_apply_view_model()


# scene-first 入口：预留动作参数，当前仅缓存不执行。
func bind(actions: Variant) -> void:
	if actions is Dictionary:
		_actions = (actions as Dictionary).duplicate()
	else:
		_actions = {}


# 返回链接按钮，供外层绑定 hover 保活逻辑。
func get_link_button() -> LinkButton:
	return _link


# 绑定场景内 NameLink 节点。
func _bind_nodes() -> void:
	_link = get_node_or_null("Row/NameLink") as LinkButton


# 将 view_model 映射到 link 文案与 item_data。
func _apply_view_model() -> void:
	if _link != null:
		_link.text = str(_view_model.get("text", "-"))
		_link.disabled = bool(_view_model.get("disabled", false))
	var payload: Variant = _view_model.get("item_payload", {})
	if payload is Dictionary:
		set_meta("item_data", (payload as Dictionary).duplicate(true))
	else:
		set_meta("item_data", {})
