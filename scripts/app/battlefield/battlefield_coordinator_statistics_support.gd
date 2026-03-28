extends RefCounted

# coordinator 统计支撑
# 说明：
# 1. 只承接战斗统计节点、单位索引和统计事件写入。
# 2. 不处理商店、关卡推进或 reload。
# 统计写入口径：
# 1. coordinator 只把事件转给这里，这里再决定写 battle_statistics 的哪种统计。
# 2. 单位先记入本地 instance_id 索引，减少战斗事件里重复查树。
# 3. 面板与统计节点共用同一实例，避免结果页和日志读到两套数据。
# 兜底口径：
# 1. 事件里缺少实例节点时，仍尽量用 fallback 信息保住统计记录。

const BATTLE_STATISTICS_SCRIPT: Script = preload("res://scripts/battle/battle_statistics.gd") # 统计运行时脚本。

var _owner = null # coordinator facade。
var _scene_root = null # 根场景入口。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。

var _battle_statistics = null # 运行时统计实例。
var _unit_lookup: Dictionary = {} # instance_id 到单位节点的回查表。


# 绑定统计支撑需要的 facade、场景引用和会话状态。
func initialize(owner, scene_root, refs, state) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state


# 返回运行时统计节点，供 coordinator 连接信号和写统计。
func get_battle_statistics() -> Node:
	return _battle_statistics


# 确保战斗统计节点存在，并把统计面板绑定到同一实例。
# 统计节点挂在 coordinator 之下，是为了跟着战场会话一起重建和销毁。
func ensure_battle_statistics_created() -> void:
	if _battle_statistics != null and is_instance_valid(_battle_statistics):
		return
	_battle_statistics = BATTLE_STATISTICS_SCRIPT.new()
	if _battle_statistics == null:
		return
	_battle_statistics.name = "RuntimeBattleStatistics"
	_owner.add_child(_battle_statistics)
	var battle_stats_panel = _get_battle_stats_panel()
	if battle_stats_panel != null:
		battle_stats_panel.bind_statistics(_battle_statistics)
	relayout_stats_panel()


# 视口变化后重新布局统计面板，避免结果界面错位。
# 布局只看可见视口，不依赖具体窗口模式，方便 headless smoke 对齐。
func relayout_stats_panel() -> void:
	var battle_stats_panel = _get_battle_stats_panel()
	if battle_stats_panel == null:
		return
	var viewport_size: Vector2 = _scene_root.get_viewport().get_visible_rect().size
	battle_stats_panel.relayout(viewport_size)


# 显示结果统计面板，并立即刷新内容。
# 结果阶段可能刚刚切入，这里主动刷新一次能避免首帧出现旧统计。
func show_battle_stats_panel(team_id: int) -> void:
	var battle_stats_panel = _get_battle_stats_panel()
	if battle_stats_panel == null:
		return
	_state.battle_stats_visible = true
	battle_stats_panel.show_panel(team_id)
	battle_stats_panel.refresh_content()


# 开战时把参战单位写入统计系统，并补齐运行时信号。
# ally/enemy 都在这里汇总成单一数组，保证 battle_statistics 看到的是同一批参战者。
func start_battle_capture(ally_units: Array[Node], enemy_units: Array[Node]) -> void:
	if _battle_statistics == null:
		return
	var all_units: Array[Node] = []
	_unit_lookup.clear()
	for unit in ally_units:
		remember_unit(unit)
		bind_unit_runtime_signals(unit)
		all_units.append(unit)
	for unit in enemy_units:
		remember_unit(unit)
		bind_unit_runtime_signals(unit)
		all_units.append(unit)
	_battle_statistics.start_battle(all_units)
	var battle_stats_panel = _get_battle_stats_panel()
	if battle_stats_panel != null:
		battle_stats_panel.refresh_content()


# 把单位加入 instance_id 索引，供后续战斗事件回查。
# lookup 只缓存活跃会话里的单位，不承担跨局缓存责任。
func remember_unit(unit: Variant) -> void:
	if not is_instance_valid(unit):
		return
	var node: Node = unit as Node
	if node == null:
		return
	_unit_lookup[node.get_instance_id()] = node


