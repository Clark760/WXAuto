extends RefCounted
class_name UnitAugmentCombatEventBridge

var _manager: Node = null


# manager 由 facade 在启动时注入，后续所有战斗事件都通过它访问子服务。
# 桥接器本身不缓存其他服务引用，避免和 manager 的装配状态分叉。
# 这样切换 manager 或重建子服务时，只需要重新注入这一处。
func configure(manager: Node) -> void:
	_manager = manager


# combat 连接统一收口到桥接服务，避免 facade 再堆一整排 signal wiring。
# 这里既负责标准战斗信号，也兼容可选信号如 terrain/team_alive 这类扩展事件。
# 所有回调都先绑定到本桥接器，再由桥接器转成 UnitAugment trigger。
func connect_combat_signals(combat_manager: Node) -> void:
	if combat_manager == null:
		return

	# 回调句柄统一先命名出来，确保 connect/disconnect 两边使用完全同一组 Callable。
	var cb_start: Callable = Callable(self, "_on_battle_started")
	var cb_damage: Callable = Callable(self, "_on_damage_resolved")
	var cb_dead: Callable = Callable(self, "_on_unit_died")
	var cb_end: Callable = Callable(self, "_on_battle_ended")
	var cb_attack_fail: Callable = Callable(self, "_on_attack_failed")
	var cb_shield_broken: Callable = Callable(self, "_on_shield_broken")
	var cb_spawn_mid: Callable = Callable(self, "_on_unit_spawned_mid_battle")
	var cb_damage_detail: Callable = Callable(self, "_on_damage_received_detail")
	var cb_heal_detail: Callable = Callable(self, "_on_heal_received")
	var cb_thorns: Callable = Callable(self, "_on_thorns_triggered")
	var cb_move_success: Callable = Callable(self, "_on_unit_move_success")
	var cb_move_failed: Callable = Callable(self, "_on_unit_move_failed")
	var cb_terrain_created: Callable = Callable(self, "_on_terrain_created")
	var cb_terrain_phase: Callable = Callable(self, "_on_terrain_phase_tick")
	var cb_team_alive: Callable = Callable(self, "_on_team_alive_count_changed")

	# 连接时统一做 has_signal/is_connected 检查，避免不同 CombatManager 版本缺信号时报错。
	if not combat_manager.is_connected("battle_started", cb_start):
		combat_manager.connect("battle_started", cb_start)
	if not combat_manager.is_connected("damage_resolved", cb_damage):
		combat_manager.connect("damage_resolved", cb_damage)
	if not combat_manager.is_connected("unit_died", cb_dead):
		combat_manager.connect("unit_died", cb_dead)
	if not combat_manager.is_connected("battle_ended", cb_end):
		combat_manager.connect("battle_ended", cb_end)
	if combat_manager.has_signal("attack_failed") \
	and not combat_manager.is_connected("attack_failed", cb_attack_fail):
		combat_manager.connect("attack_failed", cb_attack_fail)
	if combat_manager.has_signal("shield_broken") \
	and not combat_manager.is_connected("shield_broken", cb_shield_broken):
		combat_manager.connect("shield_broken", cb_shield_broken)
	if combat_manager.has_signal("unit_spawned_mid_battle") \
	and not combat_manager.is_connected("unit_spawned_mid_battle", cb_spawn_mid):
		combat_manager.connect("unit_spawned_mid_battle", cb_spawn_mid)
	if combat_manager.has_signal("damage_received_detail") \
	and not combat_manager.is_connected("damage_received_detail", cb_damage_detail):
		combat_manager.connect("damage_received_detail", cb_damage_detail)
	if combat_manager.has_signal("heal_received") \
	and not combat_manager.is_connected("heal_received", cb_heal_detail):
		combat_manager.connect("heal_received", cb_heal_detail)
	if combat_manager.has_signal("thorns_triggered") \
	and not combat_manager.is_connected("thorns_triggered", cb_thorns):
		combat_manager.connect("thorns_triggered", cb_thorns)
	if combat_manager.has_signal("unit_move_success") \
	and not combat_manager.is_connected("unit_move_success", cb_move_success):
		combat_manager.connect("unit_move_success", cb_move_success)
	if combat_manager.has_signal("unit_move_failed") \
	and not combat_manager.is_connected("unit_move_failed", cb_move_failed):
		combat_manager.connect("unit_move_failed", cb_move_failed)
	if combat_manager.has_signal("terrain_created") \
	and not combat_manager.is_connected("terrain_created", cb_terrain_created):
		combat_manager.connect("terrain_created", cb_terrain_created)
	if combat_manager.has_signal("terrain_phase_tick") \
	and not combat_manager.is_connected("terrain_phase_tick", cb_terrain_phase):
		combat_manager.connect("terrain_phase_tick", cb_terrain_phase)
	if combat_manager.has_signal("team_alive_count_changed") \
	and not combat_manager.is_connected("team_alive_count_changed", cb_team_alive):
		combat_manager.connect("team_alive_count_changed", cb_team_alive)


