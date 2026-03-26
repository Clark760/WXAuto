extends RefCounted
class_name UnitAugmentTriggerExecutionService

var _next_source_bound_aura_scope_token: int = 1


# passive_aura 的 scope token 必须按战斗重置，避免跨战斗串状态。
# 这个计数器只服务 source_bound_aura 生命周期，不参与普通 trigger 逻辑。
# 同一个 provider 的多条光环 entry 会各自分配稳定 token，避免跨技能串 scope。
func reset_battle_counters() -> void:
	_next_source_bound_aura_scope_token = 1


# 真正执行技能时，这个服务负责扣 MP、补目标、发日志和推进冷却。
# `entry` 是稳定 trigger entry，函数内部允许更新它的冷却和计数状态。
# `event_context` 只承载本次触发来源，不会替代 battle runtime 的全局上下文。
func try_fire_skill(manager: Node, source: Node, entry: Dictionary, event_context: Dictionary) -> bool:
	var state_service: Variant = manager.get_state_service()
	var battle_runtime: Variant = manager.get_battle_runtime()
	var effect_engine: Variant = manager.get_effect_engine()
	var buff_manager: Variant = manager.get_buff_manager()
	var target_service: Variant = manager.get_skill_target_service()
	var telemetry: Variant = manager.get_telemetry_emitter()

	if source == null or not is_instance_valid(source):
		return false
	if not state_service.is_unit_alive(source):
		return false
	# 概率判定放在最早阶段，确保随机失败不会污染目标选择和 aura scope 状态。
	if not _passes_trigger_chance(entry):
		return false

	var skill_data: Dictionary = entry.get("skill_data", {})
	var effects_value: Variant = skill_data.get("effects", [])
	if not (effects_value is Array):
		return false
	var effect_list: Array = effects_value as Array

	# 目标选择统一在执行前完成，避免 effect engine 里再重复写选敌逻辑。
	# 这样 effect engine 拿到的一定是“已经补齐目标”的执行上下文。
	var target: Node = _resolve_skill_target(
		state_service,
		battle_runtime,
		target_service,
		source,
		skill_data,
		effect_list,
		event_context,
		manager.DEFAULT_SKILL_CAST_RANGE_CELLS
	)
	if target == null:
		return false

	var trigger_name: String = str(entry.get("trigger", "")).strip_edges().to_lower()
	# effect context 是本次执行的共享上下文，后面 gate、effect engine 和 telemetry 都会复用它。
	var execution_context: Dictionary = build_effect_context(manager, source, target, event_context)
	_prepare_passive_aura_scope(trigger_name, source, entry, execution_context)

	# tag_linkage_branch 需要先算 gate map，其他 op 直接略过这一步。
	# 这一步只做准入判定，不在这里执行任何 tag_linkage 分支逻辑。
	var linkage_gate_result: Dictionary = _build_tag_linkage_gate_map(
		manager,
		source,
		effect_list,
		execution_context
	)
	execution_context["tag_linkage_gate_map"] = linkage_gate_result.get("gate_map", {})
	if bool(linkage_gate_result.get("has_only_tag_linkage", false)) \
	and not bool(linkage_gate_result.get("has_allowed_tag_linkage", false)):
		return false

	# MP 真正扣除发生在一切准入条件之后，避免失败分支白白消耗资源。
	if not _consume_trigger_mp_cost(source, entry):
		return false

	# 到这里说明已经具备完整 target/context，可直接把 effect 序列交给统一 effect engine 执行。
	# 执行服务本身不解析单个 op，所有效果细节都继续下沉在 effect engine 内部。
	var execution_summary: Dictionary = effect_engine.execute_active_effects(
		source,
		target,
		effect_list,
		execution_context
	)
	_finalize_passive_aura_scope(buff_manager, trigger_name, execution_context)

	# summary -> 外部信号 payload 的映射统一收口到 telemetry emitter。
	# trigger execution service 只产出 summary，不直接拼 UI/日志侧 payload。
	telemetry.emit_effect_log_events(
		manager,
		manager.get_registry(),
		execution_summary,
		source,
		target,
		"skill",
		str(entry.get("gongfa_id", "")),
		str(entry.get("trigger", "")),
		{"event_type": "apply"}
	)

	_play_skill_vfx(battle_runtime, skill_data, source, target)
	_play_skill_animation(source)
	_update_trigger_timing(battle_runtime, entry, skill_data, trigger_name)
	manager.skill_triggered.emit(source, str(entry.get("gongfa_id", "")), str(entry.get("trigger", "")))
	return true


