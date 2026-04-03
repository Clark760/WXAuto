extends RefCounted
class_name CombatTerrainService


# 负责 Combat 的地形 registry、动态/静态地形与地形 tick。
# `manager` 仍是 facade，持有信号、HexGrid 与运行时缓存。
# 这里不重新定义玩法语义，只迁移原先堆在 CombatManager 内的实现体。
func reload_terrain_registry(
	manager,
	data_manager: Node = null
) -> void:
	var terrain_manager = manager._terrain_manager
	if terrain_manager == null:
		return

	# DataManager 允许外部显式传入；为空时再退回 Combat 自己的场景查找。
	var resolved_data_manager: Node = data_manager
	if resolved_data_manager == null or not is_instance_valid(resolved_data_manager):
		resolved_data_manager = manager._get_data_manager_node()

	var terrain_records: Array = []
	if resolved_data_manager != null and is_instance_valid(resolved_data_manager):
		var data_api: Variant = resolved_data_manager
		if resolved_data_manager.has_method("get_all_records"):
			var records_value: Variant = data_api.get_all_records("terrains")
			if records_value is Array:
				terrain_records = records_value as Array

	terrain_manager.set_terrain_registry(terrain_records)
	manager._terrain_registry_loaded = not terrain_records.is_empty()
	apply_terrain_visuals(manager)


# 临时地形入口保留原有返回值：只返回是否真正添加成功。
# `config` 仍由 effect/runtime gateway 组装，这里只做 Combat 侧接入。
# barrier 与 visual 的后处理保持旧顺序，避免事件和阻挡刷新时序漂移。
func add_temporary_terrain(
	manager,
	config: Dictionary,
	source: Node = null
) -> bool:
	var terrain_manager = manager._terrain_manager
	if terrain_manager == null:
		return false
	if not manager._terrain_registry_loaded:
		reload_terrain_registry(manager)

	var result: Dictionary = terrain_manager.add_terrain(config, source, {
		"hex_grid": manager._hex_grid
	})
	_sync_dynamic_barrier_cells(manager, result)
	if bool(result.get("visual_changed", false)):
		apply_terrain_visuals(manager)
	if bool(result.get("barrier_changed", false)) or bool(result.get("visual_changed", false)):
		emit_terrain_changed(manager, "add_temporary")
	if bool(result.get("added", false)):
		var terrain_value: Variant = result.get("terrain", {})
		if terrain_value is Dictionary:
			manager.terrain_created.emit((terrain_value as Dictionary).duplicate(true), "add_temporary")
	return bool(result.get("added", false))


# 清空临时地形时，Combat 自己维护的动态阻挡缓存也必须同步清空。
# 这里仍会强制刷新可视层，避免 HexGrid 上残留旧着色。
# 即使没有任何地形实例，也保持旧版“调用即广播 clear_temporary”的行为。
func clear_temporary_terrains(manager) -> void:
	var terrain_manager = manager._terrain_manager
	if terrain_manager != null:
		terrain_manager.clear_temporary_terrains()
	manager.clear_terrain_blocked_cells()
	apply_terrain_visuals(manager)
	emit_terrain_changed(manager, "clear_temporary")


# 静态地形通常来自关卡装配，因此入口保留 `terrain_id + cells + extra_config` 形式。
# `cells` 继续允许外层传原始 Array，TerrainManager 会负责解析成 Vector2i 列表。
# 添加成功后的 `terrain_created` reason 继续区分为 add_static。
func add_static_terrain(
	manager,
	terrain_id: String,
	cells: Array,
	extra_config: Dictionary = {}
) -> bool:
	var terrain_manager = manager._terrain_manager
	if terrain_manager == null:
		return false
	if not manager._terrain_registry_loaded:
		reload_terrain_registry(manager)

	var result: Dictionary = terrain_manager.add_static_terrain(
		terrain_id,
		cells,
		{"hex_grid": manager._hex_grid},
		extra_config
	)
	_sync_static_barrier_cells(manager, result)
	if bool(result.get("visual_changed", false)):
		apply_terrain_visuals(manager)
	if bool(result.get("barrier_changed", false)) or bool(result.get("visual_changed", false)):
		emit_terrain_changed(manager, "add_static")
	if bool(result.get("added", false)):
		var terrain_value: Variant = result.get("terrain", {})
		if terrain_value is Dictionary:
			manager.terrain_created.emit((terrain_value as Dictionary).duplicate(true), "add_static")
	return bool(result.get("added", false))


# 清空静态地形时只影响关卡障碍，不动临时地形实例。
# 这一点必须和 `clear_temporary_terrains` 分开，否则战斗中召唤地形会被误删。
# 阻挡与视觉缓存都按旧逻辑立即重建。
func clear_static_terrains(manager) -> void:
	var terrain_manager = manager._terrain_manager
	if terrain_manager != null:
		terrain_manager.clear_static_terrains()
	manager.clear_static_blocked_cells()
	apply_terrain_visuals(manager)
	emit_terrain_changed(manager, "clear_static")


# Combat 对外暴露的是“某格有哪些 terrain tag”，因此这里直接透传 TerrainManager。
# `scope` 语义保持不变，仍支持 all/static/dynamic。
# 返回值必须是去重后的 Array[String]，供 trigger 和 UI tooltip 共用。
func get_terrain_tags_at_cell(
	manager,
	cell: Vector2i,
	scope: String = "all"
) -> Array[String]:
	var terrain_manager = manager._terrain_manager
	if terrain_manager == null:
		return []
	return terrain_manager.get_terrain_tags_at_cell(cell, scope, manager._hex_grid)


