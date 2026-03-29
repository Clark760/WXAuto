extends Node

signal unit_augment_data_reloaded(summary: Dictionary)
signal skill_triggered(unit: Node, gongfa_id: String, trigger: String)
signal skill_effect_damage(event: Dictionary)
signal skill_effect_heal(event: Dictionary)
signal buff_event(event: Dictionary)

const PROBE_SCOPE_UNIT_AUGMENT_MANAGER_PROCESS: String = "unit_augment_manager_process"

@export var trigger_poll_interval: float = 0.12
@export var tag_linkage_stagger_buckets: int = 8
@export var deep_runtime_probe_enabled: bool = false

const DEFAULT_SKILL_CAST_RANGE_CELLS: float = 2.0

const REGISTRY_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_registry.gd")
const BUFF_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_buff_manager.gd")
const EFFECT_ENGINE_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_effect_engine.gd")
const TAG_REGISTRY_SERVICE_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_tag_registry_service.gd")
const TAG_LINKAGE_RESOLVER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_tag_linkage_resolver.gd")
const TAG_LINKAGE_SCHEDULER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_tag_linkage_scheduler.gd")
const SKILL_TARGET_SERVICE_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_skill_target_service.gd")
const TELEMETRY_EMITTER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_telemetry_emitter.gd")
const UNIT_STATE_SERVICE_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_unit_state_service.gd")
const BATTLE_RUNTIME_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_battle_runtime.gd")
const TRIGGER_RUNTIME_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_trigger_runtime.gd")
const COMBAT_EVENT_BRIDGE_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_combat_event_bridge.gd")
var _services: ServiceRegistry = null

var _registry = REGISTRY_SCRIPT.new()
var _buff_manager = BUFF_MANAGER_SCRIPT.new()
var _effect_engine = EFFECT_ENGINE_SCRIPT.new()
var _tag_registry_service = TAG_REGISTRY_SERVICE_SCRIPT.new()
var _tag_linkage_resolver = TAG_LINKAGE_RESOLVER_SCRIPT.new()
var _tag_linkage_scheduler = TAG_LINKAGE_SCHEDULER_SCRIPT.new()
var _skill_target_service = SKILL_TARGET_SERVICE_SCRIPT.new()
var _telemetry_emitter = TELEMETRY_EMITTER_SCRIPT.new()
var _unit_data_script: Script = load("res://scripts/domain/unit/unit_data.gd")
var _state_service = UNIT_STATE_SERVICE_SCRIPT.new(
	_registry,
	_effect_engine,
	_buff_manager,
	_tag_linkage_scheduler,
	_unit_data_script
)
var _battle_runtime = BATTLE_RUNTIME_SCRIPT.new()
var _trigger_runtime = TRIGGER_RUNTIME_SCRIPT.new()
var _combat_event_bridge = COMBAT_EVENT_BRIDGE_SCRIPT.new()


# 记录 ServiceRegistry，供 facade 向下游服务转发依赖。
func bind_runtime_services(services: ServiceRegistry) -> void:
	_services = services


# manager facade 只负责装配和对外契约，不承载实际规则实现。
# 所有子服务实例都在这里集中注入，后续批次只允许继续把实现往外迁，不允许反向长回 facade。
func _ready() -> void:
	_combat_event_bridge.configure(self)
	reload_from_data()
	_connect_buff_signals()
	_connect_event_bus()
	set_process(true)


# 运行时 tick 统一交给 battle runtime，facade 本身不写业务分支。
# facade 在这里唯一做的事是把 Godot 生命周期转发给运行时服务。
func _process(delta: float) -> void:
	var process_begin_us: int = _probe_begin_timing()
	_battle_runtime.advance(self, delta)
	_probe_commit_timing(PROBE_SCOPE_UNIT_AUGMENT_MANAGER_PROCESS, process_begin_us)


