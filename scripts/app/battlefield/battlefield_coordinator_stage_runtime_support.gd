extends RefCounted

# 只负责把关卡配置投影到棋盘和地形运行时。
# coordinator 保留阶段编排顺序，这里只处理具体的数据落地。
# 约束：
# 1. 不推进战斗、不刷新 HUD、不写 battle log。
# 2. 这里只做配置归一化和场景节点落值。
# 3. 所有 world / result 级副作用都必须回到 coordinator 主体处理。

var _refs = null
var _state = null
var _stage_rules: Script = null


# 绑定关卡运行时投影所需的 refs、state 和纯规则脚本。
func initialize(refs, state, stage_rules: Script) -> void:
	_refs = refs
	_state = state
	_stage_rules = stage_rules


# 关卡切换时统一把 grid / terrain 配置投影到战场运行时。
func apply_stage_runtime_config(config: Dictionary) -> void:
	if _refs == null or _state == null or _stage_rules == null:
		return
	_apply_stage_grid_config(config.get("grid", {}))
	_apply_stage_terrains(config.get("terrains", []), config.get("obstacles", []))


# 棋盘尺寸和部署区配置统一按 StageRuntimeRules 归一化后再落到场景节点。
func _apply_stage_grid_config(grid_value: Variant) -> void:
	var fallback_deploy_zone: Dictionary = _stage_rules.DEFAULT_DEPLOY_ZONE
	if _state.current_deploy_zone is Dictionary and not (_state.current_deploy_zone as Dictionary).is_empty():
		fallback_deploy_zone = (_state.current_deploy_zone as Dictionary).duplicate(true)
	var normalized_grid: Dictionary = _stage_rules.normalize_grid_config(
		grid_value,
		int(_refs.hex_grid.grid_width),
		int(_refs.hex_grid.grid_height),
		float(_refs.hex_grid.hex_size),
		fallback_deploy_zone
	)
	var width: int = int(normalized_grid.get("width", int(_refs.hex_grid.grid_width)))
	var height: int = int(normalized_grid.get("height", int(_refs.hex_grid.grid_height)))
	_refs.hex_grid.grid_width = width
	_refs.hex_grid.grid_height = height
	_refs.hex_grid.hex_size = float(normalized_grid.get("hex_size", float(_refs.hex_grid.hex_size)))
	var deploy_zone_value: Variant = normalized_grid.get(
		"deploy_zone",
		_stage_rules.DEFAULT_DEPLOY_ZONE
	)
	if deploy_zone_value is Dictionary:
		_state.current_deploy_zone = (deploy_zone_value as Dictionary).duplicate(true)
	else:
		_state.current_deploy_zone = _stage_rules.DEFAULT_DEPLOY_ZONE.duplicate(true)
	if _refs.deploy_overlay != null:
		_refs.deploy_overlay.set_deploy_zone_rect(
			int(_state.current_deploy_zone.get("x_min", 0)),
			int(_state.current_deploy_zone.get("x_max", width - 1)),
			int(_state.current_deploy_zone.get("y_min", 0)),
			int(_state.current_deploy_zone.get("y_max", height - 1))
		)
	_refs.hex_grid.queue_redraw()
	if _refs.deploy_overlay != null:
		_refs.deploy_overlay.queue_redraw()


# 地形和障碍都通过这一个入口投影到 combat manager，避免 coordinator 自己展开数据清洗。
func _apply_stage_terrains(terrains_value: Variant, obstacles_value: Variant) -> void:
	if _refs.combat_manager == null or not is_instance_valid(_refs.combat_manager):
		return
	_refs.combat_manager.clear_static_terrains()
	var terrain_rows: Array[Dictionary] = _stage_rules.normalize_terrain_rows(
		terrains_value,
		obstacles_value
	)
	if terrain_rows.is_empty():
		return
	for row in terrain_rows:
		var terrain_id: String = str(row.get("terrain_id", "")).strip_edges().to_lower()
		if terrain_id.is_empty():
			continue
		var normalized_cells: Array[Vector2i] = _normalize_terrain_cells(row.get("cells", []))
		if normalized_cells.is_empty():
			continue
		var extra: Dictionary = {}
		for key in row.keys():
			if key == "terrain_id" or key == "cells":
				continue
			extra[key] = row[key]
		_refs.combat_manager.add_static_terrain(terrain_id, normalized_cells, extra)


# cells 支持多种输入形态，这里统一清洗成 combat 侧稳定使用的 Vector2i 数组。
func _normalize_terrain_cells(cells_value: Variant) -> Array[Vector2i]:
	if not (cells_value is Array):
		return []
	var normalized_cells: Array[Vector2i] = []
	for cell_value in (cells_value as Array):
		if cell_value is Vector2i:
			normalized_cells.append(cell_value as Vector2i)
		elif cell_value is Array:
			var cell_array: Array = cell_value as Array
			if cell_array.size() >= 2:
				normalized_cells.append(Vector2i(int(cell_array[0]), int(cell_array[1])))
		elif cell_value is Dictionary:
			var cell_dict: Dictionary = cell_value as Dictionary
			normalized_cells.append(
				Vector2i(int(cell_dict.get("x", -1)), int(cell_dict.get("y", -1)))
			)
	return normalized_cells
