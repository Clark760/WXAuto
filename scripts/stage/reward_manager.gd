extends RefCounted
class_name RewardManager

# ===========================
# 关卡奖励结算器（M5）
# ===========================
# 职责：
# 1. 根据 domain 侧奖励计划把银两、经验和掉落写入运行时；
# 2. 处理角色掉落的发放与替补回收；
# 3. 返回结构化结果，供 UI 与日志展示。

const STAGE_REWARD_RULES_SCRIPT: Script = preload("res://scripts/domain/stage/stage_reward_rules.gd")

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


# 随机源在构造时初始化一次。
# 这样每次奖励抽样都走同一条随机序列入口。
func _init() -> void:
	_rng.randomize()


# 主入口负责把 domain 奖励计划落地到运行时对象。
# rewards_config 只描述“应该给什么”，这里负责“实际是否给到”。
# 返回值统一为结构化字典，供 presenter 和日志层直接展示。
func apply_stage_rewards(
	rewards_config: Dictionary,
	economy_manager: Node,
	battlefield: Node
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

	# 先让 domain 侧生成计划，runtime 侧只执行计划。
	var reward_plan: Dictionary = STAGE_REWARD_RULES_SCRIPT.build_reward_plan(rewards_config, _rng)
	var silver_reward: int = maxi(int(reward_plan.get("silver", 0)), 0)
	var exp_reward: int = maxi(int(reward_plan.get("exp", 0)), 0)

	# 固定奖励（银两/经验）优先落地，掉落失败不会影响这两项。
	if economy_manager != null and is_instance_valid(economy_manager):
		if silver_reward > 0:
			economy_manager.add_silver(silver_reward)
		if exp_reward > 0:
			economy_manager.add_exp(exp_reward)
	result["silver"] = silver_reward
	result["exp"] = exp_reward

	# 掉落执行结果按类型分别记录，便于 UI 分区展示。
	var drops_value: Variant = reward_plan.get("drops", [])
	if not (drops_value is Array):
		return result
	for drop_value in (drops_value as Array):
		if not (drop_value is Dictionary):
			continue
		var drop: Dictionary = drop_value as Dictionary
		var drop_type: String = str(drop.get("type", "")).strip_edges().to_lower()
		var picked_id: String = str(drop.get("id", "")).strip_edges()
		if picked_id.is_empty():
			continue
		match drop_type:
			"gongfa", "equipment":
				# 物品掉落只在真正写入库存成功后才记入 drops。
				var granted_item: bool = _grant_item_drop(battlefield, drop_type, picked_id)
				if granted_item:
					(result["drops"] as Array).append({
						"type": drop_type,
						"id": picked_id
					})
			"unit":
				# 角色掉落会区分授予成功和丢弃结果。
				var unit_star: int = clampi(int(drop.get("star", 1)), 1, 3)
				var grant_info: Dictionary = _grant_unit_drop(picked_id, unit_star, battlefield)
				if bool(grant_info.get("granted", false)):
					(result["granted_units"] as Array).append(grant_info)
				else:
					(result["discarded_units"] as Array).append(grant_info)
			_:
				continue
	return result


# 物品掉落统一走战场协调层提供的发放入口。
# 这里不直接碰库存结构，保证 Stage 层和库存实现解耦。
func _grant_item_drop(battlefield: Node, item_type: String, item_id: String) -> bool:
	if battlefield == null or not is_instance_valid(battlefield):
		return false
	return bool(battlefield.grant_stage_reward_item(item_type, item_id, 1))


# 角色掉落优先尝试 coordinator 提供的直连入口。
# 入口存在时直接复用它的返回结构，避免重复组装字段。
# 入口缺失时回退到 bench + unit_factory 的通用落位流程。
func _grant_unit_drop(
	unit_id: String,
	star: int,
	battlefield: Node
) -> Dictionary:
	if battlefield == null or not is_instance_valid(battlefield):
		return {
			"type": "unit",
			"id": unit_id,
			"star": star,
			"granted": false,
			"placement": "discarded"
		}

	var direct_result: Variant = battlefield.grant_stage_reward_unit(unit_id, star)
	if direct_result is Dictionary:
		return direct_result
	return {
		"type": "unit",
		"id": unit_id,
		"star": star,
		"granted": false,
		"placement": "discarded"
	}
