extends Node

# M5 拖拽职责拆分模块
# 说明：该模块持有 battlefield_runtime 作为上下文。
# 不改外部接口，仅把拖拽逻辑下沉到 runtime 子模块。

var _owner: Node = null
var _drag_origin_kind: String = ""
var _drag_origin_slot: int = -1
var _drag_origin_cell: Vector2i = Vector2i(-999, -999)


func configure(host: Node) -> void:
	_owner = host


func try_begin_drag(screen_pos: Vector2) -> void:
	if _owner == null:
		return
	if _owner.get("_dragging_unit") != null:
		return
	var bench_ui: Node = _owner.get("bench_ui")
	if bench_ui == null:
		return
	var bench_slot: int = int(bench_ui.call("get_slot_index_at_screen_pos", screen_pos))
	if bench_slot >= 0:
		var bench_unit: Node = bench_ui.call("remove_unit_at", bench_slot)
		if bench_unit != null:
			begin_drag(bench_unit, "bench", bench_slot, Vector2i(-999, -999), screen_pos)
		return
	var world_pos: Vector2 = _owner.call("_screen_to_world", screen_pos)
	var deployed_unit: Node = _owner.call("_pick_deployed_ally_unit_at", world_pos)
	if deployed_unit == null:
		return
	var origin_cell: Vector2i = deployed_unit.get("deployed_cell")
	_owner.call("_remove_ally_mapping", deployed_unit)
	begin_drag(deployed_unit, "battlefield", -1, origin_cell, screen_pos)


func begin_drag(unit: Node, origin_kind: String, origin_slot: int, origin_cell: Vector2i, screen_pos: Vector2) -> void:
	if _owner == null:
		return
	_owner.set("_dragging_unit", unit)
	_drag_origin_kind = origin_kind
	_drag_origin_slot = origin_slot
	_drag_origin_cell = origin_cell
	# 为保持旧链路兼容，把拖拽来源写入 unit meta 供其他逻辑读取。
	unit.set_meta("drag_origin_kind", origin_kind)
	if unit is CanvasItem:
		(unit as CanvasItem).visible = false
	_owner.call("_update_drag_preview_data", unit)
	var drag_preview: Control = _owner.get("drag_preview")
	if drag_preview != null:
		drag_preview.visible = true
	_owner.call("_update_drag_preview", screen_pos)
	update_drag_target(screen_pos)
	_owner.call("_refresh_multimesh")


func try_end_drag(screen_pos: Vector2) -> void:
	if _owner == null:
		return
	var dragging_unit: Node = _owner.get("_dragging_unit")
	if dragging_unit == null:
		return
	var dropped: bool = false
	var target: Dictionary = get_drop_target(screen_pos)
	var target_type: String = str(target.get("type", "invalid"))
	if target_type == "battlefield":
		var cell: Vector2i = target.get("cell", Vector2i(-999, -999))
		if bool(_owner.call("_can_deploy_ally_to_cell", dragging_unit, cell)):
			_owner.call("_deploy_ally_unit_to_cell", dragging_unit, cell)
			dropped = true
	elif target_type == "bench":
		var slot_index: int = int(target.get("slot", -1))
		dropped = drop_to_bench_slot(dragging_unit, slot_index)
	if not dropped:
		restore_drag_origin()
	finish_drag()


func finish_drag() -> void:
	if _owner == null:
		return
	var dragging_unit: Node = _owner.get("_dragging_unit")
	var target_cell: Vector2i = _owner.get("_drag_target_cell")
	var had_drag_overlay: bool = dragging_unit != null or target_cell.x >= 0
	if dragging_unit != null and is_instance_valid(dragging_unit):
		dragging_unit.remove_meta("drag_origin_kind")
	_owner.set("_dragging_unit", null)
	_drag_origin_kind = ""
	_drag_origin_slot = -1
	_drag_origin_cell = Vector2i(-999, -999)
	_owner.set("_drag_target_cell", Vector2i(-999, -999))
	_owner.set("_drag_target_valid", false)
	var drag_preview: Control = _owner.get("drag_preview")
	if drag_preview != null:
		drag_preview.visible = false
	if had_drag_overlay:
		_owner.call("_request_drag_overlay_redraw", true)
	_owner.call("_refresh_multimesh")
	_owner.call("_refresh_all_ui")


