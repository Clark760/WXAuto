extends RefCounted
class_name UnitAugmentBattleRuntime

var _bound_combat_manager: Node = null
var _bound_hex_grid: Node = null
var _bound_vfx_factory: Node = null

var _battle_running: bool = false
var _battle_elapsed: float = 0.0
var _trigger_accum: float = 0.0


# manager 通过这个入口接收新的战斗上下文，避免把绑定状态散落回 facade。
# `combat_manager` / `hex_grid` / `vfx_factory` 是 effect 和 trigger 运行期共用的三元上下文。
# 返回值只表示绑定对象是否发生变化，不代表战斗已经开始。
# scheduler 也会在这里同步拿到新的 CombatManager 引用，避免 tag linkage 挂在旧战斗上。
func bind_combat_context(manager: Node, combat_manager: Node, hex_grid: Node, vfx_factory: Node) -> bool:
	var changed: bool = _bound_combat_manager != combat_manager \
		or _bound_hex_grid != hex_grid \
		or _bound_vfx_factory != vfx_factory
	if not changed:
		return false

	manager._disconnect_combat_signals()
	_bound_combat_manager = combat_manager
	_bound_hex_grid = hex_grid
	_bound_vfx_factory = vfx_factory

	var scheduler: Variant = manager.get_tag_linkage_scheduler()
	if scheduler != null:
		scheduler.bind_combat_manager(combat_manager)
	manager._connect_combat_signals()
	return true


# prepare_battle 负责重置 battle runtime 与 state service，不负责启动战斗。
# `ally_units` 和 `enemy_units` 只是参与单位列表，真正开战仍由 CombatManager 驱动。
# 这里必须先清 scheduler 和 buff 状态，避免上一场的光环残留到下一场。
# 所有单位都会先登记再统一 apply_unit_augment，保证运行时状态构建顺序一致。
func prepare_battle(
	manager: Node,
	ally_units: Array[Node],
	enemy_units: Array[Node],
	hex_grid: Node,
	vfx_factory: Node,
	combat_manager: Node
) -> void:
	bind_combat_context(manager, combat_manager, hex_grid, vfx_factory)

	var state_service: Variant = manager.get_state_service()
	var buff_manager: Variant = manager.get_buff_manager()
	var scheduler: Variant = manager.get_tag_linkage_scheduler()
	var trigger_runtime: Variant = manager.get_trigger_runtime()

	state_service.reset_battle_state()
	_battle_elapsed = 0.0
	_trigger_accum = 0.0
	_battle_running = false
	buff_manager.clear_all()
	if scheduler != null:
		scheduler.clear()
	if trigger_runtime != null:
		trigger_runtime.reset_battle_counters()

	for unit in ally_units:
		state_service.register_battle_unit(unit)
	for unit in enemy_units:
		state_service.register_battle_unit(unit)

	for unit in state_service.get_battle_units():
		state_service.apply_unit_augment(unit, false)


# 逻辑循环只在 battle_started 之后生效，避免备战期误轮询触发器。
# `delta` 同时推进 buff tick 和自动 trigger 轮询节拍。
# battle runtime 本身不做效果计算，只负责把节拍转交给各子服务。
# buff tick 和自动 trigger 的先后顺序固定，避免同帧里状态推进口径漂移。
func advance(manager: Node, delta: float) -> void:
	if not _battle_running:
		return

	_battle_elapsed += delta
	_trigger_accum += delta

	var state_service: Variant = manager.get_state_service()
	var buff_manager: Variant = manager.get_buff_manager()
	var trigger_runtime: Variant = manager.get_trigger_runtime()

	var buff_tick: Dictionary = buff_manager.tick(delta, {
		"all_units": state_service.get_battle_units(),
		"combat_manager": _bound_combat_manager,
		"hex_grid": _bound_hex_grid
	})
	_execute_buff_tick_requests(manager, buff_tick.get("tick_requests", []))
	state_service.reapply_changed_units(buff_tick.get("changed_unit_ids", []))

	if _trigger_accum >= maxf(manager.trigger_poll_interval, 0.05):
		_trigger_accum = 0.0
		trigger_runtime.poll_auto_triggers(manager)


