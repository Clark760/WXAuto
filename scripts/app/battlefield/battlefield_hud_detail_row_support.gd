extends RefCounted

# 只负责详情面板和 tooltip 的可复用行节点。
# 详情视图本体保留交互流程，这里只处理行节点的创建、刷新和缓存。
# 这一层不推动经济结算、不写会话状态，也不决定 tooltip 显隐时机。
# 所有行节点都必须从 refs 场景库或固定 fallback 实例化，禁止散落手写路径。

const STAGE_PREPARATION: int = 0
const SLOT_ORDER: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa"]

const GONGFA_SLOT_ROW_SCENE_ID: String = "gongfa_slot_row"
const EQUIP_SLOT_ROW_SCENE_ID: String = "equipment_slot_row"
const TOOLTIP_GONGFA_ROW_SCENE_ID: String = "unit_tooltip_gongfa_row"
const ITEM_TOOLTIP_EFFECT_ROW_SCENE_ID: String = "item_tooltip_effect_row"

const GONGFA_SLOT_ROW_SCENE_FALLBACK: PackedScene = preload("res://scenes/ui/gongfa_slot_row.tscn")
const EQUIP_SLOT_ROW_SCENE_FALLBACK: PackedScene = preload("res://scenes/ui/equipment_slot_row.tscn")
const TOOLTIP_GONGFA_ROW_SCENE_FALLBACK: PackedScene = preload(
	"res://scenes/ui/unit_tooltip_gongfa_row.tscn"
)
const ITEM_TOOLTIP_EFFECT_ROW_SCENE_FALLBACK: PackedScene = preload(
	"res://scenes/ui/item_tooltip_effect_row.tscn"
)

var _refs = null
var _state = null
var _support = null
var _hover_target: Object = null
var _shop_inventory_view = null

var _gongfa_slot_rows: Array[PanelContainer] = []
var _equip_slot_rows: Array[PanelContainer] = []
var _detail_equip_slot_order: Array[String] = []
var _tooltip_gongfa_rows: Array[PanelContainer] = []


# 绑定详情行支撑所需的 refs、state、共享 support 和 hover 回调目标。
# 这里不接 shop/inventory 回调，因为那部分要等 presenter 装配完成后再注入。
func initialize(refs, state, support, hover_target: Object) -> void:
	_refs = refs
	_state = state
	_support = support
	_hover_target = hover_target


# 释放行缓存和引用，避免切场后旧 PanelContainer 继续挂在 helper 上。
# shutdown 只清空本地缓存，不负责销毁由外层场景树持有的真实节点。
func shutdown() -> void:
	_refs = null
	_state = null
	_support = null
	_hover_target = null
	_shop_inventory_view = null
	_gongfa_slot_rows.clear()
	_equip_slot_rows.clear()
	_detail_equip_slot_order.clear()
	_tooltip_gongfa_rows.clear()


# 绑定 shop/inventory 协作者，供槽位行把拖拽和卸下事件回接出去。
# 这一步与 initialize 分开，是为了兼容 presenter 的固定装配顺序。
func bind_shop_inventory_view(shop_inventory_view) -> void:
	_shop_inventory_view = shop_inventory_view


# 刷新功法槽行文本、交互状态和 tooltip payload。
# 行节点不存在时会先懒创建，后续刷新只更新内容不重复接线。
func rebuild_detail_slot_rows(unit: Node) -> void:
	_ensure_detail_slot_rows_created()
	var slots: Dictionary = _support.normalize_unit_slots(unit.get("gongfa_slots"))
	for index in range(SLOT_ORDER.size()):
		if index >= _gongfa_slot_rows.size():
			continue
		var slot: String = SLOT_ORDER[index]
		var gongfa_id: String = str(slots.get(slot, "")).strip_edges()
		var row_panel: PanelContainer = _gongfa_slot_rows[index]
		if row_panel == null:
			continue
		var payload: Dictionary = {}
		if not gongfa_id.is_empty():
			payload = _support.build_gongfa_item_tooltip_data(gongfa_id)
		var row_view: Variant = row_panel
		row_view.refresh({
			"icon_text": _support.slot_icon(slot),
			"name_text": "%s: %s" % [
				_support.slot_to_cn(slot),
				_support.gongfa_name_or_empty(gongfa_id)
			],
			"name_disabled": gongfa_id.is_empty(),
			"unequip_text": "卸下" if not gongfa_id.is_empty() else "—",
			"unequip_disabled": gongfa_id.is_empty() or int(_state.stage) != STAGE_PREPARATION,
			"detail_text": _support.build_payload_brief_text(payload),
			"drop_enabled": int(_state.stage) == STAGE_PREPARATION,
			"item_payload": payload
		})


