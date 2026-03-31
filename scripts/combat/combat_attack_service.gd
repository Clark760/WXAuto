extends RefCounted
class_name CombatAttackService


# 承接 Combat 的攻击尝试、伤害事件整理与死亡收尾。
# `manager` 仍掌握 signal 与 runtime cache，这里只迁出规则实现体。
# 外部 API 不变，facade 继续通过 `_try_execute_attack` 等旧入口转发。
func try_execute_attack(
	manager,
	unit: Node,
	combat: Node,
	target: Node
) -> bool:
	# 普攻链路先做最外层目标有效性守卫，避免底层组件收到空目标。
	if target == null:
		manager.attack_failed.emit(
			unit,
			null,
			"no_target",
			{"performed": false, "reason": "no_target"}
		)
		return false
	if not _is_target_in_attack_range_fast(manager, unit, target, combat):
		manager.attack_failed.emit(
			unit,
			target,
			"out_of_range",
			{"performed": false, "reason": "out_of_range"}
		)
		return false

	# CombatComponent 仍持有真实攻击冷却、命中、暴击和护盾逻辑。
	# 这里不改底层 API，只把结果整理与 signal 发射迁出 facade。
	var combat_api: Variant = combat
	var attack_event: Variant = combat_api.try_attack_target(target, manager._rng)
	if not (attack_event is Dictionary):
		manager.attack_failed.emit(
			unit,
			target,
			"invalid_event",
			{"performed": false, "reason": "invalid_event"}
		)
		return false

	var event_dict: Dictionary = attack_event
	# performed=false 仍视为一次合法尝试，只是要把失败原因向上层回抛。
	if not bool(event_dict.get("performed", false)):
		var reason: String = str(event_dict.get("reason", "failed")).strip_edges().to_lower()
		manager.attack_failed.emit(unit, target, reason, event_dict)
		return false

	on_attack_resolved(manager, unit, target, event_dict)
	var movement: Node = manager._get_movement(unit)
	if movement != null:
		var movement_api: Variant = movement
		# 打出攻击后立即清移动目标，防止攻击帧继续往前滑行。
		movement_api.clear_target()
	return true


# 攻击阶段已经拿到了 combat 组件，这里直接复用，避免再回 facade 取一次组件。
func _is_target_in_attack_range_fast(manager, attacker: Node, target: Node, combat: Node) -> bool:
	if combat == null:
		return false
	if target == null or not manager._is_live_unit(target):
		return false
	var attacker_cell: Vector2i = manager._get_unit_cell(attacker)
	var target_cell: Vector2i = manager._get_unit_cell(target)
	if attacker_cell.x < 0 or target_cell.x < 0:
		return false
	var range_cells: int = 1
	if combat.has_method("get_max_effective_range_cells"):
		range_cells = maxi(int(combat.get_max_effective_range_cells()), 1)
	else:
		range_cells = maxi(int(combat.get_attack_range_cells()), 1)
	return manager._hex_distance(attacker_cell, target_cell) <= range_cells


# 普攻命中后处理链只服务普通攻击。
# 伤害数字、受击动画与 VFX 的触发顺序保持原逻辑不变。
# `event_dict` 必须原样保留，避免改动外部依赖的字段口径。
func on_attack_resolved(
	manager,
	source: Node,
	target: Node,
	event_dict: Dictionary
) -> void:
	var attack_dir: Vector2 = _build_attack_direction(source, target)
	_play_attack_animation(source, event_dict, attack_dir)
	_play_hit_feedback(manager, source, target, event_dict, attack_dir)

	manager.damage_resolved.emit(
		build_damage_event(manager, source, target, event_dict)
	)
	if bool(event_dict.get("target_died", false)):
		handle_unit_death(manager, target, source)


# 死亡处理仍是 Combat 运行时的唯一入口，所有链路都必须走这里。
# `_dead_registry` 继续承担幂等保护，避免同一单位多次结算死亡。
# 处理完成后仍会立即尝试 finalize，以阻断同帧残余行为。
func handle_unit_death(
	manager,
	dead_unit: Node,
	killer: Node
) -> void:
	if not manager._is_live_unit(dead_unit):
		return

	var dead_id: int = dead_unit.get_instance_id()
	if manager._dead_registry.has(dead_id):
		return
	# 幂等守卫必须先落表，再做 vacate/emit，避免多条死亡链路重复结算。
	manager._dead_registry[dead_id] = true
	manager._vacate_unit(dead_unit)

	var dead_unit_api: Variant = dead_unit
	dead_unit_api.play_anim_state(5, {})
	var movement: Node = manager._get_movement(dead_unit)
	if movement != null:
		var movement_api: Variant = movement
		movement_api.clear_target()

	var dead_team: int = int(dead_unit.get("team_id"))
	# alive cache 和 team signal 必须在 unit_died 前完成更新，外层监听才会读到新状态。
	manager._alive_by_team[dead_team] = maxi(
		int(manager._alive_by_team.get(dead_team, 0)) - 1,
		0
	)
	var alive_list: Array = manager._team_alive_cache.get(dead_team, [])
	alive_list.erase(dead_unit)
	manager._team_alive_cache[dead_team] = alive_list
	manager._emit_team_alive_count_changed(dead_team)
	manager._remove_unit_runtime_entry(dead_unit)
	manager.unit_died.emit(dead_unit, killer, dead_team)
	manager._finalize_if_needed()


