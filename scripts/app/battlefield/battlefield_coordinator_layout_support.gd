extends RefCounted

# coordinator 布局支撑
# 说明：
# 1. 只承接底栏回收区创建与 bench/recycle 横向布局。
# 2. 不处理商店、奖励和战斗统计写入。
# 布局口径：
# 1. 回收区是运行时补节点，但补完后要立即纳入 refs，避免世界层再找旧路径。
# 2. bench 与 recycle 必须共处同一 wrap 容器，拖拽热区才不会随父节点漂移。
# 3. 这里只有布局与显隐，没有任何出售定价或战斗状态判断。
# 可读性约束：
# 1. 这里优先解释为什么要重排容器，而不是重复节点名。

const STAGE_PREPARATION: int = 0 # 回收区只在备战期可用。
const RECYCLE_DROP_ZONE_SCENE_ID: String = "recycle_drop_zone" # 回收区子场景 id。
const RECYCLE_DROP_ZONE_SCENE_FALLBACK: PackedScene = preload(
	"res://scenes/ui/recycle_drop_zone.tscn"
) # 回收区子场景兜底。

var _owner = null # coordinator facade。
var _scene_root = null # 根场景入口。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。


# 绑定布局支撑需要的 facade、场景引用和会话状态。
# 布局支撑不缓存尺寸结果，每次都根据当前控件实时重排。
func initialize(owner, scene_root, refs, state) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state


# 需要时创建回收区容器，并把 bench 包进统一的运行时布局层。
# 这一步只做结构装配，不在这里连接出售业务信号。
func ensure_recycle_zone_created() -> void:
	if _refs.recycle_drop_zone != null and is_instance_valid(_refs.recycle_drop_zone):
		return
	if _refs.bottom_panel == null or _refs.bench_ui == null:
		return
	var root_vbox: VBoxContainer = _refs.bottom_panel.get_node_or_null("RootVBox") as VBoxContainer
	var bench_control: Control = _refs.bench_ui as Control
	if root_vbox == null or bench_control == null:
		return
	var wrap_runtime: Control = root_vbox.get_node_or_null("BenchRecycleWrapRuntime") as Control
	if wrap_runtime == null:
		wrap_runtime = Control.new()
		wrap_runtime.name = "BenchRecycleWrapRuntime"
		wrap_runtime.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		wrap_runtime.size_flags_vertical = Control.SIZE_EXPAND_FILL
		wrap_runtime.custom_minimum_size = Vector2(0.0, 154.0)
		wrap_runtime.clip_contents = true
		wrap_runtime.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bench_index: int = root_vbox.get_children().find(bench_control)
		root_vbox.add_child(wrap_runtime)
		root_vbox.move_child(wrap_runtime, maxi(bench_index, 0))
		var resize_cb: Callable = Callable(self, "layout_bench_recycle_wrap")
		if not wrap_runtime.is_connected("resized", resize_cb):
			wrap_runtime.connect("resized", resize_cb)
	if bench_control.get_parent() != wrap_runtime:
		var old_parent: Node = bench_control.get_parent()
		if old_parent != null:
			old_parent.remove_child(bench_control)
		wrap_runtime.add_child(bench_control)
	bench_control.size_flags_horizontal = 0
	bench_control.size_flags_vertical = 0
	bench_control.custom_minimum_size.x = 0.0
	bench_control.anchor_left = 0.0
	bench_control.anchor_top = 0.0
	bench_control.anchor_right = 0.0
	bench_control.anchor_bottom = 0.0
	bench_control.position = Vector2.ZERO
	if bench_control is ScrollContainer:
		var bench_scroll: ScrollContainer = bench_control as ScrollContainer
		bench_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
		bench_scroll.clip_contents = true
	var recycle_zone: PanelContainer = wrap_runtime.get_node_or_null("RecycleDropZone") as PanelContainer
	if recycle_zone == null:
		var recycle_scene: PackedScene = _resolve_ui_scene(
			RECYCLE_DROP_ZONE_SCENE_ID,
			RECYCLE_DROP_ZONE_SCENE_FALLBACK
		)
		if recycle_scene == null:
			return
		var recycle_node: Node = recycle_scene.instantiate()
		recycle_zone = recycle_node as PanelContainer
		if recycle_zone == null:
			if recycle_node != null:
				recycle_node.queue_free()
			return
		recycle_zone.name = "RecycleDropZone"
		recycle_zone.custom_minimum_size = Vector2(148, 118)
		recycle_zone.size_flags_horizontal = 0
		recycle_zone.size_flags_vertical = 0
		recycle_zone.anchor_left = 0.0
		recycle_zone.anchor_top = 0.0
		recycle_zone.anchor_right = 0.0
		recycle_zone.anchor_bottom = 0.0
		wrap_runtime.add_child(recycle_zone)
	_refs.bind_recycle_drop_zone(recycle_zone)
	layout_bench_recycle_wrap()


