extends Node
class_name BattlefieldCoordinator

enum Stage { PREPARATION, COMBAT, RESULT } # 局内阶段只允许在三态之间流转。

# coordinator 编排口径：
# 1. start_session 负责会话启动顺序，先缓存、再服务、再信号、最后关卡。
# 2. request_battle_start 负责开战顺序，先补部署与敌军，再 prepare_battle，再 start_battle。
# 3. 结果阶段入口统一先切 RESULT，再显示统计，再通知 stage manager。
# 支撑拆分口径：
# 1. 经济、奖励和出售交给 economy support。
# 2. 底栏回收区布局交给 layout support。
# 3. 战斗统计节点、索引和统计写入交给 statistics support。
# 状态口径：
# 1. 当前关卡配置、部署区、战斗耗时与结果状态全部写 session state。
# 2. presenter 和 world controller 只接收 coordinator 整体指令，不回传业务字段。
# 3. debug_label 只做本地提示，玩家可见流程文案统一走 battle log。
# reload 口径：
# 1. data reload 先重建缓存，再重载当前关卡，再刷新 HUD。
# 2. scene reload 只发一次切场请求，防止 F7 和异步 stop_battle 重复触发。

const TEAM_ALLY: int = 1 # 己方队伍标识。
const TEAM_ENEMY: int = 2 # 敌方队伍标识。
const BATTLEFIELD_SCENE_PATH: String = "res://scenes/battle/battlefield_scene.tscn" # 重开场景目标。
const COORDINATOR_ECONOMY_SUPPORT_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_coordinator_economy_support.gd"
) # 商店、奖励和出售支撑脚本。
const COORDINATOR_LAYOUT_SUPPORT_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_coordinator_layout_support.gd"
) # 底栏布局支撑脚本。
const COORDINATOR_STATISTICS_SUPPORT_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_coordinator_statistics_support.gd"
) # 战斗统计支撑脚本。
const COORDINATOR_SIGNAL_SUPPORT_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_coordinator_signal_support.gd"
) # 运行时信号接线支撑脚本。
const COORDINATOR_STAGE_RUNTIME_SUPPORT_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_coordinator_stage_runtime_support.gd"
) # 关卡网格与地形投影支撑脚本。
const STAGE_RUNTIME_RULES_SCRIPT: Script = preload(
	"res://scripts/domain/stage/stage_runtime_rules.gd"
) # 关卡运行时纯规则脚本。

@export var enemy_wave_size: int = 200 # 默认敌军波次规模。
@export var max_auto_deploy: int = 50 # 自动部署兜底上限。
@export var battle_start_enemy_spawn_batch_size: int = 24 # 开战前敌军分帧生成批大小。

var _scene_root: Node = null # 根场景入口。
var _refs: Node = null # 场景引用表。
var _state: RefCounted = null # 会话状态总表。
var _initialized: bool = false # 基础装配是否完成。
var _session_started: bool = false # 是否已启动首轮关卡加载。
var _signals_connected: bool = false # 运行时信号是否已经收口。
var _battle_start_pending: bool = false # 是否正在分帧准备开战。

var _capture_running: bool = false # 战斗统计捕获是否进行中。
var _stage_enemy_rng: RandomNumberGenerator = RandomNumberGenerator.new() # 敌军落位随机源。
var _economy_support = null # 商店/奖励/出售支撑。
var _layout_support = null # 底栏布局支撑。
var _statistics_support = null # 统计面板与统计写入支撑。
var _signal_support = null # 运行时信号接线支撑。
var _stage_runtime_support = null # 关卡运行时投影支撑。
var _services: ServiceRegistry = null


# 战场场景通过这个入口把全局服务交给 coordinator。
func bind_app_services(services: ServiceRegistry) -> void:
	_services = services


 # 装配 coordinator 和各类支撑协作者，保证编排入口显式化。
 # 所有运行时协作者都在这里显式 new + initialize，根场景只保留 getter。
func initialize(scene_root: Node, refs: Node, state: RefCounted) -> void:
	_scene_root = scene_root
	_refs = refs
	_state = state
	_stage_enemy_rng.randomize()
	get_tree().paused = false
	_economy_support = COORDINATOR_ECONOMY_SUPPORT_SCRIPT.new()
	_economy_support.initialize(self, _refs, _state, _stage_enemy_rng)
	_layout_support = COORDINATOR_LAYOUT_SUPPORT_SCRIPT.new()
	_layout_support.initialize(self, _scene_root, _refs, _state)
	_statistics_support = COORDINATOR_STATISTICS_SUPPORT_SCRIPT.new()
	_statistics_support.initialize(self, _scene_root, _refs, _state)
	_layout_support.ensure_recycle_zone_created()
	_statistics_support.ensure_battle_statistics_created()
	_signal_support = COORDINATOR_SIGNAL_SUPPORT_SCRIPT.new()
	_signal_support.initialize(self, _scene_root, _refs, _statistics_support)
	_stage_runtime_support = COORDINATOR_STAGE_RUNTIME_SUPPORT_SCRIPT.new()
	_stage_runtime_support.initialize(_refs, _state, STAGE_RUNTIME_RULES_SCRIPT)
	_initialized = _scene_root != null and _refs != null and _state != null


 # 启动会话时统一做缓存重建、服务接线和首个关卡装载。
 # 这样可以保证任意入口进场时，关卡开始前依赖已经全部齐备。
