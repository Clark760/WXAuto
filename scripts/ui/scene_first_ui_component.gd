extends Control
class_name SceneFirstUiComponent

# scene-first UI 子场景基础脚本
# 说明：
# 1. Phase 3 Batch 1 只提供统一的最小契约，先不承载具体业务渲染。
# 2. 后续批次会按组件类型拆成专用脚本；当前脚本作为过渡壳保留。

@export var component_id: String = ""

var _view_model: Variant = {}
var _actions: Variant = {}


# 统一的初始化入口：先记录 view_model，再执行一次刷新。
func setup(view_model: Variant) -> void:
	_view_model = view_model
	refresh(view_model)


# 统一刷新入口：当前阶段仅维护占位文本，后续批次再承接真实投影。
func refresh(view_model: Variant) -> void:
	_view_model = view_model
	_apply_placeholder_text()


# 统一动作绑定入口：Batch 1 只做存档，不在此阶段执行行为绑定。
func bind(actions: Variant) -> void:
	_actions = actions


# 调试/测试读取入口：返回当前绑定的 view_model 快照。
func get_bound_view_model() -> Variant:
	return _view_model


# 调试/测试读取入口：返回当前绑定的 actions 快照。
func get_bound_actions() -> Variant:
	return _actions


# 节点进入树后再补一次占位文本，确保编辑器预览与运行时一致。
func _ready() -> void:
	_apply_placeholder_text()


# 占位文本投影：
# 1. 优先使用 view_model.title / view_model.text。
# 2. 若无显式文案，回退到 component_id。
func _apply_placeholder_text() -> void:
	var fallback_text: String = component_id
	if _view_model is Dictionary:
		var vm: Dictionary = _view_model
		if vm.has("title"):
			fallback_text = str(vm.get("title", component_id))
		elif vm.has("text"):
			fallback_text = str(vm.get("text", component_id))

	if self is Button:
		var button: Button = self as Button
		if button.text.strip_edges().is_empty():
			button.text = fallback_text
		return

	var label: Label = get_node_or_null("PlaceholderLabel") as Label
	if label != null:
		label.text = fallback_text
