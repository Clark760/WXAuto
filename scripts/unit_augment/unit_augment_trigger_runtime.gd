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


# passive_aura 的 scope token 要按战斗重置，状态实际存放在执行服务里。
# facade 本身不保存计数器，避免和执行服务出现双份状态。
func reset_battle_counters() -> void:
	_execution_service.reset_battle_counters()


# 自动触发器只在 battle runtime 主循环里轮询一次，事件型触发不走这里。
# 这里处理的是轮询入口，不负责冷却、概率和数值条件的具体判断。
func poll_auto_triggers(manager: Node) -> void:
	var state_service: Variant = manager.get_state_service()
	var unit_states: Dictionary = state_service.get_unit_states()

	for key in unit_states.keys():
		var iid: int = int(key)
		var state: Dictionary = unit_states[iid]
		var unit: Node = state.get("unit", null)
		if unit == null or not is_instance_valid(unit):
			continue
		if not state_service.is_unit_alive(unit):
			continue

		var triggers: Array = state.get("triggers", [])
		for idx in range(triggers.size()):
			var entry: Dictionary = triggers[idx]
			var trigger_name: String = _normalize_trigger_name(
				str(entry.get("trigger", "")).strip_edges().to_lower()
			)
			if _is_poll_trigger(trigger_name):
				if can_trigger_entry(manager, unit, entry, {}):
					try_fire_skill(manager, unit, entry, {})
			triggers[idx] = entry

		state["triggers"] = triggers
		state_service.set_state_by_id(iid, state)


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
