extends RefCounted
class_name StageRewardRules

# 关卡奖励纯规则
# 说明：
# 1. 只解析奖励配置并生成抽样后的奖励计划。
# 2. 不访问经济、背包或战场节点。
# 3. 运行时落地由 RewardManager 承接。

const DROP_TYPES: Array[String] = ["gongfa", "equipment", "unit"]


# 根据 rewards 配置生成奖励计划。
# 计划只表达“应该发什么”，不保证运行时一定发放成功。
# 返回结构固定为 silver/exp/drops，便于 runtime 层直接消费。
static func build_reward_plan(rewards_config: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var plan: Dictionary = {
		"silver": 0,
		"exp": 0,
		"drops": []
	}
	if rewards_config.is_empty():
		return plan

	# 固定奖励直接走字段裁剪，确保不会出现负值。
	plan["silver"] = maxi(int(rewards_config.get("silver", 0)), 0)
	plan["exp"] = maxi(int(rewards_config.get("exp", 0)), 0)

	var drops_value: Variant = rewards_config.get("drops", [])
	if not (drops_value is Array):
		return plan

	# 抽样全程共用同一随机源，避免同一批次内部口径不一致。
	var safe_rng: RandomNumberGenerator = _resolve_rng(rng)
	var drop_plan: Array[Dictionary] = []
	for drop_value in (drops_value as Array):
		if not (drop_value is Dictionary):
			continue
		var drop_rule: Dictionary = _normalize_drop_rule(drop_value as Dictionary)
		if drop_rule.is_empty():
			continue

		# pool 在这里统一整理成字符串数组，后续只做随机索引。
		var pool: Array[String] = []
		var pool_value: Variant = drop_rule.get("pool", [])
		if pool_value is Array:
			for item in (pool_value as Array):
				pool.append(str(item))
		if pool.is_empty():
			continue

		var count: int = int(drop_rule.get("count", 0))
		var chance: float = float(drop_rule.get("chance", 1.0))
		for _idx in range(count):
			# 逐次投点，命中后再从池里抽一条具体 id。
			if safe_rng.randf() > chance:
				continue
			var picked_index: int = safe_rng.randi_range(0, pool.size() - 1)
			var picked_id: String = str(pool[picked_index]).strip_edges()
			if picked_id.is_empty():
				continue
			drop_plan.append({
				"type": str(drop_rule.get("type", "")),
				"id": picked_id
			})
	plan["drops"] = drop_plan
	return plan


# 把掉落行规整成可执行规则，非法配置直接返回空字典。
# 这一层只做字段合法化，不做任何抽样。
# 规范化后 count/chance 都会落到安全范围。
static func _normalize_drop_rule(raw_drop: Dictionary) -> Dictionary:
	var drop_type: String = str(raw_drop.get("type", "")).strip_edges().to_lower()
	if not DROP_TYPES.has(drop_type):
		return {}

	var pool: Array[String] = []
	var pool_value: Variant = raw_drop.get("pool", [])
	if not (pool_value is Array):
		return {}
	for candidate in (pool_value as Array):
		var item_id: String = str(candidate).strip_edges()
		if not item_id.is_empty():
			pool.append(item_id)
	if pool.is_empty():
		return {}

	return {
		"type": drop_type,
		"pool": pool,
		"count": maxi(int(raw_drop.get("count", 1)), 0),
		"chance": clampf(float(raw_drop.get("chance", 1.0)), 0.0, 1.0)
	}


# 规则层允许调用方传入共享 RNG；缺省时会创建本地随机源。
# 这样测试可注入固定种子，生产链路也不会缺随机源。
static func _resolve_rng(rng: RandomNumberGenerator) -> RandomNumberGenerator:
	if rng != null:
		return rng
	var local_rng: RandomNumberGenerator = RandomNumberGenerator.new()
	local_rng.randomize()
	return local_rng
