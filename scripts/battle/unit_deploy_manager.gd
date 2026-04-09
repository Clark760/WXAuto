extends Node

# 战场部署协作者
# 说明：
# 1. 只负责部署区判定、棋盘映射、敌我生成与单位回收。
# 2. Phase 2 起改为显式注入 refs + state + delegate，不再反向持有 host。
# 3. 这里不处理开战、结算、奖励、商店或任何 HUD 刷新。
# 4. 这里不决定“什么时候生成敌军”，只负责“给定数量时如何落位”。
# 5. 这里不维护视角、hover、tooltip 或底栏展开状态。
#
# 约束口径：
# 1. 己方部署区优先读 state.current_deploy_zone。
# 2. state 没写部署区时，再回退到 deploy_overlay 的导出配置。
# 3. 所有映射 key 一律走 delegate._cell_key。
# 4. 所有单位有效性一律走 delegate._is_valid_unit。
# 5. 所有映射缓存写入/清理都必须走 delegate。
# 6. 单位落位后必须同步 team、bench、combat 和动画状态。
# 7. 己方部署校验只负责区域与占格合法性，不做同名限制。
# 8. 协作者内部允许兼容旧 runtime 的下划线字段名。
# 9. 这种兼容只服务 Phase 2 迁移，不代表恢复 host 注入模式。
# 10. 新入口和旧入口都必须走 initialize(refs, state, delegate)。
# 11. 任何新的部署规则都应该先加到这里，再让 world controller 调用。
# 12. 任何新的敌军落位策略都应该先加到这里，再让 coordinator 编排。
#
# 迁移备忘：
# 1. Phase 1 以前，部署逻辑直接散落在 battlefield_runtime 与 battlefield 根脚本。
# 2. Phase 2 要先把部署规则收口，再把入口切到新场景。
# 3. 因此这个文件必须同时兼容旧 runtime 和新 world controller。
# 4. 兼容的目标是“字段名别名可读”，不是“继续允许 host 注入”。
# 5. 如果未来删除旧 battlefield_runtime，这里的兼容层可以再收窄。
# 6. 但在 Phase 2 完成前，旧入口仍要能加载，不允许因为接口改造直接损坏。
# 7. 自动部署、敌军波次、奖励落位本质上都依赖同一套部署判定。
# 8. 所以部署判定必须保持单一事实来源，不能在多个脚本里复制。
# 9. 部署映射缓存写在单位 meta 上，是为了让删除映射尽量走 O(1)。
# 10. 如果后续把映射结构换成别的容器，应该先在这里改，再外放。
# 11. 任何“额外允许某类单位越界部署”的特判，也应该先归并到这里。
# 12. 任何“敌军出生区按关卡配置变化”的规则，也应该先归并到这里。
# 13. 这里不看商店页签，不看背包，不看详情面板开关。
# 14. 这里不处理拖拽阈值，那是 drag_controller 和 world controller 的职责。
# 15. 这里不负责 hover 命中，那是 world controller 的职责。
# 16. 这里不负责 tooltip 渲染，那是 presenter 的职责。
# 17. 这里也不负责 `prepare_battle` 或 `start_battle` 编排，那是 coordinator 的职责。
# 18. 这样拆开之后，部署规则才能被测试、拖拽、自动补位、回放统一复用。
# 19. 这也是 Phase 2 要求“世界交互职责线可静态定位”的核心原因。
# 20. 如果未来还需要给部署判定加日志或断言，也应加在这里而不是根场景。

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2

var _refs = null
var _state = null
var _delegate = null
var _initialized: bool = false


# ===========================
# 装配与状态读取
# ===========================
# 绑定显式依赖，后续所有部署操作都只从这里取 refs/state/delegate。
func initialize(refs, state, delegate) -> void:
	_refs = refs
	_state = state
	_delegate = delegate
	_initialized = (
		_refs != null
		and _state != null
		and _delegate != null
		and _get_ref("hex_grid") != null
		and _get_ref("unit_factory") != null
		and _get_ref("unit_layer") != null
	)