func start_session() -> void:
	if not _initialized or _session_started:
		return
	_rebuild_battle_data_caches()
	_setup_runtime_services()
	_connect_signals()
	_initialize_stage_progression()
	_refresh_presenter()
	_session_started = true


 # 对外暴露基础初始化结果，供 root scene 和 smoke test 读取。
func is_initialized() -> bool:
	return _initialized


 # Batch 3 暂时不需要逐帧 coordinator 逻辑，这里保留稳定入口。
 # 保留空入口是为了避免后续批次重新把逐帧编排塞回 root scene。
func process_runtime(_delta: float) -> void:
	pass


# 开始战斗请求统一经过这里，自动部署、敌军刷出和 prepare/start 顺序都收口在此。
# 只要未来还存在“开战”概念，就必须经过这一处，不能绕过编排顺序。
func request_battle_start() -> void:
	if _battle_start_pending:
		return
	_battle_start_pending = true
	call_deferred("_request_battle_start_async")


# 回放和自动化测试统一走这个开战入口，避免再直接编排 manager 调用顺序。
func start_battle_from_session(
	battle_seed: int = 0,
	prepare_missing_deployment: bool = false
) -> bool:
	if _battle_start_pending and prepare_missing_deployment:
		return false
	if _state == null or int(_state.stage) != Stage.PREPARATION:
		return false
	if _refs.combat_manager != null \
	and bool(_refs.combat_manager.is_battle_running()):
		return false
	# 非战斗关卡直接走 stage manager 完成，不再强行创建战斗单位。
	if STAGE_RUNTIME_RULES_SCRIPT.is_non_combat_stage(_state.current_stage_config):
		if _refs.runtime_stage_manager != null:
			_refs.runtime_stage_manager.complete_current_stage_without_battle()
			return true
		return false

	# 自动部署只在己方完全未上场时触发，避免覆盖玩家已有布阵。
	if prepare_missing_deployment:
		var auto_limit: int = max_auto_deploy
		if _refs.runtime_economy_manager != null:
			auto_limit = _refs.runtime_economy_manager.get_max_deploy_limit()
		if _state.ally_deployed.is_empty() \
		and _refs.runtime_unit_deploy_manager != null:
			_refs.runtime_unit_deploy_manager.auto_deploy_from_bench(auto_limit)
		if _refs.runtime_unit_deploy_manager != null:
			_refs.runtime_unit_deploy_manager.spawn_enemy_wave(enemy_wave_size)

	# ally/enemy 数组统一从部署映射收口，后续 prepare/start 只看这一份数据。
	var ally_units: Array[Node] = _collect_units_from_map(_state.ally_deployed)
	var enemy_units: Array[Node] = _collect_units_from_map(_state.enemy_deployed)
	if ally_units.is_empty() or enemy_units.is_empty():
		if _refs.debug_label != null:
			_refs.debug_label.text = "无法开始战斗：己方与敌方都必须至少有 1 名角色。"
		return false

	_state.combat_elapsed = 0.0
	_prepare_for_battle_start()
	# prepare_battle 必须发生在 start_battle 前，保证附魔和地形上下文齐全。
	if _refs.unit_augment_manager != null:
		_refs.unit_augment_manager.prepare_battle(
			ally_units,
			enemy_units,
			_refs.hex_grid,
			_refs.vfx_factory,
			_refs.combat_manager
		)

	var started: bool = false
	if _refs.combat_manager != null:
		started = bool(_refs.combat_manager.start_battle(ally_units, enemy_units, battle_seed))
	if not started:
		if _refs.debug_label != null:
			_refs.debug_label.text = "CombatManager 启动失败。"
		return false

	# 进入战斗态后的视觉切换仍保留在各单位自身，coordinator 只负责顺序编排。
	for unit in ally_units:
		if unit != null and is_instance_valid(unit):
			unit.enter_combat()
	for unit in enemy_units:
		if unit != null and is_instance_valid(unit):
			unit.enter_combat()

	if _refs.runtime_stage_manager != null:
		_refs.runtime_stage_manager.notify_stage_combat_started()
	_start_battle_capture(ally_units, enemy_units)
	_get_world_controller().set_stage(Stage.COMBAT)
	_sync_presenter_stage()
	_refresh_presenter()
	return true


