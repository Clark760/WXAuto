extends "res://scripts/stage/mechanics/base_mechanic.gd"
class_name PhaseShieldMechanic

# ===========================
# 机制：天罡护体（相位护盾）
# ===========================
# 规则：
# 1. Boss 血量降到阈值时生成护盾；
# 2. 护盾存在期间伤害先扣护盾，不扣本体生命；
# 3. 护盾击破后 Boss 进入短暂易伤（默认 5 秒），并可获得破盾增益。

var _phases: Array[Dictionary] = []
var _next_phase_index: int = 0
var _shield_active: bool = false
var _vulnerable_until: float = -1.0


func setup(mechanic_config: Dictionary, mechanic_context: Dictionary) -> void:
	super.setup(mechanic_config, mechanic_context)
	_phases.clear()
	_next_phase_index = 0
	_shield_active = false
	_vulnerable_until = -1.0

	var raw_phases_value: Variant = config.get("phases", [])
	if raw_phases_value is Array:
		for row_value in raw_phases_value:
			if not (row_value is Dictionary):
				continue
			var row: Dictionary = row_value
			var hp_threshold: float = clampf(float(row.get("hp_threshold", 0.0)), 0.0, 1.0)
			var shield_hp: float = maxf(float(row.get("shield_hp", 0.0)), 0.0)
			if shield_hp <= 0.0:
				continue
			_phases.append({
				"hp_threshold": hp_threshold,
				"shield_hp": shield_hp,
				"buff_on_break": str(row.get("buff_on_break", "")).strip_edges().to_lower()
			})
	_phases.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("hp_threshold", 0.0)) > float(b.get("hp_threshold", 0.0))
	)


func cleanup() -> void:
	super.cleanup()
	var boss: Node = _get_primary_boss_unit()
	if boss != null and is_instance_valid(boss):
		boss.set_meta("stage_shield_hp", 0.0)
		boss.set_meta("stage_damage_taken_multiplier", 1.0)
	_shield_active = false
	_vulnerable_until = -1.0


func tick(_delta: float, _runtime_context: Dictionary) -> void:
	if not is_active:
		return
	var boss: Node = _get_primary_boss_unit()
	if boss == null or not _is_unit_alive(boss):
		return

	var now: float = _get_logic_time()
	_update_vulnerable_state(boss, now)
	_update_shield_state(boss, now)


func _update_vulnerable_state(boss: Node, now: float) -> void:
	if _vulnerable_until <= 0.0:
		return
	if now < _vulnerable_until:
		return
	_set_damage_taken_multiplier(boss, 1.0)
	_vulnerable_until = -1.0
	_append_log("Boss 易伤阶段结束。")


func _update_shield_state(boss: Node, now: float) -> void:
	var shield_hp: float = float(boss.get_meta("stage_shield_hp", 0.0))
	if _shield_active:
		if shield_hp > 0.0:
			return
		_shield_active = false
		_on_shield_broken(boss, now)
		return
	if _next_phase_index >= _phases.size():
		return

	var combat: Node = _get_unit_combat(boss)
	if combat == null:
		return
	var max_hp: float = maxf(float(combat.get("max_hp")), 1.0)
	var current_hp: float = clampf(float(combat.get("current_hp")), 0.0, max_hp)
	var hp_ratio: float = current_hp / max_hp
	var phase_row: Dictionary = _phases[_next_phase_index]
	var threshold: float = float(phase_row.get("hp_threshold", 0.0))
	if hp_ratio > threshold:
		return
	_activate_phase_shield(boss, phase_row)
	_next_phase_index += 1


func _activate_phase_shield(boss: Node, phase_row: Dictionary) -> void:
	var shield_hp: float = float(phase_row.get("shield_hp", 0.0))
	if shield_hp <= 0.0:
		return
	boss.set_meta("stage_shield_hp", shield_hp)
	_shield_active = true
	_append_log("Boss 启动护盾（%.0f）。" % shield_hp)


func _on_shield_broken(boss: Node, now: float) -> void:
	# 破盾后固定给一段易伤窗口。
	_set_damage_taken_multiplier(boss, 1.3)
	_vulnerable_until = now + 5.0
	var phase_index: int = maxi(_next_phase_index - 1, 0)
	var buff_name: String = ""
	if phase_index >= 0 and phase_index < _phases.size():
		buff_name = str((_phases[phase_index] as Dictionary).get("buff_on_break", "")).strip_edges().to_lower()
	_apply_break_buff(boss, buff_name)
	_append_log("Boss 护盾破碎，进入易伤状态。")


func _apply_break_buff(boss: Node, buff_name: String) -> void:
	match buff_name:
		"atk_up_20":
			_add_outgoing_damage_bonus(boss, 0.2)
		"berserk":
			_add_outgoing_damage_bonus(boss, 0.35)
			_add_external_modifier(boss, "attack_speed_bonus", 0.25, -0.8, 0.9)
		_:
			return