# 数据热重载后要同步 registry、tag registry 和 buff definitions。
# `summary` 返回给 UI 和日志使用，因此这里会补上 tag 统计字段。
func reload_from_data() -> Dictionary:
	var data_manager: Node = _get_data_manager()
	var summary: Dictionary = _registry.reload_from_data_manager(data_manager)
	var tag_snapshot: Dictionary = _tag_registry_service.rebuild(
		_registry,
		data_manager,
		_state_service.get_battle_units()
	)
	_state_service.configure_tag_linkage_registry(
		tag_snapshot.get("tag_to_index", {}),
		int(tag_snapshot.get("version", 1))
	)
	_tag_linkage_resolver.configure_tag_registry(tag_snapshot.get("tag_to_index", {}), int(tag_snapshot.get("version", 1)))
	_tag_linkage_scheduler.mark_all_dirty("tag_registry_reloaded")
	_buff_manager.set_buff_definitions(_registry.get_buff_map_snapshot())

	summary["tag_count"] = (tag_snapshot.get("index_to_tag", []) as Array).size()
	summary["tag_registry_version"] = int(tag_snapshot.get("version", 1))
	unit_augment_data_reloaded.emit(summary)
	return summary


# 战斗上下文只绑定到 runtime service，manager 不直接持有这三项状态字段。
func bind_combat_context(combat_manager: Node, hex_grid: Node, vfx_factory: Node) -> void:
	_battle_runtime.bind_combat_context(self, combat_manager, hex_grid, vfx_factory)


# prepare_battle 只做运行时重置和状态装配，不启动真正的 CombatManager。
func prepare_battle(
	ally_units: Array[Node],
	enemy_units: Array[Node],
	hex_grid: Node,
	vfx_factory: Node,
	combat_manager: Node
) -> void:
	_battle_runtime.prepare_battle(self, ally_units, enemy_units, hex_grid, vfx_factory, combat_manager)


# 条目级接口名保持不变，但实际入口统一由 UnitAugmentManager 暴露。
func apply_gongfa(unit: Node, defer_apply: bool = false) -> void:
	_state_service.apply_unit_augment(unit, defer_apply)


# 卸载运行时效果时不移除底层槽位配置。
func remove_gongfa(unit: Node) -> void:
	_state_service.remove_unit_augment(unit)


# 条目级装配接口继续保留原名，避免 UI 和商店层大面积改玩法接口。
func equip_gongfa(unit: Node, slot: String, gongfa_id: String) -> bool:
	return _state_service.equip_gongfa(unit, slot, gongfa_id)


# 卸下后立即重算 runtime stats，避免 UI 仍显示旧效果。
func unequip_gongfa(unit: Node, slot: String) -> void:
	_state_service.unequip_gongfa(unit, slot)


# registry 查询接口不做额外业务逻辑。
func get_gongfa_data(gongfa_id: String) -> Dictionary:
	return _registry.get_gongfa(gongfa_id)


# 商店和详情面板都依赖这个完整列表接口。
func get_all_gongfa() -> Array[Dictionary]:
	return _registry.get_all_gongfa()


# 装备数据也统一由 manager 暴露，避免 UI 直连 registry。
func get_equipment_data(equip_id: String) -> Dictionary:
	return _registry.get_equipment(equip_id)


# 商店池重建使用这份设备列表。
func get_all_equipment() -> Array[Dictionary]:
	return _registry.get_all_equipment()


# tag linkage 会读取条目 tags，而不是 runtime state。
func get_gongfa_tags(gongfa_id: String) -> Array[String]:
	return _state_service.get_gongfa_tags(gongfa_id)


# 装备 tags 同样走 state service 的统一读取口径。
func get_equipment_tags(equip_id: String) -> Array[String]:
	return _state_service.get_equipment_tags(equip_id)


# runtime ids 会被 tag linkage resolver 和 UI 同时读取。
func get_unit_runtime_gongfa_ids(unit: Node) -> Array[String]:
	return _state_service.get_unit_runtime_gongfa_ids(unit)