# 根据当前底栏宽度重排 bench 与 recycle 区，保证拖拽回收区始终可见。
# bench 宽度不足时优先给槽位留出生存空间，再压缩回收区宽度。
# 回收区显隐依赖 stage，但尺寸仍然保留，避免阶段切换时底栏高度突变。
func layout_bench_recycle_wrap() -> void:
	if _refs.bottom_panel == null or _refs.bench_ui == null or _refs.recycle_drop_zone == null:
		return
	var root_vbox: VBoxContainer = _refs.bottom_panel.get_node_or_null("RootVBox") as VBoxContainer
	var wrap_runtime: Control = root_vbox.get_node_or_null("BenchRecycleWrapRuntime") as Control
	var bench_ui: BattleBenchUI = _refs.bench_ui as BattleBenchUI
	var bench_control: Control = bench_ui as Control
	var recycle_drop_zone = _refs.recycle_drop_zone
	if root_vbox == null or wrap_runtime == null or bench_control == null or recycle_drop_zone == null:
		return
	if wrap_runtime.size.x <= 1.0 or wrap_runtime.size.y <= 1.0:
		return
	var gap: float = 8.0
	var wrap_size: Vector2 = wrap_runtime.size
	var row_height: float = maxf(wrap_size.y, 154.0)
	var slot_width: float = 112.0
	var slot_size_value: Variant = _refs.bench_ui.get("slot_size")
	if slot_size_value is Vector2:
		slot_width = maxf((slot_size_value as Vector2).x, 96.0)
	var recycle_width: float = clampf(
		148.0,
		96.0,
		maxf(wrap_size.x - gap - slot_width, 96.0)
	)
	var bench_width: float = maxf(wrap_size.x - recycle_width - gap, 0.0)
	if bench_width < slot_width:
		recycle_width = maxf(wrap_size.x - slot_width - gap, 96.0)
		bench_width = maxf(wrap_size.x - recycle_width - gap, 0.0)
	bench_control.clip_contents = true
	bench_control.custom_minimum_size = Vector2(0.0, row_height)
	bench_control.size = Vector2(bench_width, row_height)
	bench_ui.set_layout_width(bench_width)
	recycle_drop_zone.position = Vector2(wrap_size.x - recycle_width, 0.0)
	recycle_drop_zone.size = Vector2(recycle_width, row_height)
	recycle_drop_zone.custom_minimum_size = Vector2(recycle_width, row_height)
	recycle_drop_zone.visible = int(_state.stage) == STAGE_PREPARATION
	recycle_drop_zone.set_drop_enabled(int(_state.stage) == STAGE_PREPARATION)
	wrap_runtime.custom_minimum_size = Vector2(0.0, row_height)
	bench_ui.call_deferred("refresh_adaptive_layout")


# 优先从 refs 场景库解析 UI 子场景，缺失时回退到本地 fallback。
func _resolve_ui_scene(scene_id: String, fallback_scene: PackedScene) -> PackedScene:
	if _refs != null and _refs.has_method("get_ui_scene"):
		var scene_value: Variant = _refs.get_ui_scene(scene_id)
		if scene_value is PackedScene:
			return scene_value as PackedScene
	return fallback_scene


