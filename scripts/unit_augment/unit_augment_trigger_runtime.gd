extends RefCounted
class_name UnitAugmentTriggerRuntime

const CONDITION_SERVICE_SCRIPT: Script = preload(
	"res://scripts/unit_augment/unit_augment_trigger_condition_service.gd"
)
const EXECUTION_SERVICE_SCRIPT: Script = preload(
	"res://scripts/unit_augment/unit_augment_trigger_execution_service.gd"
)

var _condition_service = CONDITION_SERVICE_SCRIPT.new()
var _execution_service = EXECUTION_SERVICE_SCRIPT.new()

const PROBE_SCOPE_UNIT_AUGMENT_POLL_PASSIVE_AURA: String = "unit_augment_poll_passive_aura"
const PROBE_SCOPE_UNIT_AUGMENT_POLL_PERIODIC: String = "unit_augment_poll_periodic"

const ENTRY_META_TRY_FIRE_STATUS: String = "_unit_augment_try_fire_status"
const TRY_FIRE_STATUS_DEFERRED: String = "deferred"


# passive_aura 的 scope token 要按战斗重置，状态实际存放在执行服务里。
# facade 本身不保存计数器，避免和执行服务出现双份状态。
func reset_battle_counters() -> void:
	_execution_service.reset_battle_counters()


# 自动触发器只在 battle runtime 主循环里轮询一次，事件型触发不走这里。
# 这里处理的是轮询入口，不负责冷却、概率和数值条件的具体判断。
func poll_auto_triggers(manager: Node) -> void:
	var state_service: Variant = manager.get_state_service()
	var unit_states: Dictionary = state_service.get_unit_states()
	var deep_probe_enabled: bool = bool(manager.get("deep_runtime_probe_enabled"))
	var condition_context: Dictionary = _build_poll_condition_context(manager, state_service)
	_poll_passive_aura_triggers(
		manager,
		state_service,
		unit_states,
		deep_probe_enabled,
		condition_context
	)
	_poll_state_poll_triggers(
		manager,
		state_service,
		unit_states,
		deep_probe_enabled,
		condition_context
	)
	_poll_timed_poll_triggers(
		manager,
		state_service,
		unit_states,
		deep_probe_enabled,
		condition_context
	)


func _poll_passive_aura_triggers(
	manager: Node,
	state_service: Variant,
	unit_states: Dictionary,
	deep_probe_enabled: bool,
	condition_context: Dictionary
) -> void:
	var battle_elapsed: float = manager.get_battle_runtime().get_battle_elapsed()
	var aura_unit_ids: Array[int] = state_service.get_passive_aura_trigger_unit_ids()
	var repair_bucket_count: int = _resolve_passive_aura_repair_bucket_count(aura_unit_ids.size())
	var repair_bucket_index: int = _resolve_poll_bucket_index(manager, repair_bucket_count)

	for iid in aura_unit_ids:
		if not unit_states.has(iid):
			continue
		var state: Dictionary = unit_states[iid]
		var dirty: bool = bool(state.get("passive_aura_dirty", false))
		var next_dirty_poll_time: float = float(state.get("next_passive_aura_dirty_poll_time", 0.0))
		var next_refresh_time: float = float(state.get("next_passive_aura_refresh_time", 0.0))
		var dirty_due: bool = dirty and battle_elapsed >= next_dirty_poll_time
		var repair_due: bool = (not dirty) and battle_elapsed >= next_refresh_time
		if not dirty_due and not repair_due:
			continue
		if repair_due and repair_bucket_count > 1 and posmod(iid, repair_bucket_count) != repair_bucket_index:
			continue

		var unit: Node = state.get("unit", null)
		if unit == null or not is_instance_valid(unit):
			continue
		if not state_service.is_unit_alive(unit):
			continue

		var passive_aura_triggers: Array = state.get("passive_aura_triggers", [])
		if passive_aura_triggers.is_empty():
			continue

		var keep_dirty: bool = false
		for entry_value in passive_aura_triggers:
			if not (entry_value is Dictionary):
				continue
			var entry: Dictionary = entry_value as Dictionary
			match _get_passive_aura_entry_state(entry, battle_elapsed):
				1:
					if dirty:
						keep_dirty = true
					continue
				2:
					continue
			if not _poll_trigger_entry(manager, unit, entry, deep_probe_enabled, condition_context):
				keep_dirty = true
		state_service.finalize_passive_aura_poll(iid, battle_elapsed, keep_dirty)


