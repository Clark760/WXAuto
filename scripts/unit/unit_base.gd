extends Node2D

# ===========================
# 瑙掕壊鍩虹被
# ===========================
# 鐩爣锛?
# 1. 鎵胯浇瑙掕壊鍩虹灞炴€т笌杩愯鎬佸睘鎬с€?
# 2. 缁勫悎鎴樻枟銆佺Щ鍔ㄣ€佸姩鐢荤粍浠讹紙缁勫悎浼樹簬缁ф壙锛夈€?
# 3. 鏀寔鎷栨嫿閮ㄧ讲銆佸崌鏄熴€佺姸鎬佸垏鎹㈢殑鍙鍖栧弽棣堛€?

const _UNIT_DATA_SCRIPT: Script = preload("res://scripts/domain/unit/unit_data.gd")
const PROBE_SCOPE_UNIT_BASE_PROCESS: String = "unit_base_process"
const PROBE_SCOPE_UNIT_SETUP_FROM_RECORD: String = "unit_setup_from_record"

signal drag_started(unit: Node)
signal drag_updated(unit: Node, world_position: Vector2)
signal drag_ended(unit: Node, world_position: Vector2)
signal star_changed(unit: Node, previous_star: int, next_star: int)

@onready var visual_root: Node2D = $VisualRoot

@onready var combat_component: Node = $Components/UnitCombat
@onready var movement_component: Node = $Components/UnitMovement
@onready var sprite_animator: Node = $SpriteAnimator

var pool_key: String = ""

var unit_id: String = ""
var unit_name: String = ""
var quality: String = "white"
var cost: int = 1

var initial_gongfa: Array[String] = []
var traits: Array[Dictionary] = []
var gongfa_slots: Dictionary = {
	"neigong": "",
	"waigong": "",
	"qinggong": "",
	"zhenfa": ""
}
var equip_slots: Dictionary = {
	"slot_1": "",
	"slot_2": ""
}
var max_equip_count: int = 2
var animation_overrides: Dictionary = {}

var base_stats: Dictionary = {}
var runtime_stats: Dictionary = {}
var runtime_equipped_gongfa_ids: Array[String] = []
var runtime_equipped_equip_ids: Array[String] = []

var star_level: int = 1
var max_star: int = 3
var tags: Array[String] = []

var sprite_path: String = ""
var portrait_path: String = ""
var _services: ServiceRegistry = null

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

# 缁戝畾 bind runtime services
func bind_runtime_services(services: ServiceRegistry) -> void:
	_services = services

# 澶勭悊 ready
func _ready() -> void:
	_bind_components()
	if not unit_id.is_empty():
		_apply_runtime_stats()
		_apply_animation_overrides()
	_refresh_visual()
	_apply_pending_texture_if_needed()
	refresh_process_state()

# 澶勭悊 process
func _process(delta: float) -> void:
	var process_begin_us: int = _probe_begin_timing()

	if movement_component != null:
		movement_component.call("tick", delta)
		# Stop per-frame ticking once the movement target is consumed.
		if not bool(movement_component.get("has_target")):
			set_process(false)
	_probe_commit_timing(PROBE_SCOPE_UNIT_BASE_PROCESS, process_begin_us)

# 澶勭悊 refresh process state
func refresh_process_state() -> void:
	var should_process: bool = false
	if is_dragging:
		should_process = true
	elif movement_component != null:
		should_process = bool(movement_component.get("has_target"))
	set_process(should_process)

