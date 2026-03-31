extends RefCounted
class_name UnitAugmentTriggerConditionService

const COMBAT_TEAM_ALLY: int = 1
const COMBAT_TEAM_ENEMY: int = 2


# 这个入口只回答“当前 entry 此刻能否触发”，不执行任何效果。
# `manager` 只用来取 battle runtime 和 state service，不在这里缓存运行时依赖。
# `event_context` 是外部事件快照；轮询型 trigger 传入的通常是空字典。
func can_trigger_entry(
	manager: Node,
	unit: Node,
	entry: Dictionary,
	event_context: Dictionary = {}
) -> bool:
	var battle_runtime: Variant = manager.get_battle_runtime()
	var state_service: Variant = manager.get_state_service()
	var trigger: String = str(entry.get("trigger", "")).strip_edges().to_lower()

	# 第一层先过“时间与次数”硬门槛，失败时不值得再做更细条件判断。
	if not _passes_trigger_readiness(battle_runtime, entry):
		return false

	var trigger_params: Dictionary = {}
	var trigger_params_value: Variant = entry.get("trigger_params", {})
	if trigger_params_value is Dictionary:
		trigger_params = trigger_params_value as Dictionary

	# 队伍人数过滤先于任何触发细节，避免后面的阈值判断白算。
	# 队伍人数属于外层环境条件，放在这里提前剪枝能减少后面重复读 HP/事件字段。
	if not _passes_trigger_team_alive_conditions(manager, unit, trigger_params, event_context):
		return false

	# 统一把 skill_data 提前取出来，后续每类 trigger 都按“trigger_params 优先，skill_data 兜底”的口径读值。
	var skill_data: Dictionary = entry.get("skill_data", {})
	if not _passes_enemy_nearby_requirement(manager, unit, trigger_params, skill_data, event_context):
		return false
	# 下面的分支按 trigger 名逐类路由，每类 helper 都只关心自己那一种条件语义。

	# 资源型自动触发只校验 MP，不依赖事件上下文。
	if trigger == "auto_mp_full" or trigger == "manual":
		return _has_enough_mp_for_trigger(state_service, unit, entry)

	# 生命相关触发分成电平型和边沿型，两者不能混在一起处理。
	if trigger == "auto_hp_below":
		return _can_auto_hp_below(state_service, unit, entry, skill_data)
	if trigger == "on_hp_below":
		return _can_on_hp_below(state_service, unit, entry, trigger_params, skill_data)

	# 时间轴触发会读 battle_elapsed，并在执行后推进自身状态。
	if trigger == "on_time_elapsed":
		return _can_on_time_elapsed(
			battle_runtime,
			state_service,
			unit,
			entry,
			trigger_params,
			skill_data
		)
	if trigger == "periodic_seconds" or trigger == "periodic":
		return _can_periodic_trigger(
			battle_runtime,
			state_service,
			unit,
			entry,
			trigger_params,
			skill_data
		)

	# 这两个事件只要求上下文里带出显式布尔标志。
	if trigger == "on_crit":
		return _can_boolean_event_trigger(state_service, unit, entry, event_context, "is_crit")
	if trigger == "on_dodge":
		return _can_boolean_event_trigger(state_service, unit, entry, event_context, "is_dodged")

	# Buff/Debuff 事件需要额外比对具体 id。
	if trigger == "on_debuff_applied":
		return _can_on_debuff_applied(
			state_service,
			unit,
			entry,
			trigger_params,
			skill_data,
			event_context
		)
	if trigger == "on_buff_expired":
		return _can_on_buff_expired(
			state_service,
			unit,
			entry,
			trigger_params,
			skill_data,
			event_context
		)

	# 失败原因类触发统一复用一套 reason filter。
	if trigger == "on_attack_fail" or trigger == "on_unit_move_failed":
		return _can_reason_filtered_trigger(
			state_service,
			unit,
			entry,
			trigger_params,
			event_context
		)

	# 数值阈值型事件共用一个 helper，避免 damage/heal/thorns 三套重复。
	if trigger == "on_damage_received":
		return _can_threshold_event_trigger(
			state_service,
			unit,
			entry,
			trigger_params,
			event_context,
			"min_damage",
			"damage"
		)
	if trigger == "on_heal_received":
		return _can_threshold_event_trigger(
			state_service,
			unit,
			entry,
			trigger_params,
			event_context,
			"min_heal",
			"heal",
			"amount"
		)
	if trigger == "on_thorns_triggered":
		return _can_threshold_event_trigger(
			state_service,
			unit,
			entry,
			trigger_params,
			event_context,
			"min_reflect",
			"reflect_damage",
			"damage"
		)

	# 地形相关 trigger 统一走 terrain_tags_any/all 过滤。
	if trigger == "on_terrain_created" \
	or trigger == "on_terrain_enter" \
	or trigger == "on_terrain_tick" \
	or trigger == "on_terrain_exit" \
	or trigger == "on_terrain_expire":
		return _can_terrain_trigger(
			state_service,
			unit,
			entry,
			trigger_params,
			event_context
		)

	# 光环轮询只要轮到就执行，生命周期由 BuffManager 负责收口。
	if trigger == "passive_aura":
		return true

	# 其余 on_* 事件只要 MP 足够就视为合法命中。
	if trigger.begins_with("on_"):
		return _has_enough_mp_for_trigger(state_service, unit, entry)
	return false


