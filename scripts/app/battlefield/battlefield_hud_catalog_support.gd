extends RefCounted

# HUD 共享目录支持
# 说明：
# 1. 集中承接 HUD 各子协作者共用的单位收集、槽位规范化和静态缓存逻辑。
# 2. 这里不直接拼 tooltip 文案，也不承接信号连接。
# 共享 support 的目标不是“什么都管”，而是把目录查询和结构归一化从 view 中移走。
# 数据来源口径：
# 1. 单位列表只认 bench + ally_deployed。
# 2. Buff 名称缓存统一从 DataManager 读取。
# 3. 空配置也要返回稳定结构，避免 HUD 到处判空。
# 规范化口径：
# 1. 功法槽固定四槽。
# 2. 装备槽先排序再补空槽，确保 detail / inventory 顺序一致。
# 3. 任何单位可读性判断都统一复用 is_valid_unit。

const TEAM_ALLY: int = 1 # 己方队伍标识。
const TEAM_ENEMY: int = 2 # 敌方队伍标识。
const SLOT_ORDER: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa"] # 功法槽顺序。
const DEFAULT_EQUIP_ORDER: Array[String] = ["slot_1", "slot_2"] # 装备槽默认顺序。

var _refs = null # 场景引用表。
var _state = null # 会话状态表。
var _gongfa_by_type: Dictionary = {} # 功法类型到 id 列表的索引。
var _buff_data_map: Dictionary = {} # Buff 数据缓存。


# 重建功法类型索引，供 detail / tooltip / inventory 复用同一份查表。
# 缓存结构是 type -> [id]，后续只读这份索引，不重复扫描全量功法表。
func build_gongfa_type_cache() -> void:
	_gongfa_by_type.clear()
	for slot in SLOT_ORDER:
		_gongfa_by_type[slot] = []
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager == null:
		return
	var all_data: Variant = unit_augment_manager.get_all_gongfa()
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
	var data_manager: Node = _get_data_repository()
	if data_manager == null:
		return
	var buff_records: Variant = data_manager.get_all_records("buffs")
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
	var bench_ui = _get_bench_ui()
	if bench_ui != null:
		for unit in bench_ui.get_all_units():
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
	var combat_manager = _get_combat_manager()
	if combat_manager != null:
		return int(combat_manager.get_alive_count(team_id))
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


# 只认仍然活着的实例化节点，避免把无效单位继续交给 HUD。
# HUD 内所有“单位是否可读”的判断最终都应复用这一处。
func is_valid_unit(unit: Variant) -> bool:
	if not is_instance_valid(unit):
		return false
	return (unit as Node) != null


# 统一从注入 refs 读取数据仓库，避免 helper 自己找根节点。
# support 不缓存服务副本，防止测试环境替换节点后读到旧实例。
func _get_data_repository() -> Node:
	if _refs == null or not _refs.has_method("get_data_repository"):
		return null
	return _refs.get_data_repository()


# 统一通过 refs 取 UnitAugmentManager，避免各处重复判空。
# catalog support 只读公开接口，不回退到反射调用。
func _get_unit_augment_manager():
	if _refs == null:
		return null
	return _refs.unit_augment_manager


# 统一读取备战席组件，减少 catalog support 内部重复取 refs。
# bench_ui 缺失时直接返回 null，让上层决定是否跳过统计。
func _get_bench_ui():
	if _refs == null:
		return null
	return _refs.bench_ui


# 统一读取 CombatManager，供顶栏战力条共享。
# catalog support 只消费只读查询接口，不直接推动战斗流程。
func _get_combat_manager():
	if _refs == null:
		return null
	return _refs.combat_manager
