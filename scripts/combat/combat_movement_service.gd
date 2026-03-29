extends RefCounted
class_name CombatMovementService

const PROBE_SCOPE_COMBAT_COMPONENT_TICK: String = "combat_component_tick"
const PROBE_SCOPE_COMBAT_TARGET_PICK: String = "combat_target_pick"
const PROBE_SCOPE_COMBAT_ATTACK_EXECUTE: String = "combat_attack_execute"
const PROBE_SCOPE_COMBAT_MOVE_PHASE: String = "combat_move_phase"


# 承接 Combat 的位移、恐惧移动与单位逻辑编排。
# 这里保留旧规则口径，但把长段实现体从 facade 中移出。
# 攻击尝试会通过 manager 持有的 attack service 调用，不在 facade 内回绕。
func force_move_unit_to_cell(
	manager,
	unit: Node,
	target_cell: Vector2i
) -> bool:
	# 强制位移也必须遵守“战斗中、单位存活、目标格有效”三条底线。
	# 这能避免效果系统把单位推到战斗外或已死亡单位继续占格。
	if not manager._battle_running:
		return false
	if not manager._is_live_unit(unit) or not manager._is_unit_alive(unit):
		return false

	var hex_grid: Node = manager._hex_grid
	if hex_grid == null or not is_instance_valid(hex_grid):
		return false
	var hex_grid_api: Variant = hex_grid
	if not bool(hex_grid_api.is_inside_grid(target_cell)):
		return false

	var current_cell: Vector2i = manager._get_unit_cell(unit)
	if current_cell == target_cell:
		return true
	if not manager._is_cell_free(target_cell):
		return false

	# 强制位移仍沿用“先占新格，再更新显示”的旧约束。
	# 这样能保证同帧内后续查询读到的是已经提交后的逻辑格。
	if not manager._occupy_cell(target_cell, unit):
		return false

	var movement: Node = manager._get_movement(unit)
	_clear_movement_target(movement)
	var unit_node: Node2D = unit as Node2D
	if unit_node != null:
		unit_node.position = hex_grid_api.axial_to_world(target_cell)
	manager._flow_force_rebuild = true
	return true


# 向目标格逼近的语义保持原样：每次只取一步最优邻格，直到步数耗尽或被阻断。
# `anchor_cell` 通常来自技能或目标单位的格坐标。
# 返回值只表达“是否至少成功移动过一步”，不返回最终位置信息。
func move_unit_steps_towards(
	manager,
	unit: Node,
	anchor_cell: Vector2i,
	max_steps: int
) -> bool:
	if not manager._battle_running or max_steps <= 0:
		return false
	var current: Vector2i = manager._get_unit_cell(unit)
	if current.x < 0:
		return false

	var moved: bool = false
	var remaining_steps: int = maxi(max_steps, 0)
	# 每一步都重新读取当前位置，确保连续 pull 时不会跳过阻挡检查。
	while remaining_steps > 0:
		remaining_steps -= 1
		var next_cell: Vector2i = _pick_step_towards(manager, current, anchor_cell)
		if next_cell == current:
			break
		if not force_move_unit_to_cell(manager, unit, next_cell):
			break
		current = next_cell
		moved = true
	return moved


# 远离威胁格的逻辑与 pull 共用同一套“逐步尝试”框架。
# 唯一区别是每一步的候选格比较方向相反。
# 该入口被恐惧和击退类效果复用，因此不把理由写死在这里。
func move_unit_steps_away(
	manager,
	unit: Node,
	threat_cell: Vector2i,
	max_steps: int
) -> bool:
	if not manager._battle_running or max_steps <= 0:
		return false
	var current: Vector2i = manager._get_unit_cell(unit)
	if current.x < 0:
		return false

	var moved: bool = false
	var remaining_steps: int = maxi(max_steps, 0)
	# away 与 towards 共用同一套逐步提交框架，区别只在选下一格的策略。
	while remaining_steps > 0:
		remaining_steps -= 1
		var next_cell: Vector2i = _pick_step_away(manager, current, threat_cell)
		if next_cell == current:
			break
		if not force_move_unit_to_cell(manager, unit, next_cell):
			break
		current = next_cell
		moved = true
	return moved