# 鍑嗗 setup from unit record
func setup_from_unit_record(unit_record: Dictionary, forced_star: int = -1) -> void:
	var setup_begin_us: int = _probe_begin_timing()
	unit_id = str(unit_record.get("id", ""))
	unit_name = str(unit_record.get("name", unit_id))
	quality = str(unit_record.get("quality", "white"))
	cost = int(unit_record.get("cost", 1))

	base_stats = (unit_record.get("base_stats", {}) as Dictionary).duplicate(true)

	initial_gongfa.clear()
	if unit_record.get("initial_gongfa", []) is Array:
		for gongfa_id in unit_record["initial_gongfa"]:
			initial_gongfa.append(str(gongfa_id))
	traits.clear()
	if unit_record.get("traits", []) is Array:
		for trait_value in unit_record["traits"]:
			if trait_value is Dictionary:
				traits.append((trait_value as Dictionary).duplicate(true))

	gongfa_slots = {
		"neigong": "",
		"waigong": "",
		"qinggong": "",
		"zhenfa": ""
	}
	if unit_record.get("gongfa_slots", {}) is Dictionary:
		var slots_raw: Dictionary = unit_record["gongfa_slots"]
		for slot in gongfa_slots.keys():
			gongfa_slots[slot] = str(slots_raw.get(slot, ""))

	# 瑁呭妲戒綅鎸夋暟鎹姩鎬佽鍙栵紱鏈厤缃椂榛樿涓ゆЫ銆?
	var configured_max_equip: int = int(unit_record.get("max_equip_count", 0))
	equip_slots = _normalize_equip_slots_dict(unit_record.get("equip_slots", {}), configured_max_equip)
	max_equip_count = _resolve_max_equip_count(configured_max_equip, equip_slots)
	# 涓嶈兘鍦ㄢ€滄湭杩涘叆鍦烘櫙鏍戔€濈殑鑺傜偣涓婄洿鎺?get_node("/root/...")锛?
	# 杩欓噷鏀逛负閫氳繃 SceneTree 鏍硅妭鐐瑰畨鍏ㄦ煡璇?AutoLoad锛岄伩鍏嶅垵濮嬪寲鏈熸姤閿欍€?
	var gm: Node = _get_unit_augment_manager()
	if gm != null and not initial_gongfa.is_empty():
		var reg = gm.get("_registry")
		if reg != null:
			for item_id in initial_gongfa:
				if reg.has_equipment(item_id):
					for slot in _get_sorted_equip_slot_keys(equip_slots):
						if str(equip_slots.get(slot, "")).strip_edges() != "":
							continue
						equip_slots[slot] = item_id
						break
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
	tags = _normalize_tag_array(unit_record.get("tags", []))
	traits = _normalize_traits_tags(traits)

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
	runtime_equipped_gongfa_ids = get_equipped_gongfa_ids()
	runtime_equipped_equip_ids = get_equipped_equip_ids()
	refresh_process_state()
	_probe_commit_timing(PROBE_SCOPE_UNIT_SETUP_FROM_RECORD, setup_begin_us)

# 鑾峰彇 get unit augment manager
func _get_unit_augment_manager() -> Node:
	if _services == null:
		return null
	return _services.unit_augment_manager



func get_runtime_probe():
	return _services.runtime_probe if _services != null else null







# 澶勭悊 base star set
func base_star_set(unit_record: Dictionary, forced_star: int) -> void:
	var base_star: int = clampi(int(unit_record.get("base_star", 1)), 1, 3)
	max_star = clampi(int(unit_record.get("max_star", 3)), 1, 3)
	if forced_star > 0:
		star_level = clampi(forced_star, 1, max_star)
	else:
		star_level = clampi(base_star, 1, max_star)

# 璁剧疆 set display texture
func set_display_texture(texture: Texture2D) -> void:
	_pending_texture = texture
	_apply_pending_texture_if_needed()

# 璁剧疆 set star level
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
		sprite_animator.call("play_state", 3, {}) # SKILL 鍔ㄧ敾鐢ㄤ簬鍗囨槦鐗规晥鍙嶉
	star_changed.emit(self, previous, star_level)

