extends RefCounted
class_name UnitAugmentTagLinkageProviderCollector

var _query_compiler
var _candidate_units_scratch: Array[Node] = []
var _scan_cells_cache: Dictionary = {}


# provider collector 依赖 query compiler 的 tag 归一化和 mask 构建能力。
# 这里不自己维护 registry 状态，避免 resolver 内出现第二份 tag registry 副本。
func _init(query_compiler) -> void:
	_query_compiler = query_compiler


# 这一步只负责把 owner 周边可见的 provider 整理成统一结构。
# query 过滤和 case 匹配留给后续 evaluator，collector 不提前裁剪 provider。
func collect(
	owner: Node,
	context: Dictionary,
	range_cells: int,
	include_self: bool,
	global_source_types: Array[String],
	required_unit_team_scope: String = "all"
) -> Dictionary:
	var scan_context: Dictionary = _build_scan_context(owner, context, range_cells)
	var providers: Array[Dictionary] = []
	providers.append_array(
		_collect_unit_providers(
			owner,
			context,
			scan_context,
			range_cells,
			include_self,
			global_source_types,
			required_unit_team_scope
		)
	)
	providers.append_array(
		_collect_terrain_providers(scan_context, context, global_source_types)
	)
	return {
		"providers": providers,
		"origin_cell": scan_context.get("origin_cell", Vector2i(-1, -1)),
		"scan_cells": scan_context.get("cells", [])
	}


# unit provider 同时覆盖 unit/trait/gongfa/equipment/buff 五种来源。
# 这些 provider 最终都统一成 tags + tag_mask + team_relation 的评估结构。
func _collect_unit_providers(
	owner: Node,
	context: Dictionary,
	scan_context: Dictionary,
	range_cells: int,
	include_self: bool,
	global_source_types: Array[String],
	required_unit_team_scope: String
) -> Array[Dictionary]:
	var providers: Array[Dictionary] = []
	if required_unit_team_scope == "none":
		return providers
	var candidates: Array[Node] = _collect_unit_candidates(owner, context, scan_context, include_self)

	for unit in candidates:
		if unit == null or not is_instance_valid(unit):
			continue
		if not _is_live_unit(unit):
			continue

		var is_self: bool = unit == owner
		if is_self and not include_self:
			continue
		# range=0 只允许 self provider 留下。
		# 这样“仅自身标签生效”的配置不会被附近单位误触发。
		if range_cells <= 0 and not is_self:
			continue
		if range_cells > 0 and not _is_unit_within_range(owner, unit, context, range_cells):
			continue

		var relation: String = _resolve_team_relation(owner, unit)
		if not _unit_team_scope_accepts(required_unit_team_scope, relation):
			continue
		var unit_iid: int = unit.get_instance_id()
		var unit_source_name: String = _resolve_provider_source_name(unit)
		var provider_cache: Dictionary = _get_tag_linkage_provider_cache(context, unit)
		if bool(provider_cache.get("available", false)):
			for cached_entry_value in provider_cache.get("entries", []):
				if not (cached_entry_value is Dictionary):
					continue
				var cached_entry: Dictionary = cached_entry_value as Dictionary
				var source_type: String = str(cached_entry.get("source_type", "")).strip_edges()
				if not global_source_types.has(source_type):
					continue
				var source_name: String = str(cached_entry.get("source_name", "")).strip_edges()
				if source_name.is_empty():
					source_name = unit_source_name
				providers.append({
					"key": str(cached_entry.get("key", "")).strip_edges(),
					"source_type": source_type,
					"tags": cached_entry.get("tags", []),
					"tag_mask": cached_entry.get("tag_mask", PackedInt64Array()),
					"source_name": source_name,
					"unit_id": unit_iid,
					"is_self": is_self,
					"is_self_cell": false,
					"team_relation": relation
				})
			if global_source_types.has("buff"):
				_append_buff_providers_for_unit(
					providers,
					context,
					unit,
					unit_iid,
					unit_source_name,
					is_self,
					relation
				)
			continue

		# 四类单位侧 provider 都统一写入 unit_id/is_self/team_relation。
		# evaluator 之后只看这些归一化字段，不再回头读 live unit 节点。
		if global_source_types.has("unit"):
			var unit_tags: Array[String] = _query_compiler.normalize_tags(_node_prop(unit, "tags", []))
			if not unit_tags.is_empty():
				providers.append({
					"key": "unit:%d" % unit_iid,
					"source_type": "unit",
					"tags": unit_tags,
					"tag_mask": _query_compiler.build_mask_from_tags(unit_tags),
					"source_name": unit_source_name,
					"unit_id": unit_iid,
					"is_self": is_self,
					"is_self_cell": false,
					"team_relation": relation
				})

		if global_source_types.has("trait"):
			for trait_entry in _extract_trait_tag_entries(unit):
				var trait_tags: Array[String] = trait_entry.get("tags", [])
				if trait_tags.is_empty():
					continue
				var trait_id: String = str(trait_entry.get("id", "trait")).strip_edges()
				var trait_idx: int = int(trait_entry.get("index", 0))
				providers.append({
					"key": "trait:%d:%s:%d" % [unit_iid, trait_id, trait_idx],
					"source_type": "trait",
					"tags": trait_tags,
					"tag_mask": _query_compiler.build_mask_from_tags(trait_tags),
					"source_name": unit_source_name,
					"unit_id": unit_iid,
					"is_self": is_self,
					"is_self_cell": false,
					"team_relation": relation
				})

		if global_source_types.has("gongfa"):
			for gongfa_id in _get_unit_runtime_gongfa_ids(context, unit):
				var gongfa_tags: Array[String] = _get_gongfa_tags(context, gongfa_id)
				if gongfa_tags.is_empty():
					continue
				providers.append({
					"key": "gongfa:%d:%s" % [unit_iid, gongfa_id],
					"source_type": "gongfa",
					"tags": gongfa_tags,
					"tag_mask": _query_compiler.build_mask_from_tags(gongfa_tags),
					"source_name": unit_source_name,
					"unit_id": unit_iid,
					"is_self": is_self,
					"is_self_cell": false,
					"team_relation": relation
				})

		if global_source_types.has("equipment"):
			for equip_id in _get_unit_runtime_equip_ids(context, unit):
				var equip_tags: Array[String] = _get_equipment_tags(context, equip_id)
				if equip_tags.is_empty():
					continue
				providers.append({
					"key": "equipment:%d:%s" % [unit_iid, equip_id],
					"source_type": "equipment",
					"tags": equip_tags,
					"tag_mask": _query_compiler.build_mask_from_tags(equip_tags),
					"source_name": unit_source_name,
					"unit_id": unit_iid,
					"is_self": is_self,
					"is_self_cell": false,
					"team_relation": relation
				})
		if global_source_types.has("buff"):
			_append_buff_providers_for_unit(
				providers,
				context,
				unit,
				unit_iid,
				unit_source_name,
				is_self,
				relation
			)
	return providers


