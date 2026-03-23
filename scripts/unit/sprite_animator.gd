extends Node

# ===========================
# 程序化精灵动画器
# ===========================
# 优化要点：
# 1. 循环动画（IDLE/MOVE/BENCH/VICTORY）在 _process 里计算，不创建 Tween。
# 2. 一次性动画（ATTACK/SKILL/HIT/DEATH）保留 Tween，保障打击感与可读性。
# 3. 高频逻辑帧重复下发同一循环状态时直接忽略，避免动画相位不断重置。

enum AnimState {
	IDLE,
	MOVE,
	ATTACK,
	SKILL,
	HIT,
	DEATH,
	VICTORY,
	BENCH
}

@export var target_path: NodePath

var _target: Node2D = null
var _tween: Tween = null
var _state: int = AnimState.IDLE

var _base_position: Vector2 = Vector2.ZERO
var _base_scale: Vector2 = Vector2.ONE
var _base_rotation: float = 0.0
var _base_modulate: Color = Color(1, 1, 1, 1)

var _rest_position: Vector2 = Vector2.ZERO
var _rest_scale: Vector2 = Vector2.ONE
var _rest_rotation: float = 0.0
var _rest_modulate: Color = Color(1, 1, 1, 1)
var _has_rest_transform: bool = false

var _loop_anim_time: float = 0.0
var _loop_state_active: bool = false
var _impulse_anim_time: float = 0.0
var _impulse_duration: float = 0.0
var _impulse_direction: Vector2 = Vector2.ZERO

var _params: Dictionary = {
	"idle_amplitude": 2.0,
	"idle_period": 1.2,
	"move_tilt_deg": 5.0,
	"move_period": 0.3,
	"move_stride_px": 3.0,
	"attack_dash_distance": 5.0,
	"attack_duration": 0.15,
	"skill_scale_y": 1.2,
	"skill_flash_count": 2,
	"hit_knockback": 4.0,
	"hit_flash_duration": 0.1,
	"death_duration": 0.5,
	"victory_jump_height": 8.0,
	"victory_pulse_scale": 1.1,
	"victory_period": 0.44,
	"bench_tilt_deg": 3.0,
	"bench_period": 2.0
}


func _ready() -> void:
	_resolve_target()
	_cache_base_transform()
	set_process(false)
	play_state(AnimState.IDLE)


func _exit_tree() -> void:
	_stop_tween()


