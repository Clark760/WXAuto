extends RefCounted
class_name UnitAugmentTagLinkageScheduler

const DEFAULT_STAGGER_BUCKETS: int = 8

var _combat_manager: Node = null
var _watchers: Dictionary = {}
var _watchers_by_cell: Dictionary = {}
var _watchers_by_unit: Dictionary = {}
var _dirty_watchers: Dictionary = {}
var _scan_cells_cache: Dictionary = {}


# scheduler 维护的是 runtime watcher 状态。
# resolver 只负责纯规则判断，订阅和脏标记必须继续留在这个运行时模块。
func clear() -> void:
	_watchers.clear()
	_watchers_by_cell.clear()
	_watchers_by_unit.clear()
	_dirty_watchers.clear()
	_scan_cells_cache.clear()


# combat manager 变化后必须重连信号。
# 否则旧 watcher 还挂在旧 manager 上，新的单位移动和地形变化不会把它们标脏。
func bind_combat_manager(combat_manager: Node) -> void:
	if _combat_manager == combat_manager:
		return
	_disconnect_combat_signals()
	_combat_manager = combat_manager
	_connect_combat_signals()
	mark_all_dirty("combat_context_changed")


# should_evaluate 只决定“这一帧要不要评估”。
# `context` 里的 `tag_linkage_stagger_buckets` 会和 effect 本地配置一起决定节流节拍。
func should_evaluate(owner: Node, effect: Dictionary, context: Dictionary) -> Dictionary:
	if owner == null or not is_instance_valid(owner):
		return {
			"allowed": false,
			"dirty": false,
			"watcher_key": "",
			"reason": "invalid_owner"
		}

	var watcher_key: String = _build_watcher_key(owner, effect)
	var watcher: Dictionary = _ensure_watcher(watcher_key, owner, effect)
	var dirty: bool = bool(watcher.get("dirty", true)) or _dirty_watchers.has(watcher_key)
	var buckets: int = _resolve_bucket_count(effect, context)
	var physics_frame: int = int(Engine.get_physics_frames())
	var allowed: bool = dirty
	var reason: String = "dirty"
	if not allowed:
		# dirty watcher 要优先立即重算。
		# 只有状态没变时，才允许用 stagger 节流把评估摊到不同物理帧。
		if buckets <= 1:
			allowed = true
			reason = "always"
		else:
			var phase: int = posmod(owner.get_instance_id(), buckets)
			allowed = posmod(physics_frame, buckets) == phase
			reason = "stagger_hit" if allowed else "stagger_skip"

	return {
		"allowed": allowed,
		"dirty": dirty,
		"watcher_key": watcher_key,
		"reason": reason,
		"physics_frame": physics_frame,
		"buckets": buckets
	}


# 一次 resolver 评估结束后，scheduler 需要更新 watcher 订阅。
# `result.providers` 决定后续哪些单位或格子变化会让这条 watcher 再次变脏。
func on_evaluated(owner: Node, effect: Dictionary, context: Dictionary, result: Dictionary) -> void:
	if owner == null or not is_instance_valid(owner):
		return

	var watcher_key: String = _build_watcher_key(owner, effect)
	var watcher: Dictionary = _ensure_watcher(watcher_key, owner, effect)
	var range_cells: int = maxi(int(effect.get("range", 0)), 0)
	var cells: Array[Vector2i] = _resolve_result_scan_cells(result, owner, context, range_cells)
	var units_map: Dictionary = {}
	var providers_value: Variant = result.get("providers", [])
	if providers_value is Array:
		for provider_value in (providers_value as Array):
			if not (provider_value is Dictionary):
				continue
			var provider: Dictionary = provider_value as Dictionary
			var unit_id: int = int(provider.get("unit_id", -1))
			if unit_id > 0:
				units_map[unit_id] = true

	_reindex_watcher_subscriptions(watcher_key, watcher, cells, units_map)
	watcher["dirty"] = false
	watcher["range"] = range_cells
	_watchers[watcher_key] = watcher
	_dirty_watchers.erase(watcher_key)


# case_id 是 stateful tag_linkage 的状态入口。
# branch 切换时需要拿它和上一轮命中结果比较，决定要不要清旧 buff。
func get_last_case_id(owner: Node, effect: Dictionary) -> String:
	var watcher_key: String = _build_watcher_key(owner, effect)
	if not _watchers.has(watcher_key):
		return ""
	return str((_watchers[watcher_key] as Dictionary).get("last_case_id", "")).strip_edges()


