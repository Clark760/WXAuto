extends Node
class_name ShopManager

# ===========================
# 综合商店管理器
# ===========================
# 设计目标：
# 1. 单一管理三类商店池：侠客、秘籍、装备。
# 2. 刷新逻辑一次性生成三类商品，保证“跨页签同步刷新”。
# 3. 对外只返回纯字典快照，UI 与业务层都不直接修改内部池。

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

@export var recruit_offer_count: int = 5
@export var gongfa_offer_count: int = 5
@export var equipment_offer_count: int = 5

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

# 随机数生成器只在启动时播种一次，后续所有商店刷新都复用同一实例。
func _ready() -> void:
	_rng.randomize()


# `unit_factory` 提供侠客数据，`unit_augment_manager` 提供功法与装备数据。
# 商店只缓存快照，不持有外部数据对象的可变引用。
func reload_pools(unit_factory: Node, unit_augment_manager: Node) -> void:
	_rebuild_unit_pool(unit_factory)
	_rebuild_gongfa_pool(unit_augment_manager)
	_rebuild_equipment_pool(unit_augment_manager)


# 对外统一返回深拷贝快照，避免 UI 或流程层意外改写内部池状态。
func get_shop_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


# `tab` 只回答当前页签商品列表，不暴露内部 `_snapshot` 原始数组引用。
func get_offers(tab: String) -> Array[Dictionary]:
	var source: Variant = _snapshot.get(tab, [])
	var out: Array[Dictionary] = []
	if source is Array:
		for offer in source:
			if offer is Dictionary:
				out.append((offer as Dictionary).duplicate(true))
	return out

# 单条商品查询只做读取，不会隐式把商品标记为售出。
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

# `level_probabilities` 只影响品质抽样，不影响锁店语义。
# `force_refresh` 为 true 时必须无视锁店，直接重掷三类商品。
func refresh_shop(level_probabilities: Dictionary, is_locked: bool = false, force_refresh: bool = false) -> Dictionary:
	# 锁店规则：仅当“已有快照且非强制刷新”时保留旧商品。
	if is_locked and not force_refresh and _has_snapshot_content():
		return get_shop_snapshot()

	_snapshot[TAB_RECRUIT] = _generate_recruit_offers(level_probabilities)
	_snapshot[TAB_GONGFA] = _generate_gongfa_offers(level_probabilities)
	_snapshot[TAB_EQUIPMENT] = _generate_equipment_offers(level_probabilities)
	shop_refreshed.emit(get_shop_snapshot())
	return get_shop_snapshot()

# 购买逻辑只把当前格子的 `sold` 置真，真正扣钱和发奖仍由外层处理。
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

# 清空商店会把三类页签一起重置，避免跨页签保留脏快照。
func clear_shop() -> void:
	_snapshot[TAB_RECRUIT] = []
	_snapshot[TAB_GONGFA] = []
	_snapshot[TAB_EQUIPMENT] = []
	shop_refreshed.emit(get_shop_snapshot())

# 这里只判断“当前是否已有任何商品快照”，供锁店逻辑快速复用。
func _has_snapshot_content() -> bool:
	for key in [TAB_RECRUIT, TAB_GONGFA, TAB_EQUIPMENT]:
		var source: Variant = _snapshot.get(key, [])
		if source is Array and not (source as Array).is_empty():
			return true
	return false

# 招募商品按品质概率抽样，若目标品质桶为空则逐级回退，最后才走全池随机。
func _generate_recruit_offers(level_probabilities: Dictionary) -> Array[Dictionary]:
	var offers: Array[Dictionary] = []
	var count: int = maxi(recruit_offer_count, 1)
	var normalized_probabilities: Dictionary = _normalize_probabilities(level_probabilities)
	for idx in range(count):
		var quality: String = _roll_quality(normalized_probabilities)
		var picked: Dictionary = _pick_unit_by_quality(quality)
		if picked.is_empty():
			# 先尝试“降级兜底”，再走全池随机，避免单一品质池为空时出牌失真。
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
			"name": str(picked.get("name", "未知侠客")),
			"quality": item_quality,
			"slot_type": "",
			"price": maxi(int(picked.get("cost", _price_from_quality(item_quality))), 1),
			"sold": false
		})
	return offers

# 功法商店优先吃当前乱序候选池，池子不够时才回到按品质补抽。
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
			"name": str(picked.get("name", "无名秘籍")),
			"quality": quality,
			"slot_type": str(picked.get("type", "")),
			"price": maxi(int(picked.get("cost", _price_from_quality(quality))), 1),
			"sold": false
		})
	return offers

# 装备商店和功法商店保持同一刷新策略，避免不同页签出现抽样规则分叉。
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
			"name": str(picked.get("name", "无名装备")),
			"quality": quality,
			"slot_type": str(picked.get("type", "")),
			"price": maxi(int(picked.get("cost", _price_from_quality(quality))), 1),
			"sold": false
		})
	return offers

# 空商品是 UI 层统一识别的售罄占位结构，不代表真实物品条目。
func _build_empty_offer(tab: String) -> Dictionary:
	return {
		"tab": tab,
		"item_type": "",
		"item_id": "",
		"name": "已售罄",
		"quality": "white",
		"slot_type": "",
		"price": 0,
		"sold": true
	}

# 品质抽样统一走累计概率区间，异常概率表会回退为白色。
func _roll_quality(level_probabilities: Dictionary) -> String:
	# 按“概率累计区间”抽样，若概率表异常则回退白色。
	var normalized: Dictionary = _normalize_probabilities(level_probabilities)
	var roll: float = _rng.randf()
	var accum: float = 0.0
	for quality in QUALITY_ORDER:
		accum += float(normalized.get(quality, 0.0))
		if roll <= accum:
			return quality
	return "white"

