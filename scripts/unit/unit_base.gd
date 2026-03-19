extends Node2D

# ===========================
# 角色基类（M1/M2）
# ===========================
# 目标：
# 1. 承载角色基础属性与运行态属性。
# 2. 组合战斗、移动、动画组件（组合优于继承）。
# 3. 支持拖拽部署、升星、状态切换的可视化反馈。

signal drag_started(unit: Node)
signal drag_updated(unit: Node, world_position: Vector2)
signal drag_ended(unit: Node, world_position: Vector2)
signal star_changed(unit: Node, previous_star: int, next_star: int)

@onready var visual_root: Node2D = $VisualRoot
@onready var sprite_2d: Sprite2D = $VisualRoot/Sprite2D
@onready var name_label: Label = $VisualRoot/NameLabel
@onready var star_label: Label = $VisualRoot/StarLabel

@onready var combat_component: Node = $Components/UnitCombat
@onready var movement_component: Node = $Components/UnitMovement
@onready var sprite_animator: Node = $SpriteAnimator

var pool_key: String = ""

var unit_id: String = ""
var unit_name: String = ""
var faction: String = ""
var quality: String = "white"
var role: String = "vanguard"
var cost: int = 1

var initial_gongfa: Array[String] = []
var gongfa_slots: Dictionary = {
	"neigong": "",
	"waigong": "",
	"qinggong": "",
	"zhenfa": "",
	"qishu": ""
}
var max_gongfa_count: int = 3
var animation_overrides: Dictionary = {}

var base_stats: Dictionary = {}
var runtime_stats: Dictionary = {}
var runtime_linkage_tags: Array[String] = []
var runtime_gongfa_elements: Array[String] = []
var runtime_equipped_gongfa_ids: Array[String] = []

var star_level: int = 1
var max_star: int = 3
var tags: Array[String] = []

var sprite_path: String = ""
var portrait_path: String = ""

var team_id: int = 1
var battle_uid: int = -1
var is_in_combat: bool = false

var is_on_bench: bool = true
var bench_slot_index: int = -1
var deployed_cell: Vector2i = Vector2i(-999, -999)
var is_dragging: bool = false
var _pending_texture: Texture2D = null


func _ready() -> void:
	_bind_components()
	if not unit_id.is_empty():
		_apply_runtime_stats()
		_apply_animation_overrides()
	_refresh_visual()
	_apply_pending_texture_if_needed()


func _process(delta: float) -> void:
	# 移动组件在 M1 中主要用于拖拽后的缓动归位，后续可接入路径点导航。
	if movement_component != null:
		movement_component.call("tick", delta)


func setup_from_unit_record(unit_record: Dictionary, forced_star: int = -1) -> void:
	unit_id = str(unit_record.get("id", ""))
	unit_name = str(unit_record.get("name", unit_id))
	faction = str(unit_record.get("faction", "jianghu"))
	quality = str(unit_record.get("quality", "white"))
	role = str(unit_record.get("role", "vanguard"))
	cost = int(unit_record.get("cost", 1))

	base_stats = (unit_record.get("base_stats", {}) as Dictionary).duplicate(true)

	initial_gongfa.clear()
	if unit_record.get("initial_gongfa", []) is Array:
		for gongfa_id in unit_record["initial_gongfa"]:
			initial_gongfa.append(str(gongfa_id))

	gongfa_slots = {
		"neigong": "",
		"waigong": "",
		"qinggong": "",
		"zhenfa": "",
		"qishu": ""
	}
	if unit_record.get("gongfa_slots", {}) is Dictionary:
		var slots_raw: Dictionary = unit_record["gongfa_slots"]
		for slot in gongfa_slots.keys():
			gongfa_slots[slot] = str(slots_raw.get(slot, ""))
	max_gongfa_count = clampi(int(unit_record.get("max_gongfa_count", 3)), 1, 5)

	animation_overrides = {}
	if unit_record.get("animation_overrides", {}) is Dictionary:
		animation_overrides = (unit_record["animation_overrides"] as Dictionary).duplicate(true)

	base_star_set(unit_record, forced_star)
	sprite_path = str(unit_record.get("sprite_path", ""))
	portrait_path = str(unit_record.get("portrait_path", ""))

	tags.clear()
	if unit_record.get("tags", []) is Array:
		for tag in unit_record["tags"]:
			tags.append(str(tag))

	_apply_runtime_stats()
	_bind_components()
	if is_node_ready():
		_apply_animation_overrides()
		_refresh_visual()
		_apply_pending_texture_if_needed()

	is_on_bench = true
	deployed_cell = Vector2i(-999, -999)
	is_dragging = false
	team_id = 1
	battle_uid = -1
	is_in_combat = false
	runtime_linkage_tags.clear()
	runtime_gongfa_elements.clear()
	runtime_equipped_gongfa_ids = get_equipped_gongfa_ids()


