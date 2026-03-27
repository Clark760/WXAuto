extends Node

# 战场拖拽协作者
# 说明：
# 1. 只处理拖拽来源、落点判定、预览更新与原位恢复。
# 2. Phase 2 起通过 refs + state + delegate 显式协作，不再回调 host.call(...)。
# 3. 这里不决定详情面板、tooltip、商店或结果面板的显示。
# 4. 这里不维护开战/结算，只处理准备期拖拽生命周期。
#
# 拖拽规则：
# 1. 备战席拖起要先 remove_unit_at，再进入预览态。
# 2. 棋盘拖起要先移除 ally_deployed 映射，再进入预览态。
# 3. 落点只分棋盘、备战席、无效三类。
# 4. 无效落点必须回原位，不能让单位丢失。
# 5. 原位恢复优先回原棋盘格，其次回原备战槽，再回备战席追加。
# 6. 任何拖拽状态都必须写回 state，而不是写回根场景私有字段。
# 7. 新旧入口兼容只体现在字段别名，不代表允许恢复旧接口。
# 8. 预览卡更新口径只走 delegate，避免这里直接抓更多 UI 节点。
# 9. 覆盖层重绘也只通过 delegate 请求，拖拽协作者自己不绘制。
#
# 迁移备忘：
# 1. 旧链路里拖拽起手、拖拽阈值和拖拽结束分散在 runtime 与 ui 两层。
# 2. Phase 2 先把拖拽生命周期收回到 world controller + drag_controller。
# 3. 这样 root scene 才能只保留输入转发，不再自己持有拖拽字段。
# 4. drag_controller 只知道“来源、落点、恢复”，不知道“详情面板、商店、回收区”。
# 5. 如果未来有回收区落点，应该由 world controller 先扩展目标类型再接入这里。
# 6. 这样可以避免拖拽协作者直接认识太多 UI 节点。
# 7. 新入口里所有拖拽态都写入 session state，便于测试读出。
# 8. 旧入口还保留下划线字段名，因此这里要兼容两套字段命名。
# 9. 但兼容只限字段名，不允许重新引入 configure(host) 或 host.call(...)。
# 10. 任何新的拖拽来源，例如装备卡、功法卡，都不应该直接塞进这个文件。
# 11. 那类 UI 拖拽属于 Batch 3 或 Phase 3 的 presenter / scene-first 范畴。
# 12. 这个文件的职责边界必须一直停留在“世界单位拖拽”。
# 13. 这样拖拽失败恢复、拖拽落位和高亮刷新才能保持同一口径。
# 14. 后续回放测试也能直接复用这里的棋盘/备战席落点规则。
# 15. 如果以后要记录拖拽审计日志，也应该在 world controller 或 coordinator 做。

const INVALID_CELL: Vector2i = Vector2i(-999, -999)

var _refs = null
var _state = null
var _delegate = null
var _initialized: bool = false


# ===========================
# 装配与生命周期入口
# ===========================
# 绑定 refs/state/delegate，拖拽过程中的所有状态都写回显式状态对象。
func initialize(refs, state, delegate) -> void:
	_refs = refs
	_state = state
	_delegate = delegate
	_initialized = (
		_refs != null
		and _state != null
		and _delegate != null
		and _get_ref("bench_ui") != null
		and _get_ref("hex_grid") != null
	)


# 暴露初始化状态，方便世界控制器确认运行时协作者已就位。
func is_initialized() -> bool:
	return _initialized


# ===========================
# 拖拽开始与结束
# ===========================
# 从备战席或棋盘拾取单位并进入拖拽态，只负责世界层来源判定。
func try_begin_drag(screen_pos: Vector2) -> void:
	if _read_state("dragging_unit", null) != null:
		return
	var bench_ui = _get_ref("bench_ui")
	if bench_ui == null:
		return

	var bench_slot: int = int(bench_ui.get_slot_index_at_screen_pos(screen_pos))
	if bench_slot >= 0:
		var bench_unit: Node = bench_ui.remove_unit_at(bench_slot)
		if bench_unit != null:
			begin_drag(bench_unit, "bench", bench_slot, INVALID_CELL, screen_pos)
		return

	var world_pos: Vector2 = _delegate._screen_to_world(screen_pos)
	var deployed_unit: Node = _delegate._pick_deployed_ally_unit_at(world_pos)
	if deployed_unit == null:
		return
	var origin_cell: Vector2i = deployed_unit.get("deployed_cell")
	_delegate._remove_ally_mapping(deployed_unit)
	begin_drag(deployed_unit, "battlefield", -1, origin_cell, screen_pos)


