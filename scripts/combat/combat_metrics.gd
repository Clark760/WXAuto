extends RefCounted
class_name CombatMetrics

const DOMAIN_RULES_SCRIPT: Script = preload("res://scripts/domain/combat/combat_metrics.gd")

var _rules = DOMAIN_RULES_SCRIPT.new()

# 兼容壳
# 说明：
# 1. manager 仍按旧 owner 签名调用本文件。
# 2. 真正的快照构造规则已经迁到 domain/combat。


# 每帧开始时统一清掉 tick 级指标，不改动累计值。
func reset_tick_metrics(owner: Node) -> void:
	var zero_metrics: Dictionary = _rules.build_zero_tick_metrics()
	owner.set("_metric_tick_units", int(zero_metrics.get("tick_units", 0)))
	owner.set("_metric_tick_attack_checks", int(zero_metrics.get("tick_attack_checks", 0)))
	owner.set("_metric_tick_attacks_performed", int(zero_metrics.get("tick_attacks_performed", 0)))
	owner.set("_metric_tick_move_checks", int(zero_metrics.get("tick_move_checks", 0)))
	owner.set("_metric_tick_move_started", int(zero_metrics.get("tick_move_started", 0)))
	owner.set("_metric_tick_move_blocked", int(zero_metrics.get("tick_move_blocked", 0)))
	owner.set("_metric_tick_move_conflicts", int(zero_metrics.get("tick_move_conflicts", 0)))
	owner.set("_metric_tick_idle_no_cell", int(zero_metrics.get("tick_idle_no_cell", 0)))
	owner.set("_metric_tick_flow_unreachable", int(zero_metrics.get("tick_flow_unreachable", 0)))


# 帧末把本帧统计整理成 last_tick，并回写累计耗时。
func finalize_tick(owner: Node, tick_begin_us: int, allow_attack_phase: bool, allow_move_phase: bool) -> void:
	var finalized: Dictionary = _rules.finalize_tick(
		tick_begin_us,
		allow_attack_phase,
		allow_move_phase,
		int(owner.get("_logic_frame")),
		owner.get("_alive_by_team"),
		_build_tick_metrics(owner),
		int(owner.get("_metric_total_tick_duration_us"))
	)
	owner.set("_metric_tick_duration_us", int(finalized.get("tick_duration_us", 0)))
	owner.set(
		"_metric_total_tick_duration_us",
		int(finalized.get("total_tick_duration_us", 0))
	)
	owner.set("_metric_last_tick", (finalized.get("last_tick", {}) as Dictionary).duplicate(true))


# 对外快照继续沿用旧入口，但计算规则委托给 domain 层。
func build_runtime_snapshot(owner: Node) -> Dictionary:
	return _rules.build_runtime_snapshot(
		int(owner.get("_logic_frame")),
		float(owner.get("_logic_time")),
		bool(owner.get("_battle_running")),
		owner.get("_alive_by_team"),
		_build_total_metrics(owner),
		owner.get("_metric_last_tick")
	)


# 整局重置时同时清空 tick 指标、累计指标和 last_tick。
func reset_all_metrics(owner: Node) -> void:
	var zero_metrics: Dictionary = _rules.build_zero_runtime_metrics()
	owner.set("_metric_tick_units", int(zero_metrics.get("tick_units", 0)))
	owner.set("_metric_tick_attack_checks", int(zero_metrics.get("tick_attack_checks", 0)))
	owner.set("_metric_tick_attacks_performed", int(zero_metrics.get("tick_attacks_performed", 0)))
	owner.set("_metric_tick_move_checks", int(zero_metrics.get("tick_move_checks", 0)))
	owner.set("_metric_tick_move_started", int(zero_metrics.get("tick_move_started", 0)))
	owner.set("_metric_tick_move_blocked", int(zero_metrics.get("tick_move_blocked", 0)))
	owner.set("_metric_tick_move_conflicts", int(zero_metrics.get("tick_move_conflicts", 0)))
	owner.set("_metric_tick_idle_no_cell", int(zero_metrics.get("tick_idle_no_cell", 0)))
	owner.set("_metric_tick_flow_unreachable", int(zero_metrics.get("tick_flow_unreachable", 0)))
	owner.set("_metric_tick_duration_us", int(zero_metrics.get("tick_duration_us", 0)))
	owner.set("_metric_total_units", int(zero_metrics.get("total_units", 0)))
	owner.set("_metric_total_attack_checks", int(zero_metrics.get("total_attack_checks", 0)))
	owner.set("_metric_total_attacks_performed", int(zero_metrics.get("total_attacks_performed", 0)))
	owner.set("_metric_total_move_checks", int(zero_metrics.get("total_move_checks", 0)))
	owner.set("_metric_total_move_started", int(zero_metrics.get("total_move_started", 0)))
	owner.set("_metric_total_move_blocked", int(zero_metrics.get("total_move_blocked", 0)))
	owner.set("_metric_total_move_conflicts", int(zero_metrics.get("total_move_conflicts", 0)))
	owner.set("_metric_total_idle_no_cell", int(zero_metrics.get("total_idle_no_cell", 0)))
	owner.set("_metric_total_flow_unreachable", int(zero_metrics.get("total_flow_unreachable", 0)))
	owner.set("_metric_total_tick_duration_us", int(zero_metrics.get("total_tick_duration_us", 0)))
	(owner.get("_metric_last_tick") as Dictionary).clear()


# 兼容壳先把 owner 上的 tick 字段整理成稳定字典，再交给 domain 计算。
func _build_tick_metrics(owner: Node) -> Dictionary:
	return {
		"tick_units": int(owner.get("_metric_tick_units")),
		"tick_attack_checks": int(owner.get("_metric_tick_attack_checks")),
		"tick_attacks_performed": int(owner.get("_metric_tick_attacks_performed")),
		"tick_move_checks": int(owner.get("_metric_tick_move_checks")),
		"tick_move_started": int(owner.get("_metric_tick_move_started")),
		"tick_move_blocked": int(owner.get("_metric_tick_move_blocked")),
		"tick_move_conflicts": int(owner.get("_metric_tick_move_conflicts")),
		"tick_idle_no_cell": int(owner.get("_metric_tick_idle_no_cell")),
		"tick_flow_unreachable": int(owner.get("_metric_tick_flow_unreachable"))
	}


# 累计指标仍由 owner 保存；这里只做一次显式拷贝，避免 domain 依赖动态属性袋。
func _build_total_metrics(owner: Node) -> Dictionary:
	return {
		"total_units": int(owner.get("_metric_total_units")),
		"total_attack_checks": int(owner.get("_metric_total_attack_checks")),
		"total_attacks_performed": int(owner.get("_metric_total_attacks_performed")),
		"total_move_checks": int(owner.get("_metric_total_move_checks")),
		"total_move_started": int(owner.get("_metric_total_move_started")),
		"total_move_blocked": int(owner.get("_metric_total_move_blocked")),
		"total_move_conflicts": int(owner.get("_metric_total_move_conflicts")),
		"total_idle_no_cell": int(owner.get("_metric_total_idle_no_cell")),
		"total_flow_unreachable": int(owner.get("_metric_total_flow_unreachable")),
		"total_tick_duration_us": int(owner.get("_metric_total_tick_duration_us"))
	}
