extends RefCounted
class_name CombatMetricsRules

# 指标规则
# 说明：
# 1. 规则层只负责生成统计快照，不直接写 runtime facade 字段。
# 2. facade 侧负责把当前标量组装成输入，再回写返回结果。
# 3. 这样 metrics 模块就不再依赖 owner.set/get 的动态属性袋。


# 返回“单帧统计归零”所需的稳定字段，供 runtime 每帧开头复位。
func build_zero_tick_metrics() -> Dictionary:
	return {
		"tick_units": 0,
		"tick_attack_checks": 0,
		"tick_attacks_performed": 0,
		"tick_move_checks": 0,
		"tick_move_started": 0,
		"tick_move_blocked": 0,
		"tick_move_conflicts": 0,
		"tick_idle_no_cell": 0,
		"tick_flow_unreachable": 0
	}


# 返回“整局累计归零”所需的完整字段，避免 facade 手写重复字面量。
func build_zero_runtime_metrics() -> Dictionary:
	var metrics: Dictionary = build_zero_tick_metrics()
	# tick_* 负责单帧，total_* 负责整局，壳层会分别回写到旧字段。
	metrics["tick_duration_us"] = 0
	metrics["total_units"] = 0
	metrics["total_attack_checks"] = 0
	metrics["total_attacks_performed"] = 0
	metrics["total_move_checks"] = 0
	metrics["total_move_started"] = 0
	metrics["total_move_blocked"] = 0
	metrics["total_move_conflicts"] = 0
	metrics["total_idle_no_cell"] = 0
	metrics["total_flow_unreachable"] = 0
	metrics["total_tick_duration_us"] = 0
	metrics["last_tick"] = {}
	return metrics


# 帧末统计只产出增量结果，真正的回写仍由 facade adapter 负责。
func finalize_tick(
	tick_begin_us: int,
	allow_attack_phase: bool,
	allow_move_phase: bool,
	logic_frame: int,
	alive_by_team: Dictionary,
	tick_metrics: Dictionary,
	total_tick_duration_us: int
) -> Dictionary:
	var tick_duration_us: int = Time.get_ticks_usec() - tick_begin_us
	# last_tick 保持稳定结构，方便测试和 HUD 直接断言关键字段。
	return {
		"tick_duration_us": tick_duration_us,
		"total_tick_duration_us": total_tick_duration_us + tick_duration_us,
		"last_tick": {
			"logic_frame": logic_frame,
			"phase": _resolve_phase_label(allow_attack_phase, allow_move_phase),
			"units": int(tick_metrics.get("tick_units", 0)),
			"attack_checks": int(tick_metrics.get("tick_attack_checks", 0)),
			"attacks_performed": int(tick_metrics.get("tick_attacks_performed", 0)),
			"move_checks": int(tick_metrics.get("tick_move_checks", 0)),
			"move_started": int(tick_metrics.get("tick_move_started", 0)),
			"move_blocked": int(tick_metrics.get("tick_move_blocked", 0)),
			"move_conflicts": int(tick_metrics.get("tick_move_conflicts", 0)),
			"flow_unreachable": int(tick_metrics.get("tick_flow_unreachable", 0)),
			"idle_no_cell": int(tick_metrics.get("tick_idle_no_cell", 0)),
			"tick_duration_us": tick_duration_us,
			"ally_alive": int(alive_by_team.get(1, 0)),
			"enemy_alive": int(alive_by_team.get(2, 0))
		}
	}


# 对外暴露战斗指标快照时，统一在这里计算平均值和命中率。
func build_runtime_snapshot(
	logic_frame: int,
	logic_time: float,
	battle_running: bool,
	alive_by_team: Dictionary,
	total_metrics: Dictionary,
	last_tick: Dictionary
) -> Dictionary:
	var logic_frames: int = maxi(logic_frame, 1)
	var move_checks: int = maxi(int(total_metrics.get("total_move_checks", 0)), 1)
	var attack_checks: int = maxi(int(total_metrics.get("total_attack_checks", 0)), 1)
	# 比率字段统一在这里归一，避免 facade 和 UI 各自再补一次除零保护。
	return {
		"logic_frame": logic_frame,
		"logic_time": logic_time,
		"battle_running": battle_running,
		"ally_alive": int(alive_by_team.get(1, 0)),
		"enemy_alive": int(alive_by_team.get(2, 0)),
		"avg_tick_ms": float(total_metrics.get("total_tick_duration_us", 0)) / float(logic_frames) / 1000.0,
		"avg_units_per_tick": float(total_metrics.get("total_units", 0)) / float(logic_frames),
		"attack_performed_rate": float(total_metrics.get("total_attacks_performed", 0)) / float(attack_checks),
		"move_success_rate": float(total_metrics.get("total_move_started", 0)) / float(move_checks),
		"move_blocked_rate": float(total_metrics.get("total_move_blocked", 0)) / float(move_checks),
		"move_conflict_rate": float(total_metrics.get("total_move_conflicts", 0)) / float(move_checks),
		"flow_unreachable_rate": float(total_metrics.get("total_flow_unreachable", 0)) / float(move_checks),
		"idle_no_cell_rate": float(total_metrics.get("total_idle_no_cell", 0)) / float(move_checks),
		"totals": {
			"units": int(total_metrics.get("total_units", 0)),
			"attack_checks": int(total_metrics.get("total_attack_checks", 0)),
			"attacks_performed": int(total_metrics.get("total_attacks_performed", 0)),
			"move_checks": int(total_metrics.get("total_move_checks", 0)),
			"move_started": int(total_metrics.get("total_move_started", 0)),
			"move_blocked": int(total_metrics.get("total_move_blocked", 0)),
			"move_conflicts": int(total_metrics.get("total_move_conflicts", 0)),
			"flow_unreachable": int(total_metrics.get("total_flow_unreachable", 0)),
			"idle_no_cell": int(total_metrics.get("total_idle_no_cell", 0)),
			"tick_duration_us": int(total_metrics.get("total_tick_duration_us", 0))
		},
		"last_tick": last_tick.duplicate(true)
	}


# 攻击相位与移动相位分拆后，统一在这里生成对外可读的文本标签。
func _resolve_phase_label(allow_attack_phase: bool, allow_move_phase: bool) -> String:
	if allow_attack_phase and not allow_move_phase:
		return "attack"
	if allow_move_phase and not allow_attack_phase:
		return "move"
	return "both"
