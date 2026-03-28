extends "res://scripts/app/battlefield/battlefield_hud_catalog_support.gd"

const DISPLAY_TEXT_CATEGORY: String = "ui_texts"
const DISPLAY_TEXT_CONFIG_ID: String = "battlefield_hud_display"

var _display_text_config: Dictionary = {}

# HUD 文案与 payload 支撑
# 说明：
# 1. 集中承接 detail / tooltip / inventory 共用的文本翻译和 payload 组装逻辑。
# 2. 目录查询、槽位规范化和缓存逻辑已经下沉到 catalog support。
# 3. 外部协作者继续只依赖 battlefield_hud_support 这一个入口。
# 文案口径：
# 1. tooltip payload 统一由这里生成，避免多处拼接文案漂移。
# 2. 效果翻译、品质文案、图标和颜色都必须走统一出口。
# 3. 这里只做展示投影，不推断新的业务状态。


# 绑定 HUD support 需要的引用表和会话状态。
# `scene_root` 参数保留给既有装配入口，但本文件不再主动依赖场景树根。
func initialize(_scene_root, refs, state) -> void:
	_refs = refs
	_state = state


# 释放 HUD 支撑缓存，避免场景重进时沿用旧索引。
# support 不持有 UI 生命周期，只清理由自己维护的缓存和引用。
func shutdown() -> void:
	_refs = null
	_state = null
	_gongfa_by_type.clear()
	_buff_data_map.clear()
	_display_text_config.clear()


# DataManager reload 后同步刷新显示配置，保证文案/图标能走统一 data 覆盖链。
func reload_external_item_data() -> void:
	super.reload_external_item_data()
	_display_text_config.clear()
	var data_manager: Node = _get_data_repository()
	if data_manager == null or not data_manager.has_method("get_record"):
		return
	var config_record: Dictionary = data_manager.get_record(
		DISPLAY_TEXT_CATEGORY,
		DISPLAY_TEXT_CONFIG_ID
	)
	if config_record.is_empty():
		return
	_display_text_config = config_record.duplicate(true)


# 把运行时生效的功法与装备效果整理成详情面板的 bonus 列表。
# 这里故意读取 runtime_*_ids，而不是静态已装备槽，确保展示的是实际生效效果。
# 把运行时已生效的功法和装备效果整理成详情面板 bonus 列表。
# 这里只读 runtime_*_ids，确保展示的是战斗中真正生效的效果。
func build_gongfa_bonus_lines(unit: Node) -> Array[String]:
	var lines: Array[String] = []
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager == null:
		return lines
	var runtime_gongfa_ids: Array = unit.get("runtime_equipped_gongfa_ids")
	for gongfa_id_value in runtime_gongfa_ids:
		var gongfa_id: String = str(gongfa_id_value)
		var data: Dictionary = unit_augment_manager.get_gongfa_data(gongfa_id)
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
		var equip_data: Dictionary = unit_augment_manager.get_equipment_data(equip_id)
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
# trait 和 item 最终共用一套 payload，是为了让 detail view 只维护一个 renderer。
func build_trait_item_tooltip_data(trait_data: Dictionary) -> Dictionary:
	var effects: Array[String] = []
	var trait_effects: Variant = trait_data.get("effects", [])
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
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager != null:
		data = unit_augment_manager.get_gongfa_data(gongfa_id)
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
	var effect_lines: Array[String] = []
	var passive_effects: Variant = data.get("passive_effects", [])
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
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager != null:
		data = unit_augment_manager.get_equipment_data(equip_id)
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
	var effect_lines: Array[String] = []
	var effects: Variant = data.get("effects", [])
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


# 把配置组里的显示文本安全读成字符串，缺项时回退到代码默认值。
func _read_display_text(group_key: String, item_key: String, fallback: String) -> String:
	var group_value: Variant = _display_text_config.get(group_key, {})
	if not (group_value is Dictionary):
		return fallback
	var entry_value: Variant = (group_value as Dictionary).get(item_key, null)
	if entry_value is Dictionary:
		var entry_text: String = str((entry_value as Dictionary).get("text", fallback)).strip_edges()
		return fallback if entry_text.is_empty() else entry_text
	if entry_value == null:
		return fallback
	var text_value: String = str(entry_value).strip_edges()
	return fallback if text_value.is_empty() else text_value


# 图标配置只接受带 icon 字段的映射对象，避免把普通文本误当图标。
func _read_display_icon(group_key: String, item_key: String, fallback: String) -> String:
	var group_value: Variant = _display_text_config.get(group_key, {})
	if not (group_value is Dictionary):
		return fallback
	var entry_value: Variant = (group_value as Dictionary).get(item_key, null)
	if not (entry_value is Dictionary):
		return fallback
	var icon_text: String = str((entry_value as Dictionary).get("icon", fallback)).strip_edges()
	return fallback if icon_text.is_empty() else icon_text


# 颜色配置统一从 data 组读取，再交给底层颜色解析器做格式兼容。
func _read_display_color(group_key: String, item_key: String, fallback: Color) -> Color:
	var group_value: Variant = _display_text_config.get(group_key, {})
	if not (group_value is Dictionary):
		return fallback
	return _variant_to_color((group_value as Dictionary).get(item_key, null), fallback)


