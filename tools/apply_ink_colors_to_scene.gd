# tools/apply_ink_colors_to_scene.gd
# 使用方式：在 Godot 编辑器中通过 File → Run Script 执行
@tool
extends EditorScript

const COLOR_MAP: Dictionary = {
	# 背景
	"Background": Color(0.96, 0.93, 0.88, 1.0),
	# 格子
	"HexGrid/fill_color": Color(0.36, 0.32, 0.27, 0.08),
	"HexGrid/line_color": Color(0.36, 0.32, 0.27, 0.25),
	# 遮罩
	"UnitDetailMask": Color(0.17, 0.14, 0.09, 0.40),
	# 肖像
	"PortraitColor": Color(0.84, 0.81, 0.76, 0.70),
}

const SELF_MODULATE_REMOVE: Array[String] = [
	"TopBar",
	"BattleLogPanel",
	"ShopPanel",
	"UnitDetailPanel",
	"InventoryPanel",
	"BottomPanel",
	"UnitTooltip",
	"ItemTooltip",
	"TerrainTooltip",
]

const FONT_COLOR_MAP: Dictionary = {
	# 标题级
	"PhaseLabel": Color(0.17, 0.14, 0.09, 1.0),
	"LogTitle": Color(0.17, 0.14, 0.09, 1.0),
	"ShopTitle": Color(0.17, 0.14, 0.09, 1.0),
	"DetailTitle": Color(0.17, 0.14, 0.09, 1.0),
	"PhaseText": Color(0.17, 0.14, 0.09, 1.0),
	# 正文级
	"RoundLabel": Color(0.24, 0.20, 0.16, 1.0),
	# 次要级
	"TimerLabel": Color(0.36, 0.32, 0.27, 1.0),
	"ShopStatus": Color(0.36, 0.32, 0.27, 1.0),
}

func _run() -> void:
	var scene_root: Node = get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		push_error("No scene is open.")
		return

	# 删除 self_modulate
	for node_path in SELF_MODULATE_REMOVE:
		var node: Node = _find_node_recursive(scene_root, node_path)
		if node != null and node is CanvasItem:
			(node as CanvasItem).self_modulate = Color(1, 1, 1, 1)

	# 设置颜色
	for node_path in COLOR_MAP.keys():
		if "/" in node_path:
			var parts: PackedStringArray = node_path.split("/")
			var node: Node = _find_node_recursive(scene_root, parts[0])
			if node != null:
				node.set(parts[1], COLOR_MAP[node_path])
		else:
			var node: Node = _find_node_recursive(scene_root, node_path)
			if node != null and node is ColorRect:
				(node as ColorRect).color = COLOR_MAP[node_path]

	# 设置字体颜色
	for node_path in FONT_COLOR_MAP.keys():
		var node: Node = _find_node_recursive(scene_root, node_path)
		if node != null and node is Label:
			(node as Label).add_theme_color_override("font_color", FONT_COLOR_MAP[node_path])

	print("Ink color pass complete.")


func _find_node_recursive(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found: Node = _find_node_recursive(child, target_name)
		if found != null:
			return found
	return null