# 功法补抽只按品质过滤，不再额外看槽位或标签条件。
func _pick_gongfa_by_quality(level_probabilities: Dictionary) -> Dictionary:
	var rolled_quality: String = _roll_quality(level_probabilities).to_lower()
	var bucket: Array[Dictionary] = []
	for item in _gongfa_pool:
		if str(item.get("quality", "white")).strip_edges().to_lower() == rolled_quality:
			bucket.append(item)
	if bucket.is_empty():
		return _pick_random_dict(_gongfa_pool)
	return _pick_random_dict(bucket)

# 装备补抽与功法相同，品质桶为空时回退到整池随机。
func _pick_equipment_by_quality(level_probabilities: Dictionary) -> Dictionary:
	var rolled_quality: String = _roll_quality(level_probabilities).to_lower()
	var bucket: Array[Dictionary] = []
	for item in _equipment_pool:
		if str(item.get("quality", "white")).strip_edges().to_lower() == rolled_quality:
			bucket.append(item)
	if bucket.is_empty():
		return _pick_random_dict(_equipment_pool)
	return _pick_random_dict(bucket)

# 侠客抽样优先命中同品质桶，不在这里做品质降级。
func _pick_unit_by_quality(quality: String) -> Dictionary:
	var key: String = quality.strip_edges().to_lower()
	if _unit_pool_by_quality.has(key):
		return _pick_random_dict(_unit_pool_by_quality[key])
	return {}

# 当目标品质桶为空时，这里按品质从高到低回退，保证刷新仍然可用。
func _pick_unit_by_fallback_quality(quality: String) -> Dictionary:
	var base_index: int = QUALITY_ORDER.find(quality.strip_edges().to_lower())
	if base_index < 0:
		base_index = 0
	# 从目标品质向低品质回退，保证高等级不会因为单桶为空而完全抽不到目标梯度。
	for idx in range(base_index, -1, -1):
		var key: String = QUALITY_ORDER[idx]
		var bucket: Variant = _unit_pool_by_quality.get(key, [])
		if bucket is Array and not (bucket as Array).is_empty():
			return _pick_random_dict(bucket)
	return {}

# 这是商店内部通用的随机抽一条字典工具，不承载任何业务过滤。
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

# 候选列表乱序只用于本轮刷新，调用方传入的数组副本会被原地洗牌。
func _shuffle_dict_array(target: Array[Dictionary]) -> void:
	for idx in range(target.size() - 1, 0, -1):
		var swap_idx: int = _rng.randi_range(0, idx)
		var temp: Dictionary = target[idx]
		target[idx] = target[swap_idx]
		target[swap_idx] = temp

# 侠客池重建时会过滤 `shop_visible=false`，并按品质建立索引桶。
func _rebuild_unit_pool(unit_factory: Node) -> void:
	_unit_pool_by_quality.clear()
	_unit_pool_all.clear()
	for quality in QUALITY_ORDER:
		_unit_pool_by_quality[quality] = []

	if unit_factory == null:
		return
	if not unit_factory.has_method("get_unit_ids") or not unit_factory.has_method("get_unit_record"):
		return

	var unit_ids: Variant = unit_factory.call("get_unit_ids")
	if not (unit_ids is Array):
		return
	for id_value in unit_ids:
		var unit_id: String = str(id_value).strip_edges()
		if unit_id.is_empty():
			continue
		var record_value: Variant = unit_factory.call("get_unit_record", unit_id)
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = (record_value as Dictionary).duplicate(true)
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

# 功法池重建只接受对外公开的功法列表，不直接读底层注册表。
func _rebuild_gongfa_pool(unit_augment_manager: Node) -> void:
	_gongfa_pool.clear()
	if unit_augment_manager == null or not unit_augment_manager.has_method("get_all_gongfa"):
		return
	var raw_data: Variant = unit_augment_manager.call("get_all_gongfa")
	if not (raw_data is Array):
		return
	for item in raw_data:
		if not (item is Dictionary):
			continue
		var row: Dictionary = (item as Dictionary).duplicate(true)
		if not bool(row.get("shop_visible", true)):
			continue
		row["quality"] = str(row.get("quality", "white")).strip_edges().to_lower()
		row["cost"] = maxi(int(row.get("cost", _price_from_quality(str(row.get("quality", "white"))))), 1)
		_gongfa_pool.append(row)

# 装备池重建与功法池同口径，统一补齐质量和价格字段。
func _rebuild_equipment_pool(unit_augment_manager: Node) -> void:
	_equipment_pool.clear()
	if unit_augment_manager == null or not unit_augment_manager.has_method("get_all_equipment"):
		return
	var raw_data: Variant = unit_augment_manager.call("get_all_equipment")
	if not (raw_data is Array):
		return
	for item in raw_data:
		if not (item is Dictionary):
			continue
		var row: Dictionary = (item as Dictionary).duplicate(true)
		if not bool(row.get("shop_visible", true)):
			continue
		row["quality"] = str(row.get("quality", "white")).strip_edges().to_lower()
		row["cost"] = maxi(int(row.get("cost", _price_from_quality(str(row.get("quality", "white"))))), 1)
		_equipment_pool.append(row)

# 价格兜底只依赖品质，不在这里读取折扣或阶段修正。
func _price_from_quality(quality: String) -> int:
	return maxi(int(DEFAULT_QUALITY_PRICE.get(quality, 1)), 1)


# 概率归一化会把非法负值钳为 0，并保证总和始终回到 1。
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