# 外部效果入口继续保留旧契约，但上下文里的系统级 manager 已切到 UnitAugment。
# 这个入口不关心 trigger entry，只处理“给定 source/target/effects 立即执行”。
# `meta` 只负责日志归因字段，不参与 effect engine 的行为判定。
func execute_external_effects(
	manager: Node,
	source: Node,
	target: Node,
	effects: Array,
	context: Dictionary,
	meta: Dictionary = {}
) -> Dictionary:
	if effects.is_empty():
		return {
			"damage_total": 0.0,
			"heal_total": 0.0,
			"mp_total": 0.0,
			"summon_total": 0,
			"hazard_total": 0,
			"buff_applied": 0,
			"debuff_applied": 0,
			"damage_events": [],
			"heal_events": [],
			"mp_events": [],
			"buff_events": []
		}

	var execution_context: Dictionary = context.duplicate(false)
	# 这里统一补齐 effect engine 运行期必需的公共上下文字段。
	# 调用方如果显式传入同名字段，会保持外层优先，不会被这里覆盖。
	if not execution_context.has("all_units"):
		execution_context["all_units"] = manager.get_state_service().get_battle_units()
	if not execution_context.has("combat_manager"):
		execution_context["combat_manager"] = manager.get_battle_runtime().get_bound_combat_manager()
	if not execution_context.has("hex_grid"):
		execution_context["hex_grid"] = manager.get_battle_runtime().get_bound_hex_grid()
	if not execution_context.has("hex_size"):
		var hex_grid: Node = manager.get_battle_runtime().get_bound_hex_grid()
		execution_context["hex_size"] = hex_grid.get("hex_size") if hex_grid != null else 26.0
	if not execution_context.has("buff_manager"):
		execution_context["buff_manager"] = manager.get_buff_manager()
	if not execution_context.has("battle_elapsed"):
		execution_context["battle_elapsed"] = manager.get_battle_runtime().get_battle_elapsed()
	if not execution_context.has("tag_linkage_scheduler"):
		execution_context["tag_linkage_scheduler"] = manager.get_tag_linkage_scheduler()
	if not execution_context.has("tag_linkage_stagger_buckets"):
		execution_context["tag_linkage_stagger_buckets"] = manager.tag_linkage_stagger_buckets
	# 系统级外部效果也统一写入 unit_augment_manager，避免 effect engine 再兼容旧 manager 名。
	execution_context["unit_augment_manager"] = manager

	# 外部效果和技能效果共用同一套 execute_active_effects 入口，只是日志归因字段来自 meta。
	var summary: Dictionary = manager.get_effect_engine().execute_active_effects(
		source,
		target,
		effects,
		execution_context
	)
	var origin: String = str(meta.get("origin", "external_effect")).strip_edges()
	if origin.is_empty():
		origin = "external_effect"
	var trigger: String = str(meta.get("trigger", origin)).strip_edges()
	if trigger.is_empty():
		trigger = origin
	var gongfa_id: String = str(meta.get("gongfa_id", "")).strip_edges()
	var extra_fields: Dictionary = {}
	var extra_value: Variant = meta.get("extra_fields", {})
	if extra_value is Dictionary:
		extra_fields = (extra_value as Dictionary).duplicate(true)

	manager.get_telemetry_emitter().emit_effect_log_events(
		manager,
		manager.get_registry(),
		summary,
		source,
		target,
		origin,
		gongfa_id,
		trigger,
		extra_fields
	)
	return summary


# `event_context` 是触发来源的原始事件快照，这里只负责装配运行时公共上下文。
# 返回值会被 effect engine、tag linkage 和 telemetry 共同复用。
# `battlefield` / `unit_factory` 仍通过 CombatManager 反查，避免 effect 层直接扫场景树。
func build_effect_context(manager: Node, source: Node, target: Node, event_context: Dictionary) -> Dictionary:
	var battle_runtime: Variant = manager.get_battle_runtime()
	var battlefield_node: Node = null
	var unit_factory_node: Node = null
	var combat_manager: Node = battle_runtime.get_bound_combat_manager()
	if combat_manager != null and is_instance_valid(combat_manager):
		# battlefield / unit_factory 仍是少数旧 effect 的兼容依赖，暂时通过运行时网关补进 context。
		battlefield_node = combat_manager.get_parent()
		if battlefield_node != null and is_instance_valid(battlefield_node):
			unit_factory_node = battlefield_node.get_node_or_null("UnitFactory")

	var hex_grid: Node = battle_runtime.get_bound_hex_grid()
	# 返回字典保持扁平结构，目的是让 effect handler 和 telemetry 读取字段时不需要层层解包。
	return {
		"source": source,
		"target": target,
		"event_context": event_context,
		"all_units": manager.get_state_service().get_battle_units(),
		"hex_size": hex_grid.get("hex_size") if hex_grid != null else 26.0,
		"hex_grid": hex_grid,
		"vfx_factory": battle_runtime.get_bound_vfx_factory(),
		"buff_manager": manager.get_buff_manager(),
		"unit_augment_manager": manager,
		"battlefield": battlefield_node,
		"combat_manager": combat_manager,
		"unit_factory": unit_factory_node,
		"battle_elapsed": battle_runtime.get_battle_elapsed(),
		"tag_linkage_scheduler": manager.get_tag_linkage_scheduler(),
		"tag_linkage_stagger_buckets": manager.tag_linkage_stagger_buckets
	}