# 交换格子用于瞬时换位效果，必须同时更新占格表与显示位置。
# 这里不走 `_occupy_cell`，因为两格互换时需要原子性替换。
# 成功后仍会发出两条 cell_changed 和两条 move_success，与旧行为一致。
func swap_unit_cells(
	manager,
	unit_a: Node,
	unit_b: Node
) -> bool:
	if not manager._battle_running:
		return false
	if not manager._is_live_unit(unit_a) or not manager._is_live_unit(unit_b):
		return false
	if not manager._is_unit_alive(unit_a) or not manager._is_unit_alive(unit_b):
		return false

	var cell_a: Vector2i = manager._get_unit_cell(unit_a)
	var cell_b: Vector2i = manager._get_unit_cell(unit_b)
	if cell_a.x < 0 or cell_b.x < 0:
		return false
	if manager._is_cell_blocked(cell_a) or manager._is_cell_blocked(cell_b):
		return false

	var id_a: int = unit_a.get_instance_id()
	var id_b: int = unit_b.get_instance_id()
	var key_a: int = manager._cell_key_int(cell_a)
	var key_b: int = manager._cell_key_int(cell_b)

	# 换位是原子提交：两格的 occupancy 和 unit_cell 必须一起改。
	# 这里故意不拆成两次 occupy，避免中途被其它单位插入。
	manager._cell_occupancy[key_a] = id_b
	manager._cell_occupancy[key_b] = id_a
	manager._unit_cell[id_a] = cell_b
	manager._unit_cell[id_b] = cell_a

	var hex_grid: Node = manager._hex_grid
	if hex_grid != null and is_instance_valid(hex_grid):
		var hex_grid_api: Variant = hex_grid
		var node_a: Node2D = unit_a as Node2D
		var node_b: Node2D = unit_b as Node2D
		if node_a != null:
			node_a.position = hex_grid_api.axial_to_world(cell_b)
		if node_b != null:
			node_b.position = hex_grid_api.axial_to_world(cell_a)

	_clear_movement_target(manager._get_movement(unit_a))
	_clear_movement_target(manager._get_movement(unit_b))
	manager._flow_force_rebuild = true
	manager._notify_unit_cell_changed(unit_a, cell_a, cell_b)
	manager._notify_unit_cell_changed(unit_b, cell_b, cell_a)
	return true


# `_run_unit_logic` 是 Combat 每帧对单个单位的主行为入口。
# 它仍保留“攻击优先，移动其次”的旧顺序，只是实现体迁出 facade。
# `allow_attack/allow_move` 继续服务 split_attack_move_phase，不改外层调度。
func run_unit_logic(
	manager,
	unit: Node,
	delta: float,
	allow_attack: bool = true,
	allow_move: bool = true
) -> void:
	if not manager._battle_running:
		return
	if not manager._is_live_unit(unit):
		return
	if not manager._is_unit_alive(unit):
		return

	manager._metric_tick_units += 1
	manager._metric_total_units += 1

	var combat: Node = manager._get_combat(unit)
	if combat == null:
		return
	var combat_tick_begin_us: int = _probe_begin_timing(manager)
	_tick_combat_logic(combat, delta)
	_probe_commit_timing(manager, PROBE_SCOPE_COMBAT_COMPONENT_TICK, combat_tick_begin_us)

	# 控制态优先于普攻和移动，这样 stun/fear 不会被后续逻辑冲掉。
	if _is_unit_stunned(manager, unit):
		_clear_unit_move_and_idle(unit, manager._get_movement(unit))
		emit_unit_move_failed(manager, unit, "stunned", {})
		return

	var self_team: int = int(unit.get("team_id"))
	var enemy_team: int = manager.TEAM_ENEMY if self_team == manager.TEAM_ALLY else manager.TEAM_ALLY
	var feared: bool = _is_unit_feared(manager, unit)
	var can_attempt_attack: bool = true
	if allow_attack and combat.has_method("can_attack"):
		var combat_api: Variant = combat
		can_attempt_attack = bool(combat_api.can_attack())
	if allow_move and not allow_attack and _should_skip_move_replan(manager, unit):
		_clear_unit_move_and_idle(unit, manager._get_movement(unit))
		return
	var target: Node = null
	var should_pick_full_target: bool = feared or can_attempt_attack or (allow_attack and allow_move)
	if should_pick_full_target:
		var target_pick_begin_us: int = _probe_begin_timing(manager)
		target = manager._pick_target_for_unit(unit, allow_attack)
		_probe_commit_timing(manager, PROBE_SCOPE_COMBAT_TARGET_PICK, target_pick_begin_us)

	# fear 会覆盖普通寻路，但仍允许它复用同一套移动统计口径。
	if feared:
		_run_feared_unit_logic(manager, unit, target, enemy_team)
		return

	# 攻击相位先走，只有真的没打出去时才会下沉到移动相位。
	if allow_attack:
		manager._metric_tick_attack_checks += 1
		manager._metric_total_attack_checks += 1
		if not can_attempt_attack:
			manager.attack_failed.emit(
				unit,
				null,
				"cooldown",
				{"performed": false, "reason": "cooldown"}
			)
			if not allow_move:
				return
		var attack_begin_us: int = _probe_begin_timing(manager)
		if can_attempt_attack and manager._attack_service.try_execute_attack(manager, unit, combat, target):
			_probe_commit_timing(manager, PROBE_SCOPE_COMBAT_ATTACK_EXECUTE, attack_begin_us)
			manager._metric_tick_attacks_performed += 1
			manager._metric_total_attacks_performed += 1
			return
		_probe_commit_timing(manager, PROBE_SCOPE_COMBAT_ATTACK_EXECUTE, attack_begin_us)

	if not allow_move:
		return

	var attack_range_target: Node = _resolve_attack_range_target_for_move(
		manager,
		unit,
		target,
		enemy_team
	)

	# 目标已经在射程内时直接停步，避免“冷却中也来回抖动”的旧问题回流。
	if _should_hold_position_in_attack_range(manager, unit, attack_range_target):
		return
	var move_phase_begin_us: int = _probe_begin_timing(manager)
	_run_move_phase(
		manager,
		unit,
		combat,
		target,
		attack_range_target,
		allow_attack
	)
	_probe_commit_timing(manager, PROBE_SCOPE_COMBAT_MOVE_PHASE, move_phase_begin_us)


