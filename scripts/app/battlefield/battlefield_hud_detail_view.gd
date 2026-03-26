extends RefCounted

# HUD 详情与 Tooltip
# 说明：
# 1. 只负责角色详情、单位 tooltip、物品 tooltip 和相关悬停态。
# 2. 这里不处理商店购买、背包筛选和战斗日志。
# 详情状态流：
# 1. bench/world 点击只改 detail state，再统一刷新详情面板。
# 2. 结果期禁止重新打开详情，避免和统计面板抢焦点。
# 3. 详情刷新频率按阶段分档，备战期省刷新，战斗期保实时。
# Tooltip 状态流：
# 1. 单位 tooltip 只由 world hover 触发。
# 2. 物品 tooltip 只由卡片/槽位 hover 触发，并经过延迟和 bridge 保护。
# 3. 一旦 GUI 正在拖拽，就强制隐藏物品 tooltip，避免遮挡拖放反馈。
# 行缓存口径：
# 1. 功法槽、装备槽、tooltip 功法行都先复用缓存节点。
# 2. 槽位拖放和卸下事件统一回交 shop_inventory_view。
# 3. detail view 不直接改库存，只负责展示和交互桥接。
# 可读性约束：
# 1. 这里的注释优先解释 hover 保护、缓存重建和阶段差异。
# 2. 不再用文件末尾附录补比例，真正复杂逻辑直接写在方法附近。

const STAGE_PREPARATION: int = 0 # 备战期允许详情拖拽和装备调整。
const STAGE_COMBAT: int = 1 # 交锋期详情只读。
const STAGE_RESULT: int = 2 # 结算期优先让位给结果统计。

const DETAIL_REFRESH_INTERVAL_PREP: float = 0.20 # 备战期详情刷新节奏。
const DETAIL_REFRESH_INTERVAL_COMBAT: float = 0.05 # 战斗期详情刷新节奏。
const SLOT_ORDER: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa"] # 功法槽顺序。

const SLOT_DROP_TARGET_SCRIPT: Script = preload("res://scripts/ui/battle_slot_drop_target.gd") # 功法/装备槽拖放脚本。

var _owner = null # HUD facade，用于 tween 和对外回调。
var _scene_root = null # 根场景入口。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。
var _support = null # 共享 tooltip/格式化支撑。
var _shop_inventory_view = null # 仓库协作者，用于槽位交互回接。

var _gongfa_slot_rows: Array[PanelContainer] = [] # 详情功法槽行缓存。
var _gongfa_slot_name_buttons: Array[LinkButton] = [] # 功法槽名称按钮缓存。
var _gongfa_slot_swap_buttons: Array[Button] = [] # 功法槽替换按钮缓存。
var _equip_slot_rows: Array[PanelContainer] = [] # 装备槽行缓存。
var _equip_slot_name_buttons: Array[LinkButton] = [] # 装备槽名称按钮缓存。
var _equip_slot_swap_buttons: Array[Button] = [] # 装备槽替换按钮缓存。
var _detail_equip_slot_order: Array[String] = [] # 当前详情装备槽顺序。
var _tooltip_gongfa_rows: Array[PanelContainer] = [] # tooltip 功法行缓存。
var _tooltip_gongfa_links: Array[LinkButton] = [] # tooltip 功法按钮缓存。


# 绑定 detail view 所需的 facade、引用表、状态和共享 support。
# detail view 自己不持有业务数据副本，只依赖 session state 和 refs。
func initialize(owner, scene_root, refs, state, support) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state
	_support = support


# 让 detail view 可以把槽位拖放和卸下事件回交给 inventory/shop 协作者。
# 这样详情协作者只描述“槽位交互发生了”，不自己结算库存。
func bind_shop_inventory_view(shop_inventory_view) -> void:
	_shop_inventory_view = shop_inventory_view


# 统一关闭详情面板和相关 tooltip，避免结果阶段或 ESC 后残留。
# 关闭时顺手把拖拽态和 hover 态清掉，防止下一次打开沿用旧上下文。
func force_close_detail_panel(animate: bool) -> void:
	if _refs.unit_detail_panel == null:
		return
	if not _refs.unit_detail_panel.visible:
		_state.detail_visible = false
		_state.detail_unit = null
		if _refs.item_tooltip != null:
			_refs.item_tooltip.visible = false
		_support.clear_item_hover_state()
		return
	if animate:
		var tween: Tween = _owner.create_tween()
		tween.tween_property(_refs.unit_detail_panel, "modulate:a", 0.0, 0.08)
		tween.finished.connect(func() -> void:
			_refs.unit_detail_panel.visible = false
			_refs.unit_detail_panel.modulate = Color(1, 1, 1, 1)
		)
	else:
		_refs.unit_detail_panel.visible = false
	if _refs.unit_detail_mask != null:
		_refs.unit_detail_mask.visible = false
	if _refs.item_tooltip != null:
		_refs.item_tooltip.visible = false
	_state.detail_visible = false
	_state.detail_unit = null
	_state.is_dragging_detail_panel = false
	_support.clear_item_hover_state()


