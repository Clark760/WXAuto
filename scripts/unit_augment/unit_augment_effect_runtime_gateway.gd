extends RefCounted
class_name UnitAugmentEffectRuntimeGateway

# 兼容网关：这里只承接 effect 层与旧运行时对象的交互。
# 新增方法必须说明它依赖了哪个旧对象，以及为什么不能继续留在 domain service。

const QUERY_SERVICE_SCRIPT: Script = preload("res://scripts/domain/unit_augment/effects/target_query_service.gd")
const HEX_SPATIAL_SERVICE_SCRIPT: Script = preload("res://scripts/domain/unit_augment/effects/hex_spatial_service.gd")

var _query_service: Variant = QUERY_SERVICE_SCRIPT.new()
var _hex_spatial_service: Variant = HEX_SPATIAL_SERVICE_SCRIPT.new()
var _last_damage_meta: Dictionary = {}
var _combat_units_in_cells_scratch: Array[Node] = []


# `query_service` 只负责目标与距离查询，`hex_spatial_service` 只负责格子算法。
# 这里把它们作为依赖传入，是为了避免 gateway 反向抓取全局单例。
# gateway 只消费查询结果，不在这里重新解释查询或空间算法本身。
func _init(
	query_service: Variant = null,
	hex_spatial_service: Variant = null
) -> void:
	if query_service != null:
		_query_service = query_service
	if hex_spatial_service != null:
		_hex_spatial_service = hex_spatial_service


# 把最近一次伤害的吸收信息暴露给 summary collector。
# 返回副本而不是原字典，避免外层统计逻辑意外改写 gateway 缓存。
func get_last_damage_meta() -> Dictionary:
	return _last_damage_meta.duplicate(true)


# 每次结算新伤害前都要清空缓存，避免把上一条伤害的吸收结果带到下一条。
# 这个缓存只服务“最近一次伤害事件”的摘要收集，不承载长期状态。
func clear_last_damage_meta() -> void:
	_last_damage_meta = {}


# 伤害实际结算仍然走 `UnitCombat`，gateway 只负责兼容交互。
# `source` 是伤害来源上下文，`target` 必须能提供 `Components/UnitCombat`。
# 返回值是旧 combat 口径下的实际伤害，不是输入的理论伤害。
func deal_damage(source: Node, target: Node, amount: float, damage_type: String) -> float:
	# 这里缓存最近一次伤害的护盾/免疫吸收结果。
	# 后续 summary collector 会直接消费这份元数据。
	_last_damage_meta = {"shield_absorbed": 0.0, "immune_absorbed": 0.0}
	if target == null or not is_instance_valid(target):
		return 0.0

	var combat = target.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0

	var result: Dictionary = combat.receive_damage(
		maxf(amount, 0.0),
		source,
		damage_type,
		true,
		false,
		false
	)
	_last_damage_meta["shield_absorbed"] = float(result.get("shield_absorbed", 0.0))
	_last_damage_meta["immune_absorbed"] = float(result.get("immune_absorbed", 0.0))
	return float(result.get("damage", 0.0))


# 治疗放大沿用 `source` 当前外部 modifier，避免口径分叉。
# `source` 在这里不是治疗目标，而是可能提供 healing_amp 的施加者。
# 返回值固定是目标生命实际增加量，满血溢出部分会被丢弃。
func heal_unit(target: Node, amount: float, source: Node = null) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0

	var combat = target.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0

	var final_amount: float = maxf(amount, 0.0)
	if source != null and is_instance_valid(source):
		var source_combat = source.get_node_or_null("Components/UnitCombat")
		if source_combat != null and source_combat.has_method("get_external_modifiers"):
			var modifiers_value: Variant = source_combat.get_external_modifiers()
			if modifiers_value is Dictionary:
				var healing_amp: float = float((modifiers_value as Dictionary).get("healing_amp", 0.0))
				final_amount *= maxf(1.0 + healing_amp, 0.0)

	var before_hp: float = float(combat.get("current_hp"))
	combat.restore_hp(final_amount)
	var after_hp: float = float(combat.get("current_hp"))
	return maxf(after_hp - before_hp, 0.0)


