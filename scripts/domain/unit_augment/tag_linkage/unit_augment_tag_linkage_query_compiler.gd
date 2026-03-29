extends RefCounted
class_name UnitAugmentTagLinkageQueryCompiler

const DEFAULT_SOURCE_TYPES: Array[String] = ["trait", "gongfa", "equipment", "terrain", "unit"]
const COMPILE_CACHE_MAX: int = 256

var _tag_to_index: Dictionary = {}
var _tag_registry_version: int = 0
var _mask_word_count: int = 0
var _compiled_cache: Dictionary = {}


# 这里统一维护 tag registry 快照和编译缓存。
# `version` 一旦变化，旧 query 编译结果必须整体失效，避免命中错误的 tag bit 位。
func configure_tag_registry(tag_to_index: Dictionary, version: int) -> void:
	var incoming: Dictionary = {}
	for key_value in tag_to_index.keys():
		var key: String = str(key_value).strip_edges().to_lower()
		if key.is_empty():
			continue
		incoming[key] = int(tag_to_index[key_value])

	var changed: bool = version != _tag_registry_version
	if not changed and incoming.size() == _tag_to_index.size():
		for key in incoming.keys():
			if not _tag_to_index.has(key) or int(_tag_to_index[key]) != int(incoming[key]):
				changed = true
				break
	else:
		changed = true

	_tag_to_index = incoming
	_tag_registry_version = maxi(version, 0)
	_mask_word_count = int(ceili(float(_tag_to_index.size()) / 64.0))
	if changed:
		_compiled_cache.clear()


# resolver 每次评估前都走这里拿编译结果。
# `config` 仍保持 Mod 外观不变，但运行时不再在主循环里重复做 tags/mask 归一化。
func get_compiled_config(config: Dictionary) -> Dictionary:
	var cache_key: String = "%d|%s" % [_tag_registry_version, var_to_str(config)]
	if _compiled_cache.has(cache_key):
		return (_compiled_cache[cache_key] as Dictionary).duplicate(true)

	# 编译缓存未命中时，统一在这里重建整份 compiled config。
	# 外层 resolver 只拿结果，不需要知道缓存淘汰和字段补齐细节。
	var compiled: Dictionary = _compile_config(config)
	if _compiled_cache.size() >= COMPILE_CACHE_MAX:
		_compiled_cache.clear()
	compiled["cache_key"] = cache_key
	compiled["tag_registry_version"] = _tag_registry_version
	_compiled_cache[cache_key] = compiled.duplicate(true)
	return compiled


# provider collector 和 query evaluator 都会复用这套 mask 构建。
# 只对已经进入 registry 的标签写 bit，未注册标签走 fallback 文本匹配。
func build_mask_from_tags(tags: Array[String]) -> PackedInt64Array:
	var mask: PackedInt64Array = _create_empty_mask()
	if mask.is_empty():
		return mask

	# 这里只给已注册标签落 bit。
	# 未注册标签会留在 fallback 文本匹配，不在 mask 中伪造索引。
	for tag in tags:
		if not _tag_to_index.has(tag):
			continue
		var index: int = int(_tag_to_index[tag])
		if index < 0:
			continue
		var word: int = index >> 6
		var bit: int = index & 63
		if word < 0 or word >= mask.size():
			continue
		mask[word] = int(mask[word]) | (1 << bit)
	return mask


# `any` 匹配用于最常见的“具备任一标签即可命中”。
# 这里不做文本 fallback，调用方需要先分别传入 indexed 和 fallback tags。
func mask_matches_any(provider_mask: PackedInt64Array, query_mask: PackedInt64Array) -> bool:
	if provider_mask.is_empty() or query_mask.is_empty():
		return false
	var word_count: int = mini(provider_mask.size(), query_mask.size())
	for idx in range(word_count):
		if (int(provider_mask[idx]) & int(query_mask[idx])) != 0:
			return true
	return false


# `all` 匹配要求 provider 覆盖 query 中所有已索引标签。
# 只要任一非零 word 缺位，就说明这条 provider 不满足 all 约束。
func mask_matches_all(provider_mask: PackedInt64Array, query_mask: PackedInt64Array) -> bool:
	if query_mask.is_empty():
		return true
	if provider_mask.is_empty() or provider_mask.size() < query_mask.size():
		return false
	for idx in range(query_mask.size()):
		var query_word: int = int(query_mask[idx])
		if query_word == 0:
			continue
		if (int(provider_mask[idx]) & query_word) != query_word:
			return false
	return true


