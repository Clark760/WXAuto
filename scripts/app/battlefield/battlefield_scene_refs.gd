extends Node
class_name BattlefieldSceneRefs

# Phase 3 scene-first 子场景库（Batch 1）
# 说明：
# 1. 统一在 refs 暴露可复用 UI 组件资源，避免协作者各自硬编码路径。
# 2. Batch 1 只建立入口，不改现有 HUD 渲染行为。
const UI_SCENE_LIBRARY: Dictionary = {
	"inventory_item_card": preload("res://scenes/ui/inventory_item_card.tscn"),
	"shop_offer_card": preload("res://scenes/ui/shop_offer_card.tscn"),
	"inventory_filter_button": preload("res://scenes/ui/inventory_filter_button.tscn"),
	"gongfa_slot_row": preload("res://scenes/ui/gongfa_slot_row.tscn"),
	"equipment_slot_row": preload("res://scenes/ui/equipment_slot_row.tscn"),
	"unit_tooltip_gongfa_row": preload("res://scenes/ui/unit_tooltip_gongfa_row.tscn"),
	"item_tooltip_effect_row": preload("res://scenes/ui/item_tooltip_effect_row.tscn"),
	"recycle_drop_zone": preload("res://scenes/ui/recycle_drop_zone.tscn"),
	"battle_stats_panel": preload("res://scenes/ui/battle_stats_panel.tscn")
}

const REQUIRED_UI_SCENE_IDS: Array[String] = [
	"inventory_item_card",
	"shop_offer_card",
	"inventory_filter_button",
	"gongfa_slot_row",
	"equipment_slot_row",
	"unit_tooltip_gongfa_row",
	"item_tooltip_effect_row",
	"recycle_drop_zone",
	"battle_stats_panel"
]

# 战场场景引用表
# 说明：
# 1. 统一收口战场入口需要的显式节点和服务引用。
# 2. 其他协作者只能通过 refs 取依赖，不再四处写节点路径。
# 3. Phase 2 的新入口不允许在协作者内部重新定义节点路径常量。

# 场景根引用：只允许 Batch 1 根场景在这里写入一次。
var scene_root: Node = null # 新入口根场景，负责首次收集整棵战场引用。
var _services: ServiceRegistry = null

# 世界与战斗核心节点。
var world_container: Node2D = null # 世界根容器，统一承接缩放和平移。
var hex_grid: Node = null # 棋盘坐标与世界坐标转换入口。
var deploy_overlay: Node2D = null # 部署区可视覆盖层。
var unit_layer: Node2D = null # 战场单位真实挂载层。
var multimesh_renderer: Node2D = null # 棋盘批量渲染节点。
var vfx_factory: Node2D = null # 战斗特效创建入口。
var unit_factory: Node = null # 单位创建与回收入口。
var combat_manager: Node = null # 战斗运行时主协调器。
var unit_augment_manager: Node = null # 功法与装备数据查询入口。

# 顶层 CanvasLayer 组。
var hud_layer: CanvasLayer = null # 顶栏和日志所在层。
var shop_panel_layer: CanvasLayer = null # 商店面板所在层。
var tooltip_layer: CanvasLayer = null # 物品和单位 tooltip 所在层。
var detail_layer: CanvasLayer = null # 详情面板和结果面板所在层。
var bottom_layer: CanvasLayer = null # 备战席、拖拽预览和回收区所在层。
var debug_layer: CanvasLayer = null # 临时调试文案层。

# 底栏与调试节点。
var bottom_panel: PanelContainer = null # 底栏根容器。
var bench_ui: Node = null # 备战席控件本体。
var toggle_button: Button = null # 底栏展开/收起按钮。
var drag_preview: PanelContainer = null # 世界拖拽预览卡容器。
var drag_preview_icon: ColorRect = null # 预览卡品质色块。
var drag_preview_name: Label = null # 预览卡名称文案。
var debug_label: Label = null # 战场最小调试状态输出。
var recycle_drop_zone: PanelContainer = null # 回收区运行时挂载点。

