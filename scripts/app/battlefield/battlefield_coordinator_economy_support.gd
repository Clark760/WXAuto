extends RefCounted

# coordinator 经济与奖励支撑
# 说明：
# 1. 只承接商店、奖励发放和回收出售。
# 2. 不处理战斗开始/结束和关卡推进。
# 资金流口径：
# 1. 扣费先发生，发放失败必须回滚，避免商店和奖励把资产写乱。
# 2. 成功动作统一写 battle log，玩家能从 HUD 看到每次经济变化来源。
# 奖励口径：
# 1. 物品奖励直接写库存，不额外生成临时 UI 节点。
# 2. 角色奖励优先上 bench，再尝试棋盘，最后才放弃。
# 3. 奖励落位后的表现刷新统一交给 world controller，不在这里摆坐标。
# 出售口径：
# 1. 单位出售只允许准备期且来源为 bench 拖拽。
# 2. 物品出售只改库存和银两，不额外介入详情显示逻辑。
# 3. 回收价格优先取条目品质，再用外部传入值做兜底。

const STAGE_PREPARATION: int = 0 # 只有备战期允许商店和出售动作。
const RECYCLE_PRICING_SCRIPT: Script = preload(
	"res://scripts/domain/economy/recycle_pricing.gd"
) # 回收定价纯规则脚本。
# 价格规则继续留在 domain，support 这里只负责把条目出售结果落到运行时资产。
# 这样后续调平衡时不必再回到 coordinator support 改硬编码价格表。
# 运行时层保留的职责只有扣库存、加银两和写 battle log。

var _owner = null # coordinator facade，用于刷新 presenter。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。
var _rng: RandomNumberGenerator = RandomNumberGenerator.new() # 奖励落位随机源。


# 绑定经济支撑需要的 facade、引用表、会话状态和随机源。
func initialize(owner, refs, state, rng: RandomNumberGenerator) -> void:
	_owner = owner
	_refs = refs
	_state = state
	_rng = rng


# 准备期刷新商店时，统一遵循锁店和强制刷新口径。
# shop manager 只拿概率和锁定态，是否该刷新由这个支撑统一决策。
func refresh_shop_for_preparation(force_refresh: bool) -> void:
	if _refs.runtime_economy_manager == null or _refs.runtime_shop_manager == null:
		return
	var locked: bool = false
	if _refs.runtime_economy_manager.has_method("is_shop_locked"):
		locked = bool(_refs.runtime_economy_manager.call("is_shop_locked"))
	if _refs.runtime_shop_manager.has_method("refresh_shop"):
		_refs.runtime_shop_manager.call(
			"refresh_shop",
			_refs.runtime_economy_manager.call("get_shop_probabilities"),
			locked,
			force_refresh
		)
	_owner._refresh_presenter()


# 购买商店条目时统一处理扣费、发放和日志。
# 扣费和发放拆成两个阶段，是为了在 grant 失败时能够明确回滚。
func purchase_shop_offer(tab_id: String, index: int) -> void:
	if int(_state.stage) != STAGE_PREPARATION:
		return
	if _refs.runtime_economy_manager == null or _refs.runtime_shop_manager == null:
		return
	var offer: Dictionary = _refs.runtime_shop_manager.call("get_offer", tab_id, index)
	if offer.is_empty() or bool(offer.get("sold", false)):
		return
	var price: int = maxi(int(offer.get("price", 0)), 0)
	if not bool(_refs.runtime_economy_manager.call("spend_silver", price)):
		if _refs.debug_label != null:
			_refs.debug_label.text = "银两不足：购买失败。"
		return
	if not _grant_offer(offer):
		_refs.runtime_economy_manager.call("add_silver", price)
		return
	_refs.runtime_shop_manager.call("purchase_offer", tab_id, index)
	_owner._append_battle_log(
		"商店购买：%s（- %d 银两）" % [str(offer.get("name", "未知")), price],
		"system"
	)
	_owner._refresh_presenter()


# 顶栏手动刷新按钮只负责扣费、解锁并重建当前商店。
# 手动刷新会强制解除锁店，避免玩家误以为“锁店后还能免费换货”。
func refresh_shop_from_button() -> void:
	if int(_state.stage) != STAGE_PREPARATION:
		return
	if _refs.runtime_economy_manager == null or _refs.runtime_shop_manager == null:
		return
	var cost: int = int(_refs.runtime_economy_manager.call("get_refresh_cost"))
	if not bool(_refs.runtime_economy_manager.call("spend_silver", cost)):
		if _refs.debug_label != null:
			_refs.debug_label.text = "银两不足：刷新需要 %d 银两" % cost
		return
	_refs.runtime_economy_manager.call("set_shop_locked", false)
	_refs.runtime_shop_manager.call(
		"refresh_shop",
		_refs.runtime_economy_manager.call("get_shop_probabilities"),
		false,
		true
	)
	_owner._append_battle_log("商店刷新：消耗 %d 银两" % cost, "system")
	_owner._refresh_presenter()


