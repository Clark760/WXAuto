extends Node
class_name EconomyManager

# ===========================
# 经济与经验系统管理器
# ===========================
# 设计目标：
# 1. 将银两、门派等级、经验、商店锁定统一为单一资产模型。
# 2. 对外只暴露“加银两/扣银两/加经验”接口，业务层不直接改字典。
# 3. 基于 levels 数据驱动等级曲线，保证后续可用 JSON 调参数值。

signal silver_changed(current_silver: int, delta: int)
signal level_changed(new_level: int, max_deploy: int)
signal exp_changed(current_exp: int, max_exp: int, level: int)
signal shop_lock_changed(locked: bool)
signal assets_changed(snapshot: Dictionary)

const QUALITY_KEYS: Array[String] = ["white", "green", "blue", "purple", "orange"]

# 默认等级曲线（当 levels 数据缺失或异常时使用）
# required_exp 采用“累计总经验阈值”语义，逻辑里会自动转换为“本级升下一级所需经验”。
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

@export var starting_silver: int = 20
@export var refresh_cost: int = 2
@export var upgrade_cost: int = 4
@export var upgrade_exp_gain: int = 4

var assets: Dictionary = {
	"silver": 20,
	"level": 1,
	"exp": 0,
	"max_exp": 2,
	"locked_shop": false
}

var _level_rows: Array[Dictionary] = []
var _level_to_index: Dictionary = {}


func setup_from_data_manager(data_manager: Node) -> void:
	# 从 DataManager 加载 levels，并构建“等级 -> 索引”映射以便高频查询。
	var level_records: Array[Dictionary] = []
	if data_manager != null and data_manager.has_method("get_all_records"):
		var raw_records: Variant = data_manager.call("get_all_records", "levels")
		if raw_records is Array:
			for item in raw_records:
				if item is Dictionary:
					level_records.append((item as Dictionary).duplicate(true))

	_rebuild_level_curve(level_records)
	reset_assets(starting_silver)


func reset_assets(new_starting_silver: int = -1) -> void:
	var silver_seed: int = starting_silver if new_starting_silver < 0 else new_starting_silver
	assets["silver"] = maxi(silver_seed, 0)
	assets["level"] = 1
	assets["exp"] = 0
	assets["max_exp"] = _exp_required_to_next(1)
	assets["locked_shop"] = false
	_emit_all_changed(0)


func get_assets_snapshot() -> Dictionary:
	return assets.duplicate(true)


func get_level() -> int:
	return int(assets.get("level", 1))


func get_silver() -> int:
	return int(assets.get("silver", 0))


func is_shop_locked() -> bool:
	return bool(assets.get("locked_shop", false))


func get_refresh_cost() -> int:
	return maxi(refresh_cost, 0)


func get_upgrade_cost() -> int:
	return maxi(upgrade_cost, 0)


func get_upgrade_exp_gain() -> int:
	return maxi(upgrade_exp_gain, 0)


func get_max_deploy_limit() -> int:
	var level_data: Dictionary = get_level_record(get_level())
	return maxi(int(level_data.get("max_deploy", 5)), 1)


func get_shop_probabilities() -> Dictionary:
	var level_data: Dictionary = get_level_record(get_level())
	var probabilities: Dictionary = _normalize_probabilities(level_data.get("shop_probabilities", {}))
	return probabilities


func get_level_record(level: int = -1) -> Dictionary:
	if _level_rows.is_empty():
		return DEFAULT_LEVEL_ROWS[0].duplicate(true)
	var target_level: int = get_level() if level <= 0 else level
	if _level_to_index.has(target_level):
		return (_level_rows[int(_level_to_index[target_level])] as Dictionary).duplicate(true)
	# 若目标等级不存在，返回最接近的边界值，避免调用方拿到空字典后崩溃。
	if target_level < int((_level_rows[0] as Dictionary).get("level", 1)):
		return (_level_rows[0] as Dictionary).duplicate(true)
	return (_level_rows[_level_rows.size() - 1] as Dictionary).duplicate(true)


func add_silver(amount: int) -> void:
	if amount == 0:
		return
	var old_silver: int = get_silver()
	var next_silver: int = maxi(old_silver + amount, 0)
	assets["silver"] = next_silver
	silver_changed.emit(next_silver, next_silver - old_silver)
	assets_changed.emit(get_assets_snapshot())


func spend_silver(amount: int) -> bool:
	var cost: int = maxi(amount, 0)
	if cost == 0:
		return true
	if get_silver() < cost:
		return false
	add_silver(-cost)
	return true


func add_exp(amount: int) -> void:
	var pending: int = maxi(amount, 0)
	if pending <= 0:
		return

	while pending > 0 and not _is_max_level():
		var current_exp: int = int(assets.get("exp", 0))
		var max_exp: int = maxi(int(assets.get("max_exp", 1)), 1)
		var to_next: int = maxi(max_exp - current_exp, 1)
		var gained: int = mini(to_next, pending)
		current_exp += gained
		pending -= gained
		assets["exp"] = current_exp

		if current_exp >= max_exp:
			assets["exp"] = 0
			_level_up_once()

	if _is_max_level():
		assets["exp"] = 0
		assets["max_exp"] = 0

	exp_changed.emit(int(assets.get("exp", 0)), int(assets.get("max_exp", 0)), get_level())
	assets_changed.emit(get_assets_snapshot())


func buy_exp_with_silver() -> bool:
	var cost: int = get_upgrade_cost()
	if not spend_silver(cost):
		return false
	add_exp(get_upgrade_exp_gain())
	return true


func set_shop_locked(locked: bool) -> void:
	if bool(assets.get("locked_shop", false)) == locked:
		return
	assets["locked_shop"] = locked
	shop_lock_changed.emit(locked)
	assets_changed.emit(get_assets_snapshot())


func record_battle_result(_player_won: bool) -> void:
	# M5 开始：战斗结束不再自动发放经验，统一由关卡奖励配置决定。
	return


func _emit_all_changed(silver_delta: int) -> void:
	var level_now: int = get_level()
	silver_changed.emit(get_silver(), silver_delta)
	level_changed.emit(level_now, get_max_deploy_limit())
	exp_changed.emit(int(assets.get("exp", 0)), int(assets.get("max_exp", 0)), level_now)
	shop_lock_changed.emit(is_shop_locked())
	assets_changed.emit(get_assets_snapshot())


func _level_up_once() -> void:
	if _is_max_level():
		assets["max_exp"] = 0
		return
	var current_level: int = get_level()
	var next_level: int = current_level + 1
	assets["level"] = next_level
	assets["max_exp"] = _exp_required_to_next(next_level)
	level_changed.emit(next_level, get_max_deploy_limit())


func _is_max_level() -> bool:
	if _level_rows.is_empty():
		return true
	var top_level: int = int((_level_rows[_level_rows.size() - 1] as Dictionary).get("level", 1))
	return get_level() >= top_level


func _exp_required_to_next(level: int) -> int:
	# exp 需求由累计阈值差分得到：
	# 例如 level_2.required_exp=2, level_1.required_exp=0，则 1->2 需要 2 点经验。
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
