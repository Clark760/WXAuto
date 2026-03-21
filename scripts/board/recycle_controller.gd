extends Node

# M5 ??????????


func try_sell_dragging_unit(ctx: Node) -> bool:
	if ctx == null:
		return false
	var dragging_unit: Node = ctx.get("_dragging_unit")
	if dragging_unit == null or not bool(ctx.call("_is_valid_unit", dragging_unit)):
		return false
	# ??????????????????????
	var origin_kind: String = str(dragging_unit.get_meta("drag_origin_kind", ""))
	if origin_kind != "bench":
		var debug_label: Label = ctx.get("debug_label")
		if debug_label != null:
			debug_label.text = "????????????????????"
		return false
	return bool(ctx.call("_sell_unit_node", dragging_unit))