# 支持数组、字典和字符串三种颜色格式，保证 JSON 配置足够宽容。
func _variant_to_color(value: Variant, fallback: Color) -> Color:
	if value is Array:
		var channels: Array = value as Array
		if channels.size() == 3:
			return Color(
				float(channels[0]),
				float(channels[1]),
				float(channels[2]),
				1.0
			)
		if channels.size() >= 4:
			return Color(
				float(channels[0]),
				float(channels[1]),
				float(channels[2]),
				float(channels[3])
			)
	if value is Dictionary:
		var color_data: Dictionary = value as Dictionary
		return Color(
			float(color_data.get("r", fallback.r)),
			float(color_data.get("g", fallback.g)),
			float(color_data.get("b", fallback.b)),
			float(color_data.get("a", fallback.a))
		)
	if value is String:
		var color_text: String = str(value).strip_edges()
		if color_text.is_empty():
			return fallback
		return Color.from_string(color_text, fallback)
	return fallback


# 槽位默认文案保留在代码里，防止坏配置把 HUD 退化成原始 key。
func _fallback_slot_label(slot: String) -> String:
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


# 槽位默认图标维持旧视觉口径，配置缺失时不改变玩家认知。
func _fallback_slot_icon(slot: String) -> String:
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


# 装备类型默认文案只服务展示，不参与任何装备业务判断。
func _fallback_equip_type_label(equip_type: String) -> String:
	match equip_type:
		"weapon":
			return "兵器"
		"armor":
			return "护甲"
		"accessory":
			return "饰品"
		_:
			return equip_type


# 装备类型默认图标继续供 detail / inventory / shop 共用。
func _fallback_equip_icon(equip_type: String) -> String:
	match equip_type:
		"weapon":
			return "🗡"
		"armor":
			return "🛡"
		"accessory":
			return "📿"
		_:
			return "•"


# 属性中文名默认值留在代码里，避免效果描述在坏数据下完全失真。
func _fallback_stat_label(stat_key: String) -> String:
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


# 品质简称默认值维持旧口径，方便数据迁移阶段逐步切换。
func _fallback_quality_label(quality: String) -> String:
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


# 品质颜色默认值保留旧配色，避免配置缺失时界面跳色。
func _fallback_quality_color(quality: String) -> Color:
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


# 伤害类型默认文案只解决 HUD 展示，不改变战斗分类语义。
func _fallback_damage_type_label(damage_type: String) -> String:
	match damage_type:
		"internal":
			return "内功"
		"external":
			return "外功"
		"reflect":
			return "反伤"
		_:
			return damage_type


# 把功法槽 key 翻译成中文显示名。
# 这里返回的是 UI 文案，不参与任何玩法逻辑判断。
# 功法槽中文名优先读配置，缺失时回退旧硬编码。
func slot_to_cn(slot: String) -> String:
	return _read_display_text("slot_labels", slot, _fallback_slot_label(slot))


# 为功法槽提供稳定的视觉前缀，避免详情和库存各用各的图标。
# 图标统一后，玩家更容易把 tooltip、详情和 inventory 的同类条目对上。
# 功法槽图标优先读配置，保证 mod 可以统一替换视觉符号。
func slot_icon(slot: String) -> String:
	return _read_display_icon("slot_labels", slot, _fallback_slot_icon(slot))


# 把装备类型 key 翻译成中文显示名。
# 非标准类型原样返回，保证扩展数据至少还能被看懂。
# 装备类型中文名优先读配置，保留原有方法签名给调用方复用。
func equip_type_to_cn(equip_type: String) -> String:
	return _read_display_text(
		"equip_type_labels",
		equip_type,
		_fallback_equip_type_label(equip_type)
	)


# 为装备类型提供统一图标，供 inventory / detail 行复用。
# 这里只负责符号选择，不负责颜色和品质表现。
# 装备类型图标优先读配置，避免 detail / inventory 各自写死。
func equip_icon(equip_type: String) -> String:
	return _read_display_icon("equip_type_labels", equip_type, _fallback_equip_icon(equip_type))


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
# 属性中文名优先读配置，效果描述和面板字段共享同一出口。
func stat_key_to_cn(stat_key: String) -> String:
	return _read_display_text("stat_labels", stat_key, _fallback_stat_label(stat_key))


# 把品质 key 翻译成中文简称，供商店/库存/详情共用。
# 简称和颜色保持解耦，避免不同位置对品质视觉有不同需求时相互牵连。
# 品质简称优先读配置，方便不同数据包切换展示文案。
func quality_to_cn(quality: String) -> String:
	return _read_display_text("quality_labels", quality, _fallback_quality_label(quality))


# 返回品质主色，供商店条、头像底色和 tooltip 徽章复用。
# 颜色常量统一后，玩家能快速把品质和视觉颜色建立稳定映射。
# 品质颜色优先读配置，同时维持返回 Color 的既有契约。
func quality_color(quality: String) -> Color:
	return _read_display_color("quality_colors", quality, _fallback_quality_color(quality))


# 用缓存把 Buff id 翻译成名称，避免 tooltip 直接展示原始 id。
# DataManager reload 后会整体重建缓存，避免这里自己做局部热更新。
func buff_name_from_id(buff_id: String) -> String:
	if _buff_data_map.has(buff_id):
		return str((_buff_data_map[buff_id] as Dictionary).get("name", buff_id))
	return buff_id


# 把伤害类型 key 翻译成中文，供效果描述和日志统一。
# 这里只有展示映射，不涉及 combat 侧真实伤害分类逻辑。
# 伤害类型文案优先读配置，缺失时回退旧口径。
func damage_type_to_cn(damage_type: String) -> String:
	return _read_display_text(
		"damage_type_labels",
		damage_type,
		_fallback_damage_type_label(damage_type)
	)


# 把角色当前运行态翻译成 tooltip 状态文案。
# 这里按死亡 > 战斗中 > 备战席 > 待命的优先级收敛状态文案。
func resolve_unit_status(unit: Node) -> String:
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
