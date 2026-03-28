extends RefCounted
# 商店与仓库视图只负责数据投影、按钮事件转发、条目悬停提示和拖拽入口装配。
# 商店购买、库存拖拽、筛选搜索、详情跳转都只做界面层转发，不在这里直接改战斗状态。
# 子场景统一优先从引用表场景库解析，本地资源回退只用于资源缺失时兜底，不作为常态路径。

const STAGE_PREPARATION: int = 0 # 只有备战期允许商店与仓库交互。

const SHOP_TAB_RECRUIT: String = "recruit" # 招募页签 id。
const SHOP_TAB_GONGFA: String = "gongfa" # 功法页签 id。
const SHOP_TAB_EQUIPMENT: String = "equipment" # 装备页签 id。

const SHOP_OFFER_CARD_SCENE_ID: String = "shop_offer_card" # 商店卡片子场景 id。
const INVENTORY_CARD_SCENE_ID: String = "inventory_item_card" # 仓库卡片子场景 id。
const INVENTORY_FILTER_BUTTON_SCENE_ID: String = "inventory_filter_button" # 仓库筛选按钮子场景 id。

const SHOP_OFFER_CARD_SCENE_FALLBACK: PackedScene = preload("res://scenes/ui/shop_offer_card.tscn") # 商店卡片回退资源。
const INVENTORY_CARD_SCENE_FALLBACK: PackedScene = preload("res://scenes/ui/inventory_item_card.tscn") # 仓库卡片回退资源。
const INVENTORY_FILTER_BUTTON_SCENE_FALLBACK: PackedScene = preload("res://scenes/ui/inventory_filter_button.tscn")

var _owner = null # HUD facade。
var _scene_root = null # 根场景入口。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。
var _support = null # HUD 共享支撑。
var _detail_view = null # 详情协作者，用于 hover 和点击跳转。


# 绑定 shop/inventory 协作者需要的 facade、状态和共享 support。
func initialize(owner, scene_root, refs, state, support) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state
	_support = support


# 关闭商店仓库协作者时只清理本地引用，不触碰外部状态。
func shutdown() -> void:
	_owner = null
	_scene_root = null
	_refs = null
	_state = null
	_support = null
	_detail_view = null


# 让 shop/inventory 可以把 hover 和详情跳转交给 detail view。
func bind_detail_view(detail_view) -> void:
	_detail_view = detail_view


# 同步商店操作区文案和商品卡片列表。
func update_shop_ui() -> void:
	update_shop_operation_labels()
	rebuild_shop_cards()


# 刷新商店银两、等级和锁店按钮状态。
func update_shop_operation_labels() -> void:
	var economy_manager = _get_runtime_economy_manager()
	if economy_manager == null:
		return
	var assets: Dictionary = economy_manager.get_assets_snapshot()
	var silver: int = int(assets.get("silver", 0))
	var level: int = int(assets.get("level", 1))
	var exp_value: int = int(assets.get("exp", 0))
	var max_exp: int = int(assets.get("max_exp", 0))
	var locked: bool = bool(assets.get("locked_shop", false))
	var stage_editable: bool = int(_state.stage) == STAGE_PREPARATION
	if _refs.shop_silver_label != null:
		_refs.shop_silver_label.text = "当前银两: %d" % silver
	if _refs.shop_level_label != null:
		_refs.shop_level_label.text = "门派LV%d (%d/%d) 上场上限:%d" % [
			level,
			exp_value,
			max_exp,
			int(economy_manager.get_max_deploy_limit())
		]
	if _refs.shop_refresh_button != null:
		_refs.shop_refresh_button.text = "刷新(💰%d)" % int(economy_manager.get_refresh_cost())
		_refs.shop_refresh_button.disabled = not stage_editable
	if _refs.shop_upgrade_button != null:
		_refs.shop_upgrade_button.text = "升级(💰%d)" % int(economy_manager.get_upgrade_cost())
		_refs.shop_upgrade_button.disabled = not stage_editable or max_exp <= 0
	if _refs.shop_lock_button != null:
		_refs.shop_lock_button.text = "🔓 解锁" if locked else "🔒 锁定当前"
		_refs.shop_lock_button.disabled = not stage_editable
	if _refs.shop_status_label == null:
		return
	if int(_state.stage) != STAGE_PREPARATION:
		_refs.shop_status_label.text = "交锋期/结算期关闭商店"
	elif locked:
		_refs.shop_status_label.text = "商店已锁定，下回合保留商品"
	else:
		_refs.shop_status_label.text = "布阵期可购买"