# buff provider 读取单位当前生效 buff_id，并映射到 buff 定义上的 tags。
# 这层把 buff 也归一到统一 provider 结构，后续 evaluator 不需要感知“运行时状态”细节。
func _append_buff_providers_for_unit(
	providers: Array[Dictionary],
	context: Dictionary,
	unit: Node,
	unit_iid: int,
	unit_source_name: String,
	is_self: bool,
	relation: String
) -> void:
	for buff_id in _get_unit_active_buff_ids(context, unit):
		var buff_tags: Array[String] = _get_buff_tags(context, buff_id)
		if buff_tags.is_empty():
			continue
		providers.append({
			"key": "buff:%d:%s" % [unit_iid, buff_id],
			"source_type": "buff",
			"tags": buff_tags,
			"tag_mask": _query_compiler.build_mask_from_tags(buff_tags),
			"source_name": unit_source_name,
			"unit_id": unit_iid,
			"is_self": is_self,
			"is_self_cell": false,
			"team_relation": relation
		})


func _collect_unit_candidates(
	owner: Node,
	context: Dictionary,
	scan_context: Dictionary,
	include_self: bool
) -> Array[Node]:
	_candidate_units_scratch.clear()
	if not _append_combat_units_from_scan_cells(context, scan_context, _candidate_units_scratch):
		_candidate_units_scratch.append_array(_extract_units(context.get("all_units", [])))
	if include_self and owner != null and is_instance_valid(owner) and not _candidate_units_scratch.has(owner):
		_candidate_units_scratch.append(owner)
	return _candidate_units_scratch


func _append_combat_units_from_scan_cells(
	context: Dictionary,
	scan_context: Dictionary,
	output: Array[Node]
) -> bool:
	var combat_manager: Variant = context.get("combat_manager", null)
	if combat_manager == null or not is_instance_valid(combat_manager):
		return false
	if not combat_manager.has_method("collect_alive_units_in_cells"):
		return false

	var cells: Array[Vector2i] = scan_context.get("cells", [])
	if cells.is_empty():
		return false
	combat_manager.collect_alive_units_in_cells(cells, output)
	return true