func _request_battle_start_async() -> void:
	var started: bool = await _start_battle_from_session_async(0, true)
	_battle_start_pending = false
	if started:
		return
	if _refs != null and _refs.debug_label != null and _refs.debug_label.text.is_empty():
		_refs.debug_label.text = "开战准备失败。"


func _start_battle_from_session_async(
	battle_seed: int = 0,
	prepare_missing_deployment: bool = false
):
	if _state == null or int(_state.stage) != Stage.PREPARATION:
		return false
	if _refs.combat_manager != null and bool(_refs.combat_manager.is_battle_running()):
		return false
	if STAGE_RUNTIME_RULES_SCRIPT.is_non_combat_stage(_state.current_stage_config):
		return start_battle_from_session(battle_seed, prepare_missing_deployment)

	if prepare_missing_deployment:
		var auto_limit: int = max_auto_deploy
		if _refs.runtime_economy_manager != null:
			auto_limit = _refs.runtime_economy_manager.get_max_deploy_limit()
		if _state.ally_deployed.is_empty() and _refs.runtime_unit_deploy_manager != null:
			_refs.runtime_unit_deploy_manager.auto_deploy_from_bench(auto_limit)
		if _state.enemy_deployed.is_empty():
			await _spawn_enemy_wave_in_batches(enemy_wave_size)
			await get_tree().process_frame

	return start_battle_from_session(battle_seed, false)


func _spawn_enemy_wave_in_batches(enemy_count: int) -> void:
	if _refs.runtime_unit_deploy_manager == null:
		return
	if not _state.enemy_deployed.is_empty():
		return
	if not _refs.runtime_unit_deploy_manager.has_method("build_enemy_wave_plan"):
		_refs.runtime_unit_deploy_manager.spawn_enemy_wave(enemy_count)
		return

	var spawn_plan: Variant = _refs.runtime_unit_deploy_manager.build_enemy_wave_plan(enemy_count)
	if not (spawn_plan is Array):
		return
	var spawn_entries: Array = spawn_plan
	if spawn_entries.is_empty():
		return

	await _prewarm_spawn_plan_units_async(spawn_entries)
	await get_tree().process_frame

	var batch_size: int = maxi(battle_start_enemy_spawn_batch_size, 1)
	for start_index in range(0, spawn_entries.size(), batch_size):
		_refs.runtime_unit_deploy_manager.spawn_enemy_wave_from_plan(
			spawn_entries,
			start_index,
			batch_size
		)
		if _refs.debug_label != null:
			var spawned_count: int = mini(start_index + batch_size, spawn_entries.size())
			_refs.debug_label.text = "正在准备战斗…敌军 %d/%d" % [spawned_count, spawn_entries.size()]
		await get_tree().process_frame


 # 手动重开战场时只设置 reload 状态并延迟发出场景切换请求。
 # stop_battle 放在切场前，是为了给旧会话一个明确的结束原因。
func request_battlefield_reload() -> void:
	if _state == null or _state.scene_reload_requested:
		return
	_state.scene_reload_requested = true
	if _refs.combat_manager != null \
	and bool(_refs.combat_manager.is_battle_running()):
		_refs.combat_manager.stop_battle("manual_reload", 0)
	call_deferred("_emit_battlefield_reload_requested")


 # 准备期刷新商店时，把具体经济逻辑委托给 economy support。
func refresh_shop_for_preparation(force_refresh: bool) -> void:
	_economy_support.refresh_shop_for_preparation(force_refresh)


 # 商店购买入口对外保持不变，但内部发放逻辑交给 economy support。
func purchase_shop_offer(tab_id: String, index: int) -> void:
	_economy_support.purchase_shop_offer(tab_id, index)


 # 顶栏刷新商店按钮直接复用 economy support 的实现。
func refresh_shop_from_button() -> void:
	_economy_support.refresh_shop_from_button()


 # 锁店开关只暴露编排入口，细节交由 economy support 处理。
func toggle_shop_lock() -> void:
	_economy_support.toggle_shop_lock()


 # 门派升级入口继续保留在 coordinator，对外语义不变。
func buy_shop_upgrade() -> void:
	_economy_support.buy_shop_upgrade()


 # 本地调试银两入口沿用旧热键/按钮语义。
func add_test_silver() -> void:
	_economy_support.add_test_silver()


 # 本地调试经验入口沿用旧热键/按钮语义。
func add_test_exp() -> void:
	_economy_support.add_test_exp()


 # 世界层拖到回收区时，通过 coordinator 判断是否允许出售当前拖拽单位。
func try_sell_dragging_unit() -> bool:
	return _economy_support.try_sell_dragging_unit()


 # 关卡奖励的功法/装备库存统一从 coordinator 入口写回 session state。
func grant_stage_reward_item(item_type: String, item_id: String, count: int = 1) -> bool:
	return _economy_support.grant_stage_reward_item(item_type, item_id, count)


 # 关卡奖励角色的发放入口继续保留在 coordinator，具体落位交给 economy support。