# 备战席点选只在 detail view 内部切换详情面板，不反向触碰世界层。
# bench 点击和 world 点击最终都走同一套 detail 开合逻辑。
func handle_bench_unit_click(_slot_index: int, unit: Node) -> void:
	toggle_or_open_detail(unit)


# 世界单位点选与备战席同口径处理，统一走详情开合逻辑。
# 这样无论单位来自哪里，详情态都只有一个入口。
func handle_world_unit_click(unit: Node, _screen_pos: Vector2) -> void:
	toggle_or_open_detail(unit)


# 世界 hover 命中后，只在这里决定是否展示单位 tooltip。
# 一旦详情面板已经打开，就强制压住单位 tooltip，避免两层信息重叠。
func update_hovered_unit(unit: Node, screen_pos: Vector2) -> void:
	if not _support.is_valid_unit(unit):
		clear_hovered_unit()
		return
	if _refs.unit_detail_panel != null and _refs.unit_detail_panel.visible:
		clear_hovered_unit()
		return
	_state.tooltip_visible = true
	_state.hover_candidate_unit = unit
	show_tooltip_for_unit(unit, screen_pos)


# hover 丢失后统一隐藏单位 tooltip。
# tooltip 可见性与 hover state 一起清，避免 scene 上留下孤立浮层。
func clear_hovered_unit() -> void:
	_state.tooltip_visible = false
	if _refs.unit_tooltip != null:
		_refs.unit_tooltip.visible = false


# 点击同一角色时切换开合，点击不同角色时直接切换详情内容。
# 这样玩家可以把详情面板当作一个可切换的固定焦点层，而不是一次性弹窗。
func toggle_or_open_detail(unit: Node) -> void:
	if not _support.is_valid_unit(unit):
		return
	if _state.detail_visible and _state.detail_unit == unit:
		force_close_detail_panel(false)
		return
	open_detail_panel(unit)


# 打开角色详情时只写入详情态和面板显隐，不处理 inventory 数据。
# inventory 刷新由 facade 统一驱动，detail view 这里只负责当前目标。
func open_detail_panel(unit: Node) -> void:
	if int(_state.stage) == STAGE_RESULT:
		return
	if not _support.is_valid_unit(unit):
		return
	_state.detail_unit = unit
	_state.detail_visible = true
	_state.detail_refresh_accum = 0.0
	update_detail_panel(unit)
	if _refs.unit_detail_panel != null:
		_refs.unit_detail_panel.visible = true
	if _refs.unit_detail_mask != null:
		_refs.unit_detail_mask.visible = true


# 已打开详情时按阶段频率刷新，避免战斗期数据滞后。
# refresh_accum 只在这里消费，其他协作者不应擅自改详情刷新节奏。
func refresh_open_detail_panel(delta: float) -> void:
	if not _state.detail_visible:
		_state.detail_refresh_accum = 0.0
		return
	if _refs.unit_detail_panel == null or not _refs.unit_detail_panel.visible:
		_state.detail_refresh_accum = 0.0
		return
	if not _support.is_valid_unit(_state.detail_unit):
		force_close_detail_panel(false)
		return
	_state.detail_refresh_accum += delta
	var refresh_interval: float = DETAIL_REFRESH_INTERVAL_PREP
	if int(_state.stage) == STAGE_COMBAT:
		refresh_interval = DETAIL_REFRESH_INTERVAL_COMBAT
	if _state.detail_refresh_accum < refresh_interval:
		return
	_state.detail_refresh_accum = 0.0
	update_detail_panel(_state.detail_unit)


# 当详情目标失效时，统一回收到关闭流程，避免悬空节点留在 state。
# 只要目标节点失效，就不尝试抢救旧 UI，直接走统一关闭分支最安全。
func clear_detail_if_invalid() -> void:
	if _state.detail_visible and not _support.is_valid_unit(_state.detail_unit):
		force_close_detail_panel(false)


# 重新投影当前详情角色的头像、属性和装备槽内容。
# 详情面板所有字段都从当前单位重新读取，不依赖上次缓存文本。
func update_detail_panel(unit: Node) -> void:
	if not _support.is_valid_unit(unit):
		return
	# 头部信息和品质底色先刷新，保证切换角色时主视觉立刻变化。
	var unit_name: String = str(unit.get("unit_name"))
	var star: int = clampi(int(unit.get("star_level")), 1, 3)
	var quality: String = str(unit.get("quality"))
	if _refs.detail_title != null:
		_refs.detail_title.text = "角色详情 - %s" % unit_name
	if _refs.detail_name_label != null:
		_refs.detail_name_label.text = "%s %s" % [unit_name, "★".repeat(star)]
	if _refs.detail_quality_label != null:
		_refs.detail_quality_label.text = "品质：%s" % _support.quality_to_cn(quality)
	if _refs.detail_portrait_color != null:
		_refs.detail_portrait_color.color = _support.quality_color(quality)
	# 属性区同时展示基础值与运行时值，增益差额由 support 统一格式化。
	var base_stats: Dictionary = unit.get("base_stats")
	var runtime_stats: Dictionary = unit.get("runtime_stats")
	if _refs.detail_stats_value_label != null:
		_refs.detail_stats_value_label.text = "\n".join([
			_support.format_stat_pair("生命", runtime_stats, base_stats, "hp"),
			_support.format_stat_pair("内力", runtime_stats, base_stats, "mp"),
			_support.format_stat_pair("外功", runtime_stats, base_stats, "atk"),
			_support.format_stat_pair("外防", runtime_stats, base_stats, "def"),
			_support.format_stat_pair("内功", runtime_stats, base_stats, "iat"),
			_support.format_stat_pair("内防", runtime_stats, base_stats, "idr"),
			_support.format_stat_pair("速度", runtime_stats, base_stats, "spd"),
			_support.format_stat_pair("射程", runtime_stats, base_stats, "rng")
		])
	if _refs.detail_bonus_value_label != null:
		var bonus_lines: Array[String] = _support.build_gongfa_bonus_lines(unit)
		_refs.detail_bonus_value_label.text = "无" if bonus_lines.is_empty() else "\n".join(bonus_lines)
	# 槽位区最后刷新，确保上面的名字/品质已切到同一目标单位。
	rebuild_detail_slot_rows(unit)
	rebuild_equip_slot_rows(unit)