# 触发概率只在真正执行前判一次，避免前置状态被随机失败污染。
# 这里不缓存随机结果，每次尝试执行都会重新判定。
# 概率值统一钳到 0~1，避免配置越界后出现不可预期表现。
func _passes_trigger_chance(entry: Dictionary) -> bool:
	var chance: float = clampf(float(entry.get("chance", 1.0)), 0.0, 1.0)
	return chance >= 1.0 or randf() <= chance


# 目标选择统一处理“是否需要敌方目标”和“是否在技能射程内”。
# `state_service` 提供存活判定，`target_service` 提供选敌和射程口径。
# `event_context.target` 如果已经给出合法目标，会优先复用，避免重复选敌抖动。
func _resolve_skill_target(
	state_service: Variant,
	battle_runtime: Variant,
	target_service: Variant,
	source: Node,
	skill_data: Dictionary,
	effect_list: Array,
	event_context: Dictionary,
	default_range_cells: float
) -> Node:
	var target: Node = event_context.get("target", null)
	if not target_service.skill_requires_enemy_target(effect_list):
		if target == null or not is_instance_valid(target):
			return source
		return target

	var skill_range_cells: float = target_service.resolve_skill_cast_range_cells(
		source,
		skill_data,
		default_range_cells
	)
	if not target_service.is_valid_enemy_target(
		source,
		target,
		state_service
	):
		target = null
	if target != null and is_instance_valid(target):
		if not target_service.is_target_in_skill_range(
			source,
			target,
			skill_range_cells,
			battle_runtime.get_bound_hex_grid()
		):
			target = null
	if target == null:
		target = target_service.pick_nearest_enemy_in_range(
			state_service.get_battle_units(),
			source,
			skill_range_cells,
			battle_runtime.get_bound_hex_grid(),
			state_service
		)
	return target


# passive_aura 需要稳定 scope key/token，供 BuffManager 做 enter/exit diff。
# `entry_uid` 会回写到 trigger entry，确保同一技能在多次轮询中保持稳定身份。
# scope key 由 source instance_id 和 entry_uid 组成，避免不同 aura 技能相互串状态。
func _prepare_passive_aura_scope(
	trigger_name: String,
	source: Node,
	entry: Dictionary,
	execution_context: Dictionary
) -> void:
	if trigger_name != "passive_aura":
		return

	var entry_uid: int = int(entry.get("entry_uid", 0))
	if entry_uid <= 0:
		entry_uid = int(Time.get_ticks_usec() % 1000000) + source.get_instance_id()
		entry["entry_uid"] = entry_uid

	execution_context["source_bound_aura_scope_key"] = "%d|%d" % [
		source.get_instance_id(),
		entry_uid
	]
	execution_context["source_bound_aura_scope_token"] = _next_source_bound_aura_scope_token
	_next_source_bound_aura_scope_token += 1


# MP 扣除只集中在这里做一次，避免 trigger 分支自己反复触碰 UnitCombat。
# 返回 false 表示当前 MP 不足，调用方必须直接中止后续 effect 执行。
# 这里是唯一真正修改 current_mp 的位置，条件服务只负责“能不能放”。
func _consume_trigger_mp_cost(source: Node, entry: Dictionary) -> bool:
	var mp_cost: float = float(entry.get("mp_cost", 0.0))
	if mp_cost <= 0.0:
		return true

	var combat: Node = source.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return false
	if float(combat.get("current_mp")) < mp_cost:
		return false
	combat.add_mp(-mp_cost)
	return true


# passive_aura 结束后要把本轮 scope 的命中集合回写给 BuffManager。
# 普通 trigger 不会进入这个收尾分支。
# enter/exit diff 的最终生效点在 BuffManager，这里只负责把 scope 元数据交回去。
func _finalize_passive_aura_scope(
	buff_manager: Variant,
	trigger_name: String,
	execution_context: Dictionary
) -> void:
	if trigger_name != "passive_aura":
		return
	buff_manager.finalize_source_bound_aura_scope(
		str(execution_context.get("source_bound_aura_scope_key", "")).strip_edges(),
		int(execution_context.get("source_bound_aura_scope_token", 0)),
		execution_context
	)


