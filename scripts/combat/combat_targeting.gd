extends RefCounted
class_name CombatTargeting

const DOMAIN_RULES_SCRIPT: Script = preload("res://scripts/domain/combat/combat_targeting.gd")

var _rules = DOMAIN_RULES_SCRIPT.new()

# 兼容壳
# 说明：
# 1. 旧 runtime/test 仍按 owner 口径调用本文件。
# 2. 真正规则实现已迁到 scripts/domain/combat/combat_targeting.gd。
# 3. 这里仅做字段拆包和参数桥接。


# 每帧重建双方焦点时，owner 只负责提供当前缓存。
func update_group_ai_focus(owner: Node) -> void:
	_rules.update_group_ai_focus(
		owner.get("_group_focus_target_id"),
		owner.get("_group_center"),
		owner.get("_team_alive_cache")
	)


# 单队焦点更新继续沿用旧入口，便于 manager 无感迁移。
func update_team_focus(owner: Node, self_team: int, enemy_team: int) -> void:
	_rules.update_team_focus(
		owner.get("_group_focus_target_id"),
		owner.get("_group_center"),
		owner.get("_team_alive_cache"),
		self_team,
		enemy_team
	)


# 旧路径继续按 owner + unit 调用，但内部已切到 domain 规则。
func pick_target_for_unit(owner: Node, unit: Node) -> Node:
	return _rules.pick_target_for_unit(
		owner,
		unit,
		bool(owner.get("prioritize_targets_in_attack_range")),
		owner.get("_group_focus_target_id"),
		owner.get("_unit_by_instance_id"),
		owner.get("_spatial_hash"),
		owner.get("_team_alive_cache"),
		_get_target_memory(owner),
		_get_target_refresh_frame(owner),
		_get_logic_frame(owner),
		_get_target_rescan_interval(owner),
		_get_target_query_radius(owner)
	)


# 射程内目标筛选继续沿用旧签名，方便 effect smoke 和 manager 共用。
func pick_target_in_attack_range(owner: Node, unit: Node, enemy_team: int) -> Node:
	return _rules.pick_target_in_attack_range(
		owner,
		unit,
		enemy_team,
		owner.get("_spatial_hash"),
		owner.get("_unit_by_instance_id"),
		_get_target_memory(owner),
		_get_target_refresh_frame(owner),
		_get_logic_frame(owner),
		_get_target_rescan_interval(owner),
		_get_target_query_radius(owner),
		_get_hex_size_from_owner(owner)
	)


# 占格表反查单位的旧入口仍保留，供近战邻格攻击直接复用。
func get_occupant_unit_at_cell(owner: Node, cell: Vector2i) -> Node:
	return _rules.get_occupant_unit_at_cell(
		owner,
		cell,
		owner.get("_cell_occupancy"),
		owner.get("_unit_by_instance_id")
	)


# 攻击范围判定继续保持旧的 owner + attacker + target 契约。
func is_target_in_attack_range(owner: Node, attacker: Node, target: Node) -> bool:
	return _rules.is_target_in_attack_range(owner, attacker, target)


# target_query_radius 缺失时回退默认值，避免测试桩因为没导出属性而报错。
func _get_target_query_radius(owner: Node) -> float:
	var radius_value: Variant = owner.get("target_query_radius")
	if radius_value is float or radius_value is int:
		return radius_value
	return 420.0


# 测试桩可能还没挂接缓存字段；缺失时给空字典，保持旧入口可调用。
func _get_target_memory(owner: Node) -> Dictionary:
	var value: Variant = owner.get("_target_memory")
	return value if value is Dictionary else {}


# 重扫帧缓存与目标缓存一起缺省，避免测试桩只补一半字段时直接报错。
func _get_target_refresh_frame(owner: Node) -> Dictionary:
	var value: Variant = owner.get("_target_refresh_frame")
	return value if value is Dictionary else {}


# 某些 smoke test 不会提供运行时逻辑帧；字段缺失时按 0 处理即可。
func _get_logic_frame(owner: Node) -> int:
	var value: Variant = owner.get("_logic_frame")
	if value is int:
		return value
	if value is float:
		return int(value)
	return 0


# 重扫间隔保持固定倍率，避免高密度战斗把目标切换频率放大到不可接受。
func _get_target_rescan_interval(owner: Node) -> int:
	var interval_value: Variant = owner.get("target_rescan_interval_frames")
	if interval_value is float or interval_value is int:
		return maxi(int(interval_value), 1)
	return 2


# hex_size 只用于射程粗筛半径，不作为正式距离口径。
func _get_hex_size_from_owner(owner: Node) -> float:
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid == null or not is_instance_valid(hex_grid):
		return 0.0
	var hex_size_value: Variant = hex_grid.get("hex_size")
	if hex_size_value is float or hex_size_value is int:
		return hex_size_value
	return 0.0
