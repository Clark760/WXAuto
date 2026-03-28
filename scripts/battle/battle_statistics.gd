extends Node

# 战斗统计运行时壳层
# 说明：
# 1. 保留 Node 生命周期、信号和对外公开 API。
# 2. 统计状态与排序规则全部委托给 domain combat service。

signal battle_stat_updated(unit_instance_id: int, stat_type: String, value: int)

const BATTLE_STATISTICS_SERVICE_SCRIPT: Script = preload(
	"res://scripts/domain/combat/battle_statistics_service.gd"
)

var _service: RefCounted = BATTLE_STATISTICS_SERVICE_SCRIPT.new()


# 初始化时只桥接 domain service 的统计更新信号。
func _init() -> void:
	_connect_service_signals()


# 清空统计时继续保留原有 facade 方法名。
func clear_stats() -> void:
	_service.clear_stats()


# 开战时把 Node 单位投影成纯字典，再交给 domain service 建立快照。
func start_battle(units: Array[Node]) -> void:
	var unit_rows: Array[Dictionary] = []
	for unit in units:
		var row: Dictionary = _build_unit_snapshot(unit)
		if not row.is_empty():
			unit_rows.append(row)
	_service.start_battle(unit_rows)


# 注册单位时继续允许外层传入真实节点，壳层负责摘出统计字段。
func register_unit(unit: Node) -> int:
	return _service.register_unit(_build_unit_snapshot(unit))


# 伤害记录入口继续接受节点和 fallback 字典，内部转换后交给 domain service。
func record_damage(
	source: Node,
	target: Node,
	amount: float,
	source_fallback: Dictionary = {},
	target_fallback: Dictionary = {}
) -> void:
	_service.record_damage(
		_build_unit_snapshot(source),
		_build_unit_snapshot(target),
		amount,
		source_fallback,
		target_fallback
	)


# 治疗记录入口继续沿用旧契约，避免 coordinator 改调用面。
func record_healing(
	source: Node,
	target: Node,
	amount: float,
	source_fallback: Dictionary = {},
	target_fallback: Dictionary = {}
) -> void:
	_service.record_healing(
		_build_unit_snapshot(source),
		_build_unit_snapshot(target),
		amount,
		source_fallback,
		target_fallback
	)


# 额外统计项写入继续由 facade 接受节点，再透传给 domain service。
func record_stat(unit: Node, stat_key: String, delta: float, fallback: Dictionary = {}) -> void:
	_service.record_stat(_build_unit_snapshot(unit), stat_key, delta, fallback)


# 击杀记录继续接受运行时节点，避免调用方关心纯字典结构。
func record_kill(killer: Node, dead_unit: Node) -> void:
	_service.record_kill(_build_unit_snapshot(killer), _build_unit_snapshot(dead_unit))


# 对外暴露统计快照时继续直接透传 domain service 结果。
func get_stats_snapshot() -> Dictionary:
	return _service.get_stats_snapshot()


# 排行查询继续复用原有方法签名，供结果面板直接读取。
func get_ranked_stats(
	stat_key: String,
	limit: int = 8,
	min_value: int = 0,
	team_id: int = 0
) -> Array[Dictionary]:
	return _service.get_ranked_stats(stat_key, limit, min_value, team_id)


# MVP 查询继续透传 domain service，保持结果页逻辑不变。
func get_mvp(team_id: int = 0) -> Dictionary:
	return _service.get_mvp(team_id)


# 统一把 domain service 的统计变化桥接回 Node facade 信号。
func _connect_service_signals() -> void:
	var cb: Callable = Callable(self, "_on_service_battle_stat_updated")
	if not _service.is_connected("battle_stat_updated", cb):
		_service.connect("battle_stat_updated", cb)


# 转发统计变化信号，保持现有 coordinator 监听口径稳定。
func _on_service_battle_stat_updated(unit_instance_id: int, stat_type: String, value: int) -> void:
	battle_stat_updated.emit(unit_instance_id, stat_type, value)


# 把运行时节点投影成纯统计快照，隔离 domain service 对 Node 的依赖。
func _build_unit_snapshot(unit: Variant) -> Dictionary:
	if not is_instance_valid(unit):
		return {}
	var node: Node = unit as Node
	if node == null:
		return {}
	return {
		"instance_id": node.get_instance_id(),
		"unit_name": str(node.get("unit_name")),
		"unit_id": str(node.get("unit_id")),
		"team_id": int(node.get("team_id"))
	}