# 璁剧疆 set on bench state
func set_on_bench_state(value: bool, slot_index: int = -1) -> void:
	is_on_bench = value
	bench_slot_index = slot_index if value else -1
	refresh_process_state()

	if sprite_animator == null:
		return
	if is_on_bench:
		set_loop_animation_enabled(false)
		sprite_animator.call("play_state", 7, {}) # BENCH
	else:
		set_loop_animation_enabled(true)
		# 绂诲紑澶囨垬甯椂绔嬪嵆褰掗浂鏃嬭浆锛岄槻姝㈢户鎵?BENCH 鎽囨憜瑙掑害銆?
		if visual_root != null:
			visual_root.position = Vector2.ZERO
			visual_root.scale = Vector2.ONE
			visual_root.rotation = 0.0
		sprite_animator.call("play_state", 0, {}) # IDLE

# 璁剧疆 set team
func set_team(value: int) -> void:
	team_id = value
	_refresh_visual()

# 澶勭悊 enter combat
func enter_combat() -> void:
	# 涓婁竴灞€姝讳骸鍚庡彲鑳借闅愯棌锛岃繖閲屽叆鎴樺墠寮哄埗鎭㈠鍙銆?
	visible = true
	is_in_combat = true
	is_on_bench = false
	bench_slot_index = -1
	_apply_label_visibility()
	# 瀵硅薄姹犲鐢ㄩ槻寰★細姣忔鍏ユ垬鍏堟竻绌?visual_root 娈嬬暀锛屽啀閲嶅缓鍔ㄧ敾鍩哄噯銆?
	if visual_root != null:
		visual_root.position = Vector2.ZERO
		visual_root.scale = Vector2.ONE
		visual_root.rotation = 0.0
	if sprite_animator != null and sprite_animator.has_method("force_reset_rest_transform"):
		sprite_animator.call("force_reset_rest_transform")
	play_anim_state(0, {})
	refresh_process_state()

# 澶勭悊 leave combat
func leave_combat() -> void:
	is_in_combat = false
	_apply_label_visibility()
	refresh_process_state()

# 澶勭悊 kill quick step tween
func kill_quick_step_tween() -> void:
	if _quick_step_tween != null and _quick_step_tween.is_valid():
		_quick_step_tween.kill()
	_quick_step_tween = null

# 娓呯悊 reset visual transform
func reset_visual_transform() -> void:
	kill_quick_step_tween()
	# 鎴樺悗缁熶竴閲嶇疆瑙嗚鑺傜偣锛屾竻闄ゅ惊鐜姩鐢绘畫鐣欐棆杞?缂╂斁銆?
	if visual_root != null:
		visual_root.position = Vector2.ZERO
		visual_root.scale = Vector2.ONE
		visual_root.rotation = 0.0
		if visual_root is CanvasItem:
			(visual_root as CanvasItem).modulate = Color(1, 1, 1, 1)
	if sprite_animator != null and sprite_animator.has_method("force_reset_rest_transform"):
		sprite_animator.call("force_reset_rest_transform")
		return
	_sync_sprite_animator_rest_anchor()

# 澶勭悊 play anim state
func play_anim_state(state: int, context: Dictionary = {}) -> void:
	if sprite_animator == null:
		return
	sprite_animator.call("play_state", state, context)



func set_loop_animation_enabled(enabled: bool) -> void:
	if sprite_animator == null or not sprite_animator.has_method("set_loop_animation_enabled"):
		return
	var animator_api: Variant = sprite_animator
	animator_api.set_loop_animation_enabled(enabled)

# 澶勭悊 contains point
func contains_point(world_position: Vector2) -> bool:
	# ???????????
	# - ??????????????????????
	# - ??????????????16 ??????????????
	if visual_root != null and visual_root.has_method("get_sprite_texture_size"):
		var tex_size: Vector2 = visual_root.call("get_sprite_texture_size")
		if tex_size != Vector2.ZERO:
			var scale_abs: Vector2 = visual_root.global_scale.abs()
			var scaled_size: Vector2 = Vector2(tex_size.x * scale_abs.x, tex_size.y * scale_abs.y)
			var rect: Rect2 = Rect2(visual_root.global_position - scaled_size * 0.5, scaled_size)
			return rect.has_point(world_position)
	return global_position.distance_to(world_position) <= 16.0

