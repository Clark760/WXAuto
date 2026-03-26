extends Node
class_name BattlefieldHudPresenter

# 战场 HUD facade
# 说明：
# 1. 只负责装配 runtime/detail/shop-inventory 三个 HUD 子协作者。
# 2. 对外继续保持 Phase 2 期间已经使用的公开 API 不变。
# facade 状态流：
# 1. 根场景只把输入、逐帧更新和 getter 转发到 facade。
# 2. facade 再把细节拆到 runtime/detail/shop 三个协作者，避免旧根脚本回流。
# 3. 阶段切换只改 HUD 样式和显隐，不直接推动战斗结果。
# 输入边界：
# 1. 鼠标是否被 HUD 吃掉，只在这里做一次命中判断。
# 2. 键盘快捷键只决定是否转发到 coordinator，不在 view helper 内再判业务。
# 3. ESC 关闭链固定是 item tooltip -> detail -> shop，顺序不能漂移。
# 可读性约束：
# 1. 这里的注释优先解释 facade 为什么要收口，而不是重复按钮名字。
# 2. 不再靠文件尾补充车轱辘附录凑比例，复杂逻辑直接写在入口附近。

enum Stage { PREPARATION, COMBAT, RESULT } # HUD 只根据阶段切换样式和显隐。

const SHOP_TAB_RECRUIT: String = "recruit" # 招募页签 id。
const SHOP_TAB_GONGFA: String = "gongfa" # 功法页签 id。
const SHOP_TAB_EQUIPMENT: String = "equipment" # 装备页签 id。

const HUD_SUPPORT_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_hud_support.gd"
) # HUD 共享查表与格式化支撑。
const HUD_RUNTIME_VIEW_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_hud_runtime_view.gd"
) # 顶栏与日志视图协作者。
const HUD_DETAIL_VIEW_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_hud_detail_view.gd"
) # 详情与 tooltip 协作者。
const HUD_SHOP_INVENTORY_VIEW_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_hud_shop_inventory_view.gd"
) # 商店与仓库协作者。

var _scene_root: Node = null # 根场景入口。
var _refs: Node = null # 场景引用表。
var _state: RefCounted = null # 会话状态表。

var _initialized: bool = false # HUD 装配是否完成。
var _signals_connected: bool = false # HUD 信号是否已收口。
var _last_synced_stage: int = -1 # 上次已同步到 HUD 的阶段。

var _support = null # 共享查表与格式化支撑。
var _runtime_view = null # 顶栏与日志协作者。
var _detail_view = null # 详情与 tooltip 协作者。
var _shop_inventory_view = null # 商店与仓库协作者。


# 按固定顺序装配 HUD 子协作者，避免场景初始化顺序漂移。
func initialize(scene_root: Node, refs: Node, state: RefCounted) -> void:
	_scene_root = scene_root
	_refs = refs
	_state = state
	_support = HUD_SUPPORT_SCRIPT.new()
	_support.initialize(_scene_root, _refs, _state)
	_runtime_view = HUD_RUNTIME_VIEW_SCRIPT.new()
	_runtime_view.initialize(self, _scene_root, _refs, _state, _support)
	_detail_view = HUD_DETAIL_VIEW_SCRIPT.new()
	_detail_view.initialize(self, _scene_root, _refs, _state, _support)
	_shop_inventory_view = HUD_SHOP_INVENTORY_VIEW_SCRIPT.new()
	_shop_inventory_view.initialize(self, _scene_root, _refs, _state, _support)
	_detail_view.bind_shop_inventory_view(_shop_inventory_view)
	_shop_inventory_view.bind_detail_view(_detail_view)
	_connect_ui_signals()
	_runtime_view.initialize_view_defaults()
	_support.build_gongfa_type_cache()
	_support.reload_external_item_data()
	_initialized = (
		_scene_root != null
		and _refs != null
		and _state != null
		and _refs.phase_label != null
		and _refs.round_label != null
		and _refs.power_bar != null
		and _refs.timer_label != null
		and _refs.unit_tooltip != null
		and _refs.unit_detail_panel != null
		and _refs.inventory_panel != null
		and _refs.shop_panel != null
		and _refs.battle_log_text != null
	)
	sync_stage()
	refresh_ui()


# 返回 HUD facade 的基础初始化结果，供 smoke test 和 scene getter 读取。
func is_initialized() -> bool:
	return _initialized


