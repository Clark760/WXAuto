extends Node
class_name EconomyManager

# 经济运行时壳层
# 说明：
# 1. 保留场景节点、导出参数和信号契约。
# 2. 等级曲线与资产状态全部委托给 domain service。

signal silver_changed(current_silver: int, delta: int)
signal level_changed(new_level: int, max_deploy: int)
signal exp_changed(current_exp: int, max_exp: int, level: int)
signal shop_lock_changed(locked: bool)
signal assets_changed(snapshot: Dictionary)

const ECONOMY_PROGRESSION_SERVICE_SCRIPT: Script = preload(
	"res://scripts/domain/economy/economy_progression_service.gd"
)

@export var starting_silver: int = 20
@export var refresh_cost: int = 2
@export var upgrade_cost: int = 4
@export var upgrade_exp_gain: int = 4

var _progression: RefCounted = ECONOMY_PROGRESSION_SERVICE_SCRIPT.new()


# 初始化时只挂接 domain service 的信号桥。
func _init() -> void:
	_connect_service_signals()


# 从 DataManager 提取 levels 记录，并交给 domain service 重建等级曲线。
func setup_from_data_manager(data_manager: Node) -> void:
	var level_records: Array[Dictionary] = []
	if data_manager != null:
		var raw_records: Variant = data_manager.get_all_records("levels")
		if raw_records is Array:
			for item in raw_records:
				if item is Dictionary:
					level_records.append((item as Dictionary).duplicate(true))
	_progression.setup_level_curve(level_records)
	reset_assets(starting_silver)


# 重置运行时资产时继续遵守 facade 导出的起始银两口径。
func reset_assets(new_starting_silver: int = -1) -> void:
	var silver_seed: int = starting_silver if new_starting_silver < 0 else new_starting_silver
	_progression.reset_assets(silver_seed)


# 对外只暴露资产快照副本，避免外层误写内部状态。
func get_assets_snapshot() -> Dictionary:
	return _progression.get_assets_snapshot()


# 读取当前等级时直接透传 domain service。
func get_level() -> int:
	return _progression.get_level()


# 读取当前银两时直接透传 domain service。
func get_silver() -> int:
	return _progression.get_silver()


# 锁店状态继续由经济 facade 对外提供统一查询口径。
func is_shop_locked() -> bool:
	return _progression.is_shop_locked()


# 刷新价格仍由场景导出参数决定，不迁入资产状态服务。
func get_refresh_cost() -> int:
	return maxi(refresh_cost, 0)


# 升级价格仍由场景导出参数决定，不和资产状态耦合。
func get_upgrade_cost() -> int:
	return maxi(upgrade_cost, 0)


# 单次购买经验收益仍由 facade 持有配置口径。
func get_upgrade_exp_gain() -> int:
	return maxi(upgrade_exp_gain, 0)


# 上阵上限查询继续委托 domain service 的等级规则。
func get_max_deploy_limit() -> int:
	return _progression.get_max_deploy_limit()


# 商店品质概率继续从 domain service 的等级曲线读取。
func get_shop_probabilities() -> Dictionary:
	return _progression.get_shop_probabilities()


# 指定等级记录查询继续透传给 domain service。
func get_level_record(level: int = -1) -> Dictionary:
	return _progression.get_level_record(level)


# 银两增减继续由 domain service 维护状态与信号。
func add_silver(amount: int) -> void:
	_progression.add_silver(amount)


# 扣费逻辑继续由 domain service 做余额校验。
func spend_silver(amount: int) -> bool:
	return _progression.spend_silver(amount)


# 经验增长继续由 domain service 负责升级与上限处理。
func add_exp(amount: int) -> void:
	_progression.add_exp(amount)


# 购买经验维持原有“先扣费再加经验”的 facade 行为。
func buy_exp_with_silver() -> bool:
	if not spend_silver(get_upgrade_cost()):
		return false
	add_exp(get_upgrade_exp_gain())
	return true


# 锁店开关继续透传给 domain service，保持外部契约稳定。
func set_shop_locked(locked: bool) -> void:
	_progression.set_shop_locked(locked)


# 战斗结算发经验已移除，这里保留空实现兼容现有调用面。
func record_battle_result(_player_won: bool) -> void:
	return


# 统一把 domain service 信号桥接回 Node facade 信号。
func _connect_service_signals() -> void:
	var silver_cb: Callable = Callable(self, "_on_service_silver_changed")
	if not _progression.is_connected("silver_changed", silver_cb):
		_progression.connect("silver_changed", silver_cb)
	var level_cb: Callable = Callable(self, "_on_service_level_changed")
	if not _progression.is_connected("level_changed", level_cb):
		_progression.connect("level_changed", level_cb)
	var exp_cb: Callable = Callable(self, "_on_service_exp_changed")
	if not _progression.is_connected("exp_changed", exp_cb):
		_progression.connect("exp_changed", exp_cb)
	var lock_cb: Callable = Callable(self, "_on_service_shop_lock_changed")
	if not _progression.is_connected("shop_lock_changed", lock_cb):
		_progression.connect("shop_lock_changed", lock_cb)
	var assets_cb: Callable = Callable(self, "_on_service_assets_changed")
	if not _progression.is_connected("assets_changed", assets_cb):
		_progression.connect("assets_changed", assets_cb)


# 转发银两变更信号，保持旧节点信号名不变。
func _on_service_silver_changed(current_silver: int, delta: int) -> void:
	silver_changed.emit(current_silver, delta)


# 转发等级变化信号，供 HUD 和 coordinator 继续复用。
func _on_service_level_changed(new_level: int, max_deploy: int) -> void:
	level_changed.emit(new_level, max_deploy)


# 转发经验变化信号，保持现有展示刷新链路不变。
func _on_service_exp_changed(current_exp: int, max_exp: int, level: int) -> void:
	exp_changed.emit(current_exp, max_exp, level)


# 转发锁店状态变化信号，供顶栏和刷新逻辑继续监听。
func _on_service_shop_lock_changed(locked: bool) -> void:
	shop_lock_changed.emit(locked)


# 转发资产快照信号时继续返回副本，避免外部持有引用。
func _on_service_assets_changed(snapshot: Dictionary) -> void:
	assets_changed.emit(snapshot.duplicate(true))
