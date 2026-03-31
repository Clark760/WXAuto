extends RefCounted
class_name CombatUnitRegistry


# 处理中途召唤或增援单位，把它接入当前战斗的缓存、占格和信号链路。
# `unit` 必须已经是有效 Node；无效节点会直接拒绝接入。
# 该入口保留旧语义：如果单位已在注册表中，就直接视为成功。
func add_unit_mid_battle(manager, unit: Node) -> bool:
	if not manager._battle_running:
		return false
	if not manager._is_live_unit(unit):
		return false
	var iid: int = unit.get_instance_id()
	if manager._unit_by_instance_id.has(iid):
		return true

	var team_id: int = int(unit.get("team_id"))
	if team_id != manager.TEAM_ALLY and team_id != manager.TEAM_ENEMY:
		team_id = manager.TEAM_ENEMY

	# 单位自身状态、组件准备和信号接线仍按旧顺序执行，避免插队时序回归。
	manager._prepare_unit_for_battle(unit, team_id)
	cache_components_for_unit(manager, unit)
	var combat: Node = manager._get_combat(unit)
	if combat == null:
		return false
	bind_combat_component_signals(manager, unit)
	manager._prepare_combat_component_for_battle(combat)
	var movement: Node = manager._get_movement(unit)
	manager._clear_movement_target(movement)

	manager._all_units.append(unit)
	manager._unit_by_instance_id[iid] = unit
	manager._dead_registry.erase(iid)
	manager._spatial_hash.update(iid, unit.position)
	manager._unit_position_cache[iid] = unit.position
	manager._alive_by_team[team_id] = int(manager._alive_by_team.get(team_id, 0)) + 1
	var alive_list: Array = manager._team_alive_cache.get(team_id, [])
	alive_list.append(unit)
	manager._team_alive_cache[team_id] = alive_list
	manager._emit_team_alive_count_changed(team_id)

	# 中途加入的单位也必须立即登记占格，否则同帧移动与寻路会读到脏状态。
	if manager._hex_grid != null:
		manager._resolve_and_register_unit_cell(unit)
	manager.unit_spawned.emit(unit, team_id)
	manager.unit_spawned_mid_battle.emit(unit, team_id)
	return true


# 逻辑帧开始前统一刷新存活缓存、空间索引和格子缓存。
# 当前 Batch 3A 继续沿用增量扫描策略，只把实现体迁出 facade。
# 这个入口是 runtime service 唯一应调用的注册刷新方法。
func pre_tick_scan(manager) -> void:
	pre_tick_scan_incremental(manager)


# 增量扫描会剔除失效单位并同步刷新所有运行时缓存。
# `valid_ids` 只记录本帧仍然存活的单位，用于后续清掉陈旧缓存项。
# `_all_units` 的原地移除仍留在这里，避免 facade 再持有数组清扫细节。
func pre_tick_scan_incremental(manager) -> void:
	manager._alive_by_team[manager.TEAM_ALLY] = 0
	manager._alive_by_team[manager.TEAM_ENEMY] = 0
	manager._team_alive_cache[manager.TEAM_ALLY] = []
	manager._team_alive_cache[manager.TEAM_ENEMY] = []
	manager._team_cells_cache[manager.TEAM_ALLY] = []
	manager._team_cells_cache[manager.TEAM_ENEMY] = []

	var valid_ids: Dictionary = {}
	var ally_seen_cells: Dictionary = {}
	var enemy_seen_cells: Dictionary = {}
	var index: int = 0
	# 这里继续沿用“原地压缩数组”的老策略，避免每帧额外分配新数组。
	while index < manager._all_units.size():
		var unit: Node = manager._all_units[index]
		if not manager._is_live_unit(unit):
			manager._all_units.remove_at(index)
			continue
		cache_components_for_unit(manager, unit)
		var combat: Node = manager._get_combat(unit)
		if combat == null or not bool(combat.get("is_alive")):
			remove_unit_runtime_entry(manager, unit)
			manager._all_units.remove_at(index)
			continue

		var iid: int = unit.get_instance_id()
		valid_ids[iid] = true
		cache_alive_unit_incremental(
			manager,
			unit,
			ally_seen_cells,
			enemy_seen_cells
		)
		index += 1

	trim_component_caches(manager, valid_ids)
	trim_runtime_caches(manager, valid_ids)
	# 高密度战斗下降低占格一致性校验频率，避免每个逻辑帧都扫一遍双向索引。
	if manager._logic_frame <= 1 or manager._logic_frame % 8 == 0:
		manager._validate_cell_occupancy()