# 首次打开详情时创建功法槽 UI 行，并把拖放事件接到 shop/inventory 协作者。
# 这些行会长期复用，所以 hover、drop 和按钮事件都在创建时一次性接好。
func ensure_detail_slot_rows_created() -> void:
	if not _gongfa_slot_rows.is_empty():
		return
	if _refs.detail_slot_list == null or _shop_inventory_view == null:
		return
	for slot in SLOT_ORDER:
		var row_panel := SLOT_DROP_TARGET_SCRIPT.new() as PanelContainer
		if row_panel == null:
			row_panel = PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_panel.custom_minimum_size = Vector2(0, 30)
		row_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		if row_panel.has_method("setup_slot"):
			row_panel.call("setup_slot", "gongfa", slot)
		if row_panel.has_method("set_drop_enabled"):
			row_panel.call("set_drop_enabled", int(_state.stage) == STAGE_PREPARATION)
		if row_panel.has_signal("item_dropped"):
			row_panel.connect(
				"item_dropped",
				Callable(_shop_inventory_view, "on_slot_item_dropped")
			)
		# 每一行都带自己的 item_data，后续 tooltip 只读 meta 就能展示。
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 8)
		var icon_label := Label.new()
		icon_label.text = _support.slot_icon(slot)
		icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon_label)
		var name_button := LinkButton.new()
		name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_button)
		var unequip_button := Button.new()
		unequip_button.mouse_filter = Control.MOUSE_FILTER_PASS
		unequip_button.pressed.connect(
			Callable(_shop_inventory_view, "on_slot_unequip_pressed").bind("gongfa", slot)
		)
		row.add_child(unequip_button)
		row_panel.add_child(row)
		_refs.detail_slot_list.add_child(row_panel)
		row_panel.mouse_entered.connect(Callable(self, "on_item_row_hover_entered").bind(row_panel))
		row_panel.mouse_exited.connect(Callable(self, "on_item_source_hover_exited").bind(row_panel))
		name_button.mouse_entered.connect(
			Callable(self, "on_item_row_hover_entered").bind(row_panel)
		)
		name_button.mouse_exited.connect(
			Callable(self, "on_item_source_hover_exited").bind(row_panel)
		)
		unequip_button.mouse_entered.connect(
			Callable(self, "on_item_row_hover_entered").bind(row_panel)
		)
		unequip_button.mouse_exited.connect(
			Callable(self, "on_item_source_hover_exited").bind(row_panel)
		)
		_gongfa_slot_rows.append(row_panel)
		_gongfa_slot_name_buttons.append(name_button)
		_gongfa_slot_swap_buttons.append(unequip_button)


# 把当前详情角色的功法槽数据刷新到已创建的槽位行。
# 数据刷新只改文本和 meta，不重复销毁/重建整行节点。
func rebuild_detail_slot_rows(unit: Node) -> void:
	ensure_detail_slot_rows_created()
	var slots: Dictionary = _support.normalize_unit_slots(unit.get("gongfa_slots"))
	for index in range(SLOT_ORDER.size()):
		var slot: String = SLOT_ORDER[index]
		var gongfa_id: String = str(slots.get(slot, "")).strip_edges()
		var row_panel: PanelContainer = _gongfa_slot_rows[index]
		var name_button: LinkButton = _gongfa_slot_name_buttons[index]
		var unequip_button: Button = _gongfa_slot_swap_buttons[index]
		name_button.text = "%s: %s" % [
			_support.slot_to_cn(slot),
			_support.gongfa_name_or_empty(gongfa_id)
		]
		name_button.disabled = gongfa_id.is_empty()
		if row_panel.has_method("set_drop_enabled"):
			row_panel.call("set_drop_enabled", int(_state.stage) == STAGE_PREPARATION)
		if gongfa_id.is_empty():
			row_panel.set_meta("item_data", {})
		else:
			row_panel.set_meta("item_data", _support.build_gongfa_item_tooltip_data(gongfa_id))
		unequip_button.text = "卸下" if not gongfa_id.is_empty() else "—"
		unequip_button.disabled = gongfa_id.is_empty() or int(_state.stage) != STAGE_PREPARATION


