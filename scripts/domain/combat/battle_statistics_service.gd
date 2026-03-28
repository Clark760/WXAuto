extends RefCounted
class_name BattleStatisticsService

# 战斗统计领域服务
# 说明：
# 1. 只维护单场战斗统计状态和排行规则。
# 2. 输入输出全部使用纯字典，不依赖 Node。

signal battle_stat_updated(unit_instance_id: int, stat_type: String, value: int)

var _unit_stats: Dictionary = {}
var _fallback_key_to_iid: Dictionary = {}
var _next_fallback_iid: int = -1
var _sort_stat_key: String = "damage_dealt"


# 开新局或手动清空时统一重置全部统计状态。
func clear_stats() -> void:
	_unit_stats.clear()
	_fallback_key_to_iid.clear()
	_next_fallback_iid = -1


# 开战时接收参战单位快照，并建立同一局的统计底表。
func start_battle(units: Array[Dictionary]) -> void:
	clear_stats()
	for unit in units:
		register_unit(unit)


# 注册单位时把纯快照转成稳定统计行，并复用已有 instance_id。
func register_unit(unit: Dictionary) -> int:
	var normalized: Dictionary = _normalize_unit_snapshot(unit)
	if normalized.is_empty():
		return 0
	var iid: int = int(normalized.get("instance_id", 0))
	if iid <= 0:
		return 0
	if _unit_stats.has(iid):
		return iid
	_unit_stats[iid] = _build_stat_row(normalized)
	return iid


# 伤害统计会同时记来源伤害和目标承伤，并在必要时回退到 fallback 身份。
func record_damage(
	source: Dictionary,
	target: Dictionary,
	amount: float,
	source_fallback: Dictionary = {},
	target_fallback: Dictionary = {}
) -> void:
	var value: int = maxi(int(round(amount)), 0)
	if value <= 0:
		return
	var source_iid: int = register_unit(source)
	if source_iid <= 0 and not source_fallback.is_empty():
		source_iid = _register_fallback_unit(source_fallback)
	if source_iid != 0:
		_add_stat_value(source_iid, "damage_dealt", value)

	var target_iid: int = register_unit(target)
	if target_iid <= 0 and not target_fallback.is_empty():
		target_iid = _register_fallback_unit(target_fallback)
	if target_iid != 0:
		_add_stat_value(target_iid, "damage_taken", value)


# 治疗统计优先记在施法者名下，缺来源时再退化为目标自己。
func record_healing(
	source: Dictionary,
	target: Dictionary,
	amount: float,
	source_fallback: Dictionary = {},
	target_fallback: Dictionary = {}
) -> void:
	var value: int = maxi(int(round(amount)), 0)
	if value <= 0:
		return
	var source_iid: int = register_unit(source)
	if source_iid <= 0 and not source_fallback.is_empty():
		source_iid = _register_fallback_unit(source_fallback)
	if source_iid <= 0:
		source_iid = register_unit(target)
	if source_iid <= 0 and not target_fallback.is_empty():
		source_iid = _register_fallback_unit(target_fallback)
	if source_iid != 0:
		_add_stat_value(source_iid, "healing_done", value)


# 任意统计项写入都统一走这里，方便 coordinator 追加扩展指标。
func record_stat(unit: Dictionary, stat_key: String, delta: float, fallback: Dictionary = {}) -> void:
	var value: int = int(round(delta))
	if value == 0:
		return
	var unit_iid: int = register_unit(unit)
	if unit_iid <= 0 and not fallback.is_empty():
		unit_iid = _register_fallback_unit(fallback)
	if unit_iid == 0:
		return
	_add_stat_value(unit_iid, stat_key, value)


# 击杀记录只在真实参战单位上累计，不为 kill 单独创建 fallback 行。
func record_kill(killer: Dictionary, dead_unit: Dictionary) -> void:
	var killer_iid: int = register_unit(killer)
	if killer_iid > 0:
		_add_stat_value(killer_iid, "kills", 1)
	var dead_iid: int = register_unit(dead_unit)
	if dead_iid > 0:
		_add_stat_value(dead_iid, "deaths", 1)