# 给单位战斗组件补齐治疗和反伤统计信号。
# 这类信号不一定都由 CombatManager 转发，所以这里补一次最稳妥。
func bind_unit_runtime_signals(unit: Variant) -> void:
	if not is_instance_valid(unit):
		return
	var node: Node = unit as Node
	if node == null:
		return
	var combat: Node = node.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return
	var heal_cb: Callable = Callable(_owner, "_on_unit_healing_performed")
	if combat.has_signal("healing_performed") and not combat.is_connected("healing_performed", heal_cb):
		combat.connect("healing_performed", heal_cb)
	var thorns_cb: Callable = Callable(_owner, "_on_thorns_damage_dealt")
	if combat.has_signal("thorns_damage_dealt") and not combat.is_connected("thorns_damage_dealt", thorns_cb):
		combat.connect("thorns_damage_dealt", thorns_cb)


# 统一写入伤害、护盾吸收和免伤拆解统计。
# 先算总量再分项写入，是为了让结果面板既能看净伤也能看被抵消的量。
func record_damage_with_breakdown(
	source_unit: Node,
	target_unit: Node,
	damage: float,
	shield_absorbed: float = 0.0,
	immune_absorbed: float = 0.0,
	source_fallback: Dictionary = {},
	target_fallback: Dictionary = {}
) -> void:
	if _battle_statistics == null:
		return
	var dealt_value: int = maxi(int(round(damage)), 0)
	var shield_value: int = maxi(int(round(shield_absorbed)), 0)
	var immune_value: int = maxi(int(round(immune_absorbed)), 0)
	var total_value: int = dealt_value + shield_value + immune_value
	if dealt_value > 0:
		_battle_statistics.record_damage(
			source_unit,
			target_unit,
			dealt_value,
			source_fallback,
			target_fallback
		)
	if total_value <= 0:
		return
	_battle_statistics.record_stat(
		source_unit,
		"damage_dealt_total",
		total_value,
		source_fallback
	)
	_battle_statistics.record_stat(
		target_unit,
		"damage_taken_total",
		total_value,
		target_fallback
	)
	if shield_value > 0:
		_battle_statistics.record_stat(
			target_unit,
			"shield_absorbed",
			shield_value,
			target_fallback
		)
	if immune_value > 0:
		_battle_statistics.record_stat(
			target_unit,
			"damage_immune_blocked",
			immune_value,
			target_fallback
		)


# 从战斗事件里提取兜底单位信息，避免实例回查失败时统计丢失。
# fallback 只保留统计必要字段，不把整包 event_dict 继续往下传。
func build_fallback_from_event(event_dict: Dictionary, side: String) -> Dictionary:
	var prefix: String = side.strip_edges().to_lower()
	var unit_id: String = str(event_dict.get("%s_unit_id" % prefix, "")).strip_edges()
	var unit_name: String = str(event_dict.get("%s_name" % prefix, "")).strip_edges()
	var team_id: int = int(event_dict.get("%s_team" % prefix, 0))
	var iid_hint: int = int(event_dict.get("%s_id" % prefix, -1))
	if unit_id.is_empty() and iid_hint > 0:
		unit_id = "iid_%d" % iid_hint
	if unit_name.is_empty() and not unit_id.is_empty():
		unit_name = unit_id
	if unit_id.is_empty() and unit_name.is_empty() and team_id == 0:
		return {}
	return {
		"unit_id": unit_id,
		"unit_name": unit_name,
		"team_id": team_id
	}


# 用 instance_id 在本地索引中回查单位节点。
func find_unit_by_instance_id(instance_id: int) -> Node:
	if instance_id <= 0:
		return null
	if _unit_lookup.has(instance_id):
		return _unit_lookup[instance_id] as Node
	return null


# 统计面板节点统一从 refs 读取，避免每处重复做可见性与方法判定。
func _get_battle_stats_panel():
	if _refs == null:
		return null
	return _refs.battle_stats_panel


