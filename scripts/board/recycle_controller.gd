extends Node

# M5 回收控制器：处理拖拽单位的出售校验与回收触发。


# 尝试出售当前拖拽中的单位。
# 返回：仅当单位来源为备战席且出售流程执行成功时返回 true。
func try_sell_dragging_unit(ctx: Node) -> bool:
	if ctx == null:
		return false
	var dragging_unit: Node = ctx.get("_dragging_unit")
	if dragging_unit == null or not bool(ctx.call("_is_valid_unit", dragging_unit)):
		return false
	# 仅允许出售“备战席来源”单位，阻止误卖战斗中的在编单位。
	var origin_kind: String = str(dragging_unit.get_meta("drag_origin_kind", ""))
	if origin_kind != "bench":
		var debug_label: Label = ctx.get("debug_label")
		if debug_label != null:
			debug_label.text = "仅允许出售从备战席拖拽出的单位。"
		return false
	return bool(ctx.call("_sell_unit_node", dragging_unit))
