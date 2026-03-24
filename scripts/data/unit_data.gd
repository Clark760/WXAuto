extends RefCounted

# ===========================
# 角色数据解析器
# ===========================
# 说明：
# 1. DataManager 负责“通用 JSON 加载”，而 UnitData 负责“角色字段语义化解析”。
# 2. 本脚本只处理 units 分类，统一补默认值、清洗字段并输出可直接给 UnitBase 使用的结构。

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
	"orange": 5,
	"red": 6
}


static func normalize_unit_record(raw_record: Dictionary) -> Dictionary:
	# 角色记录必须包含 id；缺失时返回空对象，调用方应跳过。
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

	# 装备槽位与功法槽位一样，统一在数据层补齐默认值，
	# 这样战斗层/详情面板可以直接读取，避免每个调用点各自兜底。
	result["equip_slots"] = _normalize_equip_slots(raw_record.get("equip_slots", {}))
	result["max_equip_count"] = clampi(int(raw_record.get("max_equip_count", 3)), 0, 3)

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

	# 保留原始 meta 字段，便于调试来源定位。
	if raw_record.has("_meta_source_file"):
		result["_meta_source_file"] = raw_record["_meta_source_file"]
	if raw_record.has("_meta_source_tag"):
		result["_meta_source_tag"] = raw_record["_meta_source_tag"]

	return result


static func build_runtime_stats(base_stats: Dictionary, star_level: int) -> Dictionary:
	# 升星倍率在数据层统一维护，便于后续整体调平：
	# 1星 1.0x, 2星 1.8x, 3星 3.0x
	var multiplier: float = 1.0
	match star_level:
		2:
			multiplier = 1.8
		3:
			multiplier = 3.0
		_:
			multiplier = 1.0

	# 升星仅影响核心战斗数值；RNG/SPD/WIS 为固定基础值（可被 effect 改写）。
	var scaled_keys: Array[String] = ["hp", "mp", "atk", "iat", "def", "idr"]
	var runtime_stats: Dictionary = {}
	for stat_key in base_stats.keys():
		var value: float = float(base_stats.get(stat_key, 0.0))
		if scaled_keys.has(stat_key):
			runtime_stats[stat_key] = value * multiplier
		else:
			runtime_stats[stat_key] = value
	# 运行时底线约束：
	# - rng 最小 1（不能为 0）
	# - spd/wis 最小 0
	runtime_stats["rng"] = maxf(float(runtime_stats.get("rng", 1.0)), 1.0)
	runtime_stats["spd"] = maxf(float(runtime_stats.get("spd", 0.0)), 0.0)
	runtime_stats["wis"] = maxf(float(runtime_stats.get("wis", 0.0)), 0.0)
	return runtime_stats


static func _normalize_stats(value: Variant) -> Dictionary:
	var output: Dictionary = DEFAULT_BASE_STATS.duplicate(true)
	if value is Dictionary:
		var input_stats: Dictionary = value
		for stat_key in DEFAULT_BASE_STATS.keys():
			if input_stats.has(stat_key):
				output[stat_key] = float(input_stats[stat_key])
	# 明确约束：rng >= 1；spd/wis >= 0；其他基础属性 >= 0。
	for stat_key in output.keys():
		output[stat_key] = maxf(float(output[stat_key]), 0.0)
	output["rng"] = maxf(float(output.get("rng", 1.0)), 1.0)
	output["spd"] = maxf(float(output.get("spd", 0.0)), 0.0)
	output["wis"] = maxf(float(output.get("wis", 0.0)), 0.0)
	return output


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


static func _normalize_traits(value: Variant) -> Array[Dictionary]:
	var traits: Array[Dictionary] = []
	if value is Array:
		for trait_value in value:
			if trait_value is Dictionary:
				var trait_data: Dictionary = (trait_value as Dictionary).duplicate(true)
				trait_data["tags"] = _normalize_tags(trait_data.get("tags", []))
				traits.append(trait_data)
	return traits


static func _normalize_quality(quality: String) -> String:
	var normalized: String = quality.to_lower()
	if QUALITY_TO_COST.has(normalized):
		return normalized
	return "white"


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


static func _normalize_equip_slots(value: Variant) -> Dictionary:
	# 固定三类装备槽位：兵器、护甲、饰品。
	# 后续如果扩展额外槽位，应优先在此处统一定义再向上游暴露。
	var slots: Dictionary = {
		"weapon": "",
		"armor": "",
		"accessory": ""
	}
	if value is Dictionary:
		for key in slots.keys():
			slots[key] = str((value as Dictionary).get(key, "")).strip_edges()
	return slots