# 把当前仍存活的单位写回队伍缓存、空间索引和唯一格子缓存。
# `ally_seen_cells/enemy_seen_cells` 只用于同队去重记录格子，不承担占格判定。
# 这里不负责敌我判定，只负责把扫描结果回写到 runtime cache。
func cache_alive_unit_incremental(
	manager,
	unit: Node,
	ally_seen_cells: Dictionary,
	enemy_seen_cells: Dictionary
) -> void:
	var iid: int = unit.get_instance_id()
	var team_id: int = int(unit.get("team_id"))
	manager._alive_by_team[team_id] = int(manager._alive_by_team.get(team_id, 0)) + 1
	manager._unit_by_instance_id[iid] = unit
	manager._spatial_hash.update(iid, unit.position)
	manager._unit_position_cache[iid] = unit.position

	var alive_list: Array = manager._team_alive_cache.get(team_id, [])
	alive_list.append(unit)
	manager._team_alive_cache[team_id] = alive_list

	var cell: Vector2i = manager._get_unit_cell(unit)
	if cell.x < 0 or cell.y < 0:
		return
	# 队伍格缓存只保留唯一格子，供群体 AI 和流场刷新复用。
	var seen_cells: Dictionary = (
		ally_seen_cells if team_id == manager.TEAM_ALLY else enemy_seen_cells
	)
	var cell_key: int = manager._cell_key_int(cell)
	if seen_cells.has(cell_key):
		return
	seen_cells[cell_key] = true
	var team_cells: Array = manager._team_cells_cache.get(team_id, [])
	team_cells.append(cell)
	manager._team_cells_cache[team_id] = team_cells


# 清掉已经不存在于 valid_ids 中的组件缓存，避免字典持续膨胀。
# 这里只处理组件缓存，不处理单位级运行时索引。
# 组件缓存和单位索引分开清理，避免把两个职责重新搅回同一函数。
func trim_component_caches(manager, valid_ids: Dictionary) -> void:
	for key in manager._combat_cache.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			manager._combat_cache.erase(iid)
	for key in manager._movement_cache.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			manager._movement_cache.erase(iid)
	for key in manager._target_memory.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			manager._target_memory.erase(iid)
	for key in manager._target_refresh_frame.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			manager._target_refresh_frame.erase(iid)
	for key in manager._attack_range_target_memory.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			manager._attack_range_target_memory.erase(iid)
	for key in manager._attack_range_target_frame.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			manager._attack_range_target_frame.erase(iid)
	for key in manager._move_replan_cooldown_frame.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			manager._move_replan_cooldown_frame.erase(iid)
	for key in manager._side_step_cooldown_frame.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			manager._side_step_cooldown_frame.erase(iid)
	for key in manager._last_move_from_cell.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			manager._last_move_from_cell.erase(iid)


# 清掉已经失效的单位级运行时缓存，包括占格、空间索引和位置缓存。
# `valid_ids` 来自本帧扫描结果，不额外反查单位列表。
# 这一层是“索引删除”，不是“单位死亡判定”；死亡判定仍在战斗链路里。
func trim_runtime_caches(manager, valid_ids: Dictionary) -> void:
	for key in manager._unit_by_instance_id.keys():
		var iid: int = int(key)
		if valid_ids.has(iid):
			continue
		remove_runtime_entry_by_id(manager, iid)


# 从运行时索引中移除一个单位，并同步断开 combat component 信号。
# `unit` 无效时直接忽略，避免在清理路径上再次抛异常。
# 对 `_all_units` 主数组的移除由调用方处理，避免这里隐式改迭代状态。
func remove_unit_runtime_entry(manager, unit: Node) -> void:
	if not manager._is_live_unit(unit):
		return
	unbind_combat_component_signals(manager, unit)
	remove_runtime_entry_by_id(manager, unit.get_instance_id())


