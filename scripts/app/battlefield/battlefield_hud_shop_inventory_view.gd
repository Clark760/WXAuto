extends RefCounted

const STAGE_PREPARATION: int = 0

const SHOP_TAB_RECRUIT: String = "recruit"
const SHOP_TAB_GONGFA: String = "gongfa"
const SHOP_TAB_EQUIPMENT: String = "equipment"
const SHOP_CARD_COUNT: int = 5

const SHOP_OFFER_CARD_SCENE_ID: String = "shop_offer_card"
const INVENTORY_CARD_SCENE_ID: String = "inventory_item_card"
const INVENTORY_FILTER_BUTTON_SCENE_ID: String = "inventory_filter_button"

const SHOP_OFFER_CARD_SCENE_FALLBACK: PackedScene = preload("res://scenes/ui/shop_offer_card.tscn")
const INVENTORY_CARD_SCENE_FALLBACK: PackedScene = preload("res://scenes/ui/inventory_item_card.tscn")
const INVENTORY_FILTER_BUTTON_SCENE_FALLBACK: PackedScene = preload("res://scenes/ui/inventory_filter_button.tscn")

const PROBE_SCOPE_SHOP_UI_UPDATE: String = "battlefield_shop_ui_update"
const PROBE_SCOPE_SHOP_CARDS_REBUILD: String = "battlefield_shop_cards_rebuild"
const PROBE_SCOPE_INVENTORY_FILTERS_REBUILD: String = "battlefield_inventory_filters_rebuild"
const PROBE_SCOPE_INVENTORY_ITEMS_REBUILD: String = "battlefield_inventory_items_rebuild"
const PROBE_SCOPE_INVENTORY_RECORDS_BUILD: String = "battlefield_inventory_records_build"

const CARD_META_TOOLTIP_PAYLOAD: String = "tooltip_payload"
const CARD_META_FILTER_ID: String = "filter_id"

const GONGFA_FILTERS: Array[Dictionary] = [
	{"id": "all", "name": "全部"},
	{"id": "neigong", "name": "内功"},
	{"id": "waigong", "name": "外功"},
	{"id": "qinggong", "name": "身法"},
	{"id": "zhenfa", "name": "阵法"}
]

const EQUIPMENT_FILTERS: Array[Dictionary] = [
	{"id": "all", "name": "全部"},
	{"id": "weapon", "name": "武器"},
	{"id": "armor", "name": "护甲"},
	{"id": "accessory", "name": "饰品"}
]

var _owner = null
var _scene_root = null
var _refs = null
var _state = null
var _support = null
var _detail_view = null

var _shop_cards: Array[PanelContainer] = []
var _inventory_filter_buttons: Array[Button] = []
var _inventory_cards: Array[PanelContainer] = []


func initialize(owner, scene_root, refs, state, support) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state
	_support = support


func shutdown() -> void:
	_shop_cards.clear()
	_inventory_filter_buttons.clear()
	_inventory_cards.clear()
	_owner = null
	_scene_root = null
	_refs = null
	_state = null
	_support = null
	_detail_view = null


func bind_detail_view(detail_view) -> void:
	_detail_view = detail_view


func update_shop_ui() -> void:
	var begin_us: int = _probe_begin_timing()
	update_shop_operation_labels()
	rebuild_shop_cards()
	_probe_commit_timing(PROBE_SCOPE_SHOP_UI_UPDATE, begin_us)


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
		_refs.shop_lock_button.text = "🔁 解锁" if locked else "🔀 锁定当前"
		_refs.shop_lock_button.disabled = not stage_editable
	if _refs.shop_status_label == null:
		return
	if int(_state.stage) != STAGE_PREPARATION:
		_refs.shop_status_label.text = "交锋期 / 结算期关闭商店"
	elif locked:
		_refs.shop_status_label.text = "商店已锁定，下回合保留当前商品"
	else:
		_refs.shop_status_label.text = "布阵期可购买"


func rebuild_shop_cards() -> void:
	var begin_us: int = _probe_begin_timing()
	var shop_manager = _get_runtime_shop_manager()
	if _refs.shop_offer_row == null or shop_manager == null:
		_hide_extra_shop_cards(0)
		_probe_commit_timing(PROBE_SCOPE_SHOP_CARDS_REBUILD, begin_us)
		return
	_ensure_shop_cards(SHOP_CARD_COUNT)
	var offers: Array[Dictionary] = shop_manager.get_offers(_state.shop_current_tab)
	for index in range(SHOP_CARD_COUNT):
		var offer: Dictionary = offers[index] if index < offers.size() else {}
		_refresh_shop_offer_card(_shop_cards[index], offer, index, _state.shop_current_tab)
	_hide_extra_shop_cards(SHOP_CARD_COUNT)
	_probe_commit_timing(PROBE_SCOPE_SHOP_CARDS_REBUILD, begin_us)