# 从 manager 挂载的 runtime probe 取一次可选计时起点。
func _probe_begin_timing(manager) -> int:
	if manager == null or manager._runtime_probe == null:
		return 0
	if not manager._runtime_probe.has_method("begin_timing"):
		return 0
	return int(manager._runtime_probe.begin_timing())


# 把 movement/attack/targeting 子段耗时写回统一探针。
func _probe_commit_timing(manager, scope_name: String, begin_us: int) -> void:
	if manager == null or manager._runtime_probe == null:
		return
	if not manager._runtime_probe.has_method("commit_timing"):
		return
	manager._runtime_probe.commit_timing(scope_name, begin_us)


# stun/fear 都走同一套 meta 时间窗逻辑，只是键名不同。
# 状态结束时会把 meta 清理掉，避免单位长期残留无效控制标记。
# `meta_key` 由调用方传入，便于后续扩展其它控制态而不复制逻辑。
func _is_control_active(
	manager,
	unit: Node,
	meta_key: String
) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var until_time: float = float(unit.get_meta(meta_key, 0.0))
	if until_time > manager._logic_time:
		return true
	if until_time > 0.0:
		unit.remove_meta(meta_key)
	return false


# stunned 与 feared 保持拆开的语义 helper，便于阅读行为分支。
# 两者底层都只是对 `_is_control_active` 的薄封装。
# 这里不引入 enum，避免把现有 meta 约定再包一层。
func _is_unit_stunned(manager, unit: Node) -> bool:
	return _is_control_active(manager, unit, "status_stun_until")


# fear 与 stun 一样走时间窗判断，但语义不同，所以保留独立 helper。
# 调试移动问题时，单独入口比把 key 写死在调用点更容易排查。
# 这个函数本身很薄，但它是阅读恐惧分支时的重要语义锚点。
func _is_unit_feared(manager, unit: Node) -> bool:
	return _is_control_active(manager, unit, "status_fear_until")


# 统一清理移动目标并切到待机动画，避免每个失败分支重复写样板。
# `movement` 允许调用方提前传入，减少热路径重复取组件。
# 若单位或组件无效则静默跳过，保持旧容错行为。
func _clear_unit_move_and_idle(unit: Node, movement: Node = null) -> void:
	_clear_movement_target(movement)
	if unit == null or not is_instance_valid(unit):
		return
	var unit_api: Variant = unit
	unit_api.play_anim_state(0, {})


