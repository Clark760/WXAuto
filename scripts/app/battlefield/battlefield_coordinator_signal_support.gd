extends RefCounted

# 只负责把运行时节点信号接到 coordinator。
# 这里不承接业务逻辑，所有回调仍然回到 coordinator 自身处理。

var _owner: Object = null
var _scene_root: Node = null
var _refs = null
var _statistics_support = null


# 绑定 coordinator、场景入口和统计支撑，后续只负责接线不承接业务。
func initialize(owner: Object, scene_root: Node, refs, statistics_support) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_statistics_support = statistics_support


# 一次性收口所有运行时信号，避免 coordinator 自身混入大段接线样板。
func connect_all(event_bus: Node) -> void:
	if _owner == null or _refs == null:
		return
	_connect_viewport_signal()
	_connect_if_present(_refs.runtime_economy_manager, "assets_changed", "_on_assets_changed")
	_connect_if_present(_refs.runtime_economy_manager, "shop_lock_changed", "_on_shop_locked_changed")
	_connect_if_present(_refs.runtime_shop_manager, "shop_refreshed", "_on_shop_snapshot_refreshed")
	_connect_if_present(_refs.runtime_stage_manager, "stage_loaded", "_on_stage_loaded")
	_connect_if_present(_refs.runtime_stage_manager, "stage_combat_started", "_on_stage_combat_started")
	_connect_if_present(_refs.runtime_stage_manager, "stage_completed", "_on_stage_completed")
	_connect_if_present(_refs.runtime_stage_manager, "stage_failed", "_on_stage_failed")
	_connect_if_present(_refs.runtime_stage_manager, "all_stages_cleared", "_on_all_stages_cleared")
	_connect_if_present(_refs.combat_manager, "damage_resolved", "_on_damage_resolved")
	_connect_if_present(_refs.combat_manager, "unit_died", "_on_unit_died")
	_connect_if_present(_refs.combat_manager, "battle_ended", "_on_battle_ended")
	_connect_battle_statistics_signal()
	_connect_if_present(_refs.unit_augment_manager, "skill_effect_damage", "_on_skill_effect_damage")
	_connect_if_present(_refs.unit_augment_manager, "skill_effect_heal", "_on_skill_effect_heal")
	_connect_if_present(
		_refs.unit_augment_manager,
		"unit_augment_data_reloaded",
		"_on_unit_augment_data_reloaded"
	)
	_connect_if_present(_refs.recycle_drop_zone, "sell_requested", "_on_recycle_sell_requested")
	_connect_if_present(_refs.battle_stats_panel, "panel_closed", "_on_battle_stats_panel_closed")
	_connect_if_present(event_bus, "data_reloaded", "_on_data_reloaded")


# 视口尺寸变化只在这里接一次，供回收区和统计面板共用重排入口。
func _connect_viewport_signal() -> void:
	if _scene_root == null:
		return
	var viewport: Viewport = _scene_root.get_viewport()
	if viewport == null:
		return
	var callback: Callable = Callable(_owner, "_on_viewport_size_changed")
	if not viewport.is_connected("size_changed", callback):
		viewport.connect("size_changed", callback)


# 战斗统计节点是运行时创建的，需要单独通过 statistics support 取实例后接线。
func _connect_battle_statistics_signal() -> void:
	if _statistics_support == null:
		return
	var battle_statistics: Node = _statistics_support.get_battle_statistics()
	_connect_if_present(battle_statistics, "battle_stat_updated", "_on_battle_stat_updated")


# 统一处理 has_signal / is_connected 判定，避免每类节点都重复样板代码。
func _connect_if_present(target: Object, signal_name: String, method_name: String) -> void:
	if target == null or _owner == null:
		return
	if not target.has_signal(signal_name):
		return
	var callback: Callable = Callable(_owner, method_name)
	if not target.is_connected(signal_name, callback):
		target.connect(signal_name, callback)
