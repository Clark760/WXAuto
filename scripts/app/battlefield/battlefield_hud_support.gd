extends RefCounted

# HUD 共享支持
# 说明：
# 1. 集中承接 HUD 各子协作者共用的查表、格式化和库存查询逻辑。
# 2. 这里不直接操作面板显隐，也不承接信号连接。
# 共享 support 的目标不是“什么都管”，而是把重复查表和格式化从 view 中移走。
# 数据来源口径：
# 1. 单位列表只认 bench + ally_deployed。
# 2. 功法、装备、Buff 数据统一从 unit_augment_manager 或 DataManager 读取。
# 3. tooltip payload 统一由这里生成，避免多处拼接文案漂移。
# 规范化口径：
# 1. 功法槽固定四槽。
# 2. 装备槽先排序再补空槽，确保 detail / inventory 顺序一致。
# 3. 空配置也要返回稳定结构，避免 HUD 到处判空。
# 可读性口径：
# 1. 复杂逻辑优先解释为什么要去重、补槽、兜底。
# 2. 简单翻译函数保持一行一义，不写重复尾注。

const TEAM_ALLY: int = 1 # 己方队伍标识。
const TEAM_ENEMY: int = 2 # 敌方队伍标识。
const SLOT_ORDER: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa"] # 功法槽顺序。
const DEFAULT_EQUIP_ORDER: Array[String] = ["slot_1", "slot_2"] # 装备槽默认顺序。

var _scene_root = null # 根场景入口。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。

var _gongfa_by_type: Dictionary = {} # 功法类型到 id 列表的索引。
var _buff_data_map: Dictionary = {} # Buff 数据缓存。


# 绑定 HUD support 需要的场景入口、引用表和会话状态。
# support 不持有 UI 生命周期，只保存查表和格式化所需的最小上下文。
func initialize(scene_root, refs, state) -> void:
	_scene_root = scene_root
	_refs = refs
	_state = state


# 重建功法类型索引，供 detail / tooltip / inventory 复用同一份查表。
# 缓存结构是 type -> [id]，后续只读这份索引，不重复扫描全量功法表。
func build_gongfa_type_cache() -> void:
	_gongfa_by_type.clear()
	# 即便某个类型之前不存在，也在这里补空数组，后续消费代码就不用判缺失。
	for slot in SLOT_ORDER:
		_gongfa_by_type[slot] = []
	if _refs == null or _refs.unit_augment_manager == null:
		return
	if not _refs.unit_augment_manager.has_method("get_all_gongfa"):
		return
	var all_data: Variant = _refs.unit_augment_manager.call("get_all_gongfa")
	if not (all_data is Array):
		return
	for item in all_data:
		if not (item is Dictionary):
			continue
		var data: Dictionary = item as Dictionary
		var gongfa_id: String = str(data.get("id", "")).strip_edges()
		var gongfa_type: String = str(data.get("type", "")).strip_edges()
		if gongfa_id.is_empty() or gongfa_type.is_empty():
			continue
		if not _gongfa_by_type.has(gongfa_type):
			_gongfa_by_type[gongfa_type] = []
		var ids: Array = _gongfa_by_type[gongfa_type]
		ids.append(gongfa_id)
		_gongfa_by_type[gongfa_type] = ids


# 重新加载 Buff 名称映射，避免 tooltip 继续依赖旧缓存。
# Buff 数据只保留一份本地副本，便于 tooltip 快速按 id 取名。
func reload_external_item_data() -> void:
	_buff_data_map.clear()
	var data_manager: Node = get_root_node("DataManager")
	if data_manager == null or not data_manager.has_method("get_all_records"):
		return
	var buff_records: Variant = data_manager.call("get_all_records", "buffs")
	if not (buff_records is Array):
		return
	for buff_value in buff_records:
		if not (buff_value is Dictionary):
			continue
		var buff_data: Dictionary = buff_value as Dictionary
		var buff_id: String = str(buff_data.get("id", "")).strip_edges()
		if buff_id.is_empty():
			continue
		_buff_data_map[buff_id] = buff_data.duplicate(true)