# 读取完整统计快照时返回深拷贝，避免外层直接污染状态。
func get_stats_snapshot() -> Dictionary:
	var out: Dictionary = {}
	for key in _unit_stats.keys():
		out[key] = (_unit_stats[key] as Dictionary).duplicate(true)
	return out


# 排行查询负责筛队伍、裁最小值并按指定指标排序。
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


# MVP 口径继续沿用“按伤害优先，再按击杀数打破平局”。
func get_mvp(team_id: int = 0) -> Dictionary:
	var rows: Array[Dictionary] = get_ranked_stats("damage_dealt", 1, -2147483648, team_id)
	if rows.is_empty():
		return {}
	return (rows[0] as Dictionary).duplicate(true)


# 单项统计变更会更新状态并向外广播最新值。
func _add_stat_value(unit_iid: int, stat_key: String, delta: int) -> void:
	if delta == 0:
		return
	if not _unit_stats.has(unit_iid):
		return
	var row: Dictionary = _unit_stats[unit_iid]
	row[stat_key] = int(row.get(stat_key, 0)) + delta
	_unit_stats[unit_iid] = row
	battle_stat_updated.emit(unit_iid, stat_key, int(row.get(stat_key, 0)))


# 排行排序规则先比目标值，再比击杀数，最后比名称保证稳定顺序。
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


# fallback 统计行用负 instance_id 区分，避免和真实节点冲突。
func _register_fallback_unit(fallback: Dictionary) -> int:
	var normalized: Dictionary = _normalize_fallback(fallback)
	if normalized.is_empty():
		return 0
	var key: String = "%s|%s|%d" % [
		str(normalized.get("unit_id", "")),
		str(normalized.get("unit_name", "")),
		int(normalized.get("team_id", 0))
	]
	if _fallback_key_to_iid.has(key):
		return int(_fallback_key_to_iid[key])
	var iid: int = _next_fallback_iid
	_next_fallback_iid -= 1
	_fallback_key_to_iid[key] = iid
	_unit_stats[iid] = _build_stat_row(normalized)
	return iid


# 真实单位快照只保留统计必需字段，不带任何运行时对象引用。
func _normalize_unit_snapshot(unit: Dictionary) -> Dictionary:
	if unit.is_empty():
		return {}
	var iid: int = int(unit.get("instance_id", 0))
	if iid <= 0:
		return {}
	return {
		"instance_id": iid,
		"unit_name": str(unit.get("unit_name", "")),
		"unit_id": str(unit.get("unit_id", "")),
		"team_id": int(unit.get("team_id", 0))
	}


# 新建统计行时统一补齐所有指标字段，保证排行读取结构稳定。
func _build_stat_row(unit: Dictionary) -> Dictionary:
	return {
		"unit_name": str(unit.get("unit_name", unit.get("unit_id", ""))),
		"unit_id": str(unit.get("unit_id", "")),
		"team_id": int(unit.get("team_id", 0)),
		"damage_dealt": 0,
		"damage_dealt_total": 0,
		"damage_taken": 0,
		"damage_taken_total": 0,
		"shield_absorbed": 0,
		"damage_immune_blocked": 0,
		"healing_done": 0,
		"kills": 0,
		"deaths": 0
	}


# fallback 归一化只保留 unit_id、unit_name 和 team_id 三个统计身份字段。
func _normalize_fallback(fallback: Dictionary) -> Dictionary:
	if fallback.is_empty():
		return {}
	var unit_id: String = str(fallback.get("unit_id", fallback.get("source_unit_id", ""))).strip_edges()
	var unit_name: String = str(fallback.get("unit_name", fallback.get("source_name", ""))).strip_edges()
	var team_id: int = int(fallback.get("team_id", fallback.get("source_team", 0)))
	if unit_name.is_empty() and not unit_id.is_empty():
		unit_name = unit_id
	if unit_id.is_empty() and unit_name.is_empty():
		return {}
	return {
		"unit_id": unit_id,
		"unit_name": unit_name,
		"team_id": team_id
	}
