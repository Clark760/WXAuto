extends RefCounted
class_name UnitData

# 角色数据解析器
# 说明：
# 1. DataManager 负责原始 JSON 加载，UnitData 负责字段语义化和默认值补齐。
# 2. 本文件只处理 units 配置，不访问场景树和运行时节点。
# 3. 这里产出的结构会被 UnitFactory、UnitBase 和测试共同复用。
# 4. 新增字段时先在这里确定默认口径，再放给运行时读取。
# 5. 目标是把坏输入裁掉，把缺省值补齐，把结构固定下来。
# 6. 角色星级成长、槽位展开和标签去重都在这里统一定标。

const DEFAULT_BASE_STATS := {
	"hp": 500.0,
	"mp": 50.0,
	"atk": 50.0,
	"iat": 30.0,
	"def": 20.0,
	"idr": 20.0,
	"spd": 80.0,
	"rng": 1.0,
	"wis": 40.0
}

const DEFAULT_ANIMATION_OVERRIDES := {}

const QUALITY_TO_COST := {
	"white": 1,
	"green": 2,
	"blue": 3,
	"purple": 4,
	"orange": 5
}

# 默认属性表就是角色 schema 的最低保底线。
# 品质到价格映射只作为 cost 缺省值，不覆盖显式配置。
# 这里保留集中常量，是为了让测试和运行时看到同一份默认语义。


# 规范化单条角色记录，统一补默认值并裁掉非法输入。
static func normalize_unit_record(raw_record: Dictionary) -> Dictionary:
	var unit_id: String = str(raw_record.get("id", "")).strip_edges()
	if unit_id.is_empty():
		return {}

	var result: Dictionary = {}
	result["id"] = unit_id
	result["name"] = str(raw_record.get("name", unit_id))
	result["quality"] = _normalize_quality(str(raw_record.get("quality", "white")))

	var default_cost: int = int(QUALITY_TO_COST.get(result["quality"], 1))
	result["cost"] = int(raw_record.get("cost", default_cost))
	result["shop_visible"] = bool(raw_record.get("shop_visible", true))

	result["base_stats"] = _normalize_stats(raw_record.get("base_stats", {}))
	result["traits"] = _normalize_traits(raw_record.get("traits", []))

	var initial_gongfa: Array[String] = []
	var initial_gongfa_value: Variant = raw_record.get("initial_gongfa", [])
	if initial_gongfa_value is Array:
		for gongfa_id in initial_gongfa_value:
			initial_gongfa.append(str(gongfa_id))
	result["initial_gongfa"] = initial_gongfa
	result["gongfa_slots"] = _normalize_gongfa_slots(raw_record.get("gongfa_slots", {}), initial_gongfa)

	var equip_slots: Dictionary = _normalize_equip_slots(raw_record.get("equip_slots", {}))
	var default_equip_count: int = maxi(equip_slots.size(), 2)
	var max_equip_count: int = int(raw_record.get("max_equip_count", default_equip_count))
	if max_equip_count <= 0:
		max_equip_count = default_equip_count
	equip_slots = _normalize_equip_slots(equip_slots, max_equip_count)
	result["equip_slots"] = equip_slots
	result["max_equip_count"] = maxi(max_equip_count, 1)

	result["sprite_path"] = str(raw_record.get(
		"sprite_path",
		"assets/sprites/units/%s.png" % unit_id
	))
	result["portrait_path"] = str(raw_record.get(
		"portrait_path",
		"assets/sprites/portraits/%s.png" % unit_id
	))

	var animation_value: Variant = raw_record.get("animation_overrides", DEFAULT_ANIMATION_OVERRIDES)
	var animation_overrides: Dictionary = {}
	if animation_value is Dictionary:
		animation_overrides = (animation_value as Dictionary).duplicate(true)
	result["animation_overrides"] = animation_overrides

	result["base_star"] = clampi(int(raw_record.get("base_star", 1)), 1, 3)
	result["max_star"] = clampi(int(raw_record.get("max_star", 3)), 1, 3)
	result["tags"] = _normalize_tags(raw_record.get("tags", []))

	if raw_record.has("_meta_source_file"):
		result["_meta_source_file"] = raw_record["_meta_source_file"]
	if raw_record.has("_meta_source_tag"):
		result["_meta_source_tag"] = raw_record["_meta_source_tag"]

	return result


