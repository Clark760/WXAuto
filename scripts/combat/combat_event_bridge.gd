extends RefCounted
class_name CombatEventBridge


# 负责 Combat 侧组件回调与 manager 级信号转发。
# 这里不做战斗规则判定，只把组件层事件整理成 CombatManager 的稳定语义。
# 对外部系统来说，CombatManager.signal 的字段口径必须保持兼容。
func emit_team_alive_count_changed(
	manager: CombatManager,
	team_id: int
) -> void:
	if team_id != manager.TEAM_ALLY and team_id != manager.TEAM_ENEMY:
		return
	manager.team_alive_count_changed.emit(
		team_id,
		int(manager._alive_by_team.get(team_id, 0))
	)


# 单位格变更由占格模块驱动，但最终对外广播要统一收口到 bridge。
# `from_cell` 或 `to_cell` 为非法格时，仍然允许发送 `unit_cell_changed`。
# `unit_move_success` 只在“合法格 -> 合法格”且格子确实变化时发射。
func notify_unit_cell_changed(
	manager: CombatManager,
	unit: Node,
	from_cell: Vector2i,
	to_cell: Vector2i
) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	manager.unit_cell_changed.emit(unit, from_cell, to_cell)
	if (
		from_cell.x >= 0
		and from_cell.y >= 0
		and to_cell.x >= 0
		and to_cell.y >= 0
		and from_cell != to_cell
	):
		manager.unit_move_success.emit(
			unit,
			from_cell,
			to_cell,
			maxi(manager._hex_distance(from_cell, to_cell), 1)
		)


# CombatComponent 的 died 信号可能来自普攻、反伤或效果直伤等多条链路。
# 这里继续采用 deferred 处理，避免和当前调用栈里的伤害结算竞争状态。
# `manager` 通过 bind 注入，保持 connect/disconnect 侧不再依赖 facade 私有方法。
func on_combat_component_died(
	dead_unit: Node,
	killer: Node,
	manager: CombatManager
) -> void:
	if not manager._battle_running:
		return
	if not manager._is_live_unit(dead_unit):
		return
	var deferred_call: Callable = Callable(self, "handle_unit_death_from_signal")
	deferred_call.bind(dead_unit, killer, manager).call_deferred()


# deferred 收口后只做一件事：把死亡处理交回 attack service。
# 这里不直接修改 alive cache，避免事件桥接重新长出规则实现。
# 如果战斗已经结束，则直接丢弃该延迟事件。
func handle_unit_death_from_signal(
	dead_unit: Node,
	killer: Node,
	manager: CombatManager
) -> void:
	if not manager._battle_running:
		return
	manager._attack_service.handle_unit_death(manager, dead_unit, killer)


# damaged 是 UnitCombat 发出的明细事件，字段比 damage_resolved 更靠近底层。
# 这里负责补齐 target/source 的 instance_id 与 team_id，方便外层 trigger 使用。
# shield_broken 仍保持单独 signal，避免外层再自己从 payload 里二次拆。
func on_combat_component_damaged(
	target: Node,
	source: Node,
	event: Dictionary,
	manager: CombatManager
) -> void:
	if not manager._battle_running:
		return
	if target == null or not is_instance_valid(target):
		return

	var payload: Dictionary = event.duplicate(true)
	payload["target_id"] = target.get_instance_id()
	payload["target_team"] = int(target.get("team_id"))
	if source != null and is_instance_valid(source):
		payload["source_id"] = source.get_instance_id()
		payload["source_team"] = int(source.get("team_id"))

	manager.damage_received_detail.emit(target, source, payload)
	if bool(payload.get("shield_broken", false)):
		manager.shield_broken.emit(target, source, payload)


# healing_performed 只负责把底层治疗明细转成 manager 级公开 signal。
# `heal_type` 仍由底层组件给出，bridge 不做重写。
# target 无效时直接丢弃，避免 UI 和 trigger 读到悬空节点。
func on_combat_component_healing_performed(
	source: Node,
	target: Node,
	amount: float,
	heal_type: String,
	manager: CombatManager
) -> void:
	if not manager._battle_running:
		return
	if target == null or not is_instance_valid(target):
		return
	manager.heal_received.emit(source, target, amount, heal_type)


# 反伤事件的触发者是 `source`，也就是最终拿到 on_thorns_triggered 的单位。
# bridge 只负责复制 payload，避免外层监听者误改底层事件内容。
# source 无效时不再发射，和旧实现保持一致。
func on_combat_component_thorns_damage_dealt(
	source: Node,
	target: Node,
	event: Dictionary,
	manager: CombatManager
) -> void:
	if not manager._battle_running:
		return
	if source == null or not is_instance_valid(source):
		return
	manager.thorns_triggered.emit(source, target, event.duplicate(true))