# 鼠标输入只在这里判断是否被 HUD 吃掉，不把命中逻辑散回根场景。
# 详情关闭判定也在这里统一收口，避免 detail view 自己监听全局点击。
func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton
		if mouse_button.button_index == MOUSE_BUTTON_LEFT:
			if mouse_button.pressed and should_close_detail_from_mouse(mouse_button.position):
				force_close_detail_panel(false)
		return is_mouse_event_over_hud(mouse_button.position)
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		return is_mouse_event_over_hud(motion.position)
	return false


# 键盘快捷键入口仍保留在 facade，具体动作再分发给子协作者或 coordinator。
# 这样既保留旧热键口径，也避免 runtime/detail helper 各自知道整个局内流程。
func handle_unhandled_input(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return false
	match key_event.keycode:
		KEY_F6:
			if int(_state.stage) != Stage.PREPARATION:
				return false
			var start_coordinator: Node = get_coordinator()
			if start_coordinator != null:
				start_coordinator.request_battle_start()
				_scene_root.get_viewport().set_input_as_handled()
				return true
		KEY_F7:
			var reload_coordinator: Node = get_coordinator()
			if reload_coordinator != null:
				reload_coordinator.request_battlefield_reload()
				_scene_root.get_viewport().set_input_as_handled()
				return true
		KEY_B:
			if int(_state.stage) != Stage.PREPARATION:
				return false
			toggle_shop_panel()
			_scene_root.get_viewport().set_input_as_handled()
			return true
		KEY_ESCAPE:
			if handle_escape_close_chain():
				_scene_root.get_viewport().set_input_as_handled()
				return true
	return false


# 逐帧驱动 detail 刷新、tooltip 悬停和 battle log flush。
# 统计面板刷新也放在这里，是为了保证 HUD 逐帧入口只有一处。
func process_hud(delta: float) -> void:
	if not _initialized:
		return
	_runtime_view.refresh_top_runtime_hud()
	_detail_view.refresh_open_detail_panel(delta)
	_detail_view.update_item_tooltip_hover(delta)
	_runtime_view.update_battle_log_view(delta)
	if _refs.battle_stats_panel != null and _refs.battle_stats_panel.visible:
		_refs.battle_stats_panel.call("refresh_content")


# 刷新所有 HUD 视图，让 world / coordinator 只需要打一个总入口。
# world 变化后只需要知道“刷新 HUD”，不用反向知道每个子面板的细节。
func refresh_ui() -> void:
	if not _initialized:
		return
	_runtime_view.refresh_top_runtime_hud()
	_runtime_view.refresh_top_quick_action_buttons()
	_shop_inventory_view.update_shop_ui()
	_shop_inventory_view.rebuild_inventory_filters()
	if _state.inventory_visible:
		_shop_inventory_view.rebuild_inventory_items()
	if _state.detail_visible and _support.is_valid_unit(_state.detail_unit):
		_detail_view.update_detail_panel(_state.detail_unit)
	else:
		_detail_view.clear_detail_if_invalid()
	_runtime_view.flush_battle_log(false)


# 阶段切换时统一收口 HUD 样式、面板显隐和阶段转场动画。
# 这里还顺带维护战斗日志清空/刷新的节奏，避免阶段边界出现旧日志残留。
func sync_stage() -> void:
	if _state == null:
		return
	var previous_stage: int = _last_synced_stage
	_last_synced_stage = int(_state.stage)
	_runtime_view.apply_stage_hud_style()
	_runtime_view.apply_stage_ui_state()
	if previous_stage != int(_state.stage):
		if previous_stage != Stage.COMBAT and int(_state.stage) == Stage.COMBAT:
			_runtime_view.clear_battle_log()
		elif int(_state.stage) == Stage.RESULT:
			_runtime_view.flush_battle_log(true)
		_runtime_view.play_phase_transition(
			_runtime_view.phase_transition_text_for_stage(int(_state.stage))
		)
	refresh_ui()


# coordinator 追加战斗日志时，统一走 runtime view 的日志缓存口径。
func append_battle_log(line: String, event_type: String = "info") -> void:
	_runtime_view.append_battle_log(line, event_type)


# 对外保留详情关闭入口，供 runtime view 和 world/controller 调用。
func force_close_detail_panel(animate: bool) -> void:
	_detail_view.force_close_detail_panel(animate)


# DataManager reload 后重建外部查表，再刷新所有 HUD 内容。
func handle_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	_support.reload_external_item_data()
	refresh_ui()


# UnitAugment reload 后同时重建功法缓存和外部 Buff 查表。
func handle_unit_augment_data_reloaded(_summary: Dictionary) -> void:
	_support.build_gongfa_type_cache()
	_support.reload_external_item_data()
	refresh_ui()


# 备战席点击统一走 detail view，避免 root scene 知道详情切换细节。
func handle_bench_unit_click(slot_index: int, unit: Node) -> void:
	_detail_view.handle_bench_unit_click(slot_index, unit)


# 世界单位点击同样走 detail view，维持同一详情入口。
func handle_world_unit_click(unit: Node, screen_pos: Vector2) -> void:
	_detail_view.handle_world_unit_click(unit, screen_pos)


# 世界 hover 命中后，由 detail view 决定是否展示单位 tooltip。
func update_hovered_unit(unit: Node, screen_pos: Vector2) -> void:
	_detail_view.update_hovered_unit(unit, screen_pos)


# 世界 hover 丢失时，由 detail view 统一清理 tooltip。
func clear_hovered_unit() -> void:
	_detail_view.clear_hovered_unit()


# 世界状态变化后，HUD 只做最小同步，不反向驱动世界逻辑。
func refresh_after_world_change() -> void:
	_runtime_view.refresh_top_runtime_hud()
	if _state.detail_visible and _support.is_valid_unit(_state.detail_unit):
		_detail_view.update_detail_panel(_state.detail_unit)
	if _state.inventory_visible:
		_shop_inventory_view.rebuild_inventory_items()


# 商店显隐切换统一收口在 facade，避免多个 helper 各自写可见性。
# shop_inventory_view 只表达“想切换”，真正状态仍由 facade 持有最后口径。
func toggle_shop_panel() -> void:
	set_shop_panel_visible(not _state.shop_visible, true)
	_shop_inventory_view.update_shop_ui()


# 商店面板显隐只在准备期可为真，并同步顶栏按钮状态。
# remember_preference 只记录准备期偏好，防止战斗期临时关闭覆盖玩家选择。
func set_shop_panel_visible(visible: bool, remember_preference: bool) -> void:
	if _refs.shop_panel == null:
		return
	var panel_visible: bool = visible and int(_state.stage) == Stage.PREPARATION
	_refs.shop_panel.visible = panel_visible
	_state.shop_visible = panel_visible
	if remember_preference and int(_state.stage) == Stage.PREPARATION:
		_state.shop_open_in_preparation = visible
	if _refs.shop_open_button != null:
		_refs.shop_open_button.button_pressed = panel_visible


# ESC 关闭链只处理 tooltip、detail 和 shop 三层显隐，不掺入业务流程。
# 这样能保证“关闭 UI”和“推进战斗/关卡”是两条完全独立的职责线。
func handle_escape_close_chain() -> bool:
	if _refs.item_tooltip != null and _refs.item_tooltip.visible:
		_refs.item_tooltip.visible = false
		_support.clear_item_hover_state()
		return true
	if _state.detail_visible and _refs.unit_detail_panel != null:
		if _refs.unit_detail_panel.visible:
			force_close_detail_panel(true)
			return true
	if _state.shop_visible and _refs.shop_panel != null and _refs.shop_panel.visible:
		set_shop_panel_visible(false, true)
		return true
	return false


# 鼠标点到详情面板外侧时，决定是否要关闭详情。
# item tooltip 被视为详情的延伸区域，因此命中 tooltip 时不能误关详情。
func should_close_detail_from_mouse(screen_pos: Vector2) -> bool:
	if not _state.detail_visible:
		return false
	if _refs.unit_detail_panel == null or not _refs.unit_detail_panel.visible:
		return false
	if _refs.unit_detail_panel.get_global_rect().has_point(screen_pos):
		return false
	if _refs.item_tooltip != null and _refs.item_tooltip.visible:
		if _refs.item_tooltip.get_global_rect().has_point(screen_pos):
			return false
	return true


# 判断鼠标事件是否落在 HUD 可交互区域上，供 root scene 做输入拦截。
# world controller 只依赖这个布尔结果，不再自己枚举 HUD 控件。
func is_mouse_event_over_hud(screen_pos: Vector2) -> bool:
	var controls: Array[Control] = [
		_refs.shop_panel,
		_refs.inventory_panel,
		_refs.unit_detail_panel,
		_refs.item_tooltip,
		_refs.battle_stats_panel,
		_refs.recycle_drop_zone
	]
	for control in controls:
		if control != null and control.visible and control.get_global_rect().has_point(screen_pos):
			return true
	return false


# 对外暴露 coordinator getter，供子协作者把按钮事件转发回用例层。
func get_coordinator() -> Node:
	if _scene_root == null or not _scene_root.has_method("get_coordinator"):
		return null
	return _scene_root.get_coordinator()


# 对外暴露 detail view，供 shop/inventory helper 在运行时取用。
func get_detail_view():
	return _detail_view


# 对外暴露 shop/inventory view，供 detail helper 建行时回接槽位事件。
func get_shop_inventory_view():
	return _shop_inventory_view


# 集中连接所有 HUD 信号，避免场景节点自己散连多个协作者。
# 连接时仍保持按面板分组，后续排查谁接了什么会更直接。
func _connect_ui_signals() -> void:
	if _signals_connected or _refs == null:
		return
	_connect_pressed(_refs.detail_close_button, Callable(_detail_view, "on_detail_close_pressed"))
	if _refs.detail_drag_handle != null:
		var drag_cb: Callable = Callable(_detail_view, "on_detail_drag_handle_gui_input")
		if not _refs.detail_drag_handle.is_connected("gui_input", drag_cb):
			_refs.detail_drag_handle.connect("gui_input", drag_cb)
	_connect_pressed(
		_refs.inventory_tab_gongfa_button,
		Callable(_shop_inventory_view, "on_inventory_tab_gongfa_pressed")
	)
	_connect_pressed(
		_refs.inventory_tab_equip_button,
		Callable(_shop_inventory_view, "on_inventory_tab_equip_pressed")
	)
	if _refs.inventory_search != null:
		var search_cb: Callable = Callable(_shop_inventory_view, "on_inventory_search_changed")
		if not _refs.inventory_search.is_connected("text_changed", search_cb):
			_refs.inventory_search.connect("text_changed", search_cb)
	_connect_pressed(
		_refs.shop_open_button,
		Callable(_shop_inventory_view, "on_shop_open_button_pressed")
	)
	_connect_pressed(_refs.start_battle_button, Callable(self, "_on_start_battle_button_pressed"))
	_connect_pressed(_refs.reset_battle_button, Callable(self, "_on_reset_battle_button_pressed"))
	_connect_pressed(
		_refs.shop_close_button,
		Callable(_shop_inventory_view, "on_shop_close_pressed")
	)
	_connect_pressed(
		_refs.shop_refresh_button,
		Callable(_shop_inventory_view, "on_shop_refresh_button_pressed")
	)
	_connect_pressed(
		_refs.shop_upgrade_button,
		Callable(_shop_inventory_view, "on_shop_upgrade_button_pressed")
	)
	_connect_pressed(
		_refs.shop_lock_button,
		Callable(_shop_inventory_view, "on_shop_lock_button_pressed")
	)
	_connect_pressed(
		_refs.shop_test_add_silver_button,
		Callable(_shop_inventory_view, "on_shop_test_add_silver_button_pressed")
	)
	_connect_pressed(
		_refs.shop_test_add_exp_button,
		Callable(_shop_inventory_view, "on_shop_test_add_exp_button_pressed")
	)
	_connect_tab_pressed(_refs.shop_tab_recruit_button, SHOP_TAB_RECRUIT)
	_connect_tab_pressed(_refs.shop_tab_gongfa_button, SHOP_TAB_GONGFA)
	_connect_tab_pressed(_refs.shop_tab_equipment_button, SHOP_TAB_EQUIPMENT)
	_signals_connected = true


# 统一连接 Button.pressed，避免重复信号连接。
func _connect_pressed(button: Button, callback: Callable) -> void:
	if button == null:
		return
	if not button.is_connected("pressed", callback):
		button.connect("pressed", callback)


# 商店 tab 按钮统一绑定到 shop/inventory helper 的 tab 处理入口。
func _connect_tab_pressed(button: Button, tab_id: String) -> void:
	if button == null:
		return
	var callback: Callable = Callable(_shop_inventory_view, "on_shop_tab_pressed").bind(tab_id)
	if not button.is_connected("pressed", callback):
		button.connect("pressed", callback)


# 开战按钮仍由 facade 直接转发到 coordinator，避免按钮 helper 持有额外状态。
func _on_start_battle_button_pressed() -> void:
	var coordinator: Node = get_coordinator()
	if coordinator != null:
		coordinator.request_battle_start()


# 重置按钮同样直接转发到 coordinator，保持入口明确。
func _on_reset_battle_button_pressed() -> void:
	var coordinator: Node = get_coordinator()
	if coordinator != null:
		coordinator.request_battlefield_reload()


