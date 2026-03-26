extends RefCounted
class_name UnitAugmentTagLinkageCaseEvaluator

var _query_compiler


# case evaluator 只处理 query 计数、条件匹配和 effects 选择。
# provider 的收集和扫描上下文构建都在 collector 内完成，职责不要反向长回这里。
func _init(query_compiler) -> void:
	_query_compiler = query_compiler


# evaluate 返回 resolver 需要的三个核心产物：
# `query_counts`、`matched_case_ids` 和最终要执行的 `effects`。
func evaluate(config: Dictionary, providers: Array[Dictionary], compiled: Dictionary) -> Dictionary:
	var global_source_types: Array[String] = compiled.get("global_source_types", [])
	var global_team_scope: String = str(compiled.get("global_team_scope", "ally"))
	var count_mode: String = str(compiled.get("count_mode", "provider"))

	# query_counts 是 case 匹配的唯一输入。
	# 先把它稳定算出来，后面的 case/else 路径才不会重复扫 provider。
	var query_counts: Dictionary = _count_queries(
		config.get("queries", []),
		providers,
		global_source_types,
		global_team_scope,
		count_mode,
		compiled.get("compiled_queries", [])
	)

	var effects_to_execute: Array[Dictionary] = []
	var matched_case_ids: Array[String] = []
	var stop_after_first_case: bool = bool(config.get("stop_after_first_case", true))
	var cases_value: Variant = config.get("cases", [])
	if cases_value is Array:
		# case 顺序保持 Mod 声明顺序。
		# stop_after_first_case=true 时，第一条命中的 case 就立刻截断后续分支。
		for case_value in (cases_value as Array):
			if not (case_value is Dictionary):
				continue
			var case_data: Dictionary = case_value as Dictionary
			if not _is_case_matched(case_data, query_counts):
				continue
			var case_id: String = str(case_data.get("id", "")).strip_edges()
			if not case_id.is_empty():
				matched_case_ids.append(case_id)
			var case_effects_value: Variant = case_data.get("effects", [])
			if case_effects_value is Array:
				for effect_value in (case_effects_value as Array):
					if effect_value is Dictionary:
						effects_to_execute.append((effect_value as Dictionary).duplicate(true))
			if stop_after_first_case:
				break

	if effects_to_execute.is_empty():
		# 只有所有 case 都未命中时，才回落到 else_effects。
		# 这条回退语义必须和旧配置保持一致，不能和 stop_after_first_case 混淆。
		var else_effects_value: Variant = config.get("else_effects", [])
		if else_effects_value is Array:
			# else_effects 仍保持原顺序拷贝。
			# 这样日志和测试看到的效果序列不会因为重构而重排。
			for effect_value in (else_effects_value as Array):
				if effect_value is Dictionary:
					effects_to_execute.append((effect_value as Dictionary).duplicate(true))

	return {
		"query_counts": query_counts,
		"matched_case_ids": matched_case_ids,
		"effects": effects_to_execute
	}