# 璁剧疆 set compact visual mode
func set_compact_visual_mode(is_compact: bool) -> void:
	# 鎴樻枟涓己鍒舵樉绀哄悕绉?鏄熺骇锛岄潪鎴樻枟鏃舵寜 compact 瑙勫垯鏄剧ず銆?
	_compact_visual_mode = is_compact
	_apply_label_visibility()

# 澶勭悊 play quick cell step
func play_quick_cell_step(target_world: Vector2, duration: float = 0.08) -> void:
	
	if movement_component != null:
		movement_component.call("clear_target")

	var unit_node: Node2D = self

	if unit_node.position.distance_to(target_world) <= 0.5:
		unit_node.position = target_world
		_finish_sprite_animator_move_visual()
		return

	var step_duration: float = clampf(duration, 0.03, 0.14)
	kill_quick_step_tween()
	_quick_step_tween = create_tween()
	_quick_step_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_quick_step_tween.tween_property(unit_node, "position", target_world, step_duration)
	_quick_step_tween.finished.connect(func() -> void:
		_quick_step_tween = null
		unit_node.position = target_world
		_finish_sprite_animator_move_visual()
	)


func _finish_sprite_animator_move_visual() -> void:
	if sprite_animator != null and sprite_animator.has_method("finish_move_visual"):
		sprite_animator.call("finish_move_visual")
		return
	if visual_root != null:
		visual_root.position = Vector2.ZERO
		visual_root.scale = Vector2.ONE
		visual_root.rotation = 0.0
		if visual_root is CanvasItem:
			(visual_root as CanvasItem).modulate = Color(1, 1, 1, 1)
	play_anim_state(0, {})

# 搴旂敤 sync sprite animator rest anchor
func _sync_sprite_animator_rest_anchor() -> void:
	if sprite_animator == null:
		return
	sprite_animator.call("sync_rest_transform_to_current")

# 澶勭悊 begin drag
func begin_drag() -> void:
	if is_in_combat:
		return
	is_dragging = true
	refresh_process_state()
	z_index = 200
	# 浠庡鎴樺腑鎷栨嫿鏃讹紝鍏堟竻绌烘憞鎽嗘畫鐣欒搴︼紝纭繚鎷栨嫿濮挎€佺姝ｃ€?
	if visual_root != null:
		visual_root.position = Vector2.ZERO
		visual_root.scale = Vector2.ONE
		visual_root.rotation = 0.0
	play_anim_state(1, {}) # MOVE
	drag_started.emit(self)

# 璁剧疆 update drag
func update_drag(world_position: Vector2) -> void:
	if not is_dragging:
		return
	global_position = world_position
	drag_updated.emit(self, world_position)

# 澶勭悊 end drag
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

# 搴旂敤 apply runtime stats
func _apply_runtime_stats() -> void:
	# 瑙掕壊杩愯鏃跺睘鎬х敱 UnitData 缁熶竴鎸夋槦绾у€嶇巼璁＄畻锛屼究浜庡悗缁仛缁熶竴骞宠　銆?
	runtime_stats = _UNIT_DATA_SCRIPT.call("build_runtime_stats", base_stats, star_level)
	runtime_equipped_gongfa_ids = get_equipped_gongfa_ids()
	runtime_equipped_equip_ids = get_equipped_equip_ids()

	if combat_component != null:
		combat_component.call("reset_from_stats", runtime_stats)
	if movement_component != null:
		movement_component.call("reset_from_stats", runtime_stats)