# 刷新装备槽行内容与可交互状态。
# 装备槽顺序必须先按 support 归一化，避免 detail 和 inventory 看到的顺序不一致。
func rebuild_equip_slot_rows(unit: Node) -> void:
	var equip_slots: Dictionary = _support.normalize_equip_slots(_support.get_unit_equip_slots(unit))
	var equip_order: Array[String] = _support.get_sorted_equip_slot_keys(
		equip_slots,
		_support.get_unit_max_equip_count(unit, equip_slots)
	)
	_ensure_detail_equip_rows_created(equip_order)
	for index in range(equip_order.size()):
		if index >= _equip_slot_rows.size():
			continue
		var equip_slot: String = equip_order[index]
		var equip_id: String = str(equip_slots.get(equip_slot, "")).strip_edges()
		var row_panel: PanelContainer = _equip_slot_rows[index]
		if row_panel == null:
			continue
		var payload: Dictionary = {}
		if not equip_id.is_empty():
			payload = _support.build_equip_item_tooltip_data(equip_id)
		var row_view: Variant = row_panel
		row_view.refresh({
			"icon_text": _support.equip_icon(equip_slot),
			"name_text": "%s: %s" % [
				_support.equip_type_to_cn(equip_slot),
				_support.equip_name_or_empty(equip_id)
			],
			"name_disabled": equip_id.is_empty(),
			"unequip_text": "卸下" if not equip_id.is_empty() else "—",
			"unequip_disabled": equip_id.is_empty() or int(_state.stage) != STAGE_PREPARATION,
			"detail_text": _support.build_payload_brief_text(payload),
			"drop_enabled": int(_state.stage) == STAGE_PREPARATION,
			"item_payload": payload
		})


# 刷新单位 tooltip 的功法 / 特性列表。
# 特性和功法统一投影成同一套行节点，避免 tooltip renderer 出现双模板分支。
func refresh_tooltip_gongfa_list(unit: Node) -> void:
	var entries: Array[Dictionary] = []
	var trait_values: Variant = _support.safe_node_prop(unit, "traits", [])
	if trait_values is Array:
		for trait_value in trait_values:
			if not (trait_value is Dictionary):
				continue
			var trait_data: Dictionary = trait_value as Dictionary
			var trait_payload: Dictionary = _support.build_trait_item_tooltip_data(trait_data)
			entries.append({
				"prefix_text": "特性",
				"text": str(trait_data.get("name", trait_data.get("id", "未命名特性"))),
				"detail_text": _support.build_payload_brief_text(trait_payload),
				"payload": trait_payload
			})
	var runtime_ids: Array = unit.get("runtime_equipped_gongfa_ids")
	var unit_augment_manager = _get_unit_augment_manager()
	for gongfa_id_value in runtime_ids:
		var gongfa_id: String = str(gongfa_id_value)
		var data: Dictionary = {}
		if unit_augment_manager != null:
			data = unit_augment_manager.get_gongfa_data(gongfa_id)
		var entry_text: String = gongfa_id
		if not data.is_empty():
			entry_text = str(data.get("name", gongfa_id))
		var gongfa_payload: Dictionary = _support.build_gongfa_item_tooltip_data(gongfa_id)
		entries.append({
			"prefix_text": "功法",
			"text": entry_text,
			"detail_text": _support.build_payload_brief_text(gongfa_payload),
			"payload": gongfa_payload
		})
	_ensure_tooltip_gongfa_rows_created(entries.size())
	if entries.is_empty():
		_show_empty_tooltip_gongfa_row()
		return
	for index in range(_tooltip_gongfa_rows.size()):
		var row_panel: PanelContainer = _tooltip_gongfa_rows[index]
		if row_panel == null:
			continue
		row_panel.visible = index < entries.size()
		if index >= entries.size():
			continue
		var row_view: Variant = row_panel
		row_view.refresh({
			"prefix_text": str(entries[index].get("prefix_text", "·")),
			"text": str(entries[index].get("text", "-")),
			"detail_text": str(entries[index].get("detail_text", "")),
			"disabled": false,
			"item_payload": entries[index].get("payload", {})
		})