# 首次打开详情或装备槽布局变化时，重建装备槽 UI 行。
# 只有槽位数量或顺序变化时才重建，避免普通刷新期间频繁 new 控件。
func ensure_detail_equip_rows_created(equip_order: Array[String]) -> void:
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
	_equip_slot_name_buttons.clear()
	_equip_slot_swap_buttons.clear()
	_detail_equip_slot_order = equip_order.duplicate()
	for equip_slot in equip_order:
		var row_panel := SLOT_DROP_TARGET_SCRIPT.new() as PanelContainer
		if row_panel == null:
			row_panel = PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_panel.custom_minimum_size = Vector2(0, 30)
		row_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		if row_panel.has_method("setup_slot"):
			row_panel.call("setup_slot", "equipment", equip_slot)
		if row_panel.has_method("set_drop_enabled"):
			row_panel.call("set_drop_enabled", int(_state.stage) == STAGE_PREPARATION)
		if row_panel.has_signal("item_dropped"):
			row_panel.connect(
				"item_dropped",
				Callable(_shop_inventory_view, "on_slot_item_dropped")
			)
		# 装备槽和功法槽保持同一交互结构，后续 hover/拖放逻辑就能复用。
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 8)
		var icon_label := Label.new()
		icon_label.text = _support.equip_icon(equip_slot)
		icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon_label)
		var name_button := LinkButton.new()
		name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_button.modulate = Color(0.82, 0.82, 0.82, 1.0)
		name_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_button)
		var unequip_button := Button.new()
		unequip_button.mouse_filter = Control.MOUSE_FILTER_PASS
		unequip_button.pressed.connect(
			Callable(_shop_inventory_view, "on_slot_unequip_pressed").bind(
				"equipment",
				equip_slot
			)
		)
		row.add_child(unequip_button)
		row_panel.add_child(row)
		_refs.detail_equip_slot_list.add_child(row_panel)
		row_panel.mouse_entered.connect(Callable(self, "on_item_row_hover_entered").bind(row_panel))
		row_panel.mouse_exited.connect(Callable(self, "on_item_source_hover_exited").bind(row_panel))
		name_button.mouse_entered.connect(
			Callable(self, "on_item_row_hover_entered").bind(row_panel)
		)
		name_button.mouse_exited.connect(
			Callable(self, "on_item_source_hover_exited").bind(row_panel)
		)
		unequip_button.mouse_entered.connect(
			Callable(self, "on_item_row_hover_entered").bind(row_panel)
		)
		unequip_button.mouse_exited.connect(
			Callable(self, "on_item_source_hover_exited").bind(row_panel)
		)
		_equip_slot_rows.append(row_panel)
		_equip_slot_name_buttons.append(name_button)
		_equip_slot_swap_buttons.append(unequip_button)


# 把当前详情角色的装备槽状态刷新到装备槽行。
# equip_order 由 support 统一排序，detail view 这里只消费稳定顺序。
func rebuild_equip_slot_rows(unit: Node) -> void:
	var equip_slots: Dictionary = _support.normalize_equip_slots(_support.get_unit_equip_slots(unit))
	# 排序后的 equip_order 同时决定展示顺序和 drop target 顺序。
	var equip_order: Array[String] = _support.get_sorted_equip_slot_keys(
		equip_slots,
		_support.get_unit_max_equip_count(unit, equip_slots)
	)
	ensure_detail_equip_rows_created(equip_order)
	for index in range(equip_order.size()):
		var equip_slot: String = equip_order[index]
		var equip_id: String = str(equip_slots.get(equip_slot, "")).strip_edges()
		var row_panel: PanelContainer = _equip_slot_rows[index]
		var name_button: LinkButton = _equip_slot_name_buttons[index]
		var unequip_button: Button = _equip_slot_swap_buttons[index]
		name_button.text = "%s: %s" % [
			_support.equip_type_to_cn(equip_slot),
			_support.equip_name_or_empty(equip_id)
		]
		name_button.disabled = equip_id.is_empty()
		if row_panel.has_method("set_drop_enabled"):
			row_panel.call("set_drop_enabled", int(_state.stage) == STAGE_PREPARATION)
		if equip_id.is_empty():
			row_panel.set_meta("item_data", {})
		else:
			row_panel.set_meta("item_data", _support.build_equip_item_tooltip_data(equip_id))
		# 装备槽在战斗期只读，因此按钮可见但会被统一禁用。
		unequip_button.text = "卸下" if not equip_id.is_empty() else "—"
		unequip_button.disabled = equip_id.is_empty() or int(_state.stage) != STAGE_PREPARATION