# 顶栏与战斗日志。
var phase_label: Label = null # 顶栏阶段标签。
var round_label: Label = null # 顶栏回合标签。
var power_bar: ProgressBar = null # 顶栏战力对比条。
var timer_label: Label = null # 顶栏计时与 FPS 文案。
var phase_transition: CenterContainer = null # 阶段切换过场容器。
var phase_transition_text: Label = null # 阶段切换过场文案。
var battle_log_panel: PanelContainer = null # 战斗日志面板根节点。
var battle_log_text: RichTextLabel = null # 战斗日志富文本节点。

# 单位 tooltip 节点。
var unit_tooltip: PanelContainer = null # 单位悬停提示根容器。
var tooltip_header_name: Label = null # 单位 tooltip 名称。
var tooltip_quality_badge: ColorRect = null # 单位 tooltip 品质色块。
var tooltip_hp_bar: ProgressBar = null # 单位血量条。
var tooltip_hp_text: Label = null # 单位血量文案。
var tooltip_mp_bar: ProgressBar = null # 单位内力条。
var tooltip_mp_text: Label = null # 单位内力文案。
var tooltip_atk_label: Label = null # tooltip 攻击属性。
var tooltip_def_label: Label = null # tooltip 防御属性。
var tooltip_iat_label: Label = null # tooltip 内攻属性。
var tooltip_idr_label: Label = null # tooltip 内防属性。
var tooltip_spd_label: Label = null # tooltip 速度属性。
var tooltip_rng_label: Label = null # tooltip 射程属性。
var tooltip_gongfa_list: VBoxContainer = null # tooltip 功法列表。
var tooltip_buff_list: HBoxContainer = null # tooltip Buff 列表。
var tooltip_status_label: Label = null # tooltip 状态摘要。

# 详情、仓库与物品 tooltip 节点。
var unit_detail_mask: ColorRect = null # 详情面板遮罩层。
var unit_detail_panel: PanelContainer = null # 角色详情主面板。
var detail_drag_handle: HBoxContainer = null # 详情面板拖拽把手。
var detail_close_button: Button = null # 详情面板关闭按钮。
var detail_title: Label = null # 详情面板标题。
var detail_tab_overview_button: Button = null # 详情-属性装备页签按钮。
var detail_tab_linkage_button: Button = null # 详情-联动特效页签按钮。
var detail_overview_content: HBoxContainer = null # 详情-属性装备内容区。
var detail_linkage_content: VBoxContainer = null # 详情-联动特效内容区。
var detail_linkage_text: RichTextLabel = null # 详情-联动特效实时文本。
var detail_portrait_color: ColorRect = null # 详情立绘色块占位。
var detail_name_label: Label = null # 详情角色名。
var detail_quality_label: Label = null # 详情品质标签。
var detail_stats_value_label: Label = null # 详情基础属性文案。
var detail_bonus_value_label: Label = null # 详情加成属性文案。
var detail_slot_list: VBoxContainer = null # 功法槽列表容器。
var detail_equip_slot_list: VBoxContainer = null # 装备槽列表容器。
var item_tooltip: PanelContainer = null # 物品 tooltip 根容器。
var item_tooltip_name: Label = null # 物品 tooltip 名称。
var item_tooltip_type: Label = null # 物品 tooltip 类型。
var item_tooltip_desc: RichTextLabel = null # 物品 tooltip 描述。
var item_tooltip_effects: VBoxContainer = null # 物品主效果列表。
var item_tooltip_skill_section: VBoxContainer = null # 物品技能区块。
var item_tooltip_skill_trigger: Label = null # 物品技能触发条件。
var item_tooltip_skill_effects: VBoxContainer = null # 物品技能效果列表。

