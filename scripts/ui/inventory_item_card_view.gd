extends "res://scripts/ui/battle_inventory_item_card.gd"
class_name InventoryItemCardView
const INK_THEME_BUILDER = preload("res://scripts/ui/ink_theme_builder.gd")

# 仓库卡片子场景视图
# 说明：
# 1. 复用 BattleInventoryItemCard 的点击/拖拽能力。
# 2. 这里仅把 view_model 投影到卡片节点，不做库存结算。

var _view_model: Dictionary = {}
var _actions: Dictionary = {}

var _quality_bar: ColorRect = null
var _icon_label: Label = null
var _name_label: Label = null
var _type_label: Label = null
var _status_label: Label = null


# 节点就绪后抓取子节点并刷新初始展示态。
func _ready() -> void:
	_bind_nodes()
	_apply_card_panel_style()
	_apply_view_model()


# scene-first 统一入口：注入仓库卡片展示字段。
func setup(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	else:
		_view_model = {}
	refresh(_view_model)


# scene-first 统一入口：刷新图标、名称、类型和库存状态文案。
func refresh(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	_apply_view_model()


# scene-first 统一入口：保留 actions 桩位，便于后续扩展卡片内部事件。
func bind(actions: Variant) -> void:
	if actions is Dictionary:
		_actions = (actions as Dictionary).duplicate()
	else:
		_actions = {}


# 绑定场景内固定节点引用，后续 refresh 只更新文本与颜色。
func _bind_nodes() -> void:
	_quality_bar = get_node_or_null("Root/QualityBar") as ColorRect
	_icon_label = get_node_or_null("Root/IconLabel") as Label
	_name_label = get_node_or_null("Root/NameLabel") as Label
	_type_label = get_node_or_null("Root/TypeLabel") as Label
	_status_label = get_node_or_null("Root/StatusLabel") as Label


# 将 view_model 投影到库存卡片，保持与旧 UI 字段口径一致。
func _apply_view_model() -> void:
	if _quality_bar != null:
		_quality_bar.color = _view_model.get("quality_color", Color(0.65, 0.65, 0.65, 1.0))
	if _icon_label != null:
		_icon_label.text = str(_view_model.get("icon", ""))
	if _name_label != null:
		_name_label.text = str(_view_model.get("name", "未知"))
	if _type_label != null:
		_type_label.text = str(_view_model.get("type_text", ""))
	if _status_label != null:
		_status_label.text = str(_view_model.get("status_text", ""))


# 仓库卡片与商店卡片共享同一张 SVG 边框，避免列表视觉漂移。
func _apply_card_panel_style() -> void:
	var card_style: StyleBox = INK_THEME_BUILDER.make_card_panel_style() as StyleBox
	if card_style != null:
		add_theme_stylebox_override("panel", card_style)