# 鑾峰彇 get equipped gongfa ids
func get_equipped_gongfa_ids() -> Array[String]:
	# 妲戒綅椤哄簭鍥哄畾锛屼繚璇?UI 灞曠ず鍜岃Е鍙戜紭鍏堢骇绋冲畾鍙鏈熴€?
	# 瑙勫垯淇锛氬姛娉曟寜鈥滅被鍨嬫Ы浣嶁€濊澶囷紝涓嶅啀鎸夋€绘暟閲忎笂闄愭埅鏂€?
	var ids: Array[String] = []
	var ordered_slots: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa"]
	for slot in ordered_slots:
		var gid: String = str(gongfa_slots.get(slot, "")).strip_edges()
		if gid.is_empty():
			continue
		if ids.has(gid):
			continue
		ids.append(gid)
	return ids

# 鑾峰彇 get equipped equip ids
func get_equipped_equip_ids() -> Array[String]:
	# 瑁呭妲戒綅椤哄簭鍥哄畾锛屼繚璇佽鎯呭睍绀轰笌灞炴€ч噸绠楅『搴忕ǔ瀹氥€?
	var ids: Array[String] = []
	var ordered_slots: Array[String] = _get_sorted_equip_slot_keys(equip_slots)
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

# 瑙勮寖 resolve max equip count
func _resolve_max_equip_count(configured_value: int, slots: Dictionary) -> int:
	var derived: int = configured_value
	if derived <= 0:
		derived = slots.size()
	if derived <= 0:
		derived = 2
	return maxi(derived, 1)

# 瑙勮寖 normalize equip slots dict
func _normalize_equip_slots_dict(raw: Variant, desired_count: int = 0) -> Dictionary:
	var slots: Dictionary = {}
	if raw is Dictionary:
		var raw_dict: Dictionary = raw as Dictionary
		for key in _get_sorted_equip_slot_keys(raw_dict):
			slots[key] = str(raw_dict.get(key, "")).strip_edges()
	if slots.is_empty():
		slots["slot_1"] = ""
		slots["slot_2"] = ""
	var target_count: int = maxi(desired_count, 0)
	if target_count > slots.size():
		for idx in range(1, target_count + 1):
			if slots.size() >= target_count:
				break
			var key: String = "slot_%d" % idx
			if not slots.has(key):
				slots[key] = ""
	return slots

# 鑾峰彇 get sorted equip slot keys
func _get_sorted_equip_slot_keys(slots_value: Variant) -> Array[String]:
	var keys: Array[String] = []
	if slots_value is Dictionary:
		for raw_key in (slots_value as Dictionary).keys():
			var key: String = str(raw_key).strip_edges()
			if key.is_empty():
				continue
			keys.append(key)
	if keys.is_empty():
		return ["slot_1", "slot_2"]
	keys.sort_custom(Callable(self, "_compare_equip_slot_key"))
	return keys

# 姣旇緝 compare equip slot key
func _compare_equip_slot_key(a: String, b: String) -> bool:
	var a_index: int = _extract_slot_index(a)
	var b_index: int = _extract_slot_index(b)
	if a_index >= 0 and b_index >= 0:
		if a_index == b_index:
			return a < b
		return a_index < b_index
	if a_index >= 0:
		return true
	if b_index >= 0:
		return false
	return a < b

# 澶勭悊 extract slot index
func _extract_slot_index(slot_key: String) -> int:
	var key: String = slot_key.strip_edges().to_lower()
	if not key.begins_with("slot_"):
		return -1
	var tail: String = key.substr(5, key.length() - 5)
	if tail.is_empty() or not tail.is_valid_int():
		return -1
	return int(tail)

# 鑾峰彇 get trait tags
func get_trait_tags() -> Array[String]:
	var merged: Array[String] = []
	var seen: Dictionary = {}
	for trait_value in traits:
		if not (trait_value is Dictionary):
			continue
		var trait_data: Dictionary = trait_value as Dictionary
		var trait_tags: Array[String] = _normalize_tag_array(trait_data.get("tags", []))
		for tag in trait_tags:
			var key: String = tag.to_lower()
			if seen.has(key):
				continue
			seen[key] = true
			merged.append(tag)
	return merged

