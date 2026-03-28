extends RefCounted
class_name ShopCatalogService

# 商店目录领域服务
# 说明：
# 1. 只维护商品池、抽样规则和货架快照。
# 2. 不依赖场景节点，输入输出全部是纯数据。
# 3. 招募、功法、装备三类商品在这里共用一套刷新口径。
# 4. 外层 facade 只负责采集 provider 数据和转发信号。
# 5. 价格、品质和回退策略都在这里保持单一事实来源。

signal shop_refreshed(snapshot: Dictionary)
signal offer_purchased(tab: String, index: int, offer: Dictionary)

const TAB_RECRUIT: String = "recruit"
const TAB_GONGFA: String = "gongfa"
const TAB_EQUIPMENT: String = "equipment"
const QUALITY_ORDER: Array[String] = ["white", "green", "blue", "purple", "orange"]

const DEFAULT_QUALITY_PRICE: Dictionary = {
	"white": 1,
	"green": 2,
	"blue": 3,
	"purple": 4,
	"orange": 5
}

# 品质顺序同时决定抽档顺序和降档回退顺序。
# 默认价格表只服务兜底，不覆盖显式 cost 配置。

var recruit_offer_count: int = 5
var gongfa_offer_count: int = 5
var equipment_offer_count: int = 5

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _unit_pool_by_quality: Dictionary = {}
var _unit_pool_all: Array[Dictionary] = []
var _gongfa_pool: Array[Dictionary] = []
var _equipment_pool: Array[Dictionary] = []

var _snapshot: Dictionary = {
	TAB_RECRUIT: [],
	TAB_GONGFA: [],
	TAB_EQUIPMENT: []
}


# 初始化时只建立随机源，不触碰任何外部 provider。
func _init() -> void:
	_rng.randomize()


# 导出数量变化后由运行时壳层调用这里同步当前配置。
func set_offer_counts(recruit_count: int, gongfa_count: int, equipment_count: int) -> void:
	recruit_offer_count = recruit_count
	gongfa_offer_count = gongfa_count
	equipment_offer_count = equipment_count


# 运行时重新入场时允许重新播种随机源。
func randomize() -> void:
	_rng.randomize()


# 角色、功法和装备池都在这里统一重建成纯数据目录。
func reload_pools(
	unit_records: Array[Dictionary],
	gongfa_rows: Array[Dictionary],
	equipment_rows: Array[Dictionary]
) -> void:
	_rebuild_unit_pool(unit_records)
	_rebuild_gongfa_pool(gongfa_rows)
	_rebuild_equipment_pool(equipment_rows)


# 对外读取整店快照时始终返回深拷贝。
func get_shop_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


# 指定页签商品列表查询只暴露副本，不泄露内部数组引用。
func get_offers(tab: String) -> Array[Dictionary]:
	var source: Variant = _snapshot.get(tab, [])
	var out: Array[Dictionary] = []
	if source is Array:
		for offer in source:
			if offer is Dictionary:
				out.append((offer as Dictionary).duplicate(true))
	return out


# 单格商品读取负责边界判断，并返回稳定副本。
func get_offer(tab: String, index: int) -> Dictionary:
	var source: Variant = _snapshot.get(tab, [])
	if not (source is Array):
		return {}
	var offers: Array = source
	if index < 0 or index >= offers.size():
		return {}
	if not (offers[index] is Dictionary):
		return {}
	return (offers[index] as Dictionary).duplicate(true)


# 刷新逻辑统一处理锁店语义，并在真正重建货架时发刷新信号。
func refresh_shop(
	level_probabilities: Dictionary,
	is_locked: bool = false,
	force_refresh: bool = false
) -> Dictionary:
	if is_locked and not force_refresh and _has_snapshot_content():
		return get_shop_snapshot()

	_snapshot[TAB_RECRUIT] = _generate_recruit_offers(level_probabilities)
	_snapshot[TAB_GONGFA] = _generate_gongfa_offers(level_probabilities)
	_snapshot[TAB_EQUIPMENT] = _generate_equipment_offers(level_probabilities)
	shop_refreshed.emit(get_shop_snapshot())
	return get_shop_snapshot()