# 兼容入口：历史测试仍传入单一 host 对象。
# 这里只做参数转发，不恢复旧 runtime 的动态调用风格。
func configure(host: Node) -> void:
	if host == null:
		return
	initialize(host, host, host)


# 暴露初始化结果，供 world controller 和烟测确认显式注入已经完成。
func is_initialized() -> bool:
	return _initialized


# ===========================
# 部署判定与落位
# ===========================
# 判定格子是否仍位于己方部署区，用于拖拽落点和自动部署筛选。
func is_ally_deploy_zone(cell: Vector2i) -> bool:
	var hex_grid = _get_ref("hex_grid")
	if hex_grid == null or not hex_grid.is_inside_grid(cell):
		return false
	var rect: Dictionary = _resolve_ally_deploy_rect()
	return (
		cell.x >= int(rect.get("x_min", 0))
		and cell.x <= int(rect.get("x_max", -1))
		and cell.y >= int(rect.get("y_min", 0))
		and cell.y <= int(rect.get("y_max", -1))
	)


# 统一校验“单位能否落到该格”，避免世界层和自动部署写出两套规则。
func can_deploy_ally_to_cell(unit: Node, cell: Vector2i) -> bool:
	var hex_grid = _get_ref("hex_grid")
	if unit == null or hex_grid == null or not hex_grid.is_inside_grid(cell):
		return false
	if not is_ally_deploy_zone(cell):
		return false

	var ally_deployed: Dictionary = _read_state("ally_deployed", {})

	var key: String = _delegate._cell_key(cell)
	if not ally_deployed.has(key):
		return true
	return ally_deployed[key] == unit


# 把己方单位正式写入棋盘映射，并同步单位节点状态和视觉表现。
func deploy_ally_unit_to_cell(unit: Node, cell: Vector2i) -> void:
	var hex_grid = _get_ref("hex_grid")
	if unit == null or hex_grid == null:
		return
	if not can_deploy_ally_to_cell(unit, cell):
		return

	var ally_deployed: Dictionary = _read_state("ally_deployed", {})
	var map_key: String = _delegate._cell_key(cell)
	ally_deployed[map_key] = unit
	_delegate._set_unit_map_cache(unit, map_key, TEAM_ALLY)
	unit.set("deployed_cell", cell)
	unit.set_team(TEAM_ALLY)
	unit.set_on_bench_state(false, -1)
	unit.set("is_in_combat", false)

	var node2d: Node2D = unit as Node2D
	if node2d != null:
		node2d.position = hex_grid.axial_to_world(cell)
	var canvas_item: CanvasItem = unit as CanvasItem
	if canvas_item != null:
		canvas_item.visible = true

	_delegate._apply_unit_visual_presentation(unit)
	unit.play_anim_state(0, {})


# 敌方单位部署和己方同口径，但不经过部署区校验。
func deploy_enemy_unit_to_cell(unit: Node, cell: Vector2i) -> void:
	var hex_grid = _get_ref("hex_grid")
	if unit == null or hex_grid == null:
		return

	var enemy_deployed: Dictionary = _read_state("enemy_deployed", {})
	var map_key: String = _delegate._cell_key(cell)
	enemy_deployed[map_key] = unit
	_delegate._set_unit_map_cache(unit, map_key, TEAM_ENEMY)
	unit.set("deployed_cell", cell)
	unit.set_team(TEAM_ENEMY)
	unit.set_on_bench_state(false, -1)
	unit.set("is_in_combat", false)

	var node2d: Node2D = unit as Node2D
	if node2d != null:
		node2d.position = hex_grid.axial_to_world(cell)
	var canvas_item: CanvasItem = unit as CanvasItem
	if canvas_item != null:
		canvas_item.visible = true

	_delegate._apply_unit_visual_presentation(unit)
	unit.play_anim_state(0, {})


# 从己方映射中移除单位，供世界拖拽把棋盘单位提起时调用。
func remove_ally_mapping(unit: Node) -> void:
	var ally_deployed: Dictionary = _read_state("ally_deployed", {})
	remove_unit_from_map(ally_deployed, unit)


