extends Node

# M5 ?????????
# ???????? + ????UI?????????????????? battlefield.gd?


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


func update_shop_ui(ctx: Node) -> void:
	if ctx == null:
		return
	# ?????????/???? + ?????
	ctx.call("_update_shop_operation_labels")
	ctx.call("_rebuild_shop_cards")
