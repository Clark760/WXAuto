extends RefCounted

# HUD 商店与仓库
# 说明：
# 1. 只负责 shop / inventory 的数据投影与交互事件。
# 2. 这里不直接操作世界输入，也不承担战斗编排。
# 面板状态流：
# 1. 商店与仓库都只读写 session state，不新增 root 私有状态。
# 2. coordinator 负责购买、刷新、出售业务，这里只投影和转发事件。
# 3. detail_view 只接 hover 与详情跳转，不反向接管库存结算。
# 渲染口径：
# 1. 商店始终按五格槽位渲染，空位也保留骨架。
# 2. inventory 先汇总 id 集，再回查配置，再做筛选与排序。
# 3. tooltip payload 在这里预构造，避免 detail_view 再猜条目类型。
# 拖放口径：
# 1. 只有准备期允许拖放和卸下。
# 2. 拖放成功后先写库存，再刷新详情与 inventory。
# 3. 失败提示只写 debug_label，不偷偷改数据。

const STAGE_PREPARATION: int = 0 # 只有备战期允许商店与仓库交互。

const SHOP_TAB_RECRUIT: String = "recruit" # 招募页签 id。
const SHOP_TAB_GONGFA: String = "gongfa" # 功法页签 id。
const SHOP_TAB_EQUIPMENT: String = "equipment" # 装备页签 id。

const INVENTORY_CARD_SCRIPT: Script = preload("res://scripts/ui/battle_inventory_item_card.gd") # 仓库卡片脚本。

var _owner = null # HUD facade。
var _scene_root = null # 根场景入口。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。
var _support = null # HUD 共享支撑。
var _detail_view = null # 详情协作者，用于 hover 和点击跳转。


# 绑定 shop/inventory 协作者需要的 facade、状态和共享 support。
# 这里不缓存商店或库存快照，所有数据按需从 state / runtime manager 读取。
func initialize(owner, scene_root, refs, state, support) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state
	_support = support


# 让 shop/inventory 可以把 hover 和详情跳转交给 detail view。
# 这样卡片自己不需要知道 tooltip 面板在哪棵节点树里。
func bind_detail_view(detail_view) -> void:
	_detail_view = detail_view


# 同步商店操作区文案和商品卡片列表。
# 操作区和商品卡必须同时刷新，避免价格文案与可购买状态不一致。
func update_shop_ui() -> void:
	update_shop_operation_labels()
	rebuild_shop_cards()


# 刷新商店银两、等级和锁店按钮状态。
# 按钮禁用口径只看当前阶段和经济快照，不在 view 层再塞业务判断。
func update_shop_operation_labels() -> void:
	if _refs.runtime_economy_manager == null:
		return
	var assets: Dictionary = _refs.runtime_economy_manager.call("get_assets_snapshot")
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
			int(_refs.runtime_economy_manager.call("get_max_deploy_limit"))
		]
	if _refs.shop_refresh_button != null:
		_refs.shop_refresh_button.text = "刷新(💰%d)" % int(
			_refs.runtime_economy_manager.call("get_refresh_cost")
		)
		_refs.shop_refresh_button.disabled = not stage_editable
	if _refs.shop_upgrade_button != null:
		_refs.shop_upgrade_button.text = "升级(💰%d)" % int(
			_refs.runtime_economy_manager.call("get_upgrade_cost")
		)
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


# 根据当前页签重建五格商店展示卡。
# 即使某格为空，也保留卡位，这样页签切换时布局不会跳动。
func rebuild_shop_cards() -> void:
	if _refs.shop_offer_row == null or _refs.runtime_shop_manager == null:
		return
	for child in _refs.shop_offer_row.get_children():
		child.queue_free()
	var offers: Array[Dictionary] = _refs.runtime_shop_manager.call(
		"get_offers",
		_state.shop_current_tab
	)
	for index in range(5):
		var offer: Dictionary = offers[index] if index < offers.size() else {}
		_refs.shop_offer_row.add_child(
			create_shop_offer_card(offer, index, _state.shop_current_tab)
		)