# 切换 CombatManager 时必须先断旧连接，否则桥接器会收到双份事件。
# disconnect 逻辑必须与 connect 使用同一组 Callable，不能现场重新拼匿名回调。
# 这里只拆桥，不改 battle runtime 或 trigger runtime 的内部状态。
func disconnect_combat_signals(combat_manager: Node) -> void:
	if combat_manager == null:
		return

	# 断开顺序不要求和 connect 完全一致，但必须覆盖全部已连接信号。
	var cb_start: Callable = Callable(self, "_on_battle_started")
	var cb_damage: Callable = Callable(self, "_on_damage_resolved")
	var cb_dead: Callable = Callable(self, "_on_unit_died")
	var cb_end: Callable = Callable(self, "_on_battle_ended")
	var cb_attack_fail: Callable = Callable(self, "_on_attack_failed")
	var cb_shield_broken: Callable = Callable(self, "_on_shield_broken")
	var cb_spawn_mid: Callable = Callable(self, "_on_unit_spawned_mid_battle")
	var cb_damage_detail: Callable = Callable(self, "_on_damage_received_detail")
	var cb_heal_detail: Callable = Callable(self, "_on_heal_received")
	var cb_thorns: Callable = Callable(self, "_on_thorns_triggered")
	var cb_move_success: Callable = Callable(self, "_on_unit_move_success")
	var cb_move_failed: Callable = Callable(self, "_on_unit_move_failed")
	var cb_terrain_created: Callable = Callable(self, "_on_terrain_created")
	var cb_terrain_phase: Callable = Callable(self, "_on_terrain_phase_tick")
	var cb_team_alive: Callable = Callable(self, "_on_team_alive_count_changed")

	if combat_manager.is_connected("battle_started", cb_start):
		combat_manager.disconnect("battle_started", cb_start)
	if combat_manager.is_connected("damage_resolved", cb_damage):
		combat_manager.disconnect("damage_resolved", cb_damage)
	if combat_manager.is_connected("unit_died", cb_dead):
		combat_manager.disconnect("unit_died", cb_dead)
	if combat_manager.is_connected("battle_ended", cb_end):
		combat_manager.disconnect("battle_ended", cb_end)
	if combat_manager.has_signal("attack_failed") \
	and combat_manager.is_connected("attack_failed", cb_attack_fail):
		combat_manager.disconnect("attack_failed", cb_attack_fail)
	if combat_manager.has_signal("shield_broken") \
	and combat_manager.is_connected("shield_broken", cb_shield_broken):
		combat_manager.disconnect("shield_broken", cb_shield_broken)
	if combat_manager.has_signal("unit_spawned_mid_battle") \
	and combat_manager.is_connected("unit_spawned_mid_battle", cb_spawn_mid):
		combat_manager.disconnect("unit_spawned_mid_battle", cb_spawn_mid)
	if combat_manager.has_signal("damage_received_detail") \
	and combat_manager.is_connected("damage_received_detail", cb_damage_detail):
		combat_manager.disconnect("damage_received_detail", cb_damage_detail)
	if combat_manager.has_signal("heal_received") \
	and combat_manager.is_connected("heal_received", cb_heal_detail):
		combat_manager.disconnect("heal_received", cb_heal_detail)
	if combat_manager.has_signal("thorns_triggered") \
	and combat_manager.is_connected("thorns_triggered", cb_thorns):
		combat_manager.disconnect("thorns_triggered", cb_thorns)
	if combat_manager.has_signal("unit_move_success") \
	and combat_manager.is_connected("unit_move_success", cb_move_success):
		combat_manager.disconnect("unit_move_success", cb_move_success)
	if combat_manager.has_signal("unit_move_failed") \
	and combat_manager.is_connected("unit_move_failed", cb_move_failed):
		combat_manager.disconnect("unit_move_failed", cb_move_failed)
	if combat_manager.has_signal("terrain_created") \
	and combat_manager.is_connected("terrain_created", cb_terrain_created):
		combat_manager.disconnect("terrain_created", cb_terrain_created)
	if combat_manager.has_signal("terrain_phase_tick") \
	and combat_manager.is_connected("terrain_phase_tick", cb_terrain_phase):
		combat_manager.disconnect("terrain_phase_tick", cb_terrain_phase)
	if combat_manager.has_signal("team_alive_count_changed") \
	and combat_manager.is_connected("team_alive_count_changed", cb_team_alive):
		combat_manager.disconnect("team_alive_count_changed", cb_team_alive)