# 冷却和最大次数是所有 trigger 共享的最外层门槛。
# `battle_runtime` 提供 battle_elapsed，`entry` 持有每条 trigger 的自身计时状态。
# 只要这里失败，后续更细的 HP、事件或地形条件都不再评估。
func _passes_trigger_readiness(battle_runtime: Variant, entry: Dictionary) -> bool:
	if battle_runtime.get_battle_elapsed() < float(entry.get("next_ready_time", 0.0)):
		return false
	var max_trigger_count: int = int(entry.get("max_trigger_count", 0))
	if max_trigger_count > 0 and int(entry.get("trigger_count", 0)) >= max_trigger_count:
		return false
	return true


# auto_hp_below 是电平触发，只要当前低于阈值且 MP 足够就允许施放。
# `skill_data.threshold` 是技能配置阈值，未配置时回退到 30% 血线。
# 这个 trigger 不看边沿状态，因此持续低血时会在冷却结束后重复触发。
func _can_auto_hp_below(
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	skill_data: Dictionary
) -> bool:
	var threshold: float = clampf(float(skill_data.get("threshold", 0.3)), 0.01, 0.95)
	var hp_now: float = state_service.get_combat_value(unit, "current_hp")
	var hp_max: float = maxf(state_service.get_combat_value(unit, "max_hp"), 1.0)
	if hp_now / hp_max > threshold:
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# on_hp_below 只在状态从“未低于阈值”切换到“已低于阈值”时命中一次。
# `trigger_params.threshold` 优先级高于 `skill_data.threshold`，兼容旧技能写法。
# `entry.last_hp_below_state` 是边沿检测状态，必须在判定时同步写回。
func _can_on_hp_below(
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	trigger_params: Dictionary,
	skill_data: Dictionary
) -> bool:
	var hp_threshold: float = 0.3
	if trigger_params.has("threshold"):
		hp_threshold = clampf(float(trigger_params.get("threshold", 0.3)), 0.01, 0.95)
	elif skill_data.has("threshold"):
		hp_threshold = clampf(float(skill_data.get("threshold", 0.3)), 0.01, 0.95)

	var hp_now: float = state_service.get_combat_value(unit, "current_hp")
	var hp_max: float = maxf(state_service.get_combat_value(unit, "max_hp"), 1.0)
	var is_below: bool = hp_now / hp_max <= hp_threshold
	var was_below: bool = bool(entry.get("last_hp_below_state", false))
	entry["last_hp_below_state"] = is_below
	if not (is_below and not was_below):
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# 一次性时间触发在命中后会由执行层写回 fired 标记。
# `at_seconds` 支持写在 trigger_params 或 skill_data，语义都是战斗开始后的绝对秒数。
# 这里只判断“是否到点且尚未触发过”，不推进任何下一次时间。
func _can_on_time_elapsed(
	battle_runtime: Variant,
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	trigger_params: Dictionary,
	skill_data: Dictionary
) -> bool:
	var at_seconds: float = maxf(
		float(trigger_params.get("at_seconds", skill_data.get("at_seconds", -1.0))),
		-1.0
	)
	if at_seconds < 0.0:
		return false
	if battle_runtime.get_battle_elapsed() < at_seconds:
		return false
	if bool(entry.get("time_elapsed_fired", false)):
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# periodic 系列只校验是否到时，下一次时间由执行层推进。
# `interval` 最小钳到 0.05，避免配置成 0 后在单帧里无限触发。
# 周期型 trigger 的实际下一次触发时刻由执行层写回 `entry.next_periodic_time`。
func _can_periodic_trigger(
	battle_runtime: Variant,
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	trigger_params: Dictionary,
	skill_data: Dictionary
) -> bool:
	var interval: float = maxf(
		float(trigger_params.get("interval", skill_data.get("interval", 0.0))),
		0.05
	)
	var next_time: float = float(entry.get("next_periodic_time", interval))
	if next_time <= 0.0:
		next_time = interval
	if battle_runtime.get_battle_elapsed() < next_time:
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# 布尔上下文事件只要求上下文里显式带出对应标志。
# `flag_key` 由调用方显式传入，例如 `is_crit` 或 `is_dodged`。
# 这里只判断布尔命中与 MP，不负责生成事件上下文本身。
func _can_boolean_event_trigger(
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	event_context: Dictionary,
	flag_key: String
) -> bool:
	if not bool(event_context.get(flag_key, false)):
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# on_debuff_applied 允许配具体 debuff_id，也允许“任意 debuff 触发”。
# `event_context.debuff_id` 来自 telemetry/buff 事件桥接，缺失时直接判定失败。
# 如果配置里没写具体 debuff_id，就把任意 debuff 命中都视为合法触发。
func _can_on_debuff_applied(
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	trigger_params: Dictionary,
	skill_data: Dictionary,
	event_context: Dictionary
) -> bool:
	var debuff_id: String = str(event_context.get("debuff_id", "")).strip_edges()
	if debuff_id.is_empty():
		return false
	var required_debuff: String = str(
		trigger_params.get("debuff_id", skill_data.get("debuff_id", ""))
	).strip_edges()
	if not required_debuff.is_empty() and debuff_id != required_debuff:
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# on_buff_expired 兼容 watch_buff_id 和旧 buff_id 两种字段口径。
# `removed_buff_id` 是 BuffManager 删除时写回的实际 Buff 身份。
# 这里保留旧字段兼容，只为了迁移期不改现有数据口径。
func _can_on_buff_expired(
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	trigger_params: Dictionary,
	skill_data: Dictionary,
	event_context: Dictionary
) -> bool:
	var removed_buff_id: String = str(event_context.get("removed_buff_id", "")).strip_edges()
	if removed_buff_id.is_empty():
		return false
	var watch_buff_id: String = str(
		trigger_params.get("watch_buff_id", skill_data.get("watch_buff_id", ""))
	).strip_edges()
	if watch_buff_id.is_empty():
		watch_buff_id = str(
			trigger_params.get("buff_id", skill_data.get("buff_id", ""))
		).strip_edges()
	if watch_buff_id.is_empty():
		return false
	if removed_buff_id != watch_buff_id:
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# 失败原因筛选被 attack_fail 和 move_failed 两类 trigger 共用。
# `trigger_params` 里的 reasons/filter 规则统一在 helper 里归一化。
# 这个入口只处理失败原因，不读取其他数值阈值字段。
func _can_reason_filtered_trigger(
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	trigger_params: Dictionary,
	event_context: Dictionary
) -> bool:
	if not _matches_reason_filter(trigger_params, event_context, "reason"):
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# 数值阈值触发统一走 threshold/value 读取，不再各写一版最小值判断。
# `threshold_key` 指向配置里的最小门槛字段，`value_key` 指向事件里的主数值字段。
# `fallback_value_key` 用于兼容 heal/reflect 等旧事件字段名。
func _can_threshold_event_trigger(
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	trigger_params: Dictionary,
	event_context: Dictionary,
	threshold_key: String,
	value_key: String,
	fallback_value_key: String = ""
) -> bool:
	var threshold: float = maxf(float(trigger_params.get(threshold_key, 0.0)), 0.0)
	var value: float = maxf(float(event_context.get(value_key, 0.0)), 0.0)
	if value <= 0.0 and not fallback_value_key.is_empty():
		value = maxf(float(event_context.get(fallback_value_key, 0.0)), 0.0)
	if value < threshold:
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# terrain 系列 trigger 先过标签过滤，再复用统一 MP 判定。
# 地形事件的结构由 TerrainManager/Combat 事件桥接给出，这里只消费统一字段。
# 一旦 terrain tag 不匹配，就不会再继续做资源判定。
func _can_terrain_trigger(
	state_service: Variant,
	unit: Node,
	entry: Dictionary,
	trigger_params: Dictionary,
	event_context: Dictionary
) -> bool:
	if not _passes_terrain_tag_filters(trigger_params, event_context):
		return false
	return _has_enough_mp_for_trigger(state_service, unit, entry)


