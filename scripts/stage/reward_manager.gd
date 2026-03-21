extends RefCounted
class_name RewardManager

# ===========================
# 关卡奖励结算器（M5）
# ===========================
# 职责：
# 1. 按关卡 rewards 配置发放固定奖励（银两/经验）；
# 2. 处理随机掉落池（功法/装备/角色）；
# 3. 返回结构化结果，供 UI 与日志展示。

var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()


func apply_stage_rewards(
	rewards_config: Dictionary,
	economy_manager: Node,
	bench_ui: Node,
	battlefield: Node,
	unit_factory: Node
) -> Dictionary:
	var result: Dictionary = {
		"silver": 0,
		"exp": 0,
		"drops": [],
		"granted_units": [],
		"discarded_units": []
	}
	if rewards_config.is_empty():
		return result

	var silver_reward: int = maxi(int(rewards_config.get("silver", 0)), 0)
	var exp_reward: int = maxi(int(rewards_config.get("exp", 0)), 0)
	if economy_manager != null and is_instance_valid(economy_manager):
		if silver_reward > 0 and economy_manager.has_method("add_silver"):
			economy_manager.call("add_silver", silver_reward)
		if exp_reward > 0 and economy_manager.has_method("add_exp"):
			economy_manager.call("add_exp", exp_reward)
	result["silver"] = silver_reward
	result["exp"] = exp_reward

	var drops_value: Variant = rewards_config.get("drops", [])
	if not (drops_value is Array):
		return result

	for drop_value in drops_value:
		if not (drop_value is Dictionary):
			continue
		var drop: Dictionary = drop_value
		var drop_type: String = str(drop.get("type", "")).strip_edges().to_lower()
		var pool_value: Variant = drop.get("pool", [])
		if not (pool_value is Array):
			continue
		var pool: Array = pool_value
		if pool.is_empty():
			continue
		var count: int = maxi(int(drop.get("count", 1)), 0)
		var chance: float = clampf(float(drop.get("chance", 1.0)), 0.0, 1.0)
		var unit_star: int = clampi(int(drop.get("star", 1)), 1, 3)
		for _i in range(count):
			if _rng.randf() > chance:
				continue
			var picked_id: String = str(pool[_rng.randi_range(0, pool.size() - 1)]).strip_edges()
			if picked_id.is_empty():
				continue
			match drop_type:
				"gongfa", "equipment":
					var granted_item: bool = _grant_item_drop(battlefield, drop_type, picked_id)
					if granted_item:
						(result["drops"] as Array).append({
							"type": drop_type,
							"id": picked_id
						})
				"unit":
					var grant_info: Dictionary = _grant_unit_drop(
						picked_id,
						unit_star,
						bench_ui,
						battlefield,
						unit_factory
					)
					if bool(grant_info.get("granted", false)):
						(result["granted_units"] as Array).append(grant_info)
					else:
						(result["discarded_units"] as Array).append(grant_info)
				_:
					continue
	return result


func _grant_item_drop(battlefield: Node, item_type: String, item_id: String) -> bool:
	if battlefield == null or not is_instance_valid(battlefield):
		return false
	if battlefield.has_method("grant_stage_reward_item"):
		return bool(battlefield.call("grant_stage_reward_item", item_type, item_id, 1))
	# 兼容旧接口：若未提供新封装，尝试直接走库存方法。
	if battlefield.has_method("_add_owned_item"):
		var category: String = "gongfa" if item_type == "gongfa" else "equipment"
		battlefield.call("_add_owned_item", category, item_id, 1)
		return true
	return false


func _grant_unit_drop(
	unit_id: String,
	star: int,
	bench_ui: Node,
	battlefield: Node,
	unit_factory: Node
) -> Dictionary:
	if battlefield != null and is_instance_valid(battlefield) and battlefield.has_method("grant_stage_reward_unit"):
		var direct_result: Variant = battlefield.call("grant_stage_reward_unit", unit_id, star)
		if direct_result is Dictionary:
			return direct_result
	if bench_ui == null or unit_factory == null or battlefield == null:
		return {
			"type": "unit",
			"id": unit_id,
			"star": star,
			"granted": false,
			"placement": "discarded"
		}
	return _fallback_grant_unit_drop(unit_id, star, bench_ui, battlefield, unit_factory)


func _fallback_grant_unit_drop(
	unit_id: String,
	star: int,
	bench_ui: Node,
	battlefield: Node,
	unit_factory: Node
) -> Dictionary:
	if not (bench_ui is Node) or not (unit_factory is Node):
		return {
			"type": "unit",
			"id": unit_id,
			"star": star,
			"granted": false,
			"placement": "discarded"
		}
	var unit_layer: Node = null
	if battlefield is Node and (battlefield as Node).has_method("get"):
		var layer_variant: Variant = (battlefield as Node).get("unit_layer")
		if layer_variant is Node:
			unit_layer = layer_variant as Node
	var unit_node: Node = unit_factory.call("acquire_unit", unit_id, star, unit_layer)
	if unit_node == null:
		return {
			"type": "unit",
			"id": unit_id,
			"star": star,
			"granted": false,
			"placement": "discarded"
		}
	unit_node.call("set_team", 1)
	unit_node.call("set_on_bench_state", true, -1)
	unit_node.set("is_in_combat", false)
	if bench_ui.has_method("add_unit") and bool(bench_ui.call("add_unit", unit_node)):
		return {
			"type": "unit",
			"id": unit_id,
			"star": star,
			"granted": true,
			"placement": "bench"
		}
	if unit_factory.has_method("release_unit"):
		unit_factory.call("release_unit", unit_node)
	return {
		"type": "unit",
		"id": unit_id,
		"star": star,
		"granted": false,
		"placement": "discarded"
	}