# 开战事件要同步 runtime 状态，并广播 on_combat_start。
# battle runtime 的启动放在触发器广播之前，保证 on_combat_start 能看到正确运行态。
# 这里不传 ally/enemy 数量给 trigger，人数类判断统一走后续 team_alive 事件。
func _on_battle_started(_ally_count: int, _enemy_count: int) -> void:
	if _manager == null:
		return
	_manager.get_battle_runtime().on_battle_started(_manager)
	var state_service: Variant = _manager.get_state_service()
	var combat_manager: Node = _manager.get_battle_runtime().get_bound_combat_manager()
	state_service.sync_battle_cells_from_combat_manager(combat_manager)
	state_service.mark_all_passive_aura_dirty()
	_manager._fire_trigger_for_all("on_combat_start", {})


# damage_resolved 会派生出命中、暴击、被攻击和闪避四类触发器。
# `event_dict` 是 CombatManager 的原始伤害结算快照，这里只补 source/target 节点解析。
# 环境伤害会跳过攻击方相关 trigger，避免地形伤害误触发 on_attack_hit/on_crit。
func _on_damage_resolved(event_dict: Dictionary) -> void:
	if _manager == null:
		return

	# source/target 统一从 state_service 的 lookup 解析，避免桥接器自己维护第二套表。
	var state_service: Variant = _manager.get_state_service()
	var source_id: int = int(event_dict.get("source_id", -1))
	var target_id: int = int(event_dict.get("target_id", -1))
	var source: Node = state_service.get_unit_lookup().get(source_id, null)
	var target: Node = state_service.get_unit_lookup().get(target_id, null)
	if source == null or not is_instance_valid(source):
		return

	var is_environment: bool = bool(event_dict.get("is_environment", false))
	var is_dodged: bool = bool(event_dict.get("is_dodged", false))
	var is_crit: bool = bool(event_dict.get("is_crit", false))

	# 攻击方和受击方触发器在这里拆开派发，保持旧战斗事件语义不变。
	if not is_environment and not is_dodged:
		_manager._fire_trigger_for_unit(source, "on_attack_hit", {
			"target": target,
			"event": event_dict
		})
	if not is_environment and is_crit:
		_manager._fire_trigger_for_unit(source, "on_crit", {
			"target": target,
			"event": event_dict,
			"is_crit": true
		})
	if target != null and is_instance_valid(target):
		if not is_environment:
			_manager._fire_trigger_for_unit(target, "on_attacked", {
				"target": source,
				"event": event_dict
			})
		if not is_environment and is_dodged:
			_manager._fire_trigger_for_unit(target, "on_dodge", {
				"target": source,
				"event": event_dict,
				"is_dodged": true
			})
		if bool(event_dict.get("shield_broken", false)):
			_clear_shield_bound_buffs(target)


# provider 死亡时要先清其光环，再清尸体上的 Buff 和 ally_death 事件。
# 处理顺序必须先发击杀与 ally_death，再清 provider 光环和尸体 Buff，避免事件读不到最后状态。
# `team_id` 是死者所属阵营，供 ally_death 在同阵营存活单位范围内广播。
func _on_unit_died(dead_unit: Node, killer: Node, team_id: int) -> void:
	if _manager == null:
		return

	# 击杀奖励和 ally_death 都属于死亡事件派生触发，必须在 Buff 清理前完成。
	var state_service: Variant = _manager.get_state_service()
	var buff_manager: Variant = _manager.get_buff_manager()
	var dead_cell: Vector2i = state_service.get_unit_battle_cell(dead_unit)

	if killer != null and is_instance_valid(killer):
		_manager._fire_trigger_for_unit(killer, "on_kill", {"target": dead_unit})
		_grant_mp_on_kill(killer)

	for ally in state_service.get_battle_units():
		if ally == null or not is_instance_valid(ally):
			continue
		if ally == dead_unit:
			continue
		if int(ally.get("team_id")) != team_id:
			continue
		if not state_service.is_unit_alive(ally):
			continue
		_manager._fire_trigger_for_unit(ally, "on_ally_death", {"target": dead_unit})

	state_service.mark_passive_aura_dirty_for_cell_change(dead_unit, dead_cell, dead_cell)

	# 源绑定光环要先按 provider 清掉，再统一移除尸体身上的 Buff。
	buff_manager.remove_source_bound_auras_from_source(dead_unit, {
		"all_units": state_service.get_battle_units()
	})
	buff_manager.remove_all_for_unit(dead_unit)


