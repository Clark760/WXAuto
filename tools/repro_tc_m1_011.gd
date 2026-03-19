extends SceneTree

# TC-M1-011 场景重入复现脚本
# 用法：godot --headless --path . --script res://tools/repro_tc_m1_011.gd

func _initialize() -> void:
	print("[TC-M1-011] start")
	await create_timer(0.25).timeout

	var game_manager: Node = root.get_node_or_null("GameManager")
	if game_manager == null:
		push_error("[TC-M1-011] GameManager 未找到，无法执行重入链路")
		quit(1)
		return

	# 模拟用户链路：主场景 F2 -> M1，M1 F3 -> 主场景，再次 F2 -> M1。
	var ok1: bool = bool(game_manager.call("change_scene", "res://scenes/battle/battlefield_m1.tscn"))
	print("[TC-M1-011] main -> m1: ", ok1)
	await create_timer(0.25).timeout

	var ok2: bool = bool(game_manager.call("change_scene", "res://scenes/main/main.tscn"))
	print("[TC-M1-011] m1 -> main: ", ok2)
	await create_timer(0.25).timeout

	var ok3: bool = bool(game_manager.call("change_scene", "res://scenes/battle/battlefield_m1.tscn"))
	print("[TC-M1-011] main -> m1 (2nd): ", ok3)
	await create_timer(0.25).timeout

	print("[TC-M1-011] done")
	quit()
