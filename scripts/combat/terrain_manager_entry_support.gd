extends RefCounted


# 负责把外部输入配置展开成运行期 terrain entry。
# 这里聚合的是 entry 构建期逻辑，不参与 tick 与格子缓存。

# 统一把 config、definition 和 source 快照拼成标准 terrain entry。
# `context` 目前只消费 `hex_grid`，用于校验 cells 和展开 radius。
func build_terrain_entry(
	manager,
	config: Dictionary,
	source: Node,
	context: Dictionary,
	force_static: bool
) -> Dictionary:
	if config.is_empty():
		return {}

	var hex_grid: Node = context.get("hex_grid", null) # 这里只读格子信息，不持有节点引用。
	var resolved: Dictionary = manager._resolve_terrain_definition(config)
	var terrain_def_id: String = str(resolved.get("terrain_def_id", "")).strip_edges().to_lower() # 空串表示没命中 definition。
	var terrain_def: Dictionary = {}
	if resolved.get("definition", null) is Dictionary:
		terrain_def = (resolved.get("definition", {}) as Dictionary).duplicate(true) # 后续会被 config 局部覆盖。

	# 作用区域优先显式 cells，其次退回 center + radius。
	var explicit_cells: Array[Vector2i] = manager._grid_support.parse_cells(config.get("cells", []), hex_grid)
	var center_cell: Vector2i = manager._grid_support.extract_center_cell(config, source, hex_grid)
	if explicit_cells.is_empty() and center_cell.x < 0:
		return {}
	if center_cell.x < 0 and not explicit_cells.is_empty():
		center_cell = explicit_cells[0] # 显式格子存在时，用第一格兜住中心点。

	# 临时地形必须持有正 duration，静态地形不消耗 remaining。
	var is_static: bool = force_static or bool(config.get("is_static", false)) # force_static 优先级最高。
	var remaining: float = -1.0
	if not is_static:
		# 临时地形没有正 duration 时，说明配置不完整，直接拒绝创建。
		remaining = float(config.get("duration", terrain_def.get("duration", 0.0)))
		if config.has("remaining"):
			remaining = float(config.get("remaining", remaining)) # 回放路径允许显式写 remaining。
		if remaining <= 0.0:
			return {}

	# entry 里固定来源快照，后续 source 节点销毁后仍能给 tick、事件和回放归因。
	var source_payload: Dictionary = extract_source_payload(manager, config, source, is_static)
	var terrain_instance_id: String = str(config.get("terrain_id", "")).strip_edges() # 调用方可显式传固定 id。
	if terrain_instance_id.is_empty():
		# 自动生成的 id 保留短名，方便日志里快速定位 terrain definition。
		var short_name: String = manager._terrain_short_name(terrain_def_id, config)
		terrain_instance_id = "terrain_%d_%s" % [Time.get_ticks_msec(), short_name]

	var terrain_type: String = str(config.get("terrain_type", "")).strip_edges().to_lower()
	if terrain_type.is_empty():
		# terrain_type 允许外部覆写；未覆写时退回 definition 短名维持旧口径。
		terrain_type = manager._terrain_short_name(terrain_def_id, terrain_def) # 日志和事件里沿用短名。

	# effect、阻挡与可视字段在这里一次性做完标准化。
	var radius_default: int = 0 if not explicit_cells.is_empty() else 1 # 显式格子不需要额外扩圈。
	var radius: int = maxi(int(config.get("radius", terrain_def.get("radius", radius_default))), 0)
	var tick_interval: float = maxf(
		float(config.get("tick_interval", terrain_def.get("tick_interval", manager.DEFAULT_TICK_INTERVAL))),
		0.05
	)
	var target_mode: String = manager._resolve_target_mode(config, terrain_def) # 统一沿用 manager 的默认口径。
	var damage_type: String = str(
		config.get("damage_type", terrain_def.get("damage_type", manager.DEFAULT_DAMAGE_TYPE))
	).strip_edges().to_lower()
	if damage_type.is_empty():
		damage_type = manager.DEFAULT_DAMAGE_TYPE

	# 四个 phase 的 effect 数组分别解析，避免运行时共享 definition 内的原始引用。
	var effects_on_enter: Array[Dictionary] = manager._resolve_terrain_effects(config, terrain_def, "effects_on_enter")
	var effects_on_tick: Array[Dictionary] = manager._resolve_terrain_effects(config, terrain_def, "effects_on_tick")
	var effects_on_exit: Array[Dictionary] = manager._resolve_terrain_effects(config, terrain_def, "effects_on_exit")
	var effects_on_expire: Array[Dictionary] = manager._resolve_terrain_effects(config, terrain_def, "effects_on_expire")
	var is_barrier: bool = bool(config.get("is_barrier", terrain_def.get("is_barrier", false)))
	if not is_barrier and str(terrain_def.get("type", "")).strip_edges().to_lower() == "obstacle":
		is_barrier = true # obstacle 数据默认占用阻挡格。

	var color: Color = manager._grid_support.parse_color(
		config.get("color", terrain_def.get("color", "")),
		Color(0.8, 0.8, 0.8, 0.25)
	)
	var terrain_tags: Array[String] = manager._resolve_terrain_tags(config, terrain_def) # tags 在 entry 阶段就固定下来。
	return {
		"terrain_id": terrain_instance_id,
		"terrain_def_id": terrain_def_id,
		"terrain_type": terrain_type,
		"terrain_name": str(terrain_def.get("name", terrain_def_id)),
		"terrain_class": str(terrain_def.get("type", "hazard")).strip_edges().to_lower(),
		"is_static": is_static,
		"is_barrier": is_barrier,
		"cells": explicit_cells,
		"center_cell": center_cell,
		"radius": radius,
		"remaining": remaining,
		"tick_interval": tick_interval,
		"tick_accum": 0.0,
		"target_mode": target_mode,
		"damage_type": damage_type,
		"vfx_on_tick": str(config.get("vfx_on_tick", terrain_def.get("vfx_on_tick", ""))).strip_edges(),
		"effects_on_enter": effects_on_enter,
		"effects_on_tick": effects_on_tick,
		"effects_on_exit": effects_on_exit,
		"effects_on_expire": effects_on_expire,
		"occupied_iids": {},
		"source_id": int(source_payload.get("source_id", -1)),
		"source_team": int(source_payload.get("source_team", 0)),
		"source_unit_id": str(source_payload.get("source_unit_id", "")),
		"source_name": str(source_payload.get("source_name", "")),
		"tags": terrain_tags,
		"color": color
	}