func _poll_state_poll_triggers(
	manager: Node,
	state_service: Variant,
	unit_states: Dictionary,
	deep_probe_enabled: bool,
	condition_context: Dictionary
) -> void:
	var poll_unit_ids: Array[int] = state_service.get_state_poll_trigger_unit_ids()
	var bucket_count: int = _resolve_poll_bucket_count(poll_unit_ids.size())
	var bucket_index: int = _resolve_poll_bucket_index(manager, bucket_count)

	for iid in poll_unit_ids:
		if bucket_count > 1 and posmod(iid, bucket_count) != bucket_index:
			continue
		if not unit_states.has(iid):
			continue
		var state: Dictionary = unit_states[iid]
		var unit: Node = state.get("unit", null)
		if unit == null or not is_instance_valid(unit):
			continue
		if not state_service.is_unit_alive(unit):
			continue

		var poll_triggers: Array = state.get("state_poll_triggers", [])
		if poll_triggers.is_empty():
			continue
		for entry_value in poll_triggers:
			if not (entry_value is Dictionary):
				continue
			_poll_trigger_entry(
				manager,
				unit,
				entry_value as Dictionary,
				deep_probe_enabled,
				condition_context
			)


func _poll_timed_poll_triggers(
	manager: Node,
	state_service: Variant,
	unit_states: Dictionary,
	deep_probe_enabled: bool,
	condition_context: Dictionary
) -> void:
	var battle_elapsed: float = manager.get_battle_runtime().get_battle_elapsed()
	var timed_unit_ids: Array[int] = state_service.get_timed_poll_trigger_unit_ids()
	var bucket_count: int = _resolve_poll_bucket_count(timed_unit_ids.size())
	var bucket_index: int = _resolve_poll_bucket_index(manager, bucket_count)

	for iid in timed_unit_ids:
		if bucket_count > 1 and posmod(iid, bucket_count) != bucket_index:
			continue
		if not unit_states.has(iid):
			continue
		var state: Dictionary = unit_states[iid]
		var next_due_time: float = float(state.get("next_timed_poll_time", INF))
		if battle_elapsed < next_due_time:
			continue

		var unit: Node = state.get("unit", null)
		if unit == null or not is_instance_valid(unit):
			continue
		if not state_service.is_unit_alive(unit):
			continue

		var timed_poll_triggers: Array = state.get("timed_poll_triggers", [])
		if timed_poll_triggers.is_empty():
			continue

		for entry_value in timed_poll_triggers:
			if not (entry_value is Dictionary):
				continue
			var entry: Dictionary = entry_value as Dictionary
			if not _is_timed_trigger_due(entry, battle_elapsed):
				continue
			_poll_trigger_entry(manager, unit, entry, deep_probe_enabled, condition_context)

		state_service.refresh_timed_poll_state(iid)


func _poll_trigger_entry(
	manager: Node,
	unit: Node,
	entry: Dictionary,
	deep_probe_enabled: bool,
	condition_context: Dictionary = {}
) -> bool:
	var probe_scope_name: String = ""
	var probe_begin_us: int = 0
	if deep_probe_enabled:
		var trigger_name: String = str(entry.get("trigger", "")).strip_edges().to_lower()
		probe_scope_name = _resolve_poll_probe_scope(trigger_name)
		if not probe_scope_name.is_empty():
			probe_begin_us = _probe_begin_timing(manager)
	var fired: bool = false
	entry.erase(ENTRY_META_TRY_FIRE_STATUS)
	if can_trigger_entry(manager, unit, entry, condition_context):
		fired = try_fire_skill(manager, unit, entry, {})
	var try_fire_status: String = str(entry.get(ENTRY_META_TRY_FIRE_STATUS, "")).strip_edges()
	entry.erase(ENTRY_META_TRY_FIRE_STATUS)
	if not fired and try_fire_status == TRY_FIRE_STATUS_DEFERRED:
		fired = true
	if not probe_scope_name.is_empty():
		_probe_commit_timing(manager, probe_scope_name, probe_begin_us)
	return fired


func _build_poll_condition_context(manager: Node, state_service: Variant) -> Dictionary:
	var battle_units: Array = state_service.get_battle_units()
	var alive_by_team: Dictionary = _resolve_alive_by_team_snapshot(manager, state_service, battle_units)
	return {
		"_ua_battle_units": battle_units,
		"_ua_alive_by_team": alive_by_team,
		"_ua_enemy_nearby_cache": {}
	}


