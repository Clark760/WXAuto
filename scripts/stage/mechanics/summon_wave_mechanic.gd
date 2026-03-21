extends "res://scripts/stage/mechanics/base_mechanic.gd"
class_name SummonWaveMechanic

# ===========================
# 机制：呼朋引伴（增援波次）
# ===========================
# 说明：
# 1. 按 interval_seconds 周期触发；
# 2. 最多触发 max_waves 次；
# 3. 具体小兵数据由 wave_units 配置驱动。

var _elapsed: float = 0.0
var _waves_spawned: int = 0
var _next_spawn_at: float = 0.0


func setup(mechanic_config: Dictionary, mechanic_context: Dictionary) -> void:
	super.setup(mechanic_config, mechanic_context)
	_elapsed = 0.0
	_waves_spawned = 0
	var interval_seconds: float = maxf(float(config.get("interval_seconds", 15.0)), 1.0)
	_next_spawn_at = interval_seconds


func tick(delta: float, _runtime_context: Dictionary) -> void:
	if not is_active:
		return
	var boss: Node = _get_primary_boss_unit()
	if boss == null or not _is_unit_alive(boss):
		return

	_elapsed += delta
	var max_waves: int = maxi(int(config.get("max_waves", 3)), 0)
	if _waves_spawned >= max_waves:
		return
	if _elapsed < _next_spawn_at:
		return

	var battlefield: Node = _get_battlefield()
	if battlefield == null or not is_instance_valid(battlefield):
		return
	if not battlefield.has_method("spawn_mechanic_enemy_wave"):
		return

	var wave_units_value: Variant = config.get("wave_units", [])
	if not (wave_units_value is Array):
		return
	var spawned_count: int = int(battlefield.call("spawn_mechanic_enemy_wave", wave_units_value))
	_waves_spawned += 1
	var interval_seconds: float = maxf(float(config.get("interval_seconds", 15.0)), 1.0)
	_next_spawn_at += interval_seconds
	_append_log("Boss 召唤增援：第 %d 波（新增 %d 个单位）" % [_waves_spawned, spawned_count])