# scheduler 统一持有“上一轮命中的 case”。
# 这样 effect 执行层不需要再自己维护第二套 stateful branch 状态。
func set_last_case_id(owner: Node, effect: Dictionary, case_id: String) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	var watcher_key: String = _build_watcher_key(owner, effect)
	var watcher: Dictionary = _ensure_watcher(watcher_key, owner, effect)
	watcher["last_case_id"] = case_id
	_watchers[watcher_key] = watcher


# 这组 buff id 对应 stateful branch 上一轮真正挂到 owner 身上的 Buff。
# case 切换时要精准移除它们，而不是盲删整个 buff_id 家族。
func get_stateful_buff_ids(owner: Node, effect: Dictionary) -> Array[String]:
	var watcher_key: String = _build_watcher_key(owner, effect)
	if not _watchers.has(watcher_key):
		return []
	var watcher: Dictionary = _watchers[watcher_key]
	var raw: Variant = watcher.get("stateful_buff_ids", [])
	return _normalize_string_array(raw)


# effect 执行层每次切换 case 后都会把新 buff_ids 回写给 scheduler。
# scheduler 只存归一化后的副本，避免上层把可变数组引用直接塞进来。
func set_stateful_buff_ids(owner: Node, effect: Dictionary, buff_ids: Array[String]) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	var watcher_key: String = _build_watcher_key(owner, effect)
	var watcher: Dictionary = _ensure_watcher(watcher_key, owner, effect)
	watcher["stateful_buff_ids"] = _normalize_string_array(buff_ids)
	_watchers[watcher_key] = watcher


