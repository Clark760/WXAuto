extends RefCounted
class_name BattlefieldSessionState

# ===========================
# 战场会话状态
# ===========================
# 说明：
# 1. 集中承接场景级可变状态，避免状态继续散落到根场景私有字段。
# 2. Batch 1 先定义边界与默认值，后续批次再逐步把旧战场链路状态迁入这里。
# 3. 这份状态表本身不承接业务流程，它只保存可被静态定位的会话级状态。
# 4. 新增场景级状态时，优先补到这里，再决定由哪个协作者读写。
# 5. 这样 world / presenter / coordinator 才不会再次各自藏一份私有字段。

const INVALID_CELL: Vector2i = Vector2i(-999, -999)
const DEFAULT_DEPLOY_ZONE: Dictionary = {
	"x_min": 0,
	"x_max": 15,
	"y_min": 0,
	"y_max": 15
}

# 战斗阶段与部署映射。
# 这些字段描述“战场此刻是什么状态”，不描述“该执行什么流程”。
var stage: int = 0
var round_index: int = 1
var combat_elapsed: float = 0.0

var ally_deployed: Dictionary = {}
var enemy_deployed: Dictionary = {}

# 拖拽与世界视角状态。
# world controller、drag controller、renderer 都只应写这里，不应回写根场景。
var dragging_unit: Node = null
var drag_target_cell: Vector2i = INVALID_CELL
var drag_target_valid: bool = false
var drag_origin_kind: String = ""
var drag_origin_slot: int = -1
var drag_origin_cell: Vector2i = INVALID_CELL

var world_zoom: float = 1.0
var world_offset: Vector2 = Vector2.ZERO
var is_panning: bool = false
var unit_scale_factor: float = 1.0
var bottom_expanded: bool = true

# 世界输入瞬态。
# 这些字段只保存单次输入序列中的中间态，不能被长期业务流程复用。
var left_click_pending: bool = false
var left_press_pos: Vector2 = Vector2.ZERO
var bench_press_slot: int = -1
var bench_press_pos: Vector2 = Vector2.ZERO
var world_press_unit: Node = null
var world_press_pos: Vector2 = Vector2.ZERO
var world_press_cell: Vector2i = INVALID_CELL
var hover_candidate_unit: Node = null
var hover_hold_time: float = 0.0
var tooltip_hide_delay: float = 0.0

# 各类局内面板显隐状态。
# presenter 只负责投影这些显隐态，不在节点上另存一份业务真相。
var tooltip_visible: bool = false
var detail_visible: bool = false
var shop_visible: bool = false
var inventory_visible: bool = false
var recycle_visible: bool = false
var battle_stats_visible: bool = false
var shop_open_in_preparation: bool = true

# 详情面板与物品悬停态。
# detail / tooltip 的局部悬停状态同样纳入 session state，避免散回 presenter 私有字段。
var detail_unit: Node = null
var detail_refresh_accum: float = 0.0
var is_dragging_detail_panel: bool = false
var detail_drag_offset: Vector2 = Vector2.ZERO

var item_hover_source: Control = null
var item_hover_data: Dictionary = {}
var item_hover_timer: float = 0.0
var item_fade_timer: float = 0.0

# 仓库与日志视图态。
# 仓库模式和战斗日志滚动都视为场景级可变状态，而不是局部 UI 临时变量。
var inventory_mode: String = "gongfa"
var inventory_filter_type: String = "all"
var inventory_drag_enabled: bool = true

var battle_log_entries: Array[String] = []
var battle_log_dirty: bool = false
var battle_log_flush_accum: float = 0.0
var battle_log_last_flushed_count: int = 0
var battle_log_requires_rebuild: bool = false

# 关卡、商店和库存视图状态。
# coordinator 会读写这些字段，但字段本身仍由 session state 承接。
var current_stage_config: Dictionary = {}
var current_deploy_zone: Dictionary = {}
var shop_current_tab: String = "recruit"
var scene_reload_requested: bool = false
var pending_stage_advance: bool = false
var result_winner_team: int = 0

var owned_gongfa_stock: Dictionary = {}
var owned_equipment_stock: Dictionary = {}

# 场景初始化完成标记，由根场景在 Batch 1 完成装配后写入。
# smoke test 和过渡脚本都通过这个字段判断组合是否就位。
var scene_ready: bool = false


# 初始化默认状态时要复制字典，避免多个场景实例共享同一份引用。
func _init() -> void:
	current_deploy_zone = DEFAULT_DEPLOY_ZONE.duplicate(true)
	drag_target_cell = INVALID_CELL
	drag_origin_cell = INVALID_CELL
	world_press_cell = INVALID_CELL


# 根场景在完成 refs 和协作者装配后调用这个入口，供 smoke test 与后续批次判断。
func mark_scene_ready() -> void:
	scene_ready = true


# 功法和装备库存统一由 session state 保存，避免 presenter 和 coordinator 各自维护一份。
func add_owned_item(category: String, item_id: String, amount: int) -> void:
	var normalized_category: String = category.strip_edges().to_lower()
	var normalized_id: String = item_id.strip_edges()
	if normalized_id.is_empty():
		return
	var target: Dictionary = (
		owned_gongfa_stock
		if normalized_category == "gongfa"
		else owned_equipment_stock
	)
	var next_count: int = maxi(int(target.get(normalized_id, 0)) + amount, 0)
	if next_count > 0:
		target[normalized_id] = next_count
	else:
		target.erase(normalized_id)
	if normalized_category == "gongfa":
		owned_gongfa_stock = target
	else:
		owned_equipment_stock = target


# 装备/功法拖放与出售都走统一库存口径。
func consume_owned_item(category: String, item_id: String, amount: int) -> bool:
	var required: int = maxi(amount, 0)
	if required <= 0:
		return true
	if get_owned_item_count(category, item_id) < required:
		return false
	add_owned_item(category, item_id, -required)
	return true


# 读取当前库存数量时统一走这里，避免 presenter / coordinator 各自拼 stock map。
func get_owned_item_count(category: String, item_id: String) -> int:
	var normalized_category: String = category.strip_edges().to_lower()
	var normalized_id: String = item_id.strip_edges()
	if normalized_id.is_empty():
		return 0
	if normalized_category == "gongfa":
		return int(owned_gongfa_stock.get(normalized_id, 0))
	return int(owned_equipment_stock.get(normalized_id, 0))