# 锁店开关只切换状态和提示文案，不承接任何额外刷新逻辑。
# 真正的刷新发生在下次 preparation refresh，避免这里偷偷改当前货架。
func toggle_shop_lock() -> void:
	if int(_state.stage) != STAGE_PREPARATION or _refs.runtime_economy_manager == null:
		return
	var next_locked: bool = not bool(_refs.runtime_economy_manager.call("is_shop_locked"))
	_refs.runtime_economy_manager.call("set_shop_locked", next_locked)
	if _refs.debug_label != null:
		if next_locked:
			_refs.debug_label.text = "商店已锁定，下回合将保留当前商品。"
		else:
			_refs.debug_label.text = "商店已解锁，下回合会自动刷新。"
	_owner._refresh_presenter()


# 商店升级按钮只负责经验购买和提示日志。
# 升级结果统一回 presenter 刷新，避免顶栏数字与商店文案不同步。
func buy_shop_upgrade() -> void:
	if int(_state.stage) != STAGE_PREPARATION or _refs.runtime_economy_manager == null:
		return
	if not bool(_refs.runtime_economy_manager.call("buy_exp_with_silver")):
		if _refs.debug_label != null:
			_refs.debug_label.text = "银两不足：升级需要 %d 银两" % int(
				_refs.runtime_economy_manager.call("get_upgrade_cost")
			)
		return
	_owner._append_battle_log(
		"门派修炼：消耗 %d 银两，获得 %d 经验" % [
			int(_refs.runtime_economy_manager.call("get_upgrade_cost")),
			int(_refs.runtime_economy_manager.call("get_upgrade_exp_gain"))
		],
		"system"
	)
	_owner._refresh_presenter()


# 测试银两入口只在本地调试使用，但也统一走 presenter 刷新。
# 即使是调试入口，也遵守 battle log 记账口径，方便回放排查。
func add_test_silver() -> void:
	if _refs.runtime_economy_manager == null:
		return
	_refs.runtime_economy_manager.call("add_silver", 10)
	_owner._append_battle_log("测试指令：银两 +10", "system")
	_owner._refresh_presenter()


# 测试经验入口只在本地调试使用，但也统一走 presenter 刷新。
# 经验变化会影响上场上限和升级按钮状态，因此必须立刻刷新 HUD。
func add_test_exp() -> void:
	if _refs.runtime_economy_manager == null:
		return
	_refs.runtime_economy_manager.call("add_exp", 5)
	_owner._append_battle_log("测试指令：经验 +5", "system")
	_owner._refresh_presenter()


# 拖拽出售角色时，只允许备战席来源在准备期落入回收区。
# 这样可以明确拒绝棋盘中的已部署单位被世界拖拽直接卖掉。
func try_sell_dragging_unit() -> bool:
	if int(_state.stage) != STAGE_PREPARATION:
		return false
	if _state.dragging_unit == null or not is_instance_valid(_state.dragging_unit):
		return false
	var origin_kind: String = ""
	if _refs.runtime_drag_controller != null:
		if _refs.runtime_drag_controller.has_method("get_drag_origin_kind"):
			origin_kind = str(_refs.runtime_drag_controller.call("get_drag_origin_kind"))
	if origin_kind != "bench":
		return false
	return _sell_unit_node(_state.dragging_unit)


# 发放功法或装备奖励时，库存统一写回 session state。
# coordinator 后续只需要刷新 presenter，不需要知道库存内部结构。
func grant_stage_reward_item(item_type: String, item_id: String, count: int = 1) -> bool:
	var normalized_type: String = item_type.strip_edges().to_lower()
	var amount: int = maxi(count, 1)
	if item_id.strip_edges().is_empty():
		return false
	match normalized_type:
		"gongfa":
			_state.add_owned_item("gongfa", item_id, amount)
			_owner._refresh_presenter()
			return true
		"equipment":
			_state.add_owned_item("equipment", item_id, amount)
			_owner._refresh_presenter()
			return true
		_:
			return false