# 每条 query 都按 provider/source/team/origin 三层过滤。
# count_mode 决定最终按 provider、unit 还是 occurrence 统计数量。
func _count_queries(
	queries_value: Variant,
	providers: Array[Dictionary],
	global_source_types: Array[String],
	global_team_scope: String,
	count_mode: String,
	compiled_queries_value: Variant
) -> Dictionary:
	var query_counts: Dictionary = {}
	var query_items: Array = _resolve_query_items(
		queries_value,
		global_source_types,
		global_team_scope,
		compiled_queries_value
	)
	for query_value in query_items:
		if not (query_value is Dictionary):
			continue
		var query: Dictionary = query_value as Dictionary
		var query_id: String = str(query.get("id", "")).strip_edges()
		if query_id.is_empty():
			continue

		var query_type: String = str(query.get("query_type", "match_tags")).strip_edges().to_lower()
		if query_type != "forbid_tags":
			query_type = "match_tags"
		var query_tags: Array[String] = query.get("tags", [])
		var query_exclude_tags: Array[String] = query.get("exclude_tags", [])
		# forbid_tags 走的是“命中排除标签就计数”的反向语义。
		# 因此它可以没有 include tags，但不能没有 exclude tags。
		if query_type == "forbid_tags":
			if query_exclude_tags.is_empty():
				query_counts[query_id] = 0
				continue
		elif query_tags.is_empty():
			query_counts[query_id] = 0
			continue

		var query_source_types: Array[String] = query.get("source_types", global_source_types)
		var query_team_scope: String = str(query.get("team_scope", global_team_scope))
		var origin_scope: String = str(query.get("origin_scope", "all")).strip_edges().to_lower()
		var provider_seen: Dictionary = {}
		var unit_seen: Dictionary = {}
		var count: int = 0
		for provider in providers:
			# provider 过滤顺序固定为：
			# source_type -> origin_scope -> team_scope -> tag match。
			var source_type: String = str(provider.get("source_type", "")).strip_edges().to_lower()
			if source_type.is_empty() or not query_source_types.has(source_type):
				continue

			var is_self_provider: bool = bool(provider.get("is_self", false)) or bool(provider.get("is_self_cell", false))
			if origin_scope == "self" and not is_self_provider:
				continue
			if origin_scope == "nearby" and is_self_provider:
				continue

			# terrain 没有 ally/enemy 关系，team_scope 过滤只对单位侧 provider 生效。
			# neutral 地形是否接受，交给 query 的其它维度组合自己决定。
			if source_type != "terrain":
				var relation: String = str(provider.get("team_relation", "neutral")).strip_edges().to_lower()
				if not _team_scope_accepts(query_team_scope, relation):
					continue

			if not _provider_matches_query(provider, query):
				continue

			# count_mode 只决定“同一个命中集如何计数”，不改变命中集合本身。
			# provider / unit / occurrence 三种模式都建立在同一条过滤链上。
			match count_mode:
				"occurrence":
					count += 1
				"unit":
					var unit_id: int = int(provider.get("unit_id", -1))
					if unit_id > 0:
						if unit_seen.has(unit_id):
							continue
						unit_seen[unit_id] = true
						count += 1
					else:
						var terrain_key: String = str(provider.get("key", "")).strip_edges()
						if terrain_key.is_empty() or provider_seen.has(terrain_key):
							continue
						provider_seen[terrain_key] = true
						count += 1
				_:
					var provider_key: String = str(provider.get("key", "")).strip_edges()
					if provider_key.is_empty() or provider_seen.has(provider_key):
						continue
					provider_seen[provider_key] = true
					count += 1

		query_counts[query_id] = count
	return query_counts


# resolver 允许直接复用 compiler 给出的 compiled_queries。
# 只有在没有 compiledQueries 的极端测试场景下，才退回到原始 queries 数组。
func _resolve_query_items(
	queries_value: Variant,
	global_source_types: Array[String],
	global_team_scope: String,
	compiled_queries_value: Variant
) -> Array:
	# 正常运行时优先复用 compiler 产出的 compiled_queries。
	# 只有极端测试没走 facade 装配时，才退回原始 queries 现场编译。
	if compiled_queries_value is Array and not (compiled_queries_value as Array).is_empty():
		return (compiled_queries_value as Array).duplicate(true)

	var query_items: Array = []
	if not (queries_value is Array):
		return query_items
	# fallback 路径仍保持和正式编译同口径。
	# 这样测试即便直接喂原始查询，也不会跑出另一套语义。
	for query_idx in range((queries_value as Array).size()):
		var query_value: Variant = (queries_value as Array)[query_idx]
		if not (query_value is Dictionary):
			continue
		query_items.append(
			_query_compiler._compile_single_query(
				query_value as Dictionary,
				query_idx,
				global_source_types,
				global_team_scope
			)
		)
	return query_items


