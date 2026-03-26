extends RefCounted
class_name CombatRuntimeService


# 承接 Combat 的主循环、开战/停战与战报汇总。
# `manager` 是 facade，本服务只消费它已经公开的运行时状态和 helper。
# `_process` 的 Godot 入口仍保留在 manager，这里只承接真实逻辑。
func process(manager: CombatManager, delta: float) -> void:
	if not manager._battle_running:
		return

	manager._logic_accumulator += delta
	var substeps: int = 0
	# 固定步长循环仍沿用原语义，只是实现体迁到了 runtime service。
	while (
		manager._logic_accumulator >= manager._logic_step
		and substeps < manager.logic_max_substeps
	):
		logic_tick(manager, manager._logic_step)
		manager._logic_accumulator -= manager._logic_step
		substeps += 1

	# 防止极端卡顿时逻辑帧无限积压，超过上限后直接丢弃剩余累计量。
	if (
		substeps >= manager.logic_max_substeps
		and manager._logic_accumulator >= manager._logic_step
	):
		manager._logic_accumulator = 0.0


# 开战入口负责重置运行时状态、注册双方单位并启动逻辑循环。
# `battle_seed` 小于等于 0 时会在服务内部改写为稳定随机种子。
# 这里不改外部 API，只把串行编排从 facade 中搬走。
func start_battle(
	manager: CombatManager,
	ally_units: Array[Node],
	enemy_units: Array[Node],
	battle_seed: int = 0
) -> bool:
	stop_battle(manager, "restart", 0)
	reset_battle_runtime_state(manager)
	manager._register_units(ally_units, manager.TEAM_ALLY)
	manager._register_units(enemy_units, manager.TEAM_ENEMY)
	# 没有任何有效单位时，直接拒绝进入战斗循环。
	if manager._all_units.is_empty():
		return false

	setup_battle_seed(manager, battle_seed)
	begin_battle_loop(manager)
	manager._pre_tick_scan()
	manager._emit_team_alive_count_changed(manager.TEAM_ALLY)
	manager._emit_team_alive_count_changed(manager.TEAM_ENEMY)
	manager.battle_started.emit(
		int(manager._alive_by_team.get(manager.TEAM_ALLY, 0)),
		int(manager._alive_by_team.get(manager.TEAM_ENEMY, 0))
	)
	return true


# 停战时统一收口单位清理、临时地形清空和战报发射。
# `winner_team` 只影响总结与结算动画，不在这里反推胜负。
# 这条路径同时服务手动停止、重开战斗和歼灭结算。
func stop_battle(
	manager: CombatManager,
	reason: String = "manual",
	winner_team: int = 0
) -> void:
	if not manager._battle_running:
		return

	manager._battle_running = false
	var summary: Dictionary = build_battle_summary(manager, reason, winner_team)

	# 逐个清理单位，保持旧版 stop_battle 的资源释放与动画时序。
	for unit in manager._all_units:
		if not manager._is_live_unit(unit):
			continue
		cleanup_unit_after_battle(manager, unit, winner_team)
	if manager._terrain_manager != null:
		manager.clear_temporary_terrains()

	manager.battle_ended.emit(winner_team, summary)
	manager.battle_ended_detail.emit(winner_team, summary.duplicate(true))


# 单个逻辑步负责驱动预扫描、地形 tick、流场刷新与单位行为执行。
# 攻击/移动的具体规则仍由 facade 现有 helper 继续承接，后续 Batch 3B 再迁出。
# 本轮只先拆掉“主循环编排”，不在这里混入移动和攻击规则重写。
func logic_tick(manager: CombatManager, delta: float) -> void:
	var tick_begin_us: int = Time.get_ticks_usec()
	manager._metrics.reset_tick_metrics(manager)
	manager._logic_frame += 1
	manager._logic_time += delta
	var allow_attack_phase: bool = true
	var allow_move_phase: bool = true
	if manager.split_attack_move_phase:
		allow_attack_phase = manager._next_attack_phase
		allow_move_phase = not manager._next_attack_phase
		manager._next_attack_phase = not manager._next_attack_phase

	# 预扫描必须先跑，后续地形和单位逻辑都依赖这批缓存。
	manager._pre_tick_scan()
	if manager._all_units.is_empty():
		manager._tick_terrain(delta)
		finalize_if_needed(manager)
		manager._metrics.finalize_tick(
			manager,
			tick_begin_us,
			allow_attack_phase,
			allow_move_phase
		)
		return

	manager._tick_terrain(delta)
	manager._update_group_ai_focus()
	var refresh_interval: int = manager._get_effective_flow_refresh_interval()
	# 流场仍按旧策略定期刷新，只是调度责任移到 runtime service。
	if (
		manager._flow_force_rebuild
		or refresh_interval <= 1
		or (manager._logic_frame % refresh_interval == 0)
	):
		manager._rebuild_flow_fields()
		manager._flow_force_rebuild = false

	if manager.shuffle_unit_order_each_tick and manager._all_units.size() > 1:
		manager._all_units.shuffle()

	# 单位行为执行仍委托回 facade 现有 helper，避免本轮一次性改太宽。
	for unit in manager._all_units:
		if not manager._battle_running:
			break
		manager._run_unit_logic(
			unit,
			delta,
			allow_attack_phase,
			allow_move_phase
		)

	finalize_if_needed(manager)
	manager._metrics.finalize_tick(
		manager,
		tick_begin_us,
		allow_attack_phase,
		allow_move_phase
	)


