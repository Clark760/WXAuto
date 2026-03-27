extends RefCounted
class_name TerrainManager

const TERRAIN_GRID_SUPPORT_SCRIPT: Script = preload("res://scripts/combat/terrain_manager_grid_support.gd")
const TERRAIN_RUNTIME_SUPPORT_SCRIPT: Script = preload("res://scripts/combat/terrain_manager_runtime_support.gd")
const TERRAIN_ENTRY_SUPPORT_SCRIPT: Script = preload("res://scripts/combat/terrain_manager_entry_support.gd")

const DEFAULT_TICK_INTERVAL: float = 0.5
const DEFAULT_DAMAGE_TYPE: String = "internal"
const DEFAULT_TARGET_MODE: String = "enemies"
const DEFAULT_STATIC_SOURCE: Dictionary = {
	"source_id": 0,
	"source_unit_id": "environment",
	"source_name": "Environment",
	"source_team": 0
}

var _terrain_registry: Dictionary = {} # 标准 terrain_id -> 地形定义。
var _terrain_alias_to_id: Dictionary = {} # alias -> 标准 terrain_id。
var _terrains: Array[Dictionary] = [] # 当前场上的地形实例快照。
var _barrier_cells_static: Dictionary = {} # 静态阻挡格，来自关卡或预铺地块。
var _barrier_cells_dynamic: Dictionary = {} # 临时阻挡格，来自战斗中生成的地形。
var _visual_cells_cache: Dictionary = {} # 可视格缓存，key 是压缩后的格坐标。
var _needs_visual_refresh: bool = true # 只有脏时才重建可视缓存。

var _grid_support = TERRAIN_GRID_SUPPORT_SCRIPT.new()
var _runtime_support = TERRAIN_RUNTIME_SUPPORT_SCRIPT.new()
var _entry_support = TERRAIN_ENTRY_SUPPORT_SCRIPT.new()

# 载入地形定义表并建立别名索引，供运行期按 id/别名稳定解析。
# `records` 来自 DataManager，入口统一把 id 和 tags 规范化成小写。
func set_terrain_registry(records: Array) -> void:
	_terrain_registry.clear()
	_terrain_alias_to_id.clear()
	for record_value in records:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = (record_value as Dictionary).duplicate(true)
		var terrain_id: String = str(record.get("id", "")).strip_edges().to_lower()
		if terrain_id.is_empty():
			continue
		record["id"] = terrain_id # registry 内只保留标准 id。
		record["tags"] = _normalize_tags(record.get("tags", [])) # tag 查询统一走小写口径。
		_terrain_registry[terrain_id] = record
		_register_terrain_alias(terrain_id, terrain_id)
		if terrain_id.begins_with("terrain_") and terrain_id.length() > 8:
			_register_terrain_alias(terrain_id.substr(8), terrain_id) # 兼容短名写法。
		var aliases_value: Variant = record.get("aliases", [])
		if aliases_value is Array:
			for alias_value in (aliases_value as Array):
				_register_terrain_alias(str(alias_value).strip_edges().to_lower(), terrain_id)

# 清空全部地形，或仅保留静态地形。
# `include_static=false` 时只回收战斗中生成的临时地形。
func clear_all(include_static: bool = true) -> void:
	if include_static:
		_terrains.clear()
		_barrier_cells_static.clear()
		_barrier_cells_dynamic.clear()
	else:
		var kept: Array[Dictionary] = [] # 静态地形继续交给关卡障碍复用。
		for terrain_value in _terrains:
			if not (terrain_value is Dictionary):
				continue
			var terrain: Dictionary = terrain_value as Dictionary
			if bool(terrain.get("is_static", false)):
				kept.append(terrain.duplicate(true))
		_terrains = kept
		_barrier_cells_dynamic.clear()
	_visual_cells_cache.clear()
	_needs_visual_refresh = true

# 只移除临时地形，静态地形保留给关卡障碍使用。
# 这个入口给 CombatTerrainService 的“清场但不动关卡障碍”场景使用。
func clear_temporary_terrains() -> void:
	clear_all(false)