func create_shop_offer_card(offer: Dictionary, index: int, tab_id: String) -> PanelContainer:
	var card: PanelContainer = _instantiate_ui_panel(
		SHOP_OFFER_CARD_SCENE_ID,
		SHOP_OFFER_CARD_SCENE_FALLBACK
	)
	if card == null:
		var fallback_card_node: Node = SHOP_OFFER_CARD_SCENE_FALLBACK.instantiate()
		if fallback_card_node is PanelContainer:
			card = fallback_card_node as PanelContainer
		else:
			return PanelContainer.new()
	_bind_shop_offer_card(card)
	_refresh_shop_offer_card(card, offer, index, tab_id)
	return card


func rebuild_inventory_filters() -> void:
	var begin_us: int = _probe_begin_timing()
	if _refs.inventory_filter_row == null:
		_probe_commit_timing(PROBE_SCOPE_INVENTORY_FILTERS_REBUILD, begin_us)
		return
	var filters: Array[Dictionary] = _get_inventory_filters()
	_ensure_inventory_filter_buttons(filters.size())
	for index in range(_inventory_filter_buttons.size()):
		var button: Button = _inventory_filter_buttons[index]
		if index < filters.size():
			_refresh_inventory_filter_button(button, filters[index])
			button.visible = true
		else:
			button.visible = false
	if _refs.inventory_title != null:
		if _state.inventory_mode == "gongfa":
			_refs.inventory_title.text = "功法装备区丨功法"
		else:
			_refs.inventory_title.text = "功法装备区丨装备"
	_probe_commit_timing(PROBE_SCOPE_INVENTORY_FILTERS_REBUILD, begin_us)


func rebuild_inventory_items() -> void:
	var begin_us: int = _probe_begin_timing()
	if _refs.inventory_grid == null or _get_unit_augment_manager() == null:
		_hide_extra_inventory_cards(0)
		_probe_commit_timing(PROBE_SCOPE_INVENTORY_ITEMS_REBUILD, begin_us)
		return
	var stock_map: Dictionary = (
		_state.owned_gongfa_stock
		if _state.inventory_mode == "gongfa"
		else _state.owned_equipment_stock
	)
	var id_set: Dictionary = _collect_inventory_item_ids(stock_map)
	var record_begin_us: int = _probe_begin_timing()
	var items: Array[Dictionary] = _build_inventory_records(id_set, stock_map)
	_probe_commit_timing(PROBE_SCOPE_INVENTORY_RECORDS_BUILD, record_begin_us)
	items.sort_custom(Callable(self, "sort_inventory_item"))
	var search_text: String = ""
	if _refs.inventory_search != null:
		search_text = _refs.inventory_search.text.strip_edges().to_lower()
	var filtered: Array[Dictionary] = _filter_inventory_records(items, search_text)
	_ensure_inventory_cards(filtered.size())
	var total_owned: int = 0
	for index in range(filtered.size()):
		var item_data: Dictionary = filtered[index]
		total_owned += int(item_data.get("_owned_count", 0))
		_refresh_inventory_card(_inventory_cards[index], item_data)
		_inventory_cards[index].visible = true
	_hide_extra_inventory_cards(filtered.size())
	if _refs.inventory_summary != null:
		_refs.inventory_summary.text = "库存 %d 件 | 条目 %d" % [
			total_owned,
			filtered.size()
		]
	_probe_commit_timing(PROBE_SCOPE_INVENTORY_ITEMS_REBUILD, begin_us)


func _collect_inventory_item_ids(stock_map: Dictionary) -> Dictionary:
	var id_set: Dictionary = {}
	for key in stock_map.keys():
		var item_id: String = str(key).strip_edges()
		if item_id.is_empty():
			continue
		if int(stock_map.get(item_id, 0)) > 0:
			id_set[item_id] = true
	return id_set


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
		items.append(packed)
	return items


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


func create_inventory_card(item_data: Dictionary) -> PanelContainer:
	var card: PanelContainer = _instantiate_ui_panel(
		INVENTORY_CARD_SCENE_ID,
		INVENTORY_CARD_SCENE_FALLBACK
	)
	if card == null:
		var fallback_card_node: Node = INVENTORY_CARD_SCENE_FALLBACK.instantiate()
		if fallback_card_node is PanelContainer:
			card = fallback_card_node as PanelContainer
		else:
			card = PanelContainer.new()
	_bind_inventory_card(card)
	_refresh_inventory_card(card, item_data)
	return card


