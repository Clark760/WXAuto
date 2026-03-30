extends RefCounted
class_name UnitAugmentMovementControlOps

# movement/control op 只表达位移与控制语义。
# 选格复用 spatial/query service，运行时落地统一走 gateway。

var _summary_collector: Variant
var _query_service: Variant
var _hex_spatial_service: Variant


# `summary_collector` 负责日志与统计，`query_service` / `hex_spatial_service` 负责纯查询和选格。
# 这一层不直接保留旧 combat/buff 依赖，只通过 gateway 或 context 访问它们。
# 这样位移和控制语义可以独立整理，而不把旧运行时对象绑死在 service 构造期。
func _init(
	summary_collector: Variant,
	query_service: Variant,
	hex_spatial_service: Variant
) -> void:
	_summary_collector = summary_collector
	_query_service = query_service
	_hex_spatial_service = hex_spatial_service


# 位移与控制属于“改变目标位置/状态”的同类副作用。
# `routes` 只建立入口映射，具体目标选择、位移执行和 Buff 落地继续留在函数体里按语义拆开。
func register_routes(routes: Dictionary) -> void:
	routes["pull_target"] = Callable(self, "_pull_target")
	routes["knockback_aoe"] = Callable(self, "_knockback_aoe")
	routes["swap_position"] = Callable(self, "_swap_position")
	routes["silence_target"] = Callable(self, "_silence_target")
	routes["stun_target"] = Callable(self, "_stun_target")
	routes["fear_aoe"] = Callable(self, "_fear_aoe")
	routes["freeze_target"] = Callable(self, "_freeze_target")
	routes["teleport_behind"] = Callable(self, "_teleport_behind")
	routes["dash_forward"] = Callable(self, "_dash_forward")
	routes["knockback_target"] = Callable(self, "_knockback_target")
	routes["taunt_aoe"] = Callable(self, "_taunt_aoe")