# 来源快照优先读 source 节点，再读取 config 与 fallback。
# `use_static_default=true` 时，静态地形在缺来源场景下归因给环境。
func extract_source_payload(
	manager,
	config: Dictionary,
	source: Node,
	use_static_default: bool
) -> Dictionary:
	var source_id: int = -1
	var source_team: int = 0
	var source_unit_id: String = ""
	var source_name: String = ""
	if source != null and is_instance_valid(source):
		source_id = source.get_instance_id() # 节点还活着时优先信任真实来源。
		source_team = int(manager._grid_support.safe_node_prop(source, "team_id", 0))
		source_unit_id = str(manager._grid_support.safe_node_prop(source, "unit_id", ""))
		source_name = str(manager._grid_support.safe_node_prop(source, "unit_name", ""))
	# config 快照主要服务回放和序列化入口，只有节点没给出值时才补字段。
	if source_id <= 0:
		source_id = int(config.get("source_id", source_id))
	if source_unit_id.is_empty():
		source_unit_id = str(config.get("source_unit_id", source_unit_id)).strip_edges()
	if source_name.is_empty():
		source_name = str(config.get("source_name", source_name)).strip_edges()
	if source_team == 0:
		source_team = int(config.get("source_team", source_team))

	# fallback 只补空缺字段，不覆盖 source 节点的真实值。
	var source_fallback_value: Variant = config.get("source_fallback", {})
	if source_fallback_value is Dictionary:
		var fallback: Dictionary = source_fallback_value as Dictionary
		if source_id <= 0:
			source_id = int(fallback.get("source_id", source_id))
		if source_unit_id.is_empty():
			source_unit_id = str(fallback.get("source_unit_id", source_unit_id)).strip_edges()
		if source_name.is_empty():
			source_name = str(fallback.get("source_name", source_name)).strip_edges()
		if source_team == 0:
			source_team = int(fallback.get("source_team", source_team))

	if use_static_default \
	and source_id <= 0 \
	and source_unit_id.is_empty() \
	and source_name.is_empty() \
	and source_team == 0:
		# 关卡静态障碍没有来源单位时，统一归因给环境。
		source_id = int(manager.DEFAULT_STATIC_SOURCE.get("source_id", 0))
		source_unit_id = str(manager.DEFAULT_STATIC_SOURCE.get("source_unit_id", "environment"))
		source_name = str(manager.DEFAULT_STATIC_SOURCE.get("source_name", "Environment"))
		source_team = int(manager.DEFAULT_STATIC_SOURCE.get("source_team", 0))
	return {
		"source_id": source_id,
		"source_unit_id": source_unit_id,
		"source_name": source_name,
		"source_team": source_team
	}
