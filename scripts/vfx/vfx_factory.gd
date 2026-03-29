extends Node2D
class_name VfxFactory

const LIGHTWEIGHT_CANVAS_TEXT_SCRIPT: Script = preload("res://scripts/ui/lightweight_canvas_text.gd")

# ===========================
# 程序化特效工厂
# ===========================
# 优化要点：
# 1. 伤害数字不再每次创建 Tween，改为 _process 批量更新。
# 2. 粒子特效改为集中生命周期管理，不再每次创建 SceneTreeTimer。
# 3. 增加屏幕外裁剪 + 活跃粒子上限节流，避免 GPU/CPU 双重抖动。

const PROBE_SCOPE_VFX_FACTORY_PROCESS: String = "vfx_factory_process"

const DAMAGE_TEXT_POOL_KEY: String = "vfx:damage_text"
const PARTICLE_POOL_PREFIX: String = "vfx:particles:"
const DAMAGE_TEXT_DRAW_SIZE: Vector2 = Vector2(72.0, 24.0)

@export var damage_text_lifetime: float = 0.36
@export var damage_text_rise_distance: float = 26.0
@export var damage_text_jitter_x: float = 8.0
@export var max_active_damage_texts: int = 16
@export var damage_text_skip_ratio_when_busy: float = 0.82
@export var max_active_particles: int = 16
@export var particle_skip_ratio_when_busy: float = 0.82
@export var particle_cull_margin: float = 120.0

var _vfx_records: Dictionary = {}
var _registered_particle_pools: Dictionary = {}
var _white_texture: Texture2D = null

var _active_texts: Array[Dictionary] = []      # {label, start_pos, elapsed, lifetime}
var _active_particles: Array[Dictionary] = []   # {pool_key, node, elapsed, lifetime}

var _rng := RandomNumberGenerator.new()
var _cached_event_bus: Node = null
var _cached_data_manager: Node = null
var _cached_object_pool: Node = null
var _services: ServiceRegistry = null

# 绑定 bind runtime services
func bind_runtime_services(services: ServiceRegistry) -> void:
	_disconnect_event_bus(_cached_event_bus)
	_services = services
	_cached_event_bus = null
	_cached_data_manager = null
	_cached_object_pool = null
	if is_inside_tree():
		_register_damage_text_pool()
		reload_from_data()
		_connect_event_bus()

# 处理 ready
func _ready() -> void:
	_rng.randomize()
	_ensure_white_texture()
	_register_damage_text_pool()
	reload_from_data()
	_connect_event_bus()
	set_process(false)

# 处理 process
func _process(delta: float) -> void:
	var process_begin_us: int = _probe_begin_timing()
	_update_damage_texts(delta)
	_update_particles(delta)
	_refresh_processing_state()
	_probe_commit_timing(PROBE_SCOPE_VFX_FACTORY_PROCESS, process_begin_us)





# 重载 reload from data
func reload_from_data() -> void:
	_vfx_records.clear()
	_registered_particle_pools.clear()

	var data_manager: Node = _get_data_manager()
	if data_manager == null:
		return

	var records_value: Variant = data_manager.call("get_all_records", "vfx")
	if records_value is Array:
		for item in records_value:
			if not (item is Dictionary):
				continue
			var record: Dictionary = (item as Dictionary).duplicate(true)
			var vfx_id: String = str(record.get("id", "")).strip_edges()
			if vfx_id.is_empty():
				continue
			_vfx_records[vfx_id] = record