# ===========================
# 波次生成与自动部署
# ===========================
# 生成一波敌军时只负责出怪和落位，不承接战斗编排与结果处理。
func spawn_enemy_wave(count: int) -> void:
	var spawn_plan: Array[Dictionary] = build_enemy_wave_plan(count)
	spawn_enemy_wave_from_plan(spawn_plan)


# 先把敌军波次规划成“格子 + unit_id”的稳定快照，供批量或分帧生成共用。
func build_enemy_wave_plan(count: int) -> Array[Dictionary]:
	clear_enemy_wave()
	var stage_spawn_plan: Array[Dictionary] = _build_stage_enemy_wave_plan()
	if not stage_spawn_plan.is_empty():
		return stage_spawn_plan

	var unit_factory = _get_ref("unit_factory")
	if unit_factory == null:
		return []

	var unit_ids: Array = unit_factory.get_unit_ids()
	var cells: Array[Vector2i] = collect_enemy_spawn_cells()
	if unit_ids.is_empty() or cells.is_empty():
		return []

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_shuffle_cells(cells, rng)
	var spawn_total: int = mini(count, cells.size())
	var spawn_plan: Array[Dictionary] = []
	for index in range(spawn_total):
		spawn_plan.append({
			"unit_id": str(unit_ids[rng.randi_range(0, unit_ids.size() - 1)]),
			"cell": cells[index]
		})
	return spawn_plan


# 按已规划好的快照落位敌军，允许 coordinator 分帧推进，避免开战前长时间卡主线程。
func spawn_enemy_wave_from_plan(
	spawn_plan: Array[Dictionary],
	start_index: int = 0,
	max_count: int = -1
) -> int:
	var unit_factory = _get_ref("unit_factory")
	var unit_layer = _get_ref("unit_layer")
	if unit_factory == null or unit_layer == null:
		return 0
	if start_index < 0 or start_index >= spawn_plan.size():
		return 0

	var end_index: int = spawn_plan.size()
	if max_count >= 0:
		end_index = mini(start_index + max_count, spawn_plan.size())

	var spawned: int = 0
	for index in range(start_index, end_index):
		var entry: Dictionary = spawn_plan[index]
		var cell_value: Variant = entry.get("cell", Vector2i(-1, -1))
		if not (cell_value is Vector2i):
			continue
		var unit_id: String = str(entry.get("unit_id", "")).strip_edges()
		if unit_id.is_empty():
			continue
		var unit_node: Node = unit_factory.acquire_unit(unit_id, unit_layer)
		if unit_node == null:
			continue
		deploy_enemy_unit_to_cell(unit_node, cell_value as Vector2i)
		spawned += 1
	return spawned


# 关卡配置存在 enemies 时，敌军生成必须严格以关卡定义为准，不能再回退到随机波次。
func _build_stage_enemy_wave_plan() -> Array[Dictionary]:
	var config_value: Variant = _read_state("current_stage_config", {})
	if not (config_value is Dictionary):
		return []
	var config: Dictionary = config_value as Dictionary
	var enemies_value: Variant = config.get("enemies", [])
	if not (enemies_value is Array):
		return []
	var enemy_rows: Array = enemies_value as Array
	if enemy_rows.is_empty():
		return []

	var hex_grid = _get_ref("hex_grid")
	if hex_grid == null:
		return []

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var available_cells: Array[Vector2i] = collect_enemy_spawn_cells()
	var plan: Array[Dictionary] = []
	var reserved: Dictionary = {}

	for enemy_value in enemy_rows:
		if not (enemy_value is Dictionary):
			continue
		var enemy_row: Dictionary = enemy_value as Dictionary
		var unit_id: String = str(enemy_row.get("unit_id", "")).strip_edges()
		if unit_id.is_empty():
			continue
		var count: int = maxi(int(enemy_row.get("count", 1)), 0)
		if count <= 0:
			continue

		var deploy_zone: String = str(enemy_row.get("deploy_zone", "random")).strip_edges().to_lower()
		var fixed_cells: Array[Vector2i] = _normalize_enemy_fixed_cells(enemy_row.get("fixed_cells", []))
		var selected_cells: Array[Vector2i] = []

		if deploy_zone == "fixed" and not fixed_cells.is_empty():
			selected_cells.append_array(
				_take_fixed_enemy_cells(fixed_cells, count, reserved, available_cells)
			)
		if selected_cells.size() < count:
			var needed: int = count - selected_cells.size()
			selected_cells.append_array(
				_take_enemy_spawn_cells_by_zone(available_cells, deploy_zone, needed, rng)
			)
			for cell in selected_cells:
				reserved[_delegate._cell_key(cell)] = true

		for cell in selected_cells:
			plan.append({
				"unit_id": unit_id,
				"cell": cell,
				"stat_scale": maxf(float(enemy_row.get("stat_scale", 1.0)), 0.01)
			})
	return plan