# Buff tick 只负责“回放 effect 请求”，不生成新的 tick 请求。
# `tick_requests_variant` 由 BuffManager 产出，这里只负责按 instance_id 找回 source/target 并执行效果。
# 这里还会顺手把 tick summary 投影成 telemetry 事件，保持旧日志语义不变。
func _execute_buff_tick_requests(manager: Node, tick_requests_variant: Variant) -> void:
	if not (tick_requests_variant is Array):
		return

	var state_service: Variant = manager.get_state_service()
	var effect_engine: Variant = manager.get_effect_engine()
	var telemetry: Variant = manager.get_telemetry_emitter()
	var registry: Variant = manager.get_registry()

	for req_value in tick_requests_variant:
		if not (req_value is Dictionary):
			continue
		var req: Dictionary = req_value as Dictionary
		var source: Node = state_service.get_unit_lookup().get(int(req.get("source_id", -1)), null)
		var target: Node = state_service.get_unit_lookup().get(int(req.get("target_id", -1)), null)
		var buff_id: String = str(req.get("buff_id", "")).strip_edges()
		var effects: Variant = req.get("effects", [])
		if not (effects is Array):
			continue

		var context: Dictionary = manager.get_trigger_runtime().build_effect_context(
			manager,
			source,
			target,
			{
				"trigger": "buff_tick",
				"buff_id": buff_id
			}
		)
		var tick_summary: Dictionary = effect_engine.execute_active_effects(source, target, effects as Array, context)
		var tick_source_id: int = int(req.get("source_id", -1))
		var tick_source_unit_id: String = str(req.get("source_unit_id", "")).strip_edges()
		var tick_source_name: String = str(req.get("source_name", "")).strip_edges()

		if source != null and is_instance_valid(source):
			tick_source_id = source.get_instance_id()
			tick_source_unit_id = str(source.get("unit_id"))
			tick_source_name = str(source.get("unit_name"))

		telemetry.emit_effect_log_events(
			manager,
			registry,
			tick_summary,
			source,
			target,
			"buff_tick",
			"",
			"buff_tick",
			{
				"buff_id": buff_id,
				"event_type": "tick",
				"source_id": tick_source_id,
				"source_unit_id": tick_source_unit_id,
				"source_name": tick_source_name
			}
		)

		if buff_id.is_empty():
			continue
		manager.buff_event.emit({
			"origin": "buff_tick",
			"event_type": "tick",
			"source": source,
			"target": target,
			"source_team": int(source.get("team_id")) if source != null and is_instance_valid(source) else 0,
			"target_team": int(target.get("team_id")) if target != null and is_instance_valid(target) else 0,
			"buff_id": buff_id,
			"duration": 0.0,
			"op": "buff_tick",
			"gongfa_id": "",
			"trigger": "buff_tick"
		})


# battle_started 触发后才允许轮询 trigger 和 buff tick。
# 开战瞬间的护盾读取来自 UnitCombat 外挂 modifiers，不在这里重新推导。
# 这里不会修改单位条目配置，只给 UnitCombat 写运行时护盾值。
func on_battle_started(manager: Node) -> void:
	_battle_running = true
	_battle_elapsed = 0.0
	_trigger_accum = 0.0

	for unit in manager.get_state_service().get_battle_units():
		if unit == null or not is_instance_valid(unit):
			continue
		unit.remove_meta("status_frozen_force_crit")
		var combat: Node = unit.get_node_or_null("Components/UnitCombat")
		if combat == null or not combat.has_method("add_shield"):
			continue
		var modifiers: Dictionary = {}
		if combat.has_method("get_external_modifiers"):
			var modifiers_value: Variant = combat.get_external_modifiers()
			if modifiers_value is Dictionary:
				modifiers = modifiers_value as Dictionary
		var start_shield: float = maxf(float(modifiers.get("shield_on_combat_start", 0.0)), 0.0)
		if start_shield > 0.0:
			combat.add_shield(start_shield)


# 战斗结束后只关停 runtime 轮询，不清 battle_units，便于结算界面继续读取状态。
# 结算和回放仍可能读取 battle_elapsed / battle_units，因此这里只做最小停机。
# 真正的单位清理由下一次 prepare_battle 统一完成。
func on_battle_ended() -> void:
	_battle_running = false


# battle_elapsed 是 trigger 条件和外部 effect context 的时间基准。
# 返回值只在单场战斗内递增，prepare_battle 会把它清零。
# 这个时间不会和 CombatManager 的逻辑帧号直接绑定。
func get_battle_elapsed() -> float:
	return _battle_elapsed


# trigger runtime 和 effect context 会读取 battle running 状态来决定是否继续派发事件。
# 这里是所有运行期轮询的统一门闩。
# 只要这里返回 false，自动 trigger 和 buff tick 都应停机。
func is_battle_running() -> bool:
	return _battle_running


# effect context 需要 hex_size 和落点查询时，都从这里拿到当前网格对象。
# 返回的是当前绑定对象，不做副本包装。
# 这里只缓存引用，不负责网格生命周期管理。
func get_bound_hex_grid() -> Node:
	return _bound_hex_grid


# 主动技能和效果特效统一从 battle runtime 保存的 vfx factory 播放。
# 这样 trigger execution service 不需要再反查场景树。
# 工厂对象允许为空，调用方必须自己判断。
func get_bound_vfx_factory() -> Node:
	return _bound_vfx_factory


# 部分外部 effect 需要拿到 battlefield / unit_factory，入口仍从 combat manager 反查。
# 这里返回当前绑定的 CombatManager，供上层继续做局部节点解析。
# 这里不暴露更多场景节点，避免 runtime 再长成隐式 locator。
func get_bound_combat_manager() -> Node:
	return _bound_combat_manager