# 商店五格重建：每次都先清空旧子节点，再按页签快照回填。
func rebuild_shop_cards() -> void:
	var shop_manager = _get_runtime_shop_manager()
	if _refs.shop_offer_row == null or shop_manager == null:
		return
	for child in _refs.shop_offer_row.get_children():
		child.queue_free()
	var offers: Array[Dictionary] = shop_manager.get_offers(_state.shop_current_tab)
	for index in range(5):
		var offer: Dictionary = offers[index] if index < offers.size() else {}
		_refs.shop_offer_row.add_child(create_shop_offer_card(offer, index, _state.shop_current_tab))


# 把单个商店条目投影成可点击卡片，并挂上 hover tooltip。
func create_shop_offer_card(offer: Dictionary, index: int, tab_id: String) -> PanelContainer:
	var card: PanelContainer = _instantiate_ui_panel(SHOP_OFFER_CARD_SCENE_ID, SHOP_OFFER_CARD_SCENE_FALLBACK)
	if card == null:
		var fallback_card_node: Node = SHOP_OFFER_CARD_SCENE_FALLBACK.instantiate()
		if fallback_card_node is PanelContainer:
			card = fallback_card_node as PanelContainer
		else:
			return PanelContainer.new()
	var is_empty_offer: bool = offer.is_empty()
	var quality: String = str(offer.get("quality", "white"))
	var type_text: String = "暂无商品"
	var price_text: String = ""
	var buy_text: String = "—"
	var buy_disabled: bool = true
	var item_id: String = str(offer.get("item_id", "")).strip_edges()
	var price: int = int(offer.get("price", 0))
	var sold: bool = bool(offer.get("sold", false))
	var can_afford: bool = false
	var economy_manager = _get_runtime_economy_manager()
	if economy_manager != null:
		can_afford = int(economy_manager.get_silver()) >= price
	if not is_empty_offer:
		if tab_id == SHOP_TAB_RECRUIT:
			type_text = "[%s] 侠客" % _support.quality_to_cn(quality)
		else:
			var slot_label: String = _support.slot_or_equip_cn(tab_id, str(offer.get("slot_type", "")))
			type_text = "[%s] %s" % [_support.quality_to_cn(quality), slot_label]
		price_text = "💰 %d" % price if price > 0 else ""
		buy_text = "已售罄" if sold else "购买"
		buy_disabled = sold or int(_state.stage) != STAGE_PREPARATION or not can_afford
	if card is ShopOfferCardView:
		var shop_card: ShopOfferCardView = card as ShopOfferCardView
		shop_card.setup(
			{
				"is_empty": is_empty_offer,
				"name": str(offer.get("name", "未知")),
				"quality_color": _support.quality_color(quality),
				"type_text": type_text,
				"price_text": price_text,
				"buy_text": buy_text,
				"buy_disabled": buy_disabled,
				"tab_id": tab_id,
				"index": index
			}
		)
		var buy_cb: Callable = Callable(self, "on_shop_buy_pressed")
		if not shop_card.is_connected("buy_requested", buy_cb):
			shop_card.connect("buy_requested", buy_cb)
	if sold or item_id.is_empty() or tab_id == SHOP_TAB_RECRUIT or _detail_view == null:
		return card
	var tooltip_payload: Dictionary = {}
	if tab_id == SHOP_TAB_GONGFA:
		tooltip_payload = _support.build_gongfa_item_tooltip_data(item_id)
	else:
		tooltip_payload = _support.build_equip_item_tooltip_data(item_id)
	card.mouse_entered.connect(Callable(_detail_view, "on_item_source_hover_entered").bind(card, tooltip_payload))
	card.mouse_exited.connect(Callable(_detail_view, "on_item_source_hover_exited").bind(card))
	return card