# 关闭物品悬停态时统一清理 session state，避免残留 bridge 判断。
# 只要 item tooltip 相关状态失效，就一起清零，不留半旧半新的 hover 上下文。
func clear_item_hover_state() -> void:
	if _state == null:
		return
	_state.item_hover_source = null
	_state.item_hover_data = {}
	_state.item_hover_timer = 0.0
	_state.item_fade_timer = 0.0


# 统计当前库存条目被多少角色装备，供 inventory 摘要显示。
# 这里同时遍历 bench 和已部署角色，保证准备期和战斗回放都读到同一口径。
func count_equipped_instances(mode: String, item_id: String) -> int:
	var count: int = 0
	for unit in collect_player_units():
		if not is_valid_unit(unit):
			continue
		# 功法和装备的槽位结构不同，但最终都收敛成“命中几次同一 item_id”。
		if mode == "gongfa":
			var gongfa_slots: Dictionary = normalize_unit_slots(unit.get("gongfa_slots"))
			for slot in SLOT_ORDER:
				if str(gongfa_slots.get(slot, "")).strip_edges() == item_id:
					count += 1
			continue
		var equip_slots: Dictionary = normalize_equip_slots(get_unit_equip_slots(unit))
		var equip_order: Array[String] = get_sorted_equip_slot_keys(
			equip_slots,
			get_unit_max_equip_count(unit, equip_slots)
		)
		for equip_slot in equip_order:
			if str(equip_slots.get(equip_slot, "")).strip_edges() == item_id:
				count += 1
	return count


# 查找某个库存条目当前挂在哪个角色和槽位上，供 inventory 点击跳转详情。
# 找到第一处命中就返回，inventory 只需要一个可跳转入口而不是完整列表。
func find_equipped_info(item_id: String, inventory_mode: String) -> Dictionary:
	if item_id.is_empty():
		return {}
	for unit in collect_player_units():
		if not is_valid_unit(unit):
			continue
		if inventory_mode == "gongfa":
			var gongfa_slots: Dictionary = normalize_unit_slots(unit.get("gongfa_slots"))
			for slot in SLOT_ORDER:
				if str(gongfa_slots.get(slot, "")).strip_edges() == item_id:
					return {
						"unit": unit,
						"unit_name": str(unit.get("unit_name")),
						"slot": slot
					}
			continue
		var equip_slots: Dictionary = normalize_equip_slots(get_unit_equip_slots(unit))
		var equip_order: Array[String] = get_sorted_equip_slot_keys(
			equip_slots,
			get_unit_max_equip_count(unit, equip_slots)
		)
		for equip_slot in equip_order:
			if str(equip_slots.get(equip_slot, "")).strip_edges() == item_id:
				return {
					"unit": unit,
					"unit_name": str(unit.get("unit_name")),
					"slot": equip_slot
				}
	return {}


# 汇总备战席与已部署友军，给 inventory / detail / tooltip 共用。
# seen 表负责去重，避免同一个单位同时出现在 bench 数据和部署映射时重复计数。
func collect_player_units() -> Array[Node]:
	var output: Array[Node] = []
	var seen: Dictionary = {}
	if _refs != null and _refs.bench_ui != null and _refs.bench_ui.has_method("get_all_units"):
		for unit in _refs.bench_ui.call("get_all_units"):
			if not is_valid_unit(unit):
				continue
			var instance_id: int = unit.get_instance_id()
			if seen.has(instance_id):
				continue
			seen[instance_id] = true
			output.append(unit)
	if _state == null:
		return output
	for unit in _state.ally_deployed.values():
		if not is_valid_unit(unit):
			continue
		var deployed_id: int = unit.get_instance_id()
		if seen.has(deployed_id):
			continue
		seen[deployed_id] = true
		output.append(unit)
	return output


# 按当前阶段返回实时存活数，供顶栏战力条显示。
# 准备期没有真正战斗运行态时，直接回退到部署映射规模。
func get_alive_count(team_id: int) -> int:
	if _state == null:
		return 0
	if int(_state.stage) == 0:
		return _state.ally_deployed.size() if team_id == TEAM_ALLY else _state.enemy_deployed.size()
	if _refs != null and _refs.combat_manager != null:
		if _refs.combat_manager.has_method("get_alive_count"):
			return int(_refs.combat_manager.call("get_alive_count", team_id))
	return 0


