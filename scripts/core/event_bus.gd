extends Node

# ===========================
# 全局事件总线（AutoLoad）
# ===========================
# 设计目的：
# 1. 将系统间通信统一为信号，避免脚本之间硬耦合直接调用。
# 2. 核心管理器（GameManager/DataManager/ModLoader/ObjectPool）只关心事件，不关心彼此实现细节。
# 3. 后续扩展（UI、战斗、AI）时，只需订阅相关信号即可接入流程。

# 游戏阶段变化：由 GameManager 在阶段切换时发出。
signal phase_changed(previous_phase: int, next_phase: int)

# 场景切换请求与切换完成：
# - scene_change_requested：任何系统都可请求切场景
# - scene_changed：真正切换完成后回传结果
signal scene_change_requested(scene_path: String)
signal scene_changed(previous_scene: String, next_scene: String)

# 数据加载相关：用于主场景/调试面板刷新显示。
signal data_reloaded(is_full_reload: bool, summary: Dictionary)

# Mod 加载相关：每个 Mod 成功加载时发单条，全部结束后发汇总。
signal mod_loaded(mod_id: String, mod_name: String, load_order: int)
signal mod_load_completed(summary: Dictionary)

# 对象池相关：便于调试池状态与实例生命周期。
signal object_pool_registered(pool_key: String)
signal object_pool_acquired(pool_key: String, instance_id: int)
signal object_pool_released(pool_key: String, instance_id: int)


func emit_phase_changed(previous_phase: int, next_phase: int) -> void:
	phase_changed.emit(previous_phase, next_phase)


func emit_scene_change_requested(scene_path: String) -> void:
	scene_change_requested.emit(scene_path)


func emit_scene_changed(previous_scene: String, next_scene: String) -> void:
	scene_changed.emit(previous_scene, next_scene)


func emit_data_reloaded(is_full_reload: bool, summary: Dictionary) -> void:
	data_reloaded.emit(is_full_reload, summary)


func emit_mod_loaded(mod_id: String, mod_name: String, load_order: int) -> void:
	mod_loaded.emit(mod_id, mod_name, load_order)


func emit_mod_load_completed(summary: Dictionary) -> void:
	mod_load_completed.emit(summary)


func emit_object_pool_registered(pool_key: String) -> void:
	object_pool_registered.emit(pool_key)


func emit_object_pool_acquired(pool_key: String, instance_id: int) -> void:
	object_pool_acquired.emit(pool_key, instance_id)


func emit_object_pool_released(pool_key: String, instance_id: int) -> void:
	object_pool_released.emit(pool_key, instance_id)
