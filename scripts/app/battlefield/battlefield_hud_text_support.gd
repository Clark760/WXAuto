extends "res://scripts/app/battlefield/battlefield_hud_catalog_support.gd"

const DISPLAY_TEXT_CATEGORY: String = "ui_texts"
const DISPLAY_TEXT_CONFIG_IDS: Array[String] = [
	"battlefield_hud_display",
	"battlefield_hud_effect_texts"
]

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
	for config_id in DISPLAY_TEXT_CONFIG_IDS:
		var config_record: Dictionary = data_manager.get_record(DISPLAY_TEXT_CATEGORY, config_id)
		if config_record.is_empty():
			continue
		_merge_display_text_config(_display_text_config, config_record)

func _normalize_trigger_name(trigger_name: String) -> String:
	var normalized: String = trigger_name.strip_edges().to_lower()
	if normalized == "periodic":
		return "periodic_seconds"
	if normalized == "on_buff_expire":
		return "on_buff_expired"
	return normalized


func _format_number(value: float) -> String:
	if is_equal_approx(value, round(value)):
		return str(int(round(value)))
	return str(snappedf(value, 0.01))


func _format_signed_number(value: float) -> String:
	if value > 0.0:
		return "+%s" % _format_number(value)
	return _format_number(value)


func _format_percent(value: float) -> String:
	return "%s%%" % _format_number(value * 100.0)


func _format_signed_percent(value: float) -> String:
	return "%s%%" % _format_signed_number(value * 100.0)


# 根据商店页签把类型字段翻译成功法槽名或装备类型名。
# 商店卡片只关心当前 tab 下该怎么解释 slot_type，不自己判断模式细节。
func slot_or_equip_cn(tab_id: String, slot_type: String) -> String:
	return slot_to_cn(slot_type) if tab_id == "gongfa" else equip_type_to_cn(slot_type)


func _merge_display_text_config(target: Dictionary, incoming: Dictionary) -> void:
	for key_value in incoming.keys():
		var key: String = str(key_value)
		if key == "id":
			continue
		var incoming_value: Variant = incoming.get(key_value, null)
		if target.has(key) and target[key] is Dictionary and incoming_value is Dictionary:
			_merge_display_text_config(target[key] as Dictionary, incoming_value as Dictionary)
			continue
		if incoming_value is Dictionary:
			target[key] = (incoming_value as Dictionary).duplicate(true)
		elif incoming_value is Array:
			target[key] = (incoming_value as Array).duplicate(true)
		else:
			target[key] = incoming_value


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


# 地形类别默认文案只用于 HUD 展示，不参与地形判定逻辑。
func _fallback_terrain_type_label(terrain_type: String) -> String:
	match terrain_type:
		"beneficial":
			return "增益地形"
		"hazard":
			return "危险地形"
		"obstacle":
			return "障碍地形"
		_:
			return terrain_type


# 单位状态文案支持外置覆盖，兜底继续保持旧文案。
func _fallback_status_label(status_key: String) -> String:
	match status_key:
		"dead":
			return "已阵亡"
		"in_combat":
			return "战斗中"
		"on_bench":
			return "备战席"
		"idle":
			return "待命"
		_:
			return status_key


func _fallback_trigger_label(trigger_name: String) -> String:
	return trigger_name


func _fallback_trigger_team_scope_label(scope_key: String) -> String:
	match scope_key:
		"ally", "self_team":
			return "我方"
		"enemy":
			return "敌方"
		"both", "all":
			return "双方"
		_:
			return scope_key


func _fallback_linkage_execution_mode_label(mode_key: String) -> String:
	return mode_key


func _fallback_linkage_team_scope_label(scope_key: String) -> String:
	return scope_key


func _fallback_linkage_count_mode_label(mode_key: String) -> String:
	return mode_key


func _fallback_linkage_source_type_label(source_type: String) -> String:
	return source_type


func _fallback_linkage_origin_scope_label(scope_key: String) -> String:
	return scope_key


func _fallback_linkage_tag_match_label(match_key: String) -> String:
	return match_key


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


# 地形类别文案优先读配置，缺失时回退默认文案。
func terrain_class_to_cn(terrain_type: String) -> String:
	return _read_display_text(
		"terrain_type_labels",
		terrain_type.strip_edges().to_lower(),
		_fallback_terrain_type_label(terrain_type.strip_edges().to_lower())
	)


func effect_op_to_cn(op: String) -> String:
	return _read_display_text("effect_op_labels", op, op)


func trigger_to_cn(trigger_name: String) -> String:
	var normalized: String = _normalize_trigger_name(trigger_name)
	return _read_display_text("trigger_labels", normalized, _fallback_trigger_label(normalized))


func trigger_team_scope_to_cn(scope_key: String) -> String:
	var normalized: String = scope_key.strip_edges().to_lower()
	return _read_display_text(
		"trigger_team_scope_labels",
		normalized,
		_fallback_trigger_team_scope_label(normalized)
	)


func linkage_execution_mode_to_cn(mode_key: String) -> String:
	var normalized: String = mode_key.strip_edges().to_lower()
	return _read_display_text(
		"linkage_execution_mode_labels",
		normalized,
		_fallback_linkage_execution_mode_label(normalized)
	)


func linkage_team_scope_to_cn(scope_key: String) -> String:
	var normalized: String = scope_key.strip_edges().to_lower()
	return _read_display_text(
		"linkage_team_scope_labels",
		normalized,
		_fallback_linkage_team_scope_label(normalized)
	)


func linkage_count_mode_to_cn(mode_key: String) -> String:
	var normalized: String = mode_key.strip_edges().to_lower()
	return _read_display_text(
		"linkage_count_mode_labels",
		normalized,
		_fallback_linkage_count_mode_label(normalized)
	)


func linkage_source_type_to_cn(source_type: String) -> String:
	var normalized: String = source_type.strip_edges().to_lower()
	return _read_display_text(
		"linkage_source_type_labels",
		normalized,
		_fallback_linkage_source_type_label(normalized)
	)


func linkage_origin_scope_to_cn(scope_key: String) -> String:
	var normalized: String = scope_key.strip_edges().to_lower()
	return _read_display_text(
		"linkage_origin_scope_labels",
		normalized,
		_fallback_linkage_origin_scope_label(normalized)
	)


func linkage_tag_match_to_cn(tag_match: String) -> String:
	var normalized: String = tag_match.strip_edges().to_lower()
	return _read_display_text(
		"linkage_tag_match_labels",
		normalized,
		_fallback_linkage_tag_match_label(normalized)
	)


# 把角色当前运行态翻译成 tooltip 状态文案。
# 这里按死亡 > 战斗中 > 备战席 > 待命的优先级收敛状态文案。
func resolve_unit_status(unit: Node) -> String:
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat != null and not bool(combat.get("is_alive")):
		return _read_display_text("status_labels", "dead", _fallback_status_label("dead"))
	if bool(unit.get("is_in_combat")):
		return _read_display_text("status_labels", "in_combat", _fallback_status_label("in_combat"))
	if bool(unit.get("is_on_bench")):
		return _read_display_text("status_labels", "on_bench", _fallback_status_label("on_bench"))
	return _read_display_text("status_labels", "idle", _fallback_status_label("idle"))


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