# 统一读取角色装备槽，并在空槽配置时补全默认顺序。
# 对外永远返回规范化结果，调用方不需要关心单位原始字段是否缺失。
func get_unit_equip_slots(unit: Node) -> Dictionary:
	if not is_valid_unit(unit):
		return normalize_equip_slots({}, DEFAULT_EQUIP_ORDER.size())
	return normalize_equip_slots(unit.get("equip_slots"), int(unit.get("max_equip_count")))


# 把功法槽输入规范化成固定四槽，避免详情和库存各自补默认值。
# 任何缺槽或空值都在这里补成空字符串，后续 UI 文本更稳定。
func normalize_unit_slots(raw: Variant) -> Dictionary:
	var slots: Dictionary = {
		"neigong": "",
		"waigong": "",
		"qinggong": "",
		"zhenfa": ""
	}
	if raw is Dictionary:
		for key in slots.keys():
			slots[key] = str((raw as Dictionary).get(key, "")).strip_edges()
	return slots


# 把装备槽输入规范化成排序后的字典，并根据目标数量补全空槽。
# 先排序再补槽，能保证 slot_10 不会跑到 slot_2 前面。
func normalize_equip_slots(raw: Variant, desired_count: int = 0) -> Dictionary:
	var slots: Dictionary = {}
	if raw is Dictionary:
		for key in get_sorted_equip_slot_keys(raw):
			slots[key] = str((raw as Dictionary).get(key, "")).strip_edges()
	# 没有任何装备槽配置时，也返回默认两槽，避免 detail 行数忽多忽少。
	if slots.is_empty():
		for key in DEFAULT_EQUIP_ORDER:
			slots[key] = ""
	if desired_count > slots.size():
		for index in range(1, desired_count + 1):
			if slots.size() >= desired_count:
				break
			var slot_key: String = "slot_%d" % index
			if not slots.has(slot_key):
				slots[slot_key] = ""
	return slots


# 读取角色最大装备槽数，兼容缺失配置和空槽位字典。
# 最终至少返回 1，防止调用方拿到 0 后直接把整块 UI 隐掉。
func get_unit_max_equip_count(unit: Node, equip_slots: Dictionary) -> int:
	var configured: int = int(unit.get("max_equip_count")) if is_valid_unit(unit) else 0
	if configured <= 0:
		configured = equip_slots.size()
	if configured <= 0:
		configured = DEFAULT_EQUIP_ORDER.size()
	return maxi(configured, 1)


# 对装备槽 key 做稳定排序，避免 detail 和 inventory 行顺序漂移。
# desired_count 会把未来可能存在但当前为空的槽位也提前纳入排序。
func get_sorted_equip_slot_keys(
	slots_value: Variant,
	desired_count: int = 0
) -> Array[String]:
	var keys: Array[String] = []
	if slots_value is Dictionary:
		for raw_key in (slots_value as Dictionary).keys():
			var key: String = str(raw_key).strip_edges()
			if not key.is_empty():
				keys.append(key)
	if keys.is_empty():
		keys = DEFAULT_EQUIP_ORDER.duplicate()
	keys.sort_custom(Callable(self, "compare_equip_slot_key"))
	var target_count: int = maxi(desired_count, keys.size())
	if target_count > keys.size():
		for index in range(1, target_count + 1):
			if keys.size() >= target_count:
				break
			var slot_key: String = "slot_%d" % index
			if not keys.has(slot_key):
				keys.append(slot_key)
		keys.sort_custom(Callable(self, "compare_equip_slot_key"))
	return keys


# 让 slot_1、slot_2 这类槽位优先按编号排序，其他 key 再按字典序落后。
# 这样既兼容标准 slot_x，也兼容未来可能出现的特殊命名槽位。
func compare_equip_slot_key(a: String, b: String) -> bool:
	var a_index: int = extract_equip_slot_index(a)
	var b_index: int = extract_equip_slot_index(b)
	if a_index >= 0 and b_index >= 0:
		return a_index < b_index if a_index != b_index else a < b
	if a_index >= 0:
		return true
	if b_index >= 0:
		return false
	return a < b