# 根据当前 inventory 模式重建过滤按钮。
func rebuild_inventory_filters() -> void:
	if _refs.inventory_filter_row == null:
		return
	for child in _refs.inventory_filter_row.get_children():
		child.queue_free()
	var filters: Array[Dictionary] = []
	if _state.inventory_mode == "gongfa":
		filters = [
			{"id": "all", "name": "全部"},
			{"id": "neigong", "name": "内功"},
			{"id": "waigong", "name": "外功"},
			{"id": "qinggong", "name": "身法"},
			{"id": "zhenfa", "name": "阵法"}
		]
	else:
		filters = [
			{"id": "all", "name": "全部"},
			{"id": "weapon", "name": "兵器"},
			{"id": "armor", "name": "护甲"},
			{"id": "accessory", "name": "饰品"}
		]
	for filter_data in filters:
		var filter_id: String = str(filter_data.get("id", "all"))
		var button: Button = _instantiate_ui_button(INVENTORY_FILTER_BUTTON_SCENE_ID, INVENTORY_FILTER_BUTTON_SCENE_FALLBACK)
		if button == null:
			continue
		if button is InventoryFilterButtonView:
			var filter_button: InventoryFilterButtonView = button as InventoryFilterButtonView
			filter_button.setup(
				{
					"id": filter_id,
					"name": str(filter_data.get("name", filter_id)),
					"selected": filter_id == _state.inventory_filter_type
				}
			)
			var filter_cb: Callable = Callable(self, "on_inventory_filter_pressed")
			if not filter_button.is_connected("filter_selected", filter_cb):
				filter_button.connect("filter_selected", filter_cb)
		else:
			button.text = str(filter_data.get("name", filter_id))
			button.toggle_mode = true
			button.button_pressed = filter_id == _state.inventory_filter_type
			button.pressed.connect(Callable(self, "on_inventory_filter_pressed").bind(filter_id))
		_refs.inventory_filter_row.add_child(button)
	if _refs.inventory_title != null:
		if _state.inventory_mode == "gongfa":
			_refs.inventory_title.text = "功法装备区·功法"
		else:
			_refs.inventory_title.text = "功法装备区·装备"


# 根据库存与已装备状态重建 inventory 条目列表。
func rebuild_inventory_items() -> void:
	if _refs.inventory_grid == null or _get_unit_augment_manager() == null:
		return
	for child in _refs.inventory_grid.get_children():
		child.queue_free()
	var stock_map: Dictionary = (
		_state.owned_gongfa_stock
		if _state.inventory_mode == "gongfa"
		else _state.owned_equipment_stock
	)
	var id_set: Dictionary = _collect_inventory_item_ids(stock_map)
	var items: Array[Dictionary] = _build_inventory_records(id_set, stock_map)
	items.sort_custom(Callable(self, "sort_inventory_item"))
	var search_text: String = ""
	if _refs.inventory_search != null:
		search_text = _refs.inventory_search.text.strip_edges().to_lower()
	var filtered: Array[Dictionary] = _filter_inventory_records(items, search_text)
	var total_owned: int = 0
	var total_equipped: int = 0
	for item_data in filtered:
		total_owned += int(item_data.get("_owned_count", 0))
		total_equipped += int(item_data.get("_equipped_count", 0))
		_refs.inventory_grid.add_child(create_inventory_card(item_data))
	if _refs.inventory_summary != null:
		_refs.inventory_summary.text = "库存 %d 件 | 已装备 %d 件 | 条目 %d" % [
			total_owned,
			total_equipped,
			filtered.size()
		]

