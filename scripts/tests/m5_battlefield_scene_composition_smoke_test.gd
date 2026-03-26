extends SceneTree

const BATTLEFIELD_SCENE: PackedScene = preload("res://scenes/battle/battlefield_scene.tscn")
const NEW_ROOT_SCRIPT_PATH: String = "res://scripts/app/battlefield/battlefield_scene.gd"

var _failed: int = 0


func _init() -> void:
	await _run()


func _run() -> void:
	var unit_augment_manager := Node.new()
	unit_augment_manager.name = "UnitAugmentManager"
	root.add_child(unit_augment_manager)

	var battlefield: Node = BATTLEFIELD_SCENE.instantiate()
	root.add_child(battlefield)
	await process_frame
	await process_frame

	_assert_true(battlefield != null, "battlefield_scene should instantiate")
	_assert_true(
		str((battlefield.get_script() as Script).resource_path) == NEW_ROOT_SCRIPT_PATH,
		"battlefield_scene root should use the new composition script"
	)
	_assert_true(battlefield.get_node_or_null("BattlefieldSceneRefs") != null, "BattlefieldSceneRefs node exists")
	_assert_true(battlefield.get_node_or_null("BattlefieldCoordinator") != null, "BattlefieldCoordinator node exists")
	_assert_true(
		battlefield.get_node_or_null("BattlefieldWorldController") != null,
		"BattlefieldWorldController node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("BattlefieldHudPresenter") != null,
		"BattlefieldHudPresenter node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeEconomyManager") != null,
		"RuntimeEconomyManager node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeShopManager") != null,
		"RuntimeShopManager node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeStageManager") != null,
		"RuntimeStageManager node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeUnitDeployManager") != null,
		"RuntimeUnitDeployManager node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeDragController") != null,
		"RuntimeDragController node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeBattlefieldRenderer") != null,
		"RuntimeBattlefieldRenderer node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("DetailLayer/BattleStatsPanel") != null,
		"BattleStatsPanel node exists"
	)
	_assert_true(
		battlefield.get_scene_refs() != null and battlefield.get_scene_refs().has_required_scene_nodes(),
		"scene refs should capture required scene nodes"
	)
	_assert_true(
		battlefield.get_scene_refs() != null and battlefield.get_scene_refs().has_required_runtime_nodes(),
		"scene refs should capture required runtime nodes"
	)
	_assert_true(
		battlefield.get_session_state() != null and battlefield.get_session_state().scene_ready,
		"session state should be created and marked ready"
	)
	_assert_true(battlefield.is_batch1_ready(), "battlefield_scene should report Batch 1 ready")
	_assert_true(
		battlefield.get_world_controller() != null and battlefield.get_world_controller().is_batch2_ready(),
		"BattlefieldWorldController should finish Batch 2 world initialization"
	)
	_assert_true(
		battlefield.get_scene_refs() != null and battlefield.get_scene_refs().bench_ui != null,
		"scene refs should expose bench_ui for world interaction"
	)
	_assert_true(
		battlefield.get_session_state() != null
		and int(battlefield.get_session_state().stage) == 0
		and bool(battlefield.get_session_state().bottom_expanded),
		"session state should enter preparation stage with expanded bottom panel"
	)
	_assert_true(
		battlefield.is_batch2_world_ready(),
		"battlefield_scene should report Batch 2 world ready"
	)

	battlefield.queue_free()
	unit_augment_manager.queue_free()
	await process_frame

	if _failed > 0:
		push_error("Battlefield scene composition smoke test failed: %d" % _failed)
		quit(1)
		return

	print("Battlefield scene composition smoke test passed.")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error(message)