# 从 slot_x 这类 key 中提取数字编号，供装备槽排序使用。
# 非标准 key 直接返回 -1，交给 compare_equip_slot_key 走兜底分支。
func extract_equip_slot_index(slot_key: String) -> int:
	var normalized: String = slot_key.strip_edges().to_lower()
	if not normalized.begins_with("slot_"):
		return -1
	var tail: String = normalized.substr(5, normalized.length() - 5)
	return int(tail) if tail.is_valid_int() else -1


# 把运行时生效的功法与装备效果整理成详情面板的 bonus 列表。
# 这里故意读取 runtime_*_ids，而不是静态已装备槽，确保展示的是实际生效效果。
func build_gongfa_bonus_lines(unit: Node) -> Array[String]:
	var lines: Array[String] = []
	if _refs == null or _refs.unit_augment_manager == null:
		return lines
	# 功法被动和装备效果最终都落成同一行文本，详情面板不用区分渲染模板。
	var runtime_gongfa_ids: Array = unit.get("runtime_equipped_gongfa_ids")
	for gongfa_id_value in runtime_gongfa_ids:
		var gongfa_id: String = str(gongfa_id_value)
		var data: Dictionary = _refs.unit_augment_manager.call("get_gongfa_data", gongfa_id)
		if data.is_empty():
			continue
		var gongfa_name: String = str(data.get("name", gongfa_id))
		var passive_effects: Variant = data.get("passive_effects", [])
		if passive_effects is Array:
			for effect_value in passive_effects:
				if effect_value is Dictionary:
					lines.append(
						"%s: %s" % [gongfa_name, format_effect_op(effect_value as Dictionary)]
					)
	var runtime_equip_ids: Array = unit.get("runtime_equipped_equip_ids")
	for equip_id_value in runtime_equip_ids:
		var equip_id: String = str(equip_id_value)
		var equip_data: Dictionary = _refs.unit_augment_manager.call("get_equipment_data", equip_id)
		if equip_data.is_empty():
			continue
		var equip_name: String = str(equip_data.get("name", equip_id))
		var effects: Variant = equip_data.get("effects", [])
		if effects is Array:
			for effect_value in effects:
				if effect_value is Dictionary:
					lines.append(
						"%s: %s" % [equip_name, format_effect_op(effect_value as Dictionary)]
					)
	return lines


# 把角色内置特性转成统一的物品 tooltip 结构，便于 tooltip 共用渲染。
# trait 和 item 最终共用一套 payload，是为了让 detail_view 只维护一个 tooltip renderer。
func build_trait_item_tooltip_data(trait_data: Dictionary) -> Dictionary:
	var effects: Array[String] = []
	var trait_effects: Variant = trait_data.get("effects", [])
	# trait effects 也先翻译成普通效果文本，这样 tooltip renderer 完全不用分支。
	if trait_effects is Array:
		for effect_value in trait_effects:
			if effect_value is Dictionary:
				effects.append(format_effect_op(effect_value as Dictionary))
	return {
		"name": "特性·%s" % str(trait_data.get("name", trait_data.get("id", "未命名特性"))),
		"type_line": "内置特性 · 不可装卸",
		"desc": str(trait_data.get("description", "无描述")),
		"effects": effects,
		"has_skill": false,
		"skill_trigger": "",
		"skill_effects": []
	}


# 把功法配置转成统一 tooltip payload，避免多个面板各自拼装文本。
# 缺数据时也返回完整 payload 结构，调用方就不用再写一层兜底分支。
func build_gongfa_item_tooltip_data(gongfa_id: String) -> Dictionary:
	var data: Dictionary = {}
	if _refs != null and _refs.unit_augment_manager != null:
		data = _refs.unit_augment_manager.call("get_gongfa_data", gongfa_id)
	if data.is_empty():
		return {
			"name": gongfa_id,
			"type_line": "功法",
			"desc": "未找到功法数据",
			"effects": [],
			"has_skill": false,
			"skill_trigger": "",
			"skill_effects": []
		}
	# payload 的字段名固定后，detail/shop/inventory 就能共享同一渲染函数。
	var effect_lines: Array[String] = []
	var passive_effects: Variant = data.get("passive_effects", [])
	# passive_effects 只做只读投影，不在 HUD 侧推断运行时数值。
	if passive_effects is Array:
		for effect_value in passive_effects:
			if effect_value is Dictionary:
				effect_lines.append(format_effect_op(effect_value as Dictionary))
	return {
		"name": "%s [%s]" % [
			str(data.get("name", gongfa_id)),
			quality_to_cn(str(data.get("quality", "white")))
		],
		"type_line": "%s · %s" % [
			slot_to_cn(str(data.get("type", ""))),
			element_to_cn(str(data.get("element", "none")))
		],
		"desc": str(data.get("description", "无描述")),
		"effects": effect_lines,
		"has_skill": false,
		"skill_trigger": "",
		"skill_effects": []
	}