# 按 instance_id 清理所有与该单位相关的索引和缓存。
# 这里不修改 `_all_units` 主数组，数组移除由上层扫描或调用方控制。
# 占格表与 `_unit_cell` 必须一起清掉，否则后续 pathfinding 会读到幽灵单位。
func remove_runtime_entry_by_id(manager, iid: int) -> void:
	if manager._unit_cell.has(iid):
		var cell: Vector2i = manager._unit_cell[iid]
		var cell_key: int = manager._cell_key_int(cell)
		if (
			manager._cell_occupancy.has(cell_key)
			and int(manager._cell_occupancy[cell_key]) == iid
		):
			manager._cell_occupancy.erase(cell_key)
		manager._unit_cell.erase(iid)
	manager._unit_by_instance_id.erase(iid)
	manager._spatial_hash.remove(iid)
	manager._unit_position_cache.erase(iid)
	manager._combat_cache.erase(iid)
	manager._movement_cache.erase(iid)
	manager._target_memory.erase(iid)
	manager._target_refresh_frame.erase(iid)
	manager._attack_range_target_memory.erase(iid)
	manager._attack_range_target_frame.erase(iid)
	manager._follow_anchor_by_unit_id.erase(iid)
	manager._move_replan_cooldown_frame.erase(iid)
	manager._side_step_cooldown_frame.erase(iid)
	manager._last_move_from_cell.erase(iid)


# 开战时批量注册同一队伍单位，并完成进入战斗前的组件准备。
# 单位格子吸附与占格登记也在这里一次性完成，避免之后逻辑帧再补。
# Batch 3A 只迁移“注册编排”，不改外层 `start_battle` 的对外方法名。
func register_units(
	manager,
	units: Array[Node],
	team_id: int
) -> void:
	for unit in units:
		if not manager._is_live_unit(unit):
			continue

		manager._prepare_unit_for_battle(unit, team_id)
		cache_components_for_unit(manager, unit)
		var combat: Node = manager._get_combat(unit)
		if combat != null:
			bind_combat_component_signals(manager, unit)
			manager._prepare_combat_component_for_battle(combat)
		var movement: Node = manager._get_movement(unit)
		manager._clear_movement_target(movement)

		var instance_id: int = unit.get_instance_id()
		manager._all_units.append(unit)
		manager._unit_by_instance_id[instance_id] = unit

		# 注册阶段就落格，能减少首帧出现“单位无格坐标”的边界态。
		if manager._hex_grid != null:
			manager._resolve_and_register_unit_cell(unit)


# 组件缓存只做“取一次、复用多次”的热路径优化。
# 如果缓存项不存在，就从单位节点树里重新抓取对应组件。
# 这里不校验组件语义，只负责把引用存到 cache 字典。
func cache_components_for_unit(manager, unit: Node) -> void:
	if not manager._is_live_unit(unit):
		return
	var iid: int = unit.get_instance_id()
	if not manager._combat_cache.has(iid):
		manager._combat_cache[iid] = unit.get_node_or_null("Components/UnitCombat")
	if not manager._movement_cache.has(iid):
		manager._movement_cache[iid] = unit.get_node_or_null("Components/UnitMovement")


# 统一连接 Combat 组件的重要运行时信号，避免 facade 到处散落 connect。
# Batch 3B 后，组件事件统一先进入 `combat_event_bridge`，再转成 manager signal。
# 服务层只负责连接编排，不重新定义 signal 事件语义。
func bind_combat_component_signals(manager, unit: Node) -> void:
	if not manager._is_live_unit(unit):
		return
	var combat: Node = manager._get_combat(unit)
	if combat == null:
		return
	var bridge = manager._event_bridge_service
	if bridge == null:
		return
	var cb_dead: Callable = Callable(bridge, "on_combat_component_died").bind(manager)
	var cb_damaged: Callable = Callable(bridge, "on_combat_component_damaged").bind(manager)
	var cb_heal: Callable = Callable(bridge, "on_combat_component_healing_performed").bind(manager)
	var cb_thorns: Callable = Callable(bridge, "on_combat_component_thorns_damage_dealt").bind(manager)
	if combat.has_signal("died") and not combat.is_connected("died", cb_dead):
		combat.connect("died", cb_dead)
	if combat.has_signal("damaged") and not combat.is_connected("damaged", cb_damaged):
		combat.connect("damaged", cb_damaged)
	if combat.has_signal("healing_performed") and not combat.is_connected("healing_performed", cb_heal):
		combat.connect("healing_performed", cb_heal)
	if combat.has_signal("thorns_damage_dealt") and not combat.is_connected("thorns_damage_dealt", cb_thorns):
		combat.connect("thorns_damage_dealt", cb_thorns)


