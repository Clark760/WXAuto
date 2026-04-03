extends RefCounted
class_name BattlefieldCombatLogAggregator

## 战斗日志聚合器
## 说明：
## 1. 采集层只 push 结构化事件，这里负责低伤害过滤与同类合并。
## 2. flush_aggregated 返回 UI 可直接渲染的文本行，减少 runtime_view 的字符串工作量。
## 3. 内部使用环形缓冲，避免高频事件导致数组头删和 GC 抖动。

const RING_BUFFER_SCRIPT: Script = preload("res://scripts/battle/battle_log_ring_buffer.gd")

const TYPE_DAMAGE: int = 0
const TYPE_SKILL_DAMAGE: int = 1
const TYPE_SKILL_HEAL: int = 2
const TYPE_SKILL_CAST: int = 3
const TYPE_DEATH: int = 4
const TYPE_SYSTEM: int = 5

const MIN_DAMAGE_THRESHOLD: int = 5

var _ring = RING_BUFFER_SCRIPT.new()
var _last_read_head: int = 0


func initialize(_text_support = null) -> void:
	clear()


func push_event(event: Dictionary) -> void:
	if event.is_empty():
		return
	var event_type: int = int(event.get("type", TYPE_SYSTEM))
	if event_type == TYPE_DAMAGE or event_type == TYPE_SKILL_DAMAGE:
		if int(round(float(event.get("value", 0.0)))) < MIN_DAMAGE_THRESHOLD:
			return
	_ring.push(_normalize_event(event))


func flush_aggregated(_current_time: float) -> Array[Dictionary]:
	var drained: Array[Dictionary] = _ring.drain_since(_last_read_head)
	_last_read_head = _ring.get_write_head()
	if drained.is_empty():
		return []

	var output: Array[Dictionary] = []
	var merged: Dictionary = {}
	var ordered_keys: Array[String] = []

	for event in drained:
		var event_type: int = int(event.get("type", TYPE_SYSTEM))
		match event_type:
			TYPE_DAMAGE, TYPE_SKILL_DAMAGE:
				var damage_key: String = _damage_merge_key(event)
				if merged.has(damage_key):
					var current: Dictionary = merged[damage_key]
					current["value"] = int(current.get("value", 0)) + int(event.get("value", 0))
					current["count"] = int(current.get("count", 1)) + 1
					var skill_name: String = str(event.get("skill_name", "")).strip_edges()
					if not skill_name.is_empty():
						current["skill_name"] = skill_name
					merged[damage_key] = current
				else:
					var created: Dictionary = event.duplicate(true)
					created["count"] = 1
					merged[damage_key] = created
					ordered_keys.append(damage_key)
			TYPE_SKILL_HEAL:
				var heal_key: String = _heal_merge_key(event)
				if merged.has(heal_key):
					var current: Dictionary = merged[heal_key]
					current["value"] = int(current.get("value", 0)) + int(event.get("value", 0))
					current["count"] = int(current.get("count", 1)) + 1
					merged[heal_key] = current
				else:
					var created: Dictionary = event.duplicate(true)
					created["count"] = 1
					merged[heal_key] = created
					ordered_keys.append(heal_key)
			TYPE_DEATH:
				output.append({
					"text": _format_death_event(event),
					"event_type": "death"
				})
			TYPE_SKILL_CAST:
				output.append({
					"text": _format_skill_cast_event(event),
					"event_type": "skill"
				})
			TYPE_SYSTEM:
				var system_text: String = str(event.get("text", "")).strip_edges()
				if not system_text.is_empty():
					output.append({
						"text": system_text,
						"event_type": "system"
					})

	for key in ordered_keys:
		if not merged.has(key):
			continue
		var merged_event: Dictionary = merged[key]
		var merged_type: int = int(merged_event.get("type", TYPE_DAMAGE))
		if merged_type == TYPE_DAMAGE:
			output.append({
				"text": _format_damage_event(merged_event),
				"event_type": "damage"
			})
		elif merged_type == TYPE_SKILL_DAMAGE:
			output.append({
				"text": _format_damage_event(merged_event),
				"event_type": "skill"
			})
		elif merged_type == TYPE_SKILL_HEAL:
			output.append({
				"text": _format_heal_event(merged_event),
				"event_type": "buff"
			})
	return output


func clear() -> void:
	_ring.clear()
	_last_read_head = 0