func grant_stage_reward_unit(unit_id: String, star: int = 1) -> Dictionary:
	return _economy_support.grant_stage_reward_unit(unit_id, star)


 # 运行时服务初始化只做依赖注入，不在这里推进关卡或战斗。
 # stage manager 与 economy manager 的 wiring 统一放这里，避免 reload 时漏接。
func _setup_runtime_services() -> void:
	var data_manager: Node = _get_data_repository()
	if _refs.runtime_economy_manager != null:
		_refs.runtime_economy_manager.setup_from_data_manager(data_manager)
	if _refs.runtime_stage_manager != null:
		_refs.runtime_stage_manager.configure_runtime_context(
			_refs.runtime_economy_manager,
			self,
			TEAM_ALLY
		)


 # 数据缓存重建统一在这里收口，避免 reload 逻辑散到多个回调里。
 # 当前只重建商店池和地形注册表，后续扩展也应继续挂在这里。
func _rebuild_battle_data_caches() -> void:
	if _refs.runtime_shop_manager != null:
		_refs.runtime_shop_manager.reload_pools(_refs.unit_factory, _refs.unit_augment_manager)
	if _refs.combat_manager != null:
		_refs.combat_manager.reload_terrain_registry(_get_data_repository())


 # 所有运行时信号都在这里集中连接，避免阶段回调散落在各协作者内部。
 # 只连一次能避免 reload 或 reopen scene 后重复写日志和重复统计。
func _connect_signals() -> void:
	if _signals_connected:
		return
	_signal_support.connect_all(_get_event_bus())
	_signals_connected = true


 # 启动阶段序列时只消费 AppSessionState 写入的请求序列。
 # Batch 1 后测试入口和正式入口都必须走同一套显式注入链路。
func _initialize_stage_progression() -> void:
	if _refs.runtime_stage_manager == null or not is_instance_valid(_refs.runtime_stage_manager):
		return
	var data_manager: Node = _get_data_repository()
	var requested_sequence_id: String = _consume_requested_stage_sequence_id()
	if requested_sequence_id.is_empty():
		_refs.runtime_stage_manager.load_stage_sequence(data_manager)
	else:
		_refs.runtime_stage_manager.load_stage_sequence(data_manager, requested_sequence_id)
	var started: bool = bool(_refs.runtime_stage_manager.start_first_stage())
	if not started and not requested_sequence_id.is_empty():
		_refs.runtime_stage_manager.load_stage_sequence(data_manager)
		started = bool(_refs.runtime_stage_manager.start_first_stage())
		if started:
			_append_battle_log("指定章节序列不可用：%s，已回退默认序列。" % requested_sequence_id, "system")
	if not started and _refs.debug_label != null:
		_refs.debug_label.text = "Phase 2 提示：未检测到关卡配置，沿用基础战场模式。"


 # 统一消费外部请求的关卡序列 id。
 # 没有注入 AppSessionState 时直接视为空请求，不再回退旧全局管理器。
func _consume_requested_stage_sequence_id() -> String:
	if _services != null and _services.app_session != null:
		return _services.app_session.consume_requested_stage_sequence_id()
	return ""


 # 关卡加载完成后同步状态、部署区和 presenter。
 # 新关卡进入时要顺手清结果态和商店偏好，否则上一关残局会漏进来。
func _on_stage_loaded(config: Dictionary) -> void:
	_state.current_stage_config = config.duplicate(true)
	_state.round_index = maxi(int(_state.current_stage_config.get("index", _state.round_index)), 1)
	_state.pending_stage_advance = false
	_state.shop_open_in_preparation = true
	_state.shop_visible = true
	_state.result_winner_team = 0
	_apply_stage_runtime_config(_state.current_stage_config)
	_get_world_controller().set_stage(Stage.PREPARATION)
	_sync_presenter_stage()
	refresh_shop_for_preparation(false)
	var stage_name: String = str(
		_state.current_stage_config.get("name", str(_state.current_stage_config.get("id", "未知关卡")))
	)
	var stage_type: String = str(_state.current_stage_config.get("type", "normal"))
	_append_battle_log("进入关卡：%s（%s）" % [stage_name, stage_type], "system")
	if _refs.debug_label != null:
		_refs.debug_label.text = "当前关卡：%s（布阵阶段）" % stage_name
	_refresh_presenter()


 # 战斗真正开始时只做日志、调试文案和 HUD 阶段同步。
 # 真正的 prepare/start 发生在 request_battle_start，这里只响应 stage manager 的确认。
func _on_stage_combat_started(config: Dictionary) -> void:
	var stage_name: String = str(config.get("name", str(config.get("id", "未知关卡"))))
	_append_battle_log("关卡开战：%s" % stage_name, "system")


 # 关卡完成后统一承接奖励、结果面板和后续推进状态。
 # 如果当前已经在结果态，说明结果链已打开，这里只补 pending 标记即可。