func base_star_set(unit_record: Dictionary, forced_star: int) -> void:
	var base_star: int = clampi(int(unit_record.get("base_star", 1)), 1, 3)
	max_star = clampi(int(unit_record.get("max_star", 3)), 1, 3)
	if forced_star > 0:
		star_level = clampi(forced_star, 1, max_star)
	else:
		star_level = clampi(base_star, 1, max_star)


func set_display_texture(texture: Texture2D) -> void:
	_pending_texture = texture
	_apply_pending_texture_if_needed()


func set_star_level(next_star: int) -> void:
	var clamped: int = clampi(next_star, 1, max_star)
	if clamped == star_level:
		return
	var previous: int = star_level
	star_level = clamped

	_apply_runtime_stats()
	_refresh_visual()
	_apply_animation_overrides()

	if sprite_animator != null:
		sprite_animator.call("play_state", 3, {}) # SKILL 动画用于升星特效反馈
	star_changed.emit(self, previous, star_level)


func set_on_bench_state(value: bool, slot_index: int = -1) -> void:
	is_on_bench = value
	bench_slot_index = slot_index if value else -1

	if sprite_animator == null:
		return
	if is_on_bench:
		sprite_animator.call("play_state", 7, {}) # BENCH
	else:
		# 离开备战席时立即归零旋转，防止继承 BENCH 摇摆角度。
		if visual_root != null:
			visual_root.position = Vector2.ZERO
			visual_root.scale = Vector2.ONE
			visual_root.rotation = 0.0
		sprite_animator.call("play_state", 0, {}) # IDLE


func set_team(value: int) -> void:
	team_id = value
	_refresh_visual()


func enter_combat() -> void:
	is_in_combat = true
	is_on_bench = false
	bench_slot_index = -1
	play_anim_state(0, {})


func leave_combat() -> void:
	is_in_combat = false
	play_anim_state(0, {})


func play_anim_state(state: int, context: Dictionary = {}) -> void:
	if sprite_animator == null:
		return
	sprite_animator.call("play_state", state, context)


func contains_point(world_position: Vector2) -> bool:
	# 角色拾取检测：
	# - 若有贴图，使用贴图矩形范围。
	# - 若无贴图，使用默认 16 像素半径圆形区域。
	if sprite_2d != null and sprite_2d.texture != null:
		var tex_size: Vector2 = sprite_2d.texture.get_size()
		# 需要计入全局缩放（单位缩放 + 视觉节点缩放），否则缩放后拾取范围会失真。
		var scale_abs: Vector2 = sprite_2d.global_scale.abs()
		var scaled_size: Vector2 = Vector2(tex_size.x * scale_abs.x, tex_size.y * scale_abs.y)
		var rect: Rect2 = Rect2(sprite_2d.global_position - scaled_size * 0.5, scaled_size)
		return rect.has_point(world_position)

	return global_position.distance_to(world_position) <= 16.0


func set_compact_visual_mode(is_compact: bool) -> void:
	# M2 大规模战斗时隐藏名称/星级文本，降低画面噪音并减少 UI 重叠。
	if name_label != null:
		name_label.visible = not is_compact
	if star_label != null:
		star_label.visible = not is_compact


