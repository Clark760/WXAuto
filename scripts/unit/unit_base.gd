extends Node2D

# ===========================
# 角色基类
# ===========================
# 目标：
# 1. 承载角色基础属性与运行态属性。
# 2. 组合战斗、移动、动画组件（组合优于继承）。
# 3. 支持拖拽部署、升星、状态切换的可视化反馈。

const _UNIT_DATA_SCRIPT: Script = preload("res://scripts/data/unit_data.gd")

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
var max_gongfa_count: int = 5
var equip_slots: Dictionary = {
	"weapon": "",
	"armor": "",
	"accessory": ""
}
var max_equip_count: int = 3
var animation_overrides: Dictionary = {}

var base_stats: Dictionary = {}
var runtime_stats: Dictionary = {}
var runtime_linkage_tags: Array[String] = []
var runtime_gongfa_elements: Array[String] = []
var runtime_equipped_gongfa_ids: Array[String] = []
var runtime_equipped_equip_ids: Array[String] = []

var star_level: int = 1
var max_star: int = 3
var tags: Array[String] = []

var sprite_path: String = ""
var portrait_path: String = ""

var team_id: int = 1
var battle_uid: int = -1
var is_in_combat: bool = false
var _compact_visual_mode: bool = false
var _quick_step_tween: Tween = null

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
	refresh_process_state()


func _process(delta: float) -> void:
	# 移动组件统一负责拖拽归位与战场位移推进。
	if movement_component != null:
		movement_component.call("tick", delta)
		# 移动完成后关闭 process，减少空转开销。
		if not bool(movement_component.get("has_target")):
			set_process(false)


func refresh_process_state() -> void:
	var should_process: bool = false
	if is_dragging:
		should_process = true
	elif movement_component != null:
		should_process = bool(movement_component.get("has_target"))
	set_process(should_process)


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
	max_gongfa_count = clampi(int(unit_record.get("max_gongfa_count", 5)), 1, 5)

	# 装备槽位与功法槽位一样常驻在角色实例上，便于管理器直接读写。
	equip_slots = {
		"weapon": "",
		"armor": "",
		"accessory": ""
	}
	if unit_record.get("equip_slots", {}) is Dictionary:
		var equip_slots_raw: Dictionary = unit_record["equip_slots"]
		for slot in equip_slots.keys():
			equip_slots[slot] = str(equip_slots_raw.get(slot, "")).strip_edges()
	max_equip_count = clampi(int(unit_record.get("max_equip_count", 3)), 0, 3)
	# 不能在“未进入场景树”的节点上直接 get_node("/root/...")，
	# 这里改为通过 SceneTree 根节点安全查询 AutoLoad，避免初始化期报错。
	var gm: Node = _get_autoload_node("GongfaManager")
	if gm != null and not initial_gongfa.is_empty():
		var reg = gm.get("_registry")
		if reg != null:
			for item_id in initial_gongfa:
				if reg.has_equipment(item_id):
					var e_data: Dictionary = reg.get_equipment(item_id)
					var slot: String = str(e_data.get("type", "")).strip_edges()
					if slot != "" and equip_slots.get(slot, "") == "":
						equip_slots[slot] = item_id
				elif reg.has_gongfa(item_id):
					var g_data: Dictionary = reg.get_gongfa(item_id)
					var slot: String = str(g_data.get("type", "")).strip_edges()
					if slot != "" and gongfa_slots.get(slot, "") == "":
						gongfa_slots[slot] = item_id

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
	runtime_equipped_equip_ids = get_equipped_equip_ids()


func _get_autoload_node(node_name: String) -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop as SceneTree
	if tree.root == null:
		return null
	return tree.root.get_node_or_null(node_name)


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
	refresh_process_state()

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
	_apply_label_visibility()
	play_anim_state(0, {})
	refresh_process_state()


func leave_combat() -> void:
	is_in_combat = false
	_apply_label_visibility()
	play_anim_state(0, {})
	refresh_process_state()


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
	# M4：紧凑模式下不再“一刀切”隐藏文本。
	# 战斗中强制显示名称/星级，非战斗时按 compact 规则显示。
	_compact_visual_mode = is_compact
	_apply_label_visibility()


