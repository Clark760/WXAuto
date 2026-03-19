extends Node

# ===========================
# 通用对象池（AutoLoad）
# ===========================
# 目标：
# 1. 高频创建/销毁对象（单位、特效、飘字）统一复用，降低 GC 与分配开销。
# 2. 提供统一 API：注册池、预热、获取、回收。
# 3. 通过 EventBus 暴露池事件，便于调试监控。

# 池结构：
# {
#   "pool_key": {
#     "factory": Callable,           # 创建实例的工厂函数
#     "available": Array[Node],      # 空闲实例
#     "in_use": Dictionary,          # instance_id -> Node
#     "default_parent": Node         # 默认挂载父节点（可选）
#   }
# }
var _pools: Dictionary = {}


func register_factory(
	pool_key: String,
	factory: Callable,
	prewarm_count: int = 0,
	default_parent: Node = null,
	allow_update_existing: bool = false
) -> bool:
	# 工厂函数必须可调用，否则无法构建对象池。
	if not factory.is_valid():
		push_error("ObjectPool: 注册失败，factory 无效，pool_key=%s" % pool_key)
		return false

	# 默认拒绝同名池重复注册；允许更新模式用于“场景反复进入时重绑定工厂”。
	if _pools.has(pool_key):
		if not allow_update_existing:
			push_warning("ObjectPool: pool_key 已存在，忽略重复注册：%s" % pool_key)
			return false

		var existed_pool: Dictionary = _pools[pool_key]
		existed_pool["factory"] = factory
		existed_pool["default_parent"] = default_parent
		existed_pool["available"] = _filter_valid_nodes(existed_pool.get("available", []))
		existed_pool["in_use"] = _filter_valid_in_use(existed_pool.get("in_use", {}))
		_pools[pool_key] = existed_pool

		var event_bus_update: Node = _get_event_bus()
		if event_bus_update != null:
			event_bus_update.call("emit_object_pool_registered", pool_key)
		return true

	_pools[pool_key] = {
		"factory": factory,
		"available": [],
		"in_use": {},
		"default_parent": default_parent
	}

	if prewarm_count > 0:
		_prewarm_pool(pool_key, prewarm_count)

	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_object_pool_registered", pool_key)
	return true


func has_pool(pool_key: String) -> bool:
	return _pools.has(pool_key)


func acquire(pool_key: String, parent_override: Node = null) -> Node:
	if not _pools.has(pool_key):
		push_error("ObjectPool: 获取失败，未注册的 pool_key=%s" % pool_key)
		return null

	var pool: Dictionary = _pools[pool_key]
	var node: Node = null
	var available: Array = pool["available"]

	# 优先复用空闲对象；为空时再按工厂创建。
	while not available.is_empty():
		var candidate: Variant = available.pop_back()
		var candidate_node: Node = _to_live_node(candidate)
		if candidate_node != null:
			node = candidate_node
			break

	if node == null:
		node = _create_instance(pool_key, parent_override)
	else:
		_attach_parent_if_needed(node, pool, parent_override)

	if node == null:
		return null

	_set_node_active(node, true)

	var in_use: Dictionary = pool["in_use"]
	in_use[node.get_instance_id()] = node
	pool["in_use"] = in_use
	pool["available"] = available
	_pools[pool_key] = pool

	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_object_pool_acquired", pool_key, node.get_instance_id())
	return node


func release(pool_key: String, node: Node) -> bool:
	if node == null:
		return false
	if not is_instance_valid(node):
		return false

	if not _pools.has(pool_key):
		push_error("ObjectPool: 回收失败，未注册的 pool_key=%s" % pool_key)
		return false

	var pool: Dictionary = _pools[pool_key]
	var in_use: Dictionary = pool["in_use"]
	var instance_id: int = node.get_instance_id()

	# 只有已借出的实例才能回收到空闲池，防止外部误传对象污染池状态。
	if not in_use.has(instance_id):
		push_warning("ObjectPool: 回收忽略，实例不在 in_use 中，pool=%s, id=%d" % [pool_key, instance_id])
		return false

	in_use.erase(instance_id)
	pool["in_use"] = in_use

	_set_node_active(node, false)
	var available: Array = pool["available"]
	available.append(node)
	pool["available"] = available
	_pools[pool_key] = pool

	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_object_pool_released", pool_key, instance_id)
	return true