# terrain provider 只依赖扫描出的格子和 combat manager 给出的标签。
# 这里不读旧系统级 manager 回退口径，只认当前 `unit_augment_manager` 上下文。
func _collect_terrain_providers(
	scan_context: Dictionary,
	context: Dictionary,
	global_source_types: Array[String]
) -> Array[Dictionary]:
	var providers: Array[Dictionary] = []
	if not global_source_types.has("terrain"):
		return providers

	# terrain provider 不依赖 unit manager，而是直接读 combat manager 当前格子标签。
	# 这样地形变化一旦进入 combat runtime，就能在 linkage 侧即时反映。
	var combat_manager: Variant = context.get("combat_manager", null)
	if combat_manager == null or not is_instance_valid(combat_manager):
		return providers
	if not combat_manager.has_method("get_terrain_tags_at_cell"):
		return providers

	var origin_cell: Vector2i = scan_context.get("origin_cell", Vector2i(-1, -1))
	var cells: Array[Vector2i] = scan_context.get("cells", [])
	for cell in cells:
		# self_cell 只给“owner 脚下地形”打标。
		# origin_scope=self 的地形 query 就靠这个字段命中。
		var tags_value: Variant = combat_manager.get_terrain_tags_at_cell(cell, "all")
		var terrain_tags: Array[String] = _query_compiler.normalize_tags(tags_value)
		if terrain_tags.is_empty():
			continue
		providers.append({
			"key": "terrain:%d,%d" % [cell.x, cell.y],
			"source_type": "terrain",
			"tags": terrain_tags,
			"tag_mask": _query_compiler.build_mask_from_tags(terrain_tags),
			"unit_id": -1,
			"is_self": false,
			"is_self_cell": cell == origin_cell and origin_cell.x >= 0,
			"team_relation": "neutral"
		})
	return providers


# scan context 只负责圈出本次 linkage 允许观察的格子集合。
# range=0 时仍保留 owner 所在格，保证 self/self_cell 分支可用。
func _build_scan_context(owner: Node, context: Dictionary, range_cells: int) -> Dictionary:
	var origin_cell: Vector2i = _resolve_unit_cell(owner, context)
	var cells: Array[Vector2i] = []
	if origin_cell.x < 0 or origin_cell.y < 0:
		return {"origin_cell": origin_cell, "cells": cells}
	if range_cells <= 0:
		cells.append(origin_cell)
		return {"origin_cell": origin_cell, "cells": cells}

	var hex_grid: Variant = context.get("hex_grid", null)
	# range>0 时优先从 hex grid 收集整圈格子。
	# 如果 grid helper 缺席，后面会退回 origin_cell 兜底，保证 self/self_cell 仍可评估。
	cells = _collect_cells_in_radius_cached(hex_grid, origin_cell, range_cells)
	if cells.is_empty():
		cells.append(origin_cell)
	return {"origin_cell": origin_cell, "cells": cells}


# 单位格子优先走 combat manager 的运行时映射。
# 只有 manager 不可用时，才退回 hex grid 的 world_to_axial 推算。
func _resolve_unit_cell(unit: Node, context: Dictionary) -> Vector2i:
	if unit == null or not is_instance_valid(unit):
		return Vector2i(-1, -1)

	# 格子位置优先相信 combat runtime 当前占位。
	# 只有运行时映射缺席时，才退回 world_to_axial 的近似推算。
	var combat_manager: Variant = context.get("combat_manager", null)
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_cell_of"):
		var cell_from_combat: Variant = combat_manager.get_unit_cell_of(unit)
		if cell_from_combat is Vector2i:
			var cell: Vector2i = cell_from_combat as Vector2i
			if cell.x >= 0 and cell.y >= 0:
				return cell

	var hex_grid: Variant = context.get("hex_grid", null)
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
		var node2d: Node2D = unit as Node2D
		if node2d != null:
			var cell_from_world: Variant = hex_grid.world_to_axial(node2d.position)
			if cell_from_world is Vector2i:
				return cell_from_world as Vector2i
	return Vector2i(-1, -1)