# 拉拽效果优先走格子移动接口，避免世界坐标与逻辑格脱节。
# `effect.distance` 在这里解释为逻辑步数，真正的移动执行委托给 `combat_manager`。
func _pull_target(
	_runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
# 拉拽是最简单的格子位移，优先复用 CombatManager 现有接口。
	var combat_manager: Variant = context.get("combat_manager", null)
	if combat_manager == null or not combat_manager.has_method("move_unit_steps_towards"):
		return

	# 拉拽目标按 source 当前逻辑格前进，避免世界坐标位置与格子占位不同步。
	var source_cell: Vector2i = combat_manager.get_unit_cell_of(source)
	var pull_distance: int = _resolve_distance_steps(effect)
	# 旧接口会自己处理途中阻挡与停靠，因此这里不再手写路径搜索。
	combat_manager.move_unit_steps_towards(target, source_cell, pull_distance)


# 范围击退依赖 query service 找人，再依赖 combat manager 做格子位移。
# `effect.radius` 先换成世界距离找目标，`effect.distance` 再作为格子步数执行击退。
func _knockback_aoe(
	_runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	var combat_manager: Variant = context.get("combat_manager", null)
	if combat_manager == null or not combat_manager.has_method("move_unit_steps_away"):
		return

	var radius_world: float = _query_service.cells_to_world_distance(float(effect.get("radius", 2.0)), context)
	var distance_steps: int = _resolve_distance_steps(effect)
	var center_cell: Vector2i = combat_manager.get_unit_cell_of(source)
	# AOE 击退先统一取命中敌军，再逐个沿远离中心格的方向推开。
	for enemy in _query_service.collect_enemy_units_in_radius(
		source,
		_query_service.node_pos(source),
		radius_world,
		context
	):
		combat_manager.move_unit_steps_away(enemy, center_cell, distance_steps)


# 换位不需要 query 选人，但仍然只负责行为语义，不负责旧接口兼容细节。
# `source/target` 都必须已经由上层确定好，当前函数不再重选目标。
func _swap_position(
	_runtime_gateway: Variant,
	source: Node,
	target: Node,
	_effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	var combat_manager: Variant = context.get("combat_manager", null)
	if combat_manager != null and combat_manager.has_method("swap_unit_cells"):
		# 换位只依赖旧 combat 的格子交换，不在这里手写世界坐标互换。
		# 这样可以继续复用旧占位校验和事件广播逻辑。
		combat_manager.swap_unit_cells(source, target)


# 控制效果仍保留“写 meta + 附带控制 Buff”的双轨兼容行为。
# `duration` 既要写入运行时状态，也要同步写进可视 Debuff。
# `summary` 只记录 Debuff 附着结果，不记录 meta 写入这种内部行为。
func _silence_target(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var duration: float = float(effect.get("duration", 2.0))
	# 运行时控制状态和可视 Debuff 必须同时写入，才能让行为和 UI 保持一致。
	# 沉默使用专门的 debuff_silence 资源，避免和其他控制效果共用错误图标。
	runtime_gateway.apply_control_state(target, "silence", duration, context)
	_apply_control_buff(
		runtime_gateway,
		source,
		target,
		"debuff_silence",
		duration,
		context,
		summary,
		"silence_target"
	)


# 眩晕沿用冻结 Debuff 作为表现层 Buff id，保持旧 UI 资源兼容。
# `effect.duration` 决定运行时眩晕时长，但表现层仍复用既有 freeze 资源。
func _stun_target(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var duration: float = float(effect.get("duration", 1.5))
	# 眩晕沿用与冻结共用的表现 Buff，但行为层仍按 stun 状态写入。
	# 这是历史资源复用，不代表眩晕和冻结在行为层完全等价。
	runtime_gateway.apply_control_state(target, "stun", duration, context)
	_apply_control_buff(
		runtime_gateway,
		source,
		target,
		"debuff_freeze",
		duration,
		context,
		summary,
		"stun_target"
	)


# 范围恐惧逐个目标写控制状态，再统一走控制 Buff 汇总。
# 每个目标都单独追加事件，避免 AOE 控制只在 summary 里留下一个总计数字。
func _fear_aoe(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var radius_world: float = _query_service.cells_to_world_distance(float(effect.get("radius", 2.0)), context)
	var duration: float = float(effect.get("duration", 2.0))

	for enemy in _query_service.collect_enemy_units_in_radius(
		source,
		_query_service.node_pos(source),
		radius_world,
		context
	):
		# 恐惧逐目标写状态，便于后续单独清理或记录每个命中单位。
		# 这样即使部分目标中途失效，其余目标的控制也不会被整组回滚。
		runtime_gateway.apply_control_state(enemy, "fear", duration, context)
		_apply_control_buff(
			runtime_gateway,
			source,
			enemy,
			"debuff_fear",
			duration,
			context,
			summary,
			"fear_aoe"
		)


# 冻结本质上是“眩晕 + 强制暴击标记”，因此仍落在控制语义组里。
# 除了控制 Debuff，这里还会写 `status_frozen_force_crit` 给旧战斗结算读取。
func _freeze_target(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var duration: float = float(effect.get("duration", 2.0))
	runtime_gateway.apply_control_state(target, "stun", duration, context)
	if target != null and is_instance_valid(target):
		# 冻结额外写强制暴击标记，供旧暴击逻辑在命中冻结目标时读取。
		# 标记与 stun 时间分开存储，方便后续独立清理或延展冻结专属逻辑。
		target.set_meta("status_frozen_force_crit", true)
	_apply_control_buff(
		runtime_gateway,
		source,
		target,
		"debuff_freeze",
		duration,
		context,
		summary,
		"freeze_target"
	)


# 三类位移效果共享“优先走格子，失败再退回世界坐标”的策略。
# `distance` 在这里解释为位移步数，不直接用世界坐标长度。
# `context` 里的 `combat_manager/hex_grid` 缺一时，会自动退回世界坐标方案。
func _teleport_behind(
	_runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	# 这个位移入口同时兼容格子战斗和无格子世界坐标回退。
	# 两条路径都要留着，直到旧运行时彻底退场。
	if source == null or not is_instance_valid(source):
		return
	if target == null or not is_instance_valid(target):
		return

	var distance_steps: int = _resolve_distance_steps(effect)
	var combat_manager: Variant = context.get("combat_manager", null)
	var hex_grid: Variant = context.get("hex_grid", null)
	var has_grid_movement: bool = combat_manager != null \
		and combat_manager.has_method("get_unit_cell_of") \
		and combat_manager.has_method("force_move_unit_to_cell")

	if has_grid_movement:
		var source_cell_value: Variant = combat_manager.get_unit_cell_of(source)
		var target_cell_value: Variant = combat_manager.get_unit_cell_of(target)
		if source_cell_value is Vector2i and target_cell_value is Vector2i:
			# 有格子信息时优先落到“目标身后”的逻辑格，而不是只做视觉位移。
			var target_cell_behind: Vector2i = _hex_spatial_service.find_cell_behind_target(
				target_cell_value as Vector2i,
				source_cell_value as Vector2i,
				distance_steps,
				combat_manager,
				hex_grid
			)
			if target_cell_behind.x >= 0:
				combat_manager.force_move_unit_to_cell(source, target_cell_behind)
				return

	# 旧运行时缺格子接口时，回退到世界坐标并保持“落到目标身后”的视觉语义。
	var source_pos: Vector2 = _query_service.node_pos(source)
	var target_pos: Vector2 = _query_service.node_pos(target)
	var direction: Vector2 = (target_pos - source_pos).normalized()
	if direction.is_zero_approx():
		direction = Vector2.RIGHT

	var source_node: Node2D = source as Node2D
	if source_node != null:
		source_node.position = target_pos + direction * _query_service.cells_to_world_distance(
			float(distance_steps),
			context
		)


# 冲锋优先走格子路径，只有旧运行时缺格子接口时才退回到世界坐标。
# `effect.distance` 决定冲锋步数，目标本身只用于确定前进方向而不是最终占位。
func _dash_forward(
	_runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	if source == null or not is_instance_valid(source):
		return
	if target == null or not is_instance_valid(target):
		return

	var distance_steps: int = _resolve_distance_steps(effect)
	var combat_manager: Variant = context.get("combat_manager", null)
	var has_grid_movement: bool = combat_manager != null \
		and combat_manager.has_method("get_unit_cell_of") \
		and combat_manager.has_method("move_unit_steps_towards")

	if has_grid_movement:
		# 冲锋本质是 source 朝 target 的当前格子前进若干步，而不是瞬移到目标身上。
		# 这样可以保留旧战斗里“冲锋途中被阻挡”的判定空间。
		var target_cell_value: Variant = combat_manager.get_unit_cell_of(target)
		if target_cell_value is Vector2i:
			combat_manager.move_unit_steps_towards(source, target_cell_value as Vector2i, distance_steps)
			return

	var source_node: Node2D = source as Node2D
	var target_node: Node2D = target as Node2D
	if source_node == null or target_node == null:
		return

	var direction: Vector2 = (target_node.position - source_node.position).normalized()
	if direction.is_zero_approx():
		return

	# 无格子接口时退回世界坐标直线前进，至少保留视觉上的冲锋方向。
	source_node.position += direction * _query_service.cells_to_world_distance(
		float(distance_steps),
		context
	)


# 单体击退与范围击退共用同一套“远离 source”语义，只是目标解析不同。
# 当前函数只处理单体目标，不在内部再做额外的敌我筛选。
func _knockback_target(
	_runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	if source == null or not is_instance_valid(source):
		return
	if target == null or not is_instance_valid(target):
		return

	var distance_steps: int = _resolve_distance_steps(effect)
	var combat_manager: Variant = context.get("combat_manager", null)
	var has_grid_movement: bool = combat_manager != null \
		and combat_manager.has_method("get_unit_cell_of") \
		and combat_manager.has_method("move_unit_steps_away")

	if has_grid_movement:
		# 单体击退优先沿 source 的逻辑格反方向推进，避免目标穿模到非法位置。
		# 与 AOE 击退共用同一套旧移动语义，只是目标列表缩成了单体。
		var source_cell_value: Variant = combat_manager.get_unit_cell_of(source)
		if source_cell_value is Vector2i:
			combat_manager.move_unit_steps_away(target, source_cell_value as Vector2i, distance_steps)
			return

	var source_node: Node2D = source as Node2D
	var target_node: Node2D = target as Node2D
	if source_node == null or target_node == null:
		return

	var direction: Vector2 = (target_node.position - source_node.position).normalized()
	if direction.is_zero_approx():
		direction = Vector2.RIGHT

	# 世界坐标回退路径只保证方向正确，不承担格子合法性校验。
	target_node.position += direction * _query_service.cells_to_world_distance(
		float(distance_steps),
		context
	)


# 嘲讽既写运行时状态，也可附带独立 Debuff，便于状态栏显示。
# `buff_id` 为空时也会保留行为级嘲讽，只是不再生成可视 Debuff 记录。
# `summary` 里只记录可视 Debuff 的附着结果，行为级嘲讽状态不单独记事件。
func _taunt_aoe(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	# 嘲讽既改运行时状态，也可能附带一个可视 Debuff。
	# 这样 UI、日志和战斗行为能保持同一份事实来源。
	var taunt_radius: float = _query_service.cells_to_world_distance(float(effect.get("radius", 2.0)), context)
	var taunt_duration: float = maxf(float(effect.get("duration", 2.0)), 0.05)
	var taunt_buff_id: String = str(effect.get("buff_id", "")).strip_edges()

	for enemy in _query_service.collect_enemy_units_in_radius(
		source,
		_query_service.node_pos(source),
		taunt_radius,
		context
	):
		# 先写行为级嘲讽状态，再按需附带可视 Debuff，避免没有 buff_id 时行为丢失。
		runtime_gateway.apply_taunt_state(enemy, source, taunt_duration, context)
		if taunt_buff_id.is_empty():
			continue

		var taunt_effect: Dictionary = {
			"buff_id": taunt_buff_id,
			"duration": taunt_duration
		}
		if runtime_gateway.apply_buff_op(source, enemy, taunt_effect, context):
			summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
			_summary_collector.append_buff_event(summary, source, enemy, taunt_buff_id, taunt_duration, "taunt_aoe")


# 控制 Buff 汇总统一收口在这里，避免沉默/眩晕/恐惧各自重复写 summary。
# `buff_id/duration` 由控制入口决定，这里只负责附着和写事件，不再改运行时状态。
func _apply_control_buff(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	buff_id: String,
	duration: float,
	context: Dictionary,
	summary: Dictionary,
	op: String
) -> void:
	var effect: Dictionary = {
		"buff_id": buff_id,
		"duration": duration
	}
	# 控制 Buff 统一走普通 Buff 入口，确保状态栏、驱散和日志看到的是同一种附着记录。
	# 这里故意不直接操作 summary 里的事件数组，统一复用 summary collector 的写入口。
	if not runtime_gateway.apply_buff_op(source, target, effect, context):
		return

	summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
	_summary_collector.append_buff_event(summary, source, target, buff_id, duration, op)


# 手册示例常用 `cells` / `distance_cells`，运行时统一折算成位移步数。
func _resolve_distance_steps(effect: Dictionary) -> int:
	return maxi(
		int(
			effect.get(
				"distance",
				effect.get("cells", effect.get("distance_cells", 1))
			)
		),
		1
	)