# battle_ended 只负责关停 runtime 轮询，不动战后展示所需的状态。
# 结算面板仍可能读取 Buff、trigger 结果和 runtime_stats，因此这里不能主动清空状态。
# 真正的重置入口仍是下一轮 prepare_battle。
func _on_battle_ended(_winner_team: int, _summary: Dictionary) -> void:
	if _manager == null:
		return
	_manager.get_battle_runtime().on_battle_ended()


# 攻击失败事件只透传失败原因，不走伤害派生逻辑。
# `reason` 在这里统一 lower-case，保证 trigger condition 的 reasons 过滤稳定。
# 这条路径不会补 damage 字段，因为 CombatManager 已经认定本次攻击未造成伤害。
# event_dict 在 signal 发出时已经是一次性的失败快照，这里不再重复 deep copy。
func _on_attack_failed(attacker: Node, target: Node, reason: String, event_dict: Dictionary) -> void:
	if not _is_battle_running():
		return
	if attacker == null or not is_instance_valid(attacker):
		return
	_manager._fire_trigger_for_unit(attacker, "on_attack_fail", {
		"target": target,
		"reason": reason.strip_edges().to_lower(),
		"event": event_dict
	})


# 护盾破碎独立成事件，便于和普通受击拆开配 trigger。
# `shield_absorbed` 和最终 `damage` 都会原样透传给 trigger 使用。
# 这条事件单独存在，避免只靠 damage_resolved 的布尔字段再做二次分流。
func _on_shield_broken(target: Node, source: Node, event_dict: Dictionary) -> void:
	if not _is_battle_running():
		return
	if target == null or not is_instance_valid(target):
		return
	_manager._fire_trigger_for_unit(target, "on_shield_broken", {
		"target": source,
		"source": source,
		"event": event_dict.duplicate(true),
		"damage": float(event_dict.get("damage", 0.0)),
		"shield_absorbed": float(event_dict.get("shield_absorbed", 0.0))
	})


# 中途召唤出的单位要补注册、补被动并发出 spawned 触发。
# 运行时登记和 apply_unit_augment 必须在 trigger 广播之前完成，保证新单位立刻可参与后续轮询。
# `team_id` 会原样透传给 spawned 事件，供残局或阵营条件使用。
func _on_unit_spawned_mid_battle(unit: Node, team_id: int) -> void:
	if not _is_battle_running():
		return
	if unit == null or not is_instance_valid(unit):
		return

	var state_service: Variant = _manager.get_state_service()
	if not state_service.get_unit_lookup().has(unit.get_instance_id()):
		state_service.register_battle_unit(unit)
		state_service.apply_unit_augment(unit, true)
	var spawn_cell: Vector2i = Vector2i(-1, -1)
	var combat_manager: Node = _manager.get_battle_runtime().get_bound_combat_manager()
	if combat_manager != null and combat_manager.has_method("get_unit_cell_of"):
		var spawn_cell_value: Variant = combat_manager.get_unit_cell_of(unit)
		if spawn_cell_value is Vector2i:
			spawn_cell = spawn_cell_value as Vector2i
	state_service.set_unit_battle_cell(unit, spawn_cell)
	state_service.mark_passive_aura_dirty_for_cell_change(unit, spawn_cell, spawn_cell)

	_manager._fire_trigger_for_unit(unit, "on_unit_spawned_mid_battle", {
		"unit": unit,
		"team_id": team_id
	})