# provider 命中逻辑先看 include tags，再看 exclude tags。
# `forbid_tags` 的语义是“命中 exclude 即计数”，与普通 match_tags 刚好相反。
func _provider_matches_query(provider: Dictionary, query: Dictionary) -> bool:
	var provider_tags: Array[String] = provider.get("tags", [])
	if provider_tags.is_empty():
		return false
	var provider_mask: PackedInt64Array = provider.get("tag_mask", PackedInt64Array())
	var query_type: String = str(query.get("query_type", "match_tags")).strip_edges().to_lower()
	if query_type != "forbid_tags":
		query_type = "match_tags"

	var query_tag_match: String = str(query.get("tag_match", "any")).strip_edges().to_lower()
	if query_tag_match != "all":
		query_tag_match = "any"
	var query_exclude_match: String = str(query.get("exclude_match", "any")).strip_edges().to_lower()
	if query_exclude_match != "all":
		query_exclude_match = "any"

	var include_ok: bool = true
	# match_tags 先判 include，再判 exclude。
	# forbid_tags 则完全反过来，只看排除标签命中与否。
	if query_type == "match_tags":
		include_ok = _provider_matches_compiled_tags(
			provider_tags,
			provider_mask,
			query.get("tag_mask", PackedInt64Array()),
			query.get("indexed_tags", []),
			query.get("fallback_tags", []),
			query.get("tags", []),
			query_tag_match
		)
		if not include_ok:
			return false

	# exclude 逻辑始终复用同一套 compiled tag 匹配函数。
	# 区别只在于调用方如何解释“命中 exclude”的返回值。
	var exclude_hit: bool = _provider_matches_compiled_tags(
		provider_tags,
		provider_mask,
		query.get("exclude_tag_mask", PackedInt64Array()),
		query.get("exclude_indexed_tags", []),
		query.get("exclude_fallback_tags", []),
		query.get("exclude_tags", []),
		query_exclude_match
	)
	if query_type == "forbid_tags":
		return exclude_hit
	return not exclude_hit


# 这里同时处理 indexed tags 的 mask 匹配和 fallback tags 的文本匹配。
# 两条路径必须并存，否则未注册标签会在 query 中被静默忽略。
func _provider_matches_compiled_tags(
	provider_tags: Array[String],
	provider_mask: PackedInt64Array,
	compiled_mask_value: Variant,
	indexed_tags_value: Variant,
	fallback_tags_value: Variant,
	raw_tags_value: Variant,
	tag_match: String
) -> bool:
	var query_mask: PackedInt64Array = PackedInt64Array()
	if compiled_mask_value is PackedInt64Array:
		query_mask = compiled_mask_value

	var indexed_tags: Array[String] = []
	if indexed_tags_value is Array:
		for tag in (indexed_tags_value as Array):
			indexed_tags.append(str(tag))

	var fallback_tags: Array[String] = []
	if fallback_tags_value is Array:
		for tag in (fallback_tags_value as Array):
			fallback_tags.append(str(tag))

	var raw_tags: Array[String] = []
	if raw_tags_value is Array:
		for tag in (raw_tags_value as Array):
			raw_tags.append(str(tag))

	if raw_tags.is_empty():
		return false

	if tag_match == "all":
		# all 模式要求 indexed tags 和 fallback tags 都被完整覆盖。
		# 只命中其中一部分时必须直接判失败，不能退回 any 语义。
		if not _query_compiler.mask_matches_all(provider_mask, query_mask):
			return false
		for tag in fallback_tags:
			if not provider_tags.has(tag):
				return false
		return true

	if _query_compiler.mask_matches_any(provider_mask, query_mask):
		return true
	for tag in fallback_tags:
		if provider_tags.has(tag):
			return true
	# indexed_tags 不为空却一个都没命中时，说明 any 匹配已经失败。
	# 这里直接返回 false，避免再让 raw_tags 把未注册标签和已注册标签混成二义性结果。
	if not indexed_tags.is_empty():
		return false
	return _provider_matches_tags(provider_tags, raw_tags, "any")