func _take_fixed_enemy_cells(
	fixed_cells: Array[Vector2i],
	required_count: int,
	reserved: Dictionary,
	available_cells: Array[Vector2i]
) -> Array[Vector2i]:
	var selected: Array[Vector2i] = []
	if required_count <= 0:
		return selected
	var hex_grid = _get_ref("hex_grid")
	if hex_grid == null:
		return selected

	for cell in fixed_cells:
		if selected.size() >= required_count:
			break
		if not hex_grid.is_inside_grid(cell):
			continue
		var key: String = _delegate._cell_key(cell)
		if reserved.has(key):
			continue
		reserved[key] = true
		selected.append(cell)
		var available_index: int = available_cells.find(cell)
		if available_index >= 0:
			available_cells.remove_at(available_index)
	return selected


func _take_enemy_spawn_cells_by_zone(
	available_cells: Array[Vector2i],
	deploy_zone: String,
	required_count: int,
	rng: RandomNumberGenerator
) -> Array[Vector2i]:
	var selected: Array[Vector2i] = []
	if available_cells.is_empty() or required_count <= 0:
		return selected

	var ordered_cells: Array[Vector2i] = available_cells.duplicate()
	match deploy_zone:
		"front":
			ordered_cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				if a.x == b.x:
					return a.y < b.y
				return a.x < b.x
			)
		"back":
			ordered_cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				if a.x == b.x:
					return a.y < b.y
				return a.x > b.x
			)
		"center":
			var center_x: float = _compute_enemy_spawn_center_x(ordered_cells)
			ordered_cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				var dist_a: float = absf(float(a.x) - center_x)
				var dist_b: float = absf(float(b.x) - center_x)
				if is_equal_approx(dist_a, dist_b):
					if a.y == b.y:
						return a.x < b.x
					return a.y < b.y
				return dist_a < dist_b
			)
		"random", "fixed":
			_shuffle_cells(ordered_cells, rng)
		_:
			_shuffle_cells(ordered_cells, rng)

	for cell in ordered_cells:
		if selected.size() >= required_count:
			break
		selected.append(cell)
		var available_index: int = available_cells.find(cell)
		if available_index >= 0:
			available_cells.remove_at(available_index)
	return selected


func _compute_enemy_spawn_center_x(cells: Array[Vector2i]) -> float:
	if cells.is_empty():
		return 0.0
	var min_x: int = cells[0].x
	var max_x: int = cells[0].x
	for cell in cells:
		min_x = mini(min_x, cell.x)
		max_x = maxi(max_x, cell.x)
	return float(min_x + max_x) * 0.5


func _normalize_enemy_fixed_cells(value: Variant) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if value is Array:
		for item in value:
			if item is Vector2i:
				cells.append(item)
			elif item is Array and (item as Array).size() >= 2:
				var row: Array = item as Array
				cells.append(Vector2i(int(row[0]), int(row[1])))
			elif item is Dictionary:
				var row_dict: Dictionary = item as Dictionary
				cells.append(Vector2i(int(row_dict.get("x", 0)), int(row_dict.get("y", 0))))
	return cells


func _shuffle_cells(cells: Array[Vector2i], rng: RandomNumberGenerator) -> void:
	if _delegate != null and _delegate.has_method("_shuffle_cells"):
		_delegate._shuffle_cells(cells, rng)
		return
	for index in range(cells.size() - 1, 0, -1):
		var swap_index: int = rng.randi_range(0, index)
		var tmp: Vector2i = cells[index]
		cells[index] = cells[swap_index]
		cells[swap_index] = tmp