# 只移除静态地形，不动运行中的临时地形。
# 关卡重铺障碍时会走这里，不能误删战斗中的临时地形。
func clear_static_terrains() -> void:
	var kept: Array[Dictionary] = []
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = terrain_value as Dictionary
		if not bool(terrain.get("is_static", false)):
			kept.append(terrain.duplicate(true))
	_terrains = kept
	_barrier_cells_static.clear()
	_visual_cells_cache.clear()
	_needs_visual_refresh = true

# 添加一个临时地形实例，并同步 barrier 与 visual 脏标记。
# `context` 当前只消费 `hex_grid`，用于校验 cells 和展开 radius。
func add_terrain(config: Dictionary, source: Node, context: Dictionary = {}) -> Dictionary:
	var entry: Dictionary = _build_terrain_entry(config, source, context, false)
	if entry.is_empty():
		return {"added": false, "barrier_changed": false, "visual_changed": false}
	_terrains.append(entry)
	var rebuild: Dictionary = _grid_support.rebuild_all_barrier_cells(self, context.get("hex_grid", null))
	_needs_visual_refresh = true
	return {
		"added": true,
		"barrier_changed": bool(rebuild.get("dynamic_changed", false)),
		"static_barrier_changed": bool(rebuild.get("static_changed", false)),
		"visual_changed": true,
		"terrain": entry.duplicate(true)
	}

# 创建静态地形，通常用于关卡障碍或预铺地块。
# `extra_config` 只做字段覆盖，不改变静态地形的生命周期语义。
func add_static_terrain(
	terrain_ref: String,
	cells: Array,
	context: Dictionary = {},
	extra_config: Dictionary = {}
) -> Dictionary:
	var terrain_key: String = terrain_ref.strip_edges().to_lower()
	if terrain_key.is_empty():
		return {"added": false, "added_count": 0, "barrier_changed": false, "visual_changed": false}

	var static_cells: Array[Vector2i] = _grid_support.parse_cells(cells, context.get("hex_grid", null))
	if static_cells.is_empty():
		return {"added": false, "added_count": 0, "barrier_changed": false, "visual_changed": false}

	var config: Dictionary = extra_config.duplicate(true)
	config["terrain_ref_id"] = terrain_key
	config["terrain_id"] = "%s_static_%d" % [terrain_key, Time.get_ticks_msec()] # 静态实例也需要唯一 id。
	config["cells"] = static_cells # 静态地形必须显式给出格子列表。
	config["is_static"] = true
	config["duration"] = -1.0
	if not config.has("source_fallback"):
		config["source_fallback"] = DEFAULT_STATIC_SOURCE.duplicate(true) # 无来源时归因给环境。

	var entry: Dictionary = _build_terrain_entry(config, null, context, true)
	if entry.is_empty():
		return {"added": false, "added_count": 0, "barrier_changed": false, "visual_changed": false}

	_terrains.append(entry)
	var rebuild: Dictionary = _grid_support.rebuild_all_barrier_cells(self, context.get("hex_grid", null))
	_needs_visual_refresh = true
	return {
		"added": true,
		"added_count": 1,
		"barrier_changed": bool(rebuild.get("static_changed", false)),
		"visual_changed": true,
		"terrain": entry.duplicate(true)
	}

