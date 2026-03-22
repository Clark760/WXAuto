extends Node

# M5 商店控制器
# 负责“备战阶段商店刷新 + 商店 UI 更新”的调度，简化 battlefield.gd。


# 在备战阶段刷新商店内容，并在刷新后同步 UI。
# force_refresh=true 时无视常规刷新节流，执行强制重置。
func refresh_shop_for_preparation(ctx: Node, force_refresh: bool) -> void:
	if ctx == null:
		return
	var economy_manager: Node = ctx.get("_economy_manager")
	var shop_manager: Node = ctx.get("_shop_manager")
	if economy_manager == null or shop_manager == null:
		return
	var locked: bool = bool(economy_manager.call("is_shop_locked"))
	shop_manager.call("refresh_shop", economy_manager.call("get_shop_probabilities"), locked, force_refresh)
	update_shop_ui(ctx)


# 刷新商店可视层：按钮状态、货币文案、商品卡片。
func update_shop_ui(ctx: Node) -> void:
	if ctx == null:
		return
	# 统一通过 battlefield 内部实现更新，保证单一 UI 刷新入口。
	ctx.call("_update_shop_operation_labels")
	ctx.call("_rebuild_shop_cards")
