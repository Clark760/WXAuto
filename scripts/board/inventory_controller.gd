extends Node

# M5 库存控制器
# 负责触发库存面板重建，避免 battlefield.gd 承担细节刷新逻辑。


# 触发库存条目重建。
# 输入：battlefield 上下文节点（需实现 _rebuild_inventory_items_impl）。
# 副作用：刷新库存面板可见条目。
func rebuild_inventory_items(ctx: Node) -> void:
	if ctx == null:
		return
	ctx.call("_rebuild_inventory_items_impl")