# 受伤详情事件为阈值型触发器提供 damage 数值。
# 这里和 damage_resolved 分开，是为了保留“拿到结算数值”的稳定入口。
# `context.target` 仍指向来源单位，兼容旧 trigger 对 target/source 的读取口径。
func _on_damage_received_detail(target: Node, source: Node, event_dict: Dictionary) -> void:
	if not _is_battle_running():
		return
	if target == null or not is_instance_valid(target):
		return

	var context: Dictionary = event_dict.duplicate(true)
	context["target"] = source
	context["source"] = source
	context["damage"] = float(event_dict.get("damage", 0.0))
	_manager._fire_trigger_for_unit(target, "on_damage_received", context)


# 治疗事件保留 heal 和 amount 两个字段，兼容旧技能配置。
# `amount` 和 `heal` 会同时写入，是为了兼容不同版本配置对字段名的依赖。
# 这条事件默认派给被治疗者，由其自身 trigger 决定是否响应。
func _on_heal_received(source: Node, target: Node, amount: float, heal_type: String) -> void:
	if not _is_battle_running():
		return
	if target == null or not is_instance_valid(target):
		return
	_manager._fire_trigger_for_unit(target, "on_heal_received", {
		"target": source,
		"source": source,
		"heal": amount,
		"amount": amount,
		"heal_type": heal_type
	})


# 反伤事件额外写入 reflect_damage，给最小阈值触发器使用。
# `source` 是触发反伤的一方，也就是最终接收 on_thorns_triggered 的单位。
# 这样条件服务就不需要再从原始 damage 事件里猜测“谁是反伤拥有者”。
func _on_thorns_triggered(source: Node, target: Node, event_dict: Dictionary) -> void:
	if not _is_battle_running():
		return
	if source == null or not is_instance_valid(source):
		return

	var context: Dictionary = event_dict.duplicate(true)
	context["target"] = target
	context["source"] = source
	context["reflect_damage"] = float(event_dict.get("damage", 0.0))
	_manager._fire_trigger_for_unit(source, "on_thorns_triggered", context)


# 位移成功时只透传 from/to/steps，不再携带额外推断字段。
# 位移类 trigger 的路径长度、起终点格子都以 CombatManager 最终结算值为准。
# 桥接层不再根据路径自行推导附加信息，避免与 Movement 逻辑分叉。
func _on_unit_move_success(unit: Node, from_cell: Vector2i, to_cell: Vector2i, steps: int) -> void:
	if not _is_battle_running():
		return
	if unit == null or not is_instance_valid(unit):
		return
	_manager.get_state_service().mark_passive_aura_dirty_for_cell_change(unit, from_cell, to_cell)
	_manager._fire_trigger_for_unit(unit, "on_unit_move_success", {
		"unit": unit,
		"from_cell": from_cell,
		"to_cell": to_cell,
		"steps": steps
	})


# 位移失败事件需要标准化 reason，供 trigger filter 稳定比较。
# `context` 里的其他字段会完整透传，方便以后补更多失败细节而不改桥接接口。
# 统一 lower-case 的原因是配表 reasons 本来就按小写字面量匹配。
# 这里直接在 signal 传进来的 context 上补字段，避免失败热路径重复 deep copy。
func _on_unit_move_failed(unit: Node, reason: String, context: Dictionary) -> void:
	if not _is_battle_running():
		return
	if unit == null or not is_instance_valid(unit):
		return

	var payload: Dictionary = context
	payload["unit"] = unit
	payload["reason"] = reason.strip_edges().to_lower()
	_manager._fire_trigger_for_unit(unit, "on_unit_move_failed", payload)


# 地形创建是广播事件，不绑定单个 target。
# 地形定义字段直接透传，桥接层不额外读取 TerrainManager 内部对象。
# 这样新地形类型只要把 tags/type/id 写进事件，就能被 trigger 条件消费。
func _on_terrain_created(terrain: Dictionary, reason: String) -> void:
	if not _is_battle_running():
		return
	_manager._fire_trigger_for_all("on_terrain_created", {
		"terrain": terrain.duplicate(true),
		"terrain_id": str(terrain.get("terrain_id", "")),
		"terrain_def_id": str(terrain.get("terrain_def_id", "")),
		"terrain_type": str(terrain.get("terrain_type", "")),
		"terrain_tags": terrain.get("tags", []),
		"reason": reason
	})


