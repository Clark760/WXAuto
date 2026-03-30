extends RefCounted
class_name UnitAugmentTagRegistryService

var _tag_to_index: Dictionary = {}
var _index_to_tag: Array[String] = []
var _version: int = 1


# 公开快照只返回副本，避免 resolver/scheduler 之外的调用方误改注册表。
# `tag_to_index` 给 query 编译器使用，`index_to_tag` 给调试和回放日志使用。
# 任何外层调用方都只能读快照，不能把这里当成可写缓存。
func get_snapshot() -> Dictionary:
	return {
		"tag_to_index": _tag_to_index.duplicate(true),
		"index_to_tag": _index_to_tag.duplicate(),
		"version": _version
	}


# 调用方只依赖版本号来判断 resolver 的编译缓存是否需要失效。
# 版本号只在 rebuild 完成后递增，普通读取不应修改它。
# 这个值不保证连续命中某个标签，只保证“是否变更过”。
func get_version() -> int:
	return _version


# 这里统一收集功法、装备、Buff、单位和地形的 tags，避免 tag registry 口径分裂。
# `registry` 提供条目快照，`data_manager` 补全配表层 tags，`battle_units` 补全运行时单位和 trait tags。
# rebuild 结束后必须一次性替换整份注册表，不能边收集边写回旧表。
# 版本号只会在整份替换成功后递增，保证 resolver 缓存失效时机稳定。
func rebuild(
	registry: Variant,
	data_manager: Node,
	battle_units: Array[Node]
) -> Dictionary:
	var next_tag_to_index: Dictionary = {}
	var next_index_to_tag: Array[String] = []

	_collect_tags_from_rows(registry.get_all_gongfa(), next_tag_to_index, next_index_to_tag)
	_collect_tags_from_rows(registry.get_all_equipment(), next_tag_to_index, next_index_to_tag)
	_collect_tags_from_rows(registry.get_all_buffs(), next_tag_to_index, next_index_to_tag)

	if data_manager != null and is_instance_valid(data_manager) and data_manager.has_method("get_all_records"):
		var unit_rows: Array[Dictionary] = data_manager.get_all_records("units")
		var terrain_rows: Array[Dictionary] = data_manager.get_all_records("terrains")
		_collect_tags_from_rows(
			unit_rows,
			next_tag_to_index,
			next_index_to_tag
		)
		_collect_tags_from_rows(
			terrain_rows,
			next_tag_to_index,
			next_index_to_tag
		)

	for unit in battle_units:
		if unit == null or not is_instance_valid(unit):
			continue
		_register_tags(_normalize_tag_array(unit.get("tags")), next_tag_to_index, next_index_to_tag)
		var traits_value: Variant = unit.get("traits")
		if not (traits_value is Array):
			continue
		for trait_value in (traits_value as Array):
			if not (trait_value is Dictionary):
				continue
			var trait_tags: Array[String] = _normalize_tag_array(
				(trait_value as Dictionary).get("tags", [])
			)
			_register_tags(trait_tags, next_tag_to_index, next_index_to_tag)

	_tag_to_index = next_tag_to_index
	_index_to_tag = next_index_to_tag
	_version += 1
	return get_snapshot()


# `rows_value` 可以来自配表也可以来自运行时快照，因此这里只按 Dictionary 读取最小公共字段。
# 这里不关心条目类型，只认 `tags` 和可选的 `traits[].tags`。
# 这样新条目类型只要遵守 tags 结构，也能自动进入注册表。
func _collect_tags_from_rows(rows_value: Variant, tag_to_index: Dictionary, index_to_tag: Array[String]) -> void:
	if not (rows_value is Array):
		return
	for row_value in (rows_value as Array):
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value as Dictionary
		_register_tags(_normalize_tag_array(row.get("tags", [])), tag_to_index, index_to_tag)
		var traits_value: Variant = row.get("traits", [])
		if not (traits_value is Array):
			continue
		for trait_value in (traits_value as Array):
			if not (trait_value is Dictionary):
				continue
			_register_tags(_normalize_tag_array((trait_value as Dictionary).get("tags", [])), tag_to_index, index_to_tag)


# tag 注册表只接受小写去重后的标签，确保 query 编译缓存可稳定复用。
# `tag_to_index` 和 `index_to_tag` 必须同步推进，不能只改一边。
# 这里的 index 语义是稳定枚举位，不是运行时权重。
func _register_tags(tags: Array[String], tag_to_index: Dictionary, index_to_tag: Array[String]) -> void:
	for tag in tags:
		var key: String = tag.strip_edges().to_lower()
		if key.is_empty():
			continue
		if tag_to_index.has(key):
			continue
		var index: int = index_to_tag.size()
		tag_to_index[key] = index
		index_to_tag.append(key)


# 标签归一化必须在 registry 层完成，避免 resolver 和 UI 各自做一套。
# 返回值始终是小写、去重、无空串的稳定数组。
# 这里不保留原始大小写，后续展示如果需要格式化应由 UI 自己处理。
func _normalize_tag_array(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if raw is Array:
		for item in (raw as Array):
			var text: String = str(item).strip_edges().to_lower()
			if text.is_empty():
				continue
			if seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out