# 根据 hover 单位更新头信息、生命内力和技能列表。
# 单位 tooltip 只展示观战信息，不提供任何可点击的业务操作。
func show_tooltip_for_unit(unit: Node, screen_pos: Vector2) -> void:
	if _refs.unit_tooltip == null:
		return
	if not _support.is_valid_unit(unit):
		return
	# 单位名、品质徽章和血蓝条属于 tooltip 头部，优先刷新能减少观感闪烁。
	var unit_name: String = str(unit.get("unit_name"))
	var star: int = clampi(int(unit.get("star_level")), 1, 3)
	if _refs.tooltip_header_name != null:
		_refs.tooltip_header_name.text = "%s %s" % [unit_name, "★".repeat(star)]
	if _refs.tooltip_quality_badge != null:
		_refs.tooltip_quality_badge.color = _support.quality_color(str(unit.get("quality")))
	# 血蓝条优先读战斗组件；没有战斗组件时回退到安全默认值。
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	var current_hp: float = 0.0
	var max_hp: float = 1.0
	var current_mp: float = 0.0
	var max_mp: float = 1.0
	if combat != null:
		current_hp = float(combat.get("current_hp"))
		max_hp = maxf(float(combat.get("max_hp")), 1.0)
		current_mp = float(combat.get("current_mp"))
		max_mp = maxf(float(combat.get("max_mp")), 1.0)
	if _refs.tooltip_hp_bar != null:
		_refs.tooltip_hp_bar.value = clampf(current_hp / max_hp * 100.0, 0.0, 100.0)
	if _refs.tooltip_mp_bar != null:
		_refs.tooltip_mp_bar.value = clampf(current_mp / max_mp * 100.0, 0.0, 100.0)
	if _refs.tooltip_hp_text != null:
		_refs.tooltip_hp_text.text = "%d/%d" % [int(round(current_hp)), int(round(max_hp))]
	if _refs.tooltip_mp_text != null:
		_refs.tooltip_mp_text.text = "%d/%d" % [int(round(current_mp)), int(round(max_mp))]
	# tooltip 属性行和详情面板共用 support 格式化，保证数值口径一致。
	var base_stats: Dictionary = unit.get("base_stats")
	var runtime_stats: Dictionary = unit.get("runtime_stats")
	if _refs.tooltip_atk_label != null:
		_refs.tooltip_atk_label.text = _support.format_stat_pair(
			"外功",
			runtime_stats,
			base_stats,
			"atk"
		)
	if _refs.tooltip_def_label != null:
		_refs.tooltip_def_label.text = _support.format_stat_pair(
			"外防",
			runtime_stats,
			base_stats,
			"def"
		)
	if _refs.tooltip_iat_label != null:
		_refs.tooltip_iat_label.text = _support.format_stat_pair(
			"内功",
			runtime_stats,
			base_stats,
			"iat"
		)
	if _refs.tooltip_idr_label != null:
		_refs.tooltip_idr_label.text = _support.format_stat_pair(
			"内防",
			runtime_stats,
			base_stats,
			"idr"
		)
	if _refs.tooltip_spd_label != null:
		_refs.tooltip_spd_label.text = _support.format_stat_pair(
			"速度",
			runtime_stats,
			base_stats,
			"spd"
		)
	if _refs.tooltip_rng_label != null:
		_refs.tooltip_rng_label.text = _support.format_stat_pair(
			"射程",
			runtime_stats,
			base_stats,
			"rng"
		)
	if _refs.tooltip_status_label != null:
		_refs.tooltip_status_label.text = "状态: %s" % _support.resolve_unit_status(unit)
	# 技能和 Buff 列表最后刷新，再依据最终大小决定 tooltip 落点。
	refresh_tooltip_gongfa_list(unit)
	refresh_tooltip_buff_list(unit)
	position_unit_tooltip(screen_pos)


# 预创建 tooltip 的功法/特性行，避免 hover 时频繁 new 节点。
# 这里允许最少保留一行空态，避免“无技能”时整个区域高度抖动。
func ensure_tooltip_gongfa_rows_created(required_count: int) -> void:
	if _refs.tooltip_gongfa_list == null:
		return
	var needed: int = maxi(required_count, 1)
	while _tooltip_gongfa_rows.size() < needed:
		var row_panel := PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_panel.custom_minimum_size = Vector2(0, 24)
		row_panel.mouse_filter = Control.MOUSE_FILTER_PASS
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 4)
		var prefix := Label.new()
		prefix.text = "•"
		row.add_child(prefix)
		var link := LinkButton.new()
		link.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		link.text = "-"
		row.add_child(link)
		# 行和 link 都接 hover，是为了让鼠标压到任意子控件都能保持 tooltip。
		row_panel.add_child(row)
		_refs.tooltip_gongfa_list.add_child(row_panel)
		row_panel.mouse_entered.connect(Callable(self, "on_item_row_hover_entered").bind(row_panel))
		row_panel.mouse_exited.connect(Callable(self, "on_item_source_hover_exited").bind(row_panel))
		link.mouse_entered.connect(Callable(self, "on_item_row_hover_entered").bind(row_panel))
		link.mouse_exited.connect(Callable(self, "on_item_source_hover_exited").bind(row_panel))
		_tooltip_gongfa_rows.append(row_panel)
		_tooltip_gongfa_links.append(link)


