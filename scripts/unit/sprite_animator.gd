extends Node

# ===========================
# 程序化精灵动画器（Tween 驱动）
# ===========================
# 设计约束（严格按总纲）：
# - 不使用序列帧动画。
# - 通过 Tween 与属性变化模拟动作状态。
# - 支持角色 JSON 中 animation_overrides 覆盖默认参数。

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
	"bench_tilt_deg": 3.0,
	"bench_period": 2.0
}


func _ready() -> void:
	_resolve_target()
	_cache_base_transform()
	play_state(AnimState.IDLE)


func set_overrides(overrides: Dictionary) -> void:
	# 允许 JSON 只覆盖部分字段，未给出的参数继续沿用默认值。
	for key in overrides.keys():
		if _params.has(key):
			_params[key] = overrides[key]


func play_state(state: int, context: Dictionary = {}) -> void:
	_resolve_target()
	if _target == null:
		return

	_state = state
	_stop_tween()
	_normalize_base_before_state(_state)
	_cache_base_transform()

	match _state:
		AnimState.IDLE:
			_play_idle()
		AnimState.MOVE:
			_play_move()
		AnimState.ATTACK:
			_play_attack(context.get("direction", Vector2.RIGHT))
		AnimState.SKILL:
			_play_skill()
		AnimState.HIT:
			_play_hit(context.get("direction", Vector2.LEFT))
		AnimState.DEATH:
			_play_death()
		AnimState.VICTORY:
			_play_victory()
		AnimState.BENCH:
			_play_bench()
		_:
			_play_idle()


func _normalize_base_before_state(state: int) -> void:
	if _target == null:
		return

	# 修复拖放累积偏移：
	# 状态切换前统一回到静止基准，避免 MOVE/IDLE 切换时把中间帧偏移当成新基准。
	if _has_rest_transform:
		_target.position = _rest_position
		_target.scale = _rest_scale
		_target.rotation = _rest_rotation
		if _target is CanvasItem:
			(_target as CanvasItem).modulate = _rest_modulate

	# 避免 DEATH 等状态残留透明度影响后续可见性。
	if _target is CanvasItem and state != AnimState.DEATH:
		var canvas: CanvasItem = _target as CanvasItem
		canvas.modulate.a = maxf(canvas.modulate.a, 1.0)


func _resolve_target() -> void:
	if _target != null and is_instance_valid(_target):
		return

	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node2D

	# 未指定 target_path 时默认取父节点，便于快速挂载。
	if _target == null:
		_target = get_parent() as Node2D


func _cache_base_transform() -> void:
	if _target == null:
		return
	_base_position = _target.position
	_base_scale = _target.scale
	_base_rotation = _target.rotation
	if _target is CanvasItem:
		_base_modulate = (_target as CanvasItem).modulate

	if not _has_rest_transform:
		_rest_position = _base_position
		_rest_scale = _base_scale
		_rest_rotation = _base_rotation
		_rest_modulate = _base_modulate
		_has_rest_transform = true


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


func _play_idle() -> void:
	_reset_to_base()
	_tween = create_tween()
	_tween.set_loops()

	var amp: float = float(_params["idle_amplitude"])
	var half_period: float = float(_params["idle_period"]) * 0.5
	_tween.tween_property(_target, "position:y", _base_position.y - amp, half_period).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(_target, "position:y", _base_position.y + amp, half_period).set_trans(Tween.TRANS_SINE)


func _play_move() -> void:
	_reset_to_base()
	_tween = create_tween()
	_tween.set_loops()

	var tilt_rad: float = deg_to_rad(float(_params["move_tilt_deg"]))
	var period: float = float(_params["move_period"])
	var stride: float = float(_params["move_stride_px"])

	_tween.parallel().tween_property(_target, "rotation", tilt_rad, period).set_trans(Tween.TRANS_SINE)
	_tween.parallel().tween_property(_target, "position:x", _base_position.x + stride, period).set_trans(Tween.TRANS_SINE)
	_tween.tween_interval(period)
	_tween.parallel().tween_property(_target, "rotation", -tilt_rad, period).set_trans(Tween.TRANS_SINE)
	_tween.parallel().tween_property(_target, "position:x", _base_position.x - stride, period).set_trans(Tween.TRANS_SINE)
	_tween.tween_interval(period)


