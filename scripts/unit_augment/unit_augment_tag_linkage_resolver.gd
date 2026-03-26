extends RefCounted
class_name UnitAugmentTagLinkageResolver

const QUERY_COMPILER_SCRIPT: Script = preload(
	"res://scripts/domain/unit_augment/tag_linkage/unit_augment_tag_linkage_query_compiler.gd"
)
const PROVIDER_COLLECTOR_SCRIPT: Script = preload(
	"res://scripts/domain/unit_augment/tag_linkage/unit_augment_tag_linkage_provider_collector.gd"
)
const CASE_EVALUATOR_SCRIPT: Script = preload(
	"res://scripts/domain/unit_augment/tag_linkage/unit_augment_tag_linkage_case_evaluator.gd"
)

var _query_compiler = QUERY_COMPILER_SCRIPT.new()
var _provider_collector = PROVIDER_COLLECTOR_SCRIPT.new(_query_compiler)
var _case_evaluator = CASE_EVALUATOR_SCRIPT.new(_query_compiler)


# facade 只负责把 tag registry 同步给纯规则模块。
# 真正的 query 编译与 mask 构建已经迁到 `scripts/domain/unit_augment/tag_linkage/`。
func configure_tag_registry(tag_to_index: Dictionary, version: int) -> void:
	_query_compiler.configure_tag_registry(tag_to_index, version)


# 解析入口只做上下文归一化和结果拼装。
# provider 收集、query 计数和 case 匹配都已经拆到 domain 子模块，不再依赖旧 resolver。
func evaluate(owner: Node, config: Dictionary, context: Dictionary) -> Dictionary:
	# 先把返回键补齐，保证无效 owner 也不会让上层读到缺字段结果。
	# 这条契约已经被 effect facade 和测试稳定依赖，不能在这轮重构里变化。
	var output: Dictionary = {
		"query_counts": {},
		"matched_case_ids": [],
		"effects": [],
		"providers": [],
		"debug": {}
	}
	if owner == null or not is_instance_valid(owner):
		return output

	var eval_context: Dictionary = context.duplicate(false)
	# compiler 负责把 schema 默认值、tag mask 和 source/team 口径一次编译好。
	# facade 这里只消费编译结果，不再重复做 query 级归一化。
	var compiled: Dictionary = _query_compiler.get_compiled_config(config)
	var global_source_types: Array[String] = compiled.get("global_source_types", [])
	var include_self: bool = bool(config.get("include_self", true))
	var range_cells: int = maxi(int(config.get("range", 0)), 0)

	# provider 列表会原样带回给上层，用于调试、观测和 stateful branch 后续复用。
	# case evaluator 只负责计数和效果选择，不再回头触碰空间扫描过程。
	var provider_result: Dictionary = _provider_collector.collect(
		owner,
		eval_context,
		range_cells,
		include_self,
		global_source_types
	)
	var providers: Array[Dictionary] = provider_result.get("providers", [])
	var case_result: Dictionary = _case_evaluator.evaluate(config, providers, compiled)

	var compiled_queries_value: Variant = compiled.get("compiled_queries", [])
	var compiled_query_count: int = 0
	if compiled_queries_value is Array:
		compiled_query_count = (compiled_queries_value as Array).size()

	output["query_counts"] = case_result.get("query_counts", {})
	output["matched_case_ids"] = case_result.get("matched_case_ids", [])
	output["effects"] = case_result.get("effects", [])
	output["providers"] = providers
	# debug 字段继续暴露扫描范围和编译摘要。
	# 这样 contract test 可以盯住外观不变，同时内部实现已经切到新 domain 模块。
	output["debug"] = {
		"range": range_cells,
		"count_mode": str(compiled.get("count_mode", "provider")),
		"team_scope": str(compiled.get("global_team_scope", "ally")),
		"source_types": global_source_types,
		"compiled_query_count": compiled_query_count,
		"tag_registry_version": _query_compiler.get_tag_registry_version(),
		"scan_cells": provider_result.get("scan_cells", [])
	}
	return output
