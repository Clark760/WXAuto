extends "res://scripts/stage/mechanics/base_mechanic.gd"
class_name EnrageTimerMechanic

# ===========================
# 机制：绝地反击（狂暴计时）
# ===========================
# 支持：
# 1. soft_enrage_stages 分段加压；
# 2. 到时后触发最终狂暴；
# 3. Buff 通过“伤害加成 + 攻速 + 减伤”三类参数实现。

var _elapsed: float = 0.0
var _enraged: bool = false
var _soft_stage_triggered: Dictionary = {}
var _warning_emitted: bool = false


func setup(mechanic_config: Dictionary, mechanic_context: Dictionary) -> void:
	super.setup(mechanic_config, mechanic_context)
	_elapsed = 0.0
	_enraged = false
	_soft_stage_triggered.clear()
	_warning_emitted = false


func tick(delta: float, _runtime_context: Dictionary) -> void:
	if not is_active:
		return
	var boss: Node = _get_primary_boss_unit()
	if boss == null or not _is_unit_alive(boss):
		return
	_elapsed += delta

	var enrage_after: float = maxf(float(config.get("enrage_after_seconds", 60.0)), 1.0)
	var warning_seconds: float = maxf(float(config.get("pre_enrage_warning_seconds", 10.0)), 0.0)
	if not _warning_emitted and warning_seconds > 0.0 and _elapsed >= enrage_after - warning_seconds:
		_warning_emitted = true
		_append_log("Boss 气息暴涨，狂暴即将到来。")

	_apply_soft_enrage_if_needed(boss)
	if _enraged:
		return
	if _elapsed < enrage_after:
		return
	_enraged = true
	_apply_buff_profile(boss, config.get("enrage_buffs", {}))
	_append_log("Boss 进入狂暴状态！")


func _apply_soft_enrage_if_needed(boss: Node) -> void:
	var stages_value: Variant = config.get("soft_enrage_stages", [])
	if not (stages_value is Array):
		return
	var stages: Array = stages_value
	for idx in range(stages.size()):
		if _soft_stage_triggered.has(idx):
			continue
		var row_value: Variant = stages[idx]
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value
		var at_seconds: float = maxf(float(row.get("at_seconds", -1.0)), -1.0)
		if at_seconds < 0.0 or _elapsed < at_seconds:
			continue
		_soft_stage_triggered[idx] = true
		_apply_buff_profile(boss, row)
		_append_log("Boss 压力升级（阶段 %d）" % (idx + 1))


func _apply_buff_profile(boss: Node, profile_value: Variant) -> void:
	if not (profile_value is Dictionary):
		return
	var profile: Dictionary = profile_value
	var atk_percent: float = float(profile.get("atk_percent", 0.0))
	var spd_percent: float = float(profile.get("spd_percent", 0.0))
	var reduce_percent: float = float(profile.get("damage_reduce_percent", 0.0))
	if not is_zero_approx(atk_percent):
		_add_outgoing_damage_bonus(boss, atk_percent)
	if not is_zero_approx(spd_percent):
		_add_external_modifier(boss, "attack_speed_bonus", spd_percent, -0.8, 0.9)
	if not is_zero_approx(reduce_percent):
		_add_external_modifier(boss, "damage_reduce_percent", reduce_percent, 0.0, 0.95)