# 汇总库存与已装备条目的 id 集合，供 inventory 后续统一查表。
func _collect_inventory_item_ids(stock_map: Dictionary) -> Dictionary:
	var id_set: Dictionary = {}
	for key in stock_map.keys():
		var item_id: String = str(key).strip_edges()
		if item_id.is_empty():
			continue
		if int(stock_map.get(item_id, 0)) > 0:
			id_set[item_id] = true
	for unit in _support.collect_player_units():
		if not _support.is_valid_unit(unit):
			continue
		if _state.inventory_mode == "gongfa":
			var slots: Dictionary = _support.normalize_unit_slots(unit.get("gongfa_slots"))
			for slot in _support.SLOT_ORDER:
				var gongfa_id: String = str(slots.get(slot, "")).strip_edges()
				if not gongfa_id.is_empty():
					id_set[gongfa_id] = true
			continue
		var equip_slots: Dictionary = _support.normalize_equip_slots(
			_support.get_unit_equip_slots(unit)
		)
		var equip_order: Array[String] = _support.get_sorted_equip_slot_keys(
			equip_slots,
			_support.get_unit_max_equip_count(unit, equip_slots)
		)
		for equip_slot in equip_order:
			var equip_id: String = str(equip_slots.get(equip_slot, "")).strip_edges()
			if not equip_id.is_empty():
				id_set[equip_id] = true
	return id_set

# 根据条目 id 集合回查配置并补齐库存/装备数量。
func _build_inventory_records(id_set: Dictionary, stock_map: Dictionary) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager == null:
		return items
	for key in id_set.keys():
		var lookup_id: String = str(key).strip_edges()
		if lookup_id.is_empty():
			continue
		var item_data: Dictionary = {}
		if _state.inventory_mode == "gongfa":
			item_data = unit_augment_manager.get_gongfa_data(lookup_id)
		else:
			item_data = unit_augment_manager.get_equipment_data(lookup_id)
		if item_data.is_empty():
			continue
		var packed: Dictionary = item_data.duplicate(true)
		packed["_owned_count"] = int(stock_map.get(lookup_id, 0))
		packed["_equipped_count"] = _support.count_equipped_instances(
			_state.inventory_mode,
			lookup_id
		)
		items.append(packed)
	return items

# 应用 inventory 当前筛选与搜索条件，返回最终要渲染的条目列表。
func _filter_inventory_records(items: Array[Dictionary], search_text: String) -> Array[Dictionary]:
	var filtered: Array[Dictionary] = []
	for item_data in items:
		var item_type: String = str(item_data.get("type", "")).strip_edges()
		if _state.inventory_filter_type != "all" and item_type != _state.inventory_filter_type:
			continue
		var item_name: String = str(item_data.get("name", "")).to_lower()
		if not search_text.is_empty() and not item_name.contains(search_text):
			continue
		filtered.append(item_data)
	return filtered