# 把单个商店条目投影成可点击卡片，并挂上 hover tooltip。
# 招募条目不展示物品 tooltip，因为它的收益由 coordinator 负责落位解释。
func create_shop_offer_card(
	offer: Dictionary,
	index: int,
	tab_id: String
) -> PanelContainer:
	# 基础骨架先建立，再根据 offer 是否为空决定填充内容。
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(136, 170)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 3)
	card.add_child(root)
	var color_bar := ColorRect.new()
	color_bar.custom_minimum_size = Vector2(0, 8)
	color_bar.color = _support.quality_color(str(offer.get("quality", "white")))
	root.add_child(color_bar)
	var name_label := Label.new()
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(name_label)
	var type_label := Label.new()
	type_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(type_label)
	var price_label := Label.new()
	root.add_child(price_label)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)
	var buy_button := Button.new()
	root.add_child(buy_button)
	if offer.is_empty():
		name_label.text = "空位"
		type_label.text = "暂无商品"
		price_label.text = ""
		buy_button.text = "—"
		buy_button.disabled = true
		return card
	var quality: String = str(offer.get("quality", "white"))
	var item_id: String = str(offer.get("item_id", "")).strip_edges()
	var price: int = int(offer.get("price", 0))
	var sold: bool = bool(offer.get("sold", false))
	var can_afford: bool = false
	if _refs.runtime_economy_manager != null:
		can_afford = int(_refs.runtime_economy_manager.call("get_silver")) >= price
	name_label.text = str(offer.get("name", "未知"))
	if tab_id == SHOP_TAB_RECRUIT:
		type_label.text = "[%s] 侠客" % _support.quality_to_cn(quality)
	else:
		type_label.text = "[%s] %s" % [
			_support.quality_to_cn(quality),
			_support.slot_or_equip_cn(tab_id, str(offer.get("slot_type", "")))
		]
	price_label.text = "💰 %d" % price if price > 0 else ""
	buy_button.text = "已售罄" if sold else "购买"
	buy_button.disabled = sold or int(_state.stage) != STAGE_PREPARATION or not can_afford
	buy_button.pressed.connect(Callable(self, "on_shop_buy_pressed").bind(tab_id, index))
	if sold or item_id.is_empty() or tab_id == SHOP_TAB_RECRUIT or _detail_view == null:
		return card
	# tooltip payload 只给功法/装备用，招募条目没有统一的物品说明结构。
	var tooltip_payload: Dictionary = {}
	if tab_id == SHOP_TAB_GONGFA:
		tooltip_payload = _support.build_gongfa_item_tooltip_data(item_id)
	else:
		tooltip_payload = _support.build_equip_item_tooltip_data(item_id)
	card.mouse_entered.connect(
		Callable(_detail_view, "on_item_source_hover_entered").bind(card, tooltip_payload)
	)
	card.mouse_exited.connect(
		Callable(_detail_view, "on_item_source_hover_exited").bind(card)
	)
	return card