# damage_resolved 的 payload 是对外契约，字段集合不能在拆分时变动。
# `logic_frame` 继续来自 manager 运行时，确保回放和测试断言稳定。
# source/target 均按当前瞬时 team_id 回写，保持旧行为。
func build_damage_event(
	manager,
	source: Node,
	target: Node,
	event_dict: Dictionary
) -> Dictionary:
	return {
		"source_id": source.get_instance_id(),
		"target_id": target.get_instance_id(),
		"source_team": int(source.get("team_id")),
		"target_team": int(target.get("team_id")),
		"is_skill": bool(event_dict.get("is_skill", false)),
		"is_dodged": bool(event_dict.get("is_dodged", false)),
		"is_crit": bool(event_dict.get("is_crit", false)),
		"damage_type": str(event_dict.get("damage_type", "external")),
		"damage": float(event_dict.get("damage", 0.0)),
		"target_hp_after": float(event_dict.get("target_hp_after", 0.0)),
		"target_mp_after": float(event_dict.get("target_mp_after", 0.0)),
		"shield_absorbed": float(event_dict.get("shield_absorbed", 0.0)),
		"immune_absorbed": float(event_dict.get("immune_absorbed", 0.0)),
		"shield_hp_after": float(event_dict.get("shield_hp_after", 0.0)),
		"shield_broken": bool(event_dict.get("shield_broken", false)),
		"logic_frame": manager._logic_frame
	}


# 攻击方向是所有攻击动画和受击动画共享的朝向输入。
# 当 source 与 target 重叠时，兜底返回朝右，保持旧动画可播。
# 这里不引入更复杂的朝向系统，只保持旧口径。
func _build_attack_direction(source: Node, target: Node) -> Vector2:
	var attack_dir: Vector2 = (target.position - source.position).normalized()
	if attack_dir.is_zero_approx():
		return Vector2.RIGHT
	return attack_dir


# 普攻命中统一播放普攻动作，不再在 Combat 基础攻击链里夹带技能施法动画。
# 动画状态编号继续沿用旧资源约定。
func _play_attack_animation(
	source: Node,
	_event_dict: Dictionary,
	attack_dir: Vector2
) -> void:
	var source_api: Variant = source
	source_api.play_anim_state(2, {"direction": attack_dir})


# 命中反馈分成闪避和受击两条分支，顺序完全沿用旧逻辑。
# 闪避时只弹 dodge 字，不播放受击动画和攻击特效。
# 非闪避时同时负责受击动画、攻击特效和伤害数字。
func _play_hit_feedback(
	manager,
	source: Node,
	target: Node,
	event_dict: Dictionary,
	attack_dir: Vector2
) -> void:
	if bool(event_dict.get("is_dodged", false)):
		_spawn_damage_text(manager, target.position, 0.0, false, true)
		return

	var target_api: Variant = target
	target_api.play_anim_state(4, {"direction": attack_dir})
	_play_attack_vfx(manager, source.position, target.position)
	_spawn_damage_text(
		manager,
		target.position,
		float(event_dict.get("damage", 0.0)),
		bool(event_dict.get("is_crit", false)),
		false
	)


# DamageText 仍通过 VFXFactory 统一生成，避免 Combat 再自己实例化 UI/VFX 节点。
# `is_dodge` 为 true 时 amount 固定按旧逻辑传 0。
# 如果当前场景没有挂 VFXFactory，则直接静默跳过。
func _spawn_damage_text(
	manager,
	world_pos: Vector2,
	amount: float,
	is_crit: bool,
	is_dodge: bool
) -> void:
	var vfx_factory: Node = manager._vfx_factory
	if vfx_factory == null or not is_instance_valid(vfx_factory):
		return
	var vfx_api: Variant = vfx_factory
	vfx_api.spawn_damage_text(world_pos, amount, is_crit, is_dodge)


# 当前攻击链只保留一条剑气特效资源 id，保持旧表现。
# 如果未来需要按武器或伤害类型拆分，应在更上层决策后再扩。
# 这里不做资源选择逻辑，只承接旧的播放动作。
func _play_attack_vfx(
	manager,
	from_pos: Vector2,
	to_pos: Vector2
) -> void:
	var vfx_factory: Node = manager._vfx_factory
	if vfx_factory == null or not is_instance_valid(vfx_factory):
		return
	var vfx_api: Variant = vfx_factory
	vfx_api.play_attack_vfx("vfx_sword_qi", from_pos, to_pos)
