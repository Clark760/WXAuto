extends RefCounted
class_name UnitAugmentSummonTerrainOps

# summon/terrain op 只组装战场副作用请求。
# 真正与 battlefield/combat 的交互仍经由 gateway。

var _summary_collector: Variant
var _query_service: Variant


# `summary_collector` 负责累计召唤与危险区数量，`query_service` 用于复活和选点。
# 这里不直接持有 battlefield/combat 旧对象，所有运行时交互都交给 gateway。
func _init(
	summary_collector: Variant,
	query_service: Variant
) -> void:
	_summary_collector = summary_collector
	_query_service = query_service


# 召唤、地形和视觉效果都属于“向战场添加新对象/副作用”的一组。
# `routes` 只建立 `op -> handler` 的映射，具体兼容逻辑继续留在 gateway。
func register_routes(routes: Dictionary) -> void:
	routes["create_terrain"] = Callable(self, "_create_terrain")
	routes["summon_units"] = Callable(self, "_summon_units")
	routes["hazard_zone"] = Callable(self, "_hazard_zone")
	routes["spawn_vfx"] = Callable(self, "_spawn_vfx")
	routes["summon_clone"] = Callable(self, "_summon_clone")
	routes["revive_random_ally"] = Callable(self, "_revive_random_ally")
	routes["resurrect_self"] = Callable(self, "_resurrect_self")