# 移除 Combat 组件信号连接，避免单位死亡或退场后残留回调。
# disconnect 前先检查连接状态，防止清理路径再次报错。
# 与 connect 对称保留在同一服务，便于桥接策略继续集中维护。
func unbind_combat_component_signals(manager, unit: Node) -> void:
	if not manager._is_live_unit(unit):
		return
	var combat: Node = manager._get_combat(unit)
	if combat == null:
		return
	var bridge = manager._event_bridge_service
	if bridge == null:
		return
	var cb_dead: Callable = Callable(bridge, "on_combat_component_died").bind(manager)
	var cb_damaged: Callable = Callable(bridge, "on_combat_component_damaged").bind(manager)
	var cb_heal: Callable = Callable(bridge, "on_combat_component_healing_performed").bind(manager)
	var cb_thorns: Callable = Callable(bridge, "on_combat_component_thorns_damage_dealt").bind(manager)
	if combat.has_signal("died") and combat.is_connected("died", cb_dead):
		combat.disconnect("died", cb_dead)
	if combat.has_signal("damaged") and combat.is_connected("damaged", cb_damaged):
		combat.disconnect("damaged", cb_damaged)
	if combat.has_signal("healing_performed") and combat.is_connected("healing_performed", cb_heal):
		combat.disconnect("healing_performed", cb_heal)
	if combat.has_signal("thorns_damage_dealt") and combat.is_connected("thorns_damage_dealt", cb_thorns):
		combat.disconnect("thorns_damage_dealt", cb_thorns)


# 旧的整帧全量缓存重建逻辑暂时保留为 service 能力，供过渡期 helper 复用。
# Batch 3A 主链使用增量扫描，但这里仍保留同口径实现以防测试或调试路径调用。
# 保留它是为了过渡，而不是鼓励新代码再回退到全量扫描模式。
func reset_tick_caches(manager) -> void:
	manager._alive_by_team[manager.TEAM_ALLY] = 0
	manager._alive_by_team[manager.TEAM_ENEMY] = 0
	manager._unit_by_instance_id.clear()
	manager._spatial_hash.clear()
	manager._team_alive_cache[manager.TEAM_ALLY] = []
	manager._team_alive_cache[manager.TEAM_ENEMY] = []
	manager._team_cells_cache[manager.TEAM_ALLY] = []
	manager._team_cells_cache[manager.TEAM_ENEMY] = []


# 把存活单位写入全量缓存模式使用的空间索引和队伍格缓存。
# `ally_seen_cells/enemy_seen_cells` 仍然只负责同队格子去重。
# 这条老路径仍保持与旧逻辑一致，便于对照增量扫描结果。
func cache_alive_unit(
	manager,
	unit: Node,
	ally_seen_cells: Dictionary,
	enemy_seen_cells: Dictionary
) -> void:
	var combat: Node = manager._get_combat(unit)
	if combat == null:
		return
	if not bool(combat.get("is_alive")):
		return

	var iid: int = unit.get_instance_id()
	var team_id: int = int(unit.get("team_id"))
	manager._alive_by_team[team_id] = int(manager._alive_by_team.get(team_id, 0)) + 1
	manager._unit_by_instance_id[iid] = unit
	manager._spatial_hash.insert(iid, unit.position)

	var alive_list: Array = manager._team_alive_cache.get(team_id, [])
	alive_list.append(unit)
	manager._team_alive_cache[team_id] = alive_list

	if manager._hex_grid == null:
		return
	var cell: Vector2i = manager._hex_world_to_axial(unit.position)
	# 这里继续走 manager helper，避免新服务重新长出 HexGrid 动态调用。
	var seen_cells: Dictionary = (
		ally_seen_cells if team_id == manager.TEAM_ALLY else enemy_seen_cells
	)
	var cache_key: int = (
		manager.TEAM_ALLY if team_id == manager.TEAM_ALLY else manager.TEAM_ENEMY
	)
	var cell_key: int = manager._cell_key_int(cell)
	if seen_cells.has(cell_key):
		return
	seen_cells[cell_key] = true
	var team_cells: Array = manager._team_cells_cache.get(cache_key, [])
	team_cells.append(cell)
	manager._team_cells_cache[cache_key] = team_cells


# 开战前统一设置队伍、战斗态和待机动画。
# 这里不做组件准备和占格登记，职责只限于单位自身状态切换。
# 真实的动态方法调用留在 manager helper，service 只保留调用顺序。
func prepare_unit_for_battle(
	manager,
	unit: Node,
	team_id: int
) -> void:
	manager._prepare_unit_for_battle(unit, team_id)