# 处理 play attack vfx
func play_attack_vfx(vfx_id: String, from_world: Vector2, to_world: Vector2) -> void:
	var record: Dictionary = _resolve_record(vfx_id)
	if record.is_empty():
		return
	if str(record.get("type", "particles")) != "particles":
		return

	# 节流策略：
	# 1) 屏幕内裁剪：起点和终点都在屏幕外时直接跳过。
	# 2) 活跃粒子硬上限：超过后立即拒绝。
	# 3) 高负载随机丢帧：靠概率削峰，换稳定帧率。
	if not _is_in_viewport(from_world) and not _is_in_viewport(to_world):
		return
	if _active_particles.size() >= max_active_particles:
		return
	var busy_threshold: int = maxi(int(float(max_active_particles) * 0.6), 1)
	if _active_particles.size() >= busy_threshold and _rng.randf() < clampf(particle_skip_ratio_when_busy, 0.0, 0.95):
		return

	var pool_key: String = _particle_pool_key(vfx_id)
	_register_particle_pool_if_needed(vfx_id, pool_key)

	var object_pool: Node = _get_object_pool()
	if object_pool == null:
		return

	var node_value: Variant = object_pool.call("acquire", pool_key, self)
	var particles: GPUParticles2D = node_value as GPUParticles2D
	if particles == null:
		return

	particles.position = from_world
	particles.rotation = (to_world - from_world).angle()
	particles.emitting = false
	particles.restart()
	particles.emitting = true
	particles.visible = true
	particles.z_index = 100

	var lifetime: float = maxf(float(record.get("lifetime", 0.3)), 0.05) + 0.1
	_active_particles.append({
		"pool_key": pool_key,
		"node": particles,
		"elapsed": 0.0,
		"lifetime": lifetime
	})
	_refresh_processing_state()

# 处理 spawn damage text
func spawn_damage_text(world_position: Vector2, amount: float, is_crit: bool = false, is_dodge: bool = false) -> void:
	# 屏幕外伤害数字不显示，避免无意义 UI 开销。
	if not _is_in_viewport(world_position):
		return

	var object_pool: Node = _get_object_pool()
	if object_pool == null:
		return

	var node_value: Variant = object_pool.call("acquire", DAMAGE_TEXT_POOL_KEY, self)
	var label = node_value
	if label == null:
		return

	label.visible = true
	label.modulate = Color(1, 1, 1, 1)
	label.scale = Vector2.ONE
	label.z_index = 200
	label.position = world_position + Vector2(
		_rng.randf_range(-damage_text_jitter_x, damage_text_jitter_x) - DAMAGE_TEXT_DRAW_SIZE.x * 0.5,
		-18.0
	)

	if is_dodge:
		label.text = "闪避"
		label.modulate = Color(0.75, 0.9, 1.0, 1.0)
	elif is_crit:
		label.text = "-%d" % int(round(amount))
		label.modulate = Color(1.0, 0.82, 0.35, 1.0)
		label.scale = Vector2(1.25, 1.25)
	else:
		label.text = "-%d" % int(round(amount))
		label.modulate = Color(1.0, 0.45, 0.45, 1.0)

	_active_texts.append({
		"label": label,
		"start_pos": label.position,
		"elapsed": 0.0,
		"lifetime": maxf(damage_text_lifetime, 0.05)
	})
	_refresh_processing_state()

# 设置 update damage texts
func _update_damage_texts(delta: float) -> void:
	if _active_texts.is_empty():
		return

	var object_pool: Node = _get_object_pool()
	var i: int = _active_texts.size() - 1
	while i >= 0:
		var entry: Dictionary = _active_texts[i]
		var label = entry.get("label", null)
		if label == null or not is_instance_valid(label):
			_active_texts.remove_at(i)
			i -= 1
			continue

		var elapsed: float = float(entry.get("elapsed", 0.0)) + delta
		var lifetime: float = maxf(float(entry.get("lifetime", damage_text_lifetime)), 0.01)
		if elapsed >= lifetime:
			if object_pool != null and is_instance_valid(object_pool):
				object_pool.call("release", DAMAGE_TEXT_POOL_KEY, label)
			_active_texts.remove_at(i)
			i -= 1
			continue

		var start_pos: Vector2 = entry.get("start_pos", label.position)
		var t: float = clampf(elapsed / lifetime, 0.0, 1.0)
		label.position = Vector2(start_pos.x, start_pos.y - damage_text_rise_distance * t)
		var c: Color = label.modulate
		c.a = 1.0 - t
		label.modulate = c

		entry["elapsed"] = elapsed
		_active_texts[i] = entry
		i -= 1

