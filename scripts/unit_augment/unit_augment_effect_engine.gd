extends RefCounted
class_name UnitAugmentEffectEngine

# facade 只保留公开契约与服务装配。
# 旧入口仍可通过兼容壳访问真实实现，但业务 helper 不得回流到这里。

const SUMMARY_COLLECTOR_SCRIPT: Script = preload(
	"res://scripts/domain/unit_augment/effects/effect_summary_collector.gd"
)
const PASSIVE_EFFECT_APPLIER_SCRIPT: Script = preload(
	"res://scripts/domain/unit_augment/effects/passive_effect_applier.gd"
)
const TARGET_QUERY_SERVICE_SCRIPT: Script = preload(
	"res://scripts/domain/unit_augment/effects/target_query_service.gd"
)
const HEX_SPATIAL_SERVICE_SCRIPT: Script = preload(
	"res://scripts/domain/unit_augment/effects/hex_spatial_service.gd"
)
const ACTIVE_EFFECT_DISPATCHER_SCRIPT: Script = preload(
	"res://scripts/domain/unit_augment/effects/active_effect_dispatcher.gd"
)
const RUNTIME_GATEWAY_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_effect_runtime_gateway.gd")

var _summary_collector: Variant = SUMMARY_COLLECTOR_SCRIPT.new()
var _passive_effect_applier: Variant = PASSIVE_EFFECT_APPLIER_SCRIPT.new()
var _target_query_service: Variant = TARGET_QUERY_SERVICE_SCRIPT.new()
var _hex_spatial_service: Variant = HEX_SPATIAL_SERVICE_SCRIPT.new()
# 这里把 query/spatial service 显式注入 gateway，避免 gateway 反向抓全局依赖。
var _runtime_gateway: Variant = RUNTIME_GATEWAY_SCRIPT.new(
	_target_query_service,
	_hex_spatial_service
)
var _active_effect_dispatcher: Variant = ACTIVE_EFFECT_DISPATCHER_SCRIPT.new(
	_summary_collector,
	_target_query_service,
	_hex_spatial_service
)


# 公开的 modifier bundle 仍由 facade 暴露，避免旧调用方感知内部拆分。
# 真正的字段定义与默认值都由 passive applier 维护，这里只转发契约。
func create_empty_modifier_bundle() -> Dictionary:
	return _passive_effect_applier.create_empty_modifier_bundle()


# 被动入口只做转发。
# `runtime_stats` 是运行时基础属性快照，`modifier_bundle` 是叠层修正容器。
# 这两个字典的写入口径都收口在 passive applier，facade 不追加额外字段。
func apply_passive_effects(
	runtime_stats: Dictionary,
	modifier_bundle: Dictionary,
	effects: Array,
	stack_multiplier: float = 1.0
) -> void:
	_passive_effect_applier.apply_passive_effects(runtime_stats, modifier_bundle, effects, stack_multiplier)


# 主动效果入口只负责准备 summary 和 runtime context。
# `context` 会被深拷贝后再注入 runtime gateway，避免调用方的原始上下文被 effect 执行污染。
# `summary` 只汇总本次实际生效结果，不承载下一次 effect 链的中间状态。
func execute_active_effects(source: Node, target: Node, effects: Array, context: Dictionary = {}) -> Dictionary:
	var summary: Dictionary = _summary_collector.create_empty_summary()
	# effect 执行期间对 context 的临时写入都限定在副本里，避免污染调用方持有的原始上下文。
	var runtime_context: Dictionary = context.duplicate(true)
	runtime_context["_unit_augment_runtime_gateway"] = _runtime_gateway

	for effect_value in effects:
		if not (effect_value is Dictionary):
			continue

		var effect: Dictionary = effect_value as Dictionary
		_active_effect_dispatcher.execute_active_op(
			_runtime_gateway,
			source,
			target,
			effect,
			runtime_context,
			summary
		)

	return summary