func _should_skip_move_replan(manager, unit: Node) -> bool:
	if manager == null or unit == null or not is_instance_valid(unit):
		return false
	var cooldown_frames: int = int(manager._get_effective_move_replan_cooldown_frames())
	if cooldown_frames <= 0:
		return false
	var unit_id: int = unit.get_instance_id()
	if not manager._move_replan_cooldown_frame.has(unit_id):
		return false
	return int(manager._move_replan_cooldown_frame.get(unit_id, -1)) >= manager._logic_frame


func _mark_move_replan_cooldown(manager, unit: Node) -> void:
	if manager == null or unit == null or not is_instance_valid(unit):
		return
	var cooldown_frames: int = int(manager._get_effective_move_replan_cooldown_frames())
	if cooldown_frames <= 0:
		return
	manager._move_replan_cooldown_frame[unit.get_instance_id()] = manager._logic_frame + cooldown_frames


func _clear_move_replan_cooldown(manager, unit: Node) -> void:
	if manager == null or unit == null or not is_instance_valid(unit):
		return
	manager._move_replan_cooldown_frame.erase(unit.get_instance_id())


# 对外的 move_failed 事件需要把 `unit` 与 `reason` 回写到 payload 中。
# 当前 context 只承载扁平字段与节点引用，浅拷贝即可隔离监听者改写。
# 所有移动失败分支都必须走这条统一出口。
func emit_unit_move_failed(
	manager,
	unit: Node,
	reason: String,
	context: Dictionary
) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var payload: Dictionary = context.duplicate(false)
	payload["unit"] = unit
	payload["reason"] = reason
	manager.unit_move_failed.emit(unit, reason, payload)


# 恐惧移动的优先级高于普通寻路，但低于基础有效性检查。
# 若当前目标失效，会按旧逻辑尝试回退到射程内目标，再退到普通选敌。
# 成功移动和失败阻挡的指标统计与旧实现保持一致。
func _run_feared_unit_logic(
	manager,
	unit: Node,
	target: Node,
	enemy_team: int
) -> void:
	var current_cell: Vector2i = manager._get_unit_cell(unit)
	if current_cell.x < 0:
		_clear_unit_move_and_idle(unit, manager._get_movement(unit))
		return

	var resolved_target: Node = target
	# 恐惧态优先远离“当前已知的最近威胁”，找不到才退回普通选敌。
	if (
		resolved_target == null
		or not manager._is_live_unit(resolved_target)
		or not manager._is_unit_alive(resolved_target)
	):
		resolved_target = manager._pick_target_in_attack_range(unit, enemy_team)
		if resolved_target == null:
			resolved_target = manager._pick_target_for_unit(unit, false)
	if resolved_target == null:
		_clear_unit_move_and_idle(unit, manager._get_movement(unit))
		return

	var target_cell: Vector2i = manager._get_unit_cell(resolved_target)
	if target_cell.x < 0:
		_clear_unit_move_and_idle(unit, manager._get_movement(unit))
		return

	var moved: bool = move_unit_steps_away(manager, unit, target_cell, 1)
	manager._metric_tick_move_checks += 1
	manager._metric_total_move_checks += 1
	if moved:
		var unit_api: Variant = unit
		unit_api.play_anim_state(1, {})
		manager._metric_tick_move_started += 1
		manager._metric_total_move_started += 1
		return

	_clear_unit_move_and_idle(unit, manager._get_movement(unit))
	manager._metric_tick_move_blocked += 1
	manager._metric_total_move_blocked += 1


# hold 分支用于“目标已在射程内，但当前帧不需要/不能执行攻击”的情况。
# 这能避免单位在可攻击范围内来回抖动，是旧修复逻辑的一部分。
# 命中这个分支后会记一次 move_check 和一次 move_blocked。
func _should_hold_position_in_attack_range(
	manager,
	unit: Node,
	target: Node
) -> bool:
	if target == null or not manager._is_target_in_attack_range(unit, target):
		return false

	_clear_move_replan_cooldown(manager, unit)
	_clear_movement_target(manager._get_movement(unit))
	var unit_api: Variant = unit
	unit_api.play_anim_state(0, {})
	manager._metric_tick_move_checks += 1
	manager._metric_total_move_checks += 1
	manager._metric_tick_move_blocked += 1
	manager._metric_total_move_blocked += 1
	emit_unit_move_failed(manager, unit, "in_range_hold", {"target": target})
	return true