# 根据当前 inventory 模式重建过滤按钮。
# 过滤按钮是 mode 的直接投影，切 mode 时一定要整行重建。
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
		var button := Button.new()
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
# inventory 摘要和卡片列表同源重建，避免“列表刷新了但汇总没变”。
func rebuild_inventory_items() -> void:
	if _refs.inventory_grid == null or _refs.unit_augment_manager == null:
		return
	for child in _refs.inventory_grid.get_children():
		child.queue_free()
	# stock_map 表示库存拥有量，id_set 再把已装备但库存为 0 的条目补进来。
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
	# 汇总栏只统计当前筛选后的结果，让玩家看到的是眼前列表的总量。
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
# 已装备条目必须补进 id_set，否则“全部穿在身上”的条目会从仓库列表消失。
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
# record 在这里一次性补全 owned/equipped 计数，后续排序和渲染就不用再回表。
func _build_inventory_records(id_set: Dictionary, stock_map: Dictionary) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	for key in id_set.keys():
		var lookup_id: String = str(key).strip_edges()
		if lookup_id.is_empty():
			continue
		var item_data: Dictionary = {}
		if _state.inventory_mode == "gongfa":
			item_data = _refs.unit_augment_manager.call("get_gongfa_data", lookup_id)
		else:
			item_data = _refs.unit_augment_manager.call("get_equipment_data", lookup_id)
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
# 过滤顺序固定为类型再名称，方便用户理解为什么某条目没出现在列表里。
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
# 卡片既承担显示也承担 drag payload 承载，所以这里把两类数据一起装进去。
func create_inventory_card(item_data: Dictionary) -> PanelContainer:
	# 展示文本先按 mode 决定图标和类型文案，再写库存与已装备数量。
	var card := INVENTORY_CARD_SCRIPT.new() as PanelContainer
	if card == null:
		card = PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 122)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 3)
	card.add_child(vbox)
	var item_type: String = str(item_data.get("type", ""))
	var icon_label := Label.new()
	if _state.inventory_mode == "gongfa":
		icon_label.text = _support.slot_icon(item_type)
	else:
		icon_label.text = _support.equip_icon(item_type)
	vbox.add_child(icon_label)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.text = str(item_data.get("name", str(item_data.get("id", "未知"))))
	vbox.add_child(name_label)
	var type_label := Label.new()
	type_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _state.inventory_mode == "gongfa":
		type_label.text = "[%s] %s · %s" % [
			_support.quality_to_cn(str(item_data.get("quality", "white"))),
			_support.slot_to_cn(item_type),
			_support.element_to_cn(str(item_data.get("element", "none")))
		]
	else:
		type_label.text = "[%s] %s · %s" % [
			_support.quality_to_cn(str(item_data.get("quality", "white"))),
			_support.equip_type_to_cn(item_type),
			_support.element_to_cn(str(item_data.get("element", "none")))
		]
	vbox.add_child(type_label)
	var item_id: String = str(item_data.get("id", "")).strip_edges()
	var owned_count: int = int(item_data.get("_owned_count", 0))
	var equipped_count: int = int(item_data.get("_equipped_count", 0))
	var status_label := Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.text = "库存 x%d | 已装备 x%d" % [owned_count, equipped_count]
	if owned_count <= 0 and equipped_count <= 0:
		status_label.text = "无库存"
	vbox.add_child(status_label)
	var tooltip_payload: Dictionary = {}
	if _state.inventory_mode == "gongfa":
		tooltip_payload = _support.build_gongfa_item_tooltip_data(item_id)
	else:
		tooltip_payload = _support.build_equip_item_tooltip_data(item_id)
	# can_drag 只看库存拥有量和阶段开关，避免装备中的同名条目被错误拖出。
	var can_drag: bool = owned_count > 0 and _state.inventory_drag_enabled
	var drag_payload: Dictionary = {
		"type": _state.inventory_mode,
		"id": item_id,
		"item_data": item_data.duplicate(true),
		"slot_type": item_type
	}
	if card.has_method("setup_card"):
		card.call("setup_card", item_id, item_data, drag_payload, can_drag)
		var click_cb: Callable = Callable(self, "on_inventory_card_clicked")
		if card.has_signal("card_clicked") and not card.is_connected("card_clicked", click_cb):
			card.connect("card_clicked", click_cb)
	if not can_drag:
		card.modulate = Color(0.75, 0.75, 0.75, 0.92)
	if _detail_view != null:
		card.mouse_entered.connect(
			Callable(_detail_view, "on_item_source_hover_entered").bind(card, tooltip_payload)
		)
		card.mouse_exited.connect(
			Callable(_detail_view, "on_item_source_hover_exited").bind(card)
		)
	return card


# 先按品质、再按名称排序 inventory 条目，保证列表稳定。
# 品质相同时再按名称自然排序，能减少 reload 后的视觉抖动。
func sort_inventory_item(a: Dictionary, b: Dictionary) -> bool:
	var rank_a: int = quality_rank(str(a.get("quality", "white")))
	var rank_b: int = quality_rank(str(b.get("quality", "white")))
	if rank_a != rank_b:
		return rank_a > rank_b
	return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0


# 为品质排序提供固定优先级映射。
# 这里的数值只用于排序，不直接拿去做经济或颜色判断。
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
# 单独保留按钮入口，便于信号连接时不暴露字符串常量。
func on_inventory_tab_gongfa_pressed() -> void:
	on_inventory_tab_pressed("gongfa")


