extends RefCounted
class_name StageRuntimeRules

# 关卡运行时规则
# 说明：
# 1. 只承接运行时关卡类型判断和地形行归一化。
# 2. 不依赖场景树、Node 和战场协作者。
# 3. 这层规则同时服务 StageData 与 coordinator，避免两边各写一份口径。

# 非战斗阶段类型集中收在这里，后续扩展类型时不必再翻 coordinator。
const NON_COMBAT_STAGE_TYPES: Array[String] = ["rest", "event"]

# 部署区默认值集中维护，stage parser 和 runtime 都复用这份基线。
const DEFAULT_DEPLOY_ZONE: Dictionary = {
	"x_min": 0,
	"x_max": 15,
	"y_min": 0,
	"y_max": 15
}


# 某些关卡不进入战斗流程，这里统一判断其是否属于非战斗阶段。
# 这条规则只关心 stage type，不读取任何运行时对象。
# 因此它可以同时被 parser、coordinator 和测试直接复用。
static func is_non_combat_stage(config: Dictionary) -> bool:
	if config.is_empty():
		return false
	var stage_type: String = str(config.get("type", "normal")).strip_edges().to_lower()
	return NON_COMBAT_STAGE_TYPES.has(stage_type)


# 棋盘尺寸和部署区归一化统一走这一条，避免 StageData 与 coordinator 各写一份口径。
# default_* 参数来自调用方当前上下文，可覆盖 schema 默认值与运行时当前网格值。
# 返回结构固定为 width/height/hex_size/deploy_zone。
static func normalize_grid_config(
	raw_grid: Variant,
	default_width: int,
	default_height: int,
	default_hex_size: float,
	default_deploy_zone: Dictionary = DEFAULT_DEPLOY_ZONE
) -> Dictionary:
	var width: int = maxi(default_width, 4)
	var height: int = maxi(default_height, 4)
	var hex_size: float = maxf(default_hex_size, 8.0)
	var deploy_zone_value: Variant = default_deploy_zone
	if raw_grid is Dictionary:
		var source: Dictionary = raw_grid as Dictionary
		# 棋盘尺寸先裁最小值，再把部署区交给下一层统一处理。
		width = maxi(int(source.get("width", width)), 4)
		height = maxi(int(source.get("height", height)), 4)
		hex_size = maxf(float(source.get("hex_size", hex_size)), 8.0)
		deploy_zone_value = source.get("deploy_zone", default_deploy_zone)
	return {
		"width": width,
		"height": height,
		"hex_size": hex_size,
		"deploy_zone": normalize_deploy_zone(
			deploy_zone_value,
			width,
			height,
			default_deploy_zone
		)
	}


# 部署区边界修正规则集中在这里，保证 stage parser 与运行时 overlay 口径一致。
# 先读输入值，再按棋盘范围截断，最后矫正 min/max 颠倒。
# 只要 width/height 合法，这里就能稳定产出可用部署矩形。
static func normalize_deploy_zone(
	deploy_zone_value: Variant,
	width: int,
	height: int,
	fallback_zone: Dictionary = DEFAULT_DEPLOY_ZONE
) -> Dictionary:
	var safe_width: int = maxi(width, 4)
	var safe_height: int = maxi(height, 4)
	var deploy_zone: Dictionary = fallback_zone.duplicate(true)
	if deploy_zone_value is Dictionary:
		var source: Dictionary = deploy_zone_value as Dictionary
		deploy_zone["x_min"] = int(source.get("x_min", deploy_zone.get("x_min", 0)))
		deploy_zone["x_max"] = int(source.get("x_max", deploy_zone.get("x_max", safe_width - 1)))
		deploy_zone["y_min"] = int(source.get("y_min", deploy_zone.get("y_min", 0)))
		deploy_zone["y_max"] = int(source.get("y_max", deploy_zone.get("y_max", safe_height - 1)))

	# 四条边先 clamp，再处理 min/max 颠倒输入。
	deploy_zone["x_min"] = clampi(int(deploy_zone.get("x_min", 0)), 0, safe_width - 1)
	deploy_zone["x_max"] = clampi(int(deploy_zone.get("x_max", safe_width - 1)), 0, safe_width - 1)
	deploy_zone["y_min"] = clampi(int(deploy_zone.get("y_min", 0)), 0, safe_height - 1)
	deploy_zone["y_max"] = clampi(int(deploy_zone.get("y_max", safe_height - 1)), 0, safe_height - 1)
	if int(deploy_zone["x_min"]) > int(deploy_zone["x_max"]):
		var swap_x: int = int(deploy_zone["x_min"])
		deploy_zone["x_min"] = int(deploy_zone["x_max"])
		deploy_zone["x_max"] = swap_x
	if int(deploy_zone["y_min"]) > int(deploy_zone["y_max"]):
		var swap_y: int = int(deploy_zone["y_min"])
		deploy_zone["y_min"] = int(deploy_zone["y_max"])
		deploy_zone["y_max"] = swap_y
	return deploy_zone


# 把关卡地形/障碍输入规范化成 combat 侧统一的数据行。
# terrains 明确存在时直接采用，不再把旧 obstacles 混入同一批数据。
# 只有 terrains 缺省时，才把 obstacles 提升成 terrain 兼容行。
# 这样运行时读取到的 terrain_rows 永远只有一套来源语义。
static func normalize_terrain_rows(
	terrains_value: Variant,
	obstacles_value: Variant
) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if terrains_value is Array:
		for item in terrains_value:
			if not (item is Dictionary):
				continue
			var row: Dictionary = (item as Dictionary).duplicate(true)
			var terrain_id: String = str(row.get("terrain_id", "")).strip_edges().to_lower()
			if terrain_id.is_empty():
				continue
			var cells_value: Variant = row.get("cells", [])
			if not (cells_value is Array) or (cells_value as Array).is_empty():
				continue
			rows.append(row)
	if not rows.is_empty():
		return rows
	if not (obstacles_value is Array):
		return rows

	# 兼容旧 obstacles 时，只保留 terrain_id + cells 两个运行时必需字段。
	for obstacle_value in obstacles_value:
		if not (obstacle_value is Dictionary):
			continue
		var obstacle: Dictionary = obstacle_value as Dictionary
		var obstacle_type: String = str(obstacle.get("type", "rock")).strip_edges().to_lower()
		if obstacle_type.is_empty():
			continue
		var obstacle_cells: Variant = obstacle.get("cells", [])
		if not (obstacle_cells is Array) or (obstacle_cells as Array).is_empty():
			continue
		rows.append({
			"terrain_id": "terrain_%s" % obstacle_type,
			"cells": (obstacle_cells as Array).duplicate(true)
		})
	return rows