func _play_attack(direction: Vector2) -> void:
	_reset_to_base()
	_tween = create_tween()

	var dash_distance: float = float(_params["attack_dash_distance"])
	var duration: float = float(_params["attack_duration"])
	var dash_dir: Vector2 = direction.normalized()
	if dash_dir.is_zero_approx():
		dash_dir = Vector2.RIGHT

	var forward: Vector2 = _base_position + dash_dir * dash_distance
	_tween.tween_property(_target, "position", forward, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_target, "position", _base_position, duration).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	_tween.finished.connect(func() -> void:
		if _state == AnimState.ATTACK:
			play_state(AnimState.IDLE)
	)


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
		if _state == AnimState.SKILL:
			play_state(AnimState.IDLE)
	)


func _play_hit(direction: Vector2) -> void:
	_reset_to_base()
	_tween = create_tween()

	var knockback: float = float(_params["hit_knockback"])
	var flash_duration: float = float(_params["hit_flash_duration"])
	var back_dir: Vector2 = -direction.normalized()
	if back_dir.is_zero_approx():
		back_dir = Vector2.LEFT

	var hit_pos: Vector2 = _base_position + back_dir * knockback
	_tween.tween_property(_target, "position", hit_pos, flash_duration * 0.6).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(_target, "position", _base_position, flash_duration * 0.6).set_trans(Tween.TRANS_SINE)

	if _target is CanvasItem:
		var canvas: CanvasItem = _target as CanvasItem
		_tween.parallel().tween_property(canvas, "modulate", Color(1.6, 0.4, 0.4, 1.0), flash_duration * 0.5)
		_tween.parallel().tween_property(canvas, "modulate", _base_modulate, flash_duration * 0.7)

	_tween.finished.connect(func() -> void:
		if _state == AnimState.HIT:
			play_state(AnimState.IDLE)
	)


func _play_death() -> void:
	_reset_to_base()
	_tween = create_tween()

	var duration: float = float(_params["death_duration"])
	_tween.parallel().tween_property(_target, "scale", _base_scale * 0.2, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.parallel().tween_property(_target, "position:y", _base_position.y + 12.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	if _target is CanvasItem:
		_tween.parallel().tween_property(_target, "modulate:a", 0.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


func _play_victory() -> void:
	_reset_to_base()
	_tween = create_tween()
	_tween.set_loops()

	var jump_height: float = float(_params["victory_jump_height"])
	var pulse_scale: float = float(_params["victory_pulse_scale"])
	_tween.parallel().tween_property(_target, "position:y", _base_position.y - jump_height, 0.22).set_trans(Tween.TRANS_SINE)
	_tween.parallel().tween_property(_target, "scale", _base_scale * pulse_scale, 0.22).set_trans(Tween.TRANS_SINE)
	_tween.parallel().tween_property(_target, "position:y", _base_position.y, 0.22).set_trans(Tween.TRANS_BOUNCE)
	_tween.parallel().tween_property(_target, "scale", _base_scale, 0.22).set_trans(Tween.TRANS_SINE)


func _play_bench() -> void:
	_reset_to_base()
	_tween = create_tween()
	_tween.set_loops()

	var tilt: float = deg_to_rad(float(_params["bench_tilt_deg"]))
	var half_period: float = float(_params["bench_period"]) * 0.5
	_tween.tween_property(_target, "rotation", tilt, half_period).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(_target, "rotation", -tilt, half_period).set_trans(Tween.TRANS_SINE)