# 把单个 inventory 条目投影成可拖拽卡片并挂上 hover tooltip。
func create_inventory_card(item_data: Dictionary) -> PanelContainer:
	var card: PanelContainer = _instantiate_ui_panel(INVENTORY_CARD_SCENE_ID, INVENTORY_CARD_SCENE_FALLBACK)
	if card == null:
		var fallback_card_node: Node = INVENTORY_CARD_SCENE_FALLBACK.instantiate()
		if fallback_card_node is PanelContainer:
			card = fallback_card_node as PanelContainer
		else:
			card = PanelContainer.new()
	var item_type: String = str(item_data.get("type", ""))
	var icon_text: String = ""
	if _state.inventory_mode == "gongfa":
		icon_text = _support.slot_icon(item_type)
	else:
		icon_text = _support.equip_icon(item_type)
	var type_text: String = ""
	if _state.inventory_mode == "gongfa":
		type_text = "[%s] %s · %s" % [
			_support.quality_to_cn(str(item_data.get("quality", "white"))),
			_support.slot_to_cn(item_type),
			_support.element_to_cn(str(item_data.get("element", "none")))
		]
	else:
		type_text = "[%s] %s · %s" % [
			_support.quality_to_cn(str(item_data.get("quality", "white"))),
			_support.equip_type_to_cn(item_type),
			_support.element_to_cn(str(item_data.get("element", "none")))
		]
	var item_id: String = str(item_data.get("id", "")).strip_edges()
	var owned_count: int = int(item_data.get("_owned_count", 0))
	var equipped_count: int = int(item_data.get("_equipped_count", 0))
	var status_text: String = "库存 x%d | 已装备 x%d" % [owned_count, equipped_count]
	if owned_count <= 0 and equipped_count <= 0:
		status_text = "无库存"
	if card is InventoryItemCardView:
		var inventory_card: InventoryItemCardView = card as InventoryItemCardView
		inventory_card.setup(
			{
				"quality_color": _support.quality_color(str(item_data.get("quality", "white"))),
				"icon": icon_text,
				"name": str(item_data.get("name", str(item_data.get("id", "未知")))),
				"type_text": type_text,
				"status_text": status_text
			}
		)
	var tooltip_payload: Dictionary = {}
	if _state.inventory_mode == "gongfa":
		tooltip_payload = _support.build_gongfa_item_tooltip_data(item_id)
	else:
		tooltip_payload = _support.build_equip_item_tooltip_data(item_id)
	var can_drag: bool = owned_count > 0 and _state.inventory_drag_enabled
	var drag_payload: Dictionary = {
		"type": _state.inventory_mode,
		"id": item_id,
		"item_data": item_data.duplicate(true),
		"slot_type": item_type
	}
	if card is BattleInventoryItemCard:
		var drag_card: BattleInventoryItemCard = card as BattleInventoryItemCard
		drag_card.setup_card(item_id, item_data, drag_payload, can_drag)
		var click_cb: Callable = Callable(self, "on_inventory_card_clicked")
		if not drag_card.is_connected("card_clicked", click_cb):
			drag_card.connect("card_clicked", click_cb)
	if not can_drag:
		card.modulate = Color(0.75, 0.75, 0.75, 0.92)
	if _detail_view != null:
		card.mouse_entered.connect(Callable(_detail_view, "on_item_source_hover_entered").bind(card, tooltip_payload))
		card.mouse_exited.connect(Callable(_detail_view, "on_item_source_hover_exited").bind(card))
	return card

# 优先从 refs 的 UI 场景库取资源；缺失时回退到本地 fallback。
func _resolve_ui_scene(scene_id: String, fallback_scene: PackedScene) -> PackedScene:
	if _refs != null and _refs.has_method("get_ui_scene"):
		var scene_value: Variant = _refs.get_ui_scene(scene_id)
		if scene_value is PackedScene:
			return scene_value as PackedScene
	return fallback_scene

# 统一实例化 PanelContainer 子场景，避免每处重复写资源解析逻辑。
func _instantiate_ui_panel(scene_id: String, fallback_scene: PackedScene) -> PanelContainer:
	var scene: PackedScene = _resolve_ui_scene(scene_id, fallback_scene)
	if scene == null:
		return null
	var instance: Node = scene.instantiate()
	if instance is PanelContainer:
		return instance as PanelContainer
	if instance != null:
		instance.queue_free()
	return null

# 按按钮子场景实例化筛选控件，失败时返回 null 让上层兜底。
func _instantiate_ui_button(scene_id: String, fallback_scene: PackedScene) -> Button:
	var scene: PackedScene = _resolve_ui_scene(scene_id, fallback_scene)
	if scene == null:
		return null
	var instance: Node = scene.instantiate()
	if instance is Button:
		return instance as Button
	if instance != null:
		instance.queue_free()
	return null

# 先按品质、再按名称排序 inventory 条目，保证列表稳定。
func sort_inventory_item(a: Dictionary, b: Dictionary) -> bool:
	var rank_a: int = quality_rank(str(a.get("quality", "white")))
	var rank_b: int = quality_rank(str(b.get("quality", "white")))
	if rank_a != rank_b:
		return rank_a > rank_b
	return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0