# 推进地形生命周期，统一处理 enter/exit/tick/expire 四个 phase。
# `context` 需要带上 `combat_manager`、`hex_grid`、`all_units` 和 `unit_augment_manager`。
func tick(delta: float, context: Dictionary) -> Dictionary:
	if _terrains.is_empty():
		return {
			"barrier_changed": false,
			"static_barrier_changed": false,
			"visual_changed": false,
			"phase_events": []
		}

	var next_terrains: Array[Dictionary] = []
	var visual_changed: bool = false
	var phase_events: Array[Dictionary] = []
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = (terrain_value as Dictionary).duplicate(true)
		var current_targets: Array[Node] = _runtime_support.collect_targets_in_terrain(self, terrain, context)
		var is_static: bool = bool(terrain.get("is_static", false))
		if not is_static:
			# 只有临时地形会消耗 remaining；静态地形只参与 phase 判定。
			var previous_remaining: float = float(terrain.get("remaining", 0.0))
			var remaining: float = previous_remaining - delta
			terrain["remaining"] = remaining
			if previous_remaining >= 0.0 and remaining <= 0.0:
				# 过期后直接触发 expire，并且不再写回 next_terrains。
				phase_events.append_array(
					_runtime_support.execute_terrain_phase_effects(self, terrain, current_targets, "expire", context)
				)
				visual_changed = true
				continue
		# enter / exit 先跑，再进入 tick，和旧行为保持同一时序。
		phase_events.append_array(
			_runtime_support.apply_terrain_enter_exit_effects(self, terrain, current_targets, context)
		)
		var tick_interval: float = maxf(float(terrain.get("tick_interval", DEFAULT_TICK_INTERVAL)), 0.05)
		var tick_accum: float = float(terrain.get("tick_accum", 0.0)) + delta
		while tick_accum >= tick_interval:
			tick_accum -= tick_interval
			phase_events.append_array(
				_runtime_support.apply_terrain_tick(self, terrain, current_targets, context)
			)
		terrain["tick_accum"] = tick_accum
		terrain["occupied_iids"] = _build_target_iid_map(current_targets) # 下一帧 enter / exit 的基准快照。
		next_terrains.append(terrain)

	_terrains = next_terrains
	var rebuild: Dictionary = _grid_support.rebuild_all_barrier_cells(self, context.get("hex_grid", null))
	_needs_visual_refresh = _needs_visual_refresh \
		or visual_changed \
		or bool(rebuild.get("static_changed", false)) \
		or bool(rebuild.get("dynamic_changed", false)) # 任何 barrier 变化都必须拉起可视刷新。
	return {
		"barrier_changed": bool(rebuild.get("dynamic_changed", false)),
		"static_barrier_changed": bool(rebuild.get("static_changed", false)),
		"visual_changed": _needs_visual_refresh,
		"phase_events": phase_events
	}

# 返回 barrier 格子列表，scope 支持 all/static/dynamic。
# `scope` 只区分静态与临时，不承接敌我过滤语义。
func get_barrier_cells(scope: String = "all") -> Array[Vector2i]:
	var mode: String = scope.strip_edges().to_lower()
	var merged: Dictionary = {}
	match mode:
		"static":
			merged = _barrier_cells_static
		"dynamic", "temporary":
			merged = _barrier_cells_dynamic
		_:
			merged = _barrier_cells_static.duplicate(true)
			for key_value in _barrier_cells_dynamic.keys():
				merged[int(key_value)] = true

	var cells: Array[Vector2i] = []
	for key_value in merged.keys():
		cells.append(_cell_from_int_key(int(key_value)))
	return cells

# 读取 visual cache；当缓存标脏时先重建再返回副本。
# 返回副本是为了避免外部直接改写内部缓存。
func get_visual_cells(hex_grid: Node) -> Dictionary:
	if _needs_visual_refresh:
		_visual_cells_cache = _grid_support.build_visual_cells(self, hex_grid)
		_needs_visual_refresh = false
	return _visual_cells_cache.duplicate(true)


# 查询某格当前叠加的 terrain tag，供 trigger 与 tooltip 复用。
# `hex_grid` 只在 radius 地形展开时使用，不参与 scope 过滤。
func get_terrain_tags_at_cell(cell: Vector2i, scope: String = "all", hex_grid: Node = null) -> Array[String]:
	var merged: Array[String] = []
	if cell.x < 0 or cell.y < 0:
		return merged

	var seen: Dictionary = {} # 同一格可能命中多个地形，需要在这里去重。
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = terrain_value as Dictionary
		if not _should_include_terrain_by_scope(terrain, scope):
			continue

		var contains_cell: bool = false
		for terrain_cell in _grid_support.get_effective_cells_for_terrain(self, terrain, hex_grid):
			if terrain_cell == cell:
				contains_cell = true
				break
		if not contains_cell:
			continue

		var tags_value: Variant = terrain.get("tags", [])
		if not (tags_value is Array):
			continue
		for tag_value in (tags_value as Array):
			var normalized: String = str(tag_value).strip_edges().to_lower()
			if normalized.is_empty():
				continue
			if seen.has(normalized):
				continue
			seen[normalized] = true
			merged.append(normalized)
	return merged


# 布尔查询统一复用 tag 列表查询，避免出现第二套统计逻辑。
# 这样 tooltip 和 trigger 不会出现两套 tag 统计口径。
func cell_has_terrain_tag(cell: Vector2i, tag: String, scope: String = "all", hex_grid: Node = null) -> bool:
	var target: String = tag.strip_edges().to_lower()
	if target.is_empty():
		return false
	return get_terrain_tags_at_cell(cell, scope, hex_grid).has(target)