# 返回详情面板用的功法显示名，空槽时直接给出“空”。
# 名称入口收敛后，detail 行和其他地方不会再各自决定空槽文案。
func gongfa_name_or_empty(gongfa_id: String) -> String:
	if gongfa_id.is_empty():
		return "空"
	return str(build_gongfa_item_tooltip_data(gongfa_id).get("name", gongfa_id))


# 把装备配置转成统一 tooltip payload，供 detail / inventory / shop 共用。
# 装备与功法 payload 结构对齐，方便 tooltip renderer 直接复用。
func build_equip_item_tooltip_data(equip_id: String) -> Dictionary:
	var data: Dictionary = {}
	if _refs != null and _refs.unit_augment_manager != null:
		data = _refs.unit_augment_manager.call("get_equipment_data", equip_id)
	if data.is_empty():
		return {
			"name": equip_id,
			"type_line": "装备",
			"desc": "未找到装备数据",
			"effects": [],
			"has_skill": false,
			"skill_trigger": "",
			"skill_effects": []
		}
	# 装备效果和功法效果共用同一 effects 字段，tooltip renderer 不需要知道来源。
	var effect_lines: Array[String] = []
	var effects: Variant = data.get("effects", [])
	# 装备 effect 文案和功法 effect 文案共用同一翻译器，减少描述分叉。
	if effects is Array:
		for effect_value in effects:
			if effect_value is Dictionary:
				effect_lines.append(format_effect_op(effect_value as Dictionary))
	return {
		"name": "%s [%s]" % [
			str(data.get("name", equip_id)),
			quality_to_cn(str(data.get("quality", "white")))
		],
		"type_line": "%s · %s" % [
			equip_type_to_cn(str(data.get("type", "weapon"))),
			element_to_cn(str(data.get("element", "none")))
		],
		"desc": str(data.get("description", "江湖器物")),
		"effects": effect_lines,
		"has_skill": false,
		"skill_trigger": "",
		"skill_effects": []
	}


# 返回详情面板用的装备显示名，空槽时直接给出“空”。
# 这里直接复用 tooltip payload 中的名字，避免显示名来源分叉。
func equip_name_or_empty(equip_id: String) -> String:
	if equip_id.is_empty():
		return "空"
	return str(build_equip_item_tooltip_data(equip_id).get("name", equip_id))


# 把效果配置翻译成玩家可读文本，供 detail / tooltip / log 共用。
# 所有效果说明统一经过这里，后续改文案时只需要维护一个出口。
func format_effect_op(effect: Dictionary) -> String:
	var op: String = str(effect.get("op", ""))
	# 这里返回的都是玩家文案，不再把原始 effect 字典直接暴露给 UI。
	match op:
		"stat_add":
			return "%s %+d" % [
				stat_key_to_cn(str(effect.get("stat", ""))),
				int(round(float(effect.get("value", 0.0))))
			]
		"stat_percent":
			return "%s %+d%%" % [
				stat_key_to_cn(str(effect.get("stat", ""))),
				int(round(float(effect.get("value", 0.0)) * 100.0))
			]
		"mp_regen_add":
			return "内力回复 +%s/秒" % str(effect.get("value", 0))
		"range_add":
			return "射程 +%s" % str(effect.get("value", 0))
		"damage_target":
			return "对目标造成 %d 点%s伤害" % [
				int(round(float(effect.get("value", 0.0)))),
				damage_type_to_cn(str(effect.get("damage_type", "external")))
			]
		"heal_self":
			return "回复生命 %d" % int(round(float(effect.get("value", 0.0))))
		"shield_self":
			return "获得护盾 %d（%.1f秒）" % [
				int(round(float(effect.get("value", 0.0)))),
				float(effect.get("duration", 0.0))
			]
		"buff_self":
			return "获得「%s」(%.1f秒)" % [
				buff_name_from_id(str(effect.get("buff_id", ""))),
				float(effect.get("duration", 0.0))
			]
		"debuff_target":
			return "施加减益「%s」(%.1f秒)" % [
				buff_name_from_id(str(effect.get("buff_id", ""))),
				float(effect.get("duration", 0.0))
			]
		_:
			return "%s %s" % [op, str(effect)]


