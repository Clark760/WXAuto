extends RefCounted
class_name EconomyProgressionService

# 经济进度领域服务
# 说明：
# 1. 只维护等级曲线、资产状态和升级规则。
# 2. 不依赖 Node、场景树或具体 UI。

signal silver_changed(current_silver: int, delta: int)
signal level_changed(new_level: int, max_deploy: int)
signal exp_changed(current_exp: int, max_exp: int, level: int)
signal shop_lock_changed(locked: bool)
signal assets_changed(snapshot: Dictionary)

const QUALITY_KEYS: Array[String] = ["white", "green", "blue", "purple", "orange"]

const DEFAULT_LEVEL_ROWS: Array[Dictionary] = [
	{
		"level": 1,
		"required_exp": 0,
		"max_deploy": 5,
		"shop_probabilities": {"white": 1.0, "green": 0.0, "blue": 0.0, "purple": 0.0, "orange": 0.0}
	},
	{
		"level": 2,
		"required_exp": 2,
		"max_deploy": 8,
		"shop_probabilities": {"white": 0.72, "green": 0.24, "blue": 0.04, "purple": 0.0, "orange": 0.0}
	},
	{
		"level": 3,
		"required_exp": 6,
		"max_deploy": 12,
		"shop_probabilities": {"white": 0.52, "green": 0.30, "blue": 0.14, "purple": 0.04, "orange": 0.0}
	},
	{
		"level": 4,
		"required_exp": 10,
		"max_deploy": 16,
		"shop_probabilities": {"white": 0.36, "green": 0.34, "blue": 0.20, "purple": 0.10, "orange": 0.0}
	},
	{
		"level": 5,
		"required_exp": 20,
		"max_deploy": 20,
		"shop_probabilities": {"white": 0.25, "green": 0.34, "blue": 0.25, "purple": 0.14, "orange": 0.02}
	},
	{
		"level": 6,
		"required_exp": 36,
		"max_deploy": 25,
		"shop_probabilities": {"white": 0.16, "green": 0.28, "blue": 0.31, "purple": 0.20, "orange": 0.05}
	},
	{
		"level": 7,
		"required_exp": 56,
		"max_deploy": 30,
		"shop_probabilities": {"white": 0.08, "green": 0.24, "blue": 0.33, "purple": 0.25, "orange": 0.10}
	},
	{
		"level": 8,
		"required_exp": 80,
		"max_deploy": 36,
		"shop_probabilities": {"white": 0.03, "green": 0.17, "blue": 0.32, "purple": 0.31, "orange": 0.17}
	},
	{
		"level": 9,
		"required_exp": 110,
		"max_deploy": 42,
		"shop_probabilities": {"white": 0.0, "green": 0.10, "blue": 0.28, "purple": 0.36, "orange": 0.26}
	},
	{
		"level": 10,
		"required_exp": 150,
		"max_deploy": 50,
		"shop_probabilities": {"white": 0.0, "green": 0.05, "blue": 0.22, "purple": 0.35, "orange": 0.38}
	}
]

var _assets: Dictionary = {}
var _level_rows: Array[Dictionary] = []
var _level_to_index: Dictionary = {}


# 初始化时装入默认等级曲线，并建立一份可读的初始资产状态。
func _init() -> void:
	_rebuild_level_curve([])
	_assets = {
		"silver": 20,
		"level": 1,
		"exp": 0,
		"max_exp": _exp_required_to_next(1),
		"locked_shop": false
	}


# 外层在数据重载后把 levels 记录交给这里重建等级曲线。
func setup_level_curve(raw_records: Array[Dictionary]) -> void:
	_rebuild_level_curve(raw_records)


# 资产重置时统一回到 1 级与未锁店状态，并广播全量变化。
func reset_assets(starting_silver: int) -> void:
	_assets["silver"] = maxi(starting_silver, 0)
	_assets["level"] = 1
	_assets["exp"] = 0
	_assets["max_exp"] = _exp_required_to_next(1)
	_assets["locked_shop"] = false
	_emit_all_changed(0)


# 快照读取总是返回副本，避免调用方改写内部状态。
func get_assets_snapshot() -> Dictionary:
	return _assets.duplicate(true)


# 读取当前等级时只暴露整数结果。
func get_level() -> int:
	return int(_assets.get("level", 1))


# 读取当前银两时只暴露整数结果。
func get_silver() -> int:
	return int(_assets.get("silver", 0))


# 锁店状态属于资产模型的一部分，查询口径统一收口在这里。
func is_shop_locked() -> bool:
	return bool(_assets.get("locked_shop", false))


# 当前可上阵人数由等级记录里的 max_deploy 决定。
func get_max_deploy_limit() -> int:
	var level_data: Dictionary = get_level_record(get_level())
	return maxi(int(level_data.get("max_deploy", 5)), 1)


# 商店品质概率统一从当前等级记录派生。
func get_shop_probabilities() -> Dictionary:
	var level_data: Dictionary = get_level_record(get_level())
	return _normalize_probabilities(level_data.get("shop_probabilities", {}))


# 指定等级记录查询带边界钳制，避免调用方拿到空字典。
func get_level_record(level: int = -1) -> Dictionary:
	if _level_rows.is_empty():
		return DEFAULT_LEVEL_ROWS[0].duplicate(true)
	var target_level: int = get_level() if level <= 0 else level
	if _level_to_index.has(target_level):
		return (_level_rows[int(_level_to_index[target_level])] as Dictionary).duplicate(true)
	if target_level < int((_level_rows[0] as Dictionary).get("level", 1)):
		return (_level_rows[0] as Dictionary).duplicate(true)
	return (_level_rows[_level_rows.size() - 1] as Dictionary).duplicate(true)