# 技能特效播放只读取 skill_data.vfx_id，不把动画细节混进 effect engine。
# 这里的 from/to 坐标只服务表现层，不参与任何判定逻辑。
# 如果 target 缺失，就把 from/to 都落在 source 上，表现层自己决定如何兜底。
func _play_skill_vfx(
	battle_runtime: Variant,
	skill_data: Dictionary,
	source: Node,
	target: Node
) -> void:
	var skill_vfx: String = str(skill_data.get("vfx_id", "")).strip_edges()
	var vfx_factory: Node = battle_runtime.get_bound_vfx_factory()
	if skill_vfx.is_empty() or vfx_factory == null:
		return

	var from_pos: Vector2 = (source as Node2D).position
	var to_pos: Vector2 = from_pos
	if target != null and is_instance_valid(target):
		to_pos = (target as Node2D).position
	vfx_factory.play_attack_vfx(skill_vfx, from_pos, to_pos)


# 当前版本统一复用攻击动画状态 3，后续有专用施法动画时再单点替换。
# 这里故意不做动画可用性判断，缺失时由单位脚本自己兜底。
# 动画触发留在执行服务，而不是 effect engine，避免纯规则层带表现依赖。
func _play_skill_animation(source: Node) -> void:
	source.play_anim_state(3, {})


# cooldown、periodic 和一次性时间触发的状态推进都在这里统一写回。
# 执行完成后的 trigger entry 状态必须只在这里更新，避免多处分散写回。
# `battle_runtime.get_battle_elapsed()` 是所有时间型 trigger 的统一时间基准。
func _update_trigger_timing(
	battle_runtime: Variant,
	entry: Dictionary,
	skill_data: Dictionary,
	trigger_name: String
) -> void:
	if trigger_name == "periodic_seconds" or trigger_name == "periodic":
		# 周期型 trigger 的下一次 ready 时间按“当前战斗时间 + interval”推进。
		var trigger_params: Dictionary = {}
		var trigger_params_value: Variant = entry.get("trigger_params", {})
		if trigger_params_value is Dictionary:
			trigger_params = trigger_params_value as Dictionary
		var interval_seconds: float = maxf(
			float(trigger_params.get("interval", skill_data.get("interval", 0.0))),
			0.05
		)
		entry["next_periodic_time"] = battle_runtime.get_battle_elapsed() + interval_seconds
	elif trigger_name == "on_time_elapsed":
		# 一次性时间 trigger 只写 fired 标记，不再安排下一次时间点。
		entry["time_elapsed_fired"] = true

	# 所有成功执行的 trigger 都会统一累加 trigger_count 并刷新 cooldown。
	entry["trigger_count"] = int(entry.get("trigger_count", 0)) + 1
	entry["next_ready_time"] = battle_runtime.get_battle_elapsed() + float(entry.get("cooldown", 0.0))


# tag_linkage_branch 需要预先算 gate map，避免 effect engine 内部重复评估 gate。
# 返回值里同时带出“是否全是 tag_linkage”与“是否存在允许分支”两个布尔量。
# gate map 的 key 必须稳定对应到单条 effect 配置，否则同帧多个分支会串结果。
func _build_tag_linkage_gate_map(
	manager: Node,
	source: Node,
	effect_list: Array,
	context: Dictionary
) -> Dictionary:
	var gate_map: Dictionary = {}
	var has_tag_linkage: bool = false
	var has_non_tag: bool = false
	var has_allowed: bool = false

	for effect_value in effect_list:
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value as Dictionary
		if not _is_tag_linkage_effect_entry(effect):
			has_non_tag = true
			continue
		has_tag_linkage = true
		# gate key 必须和具体 effect 配置一一对应，避免不同分支错误复用允许结果。
		var effect_key: String = _tag_linkage_effect_key(effect)
		var gate: Dictionary = manager.evaluate_tag_linkage_gate(source, effect, context)
		var allowed: bool = bool(gate.get("allowed", true))
		gate_map[effect_key] = allowed
		if allowed:
			has_allowed = true

	return {
		"gate_map": gate_map,
		"has_tag_linkage": has_tag_linkage,
		"has_only_tag_linkage": has_tag_linkage and not has_non_tag,
		"has_allowed_tag_linkage": has_allowed
	}


# 这里的 `op` 判定只用于触发前的 gate map 预处理。
# 其他 effect 类型不会经过这条特殊逻辑。
# 这层 helper 的职责只是识别入口，不承担 branch 配置合法性校验。
func _is_tag_linkage_effect_entry(effect: Dictionary) -> bool:
	return str(effect.get("op", "")).strip_edges() == "tag_linkage_branch"


# 用完整 effect 序列化值做 key，避免不同 case 共用同一 gate 结果。
# key 的目标是稳定区分 effect 配置，不追求人工可读。
# 这里故意不用 op/case_id 之类短键，防止不同配置误命中同一 gate 结果。
func _tag_linkage_effect_key(effect: Dictionary) -> String:
	return var_to_str(effect)
