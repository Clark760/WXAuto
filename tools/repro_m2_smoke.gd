extends SceneTree

func _initialize() -> void:
	print("[M2-SMOKE] start")
	await create_timer(0.3).timeout

	var game_manager: Node = root.get_node_or_null("GameManager")
	if game_manager == null:
		push_error("[M2-SMOKE] GameManager not found")
		quit(1)
		return

	var ok: bool = bool(game_manager.call("change_scene", "res://scenes/battle/battlefield_m2.tscn"))
	print("[M2-SMOKE] change_scene:", ok)
	if not ok:
		quit(1)
		return

	await create_timer(0.6).timeout
	var scene: Node = current_scene
	if scene == null:
		push_error("[M2-SMOKE] current_scene null")
		quit(1)
		return

	scene.call("_start_combat")
	print("[M2-SMOKE] start_combat called")

	await create_timer(2.0).timeout
	var cm: Node = scene.get_node_or_null("CombatManager")
	if cm != null:
		print("[M2-SMOKE] ally_alive=", int(cm.call("get_alive_count", 1)), " enemy_alive=", int(cm.call("get_alive_count", 2)))

	print("[M2-SMOKE] done")
	quit()
