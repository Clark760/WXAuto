extends Button
class_name InventoryFilterButtonView

# 仓库筛选按钮子场景视图
# 说明：
# 1. 只负责筛选按钮文案与选中态显示。
# 2. 点击后仅把 filter_id 回调给上层，不做仓库重建逻辑。

signal filter_selected(filter_id: String)

var _view_model: Dictionary = {}
var _actions: Dictionary = {}

# 节点就绪后先绑定点击信号，再应用当前 view_model。
func _ready() -> void:
	_bind_internal_signals()
	_apply_view_model()


# scene-first 统一入口：写入筛选按钮展示态。
func setup(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	else:
		_view_model = {}
	refresh(_view_model)


# scene-first 统一入口：刷新按钮文案、toggle 与按下状态。
func refresh(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	_apply_view_model()


# scene-first 统一入口：保存动作回调，不在视图层触碰库存状态。
func bind(actions: Variant) -> void:
	if actions is Dictionary:
		_actions = (actions as Dictionary).duplicate()
	else:
		_actions = {}


# 保证内部 pressed 信号只连接一次，避免重复触发。
func _bind_internal_signals() -> void:
	var callback: Callable = Callable(self, "_on_pressed")
	if is_connected("pressed", callback):
		return
	connect("pressed", callback)


# 将筛选名称与选中态投影到按钮本体。
func _apply_view_model() -> void:
	text = str(_view_model.get("name", "筛选"))
	toggle_mode = true
	button_pressed = bool(_view_model.get("selected", false))


# 点击只转发 filter_id，具体刷新由 shop/inventory 协作者决定。
func _on_pressed() -> void:
	filter_selected.emit(str(_view_model.get("id", "all")))