func play_quick_cell_step(target_world: Vector2, duration: float = 0.08) -> void:
	# 严格六角格模式里，逻辑占格已经瞬时完成。
	# 这里补一段很短的视觉位移动画，避免看起来像瞬移。
	if movement_component != null:
		movement_component.call("clear_target")

	var unit_node: Node2D = self

	if unit_node.position.distance_to(target_world) <= 0.5:
		unit_node.position = target_world
		return

	var step_duration: float = clampf(duration, 0.03, 0.14)
	if _quick_step_tween != null and _quick_step_tween.is_valid():
		_quick_step_tween.kill()
	_quick_step_tween = create_tween()
	_quick_step_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_quick_step_tween.tween_property(unit_node, "position", target_world, step_duration)


func begin_drag() -> void:
	if is_in_combat:
		return
	is_dragging = true
	refresh_process_state()
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
	refresh_process_state()
	z_index = 0
	if visual_root != null:
		visual_root.position = Vector2.ZERO
		visual_root.scale = Vector2.ONE
		visual_root.rotation = 0.0
	drag_ended.emit(self, world_position)


func _apply_runtime_stats() -> void:
	# 角色运行时属性由 UnitData 统一按星级倍率计算，便于后续做统一平衡。
	runtime_stats = _UNIT_DATA_SCRIPT.call("build_runtime_stats", base_stats, star_level)
	runtime_equipped_gongfa_ids = get_equipped_gongfa_ids()
	runtime_equipped_equip_ids = get_equipped_equip_ids()

	if combat_component != null:
		combat_component.call("reset_from_stats", runtime_stats)
	if movement_component != null:
		movement_component.call("reset_from_stats", runtime_stats)


func get_equipped_gongfa_ids() -> Array[String]:
	# 槽位顺序固定，保证 UI 展示和触发优先级稳定可预期。
	# 规则修正：功法按“类型槽位”装备，不再按总数量上限截断。
	var ids: Array[String] = []
	var ordered_slots: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa", "qishu"]
	for slot in ordered_slots:
		var gid: String = str(gongfa_slots.get(slot, "")).strip_edges()
		if gid.is_empty():
			continue
		if ids.has(gid):
			continue
		ids.append(gid)
	return ids


func get_equipped_equip_ids() -> Array[String]:
	# 装备槽位顺序固定，保证详情展示与属性重算顺序稳定。
	var ids: Array[String] = []
	var ordered_slots: Array[String] = ["weapon", "armor", "accessory"]
	for slot in ordered_slots:
		var equip_id: String = str(equip_slots.get(slot, "")).strip_edges()
		if equip_id.is_empty():
			continue
		if ids.has(equip_id):
			continue
		ids.append(equip_id)
		if ids.size() >= max_equip_count:
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
	name_label.modulate = _get_team_name_color(team_id)
	_apply_label_visibility()
	modulate = _get_quality_tint(quality) * _get_team_tint(team_id)


func _apply_label_visibility() -> void:
	# 中文说明：
	# 1) 战斗中始终显示名称与星级，便于读场面和找单位。
	# 2) 非战斗阶段遵循 compact 模式，避免日常界面过密。
	var should_show_labels: bool = is_in_combat or not _compact_visual_mode
	if name_label != null:
		name_label.visible = should_show_labels
	if star_label != null:
		star_label.visible = should_show_labels


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


func _get_team_name_color(team: int) -> Color:
	match team:
		2:
			# 敌方名称暖红，突出敌我辨识。
			return Color(1.0, 0.45, 0.45, 1.0)
		1:
			# 我方名称青蓝，和敌方颜色形成明显对比。
			return Color(0.58, 0.9, 1.0, 1.0)
		_:
			return Color(0.9, 0.9, 0.9, 1.0)


func _get_team_tint(team: int) -> Color:
	match team:
		2:
			# 敌方轻微偏红，保证大规模混战时阵营可辨识，但不压过品质色。
			return Color(1.08, 0.9, 0.9, 1.0)
		_:
			return Color(1, 1, 1, 1)