# 根据角色特性与运行时功法刷新 tooltip 技能列表。
# 特性和功法在同一列表展示，是为了让玩家一次看到全部来源的能力说明。
func refresh_tooltip_gongfa_list(unit: Node) -> void:
	# entries 统一描述“展示文本 + tooltip payload”，后续渲染不再区分来源。
	# traits 来自静态配置，runtime_equipped_gongfa_ids 来自当前战斗态，两者都要兼容。
	var entries: Array[Dictionary] = []
	var trait_values: Variant = _support.safe_node_prop(unit, "traits", [])
	if trait_values is Array:
		for trait_value in trait_values:
			if not (trait_value is Dictionary):
				continue
			var trait_data: Dictionary = trait_value as Dictionary
			entries.append({
				"text": "特性·%s" % str(trait_data.get("name", trait_data.get("id", "未命名特性"))),
				"payload": _support.build_trait_item_tooltip_data(trait_data)
			})
	var runtime_ids: Array = unit.get("runtime_equipped_gongfa_ids")
	for gongfa_id_value in runtime_ids:
		var gongfa_id: String = str(gongfa_id_value)
		var data: Dictionary = {}
		if _refs.unit_augment_manager != null:
			data = _refs.unit_augment_manager.call("get_gongfa_data", gongfa_id)
		# 没查到功法配置时仍保留 id，至少让 tooltip 能看出当前挂了什么。
		var entry_text: String = gongfa_id
		if not data.is_empty():
			entry_text = "%s（%s/%s）" % [
				str(data.get("name", gongfa_id)),
				_support.slot_to_cn(str(data.get("type", ""))),
				_support.element_to_cn(str(data.get("element", "none")))
			]
		entries.append({
			"text": entry_text,
			"payload": _support.build_gongfa_item_tooltip_data(gongfa_id)
		})
	ensure_tooltip_gongfa_rows_created(entries.size())
	# 空态时也保留第一行，避免 tooltip 高度从有到无来回跳。
	if entries.is_empty():
		if _tooltip_gongfa_rows.is_empty():
			return
		_tooltip_gongfa_rows[0].visible = true
		_tooltip_gongfa_rows[0].set_meta("item_data", {})
		_tooltip_gongfa_links[0].text = "功法/特性: 无"
		_tooltip_gongfa_links[0].disabled = true
		for index in range(1, _tooltip_gongfa_rows.size()):
			_tooltip_gongfa_rows[index].visible = false
		return
	for index in range(_tooltip_gongfa_rows.size()):
		# 多出的缓存行只隐藏不销毁，下一次 hover 还能直接复用。
		_tooltip_gongfa_rows[index].visible = index < entries.size()
		if index >= entries.size():
			continue
		_tooltip_gongfa_links[index].disabled = false
		_tooltip_gongfa_links[index].text = str(entries[index].get("text", "-"))
		_tooltip_gongfa_rows[index].set_meta("item_data", entries[index].get("payload", {}))


# 根据角色当前 Buff 列表刷新 tooltip Buff 标签。
# Buff 标签每次全量重建，是因为数量通常不大，逻辑比增量同步更直观。
func refresh_tooltip_buff_list(unit: Node) -> void:
	if _refs.tooltip_buff_list == null:
		return
	# Buff 区先清空旧标签，保证不同单位之间不会串内容。
	for child in _refs.tooltip_buff_list.get_children():
		child.queue_free()
	var buff_ids: Array[String] = []
	if _refs.unit_augment_manager != null:
		if _refs.unit_augment_manager.has_method("get_unit_buff_ids"):
			buff_ids = _refs.unit_augment_manager.call("get_unit_buff_ids", unit)
	if buff_ids.is_empty():
		var empty_label := Label.new()
		empty_label.text = "Buff: 无"
		_refs.tooltip_buff_list.add_child(empty_label)
		return
	for buff_id in buff_ids:
		# Buff 这里只展示短标签，详细说明仍留给功法/物品 tooltip。
		var tag := Label.new()
		tag.text = "[%s]" % _support.buff_name_from_id(buff_id)
		_refs.tooltip_buff_list.add_child(tag)


# 把单位 tooltip 限制在视口内，避免靠边 hover 时溢出屏幕。
# 先按右下偏移放置，越界时再翻到左侧或上方，手感比直接 clamp 更自然。
func position_unit_tooltip(screen_pos: Vector2) -> void:
	if _refs.unit_tooltip == null:
		return
	_refs.unit_tooltip.reset_size()
	var viewport_size: Vector2 = _scene_root.get_viewport().get_visible_rect().size
	var desired: Vector2 = screen_pos + Vector2(16.0, 16.0)
	var tooltip_size: Vector2 = _refs.unit_tooltip.size
	if desired.x + tooltip_size.x > viewport_size.x - 8.0:
		desired.x = screen_pos.x - tooltip_size.x - 16.0
	if desired.y + tooltip_size.y > viewport_size.y - 8.0:
		desired.y = screen_pos.y - tooltip_size.y - 16.0
	# 最终再统一 clamp，确保左右翻转后也不会被屏幕边界裁掉。
	desired.x = clampf(desired.x, 8.0, viewport_size.x - tooltip_size.x - 8.0)
	desired.y = clampf(desired.y, 8.0, viewport_size.y - tooltip_size.y - 8.0)
	_refs.unit_tooltip.position = desired
	_refs.unit_tooltip.visible = true