# 为品质排序提供固定优先级映射。
func quality_rank(quality: String) -> int:
	match quality:
		"orange":
			return 5
		"purple":
			return 4
		"blue":
			return 3
		"green":
			return 2
		_:
			return 1

# 功法 tab 按钮只切到功法模式，再复用统一的 tab 处理。
func on_inventory_tab_gongfa_pressed() -> void:
	on_inventory_tab_pressed("gongfa")

# 装备 tab 按钮只切到装备模式，再复用统一的 tab 处理。
func on_inventory_tab_equip_pressed() -> void:
	on_inventory_tab_pressed("equipment")

# 切换 inventory 模式时重置筛选条件并全量刷新列表。
func on_inventory_tab_pressed(mode: String) -> void:
	_state.inventory_mode = mode
	_state.inventory_filter_type = "all"
	if _refs.inventory_search != null:
		_refs.inventory_search.text = ""
	if _refs.inventory_tab_gongfa_button != null:
		_refs.inventory_tab_gongfa_button.button_pressed = mode == "gongfa"
	if _refs.inventory_tab_equip_button != null:
		_refs.inventory_tab_equip_button.button_pressed = mode == "equipment"
	rebuild_inventory_filters()
	rebuild_inventory_items()

# 切换 inventory 子筛选时只刷新过滤按钮和结果列表。
func on_inventory_filter_pressed(filter_id: String) -> void:
	_state.inventory_filter_type = filter_id
	rebuild_inventory_filters()
	rebuild_inventory_items()

# 搜索框内容变化后，直接按当前条件重建列表。
func on_inventory_search_changed(_new_text: String) -> void:
	rebuild_inventory_items()

# 点击 inventory 条目时，如果该条目已装备，则跳到对应角色详情。
func on_inventory_card_clicked(item_id: String, _item_data: Dictionary) -> void:
	if _detail_view == null:
		return
	var equipped_info: Dictionary = _support.find_equipped_info(item_id, _state.inventory_mode)
	if equipped_info.is_empty():
		return
	var unit: Node = equipped_info.get("unit", null)
	if _support.is_valid_unit(unit):
		_detail_view.open_detail_panel(unit)

# 把 inventory 条目拖放到详情槽位时，统一处理库存扣减与替换回收。
func on_slot_item_dropped(slot_category: String, slot_key: String, item_id: String) -> void:
	if not _support.is_valid_unit(_state.detail_unit):
		return
	if int(_state.stage) != STAGE_PREPARATION:
		return
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager == null:
		return
	var stock_category: String = "gongfa" if slot_category == "gongfa" else "equipment"
	if _state.get_owned_item_count(stock_category, item_id) <= 0:
		if _refs.debug_label != null:
			_refs.debug_label.text = "库存不足：无法装备 %s" % item_id
		return
	var replaced_item_id: String = ""
	var ok: bool = false
	if slot_category == "gongfa":
		var gongfa_slots: Dictionary = _support.normalize_unit_slots(
			_state.detail_unit.get("gongfa_slots")
		)
		replaced_item_id = str(gongfa_slots.get(slot_key, "")).strip_edges()
		if replaced_item_id == item_id:
			return
		ok = bool(unit_augment_manager.equip_gongfa(_state.detail_unit, slot_key, item_id))
	else:
		var equip_slots: Dictionary = _support.normalize_equip_slots(
			_support.get_unit_equip_slots(_state.detail_unit)
		)
		replaced_item_id = str(equip_slots.get(slot_key, "")).strip_edges()
		if replaced_item_id == item_id:
			return
		ok = bool(unit_augment_manager.equip_equipment(_state.detail_unit, slot_key, item_id))
	if not ok:
		if _refs.debug_label != null:
			_refs.debug_label.text = "拖放失败：槽位不匹配或数据无效。"
		return
	_state.consume_owned_item(stock_category, item_id, 1)
	if not replaced_item_id.is_empty():
		_state.add_owned_item(stock_category, replaced_item_id, 1)
	if _detail_view != null:
		_detail_view.update_detail_panel(_state.detail_unit)
	rebuild_inventory_items()