# 银两变化统一在这里落账，并发出增减信号。
func add_silver(amount: int) -> void:
	if amount == 0:
		return
	var old_silver: int = get_silver()
	var next_silver: int = maxi(old_silver + amount, 0)
	_assets["silver"] = next_silver
	silver_changed.emit(next_silver, next_silver - old_silver)
	assets_changed.emit(get_assets_snapshot())


# 扣费逻辑负责余额校验，不允许银两穿透到负数。
func spend_silver(amount: int) -> bool:
	var cost: int = maxi(amount, 0)
	if cost == 0:
		return true
	if get_silver() < cost:
		return false
	add_silver(-cost)
	return true


# 经验增长负责处理升级、满级封顶和经验条刷新。
func add_exp(amount: int) -> void:
	var pending: int = maxi(amount, 0)
	if pending <= 0:
		return

	while pending > 0 and not _is_max_level():
		var current_exp: int = int(_assets.get("exp", 0))
		var max_exp: int = maxi(int(_assets.get("max_exp", 1)), 1)
		var to_next: int = maxi(max_exp - current_exp, 1)
		var gained: int = mini(to_next, pending)
		current_exp += gained
		pending -= gained
		_assets["exp"] = current_exp

		if current_exp >= max_exp:
			_assets["exp"] = 0
			_level_up_once()

	if _is_max_level():
		_assets["exp"] = 0
		_assets["max_exp"] = 0

	exp_changed.emit(int(_assets.get("exp", 0)), int(_assets.get("max_exp", 0)), get_level())
	assets_changed.emit(get_assets_snapshot())


# 锁店状态切换只在状态真的变化时发信号。
func set_shop_locked(locked: bool) -> void:
	if bool(_assets.get("locked_shop", false)) == locked:
		return
	_assets["locked_shop"] = locked
	shop_lock_changed.emit(locked)
	assets_changed.emit(get_assets_snapshot())


# 资产重置后统一广播全量事件，保证外层视图一次同步。
func _emit_all_changed(silver_delta: int) -> void:
	var level_now: int = get_level()
	silver_changed.emit(get_silver(), silver_delta)
	level_changed.emit(level_now, get_max_deploy_limit())
	exp_changed.emit(int(_assets.get("exp", 0)), int(_assets.get("max_exp", 0)), level_now)
	shop_lock_changed.emit(is_shop_locked())
	assets_changed.emit(get_assets_snapshot())


# 单次升级只负责推进等级并刷新下一段经验需求。
func _level_up_once() -> void:
	if _is_max_level():
		_assets["max_exp"] = 0
		return
	var next_level: int = get_level() + 1
	_assets["level"] = next_level
	_assets["max_exp"] = _exp_required_to_next(next_level)
	level_changed.emit(next_level, get_max_deploy_limit())


# 满级判断统一以等级曲线最后一行作为上限。
func _is_max_level() -> bool:
	if _level_rows.is_empty():
		return true
	var top_level: int = int((_level_rows[_level_rows.size() - 1] as Dictionary).get("level", 1))
	return get_level() >= top_level


# 单级经验需求由相邻两行累计经验差值得出。
func _exp_required_to_next(level: int) -> int:
	if _level_rows.size() <= 1:
		return 0
	if not _level_to_index.has(level):
		return 0
	var index: int = int(_level_to_index[level])
	if index >= _level_rows.size() - 1:
		return 0
	var current_row: Dictionary = _level_rows[index]
	var next_row: Dictionary = _level_rows[index + 1]
	var delta: int = int(next_row.get("required_exp", 0)) - int(current_row.get("required_exp", 0))
	return maxi(delta, 1)


# 原始等级配置会在这里补默认值、排序并建立 level 到索引映射。
func _rebuild_level_curve(raw_records: Array[Dictionary]) -> void:
	var normalized: Array[Dictionary] = []
	for record in raw_records:
		var level: int = maxi(int(record.get("level", 0)), 0)
		if level <= 0:
			continue
		normalized.append({
			"id": str(record.get("id", "level_%d" % level)),
			"level": level,
			"required_exp": maxi(int(record.get("required_exp", 0)), 0),
			"max_deploy": maxi(int(record.get("max_deploy", 1)), 1),
			"shop_probabilities": _normalize_probabilities(record.get("shop_probabilities", {}))
		})

	if normalized.is_empty():
		for fallback in DEFAULT_LEVEL_ROWS:
			normalized.append((fallback as Dictionary).duplicate(true))

	normalized.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("level", 0)) < int(b.get("level", 0))
	)

	_level_rows = normalized
	_level_to_index.clear()
	for idx in range(_level_rows.size()):
		var level_key: int = int((_level_rows[idx] as Dictionary).get("level", idx + 1))
		_level_to_index[level_key] = idx


# 商店概率统一裁剪负值并归一化到 1.0。
func _normalize_probabilities(raw_probabilities: Variant) -> Dictionary:
	var out_probabilities: Dictionary = {
		"white": 0.0,
		"green": 0.0,
		"blue": 0.0,
		"purple": 0.0,
		"orange": 0.0
	}
	if raw_probabilities is Dictionary:
		for key in QUALITY_KEYS:
			out_probabilities[key] = maxf(float((raw_probabilities as Dictionary).get(key, 0.0)), 0.0)

	var total: float = 0.0
	for key in QUALITY_KEYS:
		total += float(out_probabilities[key])
	if total <= 0.0001:
		out_probabilities["white"] = 1.0
		return out_probabilities

	for key in QUALITY_KEYS:
		out_probabilities[key] = float(out_probabilities[key]) / total
	return out_probabilities
