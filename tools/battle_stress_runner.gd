extends SceneTree

# ===========================
# 高密度战斗压测脚本（Headless）
# ===========================
# 用法示例：
# godot.exe --headless --path <project> --script res://tools/battle_stress_runner.gd -- --rounds=3 --enemy=220 --bench=260 --timeout=90 --sample=1.0 --shuffle=false

const BATTLE_SCENE_PATH: String = "res://scenes/battle/battlefield.tscn"

var _rounds: int = 3
var _enemy_wave: int = 220
var _bench_target: int = 260
var _timeout_seconds: float = 90.0
var _sample_interval_seconds: float = 1.0
var _enable_shuffle: bool = true
var _prioritize_in_range: bool = false
var _soft_flow_blocking: bool = true
var _allow_side_step: bool = true


func _initialize() -> void:
	_parse_args(OS.get_cmdline_user_args())
	call_deferred("_run_benchmark")


func _parse_args(args: Array[String]) -> void:
	for arg in args:
		if arg.begins_with("--rounds="):
			_rounds = maxi(int(arg.get_slice("=", 1)), 1)
		elif arg.begins_with("--enemy="):
			_enemy_wave = maxi(int(arg.get_slice("=", 1)), 1)
		elif arg.begins_with("--bench="):
			_bench_target = maxi(int(arg.get_slice("=", 1)), 1)
		elif arg.begins_with("--timeout="):
			_timeout_seconds = maxf(float(arg.get_slice("=", 1)), 5.0)
		elif arg.begins_with("--sample="):
			_sample_interval_seconds = maxf(float(arg.get_slice("=", 1)), 0.2)
		elif arg.begins_with("--shuffle="):
			_enable_shuffle = _parse_bool(arg.get_slice("=", 1))
		elif arg.begins_with("--prioritize="):
			_prioritize_in_range = _parse_bool(arg.get_slice("=", 1))
		elif arg.begins_with("--soft_flow="):
			_soft_flow_blocking = _parse_bool(arg.get_slice("=", 1))
		elif arg.begins_with("--side_step="):
			_allow_side_step = _parse_bool(arg.get_slice("=", 1))


func _parse_bool(raw: String) -> bool:
	var text: String = raw.strip_edges().to_lower()
	return text == "1" or text == "true" or text == "yes" or text == "on"


func _run_benchmark() -> void:
	var packed: PackedScene = load(BATTLE_SCENE_PATH) as PackedScene
	if packed == null:
		push_error("STRESS_ERROR: failed to load scene %s" % BATTLE_SCENE_PATH)
		quit(1)
		return

	var all_round_results: Array[Dictionary] = []
	for round_idx in range(_rounds):
		var result: Dictionary = await _run_single_round(packed, round_idx + 1)
		all_round_results.append(result)
		print("STRESS_ROUND %s" % JSON.stringify(result))

	var summary: Dictionary = _summarize_results(all_round_results)
	print("STRESS_SUMMARY %s" % JSON.stringify(summary))
	quit(0)