# 建立拖拽来源、预览卡和落点预判，是拖拽生命周期的统一入口。
func begin_drag(
	unit: Node,
	origin_kind: String,
	origin_slot: int,
	origin_cell: Vector2i,
	screen_pos: Vector2
) -> void:
	if unit == null:
		return
	_write_state("dragging_unit", unit)
	_write_state("drag_origin_kind", origin_kind)
	_write_state("drag_origin_slot", origin_slot)
	_write_state("drag_origin_cell", origin_cell)

	var canvas_item: CanvasItem = unit as CanvasItem
	if canvas_item != null:
		canvas_item.visible = false

	_delegate._update_drag_preview_data(unit)
	_delegate._set_drag_preview_visible(true)
	_delegate._update_drag_preview(screen_pos)
	update_drag_target(screen_pos)
	_delegate._refresh_multimesh()


# 在鼠标释放时解析真实落点，并决定部署、回席还是原位恢复。
func try_end_drag(screen_pos: Vector2) -> void:
	var dragging_unit: Node = _read_state("dragging_unit", null)
	if dragging_unit == null:
		return

	var dropped: bool = false
	var target: Dictionary = get_drop_target(screen_pos)
	var target_type: String = str(target.get("type", "invalid"))
	if target_type == "battlefield":
		var cell: Vector2i = target.get("cell", INVALID_CELL)
		if _delegate._can_deploy_ally_to_cell(dragging_unit, cell):
			_delegate._deploy_ally_unit_to_cell(dragging_unit, cell)
			dropped = true
	elif target_type == "bench":
		var slot_index: int = int(target.get("slot", -1))
		dropped = drop_to_bench_slot(dragging_unit, slot_index)
	elif target_type == "recycle":
		dropped = bool(_delegate._try_sell_dragging_unit())

	if not dropped:
		restore_drag_origin()
	finish_drag()


# ===========================
# 落点与恢复
# ===========================
# 清理拖拽状态和高亮覆盖层，保证下一次拖拽从干净状态开始。
func finish_drag() -> void:
	var dragging_unit: Node = _read_state("dragging_unit", null)
	var target_cell: Vector2i = _read_state("drag_target_cell", INVALID_CELL)
	var had_drag_overlay: bool = dragging_unit != null or target_cell.x >= 0

	_write_state("dragging_unit", null)
	_write_state("drag_origin_kind", "")
	_write_state("drag_origin_slot", -1)
	_write_state("drag_origin_cell", INVALID_CELL)
	_write_state("drag_target_cell", INVALID_CELL)
	_write_state("drag_target_valid", false)

	_delegate._set_drag_preview_visible(false)
	var recycle_drop_zone = _get_ref("recycle_drop_zone")
	if recycle_drop_zone != null and recycle_drop_zone.has_method("clear_external_preview"):
		recycle_drop_zone.call("clear_external_preview")
	if had_drag_overlay:
		_delegate._request_drag_overlay_redraw(true)
	_delegate._refresh_multimesh()
	_delegate._refresh_all_ui()


# 实时更新拖拽落点和合法性高亮，供根场景绘制提示框。
func update_drag_target(screen_pos: Vector2) -> void:
	var previous_cell: Vector2i = _read_state("drag_target_cell", INVALID_CELL)
	var previous_valid: bool = bool(_read_state("drag_target_valid", false))
	var target: Dictionary = get_drop_target(screen_pos)
	var target_type: String = str(target.get("type", "invalid"))
	var recycle_drop_zone = _get_ref("recycle_drop_zone")

	if target_type == "battlefield":
		var next_cell: Vector2i = target.get("cell", INVALID_CELL)
		_write_state("drag_target_cell", next_cell)
		var dragging_unit: Node = _read_state("dragging_unit", null)
		_write_state("drag_target_valid", _delegate._can_deploy_ally_to_cell(dragging_unit, next_cell))
	else:
		_write_state("drag_target_cell", INVALID_CELL)
		_write_state("drag_target_valid", false)

	if recycle_drop_zone != null:
		if target_type == "recycle":
			var dragging_unit: Node = _read_state("dragging_unit", null)
			var payload: Dictionary = {
				"type": "unit",
				"id": str(dragging_unit.get("unit_id")) if dragging_unit != null else "",
				"unit_node": dragging_unit,
				"cost": int(dragging_unit.get("cost")) if dragging_unit != null else 0
			}
			var accepted: bool = str(_read_state("drag_origin_kind", "")) == "bench"
			if recycle_drop_zone.has_method("set_external_preview"):
				recycle_drop_zone.call("set_external_preview", payload, accepted)
		elif recycle_drop_zone.has_method("clear_external_preview"):
			recycle_drop_zone.call("clear_external_preview")

	var current_cell: Vector2i = _read_state("drag_target_cell", INVALID_CELL)
	var current_valid: bool = bool(_read_state("drag_target_valid", false))
	if previous_cell != current_cell or previous_valid != current_valid:
		_delegate._request_drag_overlay_redraw(true)