# 设置 update particles
func _update_particles(delta: float) -> void:
	if _active_particles.is_empty():
		return

	var object_pool: Node = _get_object_pool()
	var i: int = _active_particles.size() - 1
	while i >= 0:
		var entry: Dictionary = _active_particles[i]
		var pool_key: String = str(entry.get("pool_key", ""))
		var particles: GPUParticles2D = entry.get("node", null) as GPUParticles2D
		if particles == null or not is_instance_valid(particles):
			_active_particles.remove_at(i)
			i -= 1
			continue

		var elapsed: float = float(entry.get("elapsed", 0.0)) + delta
		var lifetime: float = maxf(float(entry.get("lifetime", 0.1)), 0.01)
		if elapsed >= lifetime:
			particles.emitting = false
			particles.visible = false
			if object_pool != null and is_instance_valid(object_pool):
				object_pool.call("release", pool_key, particles)
			_active_particles.remove_at(i)
			i -= 1
			continue

		entry["elapsed"] = elapsed
		_active_particles[i] = entry
		i -= 1

# 规范 resolve record
func _resolve_record(vfx_id: String) -> Dictionary:
	if _vfx_records.has(vfx_id):
		return _vfx_records[vfx_id] as Dictionary
	if _vfx_records.has("vfx_sword_qi"):
		return _vfx_records["vfx_sword_qi"] as Dictionary
	return {}

# 处理 register damage text pool
func _register_damage_text_pool() -> void:
	var object_pool: Node = _get_object_pool()
	if object_pool == null:
		return
	var factory: Callable = Callable(self, "_create_damage_text_instance")
	object_pool.call("register_factory", DAMAGE_TEXT_POOL_KEY, factory, 16, self, true)

# 处理 register particle pool if needed
func _register_particle_pool_if_needed(vfx_id: String, pool_key: String) -> void:
	if _registered_particle_pools.has(pool_key):
		return

	var object_pool: Node = _get_object_pool()
	if object_pool == null:
		return

	var factory: Callable = Callable(self, "_create_particle_instance").bind(vfx_id)
	object_pool.call("register_factory", pool_key, factory, 4, self, true)
	_registered_particle_pools[pool_key] = true

# 构建 create damage text instance
func _create_damage_text_instance() -> Node:
	var label = LIGHTWEIGHT_CANVAS_TEXT_SCRIPT.new()
	label.text = "-0"
	label.draw_size = DAMAGE_TEXT_DRAW_SIZE
	label.font_size = 18
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.visible = false
	return label

# 构建 create particle instance
func _create_particle_instance(vfx_id: String) -> Node:
	var record: Dictionary = _resolve_record(vfx_id)
	var particles := GPUParticles2D.new()
	particles.one_shot = true
	particles.emitting = false
	particles.amount = maxi(int(record.get("amount", 20)), 1)
	particles.lifetime = maxf(float(record.get("lifetime", 0.35)), 0.05)
	particles.explosiveness = 1.0
	particles.visibility_rect = Rect2(Vector2(-96, -96), Vector2(192, 192))
	particles.texture = _white_texture

	var process := ParticleProcessMaterial.new()
	process.direction = Vector3.RIGHT
	process.spread = clampf(float(record.get("spread_angle", 25.0)), 0.0, 180.0)

	var speed: float = maxf(float(record.get("speed", 160.0)), 1.0)
	process.initial_velocity_min = speed * 0.65
	process.initial_velocity_max = speed * 1.05

	var gravity_value: Variant = record.get("gravity", {"x": 0.0, "y": 0.0})
	var gx: float = 0.0
	var gy: float = 0.0
	if gravity_value is Dictionary:
		gx = float((gravity_value as Dictionary).get("x", 0.0))
		gy = float((gravity_value as Dictionary).get("y", 0.0))
	process.gravity = Vector3(gx, gy, 0.0)

	var start_color: Color = _parse_color(str(record.get("color_start", "#FFFFFF")), Color(1, 1, 1, 1))
	var end_color: Color = _parse_color(str(record.get("color_end", "#88CCFF00")), Color(1, 1, 1, 0))
	process.color = start_color
	process.color_ramp = _build_color_ramp(start_color, end_color)

	var scale_curve: Array = record.get("scale_curve", [1.0, 0.35])
	var scale_from: float = 1.0
	var scale_to: float = 0.35
	if scale_curve is Array and (scale_curve as Array).size() >= 2:
		scale_from = maxf(float(scale_curve[0]), 0.01)
		scale_to = maxf(float(scale_curve[1]), 0.01)
	process.scale_min = minf(scale_from, scale_to)
	process.scale_max = maxf(scale_from, scale_to)

	particles.process_material = process
	particles.visible = false
	return particles