var inventory_panel: PanelContainer = null # 仓库面板根节点。
var inventory_title: Label = null # 仓库标题。
var inventory_filter_row: HBoxContainer = null # 仓库筛选按钮行。
var inventory_search: LineEdit = null # 仓库搜索框。
var inventory_grid: VBoxContainer = null # 仓库条目列表容器。
var inventory_summary: Label = null # 仓库摘要文案。
var inventory_tab_gongfa_button: Button = null # 功法页签按钮。
var inventory_tab_equip_button: Button = null # 装备页签按钮。

# 商店与快捷操作节点。
var shop_panel: PanelContainer = null # 商店主面板。
var shop_open_button: Button = null # 顶栏打开商店按钮。
var start_battle_button: Button = null # 顶栏开战按钮。
var reset_battle_button: Button = null # 顶栏重开战场按钮。
var shop_status_label: Label = null # 商店阶段提示文案。
var shop_close_button: Button = null # 商店关闭按钮。
var shop_tab_recruit_button: Button = null # 招募页签按钮。
var shop_tab_gongfa_button: Button = null # 功法页签按钮。
var shop_tab_equipment_button: Button = null # 装备页签按钮。
var shop_offer_row: HBoxContainer = null # 商店商品卡容器。
var shop_silver_label: Label = null # 当前银两文案。
var shop_level_label: Label = null # 门派等级与部署上限文案。
var shop_refresh_button: Button = null # 刷新商店按钮。
var shop_upgrade_button: Button = null # 商店升级按钮。
var shop_lock_button: Button = null # 锁店按钮。
var shop_test_add_silver_button: Button = null # 调试加银两按钮。
var shop_test_add_exp_button: Button = null # 调试加经验按钮。

# 显式运行时节点。
var runtime_economy_manager: Node = null # 经济运行时服务。
var runtime_shop_manager: Node = null # 商店运行时服务。
var runtime_stage_manager: Node = null # 关卡推进运行时服务。
var runtime_unit_deploy_manager: Node = null # 部署规则运行时服务。
var runtime_drag_controller: Node = null # 世界拖拽运行时服务。
var runtime_battlefield_renderer: Node = null # 世界渲染运行时服务。
var battle_stats_panel: PanelContainer = null # 结果统计面板节点。


# 根场景只在这里做一次引用采集，后续扩展也必须从这个入口走。
func bind_app_services(services: ServiceRegistry) -> void:
	_services = services


# 统一暴露 DataRepository，避免协作者绕开服务注册表。
func get_data_repository() -> Node:
	if _services == null:
		return null
	return _services.data_repository


# 统一暴露 RuntimeProbe，避免协作者重新回流到根场景或服务定位。
func get_runtime_probe():
	if _services == null:
		return null
	return _services.runtime_probe


# 根场景只在这里做一次引用采集，后续扩展也必须从这个入口走。
func bind_from_scene(scene_root_value: Node) -> void:
	scene_root = scene_root_value
	_bind_world_refs(scene_root_value)
	_bind_layer_refs(scene_root_value)
	_bind_bottom_refs(scene_root_value)
	_bind_top_hud_refs(scene_root_value)
	_bind_unit_tooltip_refs(scene_root_value)
	_bind_detail_refs(scene_root_value)
	_bind_inventory_refs(scene_root_value)
	_bind_shop_refs(scene_root_value)
	_bind_runtime_refs(scene_root_value)