# 统一解析当前鼠标落点属于备战席、棋盘还是无效区域。
func get_drop_target(screen_mouse: Vector2) -> Dictionary:
	var recycle_drop_zone = _get_ref("recycle_drop_zone")
	if recycle_drop_zone != null \
	and recycle_drop_zone.visible \
	and recycle_drop_zone.get_global_rect().has_point(screen_mouse):
		return {"type": "recycle"}
	var bench_ui = _get_ref("bench_ui")
	if bench_ui != null and bench_ui.is_screen_point_inside(screen_mouse):
		return {"type": "bench", "slot": int(bench_ui.get_slot_index_at_screen_pos(screen_mouse))}

	var hex_grid = _get_ref("hex_grid")
	if hex_grid == null:
		return {"type": "invalid"}
	var world_pos: Vector2 = _delegate._screen_to_world(screen_mouse)
	var cell: Vector2i = hex_grid.world_to_axial(world_pos)
	if hex_grid.is_inside_grid(cell) and _delegate._is_ally_deploy_zone(cell):
		return {"type": "battlefield", "cell": cell}
	return {"type": "invalid"}


# 处理拖回备战席和同席位交换，是拖拽结束的“回席”分支。
func drop_to_bench_slot(unit: Node, slot_index: int) -> bool:
	var bench_ui = _get_ref("bench_ui")
	if unit == null or bench_ui == null:
		return false
	if slot_index < 0:
		return bool(bench_ui.add_unit(unit))

	var target_unit: Node = bench_ui.get_unit_at_slot(slot_index)
	if target_unit == null:
		return bool(bench_ui.add_unit_to_slot(unit, slot_index, false))

	var origin_kind: String = str(_read_state("drag_origin_kind", ""))
	var origin_slot: int = int(_read_state("drag_origin_slot", -1))
	if origin_kind == "bench" and origin_slot >= 0:
		var extracted: Node = bench_ui.remove_unit_at(slot_index)
		if extracted == null:
			return false
		if not bool(bench_ui.add_unit_to_slot(unit, slot_index, false)):
			bench_ui.add_unit_to_slot(extracted, slot_index, false)
			return false
		if bool(bench_ui.add_unit_to_slot(extracted, origin_slot, false)):
			return true
		return bool(bench_ui.add_unit(extracted))
	return false


# 落点无效时把单位送回来源位置，避免拖拽失败后单位丢失。
func restore_drag_origin() -> void:
	var dragging_unit: Node = _read_state("dragging_unit", null)
	if dragging_unit == null:
		return

	var bench_ui = _get_ref("bench_ui")
	var origin_kind: String = str(_read_state("drag_origin_kind", ""))
	var origin_slot: int = int(_read_state("drag_origin_slot", -1))
	var origin_cell: Vector2i = _read_state("drag_origin_cell", INVALID_CELL)

	if origin_kind == "battlefield" and origin_cell.x > -900:
		_delegate._deploy_ally_unit_to_cell(dragging_unit, origin_cell)
		return
	if origin_kind == "bench" and origin_slot >= 0 and bench_ui != null:
		if bench_ui.get_unit_at_slot(origin_slot) == null:
			if bool(bench_ui.add_unit_to_slot(dragging_unit, origin_slot, false)):
				return
	if bench_ui != null:
		bench_ui.add_unit(dragging_unit)


# 对外暴露拖拽来源种类，便于世界层做准备期专属分支。
func get_drag_origin_kind() -> String:
	return str(_read_state("drag_origin_kind", ""))


# ===========================
# 新旧入口兼容读取
# ===========================
# refs 读取同时兼容新入口的 refs 节点和旧 runtime 直传对象。
func _get_ref(key: String, default_value = null):
	if _refs == null:
		return default_value
	if _refs is Dictionary:
		return (_refs as Dictionary).get(key, default_value)
	var value: Variant = _refs.get(key)
	if value == null:
		return default_value
	return value


# state 读取同时兼容新字段名与旧 runtime 的下划线字段名。
func _read_state(key: String, default_value = null):
	if _state == null:
		return default_value
	var keys: Array[String] = [key, "_%s" % key]
	if _state is Dictionary:
		var dict_state: Dictionary = _state as Dictionary
		for current_key in keys:
			if dict_state.has(current_key):
				return dict_state[current_key]
		return default_value
	for current_key in keys:
		if _has_property(_state, current_key):
			return _state.get(current_key)
	return default_value


# state 写回必须统一走这里，确保新旧入口都能落到正确字段。
func _write_state(key: String, value) -> void:
	if _state == null:
		return
	var keys: Array[String] = [key, "_%s" % key]
	if _state is Dictionary:
		var dict_state: Dictionary = _state as Dictionary
		dict_state[keys[0]] = value
		return
	for current_key in keys:
		if _has_property(_state, current_key):
			_state.set(current_key, value)
			return
	_state.set(keys[0], value)


# 通过属性表探测字段存在性，避免把旧入口没有的字段强行写进去。
func _has_property(target, property_name: String) -> bool:
	if target == null or not (target is Object):
		return false
	var properties: Array = (target as Object).get_property_list()
	for property_value in properties:
		if not (property_value is Dictionary):
			continue
		var property_info: Dictionary = property_value as Dictionary
		if str(property_info.get("name", "")) == property_name:
			return true
	return false