# MP 恢复与治疗一样统一返回“实际变化量”。
# 这样 effect 层只关心最终回蓝多少，不需要知道旧 combat 组件的上限裁剪细节。
func restore_mp_unit(target: Node, amount: float) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0

	var combat = target.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0

	var before_mp: float = float(combat.get("current_mp"))
	combat.add_mp(maxf(amount, 0.0))
	var after_mp: float = float(combat.get("current_mp"))
	return maxf(after_mp - before_mp, 0.0)


# Buff 入口保留 `application_key` 兼容，以支持 source_bound_aura 和同源多实例。
# `effect.buff_id/duration/application_key` 会被翻译成旧 BuffManager 所需参数。
# `context` 只负责提供运行时 `buff_manager`，不会在这里决定 Buff 语义。
func apply_buff_op(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> bool:
	if target == null or not is_instance_valid(target):
		return false

	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager == null:
		return false

	var buff_id: String = str(effect.get("buff_id", "")).strip_edges()
	if buff_id.is_empty():
		return false

	var duration: float = float(effect.get("duration", 0.0))
	var application_key: String = str(effect.get("application_key", "")).strip_edges()
	if not application_key.is_empty() and buff_manager.has_method("apply_buff_with_options"):
		# 同源多实例或光环实例需要带 application_key，避免被旧 `(buff_id, source_id)` 桶意外合并。
		# 普通 Buff 没有 application_key 时仍走旧接口，保持历史调用兼容。
		return bool(buff_manager.apply_buff_with_options(
			target,
			buff_id,
			duration,
			source,
			{"application_key": application_key}
		))

	return bool(buff_manager.apply_buff(target, buff_id, duration, source))


# 动态光环是运行时生命周期，不再依赖 `effect.duration`。
# 这里只判 `binding_mode` 字符串，真正的 enter/exit 生命周期由 BuffManager 维护。
func is_source_bound_aura_binding(effect: Dictionary) -> bool:
	return str(effect.get("binding_mode", "default")).strip_edges().to_lower() == "source_bound_aura"


# `targets` 是本轮 passive aura 轮询命中的完整目标快照。
# `context` 里会携带作用域 key 和 refresh token，用于让 BuffManager 做 enter/exit diff。
# `effect.buff_id` 决定附着内容，`scope_key` 决定同源不同光环实例的隔离边界。
func execute_source_bound_aura_op(
	source: Node,
	effect: Dictionary,
	targets: Array[Node],
	context: Dictionary
) -> Dictionary:
	if source == null or not is_instance_valid(source):
		return {"applied_count": 0, "applied_targets": []}

	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager == null or not buff_manager.has_method("refresh_source_bound_aura"):
		return {"applied_count": 0, "applied_targets": []}

	var buff_id: String = str(effect.get("buff_id", "")).strip_edges()
	if buff_id.is_empty():
		return {"applied_count": 0, "applied_targets": []}

	var scope_key: String = str(context.get("source_bound_aura_scope_key", "")).strip_edges()
	if scope_key.is_empty():
		# 没显式传作用域时，回退到“source 实例 + 默认作用域”，保证至少能稳定清理。
		scope_key = "%d|fallback_scope" % source.get_instance_id()

	var scope_refresh_token: int = int(context.get("source_bound_aura_scope_token", 0))
	var aura_key: String = build_source_bound_aura_key(source, effect, scope_key)
	# refresh 接口内部会自己做 enter/exit diff，这里只负责提供本轮完整快照和稳定主键。
	# source 死亡时也依赖这组 key 做即时清理，因此 key 口径必须和刷新时保持一致。
	return buff_manager.refresh_source_bound_aura(
		source,
		buff_id,
		aura_key,
		scope_key,
		scope_refresh_token,
		targets,
		context
	)


# `scope_key` 用来隔离同一 source 上不同 aura 实例，避免 effect 内容相同但语义不同的光环互相覆盖。
# `effect` 会被序列化成签名，保证同一配表在同一来源下得到稳定主键。
func build_source_bound_aura_key(source: Node, effect: Dictionary, scope_key: String) -> String:
	var effect_signature: String = var_to_str(effect)
	if not scope_key.is_empty():
		return "%s|%s" % [scope_key, effect_signature]
	if source == null or not is_instance_valid(source):
		return effect_signature
	return "%d|%s" % [source.get_instance_id(), effect_signature]




# mark 优先走 Buff，这样状态栏、驱散和条件判断都能复用。
# 当 `mark_id` 没有对应 Buff 定义时，才回退到 `runtime_marks` 的 meta 方案。
# 返回值只表示“是否成功写入标记状态”，不区分 Buff 路径还是 meta 路径。
func apply_mark_target_op(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> bool:
	if target == null or not is_instance_valid(target):
		return false

	var mark_id: String = str(effect.get("mark_id", "")).strip_edges()
	if mark_id.is_empty():
		return false

	var duration: float = float(effect.get("duration", 5.0))
	var mark_effect: Dictionary = {
		"buff_id": mark_id,
		"duration": duration
	}
	if apply_buff_op(source, target, mark_effect, context):
		return true

	var marks: Dictionary = target.get_meta("runtime_marks", {})
	var expire_time: float = float(context.get("battle_elapsed", 0.0)) + maxf(duration, 0.1)
	# 只有 Buff 路径缺失时才回退到 meta 标记，因此这里把过期时间直接写成最小可用结构。
	marks[mark_id] = expire_time
	target.set_meta("runtime_marks", marks)
	return true


# mark 的兜底实现仍支持 `runtime_marks`，兼容未定义 Buff 的旧效果。
# 这里会优先查询 Debuff/Buff 语义，只有没有命中时才回退到 meta 记录。
# 过期的 meta 标记会在查询时顺手清理，避免旧状态长期残留。
func target_has_mark(target: Node, mark_id: String, context: Dictionary) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if mark_id.strip_edges().is_empty():
		return false
	if _query_service.target_has_debuff(target, mark_id):
		return true

	var marks: Dictionary = target.get_meta("runtime_marks", {})
	# meta 标记是旧兜底路径，因此查询时顺手做过期清理，避免它长期污染条件判断。
	if not marks.has(mark_id):
		return false

	var expire_time: float = float(marks.get(mark_id, 0.0))
	var now_time: float = float(context.get("battle_elapsed", 0.0))
	if expire_time <= now_time:
		marks.erase(mark_id)
		target.set_meta("runtime_marks", marks)
		return false

	return true


# 控制状态仍然通过 meta 写入，先保持旧行为兼容。
# `control_type` 只负责选择写入哪组 meta 键，具体可视 Debuff 由上层 ops 决定。
# `context.battle_elapsed` 与真实时间会并行使用，以兼容旧沉默/眩晕口径差异。
func apply_control_state(target: Node, control_type: String, duration: float, context: Dictionary = {}) -> void:
	if target == null or not is_instance_valid(target):
		return

	var logic_now: float = float(context.get("battle_elapsed", 0.0))
	var until_logic: float = logic_now + maxf(duration, 0.05)
	var real_now: float = float(Time.get_ticks_msec()) * 0.001
	var until_real: float = real_now + maxf(duration, 0.05)

	match control_type:
		"silence":
			# 沉默沿用真实时间戳，兼容旧输入/施法锁定链路的读取方式。
			target.set_meta("status_silence_until", maxf(float(target.get_meta("status_silence_until", 0.0)), until_real))
		"stun":
			# 眩晕和恐惧走逻辑时间，便于战斗暂停或变速时保持和战斗帧同步。
			target.set_meta("status_stun_until", maxf(float(target.get_meta("status_stun_until", 0.0)), until_logic))
		"fear":
			target.set_meta("status_fear_until", maxf(float(target.get_meta("status_fear_until", 0.0)), until_logic))
		_:
			return


# 嘲讽除了持续时间，还要同步记录来源单位，旧 combat 逻辑会依赖这个来源。
# `source` 提供实例 id 和 team_id，便于旧索敌逻辑知道要强制朝谁开火。
func apply_taunt_state(target: Node, source: Node, duration: float, context: Dictionary) -> void:
	if target == null or not is_instance_valid(target):
		return

	var now_logic: float = float(context.get("battle_elapsed", 0.0))
	var until_logic: float = now_logic + maxf(duration, 0.05)
	target.set_meta("status_taunt_until", maxf(float(target.get_meta("status_taunt_until", 0.0)), until_logic))

	if source != null and is_instance_valid(source):
		# 旧嘲讽逻辑会按来源 id 与队伍强制索敌，所以这里同时记录两份信息。
		target.set_meta("status_taunt_source_id", source.get_instance_id())
		target.set_meta("status_taunt_source_team", int(source.get("team_id")))


# `effect` 里的视觉字段只是表现层配置，gateway 负责把它翻译成旧 VFXFactory 调用。
# `effect.at` 只支持 `self/target` 两种锚点语义，真正播放仍交给旧 `vfx_factory`。
func spawn_vfx_by_effect(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> void:
	var vfx_factory: Node = context.get("vfx_factory", null)
	if vfx_factory == null:
		return

	var vfx_id: String = str(effect.get("vfx_id", "")).strip_edges()
	if vfx_id.is_empty():
		return

	var at: String = str(effect.get("at", "self")).strip_edges().to_lower()
	var from_pos: Vector2 = _query_service.node_pos(source)
	var to_pos: Vector2 = _query_service.node_pos(source)

	if at == "target":
		# `at = target` 时只切换播放终点，起点仍保持 source 位置。
		to_pos = _query_service.node_pos(target)

	vfx_factory.play_attack_vfx(vfx_id, from_pos, to_pos)


# `effect` 是召唤配置，`context` 提供 battlefield、hex_grid 和现有单位快照。
# gateway 负责把 effect 口径翻译成旧 summon 接口能接受的 rows。
# `effect.units` 是 declarative 配置，真正的部署区、固定格和克隆来源都在这里补齐。
func execute_summon_units_op(source: Node, effect: Dictionary, context: Dictionary) -> int:
	var battlefield: Node = context.get("battlefield", null)
	if battlefield == null or not is_instance_valid(battlefield):
		return 0
	if not battlefield.has_method("spawn_enemy_wave"):
		return 0

	var units_value: Variant = effect.get("units", null)
	if not (units_value is Array) or (units_value as Array).is_empty():
		units_value = _build_summon_units_rows_from_shorthand(effect)
		if not (units_value is Array) or (units_value as Array).is_empty():
			return 0

	var source_unit_id: String = str(source.get("unit_id")) if source != null and is_instance_valid(source) else ""
	var deploy_mode: String = str(effect.get("deploy", "around_self")).strip_edges().to_lower()
	var radius_cells: int = maxi(int(effect.get("radius", 2)), 0)
	var hex_grid: Variant = context.get("hex_grid", null)
	var fixed_cells_from_effect: Array[Vector2i] = _parse_vector2i_cells(effect.get("cells", []))
	var rows: Array[Dictionary] = []

	for row_value in (units_value as Array):
		if not (row_value is Dictionary):
			continue

		var row: Dictionary = (row_value as Dictionary).duplicate(true)
		# `clone_source = self` 时，把当前 source 的 unit_id 显式抄进召唤行配置。
		var clone_source: String = str(row.get("clone_source", "")).strip_edges().to_lower()
		if clone_source == "self":
			if source_unit_id.is_empty():
				continue
			row["unit_id"] = source_unit_id

		var unit_id: String = str(row.get("unit_id", "")).strip_edges()
		var count: int = maxi(int(row.get("count", 1)), 0)
		if unit_id.is_empty() or count <= 0:
			continue

		if not fixed_cells_from_effect.is_empty():
			row["deploy_zone"] = "fixed"
			row["fixed_cells"] = fixed_cells_from_effect
		elif deploy_mode == "around_self" and source != null and is_instance_valid(source):
			# 环绕召唤优先转成固定格列表，只有拿不到可用格时才回退到 back 部署区。
			var center_cell: Vector2i = Vector2i(-1, -1)
			if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
				center_cell = hex_grid.world_to_axial(
					_query_service.node_pos(source)
				)
			var candidate_cells: Array[Vector2i] = _hex_spatial_service.collect_cells_in_radius(
				hex_grid,
				center_cell,
				radius_cells
			)
			if not candidate_cells.is_empty():
				row["deploy_zone"] = "fixed"
				row["fixed_cells"] = candidate_cells
			else:
				row["deploy_zone"] = "back"
		else:
			row["deploy_zone"] = deploy_mode

		rows.append(row)

	if rows.is_empty():
		return 0

	# 最终仍统一走 `spawn_enemy_wave`，让旧战场自己决定实例化和落位顺序。
	return int(battlefield.spawn_enemy_wave(rows))


# 危险区仍交给 BuffManager 维护生命周期。
# gateway 负责把 effect 配置翻译成旧 BuffManager 能识别的战场效果结构。
# `effect.value` 先按 DPS 解释，再结合 `tick_interval` 换算成每跳伤害。
func execute_hazard_zone_op(source: Node, effect: Dictionary, context: Dictionary) -> int:
	# 危险区配置先在这里翻译成旧 BuffManager 能识别的结构。
	# 这样 summon/terrain op 本身不需要知道旧字段细节。
	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager == null or not buff_manager.has_method("add_battlefield_effect"):
		return 0
	if source != null and is_instance_valid(source) and not _is_unit_in_combat(source):
		return 0

	var hex_grid: Variant = context.get("hex_grid", null)
	if hex_grid == null or not is_instance_valid(hex_grid):
		return 0
	var combat_manager: Variant = context.get("combat_manager", null)

	var count: int = maxi(int(effect.get("count", 1)), 1)
	var radius_cells: int = maxi(int(effect.get("radius_cells", effect.get("radius", 2))), 0)
	var duration: float = maxf(float(effect.get("duration", 6.0)), 0.1)
	var warning_seconds: float = maxf(float(effect.get("warning_seconds", 0.0)), 0.0)
	var tick_interval: float = maxf(float(effect.get("tick_interval", 0.5)), 0.05)
	var tick_effect: Dictionary = _resolve_hazard_tick_effect(effect, tick_interval)
	if tick_effect.is_empty():
		return 0

	var center_mode: String = str(effect.get("target_mode", "random_position")).strip_edges().to_lower()
	var affect_mode: String = str(effect.get("affect_mode", "enemies")).strip_edges().to_lower()
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	var created: int = 0
	var source_cell: Vector2i = Vector2i(-1, -1)
	if center_mode == "around_self":
		source_cell = _resolve_unit_combat_cell(source, combat_manager)
		if source_cell.x < 0:
			return 0

	for index in range(count):
		# 每个危险区都单独生成 effect_id，便于旧系统按实例跟踪移除。
		var center_cell: Vector2i = _hex_spatial_service.pick_hazard_center_cell(
			center_mode,
			source,
			hex_grid,
			radius_cells,
			_query_service
		)
		if center_mode == "around_self":
			var cell_pool: Array[Vector2i] = _hex_spatial_service.collect_cells_in_radius(
				hex_grid,
				source_cell,
				radius_cells
			)
			if cell_pool.is_empty():
				center_cell = source_cell
			else:
				cell_pool.shuffle()
				center_cell = cell_pool[0]
		if center_cell.x < 0:
			continue

		var effect_id: String = "hazard_zone_%d_%d" % [Time.get_ticks_msec(), index]
		var battlefield_effect: Dictionary = {
			"effect_id": effect_id,
			"center_cell": center_cell,
			"radius_cells": radius_cells,
			"target_mode": affect_mode,
			"duration": duration,
			"warning_seconds": warning_seconds,
			"tick_interval": tick_interval,
			"source_team": source_team,
			"tick_effects": [tick_effect]
		}
		# tick_effects 继续沿用普通 effect 配置格式，方便旧 BuffManager 直接复用主动效果链。
		# battlefield_effect 自身只负责区域生命周期，不在这里预先结算任何一跳伤害。
		var ok: bool = bool(buff_manager.add_battlefield_effect(battlefield_effect, source))
		if ok:
			created += 1

	return created


# 地形 effect 只负责传配置，不在 op 层直接碰旧 combat manager。
# gateway 则负责兼容 `CombatManager.add_temporary_terrain` 的旧入口。
# `effect.at` 决定以 source 还是 target 为锚点，实际落点定位优先走 combat 的逻辑格。
func apply_create_terrain_op(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> bool:
	var combat_manager: Variant = context.get("combat_manager", null)
	var hex_grid: Variant = context.get("hex_grid", null)
	if combat_manager == null or not is_instance_valid(combat_manager):
		return false
	if hex_grid == null or not is_instance_valid(hex_grid):
		return false
	if not combat_manager.has_method("add_temporary_terrain"):
		return false
	if source != null and is_instance_valid(source) and not _is_unit_in_combat(source):
		return false

	var at_mode: String = str(effect.get("at", "target")).strip_edges().to_lower()
	var anchor: Node = source
	if at_mode == "target" and target != null and is_instance_valid(target):
		anchor = target

	var center_cell: Vector2i = _resolve_unit_combat_cell(anchor, combat_manager)
	if center_cell.x < 0:
		return false

	var terrain_ref_id: String = str(effect.get("terrain_ref_id", "")).strip_edges().to_lower()
	var terrain_type: String = str(effect.get("terrain_type", "")).strip_edges().to_lower()
	if terrain_ref_id.is_empty() and terrain_type.is_empty():
		terrain_type = "fire"

	var terrain_config: Dictionary = {
		"terrain_id": "terrain_%d_%s" % [
			Time.get_ticks_msec(),
			terrain_type if not terrain_type.is_empty() else terrain_ref_id
		],
		"center_cell": center_cell,
		"radius": maxi(int(effect.get("radius", 1)), 0),
		"duration": maxf(float(effect.get("duration", 1.0)), 0.1),
		"target_mode": str(effect.get("target_mode", "")).strip_edges().to_lower()
	}
	# terrain_config 保留 effect 原始字段的同名键，方便旧地形系统少做一层翻译。

	if effect.has("tick_interval"):
		terrain_config["tick_interval"] = maxf(float(effect.get("tick_interval", 0.5)), 0.05)
	if not terrain_ref_id.is_empty():
		terrain_config["terrain_ref_id"] = terrain_ref_id
	if not terrain_type.is_empty():
		terrain_config["terrain_type"] = terrain_type
	if effect.has("cells"):
		terrain_config["cells"] = effect.get("cells", [])
	if effect.has("tags"):
		terrain_config["tags"] = effect.get("tags", [])
	if effect.has("is_barrier"):
		terrain_config["is_barrier"] = bool(effect.get("is_barrier", false))
	if effect.has("effects_on_enter"):
		terrain_config["effects_on_enter"] = effect.get("effects_on_enter", [])
	if effect.has("effects_on_tick"):
		terrain_config["effects_on_tick"] = effect.get("effects_on_tick", [])
	if effect.has("effects_on_exit"):
		terrain_config["effects_on_exit"] = effect.get("effects_on_exit", [])
	if effect.has("effects_on_expire"):
		terrain_config["effects_on_expire"] = effect.get("effects_on_expire", [])

	return bool(combat_manager.add_temporary_terrain(terrain_config, source))


# 兼容手册里的 summon_units 简写：`unit_ids + count(+star/team)`。
func _build_summon_units_rows_from_shorthand(effect: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var unit_ids_value: Variant = effect.get("unit_ids", [])
	if not (unit_ids_value is Array):
		return rows

	var default_count: int = maxi(int(effect.get("count", 1)), 1)
	var has_star: bool = effect.has("star")
	var has_team: bool = effect.has("team")
	for unit_id_value in (unit_ids_value as Array):
		var unit_id: String = str(unit_id_value).strip_edges()
		if unit_id.is_empty():
			continue
		var row: Dictionary = {
			"unit_id": unit_id,
			"count": default_count
		}
		if has_star:
			row["star"] = int(effect.get("star", 1))
		if has_team:
			row["team"] = int(effect.get("team", 0))
		rows.append(row)
	return rows


# `cells` 允许写成 `[[x,y], ...]` 或 `[{x,y}, ...]`，统一转为 `Array[Vector2i]`。
func _parse_vector2i_cells(raw: Variant) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if not (raw is Array):
		return cells
	for cell_value in (raw as Array):
		if cell_value is Array and (cell_value as Array).size() >= 2:
			cells.append(Vector2i(int((cell_value as Array)[0]), int((cell_value as Array)[1])))
		elif cell_value is Dictionary:
			var cell_dict: Dictionary = cell_value as Dictionary
			if not cell_dict.has("x") or not cell_dict.has("y"):
				continue
			cells.append(Vector2i(int(cell_dict.get("x", 0)), int(cell_dict.get("y", 0))))
	return cells


# hazard_zone 兼容两种写法：
# 1) `value` 视作 DPS（旧写法）；
# 2) `effects_on_tick` 直接提供每跳效果（手册写法）。
func _resolve_hazard_tick_effect(effect: Dictionary, tick_interval: float) -> Dictionary:
	var effects_on_tick_value: Variant = effect.get("effects_on_tick", [])
	if effects_on_tick_value is Array and not (effects_on_tick_value as Array).is_empty():
		var first_effect: Variant = (effects_on_tick_value as Array)[0]
		if first_effect is Dictionary:
			var tick_effect: Dictionary = (first_effect as Dictionary).duplicate(true)
			if str(tick_effect.get("op", "")).strip_edges().is_empty():
				tick_effect["op"] = "damage_target"
			return tick_effect

	var dps: float = maxf(float(effect.get("value", 0.0)), 0.0)
	if dps <= 0.0:
		return {}
	return {
		"op": "damage_target",
		"value": dps * tick_interval,
		"damage_type": str(effect.get("damage_type", "internal")).strip_edges().to_lower()
	}


func _is_unit_in_combat(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	return bool(unit.get("is_in_combat"))


func _resolve_unit_combat_cell(unit: Node, combat_manager: Variant) -> Vector2i:
	if unit == null or not is_instance_valid(unit):
		return Vector2i(-1, -1)
	if not _is_unit_in_combat(unit):
		return Vector2i(-1, -1)
	if combat_manager == null or not is_instance_valid(combat_manager):
		return Vector2i(-1, -1)
	if not combat_manager.has_method("get_unit_cell_of"):
		return Vector2i(-1, -1)
	var cell_value: Variant = combat_manager.get_unit_cell_of(unit)
	if cell_value is Vector2i:
		return cell_value as Vector2i
	return Vector2i(-1, -1)
