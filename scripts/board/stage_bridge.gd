extends Node

# M5 关卡桥接器
# 负责根据关卡配置生成敌方波次，把关卡数据转换为 battlefield 的部署调用。


# 根据当前关卡配置批量生成敌人并部署到棋盘。
# 返回：成功进入解析流程即为 true；缺少上下文或配置为空时返回 false。
func spawn_enemies_from_stage_config(ctx: Node) -> bool:
	if ctx == null:
		return false
	var stage_config: Dictionary = ctx.get("_current_stage_config")
	if stage_config.is_empty():
		return false
	ctx.call("_clear_enemy_wave")
	var enemies_value: Variant = stage_config.get("enemies", [])
	if not (enemies_value is Array):
		return true
	var enemies: Array = enemies_value
	if enemies.is_empty():
		return true

	var occupied: Dictionary = {}
	var unit_factory: Node = ctx.get("unit_factory")
	var unit_layer: Node = ctx.get("unit_layer")
	for raw_enemy in enemies:
		if not (raw_enemy is Dictionary):
			continue
		var enemy_cfg: Dictionary = raw_enemy
		var unit_id: String = str(enemy_cfg.get("unit_id", "")).strip_edges()
		var spawn_count: int = maxi(int(enemy_cfg.get("count", 0)), 0)
		if unit_id.is_empty() or spawn_count <= 0:
			continue
		var is_boss_cfg: bool = bool(ctx.call("_is_stage_boss_enemy_cfg", enemy_cfg))
		var spawn_cells: Array[Vector2i] = ctx.call("_resolve_stage_enemy_cells", enemy_cfg, spawn_count, occupied)
		var forced_star: int = clampi(int(enemy_cfg.get("star", 1)), 1, 3)
		for cell in spawn_cells:
			var unit_node: Node = unit_factory.call("acquire_unit", unit_id, forced_star, unit_layer) if unit_factory != null else null
			if unit_node == null:
				continue
			if is_boss_cfg:
				unit_node.set_meta("stage_is_boss", true)
			ctx.call("_apply_stage_enemy_overrides", unit_node, enemy_cfg)
			ctx.call("_deploy_enemy_unit_to_cell", unit_node, cell)
	return true


# 判断关卡是否为非战斗类型（休整/事件）。
func is_non_combat_stage(config: Dictionary) -> bool:
	if config.is_empty():
		return false
	var stage_type: String = str(config.get("type", "normal")).strip_edges().to_lower()
	return stage_type == "rest" or stage_type == "event"