# 装备 tab 按钮只切到装备模式，再复用统一的 tab 处理。
# 和功法入口保持对称，后续替换按钮实现时不影响下游逻辑。
func on_inventory_tab_equip_pressed() -> void:
	on_inventory_tab_pressed("equipment")


# 切换 inventory 模式时重置筛选条件并全量刷新列表。
# mode 变化会让筛选种类彻底变化，因此搜索框也要一起清空。
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
# 当前筛选值保存在 state，方便 detail 或 facade 重新刷新时复用。
func on_inventory_filter_pressed(filter_id: String) -> void:
	_state.inventory_filter_type = filter_id
	rebuild_inventory_filters()
	rebuild_inventory_items()


# 搜索框内容变化后，直接按当前条件重建列表。
# 搜索不做增量 patch，列表规模不大，全量重建更直观可靠。
func on_inventory_search_changed(_new_text: String) -> void:
	rebuild_inventory_items()


# 点击 inventory 条目时，如果该条目已装备，则跳到对应角色详情。
# 这让 inventory 既是库存列表，也是已装备条目的反查入口。
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
# 成功装备后，库存、详情 UI 和 inventory 列表必须按同一顺序一起刷新。
func on_slot_item_dropped(slot_category: String, slot_key: String, item_id: String) -> void:
	if not _support.is_valid_unit(_state.detail_unit):
		return
	if int(_state.stage) != STAGE_PREPARATION:
		return
	if _refs.unit_augment_manager == null:
		return
	# 先确认库存和阶段，再决定是否调用 unit_augment_manager，避免无效写入。
	var stock_category: String = "gongfa" if slot_category == "gongfa" else "equipment"
	if _state.get_owned_item_count(stock_category, item_id) <= 0:
		if _refs.debug_label != null:
			_refs.debug_label.text = "库存不足：无法装备 %s" % item_id
		return
	# 替换逻辑统一先记住被换下的条目，再在成功后回写库存。
	var replaced_item_id: String = ""
	var ok: bool = false
	if slot_category == "gongfa":
		var gongfa_slots: Dictionary = _support.normalize_unit_slots(
			_state.detail_unit.get("gongfa_slots")
		)
		replaced_item_id = str(gongfa_slots.get(slot_key, "")).strip_edges()
		if replaced_item_id == item_id:
			return
		ok = bool(_refs.unit_augment_manager.call("equip_gongfa", _state.detail_unit, slot_key, item_id))
	else:
		var equip_slots: Dictionary = _support.normalize_equip_slots(
			_support.get_unit_equip_slots(_state.detail_unit)
		)
		replaced_item_id = str(equip_slots.get(slot_key, "")).strip_edges()
		if replaced_item_id == item_id:
			return
		ok = bool(
			_refs.unit_augment_manager.call("equip_equipment", _state.detail_unit, slot_key, item_id)
		)
	if not ok:
		if _refs.debug_label != null:
			_refs.debug_label.text = "拖放失败：槽位不匹配或数据无效。"
		return
	# 写库存永远发生在装备成功之后，避免失败时把道具数量先扣掉。
	_state.consume_owned_item(stock_category, item_id, 1)
	if not replaced_item_id.is_empty():
		_state.add_owned_item(stock_category, replaced_item_id, 1)
	if _detail_view != null:
		_detail_view.update_detail_panel(_state.detail_unit)
	rebuild_inventory_items()