# 把输入配置标准化为运行期 terrain entry。
# 主文件保留这个 facade，是为了不改外部 public API。
func _build_terrain_entry(config: Dictionary, source: Node, context: Dictionary, force_static: bool) -> Dictionary:
	return _entry_support.build_terrain_entry(self, config, source, context, force_static)


# 解析 terrain_ref_id / terrain_id / terrain_type 到标准 definition。
# 候选顺序从“最明确的引用”往“可推导的类型名”回退。
func _resolve_terrain_definition(config: Dictionary) -> Dictionary:
	var candidates: Array[String] = []
	var terrain_ref: String = str(config.get("terrain_ref_id", "")).strip_edges().to_lower()
	if not terrain_ref.is_empty():
		candidates.append(terrain_ref)
	var terrain_id: String = str(config.get("terrain_id", "")).strip_edges().to_lower()
	if not terrain_id.is_empty():
		candidates.append(terrain_id)
	var terrain_type: String = str(config.get("terrain_type", "")).strip_edges().to_lower()
	if not terrain_type.is_empty():
		candidates.append(terrain_type)
		if terrain_type.begins_with("terrain_") and terrain_type.length() > 8:
			candidates.append(terrain_type.substr(8)) # 兼容配置里只写短名。

	for candidate in candidates:
		var resolved_id: String = _resolve_terrain_id_alias(candidate)
		if resolved_id.is_empty():
			continue
		return {
			"terrain_def_id": resolved_id,
			"definition": (_terrain_registry[resolved_id] as Dictionary).duplicate(true)
		}
	return {}


# 目标模式支持 all/enemies/allies/none，缺省值按地形类型兜底。
# beneficial 默认指向 allies，obstacle 默认不命中单位。
func _resolve_target_mode(config: Dictionary, terrain_def: Dictionary) -> String:
	var target_mode: String = str(config.get("target_mode", "")).strip_edges().to_lower()
	if target_mode.is_empty():
		target_mode = str(terrain_def.get("target_mode", "")).strip_edges().to_lower()
	if target_mode.is_empty():
		var terrain_class: String = str(terrain_def.get("type", "hazard")).strip_edges().to_lower()
		match terrain_class:
			"beneficial":
				target_mode = "allies"
			"obstacle":
				target_mode = "none"
			_:
				target_mode = DEFAULT_TARGET_MODE
	if target_mode != "all" and target_mode != "allies" and target_mode != "none":
		target_mode = DEFAULT_TARGET_MODE
	return target_mode


# effect 列表优先取 config 覆盖，其次取 definition 默认值。
# 运行期覆盖必须落在这里，避免不同 phase 各自拼装。
func _resolve_terrain_effects(config: Dictionary, terrain_def: Dictionary, key: String) -> Array[Dictionary]:
	if config.has(key):
		return _normalize_effect_rows(config.get(key, []))
	return _normalize_effect_rows(terrain_def.get(key, []))


# tags 也允许运行时覆盖，便于关卡或技能临时追加标签。
# 覆盖后的 tags 会继续走统一的小写去重口径。
func _resolve_terrain_tags(config: Dictionary, terrain_def: Dictionary) -> Array[String]:
	if config.has("tags"):
		return _normalize_tags(config.get("tags", []))
	return _normalize_tags(terrain_def.get("tags", []))


# phase 名称映射到对应的 effect 数组字段。
# 新 phase 如果将来扩展，先改这里再改 runtime helper。
func _get_terrain_phase_effects(terrain: Dictionary, phase: String) -> Array[Dictionary]:
	var key: String = "effects_on_tick"
	match phase:
		"enter":
			key = "effects_on_enter"
		"exit":
			key = "effects_on_exit"
		"expire":
			key = "effects_on_expire"
	var effects_value: Variant = terrain.get(key, [])
	return _normalize_effect_rows(effects_value)


# 规范化 effect 行，避免外部把非字典项塞进运行期结构。
# entry helper 和 runtime helper 都依赖这里输出的纯字典数组。
func _normalize_effect_rows(value: Variant) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	if not (value is Array):
		return output
	for effect_value in (value as Array):
		if effect_value is Dictionary:
			output.append((effect_value as Dictionary).duplicate(true))
	return output