func _resolve_alive_by_team_snapshot(
	manager: Node,
	state_service: Variant,
	battle_units: Array
) -> Dictionary:
	var battle_runtime: Variant = manager.get_battle_runtime()
	var combat_manager: Node = battle_runtime.get_bound_combat_manager()
	if (
		combat_manager != null
		and is_instance_valid(combat_manager)
		and combat_manager.has_method("get_team_alive_count")
	):
		return {
			1: int(combat_manager.get_team_alive_count(1)),
			2: int(combat_manager.get_team_alive_count(2))
		}

	var alive_by_team: Dictionary = {1: 0, 2: 0}
	for unit_value in battle_units:
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		if not state_service.is_unit_alive(unit):
			continue
		var team_id: int = int(unit.get("team_id"))
		alive_by_team[team_id] = int(alive_by_team.get(team_id, 0)) + 1
	return alive_by_team


# 全体广播型 trigger 只遍历 battle units，不直接扫场景树。
# 广播本身不区分阵营，具体过滤仍由条件服务负责。
func fire_trigger_for_all(manager: Node, trigger: String, context: Dictionary) -> void:
	for unit in manager.get_state_service().get_battle_units():
		fire_trigger_for_unit(manager, unit, trigger, context)


# 事件型触发统一走这一入口，边沿状态也在这里回写。
# `context` 是外部事件快照，这里只负责路由到匹配的 trigger entry。
func fire_trigger_for_unit(manager: Node, unit: Node, trigger: String, context: Dictionary) -> void:
	if unit == null or not is_instance_valid(unit):
		return

	var state_service: Variant = manager.get_state_service()
	var iid: int = unit.get_instance_id()
	var unit_states: Dictionary = state_service.get_unit_states()
	if not unit_states.has(iid):
		return

	var state: Dictionary = unit_states[iid]
	var triggers: Array = state.get("triggers", [])
	var trigger_name: String = _normalize_trigger_name(trigger.strip_edges().to_lower())

	for idx in range(triggers.size()):
		var entry: Dictionary = triggers[idx]
		var entry_trigger: String = _normalize_trigger_name(
			str(entry.get("trigger", "")).strip_edges().to_lower()
		)
		if entry_trigger != trigger_name:
			continue
		if can_trigger_entry(manager, unit, entry, context):
			try_fire_skill(manager, unit, entry, context)
		triggers[idx] = entry

	state["triggers"] = triggers
	state_service.set_state_by_id(iid, state)


# facade 只保留对外契约，具体条件判定由 ConditionService 承接。
# 返回值只表示“此刻是否允许触发”，不表示技能已经执行。
func can_trigger_entry(manager: Node, unit: Node, entry: Dictionary, event_context: Dictionary = {}) -> bool:
	return _condition_service.can_trigger_entry(manager, unit, entry, event_context)


# facade 只负责转发到执行服务，不再承载目标选择和冷却推进实现体。
# 真正的 MP 扣除、目标补齐和日志发射都在执行服务内部完成。
func try_fire_skill(manager: Node, source: Node, entry: Dictionary, event_context: Dictionary) -> bool:
	return _execution_service.try_fire_skill(manager, source, entry, event_context)


# 外部 effect 入口继续保留在 TriggerRuntime facade，避免上层调用面变化。
# 这个入口主要被 terrain、buff tick 和其他系统级调用方复用。
func execute_external_effects(
	manager: Node,
	source: Node,
	target: Node,
	effects: Array,
	context: Dictionary,
	meta: Dictionary = {}
) -> Dictionary:
	return _execution_service.execute_external_effects(
		manager,
		source,
		target,
		effects,
		context,
		meta
	)


# effect context 仍由 TriggerRuntime 对外暴露，但实际装配委托给执行服务。
# 这样 manager 和 battle runtime 不需要知道 context 的具体字段细节。
func build_effect_context(manager: Node, source: Node, target: Node, event_context: Dictionary) -> Dictionary:
	return _execution_service.build_effect_context(manager, source, target, event_context)


# 轮询触发器名单固定在这里，避免 battle runtime 侧散落同一批字符串。
# 只有这里返回 true 的 trigger 才会在主循环里被周期检查。
func _is_poll_trigger(trigger_name: String) -> bool:
	return trigger_name == "auto_mp_full" \
		or trigger_name == "manual" \
		or trigger_name == "auto_hp_below" \
		or trigger_name == "passive_aura" \
		or trigger_name == "on_hp_below" \
		or trigger_name == "on_time_elapsed" \
		or trigger_name == "periodic_seconds" \
		or trigger_name == "periodic"


# on_buff_expire 是旧写法，这里统一归一成 on_buff_expired。
# 其他 trigger 名保持原样返回，不在这里做额外别名扩散。
func _normalize_trigger_name(trigger_name: String) -> String:
	if trigger_name == "on_buff_expire":
		return "on_buff_expired"
	return trigger_name