# 按星级倍率构建运行时属性，并保持非战斗向字段不被放大。
static func build_runtime_stats(base_stats: Dictionary, star_level: int) -> Dictionary:
	var multiplier: float = 1.0
	match star_level:
		2:
			multiplier = 1.8
		3:
			multiplier = 3.0
		_:
			multiplier = 1.0

	var scaled_keys: Array[String] = ["hp", "atk", "iat", "def", "idr"]
	var runtime_stats: Dictionary = {}
	for stat_key in base_stats.keys():
		var value: float = float(base_stats.get(stat_key, 0.0))
		if scaled_keys.has(stat_key):
			runtime_stats[stat_key] = value * multiplier
		else:
			runtime_stats[stat_key] = value

	runtime_stats["rng"] = maxf(float(runtime_stats.get("rng", 1.0)), 1.0)
	runtime_stats["spd"] = maxf(float(runtime_stats.get("spd", 0.0)), 0.0)
	runtime_stats["wis"] = maxf(float(runtime_stats.get("wis", 0.0)), 0.0)
	return runtime_stats


# 基础属性规范化会补齐缺省字段，并钳制非法下界。
static func _normalize_stats(value: Variant) -> Dictionary:
	var output: Dictionary = DEFAULT_BASE_STATS.duplicate(true)
	if value is Dictionary:
		var input_stats: Dictionary = value
		for stat_key in DEFAULT_BASE_STATS.keys():
			if input_stats.has(stat_key):
				output[stat_key] = float(input_stats[stat_key])
	for stat_key in output.keys():
		output[stat_key] = maxf(float(output[stat_key]), 0.0)
	output["rng"] = maxf(float(output.get("rng", 1.0)), 1.0)
	output["spd"] = maxf(float(output.get("spd", 0.0)), 0.0)
	output["wis"] = maxf(float(output.get("wis", 0.0)), 0.0)
	return output


# 标签数组会去空、去重并保留第一次出现的写法。
static func _normalize_tags(value: Variant) -> Array[String]:
	var tags: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		for tag in value:
			var normalized: String = str(tag).strip_edges()
			if normalized.is_empty():
				continue
			var lookup_key: String = normalized.to_lower()
			if seen.has(lookup_key):
				continue
			seen[lookup_key] = true
			tags.append(normalized)
	return tags


# trait 规范化会递归清洗内部 tags，保证查询口径稳定。
static func _normalize_traits(value: Variant) -> Array[Dictionary]:
	var traits: Array[Dictionary] = []
	if value is Array:
		for trait_value in value:
			if trait_value is Dictionary:
				var trait_data: Dictionary = (trait_value as Dictionary).duplicate(true)
				trait_data["tags"] = _normalize_tags(trait_data.get("tags", []))
				traits.append(trait_data)
	return traits


# 品质值只允许落入当前支持的品质枚举。
static func _normalize_quality(quality: String) -> String:
	var normalized: String = quality.to_lower()
	if QUALITY_TO_COST.has(normalized):
		return normalized
	return "white"


# 功法槽位保持固定结构，缺失槽位统一补空字符串。
static func _normalize_gongfa_slots(value: Variant, _initial_gongfa: Array[String]) -> Dictionary:
	var slots: Dictionary = {
		"neigong": "",
		"waigong": "",
		"qinggong": "",
		"zhenfa": ""
	}
	if value is Dictionary:
		for key in slots.keys():
			slots[key] = str((value as Dictionary).get(key, "")).strip_edges()
	return slots


# 装备槽位支持动态扩展，并补齐到 max_equip_count 需要的数量。
static func _normalize_equip_slots(value: Variant, desired_count: int = 0) -> Dictionary:
	var slots: Dictionary = {}
	if value is Dictionary:
		var raw_dict: Dictionary = value as Dictionary
		var keys: Array[String] = []
		for raw_key in raw_dict.keys():
			var key: String = str(raw_key).strip_edges()
			if key.is_empty():
				continue
			keys.append(key)
		keys.sort()
		for key in keys:
			slots[key] = str(raw_dict.get(key, "")).strip_edges()
	if slots.is_empty():
		slots["slot_1"] = ""
		slots["slot_2"] = ""
	var target_count: int = maxi(desired_count, 0)
	if target_count <= slots.size():
		return slots
	for idx in range(1, target_count + 1):
		if slots.size() >= target_count:
			break
		var key: String = "slot_%d" % idx
		if not slots.has(key):
			slots[key] = ""
	if slots.size() >= target_count:
		return slots
	var extra_idx: int = 1
	while slots.size() < target_count:
		var extra_key: String = "equip_slot_%d" % extra_idx
		if not slots.has(extra_key):
			slots[extra_key] = ""
		extra_idx += 1
	return slots