func clear_pool(pool_key: String, free_nodes: bool = false) -> void:
	if not _pools.has(pool_key):
		return

	var pool: Dictionary = _pools[pool_key]
	var available: Array = pool["available"]
	var in_use: Dictionary = pool["in_use"]

	if free_nodes:
		for node_value in available:
			var available_node: Node = _to_live_node(node_value)
			if available_node != null:
				available_node.queue_free()
		for node_value in in_use.values():
			var in_use_node: Node = _to_live_node(node_value)
			if in_use_node != null:
				in_use_node.queue_free()

	pool["available"] = []
	pool["in_use"] = {}
	_pools[pool_key] = pool


func get_pool_stats(pool_key: String) -> Dictionary:
	if not _pools.has(pool_key):
		return {}
	var pool: Dictionary = _pools[pool_key]
	return {
		"pool_key": pool_key,
		"available": (pool["available"] as Array).size(),
		"in_use": (pool["in_use"] as Dictionary).size()
	}


func get_all_pool_stats() -> Array[Dictionary]:
	var stats: Array[Dictionary] = []
	for pool_key in _pools.keys():
		stats.append(get_pool_stats(str(pool_key)))
	return stats


func _prewarm_pool(pool_key: String, count: int) -> void:
	var pool: Dictionary = _pools[pool_key]
	var available: Array = pool["available"]

	# 预热会立即创建实例并放入空闲队列，避免战斗首帧创建峰值。
	for i in range(count):
		var node: Node = _create_instance(pool_key, null)
		if node != null:
			_set_node_active(node, false)
			available.append(node)

	pool["available"] = available
	_pools[pool_key] = pool


func _create_instance(pool_key: String, parent_override: Node) -> Node:
	var pool: Dictionary = _pools[pool_key]
	var factory: Callable = pool["factory"]
	var created: Variant = factory.call()

	# 注意：factory 可能来自旧场景残留 Callable，极端情况下会返回“已释放实例”。
	# 这里必须先做实例有效性过滤，再做 Node 转换，避免触发：
	# Left operand of 'is' is a previously freed instance.
	var node: Node = _to_live_node(created)
	if node == null:
		push_error("ObjectPool: factory 未返回有效 Node，pool_key=%s" % pool_key)
		return null

	_attach_parent_if_needed(node, pool, parent_override)
	return node


func _attach_parent_if_needed(node: Node, pool: Dictionary, parent_override: Node) -> void:
	if not is_instance_valid(node):
		return
	if node.get_parent() != null:
		return

	var target_parent: Node = parent_override
	if target_parent == null:
		target_parent = _to_live_node(pool.get("default_parent", null))

	# 若未指定父节点，则自动挂到当前场景，避免对象游离在树外无法处理。
	if target_parent == null:
		var tree: SceneTree = get_tree()
		if tree != null:
			target_parent = tree.current_scene

	if target_parent != null and is_instance_valid(target_parent):
		target_parent.add_child(node)


func _set_node_active(node: Node, is_active: bool) -> void:
	if node == null:
		return
	if not is_instance_valid(node):
		return

	# 统一处理可见性与逻辑开关，回收时关闭处理，借出时恢复处理。
	var canvas_item: CanvasItem = node as CanvasItem
	if canvas_item != null:
		canvas_item.visible = is_active

	node.set_process(is_active)
	node.set_physics_process(is_active)
	node.set_process_input(is_active)
	node.set_process_unhandled_input(is_active)


func _filter_valid_nodes(nodes: Variant) -> Array:
	var output: Array = []
	if nodes is Array:
		for node_value in nodes:
			var live_node: Node = _to_live_node(node_value)
			if live_node != null:
				output.append(live_node)
	return output


func _filter_valid_in_use(value: Variant) -> Dictionary:
	var output: Dictionary = {}
	if value is Dictionary:
		var in_use: Dictionary = value
		for instance_id in in_use.keys():
			var live_node: Node = _to_live_node(in_use[instance_id])
			if live_node != null:
				output[instance_id] = live_node
	return output


func _to_live_node(value: Variant) -> Node:
	# 先做实例有效性检查，再进行类型转换。
	# 这样可避免对“已释放实例”执行 `is` 判断时报：
	# Left operand of 'is' is a previously freed instance.
	if not is_instance_valid(value):
		return null

	var node: Node = value as Node
	return node


func _get_event_bus() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("EventBus")
