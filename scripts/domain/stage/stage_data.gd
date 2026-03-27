extends RefCounted
class_name StageData

# ===========================
# 关卡配置解析器（M5）
# 1. 对 data/stages 的原始 JSON 做最小校验与默认值补齐；
# 2. 输出稳定结构供 StageManager / Battlefield 直接消费。
# 3. 本文件只做配置清洗，不访问场景树和运行时节点。
# 4. 规则重点是把坏输入裁掉，把缺省值补齐。
# 5. 这样 StageManager 拿到的永远是稳定结构。
# 6. 任何新字段都应先在这里确定默认口径。
const STAGE_TYPES: Array[String] = ["normal", "elite", "rest", "event"]
const ENEMY_DEPLOY_ZONES: Array[String] = ["front", "back", "center", "random", "fixed"]
const DROP_TYPES: Array[String] = ["gongfa", "equipment", "unit"]
const STAGE_RUNTIME_RULES_SCRIPT: Script = preload("res://scripts/domain/stage/stage_runtime_rules.gd")
# 常量集中收在文件顶部，是为了让 schema 与运行时默认值保持可比对。
# STAGE_TYPES 只声明当前允许进入运行时的类型集合。
# ENEMY_DEPLOY_ZONES 定义敌军部署语义，不承担坐标展开。
# DROP_TYPES 则约束奖励解析时允许落入结果集的掉落类别。
# 任何新增类型都应同时改 schema 与这里，避免测试和运行时口径漂移。

const DEFAULT_GRID: Dictionary = {
	"width": 32,
	"height": 16,
	"hex_size": 26.0,
	"deploy_zone": {
		"x_min": 0,
		"x_max": 15,
		"y_min": 0,
		"y_max": 15
	}
}


# 规范化单关配置，补齐默认网格、敌人、地形和奖励结构。
# 这里的输出是 StageManager 的单一事实来源。
# 无效 stage_id 会直接返回空字典，避免后续运行时误装半成品关卡。
# terrains 缺省时会自动回退到 legacy obstacles 转 terrain 的兼容路径。
func normalize_stage_record(raw: Dictionary) -> Dictionary:
	var stage_id: String = str(raw.get("id", "")).strip_edges()
	if stage_id.is_empty():
		return {}

	var stage_type: String = str(raw.get("type", "normal")).strip_edges().to_lower()
	if not STAGE_TYPES.has(stage_type):
		stage_type = "normal"

	var chapter: int = maxi(int(raw.get("chapter", 1)), 1)
	var stage_index: int = maxi(int(raw.get("index", 1)), 1)
	var grid: Dictionary = _normalize_grid(raw.get("grid", {}))
	var enemies: Array[Dictionary] = _normalize_enemies(raw.get("enemies", []))
	var obstacles: Array[Dictionary] = _normalize_obstacles(raw.get("obstacles", []))
	var terrains: Array[Dictionary] = _normalize_terrains(raw.get("terrains", []))
	if terrains.is_empty():
		terrains.append_array(_legacy_obstacles_to_terrains(obstacles))
	var rewards: Dictionary = _normalize_rewards(raw.get("rewards", {}))

	var result: Dictionary = {
		"id": stage_id,
		"chapter": chapter,
		"index": stage_index,
		"name": str(raw.get("name", stage_id)),
		"type": stage_type,
		"description": str(raw.get("description", "")),
		"grid": grid,
		"enemies": enemies,
		"terrains": terrains,
		"obstacles": obstacles,
		"rewards": rewards
	}
	return result


# 规范化章节序列定义，把章节列表统一整理成稳定结构。
# 章节序列允许缺省 id，但不会允许空章节列表穿透到运行时。
# 每章只保留非空的 stage id，避免空字符串把顺序表污染掉。
# 返回值保持固定键，便于主场景和 StageManager 共用。
func normalize_stage_sequence_record(raw: Dictionary) -> Dictionary:
	var seq_id: String = str(raw.get("id", "stage_sequence")).strip_edges()
	if seq_id.is_empty():
		seq_id = "stage_sequence"

	var chapters_out: Array[Dictionary] = []
	var chapters_value: Variant = raw.get("chapters", [])
	if chapters_value is Array:
		for chapter_value in chapters_value:
			if not (chapter_value is Dictionary):
				continue
			var chapter_data: Dictionary = chapter_value
			var chapter_no: int = maxi(int(chapter_data.get("chapter", chapters_out.size() + 1)), 1)
			var stages: Array[String] = []
			var stages_value: Variant = chapter_data.get("stages", [])
			if stages_value is Array:
				for stage_id_value in stages_value:
					var stage_id: String = str(stage_id_value).strip_edges()
					if not stage_id.is_empty():
						stages.append(stage_id)
			if stages.is_empty():
				continue
			chapters_out.append({
				"chapter": chapter_no,
				"name": str(chapter_data.get("name", "Chapter %d" % chapter_no)),
				"stages": stages,
				"rest_after": bool(chapter_data.get("rest_after", false))
			})

	return {
		"id": seq_id,
		"chapters": chapters_out
	}


