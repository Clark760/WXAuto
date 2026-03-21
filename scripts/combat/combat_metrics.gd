extends RefCounted
class_name CombatMetrics

# ===========================
# 战斗指标统计模块
# ===========================

func reset_tick_metrics(owner: Node) -> void:
	owner.set("_metric_tick_units", 0)
	owner.set("_metric_tick_attack_checks", 0)
	owner.set("_metric_tick_attacks_performed", 0)
	owner.set("_metric_tick_move_checks", 0)
	owner.set("_metric_tick_move_started", 0)
	owner.set("_metric_tick_move_blocked", 0)
	owner.set("_metric_tick_move_conflicts", 0)
	owner.set("_metric_tick_idle_no_cell", 0)
	owner.set("_metric_tick_flow_unreachable", 0)


func finalize_tick(owner: Node, tick_begin_us: int, allow_attack_phase: bool, allow_move_phase: bool) -> void:
	var tick_duration_us: int = Time.get_ticks_usec() - tick_begin_us
	owner.set("_metric_tick_duration_us", tick_duration_us)
	owner.set("_metric_total_tick_duration_us", int(owner.get("_metric_total_tick_duration_us")) + tick_duration_us)
	owner.set("_metric_last_tick", {
		"logic_frame": int(owner.get("_logic_frame")),
		"phase": "attack" if allow_attack_phase and not allow_move_phase else ("move" if allow_move_phase and not allow_attack_phase else "both"),
		"units": int(owner.get("_metric_tick_units")),
		"attack_checks": int(owner.get("_metric_tick_attack_checks")),
		"attacks_performed": int(owner.get("_metric_tick_attacks_performed")),
		"move_checks": int(owner.get("_metric_tick_move_checks")),
		"move_started": int(owner.get("_metric_tick_move_started")),
		"move_blocked": int(owner.get("_metric_tick_move_blocked")),
		"move_conflicts": int(owner.get("_metric_tick_move_conflicts")),
		"flow_unreachable": int(owner.get("_metric_tick_flow_unreachable")),
		"idle_no_cell": int(owner.get("_metric_tick_idle_no_cell")),
		"tick_duration_us": tick_duration_us,
		"ally_alive": int((owner.get("_alive_by_team") as Dictionary).get(1, 0)),
		"enemy_alive": int((owner.get("_alive_by_team") as Dictionary).get(2, 0))
	})


func build_runtime_snapshot(owner: Node) -> Dictionary:
	var logic_frames: int = maxi(int(owner.get("_logic_frame")), 1)
	var move_checks: int = maxi(int(owner.get("_metric_total_move_checks")), 1)
	var attack_checks: int = maxi(int(owner.get("_metric_total_attack_checks")), 1)
	var alive_by_team: Dictionary = owner.get("_alive_by_team")
	return {
		"logic_frame": int(owner.get("_logic_frame")),
		"logic_time": float(owner.get("_logic_time")),
		"battle_running": bool(owner.get("_battle_running")),
		"ally_alive": int(alive_by_team.get(1, 0)),
		"enemy_alive": int(alive_by_team.get(2, 0)),
		"avg_tick_ms": float(owner.get("_metric_total_tick_duration_us")) / float(logic_frames) / 1000.0,
		"avg_units_per_tick": float(owner.get("_metric_total_units")) / float(logic_frames),
		"attack_performed_rate": float(owner.get("_metric_total_attacks_performed")) / float(attack_checks),
		"move_success_rate": float(owner.get("_metric_total_move_started")) / float(move_checks),
		"move_blocked_rate": float(owner.get("_metric_total_move_blocked")) / float(move_checks),
		"move_conflict_rate": float(owner.get("_metric_total_move_conflicts")) / float(move_checks),
		"flow_unreachable_rate": float(owner.get("_metric_total_flow_unreachable")) / float(move_checks),
		"idle_no_cell_rate": float(owner.get("_metric_total_idle_no_cell")) / float(move_checks),
		"totals": {
			"units": int(owner.get("_metric_total_units")),
			"attack_checks": int(owner.get("_metric_total_attack_checks")),
			"attacks_performed": int(owner.get("_metric_total_attacks_performed")),
			"move_checks": int(owner.get("_metric_total_move_checks")),
			"move_started": int(owner.get("_metric_total_move_started")),
			"move_blocked": int(owner.get("_metric_total_move_blocked")),
			"move_conflicts": int(owner.get("_metric_total_move_conflicts")),
			"flow_unreachable": int(owner.get("_metric_total_flow_unreachable")),
			"idle_no_cell": int(owner.get("_metric_total_idle_no_cell")),
			"tick_duration_us": int(owner.get("_metric_total_tick_duration_us"))
		},
		"last_tick": (owner.get("_metric_last_tick") as Dictionary).duplicate(true)
	}


func reset_all_metrics(owner: Node) -> void:
	reset_tick_metrics(owner)
	owner.set("_metric_tick_duration_us", 0)
	owner.set("_metric_total_units", 0)
	owner.set("_metric_total_attack_checks", 0)
	owner.set("_metric_total_attacks_performed", 0)
	owner.set("_metric_total_move_checks", 0)
	owner.set("_metric_total_move_started", 0)
	owner.set("_metric_total_move_blocked", 0)
	owner.set("_metric_total_move_conflicts", 0)
	owner.set("_metric_total_idle_no_cell", 0)
	owner.set("_metric_total_flow_unreachable", 0)
	owner.set("_metric_total_tick_duration_us", 0)
	(owner.get("_metric_last_tick") as Dictionary).clear()