func _run_single_round(packed: PackedScene, round_number: int) -> Dictionary:
	var battlefield: Node = packed.instantiate()
	root.add_child(battlefield)
	await process_frame
	await process_frame

	var combat_manager: Node = battlefield.get_node_or_null("CombatManager")
	if combat_manager == null:
		battlefield.queue_free()
		await process_frame
		return {
			"round": round_number,
			"error": "combat_manager_missing"
		}

	# 提升门派等级到上限，确保自动上场上限足够高（通常可到 50）。
	var economy_manager: Node = battlefield.get("_economy_manager")
	if economy_manager != null and economy_manager.has_method("add_exp"):
		economy_manager.call("add_exp", 99999)

	# 保证备战席数量达到压测目标，避免自动上场数量不足。
	var bench_ui: Node = battlefield.get_node_or_null("BottomLayer/BottomPanel/RootVBox/BenchArea")
	if bench_ui != null and bench_ui.has_method("get_unit_count"):
		var current_bench: int = int(bench_ui.call("get_unit_count"))
		var extra_needed: int = maxi(_bench_target - current_bench, 0)
		if extra_needed > 0:
			battlefield.call("_spawn_random_units_to_bench", extra_needed)

	battlefield.set("enemy_wave_size", _enemy_wave)
	combat_manager.set("shuffle_unit_order_each_tick", _enable_shuffle)
	combat_manager.set("prioritize_targets_in_attack_range", _prioritize_in_range)
	combat_manager.set("block_teammate_cells_in_flow", not _soft_flow_blocking)
	combat_manager.set("allow_equal_cost_side_step", _allow_side_step)

	battlefield.call("_start_combat")
	await process_frame

	var start_ms: int = Time.get_ticks_msec()
	var sample_next_time: float = 0.0
	var samples: Array[Dictionary] = []
	var alive_history: Array[Dictionary] = []
	while true:
		var elapsed_s: float = float(Time.get_ticks_msec() - start_ms) / 1000.0
		var is_running: bool = bool(combat_manager.call("is_battle_running"))
		if elapsed_s >= sample_next_time:
			var snapshot: Dictionary = combat_manager.call("get_runtime_metrics_snapshot")
			snapshot["elapsed_s"] = elapsed_s
			samples.append(snapshot)
			alive_history.append({
				"t": elapsed_s,
				"ally": int(snapshot.get("ally_alive", 0)),
				"enemy": int(snapshot.get("enemy_alive", 0))
			})
			sample_next_time += _sample_interval_seconds
		if not is_running:
			break
		if elapsed_s >= _timeout_seconds:
			break
		await process_frame

	var final_snapshot: Dictionary = combat_manager.call("get_runtime_metrics_snapshot")
	var duration_s: float = float(Time.get_ticks_msec() - start_ms) / 1000.0
	var timeout_hit: bool = duration_s >= _timeout_seconds and bool(combat_manager.call("is_battle_running"))
	if timeout_hit and combat_manager.has_method("stop_battle"):
		# 超时时主动结束战斗，避免 AutoLoad 持有已释放单位引用。
		combat_manager.call("stop_battle", "stress_timeout", 0)
		await process_frame
	var longest_alive_plateau_s: float = _calc_longest_alive_plateau(alive_history)

	var round_result: Dictionary = {
		"round": round_number,
		"duration_s": duration_s,
		"timeout": timeout_hit,
		"enemy_wave": _enemy_wave,
		"bench_target": _bench_target,
		"shuffle": _enable_shuffle,
		"prioritize": _prioritize_in_range,
		"soft_flow": _soft_flow_blocking,
		"side_step": _allow_side_step,
		"sample_count": samples.size(),
		"longest_alive_plateau_s": longest_alive_plateau_s,
		"final": final_snapshot
	}

	battlefield.queue_free()
	await process_frame
	return round_result


func _calc_longest_alive_plateau(history: Array[Dictionary]) -> float:
	if history.size() < 2:
		return 0.0
	var longest: float = 0.0
	var segment_start_time: float = float(history[0].get("t", 0.0))
	var last_ally: int = int(history[0].get("ally", 0))
	var last_enemy: int = int(history[0].get("enemy", 0))
	for idx in range(1, history.size()):
		var current: Dictionary = history[idx]
		var ally_now: int = int(current.get("ally", 0))
		var enemy_now: int = int(current.get("enemy", 0))
		if ally_now != last_ally or enemy_now != last_enemy:
			var span: float = float(current.get("t", 0.0)) - segment_start_time
			if span > longest:
				longest = span
			segment_start_time = float(current.get("t", 0.0))
			last_ally = ally_now
			last_enemy = enemy_now
	var last_span: float = float((history[history.size() - 1] as Dictionary).get("t", 0.0)) - segment_start_time
	if last_span > longest:
		longest = last_span
	return longest


func _summarize_results(results: Array[Dictionary]) -> Dictionary:
	if results.is_empty():
		return {"rounds": 0}
	var total_duration: float = 0.0
	var timeout_count: int = 0
	var total_avg_tick_ms: float = 0.0
	var total_move_blocked_rate: float = 0.0
	var total_move_success_rate: float = 0.0
	var total_attack_performed_rate: float = 0.0
	var total_plateau: float = 0.0
	var valid_metrics_rounds: int = 0
	for result in results:
		total_duration += float(result.get("duration_s", 0.0))
		if bool(result.get("timeout", false)):
			timeout_count += 1
		total_plateau += float(result.get("longest_alive_plateau_s", 0.0))
		var final_snapshot: Dictionary = result.get("final", {})
		if final_snapshot.is_empty():
			continue
		total_avg_tick_ms += float(final_snapshot.get("avg_tick_ms", 0.0))
		total_move_blocked_rate += float(final_snapshot.get("move_blocked_rate", 0.0))
		total_move_success_rate += float(final_snapshot.get("move_success_rate", 0.0))
		total_attack_performed_rate += float(final_snapshot.get("attack_performed_rate", 0.0))
		valid_metrics_rounds += 1
	var denom: float = float(maxi(valid_metrics_rounds, 1))
	return {
		"rounds": results.size(),
		"avg_duration_s": total_duration / float(results.size()),
		"timeout_count": timeout_count,
		"avg_longest_alive_plateau_s": total_plateau / float(results.size()),
		"avg_tick_ms": total_avg_tick_ms / denom,
		"avg_move_blocked_rate": total_move_blocked_rate / denom,
		"avg_move_success_rate": total_move_success_rate / denom,
		"avg_attack_performed_rate": total_attack_performed_rate / denom
	}