# 装备 runtime ids 也是统一运行时视图的一部分。
func get_unit_runtime_equip_ids(unit: Node) -> Array[String]:
	return _state_service.get_unit_runtime_equip_ids(unit)


func get_tag_linkage_provider_cache(unit: Node) -> Dictionary:
	return _state_service.get_tag_linkage_provider_cache(unit)


# 兼容入口：旧测试仍通过私有方法名 `_resolve_equipped_equip_ids` 读取装备结果。
# manager 不再自行实现解析逻辑，统一委托给 state service 的运行时口径。
func _resolve_equipped_equip_ids(unit: Node) -> Array[String]:
	return _state_service.get_unit_runtime_equip_ids(unit)


# tag registry snapshot 只暴露副本，避免外层误写版本表。
func get_tag_registry_snapshot() -> Dictionary:
	return _tag_registry_service.get_snapshot()


# resolver 的编译缓存是否失效只依赖这个版本号。
func get_tag_registry_version() -> int:
	return _tag_registry_service.get_version()


# gate 评估只决定“本次是否允许评估 tag_linkage”，不执行 effect。
func evaluate_tag_linkage_gate(owner: Node, effect: Dictionary, context: Dictionary) -> Dictionary:
	var eval_context: Dictionary = context.duplicate(false)
	if not eval_context.has("hex_grid"):
		eval_context["hex_grid"] = _battle_runtime.get_bound_hex_grid()
	if not eval_context.has("combat_manager"):
		eval_context["combat_manager"] = _battle_runtime.get_bound_combat_manager()
	if not eval_context.has("tag_linkage_stagger_buckets"):
		eval_context["tag_linkage_stagger_buckets"] = tag_linkage_stagger_buckets
	return _tag_linkage_scheduler.should_evaluate(owner, effect, eval_context)


# stateful branch 需要读取 scheduler 持有的上一轮命中状态。
func get_tag_linkage_state(owner: Node, effect: Dictionary) -> Dictionary:
	return {
		"last_case_id": _tag_linkage_scheduler.get_last_case_id(owner, effect),
		"stateful_buff_ids": _tag_linkage_scheduler.get_stateful_buff_ids(owner, effect)
	}


# 只有 scheduler 允许维护 stateful branch 的状态。
func set_tag_linkage_state(owner: Node, effect: Dictionary, case_id: String, buff_ids: Array[String]) -> void:
	_tag_linkage_scheduler.set_last_case_id(owner, effect, case_id)
	_tag_linkage_scheduler.set_stateful_buff_ids(owner, effect, buff_ids)


# 一次评估结束后，要把 providers 订阅结果回写给 scheduler。
func notify_tag_linkage_evaluated(owner: Node, effect: Dictionary, context: Dictionary, result: Dictionary) -> void:
	var eval_context: Dictionary = context.duplicate(false)
	if not eval_context.has("hex_grid"):
		eval_context["hex_grid"] = _battle_runtime.get_bound_hex_grid()
	if not eval_context.has("combat_manager"):
		eval_context["combat_manager"] = _battle_runtime.get_bound_combat_manager()
	_tag_linkage_scheduler.on_evaluated(owner, effect, eval_context, result)


# resolver 真正执行 query / case 匹配，manager 只负责补齐运行时上下文。
func evaluate_tag_linkage_branch(owner: Node, config: Dictionary, context: Dictionary) -> Dictionary:
	var eval_context: Dictionary = context.duplicate(false)
	if not eval_context.has("all_units"):
		eval_context["all_units"] = _state_service.get_battle_units()
	if not eval_context.has("combat_manager"):
		eval_context["combat_manager"] = _battle_runtime.get_bound_combat_manager()
	if not eval_context.has("hex_grid"):
		eval_context["hex_grid"] = _battle_runtime.get_bound_hex_grid()
	if not eval_context.has("hex_size"):
		var hex_grid: Node = _battle_runtime.get_bound_hex_grid()
		eval_context["hex_size"] = hex_grid.get("hex_size") if hex_grid != null else 26.0
	if not eval_context.has("tag_linkage_stagger_buckets"):
		eval_context["tag_linkage_stagger_buckets"] = tag_linkage_stagger_buckets
	eval_context["unit_augment_manager"] = self
	return _tag_linkage_resolver.evaluate(owner, config, eval_context)


