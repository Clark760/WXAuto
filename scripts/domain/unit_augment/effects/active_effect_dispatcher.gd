extends RefCounted
class_name UnitAugmentActiveEffectDispatcher

# dispatcher 只负责 `op -> callable` 路由。
# grouped ops 需要在这里注册并被持有，但具体业务实现不得回流。

const DAMAGE_OPS_SCRIPT: Script = preload("res://scripts/domain/unit_augment/effects/damage_resource_ops.gd")
const BUFF_OPS_SCRIPT: Script = preload("res://scripts/domain/unit_augment/effects/buff_control_ops.gd")
const MOVEMENT_OPS_SCRIPT: Script = preload("res://scripts/domain/unit_augment/effects/movement_control_ops.gd")
const SUMMON_OPS_SCRIPT: Script = preload("res://scripts/domain/unit_augment/effects/summon_terrain_ops.gd")
const TAG_LINKAGE_OPS_SCRIPT: Script = preload("res://scripts/domain/unit_augment/effects/tag_linkage_ops.gd")

var _routes: Dictionary = {}
var _op_groups: Array[Variant] = []

# `summary_collector` 负责写结算摘要，`query_service` / `hex_spatial_service` 只提供纯查询能力。
# dispatcher 只装配这些依赖，不在这里解释具体 op 语义。
# `hex_spatial_service` 只服务位移和地形类 op，普通伤害/治疗路由不应依赖它的内部细节。
func _init(
	summary_collector: Variant,
	query_service: Variant,
	hex_spatial_service: Variant
) -> void:
	var damage_ops: Variant = DAMAGE_OPS_SCRIPT.new(summary_collector, query_service)
	var buff_ops: Variant = BUFF_OPS_SCRIPT.new(summary_collector, query_service)
	var movement_ops: Variant = MOVEMENT_OPS_SCRIPT.new(
		summary_collector,
		query_service,
		hex_spatial_service
	)
	var summon_ops: Variant = SUMMON_OPS_SCRIPT.new(summary_collector, query_service)
	var tag_linkage_ops: Variant = TAG_LINKAGE_OPS_SCRIPT.new(Callable(self, "_execute_child_effect"))

# dispatcher 必须长期持有 grouped ops。
# 否则这些 RefCounted 会在 _init 返回后被释放，route 里的 callable 会全部失效。
	_op_groups = [damage_ops, buff_ops, movement_ops, summon_ops, tag_linkage_ops]

	damage_ops.register_routes(_routes)
	buff_ops.register_routes(_routes)
	movement_ops.register_routes(_routes)
	summon_ops.register_routes(_routes)
	tag_linkage_ops.register_routes(_routes)


# dispatcher 只根据 `effect.op` 做路由，不再承载具体 op 实现。
# `runtime_gateway` 负责落地旧运行时交互，`summary` 只记录已经实际生效的结果。
# 缺失处理器时保持“告警后跳过”的旧容错语义，避免整条 effect 链中断。
func execute_active_op(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var op: String = str(effect.get("op", "")).strip_edges()
	if op.is_empty():
		return

	var route_value: Variant = _routes.get(op, Callable())
	if not (route_value is Callable):
		push_warning("UnitAugmentEffectEngine: 未实现效果?op=%s" % op)
		return

	var route: Callable = route_value as Callable
	if not route.is_valid():
		push_warning("UnitAugmentEffectEngine: 无效效果处理器 op=%s" % op)
		return

	route.callv([runtime_gateway, source, target, effect, context, summary])


# 子效果要复用同一条 dispatch 链，才能保持 summary 和 runtime context 口径一致。
# `context` 里挂着 facade 注入的 runtime gateway，递归执行时不能丢失这份兼容依赖。
# `summary` 继续沿用同一份字典，避免分支效果各自统计后再拼接。
func _execute_child_effect(
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var runtime_gateway: Variant = context.get("_unit_augment_runtime_gateway", null)
	if runtime_gateway == null:
		return

	execute_active_op(runtime_gateway, source, target, effect, context, summary)