# 纯文本匹配只在 fallback 路径使用。
# 这里不做 lower/strip，调用方必须先传入已经归一化的 tags 数组。
func _provider_matches_tags(provider_tags: Array[String], query_tags: Array[String], tag_match: String) -> bool:
	if provider_tags.is_empty() or query_tags.is_empty():
		return false
	# 纯文本匹配只兜底未注册标签。
	# 这里故意保持简单线性判断，避免再和 mask 路径交织出第二套语义。
	if tag_match == "all":
		for tag in query_tags:
			if not provider_tags.has(tag):
				return false
		return true
	for tag in query_tags:
		if provider_tags.has(tag):
			return true
	return false


# case 的 all/any 语义和原 Mod 配置保持一致。
# all 先校验，any 只在存在配置时才要求至少命中一个条件。
func _is_case_matched(case_data: Dictionary, query_counts: Dictionary) -> bool:
	var all_conditions_value: Variant = case_data.get("all", [])
	var any_conditions_value: Variant = case_data.get("any", [])
	# 先判 all，再判 any。
	# 这样硬性条件一旦失败，就不会被 any 分支意外捞回来。
	var all_ok: bool = _match_conditions(all_conditions_value, query_counts, true)
	if not all_ok:
		return false
	if any_conditions_value is Array and not (any_conditions_value as Array).is_empty():
		return _match_conditions(any_conditions_value, query_counts, false)
	return true


# `all` 分支要求全部条件都成立，`any` 分支只要命中一个即可。
# 这个布尔语义不能在上层 case 循环里重复展开，否则很容易写出分叉不一致。
func _match_conditions(conditions_value: Variant, query_counts: Dictionary, require_all: bool) -> bool:
	if not (conditions_value is Array):
		return require_all
	var conditions: Array = conditions_value as Array
	if conditions.is_empty():
		return require_all
	# 空条件数组在 all/any 两个口径下都视为“不额外施加限制”。
	# 真正的真假差异只体现在存在条件条目后的遍历策略。
	if require_all:
		for condition_value in conditions:
			if not _is_single_condition_met(condition_value, query_counts):
				return false
		return true
	for condition_value in conditions:
		if _is_single_condition_met(condition_value, query_counts):
			return true
	return false


# 单条条件只认 query_id + min/max 这套稳定口径。
# 这样 `min_count` / `min`、`max_count` / `max` 两套历史字段都还能兼容。
func _is_single_condition_met(condition_value: Variant, query_counts: Dictionary) -> bool:
	if not (condition_value is Dictionary):
		return false
	var condition: Dictionary = condition_value as Dictionary
	var query_id: String = str(condition.get("query_id", "")).strip_edges()
	if query_id.is_empty():
		return false
	# min/max 两套历史字段继续统一收口。
	# 这样旧 Mod 不需要改字段名，也不会在重构后静默丢条件。
	var count: int = int(query_counts.get(query_id, 0))
	var min_count: int = maxi(int(condition.get("min_count", condition.get("min", 0))), 0)
	var max_count: int = int(condition.get("max_count", condition.get("max", -1)))
	if count < min_count:
		return false
	if max_count >= 0 and count > max_count:
		return false
	return true


# team_scope 的过滤只在非 terrain provider 上生效。
# terrain provider 固定标记成 neutral，由 query 层决定是否接受。
func _team_scope_accepts(scope: String, relation: String) -> bool:
	# team_scope 只表达“允许哪些关系进入计数”。
	# 它不负责 source_type 或 origin_scope 过滤，避免职责再次混杂。
	match scope:
		"enemy":
			return relation == "enemy"
		"all":
			return true
		_:
			return relation == "ally"
