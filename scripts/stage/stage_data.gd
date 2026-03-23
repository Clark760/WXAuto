extends RefCounted
class_name StageData

# ===========================
# 关卡配置解析器（M5）
# 1. 对 data/stages 的原始 JSON 做最小校验与默认值补齐；
# 2. 输出稳定结构供 StageManager / Battlefield 直接消费。
const STAGE_TYPES: Array[String] = ["normal", "elite", "boss", "rest", "event"]
const ENEMY_DEPLOY_ZONES: Array[String] = ["front", "back", "center", "random", "fixed"]
const DROP_TYPES: Array[String] = ["gongfa", "equipment", "unit"]

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

func normalize_stage_record(raw: Dictionary) -> Dictionary:
	var stage_id: String = str(raw.get("id", "")).strip_edges()
	if stage_id.is_empty():
		return {}
	if raw.has("boss_gongfa_ids") or raw.has("boss_mechanics"):
		push_error("StageData: stage=%s contains removed boss fields. Define boss data in unit records only." % stage_id)
		return {}
	var raw_enemies: Variant = raw.get("enemies", [])
	if raw_enemies is Array:
		for enemy_value in (raw_enemies as Array):
			if not (enemy_value is Dictionary):
				continue
			var enemy_row: Dictionary = enemy_value as Dictionary
			if enemy_row.has("is_boss"):
				push_error("StageData: stage=%s contains removed enemies[].is_boss. Define boss data in unit records only." % stage_id)
				return {}
			if enemy_row.has("gongfa_ids") or enemy_row.has("equip_ids") or enemy_row.has("traits"):
				push_error("StageData: stage=%s contains removed enemies inline boss data (gongfa_ids/equip_ids/traits)." % stage_id)
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


func _normalize_grid(raw_grid: Variant) -> Dictionary:
	var grid: Dictionary = DEFAULT_GRID.duplicate(true)
	if raw_grid is Dictionary:
		var src: Dictionary = raw_grid
		grid["width"] = maxi(int(src.get("width", grid["width"])), 4)
		grid["height"] = maxi(int(src.get("height", grid["height"])), 4)
		grid["hex_size"] = maxf(float(src.get("hex_size", grid["hex_size"])), 8.0)

		var deploy_zone: Dictionary = (grid.get("deploy_zone", {}) as Dictionary).duplicate(true)
		if src.get("deploy_zone", null) is Dictionary:
			var dz: Dictionary = src.get("deploy_zone", {})
			deploy_zone["x_min"] = clampi(int(dz.get("x_min", deploy_zone["x_min"])), 0, int(grid["width"]) - 1)
			deploy_zone["x_max"] = clampi(int(dz.get("x_max", deploy_zone["x_max"])), 0, int(grid["width"]) - 1)
			deploy_zone["y_min"] = clampi(int(dz.get("y_min", deploy_zone["y_min"])), 0, int(grid["height"]) - 1)
			deploy_zone["y_max"] = clampi(int(dz.get("y_max", deploy_zone["y_max"])), 0, int(grid["height"]) - 1)
		if int(deploy_zone["x_min"]) > int(deploy_zone["x_max"]):
			var swap_x: int = int(deploy_zone["x_min"])
			deploy_zone["x_min"] = int(deploy_zone["x_max"])
			deploy_zone["x_max"] = swap_x
		if int(deploy_zone["y_min"]) > int(deploy_zone["y_max"]):
			var swap_y: int = int(deploy_zone["y_min"])
			deploy_zone["y_min"] = int(deploy_zone["y_max"])
			deploy_zone["y_max"] = swap_y
		grid["deploy_zone"] = deploy_zone
	return grid


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


func _to_string_array(value: Variant) -> Array[String]:
	var output: Array[String] = []
	if value is Array:
		for item in value:
			var text: String = str(item).strip_edges()
			if not text.is_empty():
				output.append(text)
	return output


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