func _on_stage_completed(config: Dictionary, rewards: Dictionary) -> void:
	var stage_name: String = str(config.get("name", str(config.get("id", "未知关卡"))))
	var silver: int = int(rewards.get("silver", 0))
	var exp_value: int = int(rewards.get("exp", 0))
	var granted_units: int = (
		(rewards.get("granted_units", []) as Array).size()
		if rewards.get("granted_units", []) is Array
		else 0
	)
	var drops_count: int = (
		(rewards.get("drops", []) as Array).size()
		if rewards.get("drops", []) is Array
		else 0
	)
	_append_battle_log(
		"关卡胜利：%s，奖励 银两+%d 经验+%d 掉落%d 侠客%d" % [stage_name, silver, exp_value, drops_count, granted_units],
		"system"
	)
	_state.pending_stage_advance = true
	if int(_state.stage) != Stage.RESULT:
		_advance_to_next_stage_after_result()


 # 关卡失败时同样切到结果阶段，但不会推进到下一关。
 # 失败日志保留 F7 提示，是为了调试回放时能直接看到恢复路径。
func _on_stage_failed(config: Dictionary) -> void:
	_state.pending_stage_advance = false
	var stage_name: String = str(config.get("name", str(config.get("id", "未知关卡"))))
	_append_battle_log("关卡失败：%s（按 F7 重置，或调试后重开）" % stage_name, "death")


 # 全部关卡清空时只做最终提示和结果态收口。
 # 这里不主动 reload，避免通关后又被自动拉回首关。
func _on_all_stages_cleared() -> void:
	_state.pending_stage_advance = false
	_append_battle_log("全部关卡已完成，恭喜通关。", "system")
	if _refs.debug_label != null:
		_refs.debug_label.text = "全部关卡已完成。按 F7 可重开。"


 # 关卡运行时配置统一在这里下发给经济、部署和 presenter 相关状态。
 # 先处理棋盘和地形，再清战斗，再刷新世界布局，顺序不能倒。
func _apply_stage_runtime_config(config: Dictionary) -> void:
	_stage_runtime_support.apply_stage_runtime_config(config)
	if _refs.runtime_unit_deploy_manager != null:
		_refs.runtime_unit_deploy_manager.clear_enemy_wave()
	if _refs.combat_manager != null \
	and bool(_refs.combat_manager.is_battle_running()):
		_refs.combat_manager.stop_battle("stage_switched", 0)
	_state.combat_elapsed = 0.0
	_prepare_for_new_stage()
	_get_world_controller().refresh_world_layout()


 # 新关卡开始前统一清理统计面板、捕获状态和旧结果显示。
 # 这样无论是切下一关还是重新开始，都不会继承上一局的统计可见态。
func _prepare_for_new_stage() -> void:
	_capture_running = false
	_state.battle_stats_visible = false
	if _refs.battle_stats_panel != null:
		_refs.battle_stats_panel.hide_panel()


 # 开战前的准备阶段目前只需要复用新关卡清理流程。
 # 如果后续新增冻结 inventory 之类的预处理，也应继续挂在这里。
func _prepare_for_battle_start() -> void:
	_prepare_for_new_stage()


 # 开战后启动统计捕获，把单位和面板刷新统一接到统计支撑层。
 # 统计捕获的开关只在 coordinator 持有，避免多处同时认为自己在记录。
func _start_battle_capture(ally_units: Array[Node], enemy_units: Array[Node]) -> void:
	if _statistics_support.get_battle_statistics() == null:
		return
	_statistics_support.start_battle_capture(ally_units, enemy_units)
	_capture_running = true
	if _refs.battle_stats_panel != null:
		_refs.battle_stats_panel.refresh_content()


 # 战斗结束后统一切结果阶段、展示统计并通知关卡管理器。
 # 先切阶段再显面板，能保证 HUD 和 world 已经进入只读结果态。
func _on_battle_ended(winner_team: int, summary: Dictionary) -> void:
	_capture_running = false
	_state.result_winner_team = winner_team
	_get_world_controller().set_stage(Stage.RESULT)
	_sync_presenter_stage()
	_statistics_support.show_battle_stats_panel(TEAM_ALLY)
	if _refs.runtime_stage_manager != null:
		_refs.runtime_stage_manager.on_battle_ended(winner_team, summary)
	if _refs.debug_label != null:
		if winner_team == TEAM_ALLY:
			_refs.debug_label.text = "战斗结束：己方胜利。"
		elif winner_team == TEAM_ENEMY:
			_refs.debug_label.text = "战斗结束：敌方胜利。"
		else:
			_refs.debug_label.text = "战斗结束：平局。"
	_refresh_presenter()


 # 普通伤害结算事件统一写入统计支撑。
 # source/target 节点找不到时，statistics support 还会用 fallback 补齐记录。