# 地形创建不改 summary，只负责把 effect 配置转成旧地形系统能接受的调用。
# `effect` 决定地形配置，`context` 负责提供旧 combat / hex grid 依赖。
func _create_terrain(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	# 地形创建的成败由旧 combat manager 决定，这里只负责透传配置。
	runtime_gateway.apply_create_terrain_op(source, target, effect, context)


# 普通召唤只累计新增数量，不在这里关心每个单位的后续战斗状态。
# `summary.summon_total` 只统计成功创建的数量，不记录配置里声明的理论数量。
func _summon_units(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var summoned_count: int = runtime_gateway.execute_summon_units_op(source, effect, context)
	# 召唤统计只看 gateway 的实际返回值，方便旧战场接口部分失败时仍能得到真实数量。
	summary["summon_total"] = int(summary.get("summon_total", 0)) + summoned_count


# 危险区和召唤一样都是新增战场对象，但生命周期交给旧 battlefield effect 系统。
# `summary.hazard_total` 只累计成功注册的区域数量，后续 tick 伤害不在这里结算。
func _hazard_zone(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var created_count: int = runtime_gateway.execute_hazard_zone_op(source, effect, context)
	# 危险区的后续 tick 伤害不在这里累加，这里只负责“成功创建了几个区”。
	summary["hazard_total"] = int(summary.get("hazard_total", 0)) + created_count


# 视觉效果只改表现，不改结算结果，因此不会写入 summary。
# `effect` 里的 `vfx_id/at` 由 gateway 翻译成旧 VFXFactory 的调用参数。
func _spawn_vfx(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	# 视觉效果不写 summary，因此这里只保持一个干净的转发入口。
	runtime_gateway.spawn_vfx_by_effect(source, target, effect, context)


# 克隆本质上只是构造一条 `summon_units` 配置。
# `effect` 里出现的 `unit_id/hp_ratio/atk_ratio` 都会被整理成单条 summon row。
func _summon_clone(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	if source == null or not is_instance_valid(source):
		return

	var clone_count: int = maxi(int(effect.get("count", 1)), 1)
	# clone_row 会被翻译成普通召唤行，因此这里先把克隆语义收敛到统一字段集。
	var clone_row: Dictionary = {
		"clone_source": "self",
		"count": clone_count
	}

	if effect.has("unit_id"):
		var unit_id: String = str(effect.get("unit_id", "")).strip_edges()
		if not unit_id.is_empty():
			clone_row["unit_id"] = unit_id

	var inherit_ratio: float = maxf(float(effect.get("inherit_ratio", -1.0)), -1.0)
	if effect.has("hp_ratio"):
		clone_row["hp_ratio"] = maxf(float(effect.get("hp_ratio", 1.0)), 0.01)
	elif inherit_ratio >= 0.0:
		clone_row["hp_ratio"] = maxf(inherit_ratio, 0.01)
	if effect.has("atk_ratio"):
		clone_row["atk_ratio"] = maxf(float(effect.get("atk_ratio", 1.0)), 0.01)
	elif inherit_ratio >= 0.0:
		clone_row["atk_ratio"] = maxf(inherit_ratio, 0.01)

	var summon_effect: Dictionary = {
		"units": [clone_row],
		"deploy": str(effect.get("deploy", "around_self")).strip_edges().to_lower(),
		"radius": maxi(int(effect.get("radius", 2)), 0)
	}
	var summoned_count: int = runtime_gateway.execute_summon_units_op(source, summon_effect, context)
	summary["summon_total"] = int(summary.get("summon_total", 0)) + summoned_count


# 随机复活延续旧规则：只从己方已死亡单位中随机挑一个。
# `effect.value` 优先表示固定治疗量，缺省时才回退到 `hp_percent` 百分比复活。
func _revive_random_ally(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	if source == null or not is_instance_valid(source):
		return

	var source_team: int = int(source.get("team_id"))
	var dead_allies: Array[Node] = []
	for unit in _query_service.get_all_units(context):
		if unit == null or not is_instance_valid(unit):
			continue
		if source_team != 0 and int(unit.get("team_id")) != source_team:
			continue

		var combat = unit.get_node_or_null("Components/UnitCombat")
		if combat == null:
			continue
		if bool(combat.get("is_alive")):
			continue

		dead_allies.append(unit)

	if dead_allies.is_empty():
		return

	var revived_unit: Node = dead_allies[randi() % dead_allies.size()]
	var revived_combat = revived_unit.get_node_or_null("Components/UnitCombat")
	if revived_combat == null:
		return

	var max_hp: float = maxf(float(revived_combat.get("max_hp")), 1.0)
	var revive_value: float = maxf(float(effect.get("value", 0.0)), 0.0)
	var revive_percent: float = clampf(
		float(effect.get("hp_percent", effect.get("hp_ratio", 0.35))),
		0.01,
		1.0
	)
	# 固定治疗量优先级高于百分比，便于配表明确覆盖默认复活比例。
	var restore_amount: float = revive_value if revive_value > 0.0 else max_hp * revive_percent
	var healed: float = runtime_gateway.heal_unit(revived_unit, restore_amount, source)
	if healed <= 0.0:
		return

	var combat_manager: Variant = context.get("combat_manager", null)
	if combat_manager != null and combat_manager.has_method("add_unit_mid_battle"):
		# 旧战斗链路需要显式把复活单位重新登记回战场管理器。
		combat_manager.add_unit_mid_battle(revived_unit)

	summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed
	_summary_collector.append_heal_event(summary, source, revived_unit, healed, "revive_random_ally")


# 自复活只允许每个 `resurrect_key` 使用一次，保持旧状态机语义。
# 这里直接改 source 的生命与 meta，不额外写 summary，避免把被动保命误记成主动治疗。
func _resurrect_self(
	_runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	_context: Dictionary,
	_summary: Dictionary
) -> void:
	if source == null or not is_instance_valid(source):
		return

	var resurrect_key: String = "resurrect_used_%s" % str(effect.get("resurrect_key", "default"))
	# resurrect_key 允许同一单位拥有多条互不冲突的一次性保命效果。
	if bool(source.get_meta(resurrect_key, false)):
		return

	var source_combat = source.get_node_or_null("Components/UnitCombat")
	if source_combat == null:
		return

	# 自复活直接修改自身 combat 状态，保留旧“保命被动不进主动结算摘要”的语义。
	var hp_percent: float = clampf(
		float(effect.get("hp_percent", effect.get("hp_ratio", 0.3))),
		0.01,
		1.0
	)
	var max_hp: float = maxf(float(source_combat.get("max_hp")), 1.0)
	# 自复活只恢复生命并打标记，不在这里补额外事件，以免污染主动治疗日志。
	source_combat.restore_hp(max_hp * hp_percent)
	source.set_meta(resurrect_key, true)