# source_types 是条目级 schema 允许的固定枚举。
# 新实现继续接受旧配置口径，但统一在这里过滤非法值和重复值。
func normalize_source_types(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		# source_types 是 schema 固定枚举。
		# 这里先做合法值过滤，再做去重，避免脏输入污染 compiled config。
		for item in (value as Array):
			var key: String = str(item).strip_edges().to_lower()
			if key.is_empty():
				continue
			if key != "trait" and key != "gongfa" and key != "equipment" and key != "terrain" and key != "unit":
				continue
			if seen.has(key):
				continue
			seen[key] = true
			out.append(key)
	if out.is_empty():
		return DEFAULT_SOURCE_TYPES.duplicate()
	return out


# tag 文本在整个 linkage 系统里按小写去重。
# 这里统一做 strip/lower，避免 provider 和 query 的大小写口径不一致。
func normalize_tags(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		for item in (value as Array):
			var text: String = str(item).strip_edges().to_lower()
			if text.is_empty() or seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out


# team_scope 只允许 ally/enemy/all 三种运行时口径。
# schema 外的值统一回落到 ally，保持旧配置的保守行为。
func normalize_team_scope(raw_scope: String) -> String:
	var scope: String = raw_scope.strip_edges().to_lower()
	if scope == "enemy":
		return "enemy"
	if scope == "all":
		return "all"
	return "ally"


# count_mode 决定 query 最终按 provider、unit 还是 occurrence 计数。
# 非法值统一回退到 provider，避免运行时 silently 走错分支。
func normalize_count_mode(raw_mode: String) -> String:
	var mode: String = raw_mode.strip_edges().to_lower()
	if mode == "occurrence":
		return "occurrence"
	if mode == "unit":
		return "unit"
	return "provider"


# debug 信息和测试断言需要这个 version。
# facade 不直接读内部字段，统一走 getter，避免后续缓存结构变化时四处改调用点。
func get_tag_registry_version() -> int:
	return _tag_registry_version


# query 编译阶段把全局默认值、按 query 覆盖值和 tag mask 一次算清。
# 这样真正评估 query 时只做 provider 过滤，不再反复整理 schema。
func _compile_config(config: Dictionary) -> Dictionary:
	var global_source_types: Array[String] = normalize_source_types(config.get("source_types", DEFAULT_SOURCE_TYPES))
	var global_team_scope: String = normalize_team_scope(str(config.get("team_scope", "ally")))
	var count_mode: String = normalize_count_mode(str(config.get("count_mode", "provider")))
	var compiled_queries: Array = []
	var queries_value: Variant = config.get("queries", [])
	if queries_value is Array:
		# query 编译阶段直接把每条 query 的默认值和 mask 产物落成结构化快照。
		# 后续 evaluator 只需消费 compiled_queries，不再在主循环里反复整理原始字典。
		for query_idx in range((queries_value as Array).size()):
			var query_value: Variant = (queries_value as Array)[query_idx]
			if not (query_value is Dictionary):
				continue
			compiled_queries.append(
				_compile_single_query(query_value as Dictionary, query_idx, global_source_types, global_team_scope)
			)
	return {
		"global_source_types": global_source_types,
		"global_team_scope": global_team_scope,
		"count_mode": count_mode,
		"compiled_queries": compiled_queries,
		"required_unit_team_scope": _resolve_required_unit_team_scope(compiled_queries)
	}


# 每条 query 都会拆成 indexed/fallback 两组 tags。
# indexed tags 走 bit mask，fallback tags 走字符串匹配，兼顾性能和兼容性。
func _compile_single_query(
	query: Dictionary,
	query_idx: int,
	global_source_types: Array[String],
	global_team_scope: String
) -> Dictionary:
	# query id 和 query_type 都先归一化。
	# 这样后续测试和日志看到的键名稳定，不受 Mod 填写细节影响。
	var query_id: String = str(query.get("id", "q_%d" % query_idx)).strip_edges()
	if query_id.is_empty():
		query_id = "q_%d" % query_idx

	var query_type: String = str(query.get("query_type", "match_tags")).strip_edges().to_lower()
	if query_type != "forbid_tags":
		query_type = "match_tags"

	var query_tags: Array[String] = normalize_tags(query.get("tags", []))
	var query_tag_match: String = str(query.get("tag_match", "any")).strip_edges().to_lower()
	if query_tag_match != "all":
		query_tag_match = "any"

	var query_exclude_tags: Array[String] = normalize_tags(query.get("exclude_tags", []))
	var query_exclude_match: String = str(query.get("exclude_match", "any")).strip_edges().to_lower()
	if query_exclude_match != "all":
		query_exclude_match = "any"

	var query_source_types: Array[String] = global_source_types
	if query.has("source_types"):
		query_source_types = normalize_source_types(query.get("source_types", global_source_types))

	var query_team_scope: String = global_team_scope
	if query.has("team_scope"):
		query_team_scope = normalize_team_scope(str(query.get("team_scope", global_team_scope)))

	var origin_scope: String = str(query.get("origin_scope", "all")).strip_edges().to_lower()
	if origin_scope != "self" and origin_scope != "nearby":
		origin_scope = "all"

	# 已注册标签走 bit mask，未注册标签保留到 fallback 文本匹配。
	# 这两组都要留下来，否则 registry 未覆盖的标签会在运行时被静默吃掉。
	var indexed_tags: Array[String] = []
	var fallback_tags: Array[String] = []
	for tag in query_tags:
		if _tag_to_index.has(tag):
			indexed_tags.append(tag)
		else:
			fallback_tags.append(tag)

	var exclude_indexed_tags: Array[String] = []
	var exclude_fallback_tags: Array[String] = []
	for tag in query_exclude_tags:
		if _tag_to_index.has(tag):
			exclude_indexed_tags.append(tag)
		else:
			exclude_fallback_tags.append(tag)

	# return 结构就是 evaluator 的直接输入。
	# 这里只放不可变编译产物，不混入任何一次评估期的临时状态。
	return {
		"id": query_id,
		"query_type": query_type,
		"tags": query_tags,
		"indexed_tags": indexed_tags,
		"fallback_tags": fallback_tags,
		"tag_mask": build_mask_from_tags(indexed_tags),
		"tag_match": query_tag_match,
		"exclude_tags": query_exclude_tags,
		"exclude_indexed_tags": exclude_indexed_tags,
		"exclude_fallback_tags": exclude_fallback_tags,
		"exclude_tag_mask": build_mask_from_tags(exclude_indexed_tags),
		"exclude_match": query_exclude_match,
		"source_types": query_source_types,
		"team_scope": query_team_scope,
		"origin_scope": origin_scope
	}


func _resolve_required_unit_team_scope(compiled_queries: Array) -> String:
	var needs_ally: bool = false
	var needs_enemy: bool = false
	for query_value in compiled_queries:
		if not (query_value is Dictionary):
			continue
		var query: Dictionary = query_value as Dictionary
		if not _query_uses_unit_providers(query):
			continue
		var team_scope: String = str(query.get("team_scope", "ally")).strip_edges().to_lower()
		if team_scope == "all":
			return "all"
		if team_scope == "enemy":
			needs_enemy = true
		else:
			needs_ally = true
	if needs_ally and needs_enemy:
		return "all"
	if needs_enemy:
		return "enemy"
	if needs_ally:
		return "ally"
	return "none"


func _query_uses_unit_providers(query: Dictionary) -> bool:
	var source_types_value: Variant = query.get("source_types", [])
	if not (source_types_value is Array):
		return false
	for source_type_value in (source_types_value as Array):
		var source_type: String = str(source_type_value).strip_edges().to_lower()
		if source_type == "unit" or source_type == "trait" or source_type == "gongfa" or source_type == "equipment":
			return true
	return false


# mask 长度只由当前 registry 的标签总数决定。
# registry 为空时返回空数组，让调用方自动退回到 fallback 文本匹配。
func _create_empty_mask() -> PackedInt64Array:
	var word_count: int = maxi(_mask_word_count, 0)
	var mask: PackedInt64Array = PackedInt64Array()
	if word_count <= 0:
		return mask
	# PackedInt64Array 默认值虽然也是 0，但这里显式写清初始化意图。
	# 这样后续如果更换 mask 容器，实现边界也仍然清晰。
	mask.resize(word_count)
	for idx in range(word_count):
		mask[idx] = 0
	return mask