func _resolve_ui_scene(scene_id: String, fallback_scene: PackedScene) -> PackedScene:
	if _refs != null and _refs.has_method("get_ui_scene"):
		var scene_value: Variant = _refs.get_ui_scene(scene_id)
		if scene_value is PackedScene:
			return scene_value as PackedScene
	return fallback_scene


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


func sort_inventory_item(a: Dictionary, b: Dictionary) -> bool:
	var rank_a: int = quality_rank(str(a.get("quality", "white")))
	var rank_b: int = quality_rank(str(b.get("quality", "white")))
	if rank_a != rank_b:
		return rank_a > rank_b
	return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0


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


func on_inventory_tab_gongfa_pressed() -> void:
	on_inventory_tab_pressed("gongfa")


func on_inventory_tab_equip_pressed() -> void:
	on_inventory_tab_pressed("equipment")


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


func on_inventory_filter_pressed(filter_id: String) -> void:
	_state.inventory_filter_type = filter_id
	rebuild_inventory_filters()
	rebuild_inventory_items()


func on_inventory_search_changed(_new_text: String) -> void:
	rebuild_inventory_items()


func on_inventory_card_clicked(item_id: String, _item_data: Dictionary) -> void:
	if _detail_view == null:
		return
	var equipped_info: Dictionary = _support.find_equipped_info(item_id, _state.inventory_mode)
	if equipped_info.is_empty():
		return
	var unit: Node = equipped_info.get("unit", null)
	if _support.is_valid_unit(unit):
		_detail_view.open_detail_panel(unit)


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


func on_shop_open_button_pressed() -> void:
	if int(_state.stage) != STAGE_PREPARATION:
		return
	_owner.toggle_shop_panel()


func on_shop_close_pressed() -> void:
	_owner.set_shop_panel_visible(false, true)


func on_shop_tab_pressed(tab_id: String) -> void:
	_state.shop_current_tab = tab_id
	if _refs.shop_tab_recruit_button != null:
		_refs.shop_tab_recruit_button.button_pressed = tab_id == SHOP_TAB_RECRUIT
	if _refs.shop_tab_gongfa_button != null:
		_refs.shop_tab_gongfa_button.button_pressed = tab_id == SHOP_TAB_GONGFA
	if _refs.shop_tab_equipment_button != null:
		_refs.shop_tab_equipment_button.button_pressed = tab_id == SHOP_TAB_EQUIPMENT
	rebuild_shop_cards()


func on_shop_refresh_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.refresh_shop_from_button()


func on_shop_upgrade_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.buy_shop_upgrade()


func on_shop_lock_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.toggle_shop_lock()


func on_shop_test_add_silver_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.add_test_silver()


func on_shop_test_add_exp_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.add_test_exp()


func on_shop_buy_pressed(tab_id: String, index: int) -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.purchase_shop_offer(tab_id, index)


func _ensure_shop_cards(required_count: int) -> void:
	if _refs.shop_offer_row == null:
		return
	while _shop_cards.size() < required_count:
		var card: PanelContainer = create_shop_offer_card({}, _shop_cards.size(), _state.shop_current_tab)
		_refs.shop_offer_row.add_child(card)
		_shop_cards.append(card)


func _hide_extra_shop_cards(visible_count: int) -> void:
	for index in range(visible_count, _shop_cards.size()):
		var card: PanelContainer = _shop_cards[index]
		card.visible = false
		card.set_meta(CARD_META_TOOLTIP_PAYLOAD, {})


func _bind_shop_offer_card(card: PanelContainer) -> void:
	if card is ShopOfferCardView:
		var shop_card: ShopOfferCardView = card as ShopOfferCardView
		var buy_cb: Callable = Callable(self, "on_shop_buy_pressed")
		if not shop_card.is_connected("buy_requested", buy_cb):
			shop_card.connect("buy_requested", buy_cb)
	var enter_cb: Callable = Callable(self, "_on_card_mouse_entered").bind(card)
	if not card.is_connected("mouse_entered", enter_cb):
		card.connect("mouse_entered", enter_cb)
	var exit_cb: Callable = Callable(self, "_on_card_mouse_exited").bind(card)
	if not card.is_connected("mouse_exited", exit_cb):
		card.connect("mouse_exited", exit_cb)