# 发放角色奖励时优先上备战席，放不下再尝试落到棋盘。
# “discarded” 结果会留给调用方记录日志，避免奖励静默消失。
func grant_stage_reward_unit(unit_id: String, star: int = 1) -> Dictionary:
	var result: Dictionary = {
		"type": "unit",
		"id": unit_id,
		"star": clampi(star, 1, 3),
		"granted": false,
		"placement": "discarded"
	}
	if unit_id.strip_edges().is_empty() or _refs.unit_factory == null:
		return result
	var unit_node: Node = _refs.unit_factory.call("acquire_unit", unit_id, clampi(star, 1, 3), _refs.unit_layer)
	if unit_node == null:
		return result
	unit_node.call("set_team", 1)
	unit_node.call("set_on_bench_state", true, -1)
	unit_node.set("is_in_combat", false)
	if _refs.bench_ui != null and _refs.bench_ui.has_method("add_unit"):
		if bool(_refs.bench_ui.call("add_unit", unit_node)):
			result["granted"] = true
			result["placement"] = "bench"
			_owner._get_world_controller().refresh_world_layout()
			return result
	var board_cell: Vector2i = _find_reward_unit_board_cell(unit_node)
	if board_cell.x >= 0 and _refs.runtime_unit_deploy_manager != null:
		if _refs.runtime_unit_deploy_manager.has_method("deploy_ally_unit_to_cell"):
			_refs.runtime_unit_deploy_manager.call("deploy_ally_unit_to_cell", unit_node, board_cell)
			result["granted"] = true
			result["placement"] = "board"
			result["cell"] = board_cell
			_owner._get_world_controller().refresh_world_layout()
			return result
	_refs.unit_factory.call("release_unit", unit_node)
	return result


# 回收区出售请求统一在这里处理，避免 shop 和 inventory 各自写一套。
# payload 允许 unit/item 两种来源，但最终都收口为同一条银两增加路径。
func on_recycle_sell_requested(payload: Dictionary, price: int) -> void:
	if int(_state.stage) != STAGE_PREPARATION or _refs.runtime_economy_manager == null:
		return
	var item_type: String = str(payload.get("type", "")).strip_edges()
	if item_type == "unit":
		var unit_node: Node = payload.get("unit_node", null)
		if unit_node == null or not is_instance_valid(unit_node):
			return
		if _sell_unit_node(unit_node):
			return
		if _refs.debug_label != null:
			_refs.debug_label.text = "出售失败：该角色不在备战区。"
		return
	if item_type != "gongfa" and item_type != "equipment":
		return
	var item_id: String = str(payload.get("id", "")).strip_edges()
	if item_id.is_empty():
		return
	if not _state.consume_owned_item(item_type, item_id, 1):
		if _refs.debug_label != null:
			_refs.debug_label.text = "出售失败：库存不足。"
		return
	var item_data: Dictionary = {}
	var raw_item_data: Variant = payload.get("item_data", {})
	if raw_item_data is Dictionary:
		item_data = (raw_item_data as Dictionary).duplicate(true)
	# payload 没带完整条目数据时，仍允许外部 price 作为最终兜底价落账。
	var final_price: int = RECYCLE_PRICING_SCRIPT.item_sell_price(item_data)
	if final_price <= 0:
		final_price = maxi(price, 0)
	_refs.runtime_economy_manager.call("add_silver", final_price)
	_owner._append_battle_log(
		"出售%s：%s（+%d 银两）" % [
			"功法" if item_type == "gongfa" else "装备",
			_resolve_sell_item_name(item_type, item_id),
			final_price
		],
		"system"
	)
	_owner._refresh_presenter()


# 发放商店条目时，把招募与库存类条目统一收口。
# 商店条目先按 tab 分流，再落到招募或库存写入，避免 view 层直接碰数据结构。
func _grant_offer(offer: Dictionary) -> bool:
	var tab_id: String = str(offer.get("tab", ""))
	var item_id: String = str(offer.get("item_id", "")).strip_edges()
	if item_id.is_empty():
		if _refs.debug_label != null:
			_refs.debug_label.text = "商店条目无效：缺少 item_id。"
		return false
	if tab_id == "recruit":
		return _grant_recruit_unit(item_id)
	if tab_id == "gongfa":
		_state.add_owned_item("gongfa", item_id, 1)
		return true
	if tab_id == "equipment":
		_state.add_owned_item("equipment", item_id, 1)
		return true
	if _refs.debug_label != null:
		_refs.debug_label.text = "未知商店页签：%s" % tab_id
	return false


# 招募条目优先上备战席，失败则直接回滚。
# 这里不尝试自动落棋盘，商店招募的预期仍然是先进入 bench。
func _grant_recruit_unit(unit_id: String) -> bool:
	if _refs.bench_ui == null or _refs.unit_factory == null:
		return false
	if int(_refs.bench_ui.call("get_unit_count")) >= int(_refs.bench_ui.call("get_slot_count")):
		if _refs.debug_label != null:
			_refs.debug_label.text = "备战区已满，无法招募。"
		return false
	var unit_node: Node = _refs.unit_factory.call("acquire_unit", unit_id, -1, _refs.unit_layer)
	if unit_node == null:
		if _refs.debug_label != null:
			_refs.debug_label.text = "招募失败：无法创建角色 %s" % unit_id
		return false
	unit_node.call("set_team", 1)
	unit_node.call("set_on_bench_state", true, -1)
	unit_node.set("is_in_combat", false)
	if not bool(_refs.bench_ui.call("add_unit", unit_node)):
		_refs.unit_factory.call("release_unit", unit_node)
		if _refs.debug_label != null:
			_refs.debug_label.text = "备战区已满，无法招募。"
		return false
	_owner._get_world_controller().refresh_world_layout()
	return true