# 普通移动阶段负责读取流场、选择邻格、处理阻挡冲突与提交视觉移动。
# `combat` 只用于“被卡住时兜底再打一次射程内目标”的旧逻辑。
# 所有失败出口都会统一落到 move_failed signal。
func _run_move_phase(
	manager,
	unit: Node,
	combat: Node,
	target: Node,
	attack_range_target: Node,
	allow_attack: bool
) -> void:
	manager._metric_tick_move_checks += 1
	manager._metric_total_move_checks += 1

	var current_cell: Vector2i = manager._get_unit_cell(unit)
	if current_cell.x < 0 or current_cell.y < 0:
		# 逻辑格丢失时不能继续寻路，否则会把单位推入错误位置。
		_clear_unit_move_and_idle(unit, manager._get_movement(unit))
		manager._metric_tick_idle_no_cell += 1
		manager._metric_total_idle_no_cell += 1
		emit_unit_move_failed(manager, unit, "no_cell", {})
		return

	var flow_field = (
		manager._flow_to_enemy
		if int(unit.get("team_id")) == manager.TEAM_ALLY
		else manager._flow_to_ally
	)
	var flow_cost: int = flow_field.sample_cost(current_cell)
	if flow_cost < 0:
		manager._metric_tick_flow_unreachable += 1
		manager._metric_total_flow_unreachable += 1

	# 相邻格选择仍交给 pathfinding 模块，movement 只负责提交结果。
	var best_next: Vector2i = manager._pick_best_adjacent_cell(
		unit,
		current_cell,
		attack_range_target
	)
	if best_next == current_cell:
		if _try_fallback_attack_when_blocked(
			manager,
			unit,
			combat,
			attack_range_target,
			allow_attack
		):
			_clear_move_replan_cooldown(manager, unit)
			return
		_clear_unit_move_and_idle(unit, manager._get_movement(unit))
		_mark_move_replan_cooldown(manager, unit)
		manager._metric_tick_move_blocked += 1
		manager._metric_total_move_blocked += 1
		emit_unit_move_failed(manager, unit, "block", {
			"from_cell": current_cell,
			"to_cell": best_next,
			"target": target
		})
		return

	# 提交移动前再验一次空格，避免同帧被其他单位抢占目标格。
	if not manager._is_cell_free(best_next):
		_clear_unit_move_and_idle(unit, manager._get_movement(unit))
		_mark_move_replan_cooldown(manager, unit)
		manager._metric_tick_move_conflicts += 1
		manager._metric_total_move_conflicts += 1
		emit_unit_move_failed(manager, unit, "conflict", {
			"from_cell": current_cell,
			"to_cell": best_next
		})
		return

	# occupy 失败说明发生了竞争态，这里统一归类为 conflict。
	if not manager._occupy_cell(best_next, unit):
		_clear_unit_move_and_idle(unit, manager._get_movement(unit))
		_mark_move_replan_cooldown(manager, unit)
		manager._metric_tick_move_conflicts += 1
		manager._metric_total_move_conflicts += 1
		emit_unit_move_failed(manager, unit, "conflict", {
			"from_cell": current_cell,
			"to_cell": best_next
		})
		return

	_clear_move_replan_cooldown(manager, unit)
	_apply_move_visual(manager, unit, best_next)
	var unit_api: Variant = unit
	unit_api.play_anim_state(1, {})
	manager._metric_tick_move_started += 1
	manager._metric_total_move_started += 1


# 被卡住时允许再尝试一次“当前射程内是否有备选目标可打”。
# 这条分支是旧的僵持缓解逻辑，不能在拆分时丢掉。
# 只有真的打出去后才返回 true，并补记攻击统计。
func _try_fallback_attack_when_blocked(
	manager,
	unit: Node,
	combat: Node,
	attack_range_target: Node,
	allow_attack: bool
) -> bool:
	if not allow_attack:
		return false
	if attack_range_target == null:
		return false
	if not manager._attack_service.try_execute_attack(
		manager,
		unit,
		combat,
		attack_range_target
	):
		return false
	manager._metric_tick_attacks_performed += 1
	manager._metric_total_attacks_performed += 1
	return true