# 世界层只认这里收集到的显式节点，不允许各协作者再自写路径。
func _bind_world_refs(scene_root_value: Node) -> void:
	world_container = scene_root_value.get_node_or_null("WorldContainer") as Node2D
	hex_grid = scene_root_value.get_node_or_null("WorldContainer/HexGrid")
	deploy_overlay = scene_root_value.get_node_or_null(
		"WorldContainer/HexGrid/DeployZoneOverlay"
	) as Node2D
	unit_layer = scene_root_value.get_node_or_null("WorldContainer/UnitLayer") as Node2D
	multimesh_renderer = scene_root_value.get_node_or_null(
		"WorldContainer/UnitLayer/UnitMultiMeshRenderer"
	) as Node2D
	vfx_factory = scene_root_value.get_node_or_null("WorldContainer/VfxLayer/VfxFactory") as Node2D
	unit_factory = scene_root_value.get_node_or_null("UnitFactory")
	combat_manager = scene_root_value.get_node_or_null("CombatManager")
	unit_augment_manager = _resolve_unit_augment_manager(scene_root_value)


# unit augment 只从服务注册表取，避免场景路径回流。
func _resolve_unit_augment_manager(_scene_root_value: Node) -> Node:
	if _services == null:
		return null
	return _services.unit_augment_manager


# 顶层 CanvasLayer 组只在这里采集一次，后续协作者统一通过 refs 读取。
func _bind_layer_refs(scene_root_value: Node) -> void:
	hud_layer = scene_root_value.get_node_or_null("HUDLayer") as CanvasLayer
	shop_panel_layer = scene_root_value.get_node_or_null("ShopPanelLayer") as CanvasLayer
	tooltip_layer = scene_root_value.get_node_or_null("TooltipLayer") as CanvasLayer
	detail_layer = scene_root_value.get_node_or_null("DetailLayer") as CanvasLayer
	bottom_layer = scene_root_value.get_node_or_null("BottomLayer") as CanvasLayer
	debug_layer = scene_root_value.get_node_or_null("DebugLayer") as CanvasLayer


# world controller 直接依赖的底栏、拖拽预览和调试节点集中收口在这里。
func _bind_bottom_refs(scene_root_value: Node) -> void:
	bottom_panel = scene_root_value.get_node_or_null("BottomLayer/BottomPanel") as PanelContainer
	bench_ui = scene_root_value.get_node_or_null("BottomLayer/BottomPanel/RootVBox/BenchArea")
	toggle_button = scene_root_value.get_node_or_null("BottomLayer/ToggleButton") as Button
	drag_preview = scene_root_value.get_node_or_null("BottomLayer/DragPreview") as PanelContainer
	drag_preview_icon = scene_root_value.get_node_or_null(
		"BottomLayer/DragPreview/PreviewVBox/Icon"
	) as ColorRect
	drag_preview_name = scene_root_value.get_node_or_null(
		"BottomLayer/DragPreview/PreviewVBox/Name"
	) as Label
	debug_label = scene_root_value.get_node_or_null("DebugLayer/DebugLabel") as Label


# 顶栏、阶段过场和战斗日志节点由 HUD facade 统一驱动。
func _bind_top_hud_refs(scene_root_value: Node) -> void:
	phase_label = scene_root_value.get_node_or_null("HUDLayer/TopBar/TopBarContent/PhaseLabel") as Label
	round_label = scene_root_value.get_node_or_null("HUDLayer/TopBar/TopBarContent/RoundLabel") as Label
	power_bar = scene_root_value.get_node_or_null("HUDLayer/TopBar/TopBarContent/PowerBar") as ProgressBar
	timer_label = scene_root_value.get_node_or_null("HUDLayer/TopBar/TopBarContent/TimerLabel") as Label
	phase_transition = scene_root_value.get_node_or_null("HUDLayer/PhaseTransition") as CenterContainer
	phase_transition_text = scene_root_value.get_node_or_null("HUDLayer/PhaseTransition/PhaseText") as Label
	battle_log_panel = scene_root_value.get_node_or_null("HUDLayer/BattleLogPanel") as PanelContainer
	battle_log_text = scene_root_value.get_node_or_null(
		"HUDLayer/BattleLogPanel/LogRoot/LogScroll/BattleLogText"
	) as RichTextLabel