# MP 检查统一收口，避免不同 trigger 分支各自去读 current_mp。
# `entry.mp_cost` 是 trigger 触发成本，不区分主动释放还是被动反应。
# 所有条件分支最终都收口到这里，保持内力口径一致。
func _has_enough_mp_for_trigger(state_service: Variant, unit: Node, entry: Dictionary) -> bool:
	var mp_cost: float = float(entry.get("mp_cost", 0.0))
	return state_service.get_combat_value(unit, "current_mp") >= mp_cost


# reason 过滤支持空数组表示“不限制原因”，兼容旧配置。
# `reason_key` 允许调用方复用这套逻辑到不同上下文字段，而不硬编码成 `reason`。
# 只要配置数组为空，就等价于“不做失败原因过滤”。
func _matches_reason_filter(trigger_params: Dictionary, event_context: Dictionary, reason_key: String) -> bool:
	var reason_value: String = str(event_context.get(reason_key, "")).strip_edges().to_lower()
	var reasons_value: Variant = trigger_params.get("reasons", [])
	if not (reasons_value is Array):
		return true
	var normalized: Array[String] = _normalize_string_filter_array(reasons_value)
	if normalized.is_empty():
		return true
	return normalized.has(reason_value)


# 地形事件只认 terrain_tags_any/all 两组过滤字段，不额外做别名兼容。
# `event_context.terrain_tags` 应该已经是当前地形的 tags 快照，这里不再追溯 terrain 定义。
# any/all 两组过滤可以同时存在，语义是“先满足任一，再满足全部”。
func _passes_terrain_tag_filters(trigger_params: Dictionary, event_context: Dictionary) -> bool:
	var terrain_tags: Array[String] = []
	var tags_value: Variant = event_context.get("terrain_tags", [])
	if tags_value is Array:
		# terrain_tags 统一在这里做小写去重，避免 any/all 两种过滤重复归一化。
		for tag_value in (tags_value as Array):
			var tag: String = str(tag_value).strip_edges().to_lower()
			if tag.is_empty():
				continue
			if not terrain_tags.has(tag):
				terrain_tags.append(tag)

	var any_filter: Array[String] = _normalize_string_filter_array(
		trigger_params.get("terrain_tags_any", [])
	)
	if not any_filter.is_empty():
		# any 过滤要求至少命中一个标签，适合“火焰或毒沼任一地形触发”这类配置。
		var matched_any: bool = false
		for tag_any in any_filter:
			if terrain_tags.has(tag_any):
				matched_any = true
				break
		if not matched_any:
			return false

	var all_filter: Array[String] = _normalize_string_filter_array(
		trigger_params.get("terrain_tags_all", [])
	)
	# all 过滤要求全部命中，常用于“必须同时具备多种 terrain tag”的精细条件。
	for tag_all in all_filter:
		if not terrain_tags.has(tag_all):
			return false
	return true