# 奖励角色落棋盘时，复用部署区候选格和阻挡判定。
# 候选格顺序会打乱，既避免奖励总落同一格，也保留可重复的单局随机源。
func _find_reward_unit_board_cell(unit_node: Node = null) -> Vector2i:
	if _refs.runtime_unit_deploy_manager == null:
		return Vector2i(-1, -1)
	var candidates: Array[Vector2i] = _refs.runtime_unit_deploy_manager.call("collect_ally_spawn_cells")
	if candidates.is_empty():
		return Vector2i(-1, -1)
	_shuffle_cells(candidates)
	for cell in candidates:
		var cell_key: String = "%d,%d" % [cell.x, cell.y]
		if _state.ally_deployed.has(cell_key):
			continue
		if _is_stage_cell_blocked(cell):
			continue
		if unit_node != null and _refs.runtime_unit_deploy_manager.has_method("can_deploy_ally_to_cell"):
			if not bool(_refs.runtime_unit_deploy_manager.call("can_deploy_ally_to_cell", unit_node, cell)):
				continue
		return cell
	return Vector2i(-1, -1)


# 奖励落位前仍要遵循战场当前阻挡格规则。
# 这样 terrain、障碍和单位占位的限制，在奖励入口也能保持一致。
func _is_stage_cell_blocked(cell: Vector2i) -> bool:
	if _refs.combat_manager == null or not _refs.combat_manager.has_method("is_cell_blocked"):
		return false
	return bool(_refs.combat_manager.call("is_cell_blocked", cell))


# 出售角色时只允许备战席单位进入回收流程。
# 一旦角色正在详情面板中展示，出售成功后还要顺手把详情面板关掉。
func _sell_unit_node(unit_node: Node) -> bool:
	if unit_node == null or not is_instance_valid(unit_node) or _refs.runtime_economy_manager == null:
		return false
	var unit_name: String = str(_safe_node_prop(unit_node, "unit_name", "未知角色"))
	var in_bench: bool = bool(unit_node.get("is_on_bench"))
	if _refs.bench_ui != null and _refs.bench_ui.has_method("find_slot_of_unit"):
		var slot: int = int(_refs.bench_ui.call("find_slot_of_unit", unit_node))
		if slot >= 0:
			in_bench = true
			_refs.bench_ui.call("remove_unit_at", slot)
	if not in_bench:
		return false
	if _state.detail_unit == unit_node:
		var presenter: Node = _owner._get_hud_presenter()
		if presenter != null:
			presenter.force_close_detail_panel(false)
	if _refs.unit_factory != null:
		_refs.unit_factory.call("release_unit", unit_node)
	var unit_price: int = maxi(int(_safe_node_prop(unit_node, "cost", 0)), 0)
	_refs.runtime_economy_manager.call("add_silver", unit_price)
	_owner._append_battle_log("出售角色：%s（+%d 银两）" % [unit_name, unit_price], "system")
	_owner._refresh_presenter()
	return true
# 出售日志需要把 id 翻译成人类可读名称。
# 日志名称只影响展示，不反向修改库存里保存的原始 id。
func _resolve_sell_item_name(item_type: String, item_id: String) -> String:
	if _refs.unit_augment_manager == null:
		return item_id
	var data: Dictionary = {}
	if item_type == "gongfa":
		data = _refs.unit_augment_manager.call("get_gongfa_data", item_id)
	else:
		data = _refs.unit_augment_manager.call("get_equipment_data", item_id)
	return str(data.get("name", item_id))


# 局部安全读属性，避免出售路径被无效单位属性打断。
# 这里的 fallback 只服务出售流程，不向外扩展成通用对象读取工具。
func _safe_node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if node == null or not is_instance_valid(node):
		return fallback
	var value: Variant = node.get(key)
	if value == null:
		return fallback
	return value


# 用共享随机源打乱候选格，保持奖励落位稳定但不死板。
# 奖励与敌军部署共用同一个随机源，可以维持同局内随机口径一致。
func _shuffle_cells(cells: Array[Vector2i]) -> void:
	for index in range(cells.size() - 1, 0, -1):
		var swap_index: int = _rng.randi_range(0, index)
		var temp: Vector2i = cells[index]
		cells[index] = cells[swap_index]
		cells[swap_index] = temp