# 从槽位行 hover 到物品 tooltip 时，统一先检查当前是否正在拖拽 GUI 项。
# 拖拽期间禁止弹 tooltip，否则 bridge 区会把拖放反馈盖住。
func on_item_row_hover_entered(row_panel: Control) -> void:
	if _scene_root.get_viewport().gui_is_dragging():
		if _refs.item_tooltip != null:
			_refs.item_tooltip.visible = false
		_support.clear_item_hover_state()
		return
	if row_panel == null or not is_instance_valid(row_panel):
		return
	var payload: Variant = row_panel.get_meta("item_data", {})
	if not (payload is Dictionary):
		return
	if (payload as Dictionary).is_empty():
		return
	on_item_source_hover_entered(row_panel, payload as Dictionary)


# 记录当前物品 hover 来源和 payload，真正显示延迟到逐帧更新里处理。
# payload 先做 duplicate，避免外部 later mutation 把 tooltip 内容改脏。
func on_item_source_hover_entered(source: Control, payload: Dictionary) -> void:
	if _scene_root.get_viewport().gui_is_dragging():
		if _refs.item_tooltip != null:
			_refs.item_tooltip.visible = false
		_support.clear_item_hover_state()
		return
	_state.item_hover_source = source
	_state.item_hover_data = payload.duplicate(true)
	# hover 与 fade 计时都从 0 重新开始，避免从上一个来源继承剩余时间。
	_state.item_hover_timer = 0.0
	_state.item_fade_timer = 0.0


# 鼠标离开来源后只重置 hover 计时，不立即清空 bridge 保护区。
# 这样鼠标能从来源平滑移动到 tooltip，不会因为瞬时离开就闪烁。
func on_item_source_hover_exited(source: Control) -> void:
	if _state.item_hover_source != source:
		return
	_state.item_hover_timer = 0.0
	_state.item_fade_timer = 0.0


# 以统一悬停延迟和 bridge 判定维护物品 tooltip 的显示与隐藏。
# 这里同时管理进入延迟和离开淡出，确保所有物品来源的手感一致。
func update_item_tooltip_hover(delta: float) -> void:
	if _refs.item_tooltip == null:
		return
	if _scene_root.get_viewport().gui_is_dragging():
		_refs.item_tooltip.visible = false
		_support.clear_item_hover_state()
		return
	var source_valid: bool = (
		_state.item_hover_source != null and is_instance_valid(_state.item_hover_source)
	)
	if not source_valid:
		return
	# source、tooltip、bridge 三块区域共同构成“允许保持显示”的悬停范围。
	var mouse: Vector2 = _scene_root.get_viewport().get_mouse_position()
	var in_source: bool = _state.item_hover_source.get_global_rect().has_point(mouse)
	var in_tooltip: bool = false
	if _refs.item_tooltip.visible:
		in_tooltip = _refs.item_tooltip.get_global_rect().has_point(mouse)
	var in_bridge: bool = false
	if _refs.item_tooltip.visible:
		in_bridge = calc_bridge_rect(_state.item_hover_source, _refs.item_tooltip, 8.0).has_point(mouse)
	if in_source:
		_state.item_hover_timer += delta
		# 进入阈值后再真正显示，避免鼠标扫过一排条目时不断闪 tooltip。
		if _state.item_hover_timer >= 0.2:
			show_item_tooltip(_state.item_hover_data, _state.item_hover_source)
		_state.item_fade_timer = 0.0
		return
	if in_tooltip or in_bridge:
		# 鼠标已经进到 tooltip 或 bridge，就继续保持显示，不重置来源。
		_state.item_fade_timer = 0.0
		return
	# 只有完全离开这三块区域并超过淡出阈值，才真正隐藏 tooltip。
	_state.item_fade_timer += delta
	if _state.item_fade_timer < 0.2:
		return
	_refs.item_tooltip.visible = false
	_support.clear_item_hover_state()