# 购买条目只负责把 sold 状态落到快照，扣费和发奖励由外层处理。
func purchase_offer(tab: String, index: int) -> Dictionary:
	var source: Variant = _snapshot.get(tab, [])
	if not (source is Array):
		return {}
	var offers: Array = source
	if index < 0 or index >= offers.size():
		return {}
	if not (offers[index] is Dictionary):
		return {}

	var offer: Dictionary = (offers[index] as Dictionary).duplicate(true)
	if bool(offer.get("sold", false)):
		return {}

	offer["sold"] = true
	offers[index] = offer
	_snapshot[tab] = offers
	offer_purchased.emit(tab, index, offer.duplicate(true))
	return offer.duplicate(true)


# 清空商店会同时重置三类页签，避免跨页保留旧快照。
func clear_shop() -> void:
	_snapshot[TAB_RECRUIT] = []
	_snapshot[TAB_GONGFA] = []
	_snapshot[TAB_EQUIPMENT] = []
	shop_refreshed.emit(get_shop_snapshot())


# 锁店判定只关心当前是否已经存在任意商品快照。
func _has_snapshot_content() -> bool:
	for key in [TAB_RECRUIT, TAB_GONGFA, TAB_EQUIPMENT]:
		var source: Variant = _snapshot.get(key, [])
		if source is Array and not (source as Array).is_empty():
			return true
	return false


# 招募货架先按品质抽档，再按档位和回退规则挑选角色。
func _generate_recruit_offers(level_probabilities: Dictionary) -> Array[Dictionary]:
	var offers: Array[Dictionary] = []
	var count: int = maxi(recruit_offer_count, 1)
	var normalized_probabilities: Dictionary = _normalize_probabilities(level_probabilities)
	for _idx in range(count):
		var quality: String = _roll_quality(normalized_probabilities)
		var picked: Dictionary = _pick_unit_by_quality(quality)
		if picked.is_empty():
			picked = _pick_unit_by_fallback_quality(quality)
		if picked.is_empty():
			picked = _pick_random_dict(_unit_pool_all)
		if picked.is_empty():
			offers.append(_build_empty_offer(TAB_RECRUIT))
			continue
		var item_quality: String = str(picked.get("quality", quality)).strip_edges()
		if item_quality.is_empty():
			item_quality = quality
		item_quality = item_quality.to_lower()
		offers.append({
			"tab": TAB_RECRUIT,
			"item_type": "unit",
			"item_id": str(picked.get("id", "")),
			"name": str(picked.get("name", "Unknown Unit")),
			"quality": item_quality,
			"slot_type": "",
			"price": maxi(int(picked.get("cost", _price_from_quality(item_quality))), 1),
			"sold": false
		})
	return offers


# 功法货架优先消费当前乱序候选池，用完后再按品质补抽。
func _generate_gongfa_offers(level_probabilities: Dictionary) -> Array[Dictionary]:
	var offers: Array[Dictionary] = []
	var candidates: Array[Dictionary] = _gongfa_pool.duplicate(true)
	_shuffle_dict_array(candidates)
	var count: int = maxi(gongfa_offer_count, 1)
	var cursor: int = 0
	for _i in range(count):
		var picked: Dictionary = {}
		if cursor < candidates.size():
			picked = candidates[cursor]
			cursor += 1
		else:
			picked = _pick_gongfa_by_quality(level_probabilities)
		if picked.is_empty():
			offers.append(_build_empty_offer(TAB_GONGFA))
			continue
		var quality: String = str(picked.get("quality", "white")).strip_edges().to_lower()
		offers.append({
			"tab": TAB_GONGFA,
			"item_type": "gongfa",
			"item_id": str(picked.get("id", "")),
			"name": str(picked.get("name", "Unknown Gongfa")),
			"quality": quality,
			"slot_type": str(picked.get("type", "")),
			"price": maxi(int(picked.get("cost", _price_from_quality(quality))), 1),
			"sold": false
		})
	return offers