# 单位 tooltip 节点集中采集，避免 detail helper 再次写死路径。
func _bind_unit_tooltip_refs(scene_root_value: Node) -> void:
	unit_tooltip = scene_root_value.get_node_or_null("HUDLayer/UnitTooltip") as PanelContainer
	tooltip_header_name = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/HeaderRow/HeaderName"
	) as Label
	tooltip_quality_badge = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/HeaderRow/QualityBadge"
	) as ColorRect
	tooltip_hp_bar = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/HPRow/HPBarRich"
	) as ProgressBar
	tooltip_hp_text = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/HPRow/HPText"
	) as Label
	tooltip_mp_bar = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/MPRow/MPBarRich"
	) as ProgressBar
	tooltip_mp_text = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/MPRow/MPText"
	) as Label
	tooltip_atk_label = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/AtkLabel"
	) as Label
	tooltip_def_label = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/DefLabel"
	) as Label
	tooltip_iat_label = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/IatLabel"
	) as Label
	tooltip_idr_label = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/IdrLabel"
	) as Label
	tooltip_spd_label = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/SpdLabel"
	) as Label
	tooltip_rng_label = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/RngLabel"
	) as Label
	tooltip_gongfa_list = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/GongfaList"
	) as VBoxContainer
	tooltip_buff_list = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/BuffList"
	) as HBoxContainer
	tooltip_status_label = scene_root_value.get_node_or_null(
		"HUDLayer/UnitTooltip/TooltipVBox/StatusLabel"
	) as Label


# 详情、物品 tooltip 与统计面板节点统一由这里采集。
func _bind_detail_refs(scene_root_value: Node) -> void:
	unit_detail_mask = scene_root_value.get_node_or_null("DetailLayer/UnitDetailMask") as ColorRect
	unit_detail_panel = scene_root_value.get_node_or_null("DetailLayer/UnitDetailPanel") as PanelContainer
	detail_drag_handle = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/HeaderRow"
	) as HBoxContainer
	detail_close_button = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/HeaderRow/DetailCloseButton"
	) as Button
	detail_title = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/HeaderRow/DetailTitle"
	) as Label
	detail_tab_overview_button = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/DetailTabRow/DetailTabOverviewButton"
	) as Button
	detail_tab_linkage_button = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/DetailTabRow/DetailTabLinkageButton"
	) as Button
	detail_overview_content = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow"
	) as HBoxContainer
	detail_linkage_content = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/DetailLinkageContent"
	) as VBoxContainer
	detail_linkage_text = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/DetailLinkageContent/DetailLinkageText"
	) as RichTextLabel
	detail_portrait_color = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/PortraitSection/PortraitColor"
	) as ColorRect
	detail_name_label = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/PortraitSection/DetailNameLabel"
	) as Label
	detail_quality_label = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/PortraitSection/DetailQualityLabel"
	) as Label
	detail_stats_value_label = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/StatsSection/StatsValueLabel"
	) as Label
	detail_bonus_value_label = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/StatsSection/BonusValueLabel"
	) as Label
	detail_slot_list = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/GongfaSection/SlotList"
	) as VBoxContainer
	detail_equip_slot_list = scene_root_value.get_node_or_null(
		"DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/GongfaSection/EquipSlotList"
	) as VBoxContainer
	item_tooltip = scene_root_value.get_node_or_null("DetailLayer/ItemTooltip") as PanelContainer
	item_tooltip_name = scene_root_value.get_node_or_null(
		"DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/ItemName"
	) as Label
	item_tooltip_type = scene_root_value.get_node_or_null(
		"DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/ItemType"
	) as Label
	item_tooltip_desc = scene_root_value.get_node_or_null(
		"DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/DescLabel"
	) as RichTextLabel
	item_tooltip_effects = scene_root_value.get_node_or_null(
		"DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/EffectsList"
	) as VBoxContainer
	item_tooltip_skill_section = scene_root_value.get_node_or_null(
		"DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/SkillSection"
	) as VBoxContainer
	item_tooltip_skill_trigger = scene_root_value.get_node_or_null(
		"DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/SkillSection/SkillTrigger"
	) as Label
	item_tooltip_skill_effects = scene_root_value.get_node_or_null(
		"DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/SkillSection/SkillEffects"
	) as VBoxContainer
	battle_stats_panel = scene_root_value.get_node_or_null("DetailLayer/BattleStatsPanel") as PanelContainer


