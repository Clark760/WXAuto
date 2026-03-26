# scripts/domain

本目录承接领域层代码。

允许放入：

1. 战斗模拟
2. 功法、Buff、地形、经济、库存等领域服务
3. 与具体场景和具体 UI 无关的业务规则
4. 可以只靠显式参数和返回值表达的纯状态、纯规则、纯计算模块

禁止放入：

1. `Control`/`Node` 级 UI 编排
2. 场景装配逻辑
3. 通过 `_get_root_node(...)` 访问全局单例
4. 仍直接依赖 `SceneTree`、AutoLoad、HexGrid、VFX、动画播放、`add_child()` 的 runtime / adapter 文件
5. 仍把 facade 当动态属性袋，通过 `owner.get(...)` / `owner.call(...)` 读写私有运行时状态的“伪领域模块”

Combat 侧当前的归位规则：

1. 继续留在 `scripts/combat/` 的 runtime / adapter：
   - `combat_runtime_service.gd`
   - `combat_unit_registry.gd`
   - `combat_movement_service.gd`
   - `combat_attack_service.gd`
   - `combat_terrain_service.gd`
   - `combat_event_bridge.gd`
2. 未来可迁入 `scripts/domain/combat/` 的候选：
   - `cell_occupancy.gd`
   - `combat_pathfinding.gd`
   - `combat_targeting.gd`
   - `combat_metrics.gd`
   - `flow_field.gd`
3. 迁移顺序必须是：
   - 先去掉 runtime 依赖
   - 再改成显式参数
   - 最后才迁目录