# 鍒ゆ柇 has trait tag
func has_trait_tag(tag: String) -> bool:
	var target: String = tag.strip_edges().to_lower()
	if target.is_empty():
		return false
	for trait_tag in get_trait_tags():
		if trait_tag.to_lower() == target:
			return true
	return false

# 鍒ゆ柇 has unit tag
func has_unit_tag(tag: String, include_trait_tags: bool = true) -> bool:
	var target: String = tag.strip_edges().to_lower()
	if target.is_empty():
		return false
	for unit_tag in tags:
		if unit_tag.to_lower() == target:
			return true
	if include_trait_tags:
		return has_trait_tag(target)
	return false

# 搴旂敤 apply animation overrides
func _apply_animation_overrides() -> void:
	if sprite_animator != null:
		sprite_animator.call("set_overrides", animation_overrides)

# 缁戝畾 bind components
func _bind_components() -> void:
	if combat_component != null:
		combat_component.call("bind_unit", self)
	if movement_component != null:
		movement_component.call("bind_unit", self)

# 澶勭悊 refresh visual
func _refresh_visual() -> void:
	if visual_root == null:
		return
	visual_root.set("name_text", "%s" % unit_name)
	visual_root.set("star_text", char(9733).repeat(star_level))
	visual_root.set("star_color", _get_star_color(star_level))
	visual_root.set("name_color", _get_team_name_color(team_id))
	_apply_label_visibility()
	modulate = _get_quality_tint(quality) * _get_team_tint(team_id)

func _apply_label_visibility() -> void:
	var should_show_labels: bool = is_in_combat or not _compact_visual_mode
	if visual_root != null:
		visual_root.set("labels_visible", should_show_labels)

func _apply_pending_texture_if_needed() -> void:
	if visual_root == null:
		return
	if _pending_texture == null:
		return
	visual_root.set("sprite_texture", _pending_texture)

func _normalize_tag_array(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		for tag_value in (value as Array):
			var tag_text: String = str(tag_value).strip_edges()
			if tag_text.is_empty():
				continue
			var key: String = tag_text.to_lower()
			if seen.has(key):
				continue
			seen[key] = true
			out.append(tag_text)
	return out

# 瑙勮寖 normalize traits tags
func _normalize_traits_tags(raw_traits: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for trait_data in raw_traits:
		var row: Dictionary = trait_data.duplicate(true)
		row["tags"] = _normalize_tag_array(row.get("tags", []))
		out.append(row)
	return out

# 鑾峰彇 get star color
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

# 鑾峰彇 get quality tint
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
		_:
			return Color(1, 1, 1, 1)

# 鑾峰彇 get team name color
func _get_team_name_color(team: int) -> Color:
	match team:
		2:
			# 鏁屾柟鍚嶇О鏆栫孩锛岀獊鍑烘晫鎴戣鲸璇嗐€?
			return Color(1.0, 0.45, 0.45, 1.0)
		1:
			# 鎴戞柟鍚嶇О闈掕摑锛屽拰鏁屾柟棰滆壊褰㈡垚鏄庢樉瀵规瘮銆?
			return Color(0.58, 0.9, 1.0, 1.0)
		_:
			return Color(0.9, 0.9, 0.9, 1.0)

# 鑾峰彇 get team tint
func _get_team_tint(team: int) -> Color:
	match team:
		2:
			return Color(1.08, 0.9, 0.9, 1.0)
		_:
			return Color(1, 1, 1, 1)



func _probe_begin_timing() -> int:
	var runtime_probe = _services.runtime_probe if _services != null else null
	if runtime_probe == null or not runtime_probe.has_method("begin_timing"):
		return 0
	return int(runtime_probe.begin_timing())



func _probe_commit_timing(scope_name: String, begin_us: int) -> void:
	var runtime_probe = _services.runtime_probe if _services != null else null
	if runtime_probe == null or not runtime_probe.has_method("commit_timing"):
		return
	runtime_probe.commit_timing(scope_name, begin_us)


