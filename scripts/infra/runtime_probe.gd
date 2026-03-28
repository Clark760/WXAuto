extends RefCounted
class_name RuntimeProbe

# 运行时探针
# 说明：
# 1. 统一聚合逐帧 wall-clock、scope 耗时和低频样本。
# 2. 这里只做统计，不做任何业务判断，避免探针反向污染运行时链路。
# 3. 压测脚本只读取这里输出的快照，不再自己维护第二套统计口径。

var enabled: bool = true
var sample_interval_frames: int = 12

var _frame_count: int = 0
var _frame_delta_total: float = 0.0
var _wall_start_us: int = 0
var _wall_end_us: int = 0

var _fps_sample_count: int = 0
var _fps_total: float = 0.0
var _fps_min: float = INF
var _fps_max: float = 0.0

var _scope_stats: Dictionary = {}
var _sample_stats: Dictionary = {}


# 初始化时直接打开一个新的采样窗口，保证首帧就能开始记账。
func _init() -> void:
	reset()


# 重置采样窗口，供同一场景在不同阶段分别统计。
func reset() -> void:
	_frame_count = 0
	_frame_delta_total = 0.0
	_wall_start_us = Time.get_ticks_usec()
	_wall_end_us = _wall_start_us
	_fps_sample_count = 0
	_fps_total = 0.0
	_fps_min = INF
	_fps_max = 0.0
	_scope_stats.clear()
	_sample_stats.clear()


# 开始一次轻量计时；探针关闭时返回 0，调用方可直接忽略。
func begin_timing() -> int:
	if not enabled:
		return 0
	if _wall_start_us <= 0:
		_wall_start_us = Time.get_ticks_usec()
	return Time.get_ticks_usec()


# 把一次 begin/commit 形式的耗时写回指定 scope。
func commit_timing(scope_name: String, begin_us: int) -> void:
	if not enabled or begin_us <= 0:
		return
	record_timing_us(scope_name, Time.get_ticks_usec() - begin_us)


# 记录一个耗时 scope，并累计调用次数与总耗时。
func record_timing_us(scope_name: String, duration_us: int) -> void:
	if not enabled:
		return
	var scope_key: String = scope_name.strip_edges()
	if scope_key.is_empty():
		return
	var stats: Dictionary = _scope_stats.get(scope_key, {
		"calls": 0,
		"total_us": 0,
		"max_us": 0,
		"last_us": 0
	})
	stats["calls"] = int(stats.get("calls", 0)) + 1
	stats["total_us"] = int(stats.get("total_us", 0)) + duration_us
	stats["max_us"] = maxi(int(stats.get("max_us", 0)), duration_us)
	stats["last_us"] = duration_us
	_scope_stats[scope_key] = stats


# 逐帧记录 wall-clock 与引擎 FPS 采样。
func mark_frame(delta: float, fps: float = 0.0) -> void:
	if not enabled:
		return
	if _wall_start_us <= 0:
		_wall_start_us = Time.get_ticks_usec()
	_frame_count += 1
	_frame_delta_total += delta
	_wall_end_us = Time.get_ticks_usec()
	if fps <= 0.0:
		return
	_fps_sample_count += 1
	_fps_total += fps
	_fps_min = minf(_fps_min, fps)
	_fps_max = maxf(_fps_max, fps)


# 按固定帧间隔决定是否做一次高成本样本采集。
func should_sample_now() -> bool:
	if not enabled:
		return false
	if _frame_count <= 1:
		return true
	var interval: int = maxi(sample_interval_frames, 1)
	return _frame_count % interval == 0


# 记录某个数值型样本，统一输出均值/极值/最后值。
func record_sample(metric_name: String, value: float) -> void:
	if not enabled:
		return
	var metric_key: String = metric_name.strip_edges()
	if metric_key.is_empty():
		return
	var stats: Dictionary = _sample_stats.get(metric_key, {
		"samples": 0,
		"total": 0.0,
		"min": value,
		"max": value,
		"last": value
	})
	stats["samples"] = int(stats.get("samples", 0)) + 1
	stats["total"] = float(stats.get("total", 0.0)) + value
	stats["min"] = minf(float(stats.get("min", value)), value)
	stats["max"] = maxf(float(stats.get("max", value)), value)
	stats["last"] = value
	_sample_stats[metric_key] = stats


# 暴露当前已记录的帧数，供压测脚本判定采样窗口。
func get_frame_count() -> int:
	return _frame_count


# 输出统一快照，供压测脚本直接打印和排序分析。
func build_snapshot() -> Dictionary:
	var safe_frames: int = maxi(_frame_count, 1)
	var wall_elapsed_us: int = maxi(_wall_end_us - _wall_start_us, 0)
	var wall_elapsed_s: float = float(wall_elapsed_us) / 1000000.0
	var scopes_output: Dictionary = {}
	for scope_key in _scope_stats.keys():
		var stats: Dictionary = _scope_stats.get(scope_key, {})
		var calls: int = maxi(int(stats.get("calls", 0)), 1)
		var total_us: int = int(stats.get("total_us", 0))
		scopes_output[scope_key] = {
			"calls": int(stats.get("calls", 0)),
			"total_us": total_us,
			"last_us": int(stats.get("last_us", 0)),
			"max_us": int(stats.get("max_us", 0)),
			"avg_us_per_call": float(total_us) / float(calls),
			"avg_ms_per_call": float(total_us) / float(calls) / 1000.0,
			"avg_ms_per_frame": float(total_us) / float(safe_frames) / 1000.0
		}

	var samples_output: Dictionary = {}
	for metric_key in _sample_stats.keys():
		var sample_stats: Dictionary = _sample_stats.get(metric_key, {})
		var samples: int = maxi(int(sample_stats.get("samples", 0)), 1)
		var total_value: float = float(sample_stats.get("total", 0.0))
		samples_output[metric_key] = {
			"samples": int(sample_stats.get("samples", 0)),
			"avg": total_value / float(samples),
			"min": float(sample_stats.get("min", 0.0)),
			"max": float(sample_stats.get("max", 0.0)),
			"last": float(sample_stats.get("last", 0.0))
		}

	var fps_summary: Dictionary = {}
	if _fps_sample_count > 0:
		fps_summary = {
			"avg": _fps_total / float(_fps_sample_count),
			"min": _fps_min,
			"max": _fps_max,
			"samples": _fps_sample_count
		}

	return {
		"enabled": enabled,
		"frames": _frame_count,
		"avg_frame_delta_ms": _frame_delta_total / float(safe_frames) * 1000.0,
		"wall_time_s": wall_elapsed_s,
		"avg_wall_fps": (
			float(_frame_count) / wall_elapsed_s
			if wall_elapsed_s > 0.0
			else 0.0
		),
		"fps": fps_summary,
		"scopes": scopes_output,
		"samples": samples_output
	}