# 装备货架与功法货架保持同一套刷新策略，避免页签体验分叉。
func _generate_equipment_offers(level_probabilities: Dictionary) -> Array[Dictionary]:
	var offers: Array[Dictionary] = []
	var candidates: Array[Dictionary] = _equipment_pool.duplicate(true)
	_shuffle_dict_array(candidates)
	var count: int = maxi(equipment_offer_count, 1)
	var cursor: int = 0
	for _i in range(count):
		var picked: Dictionary = {}
		if cursor < candidates.size():
			picked = candidates[cursor]
			cursor += 1
		else:
			picked = _pick_equipment_by_quality(level_probabilities)
		if picked.is_empty():
			offers.append(_build_empty_offer(TAB_EQUIPMENT))
			continue
		var quality: String = str(picked.get("quality", "white")).strip_edges().to_lower()
		offers.append({
			"tab": TAB_EQUIPMENT,
			"item_type": "equipment",
			"item_id": str(picked.get("id", "")),
			"name": str(picked.get("name", "Unknown Equipment")),
			"quality": quality,
			"slot_type": str(picked.get("type", "")),
			"price": maxi(int(picked.get("cost", _price_from_quality(quality))), 1),
			"sold": false
		})
	return offers


# 空商品行使用统一占位结构，方便 UI 按 sold 状态直接渲染。
func _build_empty_offer(tab: String) -> Dictionary:
	return {
		"tab": tab,
		"item_type": "",
		"item_id": "",
		"name": "Sold Out",
		"quality": "white",
		"slot_type": "",
		"price": 0,
		"sold": true
	}


# 品质抽样统一走累计概率区间，异常概率表回退为白色。
func _roll_quality(level_probabilities: Dictionary) -> String:
	var normalized: Dictionary = _normalize_probabilities(level_probabilities)
	var roll: float = _rng.randf()
	var accum: float = 0.0
	for quality in QUALITY_ORDER:
		accum += float(normalized.get(quality, 0.0))
		if roll <= accum:
			return quality
	return "white"


# 功法补抽只按品质档过滤，找不到档位时回退到整池随机。
func _pick_gongfa_by_quality(level_probabilities: Dictionary) -> Dictionary:
	var rolled_quality: String = _roll_quality(level_probabilities).to_lower()
	var bucket: Array[Dictionary] = []
	for item in _gongfa_pool:
		if str(item.get("quality", "white")).strip_edges().to_lower() == rolled_quality:
			bucket.append(item)
	if bucket.is_empty():
		return _pick_random_dict(_gongfa_pool)
	return _pick_random_dict(bucket)


# 装备补抽和功法保持一致，避免不同品类出现额外偏置。
func _pick_equipment_by_quality(level_probabilities: Dictionary) -> Dictionary:
	var rolled_quality: String = _roll_quality(level_probabilities).to_lower()
	var bucket: Array[Dictionary] = []
	for item in _equipment_pool:
		if str(item.get("quality", "white")).strip_edges().to_lower() == rolled_quality:
			bucket.append(item)
	if bucket.is_empty():
		return _pick_random_dict(_equipment_pool)
	return _pick_random_dict(bucket)


# 角色按精确品质桶读取，不在这里做降档兜底。
func _pick_unit_by_quality(quality: String) -> Dictionary:
	var key: String = quality.strip_edges().to_lower()
	if _unit_pool_by_quality.has(key):
		return _pick_random_dict(_unit_pool_by_quality[key])
	return {}


# 角色降档兜底从目标档位向低档回退，直到找到可用桶。
func _pick_unit_by_fallback_quality(quality: String) -> Dictionary:
	var base_index: int = QUALITY_ORDER.find(quality.strip_edges().to_lower())
	if base_index < 0:
		base_index = 0
	for idx in range(base_index, -1, -1):
		var key: String = QUALITY_ORDER[idx]
		var bucket: Variant = _unit_pool_by_quality.get(key, [])
		if bucket is Array and not (bucket as Array).is_empty():
			return _pick_random_dict(bucket)
	return {}