# 目标 instance_id 快照用于 enter/exit 差集比较。
# 这里只记录 id，不缓存 Node 引用，避免持有失效节点。
func _build_target_iid_map(targets: Array[Node]) -> Dictionary:
	var out: Dictionary = {}
	for target in targets:
		if target == null or not is_instance_valid(target):
			continue
		out[target.get_instance_id()] = true
	return out


# 注册 terrain alias 到标准 terrain_id 的映射。
# alias 入口统一在这里收口，避免外部直接改索引表。
func _register_terrain_alias(alias: String, terrain_id: String) -> void:
	if alias.is_empty():
		return
	if terrain_id.is_empty():
		return
	_terrain_alias_to_id[alias] = terrain_id


# 解析别名时兼容 terrain_ 前缀与短名互转。
# 这样数据表、关卡和技能侧可以混用 `fire` 与 `terrain_fire`。
func _resolve_terrain_id_alias(alias: String) -> String:
	var key: String = alias.strip_edges().to_lower()
	if key.is_empty():
		return ""
	if _terrain_registry.has(key):
		return key
	if _terrain_alias_to_id.has(key):
		return str(_terrain_alias_to_id[key])
	if key.begins_with("terrain_") and key.length() > 8:
		var short_key: String = key.substr(8)
		if _terrain_alias_to_id.has(short_key):
			return str(_terrain_alias_to_id[short_key])
	elif _terrain_alias_to_id.has("terrain_%s" % key):
		return str(_terrain_alias_to_id["terrain_%s" % key])
	return ""


# 自动生成 terrain_id 时尽量保留简洁且可读的短名称。
# 短名同时会出现在日志和 phase event 里，避免生成难读 id。
func _terrain_short_name(terrain_def_id: String, source: Dictionary) -> String:
	if not terrain_def_id.is_empty():
		if terrain_def_id.begins_with("terrain_") and terrain_def_id.length() > 8:
			return terrain_def_id.substr(8)
		return terrain_def_id
	var terrain_type: String = str(source.get("terrain_type", "")).strip_edges().to_lower()
	if not terrain_type.is_empty():
		if terrain_type.begins_with("terrain_") and terrain_type.length() > 8:
			return terrain_type.substr(8)
		return terrain_type
	return "custom"


# scope 只区分 static 与 dynamic，不承接敌我过滤语义。
# 敌我过滤属于 target_mode 语义，不属于 tag 查询语义。
func _should_include_terrain_by_scope(terrain: Dictionary, scope: String) -> bool:
	var mode: String = scope.strip_edges().to_lower()
	if mode == "static":
		return bool(terrain.get("is_static", false))
	if mode == "dynamic" or mode == "temporary":
		return not bool(terrain.get("is_static", false))
	return true


# tag 列表统一做 trim、lower 和去重，避免查询口径分叉。
# 任何空字符串或大小写重复项都会在这里被丢弃。
func _normalize_tags(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		for tag_value in (value as Array):
			var normalized: String = str(tag_value).strip_edges().to_lower()
			if normalized.is_empty():
				continue
			if seen.has(normalized):
				continue
			seen[normalized] = true
			out.append(normalized)
	return out


# barrier key 集是否变化只看 key，不比较 value 内容。
# 只要 key 集相同，就说明阻挡覆盖范围没有变化。
func _dict_keys_changed(before: Dictionary, after: Dictionary) -> bool:
	if before.size() != after.size():
		return true
	for key in before.keys():
		if not after.has(key):
			return true
	return false


# 通过 int key 索引格子，便于 Dictionary 热路径查找。
# 所有 barrier / visual map 都沿用这一套压缩口径。
func _cell_key_int(cell: Vector2i) -> int:
	return ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF)


# 从 int key 还原出 Vector2i，用于对外返回 barrier 变化格。
# 对外接口仍然返回 Vector2i，避免把压缩细节泄漏给调用方。
func _cell_from_int_key(int_key: int) -> Vector2i:
	var x_raw: int = (int_key >> 16) & 0xFFFF
	var y_raw: int = int_key & 0xFFFF
	if x_raw > 0x7FFF:
		x_raw -= 0x10000
	if y_raw > 0x7FFF:
		y_raw -= 0x10000
	return Vector2i(x_raw, y_raw)