# 构建 build color ramp
func _build_color_ramp(start_color: Color, end_color: Color) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	gradient.colors = PackedColorArray([start_color, end_color])

	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	return ramp

# 处理 parse color
func _parse_color(value: String, fallback: Color) -> Color:
	return Color.from_string(value, fallback)

# 处理 particle pool key
func _particle_pool_key(vfx_id: String) -> String:
	return "%s%s" % [PARTICLE_POOL_PREFIX, vfx_id]

# 处理 ensure white texture
func _ensure_white_texture() -> void:
	if _white_texture != null:
		return
	var image: Image = Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 1))
	_white_texture = ImageTexture.create_from_image(image)

# 处理 refresh processing state
func _refresh_processing_state() -> void:
	# 仅在有活跃特效时开启 _process，减少空闲帧函数调度。
	set_process((not _active_texts.is_empty()) or (not _active_particles.is_empty()))


# 暴露当前活跃特效数量，供压力测试和运行时探针低频采样。
func get_runtime_activity_snapshot() -> Dictionary:
	return {
		"active_texts": _active_texts.size(),
		"active_particles": _active_particles.size()
	}

# 判断 is in viewport
func _is_in_viewport(world_pos: Vector2) -> bool:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return true
	var visible_rect: Rect2 = viewport.get_visible_rect().grow(particle_cull_margin)
	var screen_pos: Vector2 = to_global(world_pos)
	return visible_rect.has_point(screen_pos)

# 连接 disconnect event bus
func _disconnect_event_bus(event_bus: Node = null) -> void:
	var resolved_event_bus: Node = event_bus
	if resolved_event_bus == null:
		resolved_event_bus = _cached_event_bus
	if resolved_event_bus == null or not is_instance_valid(resolved_event_bus):
		return
	var cb: Callable = Callable(self, "_on_data_reloaded")
	if resolved_event_bus.is_connected("data_reloaded", cb):
		resolved_event_bus.disconnect("data_reloaded", cb)

# 连接 connect event bus
func _connect_event_bus() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null:
		return
	var cb: Callable = Callable(self, "_on_data_reloaded")
	if not event_bus.is_connected("data_reloaded", cb):
		event_bus.connect("data_reloaded", cb)

# 响应 on data reloaded
func _on_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	reload_from_data()

# 获取 get event bus
func _get_event_bus() -> Node:
	if _cached_event_bus != null and is_instance_valid(_cached_event_bus):
		return _cached_event_bus
	if _services == null:
		return null
	_cached_event_bus = _services.event_bus
	return _cached_event_bus

# 获取 get data manager
func _get_data_manager() -> Node:
	if _cached_data_manager != null and is_instance_valid(_cached_data_manager):
		return _cached_data_manager
	if _services == null:
		return null
	_cached_data_manager = _services.data_repository
	return _cached_data_manager

# 获取 get object pool
func _get_object_pool() -> Node:
	if _cached_object_pool != null and is_instance_valid(_cached_object_pool):
		return _cached_object_pool
	if _services == null:
		return null
	_cached_object_pool = _services.object_pool
	return _cached_object_pool


# VFXFactory 的独立 _process 不在 CombatManager scope 内，必须单独打点。
func _probe_begin_timing() -> int:
	var runtime_probe = _services.runtime_probe if _services != null else null
	if runtime_probe == null or not runtime_probe.has_method("begin_timing"):
		return 0
	return int(runtime_probe.begin_timing())


# 统一把 VFX 的逐帧更新写回 RuntimeProbe，便于和逻辑层成本做横向对比。
func _probe_commit_timing(scope_name: String, begin_us: int) -> void:
	var runtime_probe = _services.runtime_probe if _services != null else null
	if runtime_probe == null or not runtime_probe.has_method("commit_timing"):
		return
	runtime_probe.commit_timing(scope_name, begin_us)