# 队伍人数门槛用于残局类触发，例如“仅剩 1 名队友时触发”。
# `team_scope` 决定统计己方、敌方还是双方；`exclude_self` 控制是否把自己算进人数。
# 这层过滤放在最前面，避免后续 HP/地形判断在明显不满足的人数场景下白跑。
func _passes_trigger_team_alive_conditions(
	manager: Node,
	unit: Node,
	trigger_params: Dictionary,
	event_context: Dictionary = {}
) -> bool:
	var has_min_alive: bool = trigger_params.has("team_alive_at_least") \
		or trigger_params.has("team_alive_count_min")
	var has_max_alive: bool = trigger_params.has("team_alive_at_most") \
		or trigger_params.has("team_alive_count_max")
	var min_alive: int = int(
		trigger_params.get("team_alive_at_least", trigger_params.get("team_alive_count_min", 0))
	)
	var max_alive: int = int(
		trigger_params.get("team_alive_at_most", trigger_params.get("team_alive_count_max", 0))
	)
	# `team_alive_at_most = 0` 是“除自己外一个队友都不能活着”的合法配置。
	# 这里必须按“字段是否显式出现”判断条件是否启用，不能再把 0 当成“未配置”。
	if not has_min_alive and not has_max_alive:
		return true

	var team_scope: String = str(
		trigger_params.get("team_scope", trigger_params.get("team_alive_scope", "ally"))
	).strip_edges().to_lower()
	var exclude_self: bool = bool(trigger_params.get("exclude_self", false))
	# team_scope 和 exclude_self 的解释统一收口到这里，其他 trigger 不再重复实现人数统计。
	var alive_count: int = _resolve_team_alive_count_for_trigger(
		manager,
		unit,
		team_scope,
		exclude_self,
		event_context
	)
	if has_min_alive and alive_count < min_alive:
		return false
	if has_max_alive and alive_count > max_alive:
		return false
	return true