func _on_damage_resolved(event_dict: Dictionary) -> void:
	if not _capture_running or _statistics_support.get_battle_statistics() == null:
		return
	var source_unit: Node = _statistics_support.find_unit_by_instance_id(
		int(event_dict.get("source_id", -1))
	)
	var target_unit: Node = _statistics_support.find_unit_by_instance_id(
		int(event_dict.get("target_id", -1))
	)
	_statistics_support.remember_unit(source_unit)
	_statistics_support.remember_unit(target_unit)
	_statistics_support.record_damage_with_breakdown(
		source_unit,
		target_unit,
		float(event_dict.get("damage", 0.0)),
		float(event_dict.get("shield_absorbed", 0.0)),
		float(event_dict.get("immune_absorbed", 0.0)),
		_statistics_support.build_fallback_from_event(event_dict, "source"),
		_statistics_support.build_fallback_from_event(event_dict, "target")
	)


 # 技能伤害事件同样走统计支撑，保持普通伤害与技能伤害口径一致。
 # 这样最终统计面板看到的是总伤害，而不是被事件来源拆碎的多套口径。
func _on_skill_effect_damage(event_dict: Dictionary) -> void:
	if not _capture_running or _statistics_support.get_battle_statistics() == null:
		return
	var source_unit: Node = event_dict.get("source", null)
	var target_unit: Node = event_dict.get("target", null)
	_statistics_support.remember_unit(source_unit)
	_statistics_support.remember_unit(target_unit)
	_statistics_support.record_damage_with_breakdown(
		source_unit,
		target_unit,
		float(event_dict.get("damage", 0.0)),
		float(event_dict.get("shield_absorbed", 0.0)),
		float(event_dict.get("immune_absorbed", 0.0)),
		_statistics_support.build_fallback_from_event(event_dict, "source"),
		_statistics_support.build_fallback_from_event(event_dict, "target")
	)


 # 技能治疗事件统一记录到统计系统。
 # 治疗事件只要数值大于 0 就会入表，避免瞬时小治疗被静默吞掉。
func _on_skill_effect_heal(event_dict: Dictionary) -> void:
	var battle_statistics: Node = _statistics_support.get_battle_statistics()
	if not _capture_running or battle_statistics == null:
		return
	var heal_value: int = int(round(float(event_dict.get("heal", 0.0))))
	if heal_value <= 0:
		return
	var source_unit: Node = event_dict.get("source", null)
	var target_unit: Node = event_dict.get("target", null)
	_statistics_support.remember_unit(source_unit)
	_statistics_support.remember_unit(target_unit)
	battle_statistics.record_healing(
		source_unit,
		target_unit,
		heal_value,
		_statistics_support.build_fallback_from_event(event_dict, "source"),
		_statistics_support.build_fallback_from_event(event_dict, "target")
	)


 # 单位组件主动上报治疗时，也统一进入同一份统计。
 # 这条链路补的是非技能来源治疗，和上面的技能治疗互补而不冲突。
func _on_unit_healing_performed(source: Node, target: Node, amount: float, _heal_type: String) -> void:
	var battle_statistics: Node = _statistics_support.get_battle_statistics()
	if not _capture_running or battle_statistics == null:
		return
	var heal_value: int = int(round(amount))
	if heal_value <= 0:
		return
	_statistics_support.remember_unit(source)
	_statistics_support.remember_unit(target)
	battle_statistics.record_healing(source, target, heal_value)


 # 反伤事件的统计写入和普通伤害保持同一拆解逻辑。
 # 共用同一拆解函数后，伤害、护盾和免伤的面板口径才能一致。
func _on_thorns_damage_dealt(source: Node, target: Node, event_dict: Dictionary) -> void:
	if not _capture_running or _statistics_support.get_battle_statistics() == null:
		return
	_statistics_support.remember_unit(source)
	_statistics_support.remember_unit(target)
	_statistics_support.record_damage_with_breakdown(
		source,
		target,
		float(event_dict.get("damage", 0.0)),
		float(event_dict.get("shield_absorbed", 0.0)),
		float(event_dict.get("immune_absorbed", 0.0))
	)


 # 死亡事件只负责写 kill 统计，不在这里处理结果阶段切换。
 # 结果阶段切换仍以 battle_ended 为准，避免提前把局面误判为结束。
func _on_unit_died(dead_unit: Node, killer: Node, _team_id: int) -> void:
	var battle_statistics: Node = _statistics_support.get_battle_statistics()
	if not _capture_running or battle_statistics == null:
		return
	_statistics_support.remember_unit(dead_unit)
	_statistics_support.remember_unit(killer)
	battle_statistics.record_kill(killer, dead_unit)


 # 统计面板打开时，收到战斗统计变更后即时刷新内容。
 # 面板关闭时则不刷新，避免后台频繁重建 UI。