func update_drag_target(screen_pos: Vector2) -> void:
	if _owner == null:
		return
	var previous_cell: Vector2i = _owner.get("_drag_target_cell")
	var previous_valid: bool = bool(_owner.get("_drag_target_valid"))
	var target: Dictionary = get_drop_target(screen_pos)
	var target_type: String = str(target.get("type", "invalid"))
	if target_type == "battlefield":
		var next_cell: Vector2i = target.get("cell", Vector2i(-999, -999))
		_owner.set("_drag_target_cell", next_cell)
		var dragging_unit: Node = _owner.get("_dragging_unit")
		_owner.set("_drag_target_valid", bool(_owner.call("_can_deploy_ally_to_cell", dragging_unit, next_cell)))
	else:
		_owner.set("_drag_target_cell", Vector2i(-999, -999))
		_owner.set("_drag_target_valid", false)
	var current_cell: Vector2i = _owner.get("_drag_target_cell")
	var current_valid: bool = bool(_owner.get("_drag_target_valid"))
	if previous_cell != current_cell or previous_valid != current_valid:
		_owner.call("_request_drag_overlay_redraw", true)


func get_drop_target(screen_mouse: Vector2) -> Dictionary:
	if _owner == null:
		return {"type": "invalid"}
	var bench_ui: Node = _owner.get("bench_ui")
	if bench_ui != null and bool(bench_ui.call("is_screen_point_inside", screen_mouse)):
		return {"type": "bench", "slot": int(bench_ui.call("get_slot_index_at_screen_pos", screen_mouse))}
	var hex_grid: Node = _owner.get("hex_grid")
	if hex_grid == null:
		return {"type": "invalid"}
	var world_pos: Vector2 = _owner.call("_screen_to_world", screen_mouse)
	var cell: Vector2i = hex_grid.call("world_to_axial", world_pos)
	if bool(hex_grid.call("is_inside_grid", cell)) and bool(_owner.call("_is_ally_deploy_zone", cell)):
		return {"type": "battlefield", "cell": cell}
	return {"type": "invalid"}


func drop_to_bench_slot(unit: Node, slot_index: int) -> bool:
	if _owner == null:
		return false
	var bench_ui: Node = _owner.get("bench_ui")
	if bench_ui == null:
		return false
	if slot_index < 0:
		return bool(bench_ui.call("add_unit", unit))
	var target_unit: Node = bench_ui.call("get_unit_at_slot", slot_index)
	if target_unit == null:
		return bool(bench_ui.call("add_unit_to_slot", unit, slot_index, false))
	if _drag_origin_kind == "bench" and _drag_origin_slot >= 0:
		var extracted: Node = bench_ui.call("remove_unit_at", slot_index)
		if extracted == null:
			return false
		if not bool(bench_ui.call("add_unit_to_slot", unit, slot_index, false)):
			bench_ui.call("add_unit_to_slot", extracted, slot_index, false)
			return false
		if bool(bench_ui.call("add_unit_to_slot", extracted, _drag_origin_slot, false)):
			return true
		# 原槽位回填失败时降级追加，避免交换过程中单位丢失。
		return bool(bench_ui.call("add_unit", extracted))
	return false


func restore_drag_origin() -> void:
	if _owner == null:
		return
	var dragging_unit: Node = _owner.get("_dragging_unit")
	if dragging_unit == null:
		return
	var bench_ui: Node = _owner.get("bench_ui")
	if _drag_origin_kind == "battlefield" and _drag_origin_cell.x > -900:
		_owner.call("_deploy_ally_unit_to_cell", dragging_unit, _drag_origin_cell)
		return
	if _drag_origin_kind == "bench" and _drag_origin_slot >= 0 and bench_ui != null:
		if bench_ui.call("get_unit_at_slot", _drag_origin_slot) == null:
			if bool(bench_ui.call("add_unit_to_slot", dragging_unit, _drag_origin_slot, false)):
				return
	if bench_ui != null:
		bench_ui.call("add_unit", dragging_unit)
