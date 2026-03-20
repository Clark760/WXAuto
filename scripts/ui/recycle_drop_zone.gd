extends PanelContainer

# ===========================
# 回收出售槽（拖放接收器）
# ===========================
# 说明：
# 1. 支持接收两类拖拽来源：
#    - Godot GUI 拖拽（功法/装备卡片）
#    - 战场脚本手动拖拽（备战区角色）
# 2. 对合法条目实时显示预估售价，并在放下后抛出统一售卖信号。

signal sell_requested(payload: Dictionary, price: int)

const QUALITY_SELL_PRICE: Dictionary = {
	"white": 1,
	"green": 2,
	"blue": 3,
	"purple": 5,
	"orange": 8,
	"red": 15
}

var drop_enabled: bool = true
var _default_modulate: Color = Color(1, 1, 1, 1)
var _manual_preview_active: bool = false

var _hint_label: Label = null
var _price_label: Label = null
var _reject_icon: Label = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_default_modulate = modulate
	_build_ui()
	_reset_visual()


func set_drop_enabled(enabled: bool) -> void:
	drop_enabled = enabled
	if not drop_enabled:
		_reset_visual()


func set_external_preview(payload: Dictionary, accepted: bool) -> void:
	# 外部拖拽（备战角色）不走 Godot 原生 _can_drop_data，因此提供手动预览入口。
	_manual_preview_active = true
	_apply_drop_visual(accepted)
	if accepted:
		_hint_label.text = "松手出售"
		_price_label.text = "💰 +%d" % _calc_price(payload)
	else:
		_hint_label.text = "🚫 仅可出售备战角色"
		_price_label.text = "💰 ?"


func clear_external_preview() -> void:
	_manual_preview_active = false
	_reset_visual()


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
		_hint_label.text = "松手出售"
		_price_label.text = "💰 +%d" % _calc_price(payload)
	else:
		_hint_label.text = "不可出售"
		_price_label.text = "💰 ?"
	return accepted


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var payload: Dictionary = _normalize_payload(data)
	if payload.is_empty():
		_reset_visual()
		return
	if not _is_payload_supported(payload):
		_reset_visual()
		return
	var price: int = _calc_price(payload)
	sell_requested.emit(payload, price)
	_manual_preview_active = false
	_reset_visual()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and not _manual_preview_active:
		_reset_visual()


func _build_ui() -> void:
	if _hint_label != null and is_instance_valid(_hint_label):
		return
	custom_minimum_size = Vector2(148, 0)
	# 回收区必须在深色战场背景下有稳定可见度，显式设置面板底色与边框。
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

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var icon := Label.new()
	icon.text = "🗑️"
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.add_theme_font_size_override("font_size", 30)
	root.add_child(icon)

	_hint_label = Label.new()
	_hint_label.text = "拖入出售"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.add_theme_font_size_override("font_size", 15)
	root.add_child(_hint_label)

	_price_label = Label.new()
	_price_label.text = "💰 ?"
	_price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_price_label.add_theme_font_size_override("font_size", 18)
	root.add_child(_price_label)

	_reject_icon = Label.new()
	_reject_icon.text = "🚫"
	_reject_icon.visible = false
	_reject_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reject_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_reject_icon.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_reject_icon.anchor_left = 1.0
	_reject_icon.anchor_right = 1.0
	_reject_icon.offset_left = -36.0
	_reject_icon.offset_right = -8.0
	_reject_icon.offset_top = 6.0
	_reject_icon.offset_bottom = 34.0
	add_child(_reject_icon)


func _reset_visual() -> void:
	modulate = _default_modulate
	if _hint_label != null:
		_hint_label.text = "拖入出售"
	if _price_label != null:
		_price_label.text = "💰 ?"
	if _reject_icon != null:
		_reject_icon.visible = false


func _apply_drop_visual(accepted: bool) -> void:
	# 回收槽的视觉语义：可卖时偏红（危险操作），不可卖时灰化并显示 🚫。
	modulate = Color(1.0, 0.84, 0.84, 1.0) if accepted else Color(0.86, 0.86, 0.86, 1.0)
	if _reject_icon != null:
		_reject_icon.visible = not accepted


func _normalize_payload(data: Variant) -> Dictionary:
	if data is Dictionary:
		return (data as Dictionary).duplicate(true)
	return {}


func _is_payload_supported(payload: Dictionary) -> bool:
	var item_type: String = str(payload.get("type", "")).strip_edges()
	return item_type == "unit" or item_type == "gongfa" or item_type == "equipment"


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
			item_data.get("quality", item_data.get("rarity", "white"))
		)
	).strip_edges().to_lower()
	return int(QUALITY_SELL_PRICE.get(quality_key, 1))