# 从详情槽位卸下条目时，统一回写库存并刷新详情显示。
func on_slot_unequip_pressed(slot_category: String, slot: String) -> void:
	if not _support.is_valid_unit(_state.detail_unit):
		return
	if int(_state.stage) != STAGE_PREPARATION:
		return
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager == null:
		return
	var removed_item_id: String = ""
	if slot_category == "gongfa":
		var gongfa_slots: Dictionary = _support.normalize_unit_slots(
			_state.detail_unit.get("gongfa_slots")
		)
		removed_item_id = str(gongfa_slots.get(slot, "")).strip_edges()
		if removed_item_id.is_empty():
			return
		unit_augment_manager.unequip_gongfa(_state.detail_unit, slot)
		_state.add_owned_item("gongfa", removed_item_id, 1)
	else:
		var equip_slots: Dictionary = _support.normalize_equip_slots(
			_support.get_unit_equip_slots(_state.detail_unit)
		)
		removed_item_id = str(equip_slots.get(slot, "")).strip_edges()
		if removed_item_id.is_empty():
			return
		unit_augment_manager.unequip_equipment(_state.detail_unit, slot)
		_state.add_owned_item("equipment", removed_item_id, 1)
	if _detail_view != null:
		_detail_view.update_detail_panel(_state.detail_unit)
	rebuild_inventory_items()

# 顶栏商店按钮只在准备期切换商店面板显隐。
func on_shop_open_button_pressed() -> void:
	if int(_state.stage) != STAGE_PREPARATION:
		return
	_owner.toggle_shop_panel()

# 商店关闭按钮直接复用 facade 的统一显隐入口。
func on_shop_close_pressed() -> void:
	_owner.set_shop_panel_visible(false, true)

# 商店 tab 变化时只切换当前页签和按钮状态，再重建卡片。
func on_shop_tab_pressed(tab_id: String) -> void:
	_state.shop_current_tab = tab_id
	if _refs.shop_tab_recruit_button != null:
		_refs.shop_tab_recruit_button.button_pressed = tab_id == SHOP_TAB_RECRUIT
	if _refs.shop_tab_gongfa_button != null:
		_refs.shop_tab_gongfa_button.button_pressed = tab_id == SHOP_TAB_GONGFA
	if _refs.shop_tab_equipment_button != null:
		_refs.shop_tab_equipment_button.button_pressed = tab_id == SHOP_TAB_EQUIPMENT
	rebuild_shop_cards()

# 商店刷新按钮只把动作转发给 coordinator。
func on_shop_refresh_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.refresh_shop_from_button()

# 商店升级按钮只把动作转发给 coordinator。
func on_shop_upgrade_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.buy_shop_upgrade()

# 商店锁定按钮只把动作转发给 coordinator。
func on_shop_lock_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.toggle_shop_lock()

# 测试银两按钮只把动作转发给 coordinator。
func on_shop_test_add_silver_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.add_test_silver()

# 测试经验按钮只把动作转发给 coordinator。
func on_shop_test_add_exp_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.add_test_exp()

# 商品卡购买按钮只把条目索引转发给 coordinator。
func on_shop_buy_pressed(tab_id: String, index: int) -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.purchase_shop_offer(tab_id, index)

# 统一读取经济运行时服务，避免多处直接碰 refs 字段。
func _get_runtime_economy_manager():
	if _refs == null:
		return null
	return _refs.runtime_economy_manager

# 统一读取商店运行时服务，保证商店卡刷新走同一入口。
func _get_runtime_shop_manager():
	if _refs == null:
		return null
	return _refs.runtime_shop_manager

# 统一读取 UnitAugmentManager，避免库存与槽位交互各自判空。
func _get_unit_augment_manager():
	if _refs == null:
		return null
	return _refs.unit_augment_manager