# 把序列配置压平成有序关卡 id 列表，供 StageManager 直接消费。
# 这里不做额外排序，调用方拿到的就是配置顺序。
# 只要章结构合法，flatten 结果就只包含非空字符串 id。
# 这样关卡推进层不需要再关心 chapters 的嵌套层级。
func flatten_sequence_stage_ids(sequence_record: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	var chapters_value: Variant = sequence_record.get("chapters", [])
	if chapters_value is Array:
		for chapter_value in chapters_value:
			if not (chapter_value is Dictionary):
				continue
			var chapter_data: Dictionary = chapter_value
			var stages_value: Variant = chapter_data.get("stages", [])
			if not (stages_value is Array):
				continue
			for stage_id_value in stages_value:
				var stage_id: String = str(stage_id_value).strip_edges()
				if not stage_id.is_empty():
					ids.append(stage_id)
	return ids


# 清洗棋盘尺寸与部署区，保证运行时永远拿到合法范围。
# 默认网格从 DEFAULT_GRID 复制，防止多个关卡共享同一份引用。
# 部署区坐标会统一 clamp 到棋盘范围内，再修正 min/max 颠倒问题。
# 这样 world controller 与 deploy manager 不必再重复处理坏数据。
func _normalize_grid(raw_grid: Variant) -> Dictionary:
	var defaults: Dictionary = DEFAULT_GRID
	return STAGE_RUNTIME_RULES_SCRIPT.normalize_grid_config(
		raw_grid,
		int(defaults.get("width", 32)),
		int(defaults.get("height", 16)),
		float(defaults.get("hex_size", 26.0)),
		defaults.get("deploy_zone", {}) as Dictionary
	)


# 规范化敌军行，过滤无效 id、数量和非法部署区类型。
# 运行时只需要 unit_id、数量、星级和部署信息，不保留内联构建字段。
# fixed_cells 会统一复用格子解析逻辑，兼容数组、字典和 Vector2i。
# 返回数组里的每一项都可以直接交给敌军生成逻辑消费。
func _normalize_enemies(raw_enemies: Variant) -> Array[Dictionary]:
	var enemies: Array[Dictionary] = []
	if not (raw_enemies is Array):
		return enemies
	for item in raw_enemies:
		if not (item is Dictionary):
			continue
		var entry: Dictionary = item
		var unit_id: String = str(entry.get("unit_id", "")).strip_edges()
		if unit_id.is_empty():
			continue
		var count: int = maxi(int(entry.get("count", 1)), 0)
		if count <= 0:
			continue
		var deploy_zone: String = str(entry.get("deploy_zone", "random")).strip_edges().to_lower()
		if not ENEMY_DEPLOY_ZONES.has(deploy_zone):
			deploy_zone = "random"
		var fixed_cells: Array[Vector2i] = _parse_cells(entry.get("fixed_cells", []))
		enemies.append({
			"unit_id": unit_id,
			"count": count,
			"star": clampi(int(entry.get("star", 1)), 1, 3),
			"deploy_zone": deploy_zone,
			"fixed_cells": fixed_cells,
			"stat_scale": maxf(float(entry.get("stat_scale", 1.0)), 0.01)
		})
	return enemies


# 把旧 obstacles 定义整理成稳定的类型加格子列表。
# obstacles 本身仍然保留，供需要兼容旧字段的调用方读取。
# 只要 cells 为空，就视为无效障碍行并直接丢弃。
# 这样 terrain 兼容层就不会收到没有坐标的数据。
func _normalize_obstacles(raw_obstacles: Variant) -> Array[Dictionary]:
	var obstacles: Array[Dictionary] = []
	if not (raw_obstacles is Array):
		return obstacles
	for item in raw_obstacles:
		if not (item is Dictionary):
			continue
		var obstacle: Dictionary = item
		var obstacle_type: String = str(obstacle.get("type", "rock")).strip_edges().to_lower()
		var cells: Array[Vector2i] = _parse_cells(obstacle.get("cells", []))
		if cells.is_empty():
			continue
		obstacles.append({
			"type": obstacle_type,
			"cells": cells
		})
	return obstacles


# 规范化 terrains 行，并把 tags 统一去重后保留下来。
# 这层不会推断 terrain 语义，只负责把输入整理成稳定字典。
# 除 terrain_id、cells、tags 外的其他字段都会原样保留给运行时。
# 因此后续新增 terrain 扩展字段时，不需要先改 parser 结构。
func _normalize_terrains(raw_terrains: Variant) -> Array[Dictionary]:
	var terrains: Array[Dictionary] = []
	if not (raw_terrains is Array):
		return terrains
	for item in raw_terrains:
		if not (item is Dictionary):
			continue
		var terrain: Dictionary = (item as Dictionary).duplicate(true)
		var terrain_id: String = str(terrain.get("terrain_id", "")).strip_edges().to_lower()
		if terrain_id.is_empty():
			continue
		var cells: Array[Vector2i] = _parse_cells(terrain.get("cells", []))
		if cells.is_empty():
			continue
		var row: Dictionary = {
			"terrain_id": terrain_id,
			"cells": cells,
			"tags": _normalize_tags(terrain.get("tags", []))
		}
		for key in terrain.keys():
			if key == "terrain_id" or key == "cells" or key == "tags":
				continue
			row[key] = terrain[key]
		terrains.append(row)
	return terrains


# 旧障碍配置在缺少 terrains 时转成 terrain 行，维持 M5 兼容输入。
# 生成的 terrain_id 会带上 terrain_ 前缀，和运行时 registry 口径对齐。
# tags 会额外写入 obstacle 与障碍类型，方便地形标签系统继续工作。
# 这条兼容链只在 terrains 为空时生效，避免新旧配置互相覆盖。
func _legacy_obstacles_to_terrains(obstacles: Array[Dictionary]) -> Array[Dictionary]:
	var terrains: Array[Dictionary] = []
	for obstacle in obstacles:
		var obstacle_type: String = str(obstacle.get("type", "rock")).strip_edges().to_lower()
		var cells_value: Variant = obstacle.get("cells", [])
		if obstacle_type.is_empty() or not (cells_value is Array) or (cells_value as Array).is_empty():
			continue
		var terrain_id: String = "terrain_%s" % obstacle_type
		terrains.append({
			"terrain_id": terrain_id,
			"cells": (cells_value as Array).duplicate(true),
			"tags": _normalize_tags(["obstacle", obstacle_type])
		})
	return terrains


# 规范化奖励字典，保证银两、经验和掉落池字段始终存在。
# 掉落类型只允许 DROP_TYPES 中声明的三类，非法值会被静默丢弃。
# pool 会统一压成字符串数组，空池配置不会进入运行时结果。
# 返回结构稳定后，奖励发放层就不需要再写多层判空。
func _normalize_rewards(raw_rewards: Variant) -> Dictionary:
	var rewards: Dictionary = {
		"silver": 0,
		"exp": 0,
		"drops": []
	}
	if not (raw_rewards is Dictionary):
		return rewards
	var source: Dictionary = raw_rewards
	rewards["silver"] = maxi(int(source.get("silver", 0)), 0)
	rewards["exp"] = maxi(int(source.get("exp", 0)), 0)
	var drops_out: Array[Dictionary] = []
	var drops_value: Variant = source.get("drops", [])
	if drops_value is Array:
		for item in drops_value:
			if not (item is Dictionary):
				continue
			var drop: Dictionary = item
			var drop_type: String = str(drop.get("type", "")).strip_edges().to_lower()
			if not DROP_TYPES.has(drop_type):
				continue
			var pool: Array[String] = _to_string_array(drop.get("pool", []))
			if pool.is_empty():
				continue
			drops_out.append({
				"type": drop_type,
				"pool": pool,
				"count": maxi(int(drop.get("count", 1)), 0),
				"chance": clampf(float(drop.get("chance", 1.0)), 0.0, 1.0),
				"star": clampi(int(drop.get("star", 1)), 1, 3)
			})
	rewards["drops"] = drops_out
	return rewards


# 把任意数组输入压成非空字符串数组，供掉落池和其他 id 列表复用。
# 这里只做裁剪和空值过滤，不负责验证 id 是否真实存在。
# 这样上层 parser 可以统一复用这条工具链，而不用重复写 trim 分支。
# 返回结果里的顺序与原始数组保持一致，方便配置排查。
func _to_string_array(value: Variant) -> Array[String]:
	var output: Array[String] = []
	if value is Array:
		for item in value:
			var text: String = str(item).strip_edges()
			if not text.is_empty():
				output.append(text)
	return output


# 去掉空标签和大小写重复标签，保留第一次出现的原始写法。
# 这里的目标是让 UI 还能看到作者写下的首个标签文本。
# 同时，查询层只要走 to_lower 后的 key，就不会出现重复命中。
# 这和 unit trait tag 的规范化口径保持一致。
func _normalize_tags(value: Variant) -> Array[String]:
	var tags: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		for item in value:
			var text: String = str(item).strip_edges()
			if text.is_empty():
				continue
			var key: String = text.to_lower()
			if seen.has(key):
				continue
			seen[key] = true
			tags.append(text)
	return tags


# 把 Vector2i、数组和字典三种格子输入统一解析成坐标数组。
# 这层只处理形态转换，不负责检查坐标是否越界。
# 越界校验应放到真正知道棋盘尺寸的运行时配置层。
# 这样 parser 就能同时服务 schema test、terrain test 和实际战场装配。
func _parse_cells(value: Variant) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if not (value is Array):
		return cells
	for item in value:
		if item is Vector2i:
			cells.append(item)
			continue
		if item is Array:
			var arr: Array = item
			if arr.size() >= 2:
				cells.append(Vector2i(int(arr[0]), int(arr[1])))
			continue
		if item is Dictionary:
			var d: Dictionary = item
			cells.append(Vector2i(int(d.get("x", 0)), int(d.get("y", 0))))
	return cells