# 地形和其他系统级外部 effect 继续通过这个统一入口执行。
func execute_external_effects(
	source: Node,
	target: Node,
	effects: Array,
	context: Dictionary,
	meta: Dictionary = {}
) -> Dictionary:
	return _trigger_runtime.execute_external_effects(self, source, target, effects, context, meta)


# 装备接口继续保留原名，但运行时由 state service 真正生效。
func equip_equipment(unit: Node, slot: String, equip_id: String) -> bool:
	return _state_service.equip_equipment(unit, slot, equip_id)


# 卸下装备后也要通知 tag linkage scheduler 刷新 watcher。
func unequip_equipment(unit: Node, slot: String) -> void:
	_state_service.unequip_equipment(unit, slot)


# Tooltip 与详情面板通过这个接口读取单位当前 Buff 列表。
func get_unit_buff_ids(unit: Node) -> Array[String]:
	return _buff_manager.get_active_buff_ids_for_unit(unit)


# Debuff 查询继续暴露给 UI 和 effect 查询层使用。
func has_unit_debuff(unit: Node, debuff_id: String = "") -> bool:
	return _buff_manager.has_debuff(unit, debuff_id)


# runtime Buff 是战斗中直接附着的效果，需要立即重算目标单位状态。
func apply_runtime_buff(
	target: Node,
	buff_id: String,
	duration: float,
	source: Node = null,
	_origin: String = "runtime"
) -> bool:
	var ok: bool = _buff_manager.apply_buff(target, buff_id, duration, source)
	if not ok or target == null or not is_instance_valid(target):
		return ok

	_state_service.apply_state_to_unit(target.get_instance_id(), true)
	if _registry.has_buff(buff_id):
		var buff_data: Dictionary = _registry.get_buff(buff_id)
		if str(buff_data.get("type", "buff")).strip_edges().to_lower() == "debuff":
			_fire_trigger_for_unit(target, "on_debuff_applied", {
				"target": target,
				"source": source,
				"debuff_id": buff_id
			})
	return ok

# Buff 过期事件需要从 buff_removed 中转成 on_buff_expired。
func _on_buff_removed(event_dict: Dictionary) -> void:
	var target_id: int = int(event_dict.get("target_id", -1))
	if target_id <= 0:
		return
	if not _state_service.get_unit_lookup().has(target_id):
		return
	var target: Node = _state_service.get_unit_lookup()[target_id]
	if target == null or not is_instance_valid(target):
		return
	if not _state_service.is_unit_alive(target):
		return
	var removed_buff_id: String = str(event_dict.get("buff_id", "")).strip_edges()
	if removed_buff_id.is_empty():
		return
	_fire_trigger_for_unit(target, "on_buff_expired", {
		"target": target,
		"removed_buff_id": removed_buff_id,
		"event": event_dict
	})


# data reload 后，战场中的单位也要按新 registry 重新投影一遍 runtime stats。
func _on_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	reload_from_data()
	for unit in _state_service.get_battle_units():
		_state_service.apply_unit_augment(unit)


# trigger runtime 的对外广播入口只保留在 manager，方便 telemetry 和事件桥接复用。
func _fire_trigger_for_all(trigger: String, context: Dictionary) -> void:
	_trigger_runtime.fire_trigger_for_all(self, trigger, context)


# 这里保留私有桥接方法，避免外部直接拿 trigger runtime 当公共接口。
func _fire_trigger_for_unit(unit: Node, trigger: String, context: Dictionary) -> void:
	_trigger_runtime.fire_trigger_for_unit(self, unit, trigger, context)