# 按统一子场景行重建物品 tooltip 的效果文本列表。
# 空效果时是否展示“无”占位由调用方显式决定，这里不猜业务语义。
func rebuild_item_tooltip_effect_rows(
	container: VBoxContainer,
	lines: Array,
	show_empty_placeholder: bool
) -> void:
	for child in container.get_children():
		child.queue_free()
	if lines.is_empty() and not show_empty_placeholder:
		return
	if lines.is_empty():
		var empty_row: Control = _instantiate_effect_row()
		if empty_row == null:
			return
		var empty_row_view: Variant = empty_row
		empty_row_view.setup({"text": "· 无"})
		container.add_child(empty_row)
		return
	for line_value in lines:
		var line_row: Control = _instantiate_effect_row()
		if line_row == null:
			continue
		var line_row_view: Variant = line_row
		line_row_view.setup({"text": "· %s" % str(line_value)})
		container.add_child(line_row)


# 懒创建详情功法槽行，并把拖拽 / 卸下 / hover 信号一次接好。
# 详情行一旦创建完成，后续刷新只改内容，不再重复实例化。
func _ensure_detail_slot_rows_created() -> void:
	if not _gongfa_slot_rows.is_empty():
		return
	if _refs.detail_slot_list == null or _shop_inventory_view == null:
		return
	for slot in SLOT_ORDER:
		var row_panel: Variant = _instantiate_slot_row(
			GONGFA_SLOT_ROW_SCENE_ID,
			GONGFA_SLOT_ROW_SCENE_FALLBACK
		)
		if row_panel == null:
			continue
		row_panel.setup({
			"slot_category": "gongfa",
			"slot_key": slot,
			"icon_text": _support.slot_icon(slot),
			"name_text": "%s: -" % _support.slot_to_cn(slot),
			"name_disabled": true,
			"unequip_text": "—",
			"unequip_disabled": true,
			"drop_enabled": int(_state.stage) == STAGE_PREPARATION,
			"item_payload": {}
		})
		_bind_slot_row_actions(row_panel)
		var row_view: PanelContainer = row_panel as PanelContainer
		_refs.detail_slot_list.add_child(row_view)
		_gongfa_slot_rows.append(row_view)
		_connect_row_hover(row_view, row_panel)


