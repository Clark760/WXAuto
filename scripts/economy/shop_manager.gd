extends Node
class_name ShopManager

# 商店运行时壳层
# 说明：
# 1. 保留节点导出参数和信号契约。
# 2. 商品池与抽样规则全部委托给 domain shop service。

signal shop_refreshed(snapshot: Dictionary)
signal offer_purchased(tab: String, index: int, offer: Dictionary)

const SHOP_CATALOG_SERVICE_SCRIPT: Script = preload(
	"res://scripts/domain/shop/shop_catalog_service.gd"
)

@export var recruit_offer_count: int = 5
@export var gongfa_offer_count: int = 5
@export var equipment_offer_count: int = 5

var _catalog: RefCounted = SHOP_CATALOG_SERVICE_SCRIPT.new()


# 初始化时挂好 signal bridge，并把导出数量同步给 service。
func _init() -> void:
	_connect_service_signals()
	_sync_offer_counts()


# 场景就绪时只刷新随机源，不承载业务规则。
func _ready() -> void:
	_catalog.randomize()


# 运行时 facade 负责从 provider 收集原始条目，再交给 domain service 建池。
func reload_pools(unit_factory: Node, unit_augment_manager: Node) -> void:
	_sync_offer_counts()
	_catalog.reload_pools(
		_collect_unit_records(unit_factory),
		_collect_gongfa_rows(unit_augment_manager),
		_collect_equipment_rows(unit_augment_manager)
	)


# 对外只返回 domain service 持有的商店快照副本。
func get_shop_snapshot() -> Dictionary:
	return _catalog.get_shop_snapshot()


# 页签商品列表查询继续直接透传给 domain service。
func get_offers(tab: String) -> Array[Dictionary]:
	return _catalog.get_offers(tab)


# 单格商品读取继续委托 domain service 处理边界与副本。
func get_offer(tab: String, index: int) -> Dictionary:
	return _catalog.get_offer(tab, index)


# 刷新入口仍保留在 facade，上层无需感知 domain service 细节。
func refresh_shop(
	level_probabilities: Dictionary,
	is_locked: bool = false,
	force_refresh: bool = false
) -> Dictionary:
	_sync_offer_counts()
	return _catalog.refresh_shop(level_probabilities, is_locked, force_refresh)


# 购买条目继续透传给 domain service，Node 壳层只保留公开 API。
func purchase_offer(tab: String, index: int) -> Dictionary:
	return _catalog.purchase_offer(tab, index)


# 清空货架继续委托 domain service 处理内部状态。
func clear_shop() -> void:
	_catalog.clear_shop()


# 导出数量参数变化时统一同步到 domain service。
func _sync_offer_counts() -> void:
	_catalog.set_offer_counts(recruit_offer_count, gongfa_offer_count, equipment_offer_count)


# 统一桥接 domain service 的刷新和购买信号。
func _connect_service_signals() -> void:
	var refreshed_cb: Callable = Callable(self, "_on_catalog_shop_refreshed")
	if not _catalog.is_connected("shop_refreshed", refreshed_cb):
		_catalog.connect("shop_refreshed", refreshed_cb)
	var purchased_cb: Callable = Callable(self, "_on_catalog_offer_purchased")
	if not _catalog.is_connected("offer_purchased", purchased_cb):
		_catalog.connect("offer_purchased", purchased_cb)


# 转发整店刷新信号，保持现有 HUD 监听契约不变。
func _on_catalog_shop_refreshed(snapshot: Dictionary) -> void:
	shop_refreshed.emit(snapshot.duplicate(true))


# 转发购买信号，保持外层奖励与日志逻辑不变。
func _on_catalog_offer_purchased(tab: String, index: int, offer: Dictionary) -> void:
	offer_purchased.emit(tab, index, offer.duplicate(true))


# 收集角色池时只依赖 UnitFactory 的显式公开接口。
func _collect_unit_records(unit_factory: Node) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	if unit_factory == null:
		return records
	var unit_ids: Variant = unit_factory.get_unit_ids()
	if not (unit_ids is Array):
		return records
	for id_value in unit_ids:
		var unit_id: String = str(id_value).strip_edges()
		if unit_id.is_empty():
			continue
		var record_value: Variant = unit_factory.get_unit_record(unit_id)
		if record_value is Dictionary:
			records.append((record_value as Dictionary).duplicate(true))
	return records


# 收集功法池时只读取 UnitAugmentManager 的公开列表接口。
func _collect_gongfa_rows(unit_augment_manager: Node) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if unit_augment_manager == null:
		return rows
	var raw_data: Variant = unit_augment_manager.get_all_gongfa()
	if not (raw_data is Array):
		return rows
	for item in raw_data:
		if item is Dictionary:
			rows.append((item as Dictionary).duplicate(true))
	return rows


# 收集装备池时同样只依赖公开列表接口，不下钻运行时私有状态。
func _collect_equipment_rows(unit_augment_manager: Node) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if unit_augment_manager == null:
		return rows
	var raw_data: Variant = unit_augment_manager.get_all_equipment()
	if not (raw_data is Array):
		return rows
	for item in raw_data:
		if item is Dictionary:
			rows.append((item as Dictionary).duplicate(true))
	return rows