# 双方存活数只要有一侧归零，就立即走 stop_battle。
# 这里是战斗循环内的统一终止点，避免多处各自判定胜负。
# 胜负判定口径保持旧逻辑，不在服务层额外引入平局新语义。
func finalize_if_needed(manager: CombatManager) -> void:
	var ally_alive: int = int(manager._alive_by_team.get(manager.TEAM_ALLY, 0))
	var enemy_alive: int = int(manager._alive_by_team.get(manager.TEAM_ENEMY, 0))
	if ally_alive > 0 and enemy_alive > 0:
		return

	var winner: int = 0
	if ally_alive > enemy_alive:
		winner = manager.TEAM_ALLY
	elif enemy_alive > ally_alive:
		winner = manager.TEAM_ENEMY
	stop_battle(manager, "annihilation", winner)


# 战斗种子统一在这里设定，保证 start_battle 不直接操作随机源细节。
# `battle_seed<=0` 时使用当前时间兜底，保持外部 API 不变。
# 随机源仍复用 manager 持有的 `_rng`，不单独再建第二套状态。
func setup_battle_seed(manager: CombatManager, battle_seed: int) -> void:
	var actual_seed: int = battle_seed
	if actual_seed <= 0:
		actual_seed = int(Time.get_ticks_usec() % 2147483647)
	manager._rng.seed = actual_seed


# 初始化逻辑帧步长、累计器和轮换攻击相位。
# 这里只改运行时状态，不负责注册单位或广播信号。
# 这样 Batch 3A 后，manager 就不再持有完整的“开战状态机”实现体。
func begin_battle_loop(manager: CombatManager) -> void:
	manager._logic_step = 1.0 / maxf(manager.logic_fps, 1.0)
	manager._logic_accumulator = 0.0
	manager._logic_frame = 0
	manager._logic_time = 0.0
	manager._next_attack_phase = true
	manager._flow_force_rebuild = true
	manager._battle_running = true


# 战报总结只暴露稳定字段，供 UI 和测试做契约断言。
# `reason` 与 `winner_team` 由外部调用方传入，不在这里推导业务原因。
# summary 字段集合必须保持兼容，不能在服务拆分时偷偷改口径。
func build_battle_summary(
	manager: CombatManager,
	reason: String,
	winner_team: int
) -> Dictionary:
	return {
		"winner_team": winner_team,
		"reason": reason,
		"logic_frames": manager._logic_frame,
		"logic_time": manager._logic_time,
		"ally_alive": int(manager._alive_by_team.get(manager.TEAM_ALLY, 0)),
		"enemy_alive": int(manager._alive_by_team.get(manager.TEAM_ENEMY, 0))
	}


# 停战清理统一收口在这里，保证移动、动画和占格回吸附时序一致。
# `winner_team` 只决定胜利动画归属，不改变单位存活状态。
# 视觉节点和动态交互暂时留在 manager helper，避免新服务重新长出动态调用。
func cleanup_unit_after_battle(
	manager: CombatManager,
	unit: Node,
	winner_team: int
) -> void:
	# 这层只做流程编排；真正的兼容调用继续收口在 facade。
	manager._cleanup_unit_after_battle(unit, winner_team)


# 整场战斗开始前统一清空缓存、计数器、占格和临时地形。
# 该函数只用于整局重置，不能拿来做逻辑帧内的增量清理。
# 这里和 `pre_tick_scan` 的职责不同，前者是整局 reset，后者是逐帧刷新。
func reset_battle_runtime_state(manager: CombatManager) -> void:
	manager._all_units.clear()
	manager._unit_by_instance_id.clear()
	manager._dead_registry.clear()
	manager._unit_position_cache.clear()
	manager._combat_cache.clear()
	manager._movement_cache.clear()
	manager._group_focus_target_id.clear()
	manager._group_center.clear()
	manager._spatial_hash.clear()
	manager._alive_by_team[manager.TEAM_ALLY] = 0
	manager._alive_by_team[manager.TEAM_ENEMY] = 0
	manager._team_alive_cache[manager.TEAM_ALLY] = []
	manager._team_alive_cache[manager.TEAM_ENEMY] = []
	manager._team_cells_cache[manager.TEAM_ALLY] = []
	manager._team_cells_cache[manager.TEAM_ENEMY] = []
	manager._cell_occupancy.clear()
	manager._unit_cell.clear()
	manager._terrain_blocked_cells.clear()
	manager._last_terrain_cells.clear()
	manager._flow_force_rebuild = true
	# 临时地形在整局重开时必须一起清空，否则旧场景残留会污染新战斗。
	if manager._terrain_manager != null:
		manager.clear_temporary_terrains()
	manager._metrics.reset_all_metrics(manager)