# 仓库节点在这里单独采集，避免 inventory helper 继续碰路径常量。
func _bind_inventory_refs(scene_root_value: Node) -> void:
	inventory_panel = scene_root_value.get_node_or_null("InventoryLayer/InventoryPanel") as PanelContainer
	inventory_title = scene_root_value.get_node_or_null(
		"InventoryLayer/InventoryPanel/InventoryMargin/InventoryRoot/HeaderRow/InventoryTitle"
	) as Label
	inventory_filter_row = scene_root_value.get_node_or_null(
		"InventoryLayer/InventoryPanel/InventoryMargin/InventoryRoot/FilterRow"
	) as HBoxContainer
	inventory_search = scene_root_value.get_node_or_null(
		"InventoryLayer/InventoryPanel/InventoryMargin/InventoryRoot/SearchInput"
	) as LineEdit
	inventory_grid = scene_root_value.get_node_or_null(
		"InventoryLayer/InventoryPanel/InventoryMargin/InventoryRoot/InventoryScroll/InventoryGrid"
	) as VBoxContainer
	inventory_summary = scene_root_value.get_node_or_null(
		"InventoryLayer/InventoryPanel/InventoryMargin/InventoryRoot/FooterRow/InventorySummary"
	) as Label
	inventory_tab_gongfa_button = scene_root_value.get_node_or_null(
		"InventoryLayer/InventoryPanel/InventoryMargin/InventoryRoot/HeaderRow/InventoryTabGongfaButton"
	) as Button
	inventory_tab_equip_button = scene_root_value.get_node_or_null(
		"InventoryLayer/InventoryPanel/InventoryMargin/InventoryRoot/HeaderRow/InventoryTabEquipButton"
	) as Button


# 商店节点和顶栏快捷按钮统一由这里收口。
func _bind_shop_refs(scene_root_value: Node) -> void:
	shop_panel = scene_root_value.get_node_or_null("ShopPanelLayer/ShopPanel") as PanelContainer
	shop_open_button = scene_root_value.get_node_or_null(
		"HUDLayer/TopBar/TopBarContent/ShopOpenButton"
	) as Button
	start_battle_button = scene_root_value.get_node_or_null(
		"HUDLayer/TopBar/TopBarContent/StartBattleButton"
	) as Button
	reset_battle_button = scene_root_value.get_node_or_null(
		"HUDLayer/TopBar/TopBarContent/ResetBattleButton"
	) as Button
	shop_status_label = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/HeaderRow/ShopStatus"
	) as Label
	shop_close_button = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/HeaderRow/ShopCloseButton"
	) as Button
	shop_tab_recruit_button = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/TabRow/RecruitTabButton"
	) as Button
	shop_tab_gongfa_button = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/TabRow/GongfaTabButton"
	) as Button
	shop_tab_equipment_button = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/TabRow/EquipmentTabButton"
	) as Button
	shop_offer_row = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/OfferRow"
	) as HBoxContainer
	shop_silver_label = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row1/ShopSilverLabel"
	) as Label
	shop_refresh_button = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row1/ShopRefreshButton"
	) as Button
	shop_test_add_silver_button = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row1/ShopTestAddSilverButton"
	) as Button
	shop_level_label = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row2/ShopLevelLabel"
	) as Label
	shop_upgrade_button = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row2/ShopUpgradeButton"
	) as Button
	shop_test_add_exp_button = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row2/ShopTestAddExpButton"
	) as Button
	shop_lock_button = scene_root_value.get_node_or_null(
		"ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row2/ShopLockButton"
	) as Button