# 逻辑占格先变更，再根据 strict snap 配置决定如何更新视觉位置。
# 严格格子模式下，视觉移动只是补充 tween，不再反向驱动逻辑坐标。
# 没有移动组件时则直接瞬移到格心，保证显示与逻辑一致。
func _apply_move_visual(
	manager,
	unit: Node,
	best_next: Vector2i
) -> void:
	var hex_grid: Node = manager._hex_grid
	var movement: Node = manager._get_movement(unit)
	if hex_grid != null and is_instance_valid(hex_grid):
		var hex_grid_api: Variant = hex_grid
		var target_world: Vector2 = hex_grid_api.axial_to_world(best_next)

		# 有移动组件时优先让组件接管视觉移动；没有组件再直接改坐标。
		if movement != null:
			var movement_api: Variant = movement
			if manager.strict_cell_snap_in_combat:
				# 严格格子模式下，逻辑已经落格，视觉位移只是短补间。
				var did_visual_step: bool = false
				if manager.strict_snap_visual_step_enabled and unit.has_method("play_quick_cell_step"):
					var duration: float = clampf(
						manager._logic_step * manager.strict_snap_visual_step_duration_ratio,
						0.03,
						0.14
					)
					var unit_api: Variant = unit
					unit_api.play_quick_cell_step(target_world, duration)
					did_visual_step = true
				if not did_visual_step:
					var snap_node: Node2D = unit as Node2D
					if snap_node != null:
						snap_node.position = target_world
				movement_api.clear_target()
				return
			movement_api.set_target(target_world)
			return

		var unit_node: Node2D = unit as Node2D
		if unit_node != null:
			unit_node.position = target_world
		return

	# HexGrid 丢失时保留兜底清目标，避免 UnitMovement 卡着旧目标继续跑。
	_clear_movement_target(movement)


# 逼近一步只比较相邻格与目标格的六角距离。
# 这里不读流场，专门服务技能位移与恐惧/击退这类即时一步效果。
# 若没有更优邻格，则返回原地不动。
func _pick_step_towards(
	manager,
	from_cell: Vector2i,
	target_cell: Vector2i
) -> Vector2i:
	# toward/away 这两组 helper 专门服务即时位移，不复用流场代价。
	# 这样技能 push/pull 的行为会更直观，也不会受队伍流场缓存影响。
	var best: Vector2i = from_cell
	var best_dist: int = manager._hex_distance(from_cell, target_cell)
	for neighbor in manager._neighbors_of(from_cell):
		if not manager._is_cell_free(neighbor):
			continue
		var dist: int = manager._hex_distance(neighbor, target_cell)
		if dist < best_dist:
			best_dist = dist
			best = neighbor
	return best


# 远离一步与逼近一步共享同一邻格遍历，只是比较方向相反。
# 返回原地表示没有更安全的可走格。
# 这里不额外引入 tie-break，完全保持旧口径。
func _pick_step_away(
	manager,
	from_cell: Vector2i,
	threat_cell: Vector2i
) -> Vector2i:
	# away 只关心“是否更远”，不额外比较侧向偏好。
	var best: Vector2i = from_cell
	var best_dist: int = manager._hex_distance(from_cell, threat_cell)
	for neighbor in manager._neighbors_of(from_cell):
		if not manager._is_cell_free(neighbor):
			continue
		var dist: int = manager._hex_distance(neighbor, threat_cell)
		if dist > best_dist:
			best_dist = dist
			best = neighbor
	return best


# 统一推进 UnitCombat 的逻辑帧，避免主逻辑里夹杂组件细节。
# `combat` 仍是动态脚本组件，因此这里通过 Variant 直接调用方法。
# 若组件引用失效则静默跳过，由上层存活检查兜底。
func _tick_combat_logic(combat: Node, delta: float) -> void:
	if combat == null or not is_instance_valid(combat):
		return
	var combat_api: Variant = combat
	# 攻击冷却、护盾衰减等逐帧状态都仍由 UnitCombat 自己推进。
	combat_api.tick_logic(delta)


# 移动目标清理由多个分支复用，因此单独做成 helper。
# 这里不发 signal，只负责把 UnitMovement 拉回空目标状态。
# `movement` 为空时直接返回，避免各调用点重复判空。
func _clear_movement_target(movement: Node) -> void:
	if movement == null or not is_instance_valid(movement):
		return
	var movement_api: Variant = movement
	# 清空 target 是所有停步、冲突和战斗结束路径的公共收尾动作。
	movement_api.clear_target()
func _resolve_attack_range_target_for_move(
	manager,
	unit: Node,
	target: Node,
	enemy_team: int
) -> Node:
	if target != null and manager._is_target_in_attack_range(unit, target):
		return target
	return manager._pick_target_in_attack_range(unit, enemy_team)