# 根据商店页签把类型字段翻译成功法槽名或装备类型名。
# 商店卡片只关心当前 tab 下该怎么解释 slot_type，不自己判断模式细节。
func slot_or_equip_cn(tab_id: String, slot_type: String) -> String:
	return slot_to_cn(slot_type) if tab_id == "gongfa" else equip_type_to_cn(slot_type)


# 把功法槽 key 翻译成中文显示名。
# 这里返回的是 UI 文案，不参与任何玩法逻辑判断。
func slot_to_cn(slot: String) -> String:
	match slot:
		"neigong":
			return "内功"
		"waigong":
			return "外功"
		"qinggong":
			return "身法"
		"zhenfa":
			return "阵法"
		_:
			return slot


# 为功法槽提供稳定的视觉前缀，避免详情和库存各用各的图标。
# 图标统一后，玩家更容易把 tooltip、详情和 inventory 的同类条目对上。
func slot_icon(slot: String) -> String:
	match slot:
		"neigong":
			return "☯"
		"waigong":
			return "⚔"
		"qinggong":
			return "🜂"
		"zhenfa":
			return "🧭"
		_:
			return "•"


# 把装备类型 key 翻译成中文显示名。
# 非标准类型原样返回，保证扩展数据至少还能被看懂。
func equip_type_to_cn(equip_type: String) -> String:
	match equip_type:
		"weapon":
			return "兵器"
		"armor":
			return "护甲"
		"accessory":
			return "饰品"
		_:
			return equip_type


# 为装备类型提供统一图标，供 inventory / detail 行复用。
# 这里只负责符号选择，不负责颜色和品质表现。
func equip_icon(equip_type: String) -> String:
	match equip_type:
		"weapon":
			return "🗡"
		"armor":
			return "🛡"
		"accessory":
			return "📿"
		_:
			return "•"


# 把五行属性 key 翻译成中文显示名。
# element 文案贯穿商店、inventory 和 tooltip，需要统一出口。
func element_to_cn(element: String) -> String:
	match element:
		"metal":
			return "金"
		"wood":
			return "木"
		"water":
			return "水"
		"fire":
			return "火"
		"earth":
			return "土"
		"none":
			return "无属性"
		_:
			return element


# 把属性字段名翻译成战斗面板文案。
# 这里优先服务 HUD 展示，不做数值计算。
func stat_key_to_cn(stat_key: String) -> String:
	match stat_key:
		"hp":
			return "生命"
		"mp":
			return "内力"
		"atk":
			return "外功"
		"def":
			return "外防"
		"iat":
			return "内功"
		"idr":
			return "内防"
		"spd":
			return "速度"
		"rng":
			return "射程"
		_:
			return stat_key


# 把品质 key 翻译成中文简称，供商店/库存/详情共用。
# 简称和颜色保持解耦，避免不同位置对品质视觉有不同需求时相互牵连。
func quality_to_cn(quality: String) -> String:
	match quality:
		"orange":
			return "橙"
		"purple":
			return "紫"
		"blue":
			return "蓝"
		"green":
			return "绿"
		"white":
			return "白"
		_:
			return quality