# manager 对外只暴露只读 getter，具体实现都在子服务里。
func get_registry() -> Variant:
	return _registry


# effect engine 是主动/被动效果执行的唯一 facade。
func get_effect_engine() -> Variant:
	return _effect_engine


# BuffManager 继续承担生命周期和源绑定光环状态。
func get_buff_manager() -> Variant:
	return _buff_manager


# state service 管理 battle units、unit lookup 和 runtime state。
func get_state_service() -> Variant:
	return _state_service


# battle runtime 统一管理上下文绑定和 tick。
func get_battle_runtime() -> Variant:
	return _battle_runtime


# trigger runtime 统一管理 trigger 轮询和 effect context 组装。
func get_trigger_runtime() -> Variant:
	return _trigger_runtime


# tag linkage resolver/scheduler 仍拆成独立服务，不允许 manager 自己持有实现体。
func get_tag_linkage_scheduler() -> Variant:
	return _tag_linkage_scheduler


# resolver 主要被 evaluate_tag_linkage_branch 使用。
func get_tag_linkage_resolver() -> Variant:
	return _tag_linkage_resolver


# tag registry service 只负责 tags -> index 映射维护。
func get_tag_registry_service() -> Variant:
	return _tag_registry_service


# trigger runtime 的选敌逻辑委托给独立服务，避免继续长在 trigger 文件里。
func get_skill_target_service() -> Variant:
	return _skill_target_service


# summary -> signal payload 的映射统一走 telemetry emitter。
func get_telemetry_emitter() -> Variant:
	return _telemetry_emitter


# buff_removed 由 manager 统一接住，再转成 on_buff_expired 触发器。
func _connect_buff_signals() -> void:
	var cb_removed: Callable = Callable(self, "_on_buff_removed")
	if _buff_manager != null and not _buff_manager.is_connected("buff_removed", cb_removed):
		_buff_manager.connect("buff_removed", cb_removed)


# 数据热重载仍然通过 EventBus 触发，不在本轮动全局总线语义。
func _connect_event_bus() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null:
		return
	var cb: Callable = Callable(self, "_on_data_reloaded")
	if not event_bus.is_connected("data_reloaded", cb):
		event_bus.connect("data_reloaded", cb)


# combat signal 连接仍由 manager 持有，避免 runtime service 直接发射业务事件。
func _connect_combat_signals() -> void:
	var combat_manager: Node = _battle_runtime.get_bound_combat_manager()
	if combat_manager == null:
		return
	_combat_event_bridge.connect_combat_signals(combat_manager)


# 切换 CombatManager 时，旧连接必须全部断开，避免双派发。
func _disconnect_combat_signals() -> void:
	var combat_manager: Node = _battle_runtime.get_bound_combat_manager()
	if combat_manager == null:
		return
	_combat_event_bridge.disconnect_combat_signals(combat_manager)


# EventBus 只从显式注入的 ServiceRegistry 获取。
func _get_event_bus() -> Node:
	if _services == null:
		return null
	return _services.event_bus


# DataManager 同样只从显式注入的 ServiceRegistry 获取。
func _get_data_manager() -> Node:
	if _services == null:
		return null
	return _services.data_repository


# manager 自己的 _process scope 也统一写回 RuntimeProbe，便于和 Combat 主循环拆开看。
func _probe_begin_timing() -> int:
	var runtime_probe = _services.runtime_probe if _services != null else null
	if runtime_probe == null or not runtime_probe.has_method("begin_timing"):
		return 0
	return int(runtime_probe.begin_timing())


# UnitAugment 的主循环单独挂 scope，方便压测时确认 buff/trigger 是否在抢预算。
func _probe_commit_timing(scope_name: String, begin_us: int) -> void:
	var runtime_probe = _services.runtime_probe if _services != null else null
	if runtime_probe == null or not runtime_probe.has_method("commit_timing"):
		return
	runtime_probe.commit_timing(scope_name, begin_us)