# 通用字典随机选择工具只负责从数组里抽一行副本。
func _pick_random_dict(source: Variant) -> Dictionary:
	if not (source is Array):
		return {}
	var list: Array = source as Array
	if list.is_empty():
		return {}
	var idx: int = _rng.randi_range(0, list.size() - 1)
	if not (list[idx] is Dictionary):
		return {}
	return (list[idx] as Dictionary).duplicate(true)


# 候选池乱序使用原地交换，避免刷新时总是按照数据顺序出货。
func _shuffle_dict_array(target: Array[Dictionary]) -> void:
	for idx in range(target.size() - 1, 0, -1):
		var swap_idx: int = _rng.randi_range(0, idx)
		var temp: Dictionary = target[idx]
		target[idx] = target[swap_idx]
		target[swap_idx] = temp


# 角色池重建时会按品质分桶，并过滤 shop_visible=false 的条目。
func _rebuild_unit_pool(unit_records: Array[Dictionary]) -> void:
	_unit_pool_by_quality.clear()
	_unit_pool_all.clear()
	for quality in QUALITY_ORDER:
		_unit_pool_by_quality[quality] = []

	for record_value in unit_records:
		var record: Dictionary = record_value.duplicate(true)
		var unit_id: String = str(record.get("id", "")).strip_edges()
		if unit_id.is_empty():
			continue
		if not bool(record.get("shop_visible", true)):
			continue
		var quality: String = str(record.get("quality", "white")).strip_edges().to_lower()
		if quality.is_empty():
			quality = "white"
		var normalized: Dictionary = {
			"id": unit_id,
			"name": str(record.get("name", unit_id)),
			"quality": quality,
			"cost": maxi(int(record.get("cost", _price_from_quality(quality))), 1),
			"slot_type": ""
		}
		_unit_pool_all.append(normalized)
		if not _unit_pool_by_quality.has(quality):
			_unit_pool_by_quality[quality] = []
		var bucket: Array = _unit_pool_by_quality[quality]
		bucket.append(normalized)
		_unit_pool_by_quality[quality] = bucket


# 功法池重建时统一补齐 quality 和 cost 字段，确保货架结构稳定。
func _rebuild_gongfa_pool(gongfa_rows: Array[Dictionary]) -> void:
	_gongfa_pool.clear()
	for item in gongfa_rows:
		var row: Dictionary = item.duplicate(true)
		if not bool(row.get("shop_visible", true)):
			continue
		row["quality"] = str(row.get("quality", "white")).strip_edges().to_lower()
		row["cost"] = maxi(int(row.get("cost", _price_from_quality(str(row.get("quality", "white"))))), 1)
		_gongfa_pool.append(row)


# 装备池重建逻辑与功法一致，统一补齐展示和定价字段。
func _rebuild_equipment_pool(equipment_rows: Array[Dictionary]) -> void:
	_equipment_pool.clear()
	for item in equipment_rows:
		var row: Dictionary = item.duplicate(true)
		if not bool(row.get("shop_visible", true)):
			continue
		row["quality"] = str(row.get("quality", "white")).strip_edges().to_lower()
		row["cost"] = maxi(int(row.get("cost", _price_from_quality(str(row.get("quality", "white"))))), 1)
		_equipment_pool.append(row)


# 默认价格兜底只依赖品质，不读任何运行时折扣状态。
func _price_from_quality(quality: String) -> int:
	return maxi(int(DEFAULT_QUALITY_PRICE.get(quality, 1)), 1)


# 概率归一化会裁掉负值，并保证总和最终回到 1.0。
func _normalize_probabilities(raw_probabilities: Dictionary) -> Dictionary:
	var out_probabilities: Dictionary = {
		"white": 0.0,
		"green": 0.0,
		"blue": 0.0,
		"purple": 0.0,
		"orange": 0.0
	}
	for key in QUALITY_ORDER:
		out_probabilities[key] = maxf(float(raw_probabilities.get(key, 0.0)), 0.0)
	var total: float = 0.0
	for key in QUALITY_ORDER:
		total += float(out_probabilities[key])
	if total <= 0.0001:
		out_probabilities["white"] = 1.0
		return out_probabilities
	for key in QUALITY_ORDER:
		out_probabilities[key] = float(out_probabilities[key]) / total
	return out_probabilities
