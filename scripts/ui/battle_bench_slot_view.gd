extends PanelContainer
class_name BattleBenchSlotView

# 备战席槽位子场景视图
# 说明：
# 1. 只负责槽位 UI 结构和文本/颜色投影，不处理备战席业务规则。
# 2. BattleBenchUI 统一实例化这一子场景，避免再用代码硬拼控件树。

var _icon_rect: ColorRect = null
var _name_label: Label = null
var _star_label: Label = null
var _content_box: VBoxContainer = null


# 节点进入树后缓存固定子节点，后续刷新只改文本和颜色。
func _ready() -> void:
	_bind_nodes()


# 统一写入槽位尺寸、提示文案和可交互态，避免外层散写节点属性。
func configure_slot(slot_index: int, slot_size: Vector2, interactable: bool) -> void:
	_bind_nodes()
	custom_minimum_size = slot_size
	size_flags_horizontal = 0
	size_flags_vertical = 0
	tooltip_text = "槽位 %d" % (slot_index + 1)
	set_interactable(interactable)
	if _content_box != null:
		_content_box.custom_minimum_size = slot_size
	if _icon_rect != null:
		var icon_height: float = clampf(slot_size.y * 0.55, 28.0, slot_size.x - 10.0)
		_icon_rect.custom_minimum_size = Vector2(slot_size.x - 10.0, icon_height)


# 槽位交互开关统一收口，外层不用再直接碰根节点 mouse_filter。
func set_interactable(value: bool) -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS if value else Control.MOUSE_FILTER_IGNORE


# 空槽位只显示默认背景和占位文本。
func apply_empty_state() -> void:
	_bind_nodes()
	if _icon_rect != null:
		_icon_rect.color = Color(0.16, 0.19, 0.23, 0.65)
	if _name_label != null:
		_name_label.text = "空"
	if _star_label != null:
		_star_label.text = ""
		_star_label.modulate = Color(1, 1, 1, 1)


# 有单位时只投影名称、星级和品质色，不承接备战席规则判断。
func apply_unit_state(unit_name: String, star: int, quality_color: Color, star_color: Color) -> void:
	_bind_nodes()
	if _icon_rect != null:
		_icon_rect.color = quality_color
	if _name_label != null:
		_name_label.text = unit_name
	if _star_label != null:
		_star_label.text = "★".repeat(clampi(star, 1, 3))
		_star_label.modulate = star_color


# 固定节点路径只在这里维护，BattleBenchUI 不再知道内部结构细节。
func _bind_nodes() -> void:
	if _content_box == null:
		_content_box = get_node_or_null("Content") as VBoxContainer
	if _icon_rect == null:
		_icon_rect = get_node_or_null("Content/IconRect") as ColorRect
	if _name_label == null:
		_name_label = get_node_or_null("Content/NameLabel") as Label
	if _star_label == null:
		_star_label = get_node_or_null("Content/StarLabel") as Label