# 返回品质主色，供商店条、头像底色和 tooltip 徽章复用。
# 颜色常量统一后，玩家能快速把品质和视觉颜色建立稳定映射。
func quality_color(quality: String) -> Color:
	match quality:
		"white":
			return Color(0.78, 0.80, 0.82, 0.95)
		"green":
			return Color(0.42, 0.68, 0.42, 0.95)
		"blue":
			return Color(0.32, 0.52, 0.80, 0.95)
		"purple":
			return Color(0.54, 0.38, 0.72, 0.95)
		"orange":
			return Color(0.76, 0.48, 0.20, 0.95)
		_:
			return Color(0.50, 0.50, 0.50, 0.95)


# 用缓存把 Buff id 翻译成名称，避免 tooltip 直接展示原始 id。
# DataManager reload 后会整体重建缓存，避免这里自己做局部热更新。
func buff_name_from_id(buff_id: String) -> String:
	if _buff_data_map.has(buff_id):
		return str((_buff_data_map[buff_id] as Dictionary).get("name", buff_id))
	return buff_id


# 把伤害类型 key 翻译成中文，供效果描述和日志统一。
# 这里只有展示映射，不涉及 combat 侧真实伤害分类逻辑。
func damage_type_to_cn(damage_type: String) -> String:
	match damage_type:
		"internal":
			return "内功"
		"external":
			return "外功"
		"reflect":
			return "反伤"
		_:
			return damage_type


# 把角色当前运行态翻译成 tooltip 状态文案。
# 这里按死亡 > 战斗中 > 备战席 > 待命的优先级收敛状态文案。
func resolve_unit_status(unit: Node) -> String:
	# 状态文案偏向玩家理解，不试图覆盖 combat 侧所有细粒度状态。
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat != null and not bool(combat.get("is_alive")):
		return "已阵亡"
	if bool(unit.get("is_in_combat")):
		return "战斗中"
	if bool(unit.get("is_on_bench")):
		return "备战席"
	return "待命"


# 格式化单项属性的基础值与增益值，供详情和 tooltip 共用。
# 差值接近 0 时直接收敛成单值文本，避免出现视觉噪声很大的 +0。
func format_stat_pair(
	cn_name: String,
	runtime_stats: Dictionary,
	base_stats: Dictionary,
	key: String
) -> String:
	var runtime_value: float = float(runtime_stats.get(key, 0.0))
	var base_value: float = float(base_stats.get(key, 0.0))
	var bonus: float = runtime_value - base_value
	if absf(bonus) <= 0.001:
		return "%s %d" % [cn_name, int(round(runtime_value))]
	var prefix: String = "+" if bonus > 0.0 else ""
	return "%s %d (%s%d)" % [
		cn_name,
		int(round(runtime_value)),
		prefix,
		int(round(bonus))
	]


# 统一战斗日志颜色口径，避免不同事件类型各自定义颜色。
# 颜色只输出 hex 字符串，具体 RichText 标签由 runtime_view 拼接。
func battle_log_color_hex(event_type: String) -> String:
	match event_type:
		"damage":
			return "#FFC38A"
		"skill":
			return "#87D7FF"
		"buff":
			return "#7DE3C0"
		"death":
			return "#FF8A8A"
		"system":
			return "#B0F0B0"
		_:
			return "#D6D6D6"


# 安全读取单位属性，避免悬空节点或 null 属性把 HUD 渲染打断。
# 这里是 HUD 侧的兜底，不替代领域对象自身的数据校验。
func safe_node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if not is_valid_unit(node):
		return fallback
	var value: Variant = node.get(key)
	return fallback if value == null else value


# 只认仍然活着的实例化节点，避免把无效单位继续交给 HUD。
# HUD 内所有“单位是否可读”的判断最终都应复用这一处。
func is_valid_unit(unit: Variant) -> bool:
	if not is_instance_valid(unit):
		return false
	return (unit as Node) != null


# 统一从场景树根节点读取 autoload，避免各 helper 自己写 root 路径。
# support 自己不缓存 autoload 引用，防止测试环境替换节点后读到旧实例。
func get_root_node(node_name: String) -> Node:
	var tree: SceneTree = _scene_root.get_tree() if _scene_root != null else null
	if tree == null or tree.root == null:
		return null
	var direct: Node = tree.root.get_node_or_null(node_name)
	if direct != null:
		return direct
	return tree.root.find_child(node_name, true, false)