func _normalize_event(event: Dictionary) -> Dictionary:
	var normalized: Dictionary = event.duplicate(true)
	normalized["type"] = int(event.get("type", TYPE_SYSTEM))
	normalized["source_name"] = str(event.get("source_name", "")).strip_edges()
	normalized["target_name"] = str(event.get("target_name", "")).strip_edges()
	normalized["source_team"] = int(event.get("source_team", 0))
	normalized["target_team"] = int(event.get("target_team", 0))
	normalized["source_id"] = int(event.get("source_id", -1))
	normalized["target_id"] = int(event.get("target_id", -1))
	normalized["value"] = int(round(float(event.get("value", 0.0))))
	normalized["skill_name"] = str(event.get("skill_name", "")).strip_edges()
	normalized["timestamp"] = float(event.get("timestamp", 0.0))
	normalized["text"] = str(event.get("text", "")).strip_edges()
	return normalized


func _damage_merge_key(event: Dictionary) -> String:
	var event_type: int = int(event.get("type", TYPE_DAMAGE))
	var source_id: int = int(event.get("source_id", -1))
	var target_id: int = int(event.get("target_id", -1))
	var source_name: String = str(event.get("source_name", "")).strip_edges()
	var target_name: String = str(event.get("target_name", "")).strip_edges()
	var skill_name: String = str(event.get("skill_name", "")).strip_edges()
	return "d|%d|%d|%d|%s|%s|%s" % [
		event_type,
		source_id,
		target_id,
		source_name,
		target_name,
		skill_name
	]


func _heal_merge_key(event: Dictionary) -> String:
	var source_id: int = int(event.get("source_id", -1))
	var target_id: int = int(event.get("target_id", -1))
	var source_name: String = str(event.get("source_name", "")).strip_edges()
	var target_name: String = str(event.get("target_name", "")).strip_edges()
	var skill_name: String = str(event.get("skill_name", "")).strip_edges()
	return "h|%d|%d|%s|%s|%s" % [
		source_id,
		target_id,
		source_name,
		target_name,
		skill_name
	]


func _format_damage_event(event: Dictionary) -> String:
	var source: String = _fallback_name(str(event.get("source_name", "")), "未知来源")
	var target: String = _fallback_name(str(event.get("target_name", "")), "未知目标")
	var value: int = int(event.get("value", 0))
	var count: int = int(event.get("count", 1))
	var skill: String = str(event.get("skill_name", "")).strip_edges()
	var prefix: String = _team_marker(int(event.get("source_team", 0)))
	if not skill.is_empty():
		if count > 1:
			return "%s%s [%s] -> %s %d 伤 x%d" % [prefix, source, skill, target, value, count]
		return "%s%s [%s] -> %s %d 伤" % [prefix, source, skill, target, value]
	if count > 1:
		return "%s%s -> %s 共 %d 击 %d 伤" % [prefix, source, target, count, value]
	return "%s%s -> %s %d 伤" % [prefix, source, target, value]


func _format_heal_event(event: Dictionary) -> String:
	var source: String = _fallback_name(str(event.get("source_name", "")), "未知来源")
	var target: String = _fallback_name(str(event.get("target_name", "")), "未知目标")
	var value: int = int(event.get("value", 0))
	var count: int = int(event.get("count", 1))
	var skill: String = str(event.get("skill_name", "")).strip_edges()
	var prefix: String = _team_marker(int(event.get("source_team", 0)))
	if source == target:
		if not skill.is_empty():
			return "%s%s [%s] 恢复 %d" % [prefix, source, skill, value]
		return "%s%s 恢复 %d" % [prefix, source, value]
	if not skill.is_empty():
		return "%s%s [%s] -> %s 治疗 %d" % [prefix, source, skill, target, value]
	if count > 1:
		return "%s%s -> %s 治疗 %d x%d" % [prefix, source, target, value, count]
	return "%s%s -> %s 治疗 %d" % [prefix, source, target, value]


func _format_death_event(event: Dictionary) -> String:
	var dead_name: String = _fallback_name(str(event.get("target_name", "")), "未知单位")
	var killer_name: String = str(event.get("source_name", "")).strip_edges()
	var prefix: String = _team_marker(int(event.get("target_team", 0)))
	if killer_name.is_empty():
		return "%s%s 阵亡" % [prefix, dead_name]
	return "%s%s 被 %s 击杀" % [prefix, dead_name, killer_name]


func _format_skill_cast_event(event: Dictionary) -> String:
	var source: String = _fallback_name(str(event.get("source_name", "")), "未知来源")
	var skill: String = _fallback_name(str(event.get("skill_name", "")).strip_edges(), "技能")
	var prefix: String = _team_marker(int(event.get("source_team", 0)))
	return "%s%s 发动 [%s]" % [prefix, source, skill]


func _team_marker(team_id: int) -> String:
	if team_id == 1:
		return "▶"
	if team_id == 2:
		return "◀"
	return ""


func _fallback_name(value: String, fallback: String) -> String:
	var normalized: String = value.strip_edges()
	return fallback if normalized.is_empty() else normalized
