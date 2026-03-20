extends Node

# ===========================
# M4 战斗统计管理器
# ===========================
# 设计目标：
# 1. 用统一字典维护每个单位在单场战斗内的关键统计数据。
# 2. 对外提供“记录伤害/治疗/击杀”和“查询排行/MVP”的最小接口。
# 3. 统计逻辑独立于战斗逻辑，避免 CombatManager 变得臃肿难维护。

signal battle_stat_updated(unit_instance_id: int, stat_type: String, value: int)

const STAT_KEYS: Array[String] = [
	"damage_dealt",
	"damage_taken",
	"healing_done",
	"kills",
	"deaths"
]

var _unit_stats: Dictionary = {} # unit_instance_id -> Dictionary
var _sort_stat_key: String = "damage_dealt"


func clear_stats() -> void:
	_unit_stats.clear()


func start_battle(units: Array[Node]) -> void:
	# 每场战斗开始时清空统计，保证不会串场累计。
	_unit_stats.clear()
	for unit in units:
		register_unit(unit)


func register_unit(unit: Node) -> int:
	if not _is_valid_unit(unit):
		return -1
	var iid: int = unit.get_instance_id()
	if _unit_stats.has(iid):
		return iid
	_unit_stats[iid] = {
		"unit_name": str(unit.get("unit_name")),
		"unit_id": str(unit.get("unit_id")),
		"team_id": int(unit.get("team_id")),
		"damage_dealt": 0,
		"damage_taken": 0,
		"healing_done": 0,
		"kills": 0,
		"deaths": 0
	}
	return iid


func record_damage(source: Node, target: Node, amount: float) -> void:
	var value: int = maxi(int(round(amount)), 0)
	if value <= 0:
		return
	var source_iid: int = register_unit(source)
	if source_iid > 0:
		_add_stat_value(source_iid, "damage_dealt", value)
	var target_iid: int = register_unit(target)
	if target_iid > 0:
		_add_stat_value(target_iid, "damage_taken", value)


func record_healing(source: Node, target: Node, amount: float) -> void:
	var value: int = maxi(int(round(amount)), 0)
	if value <= 0:
		return
	# 优先记在施法者名下；若来源缺失，则退化为记在受治疗单位名下。
	var source_iid: int = register_unit(source)
	if source_iid <= 0:
		source_iid = register_unit(target)
	if source_iid > 0:
		_add_stat_value(source_iid, "healing_done", value)


func record_kill(killer: Node, dead_unit: Node) -> void:
	var killer_iid: int = register_unit(killer)
	if killer_iid > 0:
		_add_stat_value(killer_iid, "kills", 1)
	var dead_iid: int = register_unit(dead_unit)
	if dead_iid > 0:
		_add_stat_value(dead_iid, "deaths", 1)


func get_stats_snapshot() -> Dictionary:
	var out: Dictionary = {}
	for key in _unit_stats.keys():
		out[key] = (_unit_stats[key] as Dictionary).duplicate(true)
	return out


func get_ranked_stats(
	stat_key: String,
	limit: int = 8,
	min_value: int = 0,
	team_id: int = 0
) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for key in _unit_stats.keys():
		var row: Dictionary = (_unit_stats[key] as Dictionary).duplicate(true)
		if team_id > 0 and int(row.get("team_id", 0)) != team_id:
			continue
		row["unit_instance_id"] = int(key)
		row["value"] = int(row.get(stat_key, 0))
		if int(row.get("value", 0)) < min_value:
			continue
		rows.append(row)
	_sort_stat_key = stat_key
	rows.sort_custom(Callable(self, "_sort_rows_desc"))
	if limit > 0 and rows.size() > limit:
		rows.resize(limit)
	return rows


func get_mvp(team_id: int = 0) -> Dictionary:
	# MVP 先按伤害排序，伤害相同再看击杀数。
	var rows: Array[Dictionary] = get_ranked_stats("damage_dealt", 1, -2147483648, team_id)
	if rows.is_empty():
		return {}
	return (rows[0] as Dictionary).duplicate(true)


func _add_stat_value(unit_iid: int, stat_key: String, delta: int) -> void:
	if delta == 0:
		return
	if not _unit_stats.has(unit_iid):
		return
	var row: Dictionary = _unit_stats[unit_iid]
	row[stat_key] = int(row.get(stat_key, 0)) + delta
	_unit_stats[unit_iid] = row
	battle_stat_updated.emit(unit_iid, stat_key, int(row.get(stat_key, 0)))


func _sort_rows_desc(a: Dictionary, b: Dictionary) -> bool:
	var av: int = int(a.get(_sort_stat_key, 0))
	var bv: int = int(b.get(_sort_stat_key, 0))
	if av != bv:
		return av > bv
	var ak: int = int(a.get("kills", 0))
	var bk: int = int(b.get("kills", 0))
	if ak != bk:
		return ak > bk
	return str(a.get("unit_name", "")) < str(b.get("unit_name", ""))


func _is_valid_unit(unit: Variant) -> bool:
	if not is_instance_valid(unit):
		return false
	return (unit as Node) != null