# 清空当前敌军波次，并把单位归还给 UnitFactory。
func clear_enemy_wave() -> void:
	var unit_factory = _get_ref("unit_factory")
	var enemy_deployed: Dictionary = _read_state("enemy_deployed", {})
	for enemy in enemy_deployed.values():
		if _delegate._is_valid_unit(enemy):
			_delegate._clear_unit_map_cache(enemy)
			if unit_factory != null:
				unit_factory.release_unit(enemy)
	enemy_deployed.clear()


# 把备战席单位按顺序补到部署区，用于开战前的自动补位。
func auto_deploy_from_bench(limit: int) -> void:
	var bench_ui = _get_ref("bench_ui")
	if bench_ui == null:
		return
	var ally_deployed: Dictionary = _read_state("ally_deployed", {})
	var deploy_cells: Array[Vector2i] = collect_ally_spawn_cells()
	var deployed_count: int = 0
	for cell in deploy_cells:
		if deployed_count >= limit:
			break
		var bench_units: Array = bench_ui.get_all_units()
		if bench_units.is_empty():
			break
		if ally_deployed.has(_delegate._cell_key(cell)):
			continue

		var unit: Node = null
		for index in range(bench_units.size() - 1, -1, -1):
			var candidate: Node = bench_units[index] as Node
			if candidate == null:
				continue
			if not can_deploy_ally_to_cell(candidate, cell):
				continue
			unit = candidate
			break
		if unit == null:
			continue

		bench_ui.remove_unit(unit)
		deploy_ally_unit_to_cell(unit, cell)
		deployed_count += 1


# 返回己方部署区内全部候选格，供自动部署与奖励落位复用。
func collect_ally_spawn_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var rect: Dictionary = _resolve_ally_deploy_rect()
	var x_min: int = int(rect.get("x_min", 0))
	var x_max: int = int(rect.get("x_max", -1))
	var y_min: int = int(rect.get("y_min", 0))
	var y_max: int = int(rect.get("y_max", -1))
	for row in range(y_min, y_max + 1):
		for col in range(x_min, x_max + 1):
			cells.append(Vector2i(col, row))
	return cells


# 返回敌方出生候选格，默认是部署区之外的全部棋盘格。
func collect_enemy_spawn_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var hex_grid = _get_ref("hex_grid")
	if hex_grid == null:
		return cells

	var rect: Dictionary = _resolve_ally_deploy_rect()
	var x_min: int = int(rect.get("x_min", 0))
	var x_max: int = int(rect.get("x_max", -1))
	var y_min: int = int(rect.get("y_min", 0))
	var y_max: int = int(rect.get("y_max", -1))
	var width: int = int(hex_grid.get("grid_width"))
	var height: int = int(hex_grid.get("grid_height"))
	for row in range(height):
		for col in range(width):
			if col >= x_min and col <= x_max and row >= y_min and row <= y_max:
				continue
			cells.append(Vector2i(col, row))
	return cells


# 把映射字典转成单位数组，供上层读取当前参战或已部署单位集合。
func collect_units_from_map(map_value: Dictionary) -> Array[Node]:
	var units: Array[Node] = []
	for unit in map_value.values():
		if _delegate._is_valid_unit(unit):
			units.append(unit)
	return units


# 从部署映射删除单位时优先走缓存 key，减少整表扫描。
func remove_unit_from_map(target_map: Dictionary, unit: Node) -> void:
	if not _delegate._is_valid_unit(unit):
		return

	# 优先走 O(1) 路径：从 deployed_cell 直接还原 key。
	var cell: Vector2i = unit.get("deployed_cell")
	if cell.x > -900:
		var direct_key: String = _delegate._cell_key(cell)
		if target_map.has(direct_key) and target_map[direct_key] == unit:
			target_map.erase(direct_key)
			_delegate._clear_unit_map_cache(unit)
			return

	# deployed_cell 不可信时再退回遍历，避免脏状态导致映射残留。
	var remove_key: String = ""
	for key in target_map.keys():
		if target_map[key] == unit:
			remove_key = str(key)
			break
	if remove_key.is_empty():
		return
	target_map.erase(remove_key)
	_delegate._clear_unit_map_cache(unit)