# 从详情槽位卸下条目时，统一回写库存并刷新详情显示。
# 卸下和拖放共享同一份库存口径，避免“装上去”和“卸下来”走两套规则。
func on_slot_unequip_pressed(slot_category: String, slot: String) -> void:
	if not _support.is_valid_unit(_state.detail_unit):
		return
	if int(_state.stage) != STAGE_PREPARATION:
		return
	if _refs.unit_augment_manager == null:
		return
	var removed_item_id: String = ""
	if slot_category == "gongfa":
		var gongfa_slots: Dictionary = _support.normalize_unit_slots(
			_state.detail_unit.get("gongfa_slots")
		)
		removed_item_id = str(gongfa_slots.get(slot, "")).strip_edges()
		if removed_item_id.is_empty():
			return
		_refs.unit_augment_manager.call("unequip_gongfa", _state.detail_unit, slot)
		_state.add_owned_item("gongfa", removed_item_id, 1)
	else:
		var equip_slots: Dictionary = _support.normalize_equip_slots(
			_support.get_unit_equip_slots(_state.detail_unit)
		)
		removed_item_id = str(equip_slots.get(slot, "")).strip_edges()
		if removed_item_id.is_empty():
			return
		_refs.unit_augment_manager.call("unequip_equipment", _state.detail_unit, slot)
		_state.add_owned_item("equipment", removed_item_id, 1)
	if _detail_view != null:
		_detail_view.update_detail_panel(_state.detail_unit)
	# 卸下后同样重建 inventory，确保库存数字和已装备数量立即回正。
	rebuild_inventory_items()


# 顶栏商店按钮只在准备期切换商店面板显隐。
# 阶段限制放在这里，是为了让按钮和快捷键共享同一入口规则。
func on_shop_open_button_pressed() -> void:
	if int(_state.stage) != STAGE_PREPARATION:
		return
	# 是否真正展示面板仍由 facade 决定，这里只表达“用户想打开商店”。
	_owner.toggle_shop_panel()


# 商店关闭按钮直接复用 facade 的统一显隐入口。
# 关闭后是否记住偏好由 facade 决定，这里不额外改 state。
func on_shop_close_pressed() -> void:
	_owner.set_shop_panel_visible(false, true)


# 商店 tab 变化时只切换当前页签和按钮状态，再重建卡片。
# tab 按钮状态和卡片列表必须同步，否则玩家会看到按钮亮着但内容没切换。
func on_shop_tab_pressed(tab_id: String) -> void:
	_state.shop_current_tab = tab_id
	if _refs.shop_tab_recruit_button != null:
		_refs.shop_tab_recruit_button.button_pressed = tab_id == SHOP_TAB_RECRUIT
	if _refs.shop_tab_gongfa_button != null:
		_refs.shop_tab_gongfa_button.button_pressed = tab_id == SHOP_TAB_GONGFA
	if _refs.shop_tab_equipment_button != null:
		_refs.shop_tab_equipment_button.button_pressed = tab_id == SHOP_TAB_EQUIPMENT
	# 商店页签切换不动库存 state，避免玩家在商店和仓库之间来回切换时丢筛选。
	rebuild_shop_cards()


# 商店刷新按钮只把动作转发给 coordinator。
# 费用扣减与锁店处理都留在 coordinator / economy support。
func on_shop_refresh_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.refresh_shop_from_button()


# 商店升级按钮只把动作转发给 coordinator。
# 这里不读升级代价，避免按钮文案和业务判断分裂。
func on_shop_upgrade_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.buy_shop_upgrade()


# 商店锁定按钮只把动作转发给 coordinator。
# view 层只负责表达点击，不自行切换锁店状态。
func on_shop_lock_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.toggle_shop_lock()


# 测试银两按钮只把动作转发给 coordinator。
# 调试按钮也遵守同一事件出口，方便之后统一删除或隐藏。
func on_shop_test_add_silver_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.add_test_silver()


# 测试经验按钮只把动作转发给 coordinator。
# 这样本地调试和正式按钮一样，都能被 coordinator 记到 battle log。
func on_shop_test_add_exp_button_pressed() -> void:
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		coordinator.add_test_exp()


# 商品卡购买按钮只把条目索引转发给 coordinator。
# 购买成功后的刷新由 coordinator 反向通知，不在 view 层先行假设结果。
func on_shop_buy_pressed(tab_id: String, index: int) -> void:
	# view 层永远只传 tab + index，真正的 offer 快照以 coordinator 再次读取为准。
	var coordinator = _owner.get_coordinator()
	if coordinator != null:
		# 这样即便商店快照刚刷新，购买仍会使用 coordinator 手里的最新数据。
		coordinator.purchase_shop_offer(tab_id, index)