# 根据装备槽顺序重建详情装备行。
# 当槽位数量或顺序变化时必须整组重建，避免旧行继续绑定旧 slot_key。
func _ensure_detail_equip_rows_created(equip_order: Array[String]) -> void:
	var should_rebuild: bool = _equip_slot_rows.size() != equip_order.size()
	if not should_rebuild and _detail_equip_slot_order.size() == equip_order.size():
		for index in range(equip_order.size()):
			if _detail_equip_slot_order[index] != equip_order[index]:
				should_rebuild = true
				break
	if not should_rebuild:
		return
	if _refs.detail_equip_slot_list == null or _shop_inventory_view == null:
		return
	for child in _refs.detail_equip_slot_list.get_children():
		child.queue_free()
	_equip_slot_rows.clear()
	_detail_equip_slot_order = equip_order.duplicate()
	for equip_slot in equip_order:
		var row_panel: Variant = _instantiate_slot_row(
			EQUIP_SLOT_ROW_SCENE_ID,
			EQUIP_SLOT_ROW_SCENE_FALLBACK
		)
		if row_panel == null:
			continue
		row_panel.setup({
			"slot_category": "equipment",
			"slot_key": equip_slot,
			"icon_text": _support.equip_icon(equip_slot),
			"name_text": "%s: -" % _support.equip_type_to_cn(equip_slot),
			"name_disabled": true,
			"unequip_text": "—",
			"unequip_disabled": true,
			"drop_enabled": int(_state.stage) == STAGE_PREPARATION,
			"item_payload": {}
		})
		_bind_slot_row_actions(row_panel)
		var row_view: PanelContainer = row_panel as PanelContainer
		_refs.detail_equip_slot_list.add_child(row_view)
		_equip_slot_rows.append(row_view)
		_connect_row_hover(row_view, row_panel)


# 按需补足 tooltip 功法行缓存，保证“无条目”时也至少保留一行占位。
# 这里统一创建 hover 连接，避免详情视图本体再关心子节点结构。
func _ensure_tooltip_gongfa_rows_created(required_count: int) -> void:
	if _refs.tooltip_gongfa_list == null:
		return
	var needed: int = maxi(required_count, 1)
	while _tooltip_gongfa_rows.size() < needed:
		var row_node: Node = _instantiate_ui_node(
			TOOLTIP_GONGFA_ROW_SCENE_ID,
			TOOLTIP_GONGFA_ROW_SCENE_FALLBACK
		)
		var row_panel: PanelContainer = row_node as PanelContainer
		if row_panel == null:
			if row_node != null:
				row_node.queue_free()
			break
		var row_view: Variant = row_panel
		row_view.setup({
			"prefix_text": "·",
			"text": "-",
			"detail_text": "",
			"disabled": true,
			"item_payload": {}
		})
		_refs.tooltip_gongfa_list.add_child(row_panel)
		_tooltip_gongfa_rows.append(row_panel)
		_connect_tooltip_row_hover(row_panel, row_view)


# 当单位没有功法和特性时，显式展示一条禁用占位行。
# 这样 tooltip 高度和结构更稳定，不会因为空列表突然塌掉一块。
func _show_empty_tooltip_gongfa_row() -> void:
	if _tooltip_gongfa_rows.is_empty():
		return
	var first_row: PanelContainer = _tooltip_gongfa_rows[0]
	if first_row == null:
		return
	first_row.visible = true
	var first_row_view: Variant = first_row
	first_row_view.refresh({
		"prefix_text": "·",
		"text": "功法/特性: 无",
		"detail_text": "",
		"disabled": true,
		"item_payload": {}
	})
	for index in range(1, _tooltip_gongfa_rows.size()):
		_tooltip_gongfa_rows[index].visible = false


# 把槽位行的 dropped / unequip 信号统一接回 shop/inventory 协作者。
# 行节点本身只负责抛事件，不认识上层业务对象。
func _bind_slot_row_actions(row_panel: Variant) -> void:
	var dropped_cb: Callable = Callable(_shop_inventory_view, "on_slot_item_dropped")
	if not row_panel.is_connected("item_dropped", dropped_cb):
		row_panel.connect("item_dropped", dropped_cb)
	var unequip_cb: Callable = Callable(_shop_inventory_view, "on_slot_unequip_pressed")
	if not row_panel.is_connected("unequip_requested", unequip_cb):
		row_panel.connect("unequip_requested", unequip_cb)