# terrain 四相事件统一映射到 enter/tick/exit/expire 触发器名。
# 如果事件里已经给出 target，就按单体事件派发；否则退回全体广播。
# `terrain_tags` 会从 terrain 字典里补齐，避免条件服务再去读嵌套结构。
func _on_terrain_phase_tick(event_dict: Dictionary) -> void:
	if not _is_battle_running():
		return

	var phase: String = str(event_dict.get("phase", "")).strip_edges().to_lower()
	if phase.is_empty():
		return

	var trigger_name: String = _resolve_terrain_trigger_name(phase)
	if trigger_name.is_empty():
		return

	var context: Dictionary = event_dict.duplicate(true)
	if context.has("terrain"):
		var terrain_value: Variant = context.get("terrain", {})
		if terrain_value is Dictionary:
			var tags_value: Variant = (terrain_value as Dictionary).get("tags", [])
			if context.get("terrain_tags", null) == null:
				context["terrain_tags"] = tags_value

	var target_value: Variant = context.get("target", null)
	if target_value is Node and is_instance_valid(target_value):
		_manager._fire_trigger_for_unit(target_value as Node, trigger_name, context)
		return
	_manager._fire_trigger_for_all(trigger_name, context)


# team alive 改变是广播型状态事件，所有单位都能按己方/敌方人数做判断。
# 这里不做阵营预过滤，因为真正的 ally/enemy/both 逻辑在条件服务里统一判。
# 广播事件的目标是让每个单位都能基于同一份 alive_count 快照做判断。
func _on_team_alive_count_changed(team_id: int, alive_count: int) -> void:
	if not _is_battle_running():
		return
	_manager._fire_trigger_for_all("on_team_alive_count_changed", {
		"team_id": team_id,
		"alive_count": alive_count
	})


# 击杀回蓝读取 UnitCombat 外挂 modifier，桥接器只负责安全取值。
# 是否存在 mp_on_kill 修正属于运行时 modifiers 语义，不应该回到功法/装备静态表重复推导。
# 这里也顺手做了组件能力检查，避免旧 UnitCombat 缺接口时报错。
func _grant_mp_on_kill(killer: Node) -> void:
	var killer_combat: Node = killer.get_node_or_null("Components/UnitCombat")
	if killer_combat == null:
		return
	if not killer_combat.has_method("add_mp"):
		return
	if not killer_combat.has_method("get_external_modifiers"):
		return

	var modifiers_value: Variant = killer_combat.get_external_modifiers()
	if not (modifiers_value is Dictionary):
		return

	var mp_gain: float = maxf(float((modifiers_value as Dictionary).get("mp_on_kill", 0.0)), 0.0)
	if mp_gain > 0.0:
		killer_combat.add_mp(mp_gain)


# 盾条绑定 buff 被打碎后必须一起移除，避免单位继续挂着失效 meta。
# 这两个 meta 都是运行时临时状态，桥接器在这里负责同步清理。
# 如果没有对应 meta，remove_buff 会被直接跳过，不影响普通 Buff 生命周期。
func _clear_shield_bound_buffs(target: Node) -> void:
	var buff_manager: Variant = _manager.get_buff_manager()
	var shield_buff_id: String = str(target.get_meta("shield_bound_buff_id", "")).strip_edges()
	if not shield_buff_id.is_empty():
		buff_manager.remove_buff(target, shield_buff_id, "shield_broken")

	var immunity_buff_id: String = str(target.get_meta("shield_immunity_buff_id", "")).strip_edges()
	if not immunity_buff_id.is_empty():
		buff_manager.remove_buff(target, immunity_buff_id, "shield_broken")

	target.remove_meta("shield_bound_buff_id")
	target.remove_meta("shield_immunity_buff_id")


# battle runtime 是否在运行是所有 combat 回调的统一前置条件。
# 桥接器只看 UnitAugmentBattleRuntime 的运行态，不自行判断 CombatManager 状态。
# 所有事件回调的第一层快速返回都收口到这里。
func _is_battle_running() -> bool:
	if _manager == null:
		return false
	return _manager.get_battle_runtime().is_battle_running()


# terrain phase 到 trigger 名的映射固定在这里，避免各处手写字符串。
# 只有 enter/tick/exit/expire 四个阶段会被转成 trigger；未知阶段统一忽略。
# 这样新阶段若要生效，必须显式在这里补映射，避免静默扩散事件语义。
func _resolve_terrain_trigger_name(phase: String) -> String:
	match phase:
		"enter":
			return "on_terrain_enter"
		"tick":
			return "on_terrain_tick"
		"exit":
			return "on_terrain_exit"
		"expire":
			return "on_terrain_expire"
		_:
			return ""