func _on_battle_stat_updated(_unit_instance_id: int, _stat_type: String, _value: int) -> void:
	if not _state.battle_stats_visible or _refs.battle_stats_panel == null:
		return
	if not _refs.battle_stats_panel.visible:
		return
	_refs.battle_stats_panel.refresh_content()


 # 结果统计面板关闭后，如有待推进关卡则继续进入下一阶段。
 # 这样玩家先看完结果，再推进下一关，不会被自动切场打断。
func _on_battle_stats_panel_closed() -> void:
	_state.battle_stats_visible = false
	_refresh_presenter()
	if _state.pending_stage_advance:
		_advance_to_next_stage_after_result()


 # 从结果阶段进入下一关前，先把单位视觉状态恢复为 idle。
 # 世界表现恢复放在真正 advance 前，避免下一关首帧还带着胜利动作。
func _advance_to_next_stage_after_result() -> void:
	_state.pending_stage_advance = false
	var world_controller: Node = _get_world_controller()
	if world_controller != null:
		world_controller.reset_all_units_to_idle()
	if _refs.runtime_stage_manager == null:
		return
	_refs.runtime_stage_manager.advance_to_next_stage()


 # 回收区出售请求只做转发，具体出售规则由 economy support 承接。
func _on_recycle_sell_requested(payload: Dictionary, price: int) -> void:
	_economy_support.on_recycle_sell_requested(payload, price)


 # 资产快照变化后统一刷新 presenter。
func _on_assets_changed(_snapshot: Dictionary) -> void:
	var presenter: Node = _get_hud_presenter()
	if presenter != null and presenter.has_method("refresh_after_shop_economy_change"):
		presenter.refresh_after_shop_economy_change()
		return
	_refresh_presenter()


 # 锁店状态变化后统一刷新 presenter。
func _on_shop_locked_changed(_locked: bool) -> void:
	var presenter: Node = _get_hud_presenter()
	if presenter != null and presenter.has_method("refresh_after_shop_economy_change"):
		presenter.refresh_after_shop_economy_change()
		return
	_refresh_presenter()


 # 商店快照变化后统一刷新 presenter。
func _on_shop_snapshot_refreshed(_snapshot: Dictionary) -> void:
	_prewarm_visible_recruit_offers(_snapshot)
	var presenter: Node = _get_hud_presenter()
	if presenter != null and presenter.has_method("refresh_after_shop_economy_change"):
		presenter.refresh_after_shop_economy_change()
		return
	_refresh_presenter()


 # DataManager reload 后重建缓存、重载关卡并刷新 presenter。
 # reload 后优先尝试恢复当前关卡 id，失败时才回退到首关。
func _on_data_reloaded(is_full_reload: bool, summary: Dictionary) -> void:
	_rebuild_battle_data_caches()
	if _refs.runtime_stage_manager != null and is_instance_valid(_refs.runtime_stage_manager):
		var data_manager: Node = _get_data_repository()
		_refs.runtime_stage_manager.load_stage_sequence(data_manager)
		var current_stage_id: String = str(_refs.runtime_stage_manager.get_current_stage_id())
		if current_stage_id.is_empty() or not bool(_refs.runtime_stage_manager.start_stage(current_stage_id)):
			_refs.runtime_stage_manager.start_first_stage()
	refresh_shop_for_preparation(true)
	var presenter: Node = _get_hud_presenter()
	if presenter != null:
		presenter.handle_data_reloaded(is_full_reload, summary)


 # UnitAugment reload 后也需要重建缓存和当前关卡状态。
 # 这里和 DataManager reload 共用流程，是为了保证功法装备改动立刻落到当前战场。
func _on_unit_augment_data_reloaded(summary: Dictionary) -> void:
	_rebuild_battle_data_caches()
	if _refs.runtime_stage_manager != null and is_instance_valid(_refs.runtime_stage_manager):
		var data_manager: Node = _get_data_repository()
		_refs.runtime_stage_manager.load_stage_sequence(data_manager)
		var current_stage_id: String = str(_refs.runtime_stage_manager.get_current_stage_id())
		if not current_stage_id.is_empty():
			_refs.runtime_stage_manager.start_stage(current_stage_id)
	refresh_shop_for_preparation(true)
	var presenter: Node = _get_hud_presenter()
	if presenter != null:
		presenter.handle_unit_augment_data_reloaded(summary)


 # 视口变化后同步底栏回收区与统计面板布局。
 # 具体布局算法交给 support，实现上保持 coordinator 只发一个重排命令。
func _on_viewport_size_changed() -> void:
	_layout_support.layout_bench_recycle_wrap()
	_statistics_support.relayout_stats_panel()


 # 统一从部署映射中读取单位数组，供开战编排复用。
 # coordinator 不直接遍历 map，是为了把部署容器结构继续封在 deploy manager 内。
