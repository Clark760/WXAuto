extends PanelContainer
class_name InventoryDragPreviewView

# 物品拖拽预览子场景视图
# 说明：
# 1. 只负责显示一个简化标题，不承接库存卡片业务逻辑。
# 2. BattleInventoryItemCard 通过实例化这个子场景生成拖拽预览，避免代码硬拼预览控件。

var _title_label: Label = null


# 统一写入预览标题，拖拽源只传入已格式化文本。
func setup_preview(title: String) -> void:
	_bind_nodes()
	if _title_label != null:
		_title_label.text = title


# 固定节点路径只在这里维护。
func _bind_nodes() -> void:
	if _title_label == null:
		_title_label = get_node_or_null("TitleLabel") as Label
