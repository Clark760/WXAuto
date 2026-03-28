extends HBoxContainer
class_name ItemTooltipEffectRowView

# 物品效果行仅负责单行文案展示。
var _view_model: Dictionary = {}
var _actions: Dictionary = {}

var _line_label: Label = null


# 节点就绪后绑定文本节点并应用默认值。
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


# scene-first 入口：刷新效果文案。
func refresh(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	_apply_view_model()


# scene-first 入口：预留动作参数，当前仅缓存。
func bind(actions: Variant) -> void:
	if actions is Dictionary:
		_actions = (actions as Dictionary).duplicate()
	else:
		_actions = {}


# 绑定场景内的行文本标签。
func _bind_nodes() -> void:
	_line_label = get_node_or_null("LineLabel") as Label


# 将 view_model 文案投影到标签。
func _apply_view_model() -> void:
	if _line_label == null:
		return
	_line_label.text = str(_view_model.get("text", "· -"))