# 实际存活数继续从 UnitAugment battle_units 视图读取，不扫场景树。
# `team_scope` 已经在上一层归一化，这里只做遍历和计数，不再读配置字段。
# `exclude_self` 主要服务“除自己外仅剩 N 名单位”这类残局触发。
func _resolve_team_alive_count_for_trigger(
	manager: Node,
	unit: Node,
	team_scope: String,
	exclude_self: bool,
	event_context: Dictionary = {}
) -> int:
	var state_service: Variant = manager.get_state_service()
	var team_ids: Array[int] = _resolve_trigger_team_ids(unit, team_scope)
	if event_context.has("_ua_alive_by_team"):
		var cached_counts: Variant = event_context.get("_ua_alive_by_team", {})
		if cached_counts is Dictionary:
			var alive_count_from_cache: int = 0
			for team_id in team_ids:
				alive_count_from_cache += int((cached_counts as Dictionary).get(team_id, 0))
			if exclude_self and state_service.is_unit_alive(unit) and team_ids.has(int(unit.get("team_id"))):
				alive_count_from_cache -= 1
			return maxi(alive_count_from_cache, 0)
	var alive_count: int = 0
	var battle_units_value: Variant = event_context.get("_ua_battle_units", state_service.get_battle_units())
	var battle_units: Array = battle_units_value if battle_units_value is Array else state_service.get_battle_units()
	for battle_unit in battle_units:
		# 这里只统计 UnitAugment 已登记的战斗单位，不碰场景树中的其他临时节点。
		if battle_unit == null or not is_instance_valid(battle_unit):
			continue
		if not team_ids.has(int(battle_unit.get("team_id"))):
			continue
		if exclude_self and battle_unit == unit:
			continue
		if state_service.is_unit_alive(battle_unit):
			alive_count += 1
	return alive_count