func _refresh_shop_offer_card(
	card: PanelContainer,
	offer: Dictionary,
	index: int,
	tab_id: String
) -> void:
	card.visible = true
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
	var tooltip_payload: Dictionary = {}
	var economy_manager = _get_runtime_economy_manager()
	if economy_manager != null:
		can_afford = int(economy_manager.get_silver()) >= price
	if not is_empty_offer:
		if tab_id == SHOP_TAB_RECRUIT:
			type_text = "[%s] 侠客" % _support.quality_to_cn(quality)
		else:
			var slot_label: String = _support.slot_or_equip_cn(tab_id, str(offer.get("slot_type", "")))
			type_text = "[%s] %s" % [_support.quality_to_cn(quality), slot_label]
			if not item_id.is_empty():
				if tab_id == SHOP_TAB_GONGFA:
					tooltip_payload = _support.build_gongfa_item_tooltip_data(item_id)
				elif tab_id == SHOP_TAB_EQUIPMENT:
					tooltip_payload = _support.build_equip_item_tooltip_data(item_id)
				var brief_text: String = _support.build_payload_brief_text(tooltip_payload)
				if not brief_text.is_empty():
					type_text += "\n%s" % brief_text
		price_text = "💰 %d" % price if price > 0 else ""
		buy_text = "已售罄" if sold else "点击购买"
		buy_disabled = sold or int(_state.stage) != STAGE_PREPARATION or not can_afford
	if card is ShopOfferCardView:
		var shop_card: ShopOfferCardView = card as ShopOfferCardView
		shop_card.refresh(
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
	if sold or _detail_view == null:
		tooltip_payload = {}
	card.set_meta(CARD_META_TOOLTIP_PAYLOAD, tooltip_payload)


func _get_inventory_filters() -> Array[Dictionary]:
	return GONGFA_FILTERS if _state.inventory_mode == "gongfa" else EQUIPMENT_FILTERS


func _ensure_inventory_filter_buttons(required_count: int) -> void:
	if _refs.inventory_filter_row == null:
		return
	while _inventory_filter_buttons.size() < required_count:
		var button: Button = _instantiate_ui_button(
			INVENTORY_FILTER_BUTTON_SCENE_ID,
			INVENTORY_FILTER_BUTTON_SCENE_FALLBACK
		)
		if button == null:
			break
		_bind_inventory_filter_button(button)
		_refs.inventory_filter_row.add_child(button)
		_inventory_filter_buttons.append(button)


func _bind_inventory_filter_button(button: Button) -> void:
	if button is InventoryFilterButtonView:
		var filter_button: InventoryFilterButtonView = button as InventoryFilterButtonView
		var filter_cb: Callable = Callable(self, "on_inventory_filter_pressed")
		if not filter_button.is_connected("filter_selected", filter_cb):
			filter_button.connect("filter_selected", filter_cb)
		return
	var plain_cb: Callable = Callable(self, "_on_plain_inventory_filter_button_pressed").bind(button)
	if not button.is_connected("pressed", plain_cb):
		button.connect("pressed", plain_cb)


func _refresh_inventory_filter_button(button: Button, filter_data: Dictionary) -> void:
	var filter_id: String = str(filter_data.get("id", "all"))
	button.set_meta(CARD_META_FILTER_ID, filter_id)
	if button is InventoryFilterButtonView:
		var filter_button: InventoryFilterButtonView = button as InventoryFilterButtonView
		filter_button.refresh(
			{
				"id": filter_id,
				"name": str(filter_data.get("name", filter_id)),
				"selected": filter_id == _state.inventory_filter_type
			}
		)
		return
	button.text = str(filter_data.get("name", filter_id))
	button.toggle_mode = true
	button.button_pressed = filter_id == _state.inventory_filter_type


func _on_plain_inventory_filter_button_pressed(button: Button) -> void:
	on_inventory_filter_pressed(str(button.get_meta(CARD_META_FILTER_ID, "all")))


func _ensure_inventory_cards(required_count: int) -> void:
	if _refs.inventory_grid == null:
		return
	while _inventory_cards.size() < required_count:
		var card: PanelContainer = create_inventory_card({})
		_refs.inventory_grid.add_child(card)
		_inventory_cards.append(card)


func _hide_extra_inventory_cards(visible_count: int) -> void:
	for index in range(visible_count, _inventory_cards.size()):
		var card: PanelContainer = _inventory_cards[index]
		card.visible = false
		card.modulate = Color(1, 1, 1, 1)
		card.set_meta(CARD_META_TOOLTIP_PAYLOAD, {})


func _bind_inventory_card(card: PanelContainer) -> void:
	if card is BattleInventoryItemCard:
		var drag_card: BattleInventoryItemCard = card as BattleInventoryItemCard
		var click_cb: Callable = Callable(self, "on_inventory_card_clicked")
		if not drag_card.is_connected("card_clicked", click_cb):
			drag_card.connect("card_clicked", click_cb)
	var enter_cb: Callable = Callable(self, "_on_card_mouse_entered").bind(card)
	if not card.is_connected("mouse_entered", enter_cb):
		card.connect("mouse_entered", enter_cb)
	var exit_cb: Callable = Callable(self, "_on_card_mouse_exited").bind(card)
	if not card.is_connected("mouse_exited", exit_cb):
		card.connect("mouse_exited", exit_cb)


func _refresh_inventory_card(card: PanelContainer, item_data: Dictionary) -> void:
	card.visible = true
	var item_type: String = str(item_data.get("type", ""))
	var icon_text: String = ""
	if _state.inventory_mode == "gongfa":
		icon_text = _support.slot_icon(item_type)
	else:
		icon_text = _support.equip_icon(item_type)
	var type_text: String = ""
	if _state.inventory_mode == "gongfa":
		type_text = "[%s] %s 路 %s" % [
			_support.quality_to_cn(str(item_data.get("quality", "white"))),
			_support.slot_to_cn(item_type),
			_support.element_to_cn(str(item_data.get("element", "none")))
		]
	else:
		type_text = "[%s] %s 路 %s" % [
			_support.quality_to_cn(str(item_data.get("quality", "white"))),
			_support.equip_type_to_cn(item_type),
			_support.element_to_cn(str(item_data.get("element", "none")))
		]
	var item_id: String = str(item_data.get("id", "")).strip_edges()
	var owned_count: int = int(item_data.get("_owned_count", 0))
	var status_text: String = "库存 x%d" % owned_count
	if owned_count <= 0:
		status_text = "无库存"
	var tooltip_payload: Dictionary = {}
	if _state.inventory_mode == "gongfa":
		tooltip_payload = _support.build_gongfa_item_tooltip_data(item_id)
	else:
		tooltip_payload = _support.build_equip_item_tooltip_data(item_id)
	var brief_text: String = _support.build_payload_brief_text(tooltip_payload)
	if not brief_text.is_empty():
		type_text += "\n%s" % brief_text
	if card is InventoryItemCardView:
		var inventory_card: InventoryItemCardView = card as InventoryItemCardView
		inventory_card.refresh(
			{
				"quality_color": _support.quality_color(str(item_data.get("quality", "white"))),
				"icon": icon_text,
				"name": str(item_data.get("name", str(item_data.get("id", "未知")))),
				"type_text": type_text,
				"status_text": status_text
			}
		)
	card.set_meta(CARD_META_TOOLTIP_PAYLOAD, tooltip_payload)
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
	card.modulate = Color(1, 1, 1, 1) if can_drag else Color(0.75, 0.75, 0.75, 0.92)


func _on_card_mouse_entered(card: Control) -> void:
	if _detail_view == null or card == null or not is_instance_valid(card) or not card.visible:
		return
	var payload_value: Variant = card.get_meta(CARD_META_TOOLTIP_PAYLOAD, {})
	if not (payload_value is Dictionary):
		return
	var payload: Dictionary = payload_value as Dictionary
	if payload.is_empty():
		return
	_detail_view.on_item_source_hover_entered(card, payload)


func _on_card_mouse_exited(card: Control) -> void:
	if _detail_view == null or card == null or not is_instance_valid(card):
		return
	_detail_view.on_item_source_hover_exited(card)


func _get_runtime_probe():
	if _refs == null or not _refs.has_method("get_runtime_probe"):
		return null
	return _refs.get_runtime_probe()


func _probe_begin_timing() -> int:
	var runtime_probe = _get_runtime_probe()
	if runtime_probe == null or not runtime_probe.has_method("begin_timing"):
		return 0
	return int(runtime_probe.begin_timing())


func _probe_commit_timing(scope_name: String, begin_us: int) -> void:
	var runtime_probe = _get_runtime_probe()
	if runtime_probe == null or not runtime_probe.has_method("commit_timing"):
		return
	runtime_probe.commit_timing(scope_name, begin_us)


func _get_runtime_economy_manager():
	if _refs == null:
		return null
	return _refs.runtime_economy_manager


func _get_runtime_shop_manager():
	if _refs == null:
		return null
	return _refs.runtime_shop_manager


func _get_unit_augment_manager():
	if _refs == null:
		return null
	return _refs.unit_augment_manager