# 高密度战斗把自动触发轮询拆成多桶，优先压住一次性大尖峰。
func _is_timed_trigger_due(entry: Dictionary, battle_elapsed: float) -> bool:
	var next_ready_time: float = float(entry.get("next_ready_time", 0.0))
	if battle_elapsed < next_ready_time:
		return false
	var max_trigger_count: int = int(entry.get("max_trigger_count", 0))
	if max_trigger_count > 0 and int(entry.get("trigger_count", 0)) >= max_trigger_count:
		return false

	var trigger_name: String = str(entry.get("trigger", "")).strip_edges().to_lower()
	match trigger_name:
		"periodic_seconds", "periodic":
			var trigger_params: Dictionary = {}
			var trigger_params_value: Variant = entry.get("trigger_params", {})
			if trigger_params_value is Dictionary:
				trigger_params = trigger_params_value as Dictionary
			var skill_data: Dictionary = {}
			var skill_data_value: Variant = entry.get("skill_data", {})
			if skill_data_value is Dictionary:
				skill_data = skill_data_value as Dictionary
			var interval: float = maxf(
				float(trigger_params.get("interval", skill_data.get("interval", 0.0))),
				0.05
			)
			var next_periodic_time: float = float(entry.get("next_periodic_time", interval))
			if next_periodic_time <= 0.0:
				next_periodic_time = interval
			return battle_elapsed >= next_periodic_time
		"on_time_elapsed":
			if bool(entry.get("time_elapsed_fired", false)):
				return false
			var trigger_params: Dictionary = {}
			var trigger_params_value: Variant = entry.get("trigger_params", {})
			if trigger_params_value is Dictionary:
				trigger_params = trigger_params_value as Dictionary
			var skill_data: Dictionary = {}
			var skill_data_value: Variant = entry.get("skill_data", {})
			if skill_data_value is Dictionary:
				skill_data = skill_data_value as Dictionary
			var at_seconds: float = maxf(
				float(trigger_params.get("at_seconds", skill_data.get("at_seconds", -1.0))),
				-1.0
			)
			return at_seconds >= 0.0 and battle_elapsed >= at_seconds
		_:
			return false


func _resolve_poll_bucket_count(unit_count: int) -> int:
	if unit_count >= 220:
		return 5
	if unit_count >= 120:
		return 3
	return 1


func _resolve_passive_aura_repair_bucket_count(unit_count: int) -> int:
	if unit_count >= 80:
		return 5
	if unit_count >= 32:
		return 3
	return 1


func _get_passive_aura_entry_state(entry: Dictionary, battle_elapsed: float) -> int:
	var max_trigger_count: int = int(entry.get("max_trigger_count", 0))
	if max_trigger_count > 0 and int(entry.get("trigger_count", 0)) >= max_trigger_count:
		return 2
	if battle_elapsed < float(entry.get("next_ready_time", 0.0)):
		return 1
	return 0


# 轮询桶索引直接由 battle_elapsed 和 poll_interval 推导，避免再维护额外计数器。
func _resolve_poll_bucket_index(manager: Node, bucket_count: int) -> int:
	if bucket_count <= 1:
		return 0
	var poll_interval: float = maxf(manager.trigger_poll_interval, 0.05)
	var battle_elapsed: float = manager.get_battle_runtime().get_battle_elapsed()
	var poll_round: int = int(floor(battle_elapsed / poll_interval))
	return posmod(poll_round, bucket_count)


func _resolve_poll_probe_scope(trigger_name: String) -> String:
	if trigger_name == "passive_aura":
		return PROBE_SCOPE_UNIT_AUGMENT_POLL_PASSIVE_AURA
	if trigger_name == "periodic_seconds" or trigger_name == "periodic":
		return PROBE_SCOPE_UNIT_AUGMENT_POLL_PERIODIC
	return ""


func _probe_begin_timing(manager: Node) -> int:
	var runtime_probe = manager._services.runtime_probe if manager._services != null else null
	if runtime_probe == null or not runtime_probe.has_method("begin_timing"):
		return 0
	return int(runtime_probe.begin_timing())


func _probe_commit_timing(manager: Node, scope_name: String, begin_us: int) -> void:
	var runtime_probe = manager._services.runtime_probe if manager._services != null else null
	if runtime_probe == null or not runtime_probe.has_method("commit_timing"):
		return
	runtime_probe.commit_timing(scope_name, begin_us)