# 这里按 hex 邻居做 BFS，拿到 range 内全部格子。
# scheduler 之后会基于同样的格子集合建立 watcher 订阅，所以 collector 和 scheduler 必须保持同口径。
func _collect_cells_in_radius(hex_grid: Variant, center_cell: Vector2i, radius_cells: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if hex_grid == null or not is_instance_valid(hex_grid):
		return out
	if not hex_grid.has_method("is_inside_grid") or not hex_grid.has_method("get_neighbor_cells"):
		return out
	if not bool(hex_grid.is_inside_grid(center_cell)):
		return out

	# BFS 结果同时会被 scheduler 拿去建 watcher 订阅。
	# collector 和 scheduler 必须共享这套格子口径，不能一边扫少一边订多。
	var queue: Array[Vector2i] = [center_cell]
	var visited: Dictionary = {"%d,%d" % [center_cell.x, center_cell.y]: true}
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		if _hex_distance(center_cell, cell, hex_grid) > radius_cells:
			continue
		out.append(cell)
		var neighbors_value: Variant = hex_grid.get_neighbor_cells(cell)
		if not (neighbors_value is Array):
			continue
		for neighbor_value in (neighbors_value as Array):
			if not (neighbor_value is Vector2i):
				continue
			var neighbor: Vector2i = neighbor_value as Vector2i
			if not bool(hex_grid.is_inside_grid(neighbor)):
				continue
			var key: String = "%d,%d" % [neighbor.x, neighbor.y]
			if visited.has(key):
				continue
			visited[key] = true
			queue.append(neighbor)
	return out


func _collect_cells_in_radius_cached(
	hex_grid: Variant,
	center_cell: Vector2i,
	radius_cells: int
) -> Array[Vector2i]:
	var cache_key: String = _build_scan_cells_cache_key(hex_grid, center_cell, radius_cells)
	if not cache_key.is_empty() and _scan_cells_cache.has(cache_key):
		var cached_value: Variant = _scan_cells_cache[cache_key]
		if cached_value is Array:
			return cached_value

	var cells: Array[Vector2i] = _collect_cells_in_radius(hex_grid, center_cell, radius_cells)
	if not cache_key.is_empty():
		_scan_cells_cache[cache_key] = cells
	return cells


func _build_scan_cells_cache_key(
	hex_grid: Variant,
	center_cell: Vector2i,
	radius_cells: int
) -> String:
	if hex_grid == null or not is_instance_valid(hex_grid):
		return ""
	return "%d|%d,%d|%d" % [
		hex_grid.get_instance_id(),
		center_cell.x,
		center_cell.y,
		radius_cells
	]


# range 命中优先按格子距离判断。
# 只有当 grid 信息缺失时，才退回到 world position 的近似距离。
func _is_unit_within_range(owner: Node, unit: Node, context: Dictionary, range_cells: int) -> bool:
	if owner == unit:
		return true
	if range_cells <= 0:
		return false

	# 有 grid 信息时按 hex 距离判定。
	# 缺少 grid 时才退回 world 距离兜底，避免把近似算法当成主路径。
	var owner_cell: Vector2i = _resolve_unit_cell(owner, context)
	var unit_cell: Vector2i = _resolve_unit_cell(unit, context)
	if owner_cell.x >= 0 and unit_cell.x >= 0:
		var hex_grid: Variant = context.get("hex_grid", null)
		return _hex_distance(owner_cell, unit_cell, hex_grid) <= range_cells

	var owner_pos: Vector2 = _node_pos(owner)
	var unit_pos: Vector2 = _node_pos(unit)
	if owner_pos == Vector2.ZERO and unit_pos == Vector2.ZERO:
		return false
	# world 距离兜底只在格子信息缺失时生效。
	# 它不是主路径，只负责让简化测试节点也能参与范围判断。
	var max_world_distance: float = _cells_to_world_distance(float(range_cells), context)
	return owner_pos.distance_squared_to(unit_pos) <= max_world_distance * max_world_distance


# query evaluator 后续会按这个 relation 应用 ally/enemy/all 过滤。
# collector 只负责把 relation 标好，不提前裁剪 provider。
func _resolve_team_relation(owner: Node, unit: Node) -> String:
	if owner == null or not is_instance_valid(owner):
		return "neutral"
	if unit == null or not is_instance_valid(unit):
		return "neutral"
	var owner_team: int = int(owner.get("team_id"))
	var unit_team: int = int(unit.get("team_id"))
	if owner_team == 0 or unit_team == 0:
		return "neutral"
	if owner_team == unit_team:
		return "ally"
	return "enemy"


func _unit_team_scope_accepts(scope: String, relation: String) -> bool:
	if scope == "all":
		return relation == "ally" or relation == "enemy"
	if scope == "enemy":
		return relation == "enemy"
	return relation == "ally"


# trait provider 读取单位 trait 列表中的 tags 字段。
# 这里继续兼容“traits 数组里每个元素都是字典”的旧外观。
func _extract_trait_tag_entries(unit: Node) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if unit == null or not is_instance_valid(unit):
		return out
	var traits_value: Variant = unit.get("traits")
	if not (traits_value is Array):
		return out

	var traits: Array = traits_value as Array
	for idx in range(traits.size()):
		# trait provider 只认每个条目里的 tags。
		# 其它展示字段不会被带进 linkage 运行时，避免 provider 结构继续膨胀。
		var trait_value: Variant = traits[idx]
		if not (trait_value is Dictionary):
			continue
		var trait_data: Dictionary = trait_value as Dictionary
		var trait_tags: Array[String] = _query_compiler.normalize_tags(trait_data.get("tags", []))
		if trait_tags.is_empty():
			continue
		var trait_id: String = str(trait_data.get("id", "trait_%d" % idx)).strip_edges()
		if trait_id.is_empty():
			trait_id = "trait_%d" % idx
		out.append({
			"id": trait_id,
			"index": idx,
			"tags": trait_tags
		})
	return out


# runtime ids 的主入口已经统一到 `unit_augment_manager`。
# manager 缺失时才退回单位元数据，避免测试 mock 被迫完整装配 manager。
func _get_unit_runtime_gongfa_ids(context: Dictionary, unit: Node) -> Array[String]:
	var manager: Variant = context.get("unit_augment_manager", null)
	if manager != null and is_instance_valid(manager) and manager.has_method("get_unit_runtime_gongfa_ids"):
		return _normalize_ids(manager.get_unit_runtime_gongfa_ids(unit))
	return _normalize_ids(unit.get("runtime_equipped_gongfa_ids"))


# 装备 runtime ids 和功法 ids 走同一条兼容口径。
# 这里不再读取旧系统级 manager 键，彻底切断旧系统名回退。
func _get_unit_runtime_equip_ids(context: Dictionary, unit: Node) -> Array[String]:
	var manager: Variant = context.get("unit_augment_manager", null)
	if manager != null and is_instance_valid(manager) and manager.has_method("get_unit_runtime_equip_ids"):
		return _normalize_ids(manager.get_unit_runtime_equip_ids(unit))
	return _normalize_ids(unit.get("runtime_equipped_equip_ids"))


# buff runtime ids 优先走 manager 暴露的统一口径。
# manager 不可用时退回单位 meta/属性，保证纯规则测试依然可注入 active buff 列表。
func _get_unit_active_buff_ids(context: Dictionary, unit: Node) -> Array[String]:
	if unit == null or not is_instance_valid(unit):
		return []
	var manager: Variant = context.get("unit_augment_manager", null)
	if manager != null and is_instance_valid(manager) and manager.has_method("get_unit_buff_ids"):
		return _normalize_ids(manager.get_unit_buff_ids(unit))
	if unit.has_meta("active_buff_ids"):
		return _normalize_ids(unit.get_meta("active_buff_ids"))
	return _normalize_ids(unit.get("runtime_active_buff_ids"))


# tag 定义应由当前 manager 暴露。
# manager 缺失时返回空数组，而不是偷偷回退到旧系统路径。
func _get_gongfa_tags(context: Dictionary, gongfa_id: String) -> Array[String]:
	var manager: Variant = context.get("unit_augment_manager", null)
	if manager == null or not is_instance_valid(manager):
		return []
	if manager.has_method("get_gongfa_tags"):
		return _query_compiler.normalize_tags(manager.get_gongfa_tags(gongfa_id))
	if manager.has_method("get_gongfa_data"):
		var data_value: Variant = manager.get_gongfa_data(gongfa_id)
		if data_value is Dictionary:
			return _query_compiler.normalize_tags((data_value as Dictionary).get("tags", []))
	return []


# equipment tags 也只认新 manager 口径。
# 这样 coverage 检查可以直接断言旧系统级 manager 键彻底消失。
func _get_equipment_tags(context: Dictionary, equip_id: String) -> Array[String]:
	var manager: Variant = context.get("unit_augment_manager", null)
	if manager == null or not is_instance_valid(manager):
		return []
	if manager.has_method("get_equipment_tags"):
		return _query_compiler.normalize_tags(manager.get_equipment_tags(equip_id))
	if manager.has_method("get_equipment_data"):
		var data_value: Variant = manager.get_equipment_data(equip_id)
		if data_value is Dictionary:
			return _query_compiler.normalize_tags((data_value as Dictionary).get("tags", []))
	return []


# buff tags 只认 manager 暴露的定义口径。
# 缺失时再回退 `get_buff_data().tags`，保证老 mock 也能跑到同一语义。
func _get_buff_tags(context: Dictionary, buff_id: String) -> Array[String]:
	var manager: Variant = context.get("unit_augment_manager", null)
	if manager == null or not is_instance_valid(manager):
		return []
	if manager.has_method("get_buff_tags"):
		return _query_compiler.normalize_tags(manager.get_buff_tags(buff_id))
	if manager.has_method("get_buff_data"):
		var data_value: Variant = manager.get_buff_data(buff_id)
		if data_value is Dictionary:
			return _query_compiler.normalize_tags((data_value as Dictionary).get("tags", []))
	return []


# `all_units` 上下文允许混入 null 或非 Node 值。
# collector 在入口就把它归一化，避免后续每层循环都做重复判定。
func _extract_units(value: Variant) -> Array[Node]:
	var out: Array[Node] = []
	if value is Array:
		# all_units 允许混入 null、字典或其它测试辅助值。
		# 这里先筛成 Node 数组，后续收集流程就能只处理一种输入形态。
		for unit_value in (value as Array):
			if unit_value is Node:
				out.append(unit_value as Node)
	return out


# runtime id 列表只保留非空唯一文本。
# 这里不关心来源是 Array[String] 还是混合数组，统一按字符串归一化。
func _normalize_ids(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		# runtime id 列表可能混入 null、数字或重复值。
		# 统一转成非空字符串后再去重，能减少后续 provider key 抖动。
		for item in (value as Array):
			var text: String = str(item).strip_edges()
			if text.is_empty() or seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out


# live unit 判定继续以 UnitCombat.is_alive 为准。
# 没有战斗组件的 mock 单位允许参与 provider 收集，避免纯规则测试被 runtime 组件绑死。
func _get_tag_linkage_provider_cache(context: Dictionary, unit: Node) -> Dictionary:
	var manager: Variant = context.get("unit_augment_manager", null)
	if manager == null or not is_instance_valid(manager):
		return {"available": false, "entries": []}
	if not manager.has_method("get_tag_linkage_provider_cache"):
		return {"available": false, "entries": []}
	var cache_value: Variant = manager.get_tag_linkage_provider_cache(unit)
	if cache_value is Dictionary:
		return cache_value as Dictionary
	return {"available": false, "entries": []}


func _resolve_provider_source_name(unit: Node) -> String:
	if unit == null or not is_instance_valid(unit):
		return ""
	var unit_name: String = str(_node_prop(unit, "unit_name", "")).strip_edges()
	if not unit_name.is_empty():
		return unit_name
	var unit_id: String = str(_node_prop(unit, "unit_id", "")).strip_edges()
	if not unit_id.is_empty():
		return unit_id
	return ""


func _is_live_unit(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return true
	return bool(combat.get("is_alive"))


# hex 距离优先走 grid 的原生实现。
# 没有 grid helper 时退回到标准 axial distance 公式，保持测试和运行时同口径。
func _hex_distance(a: Vector2i, b: Vector2i, hex_grid: Variant) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.get_cell_distance(a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)


# world 距离只用于 grid 信息缺失的兜底估算。
# `hex_size` 继续沿用原来的宽松倍率，避免近似距离行为突变。
func _cells_to_world_distance(cells: float, context: Dictionary) -> float:
	var hex_size: float = float(context.get("hex_size", 26.0))
	return maxf(cells, 0.0) * maxf(hex_size, 1.0) * 1.2


# resolver 只认 Node2D 的实际位置。
# 其他 Node 类型统一视为没有空间信息，避免把无效坐标当成可比较位置。
func _node_pos(node: Node) -> Vector2:
	if node == null or not is_instance_valid(node):
		return Vector2.ZERO
	var node2d: Node2D = node as Node2D
	if node2d == null:
		return Vector2.ZERO
	return node2d.position


# 一些测试 unit 会直接把 tags 挂在自定义属性上。
# 这里继续保留属性访问兜底，但只做无副作用读取。
func _node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if node == null or not is_instance_valid(node):
		return fallback
	var value: Variant = node.get(key)
	if value == null:
		return fallback
	return value