# 显式 runtime 节点必须在场景树里可静态定位，不能回退成动态创建。
func _bind_runtime_refs(scene_root_value: Node) -> void:
	runtime_economy_manager = scene_root_value.get_node_or_null("RuntimeEconomyManager")
	runtime_shop_manager = scene_root_value.get_node_or_null("RuntimeShopManager")
	runtime_stage_manager = scene_root_value.get_node_or_null("RuntimeStageManager")
	runtime_unit_deploy_manager = scene_root_value.get_node_or_null("RuntimeUnitDeployManager")
	runtime_drag_controller = scene_root_value.get_node_or_null("RuntimeDragController")
	runtime_battlefield_renderer = scene_root_value.get_node_or_null("RuntimeBattlefieldRenderer")


# 这里只验证场景内必须显式存在的节点，不把 autoload 缺失混入结构烟测。
func has_required_scene_nodes() -> bool:
	return (
		scene_root != null
		and world_container != null
		and hex_grid != null
		and deploy_overlay != null
		and unit_layer != null
		and multimesh_renderer != null
		and vfx_factory != null
		and unit_factory != null
		and combat_manager != null
		and hud_layer != null
		and shop_panel_layer != null
		and tooltip_layer != null
		and detail_layer != null
		and bottom_layer != null
		and debug_layer != null
		and bottom_panel != null
		and bench_ui != null
		and toggle_button != null
		and drag_preview != null
		and drag_preview_icon != null
		and drag_preview_name != null
		and debug_label != null
	)


# 显式运行时节点必须全部存在；后续批次只允许继续扩展，不允许回退。
func has_required_runtime_nodes() -> bool:
	return (
		runtime_economy_manager != null
		and runtime_shop_manager != null
		and runtime_stage_manager != null
		and runtime_unit_deploy_manager != null
		and runtime_drag_controller != null
		and runtime_battlefield_renderer != null
		and battle_stats_panel != null
	)


# recycle 区在 Phase 2 仍沿用运行时创建，但引用必须统一回写到 refs。
func bind_recycle_drop_zone(node: PanelContainer) -> void:
	recycle_drop_zone = node


# 统一按 scene_id 返回可复用 UI 子场景。
func get_ui_scene(scene_id: String) -> PackedScene:
	var scene_value: Variant = UI_SCENE_LIBRARY.get(scene_id, null)
	if scene_value is PackedScene:
		return scene_value as PackedScene
	return null


# 快速存在性判断：供协作者在运行时做兜底分支。
func has_ui_scene(scene_id: String) -> bool:
	return get_ui_scene(scene_id) != null


# 返回稳定排序后的 scene_id 列表，便于测试断言与调试输出。
func get_ui_scene_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in UI_SCENE_LIBRARY.keys():
		ids.append(str(key))
	ids.sort()
	return ids


# Batch 1 资源完整性检查：后续 smoke test 可直接用这个入口验子场景是否齐全。
func has_required_ui_scene_assets() -> bool:
	for scene_id in REQUIRED_UI_SCENE_IDS:
		if get_ui_scene(scene_id) == null:
			return false
	return true


# UI 挂载点统一收口：后续 batch 直接消费该字典，不再散落节点路径。
func get_ui_mount_points() -> Dictionary:
	return {
		"shop_offer_row": shop_offer_row,
		"inventory_filter_row": inventory_filter_row,
		"inventory_grid": inventory_grid,
		"detail_slot_list": detail_slot_list,
		"detail_equip_slot_list": detail_equip_slot_list,
		"tooltip_gongfa_list": tooltip_gongfa_list,
		"item_tooltip_effects": item_tooltip_effects,
		"detail_layer": detail_layer,
		"bottom_panel": bottom_panel
	}