# 这是 remove_unit_from_map 的缓存优先版本，供高频路径复用。
func remove_unit_from_map_cached(target_map: Dictionary, unit: Node) -> void:
	if not _delegate._is_valid_unit(unit):
		return
	var cached_key: String = _delegate._get_unit_map_key(unit)
	if not cached_key.is_empty() and target_map.get(cached_key, null) == unit:
		target_map.erase(cached_key)
		_delegate._clear_unit_map_cache(unit)
		return
	for key in target_map.keys():
		if target_map[key] == unit:
			target_map.erase(key)
			_delegate._clear_unit_map_cache(unit)
			return


# ===========================
# 部署区解析
# ===========================
# 优先读取 state.current_deploy_zone；没有时再回退到 overlay 上的配置。
func _resolve_ally_deploy_rect() -> Dictionary:
	var default_rect: Dictionary = _build_default_deploy_rect()
	var rect_source: Dictionary = {}
	var stage_rect_value: Variant = _read_state("current_deploy_zone", null)
	if stage_rect_value is Dictionary:
		rect_source = (stage_rect_value as Dictionary).duplicate(true)
	if rect_source.is_empty():
		var overlay = _get_ref("deploy_overlay")
		if overlay != null:
			rect_source = {
				"x_min": int(overlay.get("deploy_x_min")),
				"x_max": int(overlay.get("deploy_x_max")),
				"y_min": int(overlay.get("deploy_y_min")),
				"y_max": int(overlay.get("deploy_y_max"))
			}
	return _sanitize_deploy_rect(rect_source, default_rect)


# 当场景还没写入关卡部署区时，用半张棋盘作为默认己方部署区。
func _build_default_deploy_rect() -> Dictionary:
	var width: int = 1
	var height: int = 1
	var hex_grid = _get_ref("hex_grid")
	if hex_grid != null:
		width = maxi(int(hex_grid.get("grid_width")), 1)
		height = maxi(int(hex_grid.get("grid_height")), 1)
	var ally_width: int = maxi(width / 2, 1)
	return {
		"x_min": 0,
		"x_max": ally_width - 1,
		"y_min": 0,
		"y_max": height - 1
	}


# 对部署区配置做边界裁剪和顺序修正，避免坏数据冲破棋盘范围。
func _sanitize_deploy_rect(source: Dictionary, fallback: Dictionary) -> Dictionary:
	var width: int = 1
	var height: int = 1
	var hex_grid = _get_ref("hex_grid")
	if hex_grid != null:
		width = maxi(int(hex_grid.get("grid_width")), 1)
		height = maxi(int(hex_grid.get("grid_height")), 1)

	var x_min: int = clampi(int(source.get("x_min", int(fallback.get("x_min", 0)))), 0, width - 1)
	var x_max: int = clampi(int(source.get("x_max", int(fallback.get("x_max", width - 1)))), 0, width - 1)
	var y_min: int = clampi(int(source.get("y_min", int(fallback.get("y_min", 0)))), 0, height - 1)
	var y_max: int = clampi(int(source.get("y_max", int(fallback.get("y_max", height - 1)))), 0, height - 1)
	if x_min > x_max:
		var swap_x: int = x_min
		x_min = x_max
		x_max = swap_x
	if y_min > y_max:
		var swap_y: int = y_min
		y_min = y_max
		y_max = swap_y
	return {
		"x_min": x_min,
		"x_max": x_max,
		"y_min": y_min,
		"y_max": y_max
	}


# ===========================
# 新旧入口兼容读取
# ===========================
# 显式 refs 既支持 BattlefieldSceneRefs，也兼容旧 runtime 直接作为 refs 传入。
func _get_ref(key: String, default_value = null):
	if _refs == null:
		return default_value
	if _refs is Dictionary:
		return (_refs as Dictionary).get(key, default_value)
	var value: Variant = _refs.get(key)
	if value == null:
		return default_value
	return value


# state 读取同时兼容新字段名和旧 runtime 的下划线字段名。
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


# 用属性表判断字段是否存在，避免把不存在的旧字段直接拿来 set/get。
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