# team_scope 只支持 ally/enemy/both 和显式 team_id 三类口径。
# 显式数字 team_id 允许未来扩展更多阵营，但当前战斗仍主要是双阵营。
# 未识别的 scope 一律回退到 source 自己所在阵营，避免静默统计错队伍。
func _resolve_trigger_team_ids(unit: Node, team_scope: String) -> Array[int]:
	var source_team: int = int(unit.get("team_id"))
	match team_scope:
		"ally", "self_team", "":
			return [source_team]
		"enemy":
			return [_resolve_enemy_team(source_team)]
		"both":
			return [COMBAT_TEAM_ALLY, COMBAT_TEAM_ENEMY]
		_:
			if team_scope.is_valid_int():
				return [int(team_scope)]
			return [source_team]


func _passes_enemy_nearby_requirement(
	manager: Node,
	unit: Node,
	trigger_params: Dictionary,
	skill_data: Dictionary,
	event_context: Dictionary = {}
) -> bool:
	if not bool(trigger_params.get("require_enemy_nearby", false)):
		return true
	if unit == null or not is_instance_valid(unit):
		return false

	var battle_runtime: Variant = manager.get_battle_runtime()
	var state_service: Variant = manager.get_state_service()
	var target_service: Variant = manager.get_skill_target_service()
	var skill_range_cells: float = target_service.resolve_skill_cast_range_cells(
		unit,
		skill_data,
		manager.DEFAULT_SKILL_CAST_RANGE_CELLS
	)
	var nearby_cache_value: Variant = event_context.get("_ua_enemy_nearby_cache", {})
	var range_key: int = int(roundi(skill_range_cells * 1000.0))
	var cache_key: int = int(unit.get_instance_id()) ^ (range_key << 1)
	if nearby_cache_value is Dictionary and (nearby_cache_value as Dictionary).has(cache_key):
		return bool((nearby_cache_value as Dictionary).get(cache_key, false))
	var battle_units_value: Variant = event_context.get("_ua_battle_units", state_service.get_battle_units())
	var battle_units: Array = battle_units_value if battle_units_value is Array else state_service.get_battle_units()
	var nearby_enemy: Node = target_service.pick_nearest_enemy_in_range(
		battle_units,
		unit,
		skill_range_cells,
		battle_runtime.get_bound_hex_grid(),
		state_service,
		battle_runtime.get_bound_combat_manager()
	)
	var has_nearby_enemy: bool = nearby_enemy != null
	if nearby_cache_value is Dictionary:
		(nearby_cache_value as Dictionary)[cache_key] = has_nearby_enemy
	return has_nearby_enemy


# 当前战斗只有 ally/enemy 两队，因此敌方阵营可以直接二值互换。
# 如果未来扩到多阵营，这里会是最先替换的边界之一。
# 当前默认回退到 ENEMY，目的是让未知队伍值至少还能指向“对侧”。
func _resolve_enemy_team(team_id: int) -> int:
	if team_id == COMBAT_TEAM_ALLY:
		return COMBAT_TEAM_ENEMY
	if team_id == COMBAT_TEAM_ENEMY:
		return COMBAT_TEAM_ALLY
	return COMBAT_TEAM_ENEMY


# 字符串过滤数组统一做去重和小写化，保证比较口径稳定。
# 这里主要服务 reasons、terrain_tags_any/all 这类配置数组。
# 统一归一化后，条件服务里的比较都可以直接用小写字符串匹配。
func _normalize_string_filter_array(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		# seen 只用来去重，不保留额外元信息，保证输出仍是稳定字符串数组。
		for item in (value as Array):
			var text: String = str(item).strip_edges().to_lower()
			if text.is_empty():
				continue
			if seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out