# tags、装备、traits 变化时，不仅 owner 自己会受影响，周边 watcher 也可能受影响。
# 因此这里同时按 unit 和 cell 两条索引把相关 watcher 标脏。
func notify_unit_tags_changed(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var unit_iid: int = unit.get_instance_id()
	_mark_watchers_dirty_by_unit_id(unit_iid)
	mark_owner_dirty(unit)
	var cell: Vector2i = _resolve_unit_cell(unit, {})
	if cell.x >= 0 and cell.y >= 0:
		_mark_watchers_dirty_by_cell(cell)


# owner 自身状态变化时，和它绑定的 watcher 一定要优先重算。
# 这里不看 provider 索引，只按 owner_id 找 watcher，避免遗漏自引用 branch。
func mark_owner_dirty(owner: Node) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	var owner_iid: int = owner.get_instance_id()
	for watcher_key in _watchers.keys():
		var watcher: Dictionary = _watchers[watcher_key] as Dictionary
		if int(watcher.get("owner_id", -1)) != owner_iid:
			continue
		_mark_watcher_dirty(str(watcher_key))


# registry reload、combat context 替换这类全局事件最稳妥的处理方式就是全量标脏。
# 原因字符串目前只用于调试，不参与逻辑判定。
func mark_all_dirty(_reason: String = "") -> void:
	for watcher_key in _watchers.keys():
		_mark_watcher_dirty(str(watcher_key))


# scheduler 只依赖四类 combat 事件：移动、出生、死亡、地形变化。
# 其他信号不应继续往这里堆，避免 runtime 观察范围再次膨胀。
func _connect_combat_signals() -> void:
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		return
	_try_connect_signal("unit_cell_changed", "_on_unit_cell_changed")
	_try_connect_signal("unit_spawned", "_on_unit_spawned")
	_try_connect_signal("unit_died", "_on_unit_died")
	_try_connect_signal("terrain_changed", "_on_terrain_changed")


# combat manager 切换时必须先断旧连接。
# 不然同一个 watcher 会被旧 manager 和新 manager 双重标脏，导致节流失效。
func _disconnect_combat_signals() -> void:
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		return
	_try_disconnect_signal("unit_cell_changed", "_on_unit_cell_changed")
	_try_disconnect_signal("unit_spawned", "_on_unit_spawned")
	_try_disconnect_signal("unit_died", "_on_unit_died")
	_try_disconnect_signal("terrain_changed", "_on_terrain_changed")


# 这里保留统一的 connect 封装，只是为了少写重复样板。
# 真正的 signal 名称仍是显式字符串，不通过动态方法分发绕开可读性。
func _try_connect_signal(signal_name: String, callback_name: String) -> void:
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		return
	if not _combat_manager.has_signal(signal_name):
		return
	var callback: Callable = Callable(self, callback_name)
	if not _combat_manager.is_connected(signal_name, callback):
		_combat_manager.connect(signal_name, callback)


# disconnect 路径和 connect 保持对称。
# 只要 callback 存在，就必须在 manager 切换时精确断开旧连接。
func _try_disconnect_signal(signal_name: String, callback_name: String) -> void:
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		return
	if not _combat_manager.has_signal(signal_name):
		return
	var callback: Callable = Callable(self, callback_name)
	if _combat_manager.is_connected(signal_name, callback):
		_combat_manager.disconnect(signal_name, callback)


# 单位换格时，原格和新格上的 watcher 都可能受影响。
# 同时这个单位自己作为 provider 的 watcher 也要重新评估。
func _on_unit_cell_changed(unit: Node, from_cell: Vector2i, to_cell: Vector2i) -> void:
	if unit != null and is_instance_valid(unit):
		_mark_watchers_dirty_by_unit_id(unit.get_instance_id())
	if from_cell.x >= 0 and from_cell.y >= 0:
		_mark_watchers_dirty_by_cell(from_cell)
	if to_cell.x >= 0 and to_cell.y >= 0:
		_mark_watchers_dirty_by_cell(to_cell)


# 新单位出生后，既会改变附近 unit provider 计数，也可能改变某些地形条件分支。
# 如果 unit 无效，则直接全量标脏，避免丢失一次性初始化事件。
func _on_unit_spawned(unit: Node, _team_id: int) -> void:
	if unit == null or not is_instance_valid(unit):
		mark_all_dirty("unit_spawned")
		return
	var cell: Vector2i = _resolve_unit_cell(unit, {})
	if cell.x >= 0 and cell.y >= 0:
		_mark_watchers_dirty_by_cell(cell)
	_mark_watchers_dirty_by_unit_id(unit.get_instance_id())


# 死亡会同时影响 provider 存在性、队伍计数和地面占位。
# 所以和出生一样，既要按 unit 标脏，也要按当前格子标脏。
func _on_unit_died(unit: Node, _killer: Node, _team_id: int) -> void:
	if unit == null or not is_instance_valid(unit):
		mark_all_dirty("unit_died")
		return
	var unit_iid: int = unit.get_instance_id()
	var cell: Vector2i = _resolve_unit_cell(unit, {})
	_mark_watchers_dirty_by_unit_id(unit_iid)
	if cell.x >= 0 and cell.y >= 0:
		_mark_watchers_dirty_by_cell(cell)


# terrain 变化只影响订阅到对应格子的 watcher。
# 如果 changed_cells 为空，说明外层无法精确定位脏区，只能保守地全量标脏。
func _on_terrain_changed(changed_cells: Array, _reason: String) -> void:
	if changed_cells.is_empty():
		mark_all_dirty("terrain_changed_all")
		return
	for cell_value in changed_cells:
		if not (cell_value is Vector2i):
			continue
		_mark_watchers_dirty_by_cell(cell_value as Vector2i)


# bucket 数优先读 effect 的局部配置。
# 没有局部配置时，再回退到全局 `tag_linkage_stagger_buckets`。
func _resolve_bucket_count(effect: Dictionary, context: Dictionary) -> int:
	var local_buckets: int = int(effect.get("stagger_buckets", 0))
	if local_buckets > 0:
		return maxi(local_buckets, 1)
	var global_buckets: int = int(context.get("tag_linkage_stagger_buckets", DEFAULT_STAGGER_BUCKETS))
	return maxi(global_buckets, 1)


# watcher 的主键由 owner instance_id + effect signature 组成。
# 同一 owner 的同一 effect 配置在整个战斗期内都复用同一个 watcher 槽位。
func _ensure_watcher(watcher_key: String, owner: Node, effect: Dictionary) -> Dictionary:
	if _watchers.has(watcher_key):
		return _watchers[watcher_key] as Dictionary
	var watcher: Dictionary = {
		"watcher_key": watcher_key,
		"owner_id": owner.get_instance_id(),
		"effect_signature": _build_effect_signature(effect),
		"dirty": true,
		"last_case_id": "",
		"stateful_buff_ids": [],
		"range": maxi(int(effect.get("range", 0)), 0),
		"subscribed_cells": {},
		"subscribed_units": {},
		"last_eval_time": 0.0
	}
	_watchers[watcher_key] = watcher
	_dirty_watchers[watcher_key] = true
	return watcher


# 每次评估完都要重建订阅集合。
# 旧订阅必须先全部解绑，否则 watcher 会长期保留已经失效的 cell/unit 依赖。
func _reindex_watcher_subscriptions(
	watcher_key: String,
	watcher: Dictionary,
	cells: Array[Vector2i],
	units_map: Dictionary
) -> void:
	var old_cells: Dictionary = watcher.get("subscribed_cells", {})
	var old_units: Dictionary = watcher.get("subscribed_units", {})
	for cell_key in old_cells.keys():
		_unsubscribe_cell(str(cell_key), watcher_key)
	for unit_key in old_units.keys():
		_unsubscribe_unit(int(unit_key), watcher_key)

	var next_cells: Dictionary = {}
	for cell in cells:
		var cell_key: String = _cell_key(cell)
		next_cells[cell_key] = true
		_subscribe_cell(cell_key, watcher_key)

	var next_units: Dictionary = {}
	for unit_key in units_map.keys():
		var unit_iid: int = int(unit_key)
		next_units[unit_iid] = true
		_subscribe_unit(unit_iid, watcher_key)

	watcher["subscribed_cells"] = next_cells
	watcher["subscribed_units"] = next_units


# cell -> watcher 反向索引用来处理移动和地形脏标记。
# 这里的 slot 是轻量字典集合，避免在频繁订阅变动时反复做数组去重。
func _subscribe_cell(cell_key: String, watcher_key: String) -> void:
	var slot: Dictionary = _watchers_by_cell.get(cell_key, {})
	slot[watcher_key] = true
	_watchers_by_cell[cell_key] = slot


# watcher 不再订阅某个格子时，要及时把反向索引清掉。
# 否则后续 unrelated terrain 变化也会误触发这条 watcher。
func _unsubscribe_cell(cell_key: String, watcher_key: String) -> void:
	if not _watchers_by_cell.has(cell_key):
		return
	var slot: Dictionary = _watchers_by_cell[cell_key]
	slot.erase(watcher_key)
	if slot.is_empty():
		_watchers_by_cell.erase(cell_key)
	else:
		_watchers_by_cell[cell_key] = slot


# unit -> watcher 反向索引用来处理 provider 的出生、死亡和 tags 变化。
# 同一单位可能同时被多条 watcher 订阅，所以这里继续用集合字典。
func _subscribe_unit(unit_iid: int, watcher_key: String) -> void:
	var slot: Dictionary = _watchers_by_unit.get(unit_iid, {})
	slot[watcher_key] = true
	_watchers_by_unit[unit_iid] = slot


# unit 订阅解绑逻辑和 cell 保持一致。
# 只有当 slot 为空时才真正删除 key，避免留下空集合占位。
func _unsubscribe_unit(unit_iid: int, watcher_key: String) -> void:
	if not _watchers_by_unit.has(unit_iid):
		return
	var slot: Dictionary = _watchers_by_unit[unit_iid]
	slot.erase(watcher_key)
	if slot.is_empty():
		_watchers_by_unit.erase(unit_iid)
	else:
		_watchers_by_unit[unit_iid] = slot


# 某个格子变化时，只需要把订阅它的 watcher 标脏。
# 不做全量扫描是 scheduler 这个模块存在的主要价值之一。
func _mark_watchers_dirty_by_cell(cell: Vector2i) -> void:
	var cell_key: String = _cell_key(cell)
	if not _watchers_by_cell.has(cell_key):
		return
	var slot: Dictionary = _watchers_by_cell[cell_key]
	for watcher_key in slot.keys():
		_mark_watcher_dirty(str(watcher_key))


# provider 单位变化时，只把直接订阅它的 watcher 标脏。
# 这条索引主要服务于出生、死亡、tags 变化这类以单位为中心的事件。
func _mark_watchers_dirty_by_unit_id(unit_iid: int) -> void:
	if not _watchers_by_unit.has(unit_iid):
		return
	var slot: Dictionary = _watchers_by_unit[unit_iid]
	for watcher_key in slot.keys():
		_mark_watcher_dirty(str(watcher_key))


# watcher 的 dirty 状态要同时落到主表和 dirty 索引。
# 这样 should_evaluate 不需要每次扫描全部 watcher 也能知道这条 watcher 已脏。
func _mark_watcher_dirty(watcher_key: String) -> void:
	if not _watchers.has(watcher_key):
		return
	var watcher: Dictionary = _watchers[watcher_key]
	watcher["dirty"] = true
	_watchers[watcher_key] = watcher
	_dirty_watchers[watcher_key] = true


# scheduler 的扫描格子口径必须和 resolver collector 保持一致。
# 否则 watcher 订阅到的格子集合和 resolver 实际观察的格子集合会发生偏差。
func _collect_scan_cells(owner: Node, context: Dictionary, range_cells: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var origin: Vector2i = _resolve_unit_cell(owner, context)
	if origin.x < 0 or origin.y < 0:
		return out
	if range_cells <= 0:
		out.append(origin)
		return out

	var hex_grid: Variant = context.get("hex_grid", null)
	if hex_grid == null or not is_instance_valid(hex_grid):
		out.append(origin)
		return out
	if not hex_grid.has_method("is_inside_grid") or not hex_grid.has_method("get_neighbor_cells"):
		out.append(origin)
		return out
	if not bool(hex_grid.is_inside_grid(origin)):
		out.append(origin)
		return out

	var cache_key: String = _build_scan_cells_cache_key(hex_grid, origin, range_cells)
	if not cache_key.is_empty() and _scan_cells_cache.has(cache_key):
		var cached_value: Variant = _scan_cells_cache[cache_key]
		if cached_value is Array:
			return cached_value

	var queue: Array[Vector2i] = [origin]
	var visited: Dictionary = {_cell_key(origin): true}
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		if _hex_distance(origin, cell, hex_grid) > range_cells:
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
			var neighbor_key: String = _cell_key(neighbor)
			if visited.has(neighbor_key):
				continue
			visited[neighbor_key] = true
			queue.append(neighbor)
	if not cache_key.is_empty():
		_scan_cells_cache[cache_key] = out
	return out


func _resolve_result_scan_cells(
	result: Dictionary,
	owner: Node,
	context: Dictionary,
	range_cells: int
) -> Array[Vector2i]:
	var scan_cells_value: Variant = result.get("scan_cells", null)
	if scan_cells_value is Array:
		return scan_cells_value
	var debug_value: Variant = result.get("debug", {})
	if debug_value is Dictionary:
		var debug_scan_cells: Variant = (debug_value as Dictionary).get("scan_cells", null)
		if debug_scan_cells is Array:
			return debug_scan_cells
	return _collect_scan_cells(owner, context, range_cells)


func _build_scan_cells_cache_key(
	hex_grid: Variant,
	origin: Vector2i,
	range_cells: int
) -> String:
	if hex_grid == null or not is_instance_valid(hex_grid):
		return ""
	return "%d|%d,%d|%d" % [
		hex_grid.get_instance_id(),
		origin.x,
		origin.y,
		range_cells
	]


# 单位格子优先取 combat manager 的运行时映射。
# 只有 manager 没法给出有效格子时，才退回到 hex grid 的 world_to_axial 推算。
func _resolve_unit_cell(unit: Node, context: Dictionary) -> Vector2i:
	if unit == null or not is_instance_valid(unit):
		return Vector2i(-1, -1)

	var combat_manager: Variant = context.get("combat_manager", _combat_manager)
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_cell_of"):
		var cell_value: Variant = combat_manager.get_unit_cell_of(unit)
		if cell_value is Vector2i:
			var cell: Vector2i = cell_value as Vector2i
			if cell.x >= 0 and cell.y >= 0:
				return cell

	var hex_grid: Variant = context.get("hex_grid", null)
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
		var node2d: Node2D = unit as Node2D
		if node2d != null:
			var axial_value: Variant = hex_grid.world_to_axial(node2d.position)
			if axial_value is Vector2i:
				return axial_value as Vector2i
	return Vector2i(-1, -1)


# hex 距离优先复用 grid 自身的 helper。
# 没有 helper 时退回标准 axial distance，保持 mock grid 和真实 grid 行为一致。
func _hex_distance(a: Vector2i, b: Vector2i, hex_grid: Variant) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.get_cell_distance(a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)


# watcher 主键必须稳定。
# 同一 owner + 同一 effect 的 watcher 复用同一条记录，避免重复订阅同一批格子和单位。
func _build_watcher_key(owner: Node, effect: Dictionary) -> String:
	if owner == null or not is_instance_valid(owner):
		return ""
	return "%d|%s" % [owner.get_instance_id(), _build_effect_signature(effect)]


# effect signature 直接用配置序列化文本。
# Batch 5 不在这里引入额外 hash 规则，避免无必要地改变现有 watcher key 口径。
func _build_effect_signature(effect: Dictionary) -> String:
	return var_to_str(effect)


# 反向索引里统一用 `x,y` 文本作为 cell key。
# 这样字典键稳定、可打印，也方便测试断言和调试输出。
func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


# scheduler 存储的 buff id 状态必须先去重、去空串。
# 否则 stateful branch 多次切换后会累计重复 id，导致后续精确清理失真。
func _normalize_string_array(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if raw is Array:
		for value in (raw as Array):
			var text: String = str(value).strip_edges()
			if text.is_empty() or seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out