func begin_drag() -> void:
	if is_in_combat:
		return
	is_dragging = true
	z_index = 200
	# 从备战席拖拽时，先清空摇摆残留角度，确保拖拽姿态端正。
	if visual_root != null:
		visual_root.position = Vector2.ZERO
		visual_root.scale = Vector2.ONE
		visual_root.rotation = 0.0
	play_anim_state(1, {}) # MOVE
	drag_started.emit(self)


func update_drag(world_position: Vector2) -> void:
	if not is_dragging:
		return
	global_position = world_position
	drag_updated.emit(self, world_position)


func end_drag(world_position: Vector2) -> void:
	if not is_dragging:
		return
	is_dragging = false
	z_index = 0
	if visual_root != null:
		visual_root.position = Vector2.ZERO
		visual_root.scale = Vector2.ONE
		visual_root.rotation = 0.0
	drag_ended.emit(self, world_position)


func _apply_runtime_stats() -> void:
	# 角色运行时属性由 UnitData 统一按星级倍率计算，便于后续做统一平衡。
	var unit_data_script: Script = load("res://scripts/data/unit_data.gd")
	runtime_stats = unit_data_script.call("build_runtime_stats", base_stats, star_level)
	runtime_equipped_gongfa_ids = get_equipped_gongfa_ids()

	if combat_component != null:
		combat_component.call("reset_from_stats", runtime_stats)
	if movement_component != null:
		movement_component.call("reset_from_stats", runtime_stats)


func get_equipped_gongfa_ids() -> Array[String]:
	# 槽位顺序固定，保证 UI 展示和触发优先级稳定可预期。
	var ids: Array[String] = []
	var ordered_slots: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa", "qishu"]
	for slot in ordered_slots:
		var gid: String = str(gongfa_slots.get(slot, "")).strip_edges()
		if gid.is_empty():
			continue
		if ids.has(gid):
			continue
		ids.append(gid)
		if ids.size() >= max_gongfa_count:
			return ids
	return ids


func _apply_animation_overrides() -> void:
	if sprite_animator != null:
		sprite_animator.call("set_overrides", animation_overrides)


func _bind_components() -> void:
	if combat_component != null:
		combat_component.call("bind_unit", self)
	if movement_component != null:
		movement_component.call("bind_unit", self)


func _refresh_visual() -> void:
	if name_label == null or star_label == null:
		return
	name_label.text = "%s" % unit_name
	star_label.text = "★".repeat(star_level)
	star_label.modulate = _get_star_color(star_level)
	modulate = _get_quality_tint(quality) * _get_team_tint(team_id)


func _apply_pending_texture_if_needed() -> void:
	if sprite_2d == null:
		return
	if _pending_texture == null:
		return
	sprite_2d.texture = _pending_texture


func _get_star_color(star: int) -> Color:
	match star:
		1:
			return Color(0.95, 0.95, 0.95, 1.0)
		2:
			return Color(1.0, 0.85, 0.25, 1.0)
		3:
			return Color(1.0, 0.45, 0.2, 1.0)
		_:
			return Color(1, 1, 1, 1)


func _get_quality_tint(q: String) -> Color:
	match q:
		"white":
			return Color(1, 1, 1, 1)
		"green":
			return Color(0.8, 1.0, 0.82, 1)
		"blue":
			return Color(0.72, 0.84, 1.0, 1)
		"purple":
			return Color(0.9, 0.72, 1.0, 1)
		"orange":
			return Color(1.0, 0.86, 0.62, 1)
		"red":
			return Color(1.0, 0.62, 0.62, 1)
		_:
			return Color(1, 1, 1, 1)


func _get_team_tint(team: int) -> Color:
	match team:
		2:
			# 敌方轻微偏红，保证大规模混战时阵营可辨识，但不压过品质色。
			return Color(1.08, 0.9, 0.9, 1.0)
		_:
			return Color(1, 1, 1, 1)