# 给详情槽位行和其内部按钮统一补 hover 入口。
# hover 一律回到 detail view 本体，避免 item tooltip 状态散落在多个 helper 里。
func _connect_row_hover(row_view: PanelContainer, row_panel: Variant) -> void:
	if _hover_target == null:
		return
	row_view.mouse_entered.connect(Callable(_hover_target, "on_item_row_hover_entered").bind(row_view))
	row_view.mouse_exited.connect(Callable(_hover_target, "on_item_source_hover_exited").bind(row_view))
	var name_button: LinkButton = row_panel.get_name_button()
	var unequip_button: Button = row_panel.get_unequip_button()
	if name_button == null or unequip_button == null:
		return
	name_button.mouse_entered.connect(
		Callable(_hover_target, "on_item_row_hover_entered").bind(row_view)
	)
	name_button.mouse_exited.connect(
		Callable(_hover_target, "on_item_source_hover_exited").bind(row_view)
	)
	unequip_button.mouse_entered.connect(
		Callable(_hover_target, "on_item_row_hover_entered").bind(row_view)
	)
	unequip_button.mouse_exited.connect(
		Callable(_hover_target, "on_item_source_hover_exited").bind(row_view)
	)


# 给 tooltip 功法行补 hover 入口，使 link button 与整行共享同一 item payload。
# 这里不直接显示 tooltip，只转发到 detail view 的统一 hover 状态机。
func _connect_tooltip_row_hover(row_panel: PanelContainer, row_view: Variant) -> void:
	if _hover_target == null:
		return
	row_panel.mouse_entered.connect(Callable(_hover_target, "on_item_row_hover_entered").bind(row_panel))
	row_panel.mouse_exited.connect(Callable(_hover_target, "on_item_source_hover_exited").bind(row_panel))
	var link: LinkButton = row_view.get_link_button()
	if link == null:
		return
	link.mouse_entered.connect(Callable(_hover_target, "on_item_row_hover_entered").bind(row_panel))
	link.mouse_exited.connect(Callable(_hover_target, "on_item_source_hover_exited").bind(row_panel))


# 实例化一行物品效果文本，失败时返回 null 让调用方直接跳过。
# 这里统一走子场景入口，保证效果行样式和排版与其它列表保持一致。
func _instantiate_effect_row() -> Control:
	var row_node: Node = _instantiate_ui_node(
		ITEM_TOOLTIP_EFFECT_ROW_SCENE_ID,
		ITEM_TOOLTIP_EFFECT_ROW_SCENE_FALLBACK
	)
	var row: Control = row_node as Control
	if row == null and row_node != null:
		row_node.queue_free()
	return row


# 先尝试从 refs 场景库取子场景，不存在时再回退到固定资源。
# 这样 UI 资源切换只需要更新 refs，不用改 helper 逻辑。
func _resolve_ui_scene(scene_id: String, fallback_scene: PackedScene) -> PackedScene:
	if _refs != null and _refs.has_method("get_ui_scene"):
		var scene_value: Variant = _refs.get_ui_scene(scene_id)
		if scene_value is PackedScene:
			return scene_value as PackedScene
	return fallback_scene


# 统一实例化任意 UI 子场景节点。
# helper 自己不缓存 PackedScene，只在需要时从 refs 或 fallback 拿最新版本。
func _instantiate_ui_node(scene_id: String, fallback_scene: PackedScene) -> Node:
	var scene: PackedScene = _resolve_ui_scene(scene_id, fallback_scene)
	return scene.instantiate() if scene != null else null


# 实例化槽位行视图，失败时主动释放非目标类型节点并返回 null。
# 这样外层刷新逻辑只需要判断 null，不必重复做类型防御。
func _instantiate_slot_row(scene_id: String, fallback_scene: PackedScene) -> Variant:
	var instance: Node = _instantiate_ui_node(scene_id, fallback_scene)
	if instance is PanelContainer:
		return instance
	if instance != null:
		instance.queue_free()
	return null


# 统一通过 refs 读取 UnitAugmentManager，避免 tooltip 行构建自己去查根节点。
# 这里只拿只读数据接口，具体 tooltip 状态仍由 detail view 维护。
func _get_unit_augment_manager():
	if _refs == null:
		return null
	return _refs.unit_augment_manager