# 查询指定格子的地形条目快照，供 HUD 悬停提示展示名称/类型/效果概要。
# 返回数组内容来自 TerrainManager 的只读快照，不暴露内部实例引用。
func get_terrain_entries_at_cell(
	manager,
	cell: Vector2i,
	scope: String = "all"
) -> Array[Dictionary]:
	var terrain_manager = manager._terrain_manager
	if terrain_manager == null:
		return []
	return terrain_manager.get_terrain_entries_at_cell(cell, scope, manager._hex_grid)


# 布尔查询入口统一复用 TerrainManager 的 tag 查询。
# `tag` 会在 TerrainManager 内部做标准化，这里不重复处理。
# Combat 只负责兜底 null manager 的情况。
func cell_has_terrain_tag(
	manager,
	cell: Vector2i,
	tag: String,
	scope: String = "all"
) -> bool:
	var terrain_manager = manager._terrain_manager
	if terrain_manager == null:
		return false
	return terrain_manager.cell_has_terrain_tag(cell, tag, scope, manager._hex_grid)


# 地形 tick 只负责推进地形生命周期和回放 phase event。
# `delta` 使用 Combat 固定逻辑步长，不额外引入第二套时间口径。
# 进入、退出、tick、expire 的事件顺序仍完全由 TerrainManager 决定。
func tick_terrain(manager, delta: float) -> void:
	var terrain_manager = manager._terrain_manager
	if terrain_manager == null or manager._hex_grid == null:
		return

	var tick_result: Dictionary = terrain_manager.tick(delta, {
		"combat_manager": manager,
		"hex_grid": manager._hex_grid,
		"all_units": manager._all_units,
		"unit_augment_manager": manager._get_unit_augment_manager()
	})

	var phase_events_value: Variant = tick_result.get("phase_events", [])
	if phase_events_value is Array:
		for event_value in (phase_events_value as Array):
			if not (event_value is Dictionary):
				continue
			manager.terrain_phase_tick.emit((event_value as Dictionary).duplicate(true))

	_sync_dynamic_barrier_cells(manager, tick_result)
	if bool(tick_result.get("visual_changed", false)):
		apply_terrain_visuals(manager)
	if bool(tick_result.get("barrier_changed", false)) or bool(tick_result.get("visual_changed", false)):
		emit_terrain_changed(manager, "tick")


# HexGrid 上的可视地形始终来自 TerrainManager 的 visual cache。
# manager 只持有 HexGrid 引用，不再在 facade 内自己组 visual map。
# 这里故意不发 signal；signal 由显式调用 `emit_terrain_changed` 的路径统一处理。
func apply_terrain_visuals(manager) -> void:
	var hex_grid: Node = manager._hex_grid
	if hex_grid == null or not is_instance_valid(hex_grid):
		return
	if not hex_grid.has_method("set_terrain_cells"):
		return

	var visual_cells: Dictionary = {}
	var terrain_manager = manager._terrain_manager
	if terrain_manager != null:
		visual_cells = terrain_manager.get_visual_cells(hex_grid)
	var hex_grid_api: Variant = hex_grid
	hex_grid_api.set_terrain_cells(visual_cells)


# terrain_changed 只关心“上次可视格集合”和“本次可视格集合”的差异。
# `_last_terrain_cells` 仍存 int-key map，避免每次 signal 都保留 Vector2i 大数组。
# reason 继续由调用方显式传入，方便 trigger 与调试区分来源。
func emit_terrain_changed(manager, reason: String) -> void:
	var terrain_manager = manager._terrain_manager
	var hex_grid: Node = manager._hex_grid
	if terrain_manager == null or hex_grid == null or not is_instance_valid(hex_grid):
		manager.terrain_changed.emit([], reason)
		return

	var visual_cells: Dictionary = terrain_manager.get_visual_cells(hex_grid)
	var next_cells: Dictionary = {}
	for key_value in visual_cells.keys():
		next_cells[int(key_value)] = true

	var changed_map: Dictionary = {}
	for key_value in manager._last_terrain_cells.keys():
		var key_before: int = int(key_value)
		if not next_cells.has(key_before):
			changed_map[key_before] = true
	for key_value in next_cells.keys():
		var key_after: int = int(key_value)
		if not manager._last_terrain_cells.has(key_after):
			changed_map[key_after] = true

	var changed_cells: Array[Vector2i] = []
	for key_value in changed_map.keys():
		changed_cells.append(manager._cell_from_key_int(int(key_value)))

	manager._last_terrain_cells = next_cells
	manager.terrain_changed.emit(changed_cells, reason)


# 动态 barrier 只来自临时地形或 tick 中生成/消失的地形。
# 这里不碰静态阻挡缓存，避免把关卡障碍和战斗内地形混在一起。
# `result` 只读取 `barrier_changed` 标志，不依赖其它附带字段。
func _sync_dynamic_barrier_cells(
	manager,
	result: Dictionary
) -> void:
	if not bool(result.get("barrier_changed", false)):
		return
	var terrain_manager = manager._terrain_manager
	if terrain_manager == null:
		return
	manager.set_terrain_blocked_cells(terrain_manager.get_barrier_cells("dynamic"))


# 静态 barrier 只在关卡障碍新增时刷新。
# 和动态 barrier 分开维护，能避免 clear_temporary 时把静态阻挡误清。
# `result` 来源于 add_static_terrain，不混用 tick 的返回值。
func _sync_static_barrier_cells(
	manager,
	result: Dictionary
) -> void:
	if not bool(result.get("barrier_changed", false)):
		return
	var terrain_manager = manager._terrain_manager
	if terrain_manager == null:
		return
	manager.set_static_blocked_cells(terrain_manager.get_barrier_cells("static"))