func _process(delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		return

	if _loop_state_active:
		_loop_anim_time += delta
		_apply_loop_pose(_loop_anim_time)
		return
	if _state == AnimState.ATTACK or _state == AnimState.HIT:
		_impulse_anim_time += delta
		_apply_impulse_pose()


func set_overrides(overrides: Dictionary) -> void:
	# 允许 JSON 只覆盖部分字段，未提供键值继续使用默认参数。
	for key in overrides.keys():
		if _params.has(key):
			_params[key] = overrides[key]


func play_state(state: int, context: Dictionary = {}) -> void:
	_resolve_target()
	if _target == null:
		return

	# 高频逻辑帧下，循环状态重复设置会造成抖动；直接忽略即可。
	# 但仅在“循环状态已激活”时才允许早返回，避免 reset 后卡在静止姿态。
	if _state == state and _is_loop_state(state) and _loop_state_active:
		return

	_stop_tween()
	_clear_impulse_state()
	_normalize_base_before_state(state)
	_cache_base_transform()

	_state = state
	_loop_anim_time = 0.0

	if _is_loop_state(_state):
		_loop_state_active = true
		set_process(true)
		_apply_loop_pose(0.0)
		return

	_loop_state_active = false
	set_process(false)

	match _state:
		AnimState.ATTACK:
			_play_attack(context.get("direction", Vector2.RIGHT))
		AnimState.SKILL:
			_play_skill()
		AnimState.HIT:
			_play_hit(context.get("direction", Vector2.LEFT))
		AnimState.DEATH:
			_play_death()
		_:
			# 未知状态统一回退到 IDLE，避免角色卡死在无效姿态。
			play_state(AnimState.IDLE)


func _is_loop_state(state: int) -> bool:
	return state == AnimState.IDLE or state == AnimState.MOVE or state == AnimState.BENCH or state == AnimState.VICTORY


func _apply_impulse_pose() -> void:
	if _target == null:
		return
	if _impulse_duration <= 0.0:
		_switch_to_idle_if_current(_state)
		return

	var normalized: float = clampf(_impulse_anim_time / _impulse_duration, 0.0, 1.0)
	match _state:
		AnimState.ATTACK:
			var dash_distance: float = float(_params["attack_dash_distance"])
			var dash_ratio: float = 1.0 - absf(normalized * 2.0 - 1.0)
			_target.position = _base_position + _impulse_direction * dash_distance * dash_ratio
			_target.rotation = _base_rotation
			_target.scale = _base_scale
		AnimState.HIT:
			var knockback: float = float(_params["hit_knockback"])
			var back_ratio: float = sin(normalized * PI)
			_target.position = _base_position + _impulse_direction * knockback * back_ratio
			_target.rotation = _base_rotation
			_target.scale = _base_scale
			if _target is CanvasItem:
				var flash_ratio: float = sin(normalized * PI)
				(_target as CanvasItem).modulate = _base_modulate.lerp(Color(1.6, 0.4, 0.4, 1.0), flash_ratio)
		_:
			return

	if normalized >= 1.0:
		_reset_to_base()
		_switch_to_idle_if_current(_state)


func _apply_loop_pose(anim_time: float) -> void:
	if _target == null:
		return

	match _state:
		AnimState.IDLE:
			var period_idle: float = maxf(float(_params["idle_period"]), 0.01)
			var amp: float = float(_params["idle_amplitude"])
			var phase_idle: float = anim_time / period_idle * TAU
			_target.position = Vector2(_base_position.x, _base_position.y + sin(phase_idle) * amp)
			_target.rotation = _base_rotation
			_target.scale = _base_scale

		AnimState.MOVE:
			var period_move: float = maxf(float(_params["move_period"]), 0.01)
			var tilt_rad: float = deg_to_rad(float(_params["move_tilt_deg"]))
			var stride: float = float(_params["move_stride_px"])
			var phase_move: float = anim_time / period_move * TAU
			_target.position = Vector2(_base_position.x + sin(phase_move) * stride, _base_position.y)
			_target.rotation = _base_rotation + sin(phase_move) * tilt_rad
			_target.scale = _base_scale

		AnimState.BENCH:
			var period_bench: float = maxf(float(_params["bench_period"]), 0.01)
			var tilt_bench: float = deg_to_rad(float(_params["bench_tilt_deg"]))
			var phase_bench: float = anim_time / period_bench * TAU
			_target.position = _base_position
			_target.scale = _base_scale
			_target.rotation = _base_rotation + sin(phase_bench) * tilt_bench

		AnimState.VICTORY:
			var period_victory: float = maxf(float(_params["victory_period"]), 0.05)
			var jump_height: float = float(_params["victory_jump_height"])
			var pulse_scale: float = maxf(float(_params["victory_pulse_scale"]), 1.0)
			var phase_victory: float = anim_time / period_victory * TAU
			var jump_ratio: float = maxf(sin(phase_victory), 0.0)
			_target.position = Vector2(_base_position.x, _base_position.y - jump_ratio * jump_height)
			var pulse_ratio: float = sin(phase_victory) * 0.5 + 0.5
			var current_scale: float = 1.0 + (pulse_scale - 1.0) * pulse_ratio
			_target.scale = _base_scale * current_scale
			_target.rotation = _base_rotation

		_:
			pass


func _normalize_base_before_state(state: int) -> void:
	if _target == null:
		return

	# 状态切换前先回到静止基准，避免循环动画偏移累积导致“漂移”。
	# 旋转在静止态下必须恒为 0，防止对象池残留角度被二次采样。
	_target.rotation = 0.0
	if not _has_rest_transform:
		_target.scale = Vector2.ONE
		_target.position = Vector2.ZERO

	if _has_rest_transform:
		_target.position = _rest_position
		_target.scale = _rest_scale
		_target.rotation = _rest_rotation
		if _target is CanvasItem:
			(_target as CanvasItem).modulate = _rest_modulate

	# 防止 DEATH 动画残留 alpha 影响后续状态。
	if _target is CanvasItem and state != AnimState.DEATH:
		var canvas: CanvasItem = _target as CanvasItem
		var c: Color = canvas.modulate
		c.a = 1.0
		canvas.modulate = c


func _resolve_target() -> void:
	if _target != null and is_instance_valid(_target):
		return

	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node2D
	if _target == null:
		# 未指定 target_path 时默认作用于父节点，便于快速复用。
		_target = get_parent() as Node2D


func _cache_base_transform() -> void:
	if _target == null:
		return

	if not _has_rest_transform:
		# 首次缓存时，以当前姿态作为“静止基准”。
		_rest_position = _target.position
		_rest_scale = _target.scale
		# VisualRoot 的静止角度恒为 0，禁止从当前帧采样，避免倾斜基准污染。
		_rest_rotation = 0.0
		if _target is CanvasItem:
			_rest_modulate = (_target as CanvasItem).modulate
		_has_rest_transform = true

	# 关键修复：后续状态切换始终沿用 rest transform，
	# 避免在 MOVE 中途切状态时把瞬时偏移误记成新的 base。
	_base_position = _rest_position
	_base_scale = _rest_scale
	_base_rotation = _rest_rotation
	if _target is CanvasItem:
		_base_modulate = _rest_modulate


func update_rest_position(new_position: Vector2) -> void:
	# 仅更新静止位置，适合“格子位移完成后”修正漂移锚点。
	_rest_position = new_position
	_rest_rotation = 0.0
	_base_position = new_position
	_base_rotation = 0.0
	_has_rest_transform = true


func sync_rest_transform_to_current() -> void:
	# 以当前 target 姿态重建 rest/base，避免坐标系假设错误。
	_resolve_target()
	if _target == null:
		return
	_rest_position = _target.position
	_rest_scale = _target.scale
	_rest_rotation = 0.0
	if _target is CanvasItem:
		_rest_modulate = (_target as CanvasItem).modulate
	_base_position = _rest_position
	_base_scale = _rest_scale
	_base_rotation = _rest_rotation
	if _target is CanvasItem:
		_base_modulate = _rest_modulate
	_has_rest_transform = true


func force_reset_rest_transform() -> void:
	# 对外统一暴露的“强制重置锚点”接口：
	# - 用于对象池复用、战后重置和异常姿态兜底
	# - 目标是把 VisualRoot 恢复到绝对干净的静止态
	_resolve_target()
	if _target == null:
		return
	_stop_tween()
	_clear_impulse_state()
	_loop_state_active = false
	_target.position = Vector2.ZERO
	_target.scale = Vector2.ONE
	_target.rotation = 0.0
	if _target is CanvasItem:
		(_target as CanvasItem).modulate = Color(1, 1, 1, 1)
	_has_rest_transform = false
	_cache_base_transform()
	_state = AnimState.IDLE
	set_process(false)


func _reset_to_base() -> void:
	if _target == null:
		return
	_target.position = _base_position
	_target.scale = _base_scale
	_target.rotation = _base_rotation
	if _target is CanvasItem:
		(_target as CanvasItem).modulate = _base_modulate


func _stop_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func _clear_impulse_state() -> void:
	_impulse_anim_time = 0.0
	_impulse_duration = 0.0
	_impulse_direction = Vector2.ZERO


func _switch_to_idle_if_current(expected_state: int) -> void:
	if _state == expected_state:
		play_state(AnimState.IDLE)


func _play_attack(direction: Vector2) -> void:
	_reset_to_base()
	var dash_dir: Vector2 = direction.normalized()
	if dash_dir.is_zero_approx():
		dash_dir = Vector2.RIGHT
	_impulse_direction = dash_dir
	_impulse_duration = maxf(float(_params["attack_duration"]), 0.01) * 2.0
	_impulse_anim_time = 0.0
	set_process(true)
	_apply_impulse_pose()


func _play_skill() -> void:
	_reset_to_base()
	_tween = create_tween()

	var scale_y: float = float(_params["skill_scale_y"])
	var flash_count: int = maxi(int(_params["skill_flash_count"]), 1)
	var stretch: Vector2 = Vector2(_base_scale.x * 0.92, _base_scale.y * scale_y)
	_tween.tween_property(_target, "scale", stretch, 0.08).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_target, "scale", _base_scale, 0.08).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)

	if _target is CanvasItem:
		var canvas: CanvasItem = _target as CanvasItem
		for i in range(flash_count):
			_tween.tween_property(canvas, "modulate", Color(1.4, 1.35, 1.2, 1.0), 0.05)
			_tween.tween_property(canvas, "modulate", _base_modulate, 0.05)

	_tween.finished.connect(func() -> void:
		_switch_to_idle_if_current(AnimState.SKILL)
	)


func _play_hit(direction: Vector2) -> void:
	_reset_to_base()
	var back_dir: Vector2 = -direction.normalized()
	if back_dir.is_zero_approx():
		back_dir = Vector2.LEFT
	_impulse_direction = back_dir
	_impulse_duration = maxf(float(_params["hit_flash_duration"]), 0.01) * 1.2
	_impulse_anim_time = 0.0
	set_process(true)
	_apply_impulse_pose()


func _play_death() -> void:
	_reset_to_base()
	_tween = create_tween()

	var duration: float = maxf(float(_params["death_duration"]), 0.01)
	_tween.parallel().tween_property(_target, "scale", _base_scale * 0.2, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.parallel().tween_property(_target, "position:y", _base_position.y + 12.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	if _target is CanvasItem:
		_tween.parallel().tween_property(_target, "modulate:a", 0.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

	_tween.finished.connect(func() -> void:
		# 死亡状态通常由外部管理，不自动切回 IDLE。
		_stop_tween()
		# M5-FIX: 死亡动画结束后隐藏单位根节点，防止后续状态切换把尸体重新显示。
		var unit_root: Node = _target.get_parent() if _target != null else null
		if unit_root != null and unit_root is CanvasItem:
			(unit_root as CanvasItem).visible = false
	)
