extends RefCounted

# ===========================
# 角色数据解析器（M1）
# ===========================
# 说明：
# 1. DataManager 负责“通用 JSON 加载”，而 UnitData 负责“角色字段语义化解析”。
# 2. 本脚本只处理 units 分类，统一补默认值、清洗字段并输出可直接给 UnitBase 使用的结构。
# 3. 后续 M2/M3 若新增角色字段，可优先在此处扩展，避免业务脚本散落硬编码。

const DEFAULT_BASE_STATS := {
	"hp": 500.0,
	"mp": 50.0,
	"atk": 50.0,
	"iat": 30.0,
	"def": 20.0,
	"idr": 20.0,
	"spd": 80.0,
	"rng": 1.0,
	"mov": 90.0,
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
	result["faction"] = str(raw_record.get("faction", "jianghu"))
	result["quality"] = _normalize_quality(str(raw_record.get("quality", "white")))

	var default_cost: int = int(QUALITY_TO_COST.get(result["quality"], 1))
	result["cost"] = int(raw_record.get("cost", default_cost))
	result["role"] = str(raw_record.get("role", "vanguard"))

	result["base_stats"] = _normalize_stats(raw_record.get("base_stats", {}))

	var initial_gongfa: Array[String] = []
	if raw_record.get("initial_gongfa", []) is Array:
		for gongfa_id in raw_record["initial_gongfa"]:
			initial_gongfa.append(str(gongfa_id))
	result["initial_gongfa"] = initial_gongfa
	result["gongfa_slots"] = _normalize_gongfa_slots(raw_record.get("gongfa_slots", {}), initial_gongfa)
	result["max_gongfa_count"] = clampi(int(raw_record.get("max_gongfa_count", 3)), 1, 5)

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
	# 升星倍率用于 M1 原型验证，不代表最终平衡值：
	# 1星 1.0x, 2星 1.8x, 3星 3.0x
	var multiplier: float = 1.0
	match star_level:
		2:
			multiplier = 1.8
		3:
			multiplier = 3.0
		_:
			multiplier = 1.0

	var runtime_stats: Dictionary = {}
	for stat_key in base_stats.keys():
		runtime_stats[stat_key] = float(base_stats[stat_key]) * multiplier
	return runtime_stats


static func _normalize_stats(value: Variant) -> Dictionary:
	var output: Dictionary = DEFAULT_BASE_STATS.duplicate(true)
	if value is Dictionary:
		var input_stats: Dictionary = value
		for stat_key in DEFAULT_BASE_STATS.keys():
			if input_stats.has(stat_key):
				output[stat_key] = maxf(float(input_stats[stat_key]), 0.0)
	return output


static func _normalize_tags(value: Variant) -> Array[String]:
	var tags: Array[String] = []
	if value is Array:
		for tag in value:
			tags.append(str(tag))
	return tags


static func _normalize_quality(quality: String) -> String:
	var normalized: String = quality.to_lower()
	if QUALITY_TO_COST.has(normalized):
		return normalized
	return "white"


static func _normalize_gongfa_slots(value: Variant, initial_gongfa: Array[String]) -> Dictionary:
	var slots: Dictionary = {
		"neigong": "",
		"waigong": "",
		"qinggong": "",
		"zhenfa": "",
		"qishu": ""
	}
	if value is Dictionary:
		for key in slots.keys():
			slots[key] = str((value as Dictionary).get(key, "")).strip_edges()

	# 兼容旧版 initial_gongfa：按固定槽位顺序回填，减少历史数据改造成本。
	if initial_gongfa.size() > 0 and slots["neigong"] == "":
		slots["neigong"] = initial_gongfa[0]
	if initial_gongfa.size() > 1 and slots["waigong"] == "":
		slots["waigong"] = initial_gongfa[1]
	if initial_gongfa.size() > 2 and slots["qinggong"] == "":
		slots["qinggong"] = initial_gongfa[2]
	return slots