func _collect_units_from_map(map_value: Dictionary) -> Array[Node]:
	if _refs.runtime_unit_deploy_manager == null:
		return []
	return _refs.runtime_unit_deploy_manager.collect_units_from_map(map_value)


 # 往 HUD battle log 追加文案时统一经过 presenter。
 # presenter 不存在时静默跳过，保证 headless 或半装配场景也不会崩。
func _append_battle_log(line: String, event_type: String = "info") -> void:
	var presenter: Node = _get_hud_presenter()
	if presenter != null:
		presenter.append_battle_log(line, event_type)


 # 需要全量刷新 HUD 时统一经过 presenter facade。
 # 其他支撑层需要重画 HUD 时，也都应通过这个包装口。
func _refresh_presenter() -> void:
	var presenter: Node = _get_hud_presenter()
	if presenter != null:
		presenter.refresh_ui()


 # 阶段变化后统一同步 presenter 与底栏回收区布局。
 # 世界层与 HUD 的阶段同步都应从 coordinator 的阶段切换发出。
func _sync_presenter_stage() -> void:
	var presenter: Node = _get_hud_presenter()
	if presenter != null:
		presenter.sync_stage()
	_layout_support.layout_bench_recycle_wrap()

 # 通过 EventBus 发出战场重载请求，避免直接改根场景。
func _emit_battlefield_reload_requested() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.emit_scene_change_requested(BATTLEFIELD_SCENE_PATH)
	else:
		_state.scene_reload_requested = false


 # 通过根场景 getter 读取 HUD presenter，避免写死子节点路径。
func _get_hud_presenter() -> Node:
	if _scene_root == null or not _scene_root.has_method("get_hud_presenter"):
		return null
	return _scene_root.get_hud_presenter()


 # 通过根场景 getter 读取 world controller，保持职责边界清晰。
func _get_world_controller() -> Node:
	if _scene_root == null or not _scene_root.has_method("get_world_controller"):
		return null
	return _scene_root.get_world_controller()




 # coordinator 只通过注入服务拿事件总线，不再回退根节点查找。
func _get_event_bus() -> Node:
	if _services == null:
		return null
	return _services.event_bus


 # coordinator 只通过注入服务拿数据仓库，避免把运行时再绑回 autoload。
func _get_data_repository() -> Node:
	if _services == null:
		return null
	return _services.data_repository


func _prewarm_visible_recruit_offers(snapshot: Dictionary) -> void:
	if _refs == null or _refs.unit_factory == null or _refs.unit_layer == null:
		return
	if not _refs.unit_factory.has_method("prewarm_unit_instances_by_count"):
		return

	var recruit_counts: Dictionary = _build_recruit_offer_counts(snapshot)
	if recruit_counts.is_empty():
		return
	_refs.unit_factory.prewarm_unit_instances_by_count(recruit_counts, _refs.unit_layer)


func _prewarm_spawn_plan_units_async(spawn_plan: Array[Dictionary]) -> void:
	if _refs == null or _refs.unit_factory == null or _refs.unit_layer == null:
		return
	if not _refs.unit_factory.has_method("prewarm_unit_instances_by_count"):
		return

	var count_by_unit_id: Dictionary = _build_spawn_plan_unit_counts(spawn_plan)
	if count_by_unit_id.is_empty():
		return

	var batch_budget: int = maxi(battle_start_enemy_spawn_batch_size, 1)
	while true:
		var warmed_count: int = int(
			_refs.unit_factory.prewarm_unit_instances_by_count(
				count_by_unit_id,
				_refs.unit_layer,
				batch_budget
			)
		)
		if warmed_count <= 0:
			return
		if _refs.debug_label != null:
			_refs.debug_label.text = "正在准备战斗…预热单位缓存"
		await get_tree().process_frame


func _build_recruit_offer_counts(snapshot: Dictionary) -> Dictionary:
	var count_by_unit_id: Dictionary = {}
	var offers_value: Variant = snapshot.get("recruit", [])
	if not (offers_value is Array):
		return count_by_unit_id
	for offer_value in offers_value:
		if not (offer_value is Dictionary):
			continue
		var offer: Dictionary = offer_value as Dictionary
		if bool(offer.get("sold", false)):
			continue
		if str(offer.get("item_type", "")).strip_edges() != "unit":
			continue
		var unit_id: String = str(offer.get("item_id", "")).strip_edges()
		if unit_id.is_empty():
			continue
		count_by_unit_id[unit_id] = int(count_by_unit_id.get(unit_id, 0)) + 1
	return count_by_unit_id


func _build_spawn_plan_unit_counts(spawn_plan: Array[Dictionary]) -> Dictionary:
	var count_by_unit_id: Dictionary = {}
	for entry_value in spawn_plan:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value as Dictionary
		var unit_id: String = str(entry.get("unit_id", "")).strip_edges()
		if unit_id.is_empty():
			continue
		count_by_unit_id[unit_id] = int(count_by_unit_id.get(unit_id, 0)) + 1
	return count_by_unit_id