# 把统一 payload 投影到物品 tooltip 节点树中。
# detail、inventory、shop 都先构造 payload，再复用这一套渲染逻辑。
func show_item_tooltip(payload: Dictionary, source: Control) -> void:
	if _refs.item_tooltip == null:
		return
	if payload.is_empty():
		_refs.item_tooltip.visible = false
		return
	# 基础描述区先覆盖，技能区再按 has_skill 决定是否展开。
	# payload 字段缺失时统一走默认文案，避免单个条目把整个 tooltip 打空。
	if _refs.item_tooltip_name != null:
		_refs.item_tooltip_name.text = str(payload.get("name", "未知条目"))
	if _refs.item_tooltip_type != null:
		_refs.item_tooltip_type.text = str(payload.get("type_line", ""))
	if _refs.item_tooltip_desc != null:
		_refs.item_tooltip_desc.text = str(payload.get("desc", ""))
	# effect 列表和 skill_effect 列表都采用全量重建，避免残留上一个条目的多余行。
	if _refs.item_tooltip_effects != null:
		for child in _refs.item_tooltip_effects.get_children():
			child.queue_free()
		var effect_lines: Array = payload.get("effects", [])
		if effect_lines.is_empty():
			var empty_label := Label.new()
			empty_label.text = "· 无"
			_refs.item_tooltip_effects.add_child(empty_label)
		else:
			for line_value in effect_lines:
				var line := Label.new()
				line.text = "· %s" % str(line_value)
				_refs.item_tooltip_effects.add_child(line)
	if _refs.item_tooltip_skill_effects != null:
		for child in _refs.item_tooltip_skill_effects.get_children():
			child.queue_free()
	var has_skill: bool = bool(payload.get("has_skill", false))
	if _refs.item_tooltip_skill_section != null:
		_refs.item_tooltip_skill_section.visible = has_skill
	if has_skill:
		if _refs.item_tooltip_skill_trigger != null:
			_refs.item_tooltip_skill_trigger.text = str(payload.get("skill_trigger", "触发：-"))
		if _refs.item_tooltip_skill_effects != null:
			for line_value in payload.get("skill_effects", []):
				var line := Label.new()
				line.text = "· %s" % str(line_value)
				_refs.item_tooltip_skill_effects.add_child(line)
	# reset_size 放在最后，确保技能区显隐和内容变更都已计入最终尺寸。
	_refs.item_tooltip.reset_size()
	position_item_tooltip(source)
	_refs.item_tooltip.visible = true


# 把物品 tooltip 放到来源控件右侧或左侧，并限制在视口内。
# 物品 tooltip 相对来源控件定位，而不是跟鼠标跑，能减少读文本时的抖动。
func position_item_tooltip(source: Control) -> void:
	if _refs.item_tooltip == null:
		return
	if source == null or not is_instance_valid(source):
		return
	var viewport_size: Vector2 = _scene_root.get_viewport().get_visible_rect().size
	var source_rect: Rect2 = source.get_global_rect()
	var desired: Vector2 = source_rect.position + Vector2(source_rect.size.x + 10.0, 0.0)
	var tooltip_size: Vector2 = _refs.item_tooltip.size
	if desired.x + tooltip_size.x > viewport_size.x - 8.0:
		desired.x = source_rect.position.x - tooltip_size.x - 10.0
	# 纵向没有左右翻面概念，所以只做底边兜底和最终 clamp。
	if desired.y + tooltip_size.y > viewport_size.y - 8.0:
		desired.y = viewport_size.y - tooltip_size.y - 8.0
	desired.x = clampf(desired.x, 8.0, viewport_size.x - tooltip_size.x - 8.0)
	desired.y = clampf(desired.y, 8.0, viewport_size.y - tooltip_size.y - 8.0)
	_refs.item_tooltip.position = desired


# 构造来源控件与 tooltip 之间的桥接区域，避免鼠标移过去时闪烁。
# bridge 用 merge + grow 生成，逻辑比手写方向分支更稳定。
func calc_bridge_rect(source: Control, tooltip: Control, padding: float) -> Rect2:
	if source == null or tooltip == null:
		return Rect2()
	if not is_instance_valid(source) or not is_instance_valid(tooltip):
		return Rect2()
	return source.get_global_rect().merge(tooltip.get_global_rect()).grow(padding)


# 详情关闭按钮统一走同一关闭口径，保持 tooltip 与状态一起清理。
# 所有关闭入口都尽量汇到 force_close_detail_panel，减少状态分叉。
func on_detail_close_pressed() -> void:
	force_close_detail_panel(true)


# 详情面板拖拽只维护位置与拖拽偏移，不处理内容更新。
# 拖拽句柄只改 panel 位置，hover 和详情数据仍由其他逻辑继续维护。
func on_detail_drag_handle_gui_input(event: InputEvent) -> void:
	if not _state.detail_visible:
		return
	if not _support.is_valid_unit(_state.detail_unit):
		return
	if _refs.unit_detail_panel == null:
		return
	# 这里不 clamp 面板位置，让玩家可以把详情拖到自己顺手的位置。
	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton
		if mouse_button.button_index != MOUSE_BUTTON_LEFT:
			return
		if mouse_button.pressed:
			var mouse_screen: Vector2 = _scene_root.get_viewport().get_mouse_position()
			if _refs.detail_close_button != null:
				if _refs.detail_close_button.get_global_rect().has_point(mouse_screen):
					return
			# 点击关闭按钮区域时不进入拖拽，避免一次按下同时触发关闭和挪动。
			_state.is_dragging_detail_panel = true
			_state.detail_drag_offset = mouse_screen - _refs.unit_detail_panel.position
			return
		_state.is_dragging_detail_panel = false
		return
	if event is InputEventMouseMotion and _state.is_dragging_detail_panel:
		# 拖拽中的实时跟随只改 panel 位置，不触发额外刷新，避免性能抖动。
		_refs.unit_detail_panel.position = (
			_scene_root.get_viewport().get_mouse_position() - _state.detail_drag_offset
		)


