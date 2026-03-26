# Phase 2 落地方案：战场主场景组合编排

> 状态：**Phase 2 唯一执行细则**
>
> 适用范围：战场主场景组合化、战场入口切换、旧战场链路删除、Phase 2 到期豁免清零
>
> 文档关系：
> 1. `doc/项目代码重构方案.md` 负责给出总体蓝图与阶段边界。
> 2. **本文件负责 Phase 2 的具体执行、验收与禁止项。**
> 3. 如本文件与 `doc/项目代码重构方案.md` 的 Phase 2 细节描述冲突，**以本文件为准**。
> 4. Phase 2 实施过程中若需调整接口、批次、验收口径，必须先更新本文件，再继续改代码。

---

## 1. 目标与成功标准

Phase 2 的目标固定为三件事，不允许在执行过程中漂移：

1. 切断 `battlefield.gd -> battlefield_ui.gd -> battlefield_runtime.gd` 继承链。
2. 把战场入口切到 `res://scenes/battle/battlefield_scene.tscn`。
3. 清空全部 `expires_phase=phase2` 的架构豁免。

Phase 2 完成时，必须同时满足：

1. 战场根场景只负责装配、引用收集、初始化顺序与只读 getter。
2. 世界交互、HUD 投影、局内编排三条职责线可以从文件结构和场景树中静态定位。
3. 生产代码和测试代码只认 `battlefield_scene.tscn`，旧入口 `battlefield.tscn` 删除。
4. `scripts/board/battlefield.gd`、`scripts/battle/battlefield_runtime.gd`、`scripts/combat/battle_flow.gd`、`scripts/board/terrain_manager.gd` 不再作为生产主路径。
5. `tools/check.ps1`、`tools/architecture_guard.ps1`、leak guard 可直接执行，且不依赖 `phase2` 到期例外。

---

## 2. 范围与冻结项

### 2.1 本阶段必须完成

1. 新建 Phase 2 组合骨架：
   - `BattlefieldScene`
   - `BattlefieldSceneRefs`
   - `BattlefieldSessionState`
   - `BattlefieldCoordinator`
   - `BattlefieldWorldController`
   - `BattlefieldHudPresenter`
2. 新建战场入口场景 `res://scenes/battle/battlefield_scene.tscn`。
3. 把现有运行时动态创建节点改为场景内显式子节点。
4. 迁移旧战场链路中的世界交互、HUD 展示、局内编排职责。
5. 切换所有生产入口、事件跳转和测试到新场景。
6. 删除旧战场链路与 Phase 2 到期豁免。

### 2.2 本阶段明确不做

1. 不做 Phase 3 的 UI 全量 scene-first 迁移。
2. 不改 JSON schema、Mod 组织、autoload 名称。
3. 不改 `CombatManager` 与 `UnitAugmentManager` 的对外玩法语义。
4. 不保留长期双入口，也不保留长期兼容别名。

### 2.3 本阶段禁止项

1. 不允许继续在 `battlefield.gd`、`battlefield_ui.gd`、`battlefield_runtime.gd` 中承接新职责。
2. 不允许用“先复制旧壳到 `scripts/app/` 再说”的方式伪装完成组合化。
3. 不允许继续使用 `configure(host)`、`ctx.call(...)`、`_owner.call(...)` 作为新接口风格。
4. 不允许保留 `battlefield.tscn` 作为长期兼容入口。
5. 不允许为了赶阶段，把 `expires_phase=phase2` 的例外顺延到 Phase 3。

---

## 3. 核心结构与职责

### 3.1 `BattlefieldScene`

定位：战场入口根脚本，只做装配。

唯一允许职责：

1. 收集场景引用。
2. 创建并持有 `BattlefieldSessionState`。
3. 按固定顺序初始化协作者。
4. 暴露只读 getter 给测试和过渡层。

明确禁止：

1. 不承载拖拽部署、镜头缩放、hover、单位点击。
2. 不承载商店刷新、关卡推进、奖励发放、开战/结算编排。
3. 不承载 HUD、详情、背包、tooltip、日志刷新逻辑。

### 3.2 `BattlefieldSceneRefs`

定位：统一维护显式依赖。

引用范围固定包含：

1. `WorldContainer`
2. `HexGrid`
3. `DeployZoneOverlay`
4. `UnitLayer`
5. `VfxFactory`
6. `UnitFactory`
7. `CombatManager`
8. `UnitAugmentManager`
9. 所有 `CanvasLayer`
10. `RuntimeEconomyManager`
11. `RuntimeShopManager`
12. `RuntimeStageManager`
13. `RuntimeUnitDeployManager`
14. `RuntimeDragController`
15. `RuntimeBattlefieldRenderer`
16. 结果统计面板相关节点

规则：

1. 其他对象只通过 `refs` 拿节点，不再四处写节点路径。
2. 新增依赖必须先补到 `BattlefieldSceneRefs`，再给协作者注入。

### 3.3 `BattlefieldSessionState`

定位：集中承接场景级可变状态。

状态范围固定包含：

1. 阶段与回合索引
2. 已部署友军/敌军映射
3. 拖拽态
4. 镜头缩放与偏移态
5. tooltip / 详情 / 商店 / 背包 / 回收区显隐态
6. 当前关卡配置与部署区配置
7. 商店当前页签
8. 持有库存与已装备视图态
9. 战斗统计面板视图态

规则：

1. 组合对象不得继续把这些状态散回根脚本私有字段。
2. 新增场景级状态必须先放入 `BattlefieldSessionState`。

### 3.4 `BattlefieldCoordinator`

定位：局内编排唯一入口。

职责固定为：

1. 战斗开始与结束编排
2. `UnitAugmentManager.prepare_battle` 与 `CombatManager.start_battle` 装配
3. 关卡推进与关卡结果处理
4. 商店刷新与奖励发放流程
5. 场景重开
6. 数据 reload 响应
7. 运行时服务初始化顺序

不负责：

1. 拖拽部署与视角交互
2. 详情面板、tooltip、商店面板绘制
3. 直接操作 UI 节点布局

### 3.5 `BattlefieldWorldController`

定位：世界交互唯一入口。

职责固定为：

1. 拖拽部署
2. 镜头缩放与平移
3. 棋盘自适应与世界视图刷新
4. hover 与战场单位点击
5. 准备期世界输入优先级

不负责：

1. 商店、奖励、关卡编排
2. HUD 数据投影
3. 结果统计面板控制

### 3.6 `BattlefieldHudPresenter`

定位：HUD 与局内面板唯一投影入口。

职责固定为：

1. 顶栏 HUD
2. 战斗日志
3. 详情面板
4. 背包面板
5. 商店面板
6. tooltip
7. 回收区
8. 结果统计面板

规则：

1. 只做数据投影、节点绑定、事件转发。
2. 不直接驱动战斗或关卡流程。

---

## 4. 协作者与接口约束

### 4.1 保留的世界协作者

以下文件保留，但必须改成显式注入 `refs + state`：

1. `scripts/battle/unit_deploy_manager.gd`
2. `scripts/battle/drag_controller.gd`
3. `scripts/battle/battlefield_renderer.gd`

接口约束：

1. 不再允许 `configure(host)`。
2. 不再允许 `ctx.call(...)`。
3. 不再允许 `_owner.call(...)`。
4. 只能通过显式字段、显式参数和返回值交互。

### 4.2 必须删除的过渡壳

以下文件不得在 Phase 2 结束后继续保留为生产主路径：

1. `scripts/board/shop_controller.gd`
2. `scripts/board/stage_bridge.gd`
3. `scripts/board/inventory_controller.gd`
4. `scripts/board/recycle_controller.gd`
5. `scripts/combat/battle_flow.gd`

职责归属：

1. 商店、关卡、奖励、开战/结算编排并入 `BattlefieldCoordinator`
2. 详情、背包、商店、tooltip、日志、统计面板并入 `BattlefieldHudPresenter`

### 4.3 运行时节点显式化

以下节点必须作为 `battlefield_scene.tscn` 显式子节点存在：

1. `RuntimeEconomyManager`
2. `RuntimeShopManager`
3. `RuntimeStageManager`
4. `RuntimeUnitDeployManager`
5. `RuntimeDragController`
6. `RuntimeBattlefieldRenderer`
7. 战斗统计面板节点

规则：

1. 禁止继续在 `_ready()` 或 `_bootstrap_*()` 中用 `.new() + add_child()` 偷偷创建这些节点。
2. 新增 runtime 节点也必须优先进入场景树，而不是继续走动态装配。

---

## 5. 实施批次

### Batch 0：修复门禁执行链

目标：

1. 修复 `tools/check.ps1`
2. 修复 `tools/architecture_guard.ps1`
3. 恢复 `check.ps1`、`architecture_guard.ps1 -ReportOnly`、leak guard 三条验收路径

退出条件：

1. 三条门禁路径在本地仓库可直接执行
2. `tools/baselines/architecture_guard_exceptions.json` 中 stale 例外与真实未完成项完成复核

当前审计结果（2026-03-26）：

1. 已确认并移除 3 条 stale `module_split_guard` 例外：
   - `scripts/battle/battlefield_runtime.gd`
   - `scripts/combat/combat_manager.gd`
   - `scripts/board/terrain_manager.gd`
2. 仍保留、且应在后续批次继续清零的 `phase2` 例外包括：
   - `scripts/battle/battlefield_runtime.gd` 的 `readability_guard`
   - `scripts/combat/combat_manager.gd` 的 `readability_guard`
   - `scripts/board/battlefield.gd` 的 `readability_guard`
   - `scripts/board/battlefield.gd` 的 `module_split_guard`
   - `scripts/unit/unit_base.gd` 的 `readability_guard`
   - `scripts/board/terrain_manager.gd` 的 `file_length`
   - `scripts/board/terrain_manager.gd` 的 `readability_guard`
   - `scripts/combat/battle_flow.gd` 的 `readability_guard`

### Batch 1：建立新入口与组合骨架

目标：

1. 新建 `doc/phase2_战场主场景组合编排落地方案.md`
2. 新建 `battlefield_scene / battlefield_scene_refs / battlefield_session_state / battlefield_coordinator / battlefield_world_controller / battlefield_hud_presenter`
3. 新建 `res://scenes/battle/battlefield_scene.tscn`

退出条件：

1. 新入口场景可以实例化
2. 根脚本不再继承旧战场链路
3. runtime 节点已经显式进入场景树

当前执行结果（2026-03-27）：

1. 已新增 6 个组合骨架脚本：
   - `scripts/app/battlefield/battlefield_scene.gd`
   - `scripts/app/battlefield/battlefield_scene_refs.gd`
   - `scripts/app/battlefield/battlefield_session_state.gd`
   - `scripts/app/battlefield/battlefield_coordinator.gd`
   - `scripts/app/battlefield/battlefield_world_controller.gd`
   - `scripts/app/battlefield/battlefield_hud_presenter.gd`
2. 已新增新入口场景 `res://scenes/battle/battlefield_scene.tscn`，根脚本改为 `battlefield_scene.gd`，不再继承旧战场链路。
3. 已将以下节点显式挂入新场景树：
   - `BattlefieldSceneRefs`
   - `BattlefieldCoordinator`
   - `BattlefieldWorldController`
   - `BattlefieldHudPresenter`
   - `RuntimeEconomyManager`
   - `RuntimeShopManager`
   - `RuntimeStageManager`
   - `RuntimeUnitDeployManager`
   - `RuntimeDragController`
   - `RuntimeBattlefieldRenderer`
   - `DetailLayer/BattleStatsPanel`
4. 已新增结构烟测 `scripts/tests/m5_battlefield_scene_composition_smoke_test.gd`，覆盖新入口实例化、组合骨架存在性、显式 runtime 节点存在性。
5. 已验证：
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\architecture_guard.ps1 -ReportOnly`
   - `E:\Godot_v4.6.1\godot.exe --headless --path . --script scripts/tests/m5_battlefield_scene_composition_smoke_test.gd`
6. 当前结论：Batch 1 只完成“新入口 + 组合骨架 + 显式 runtime 节点 + 结构烟测”，尚未开始世界交互与 HUD/编排逻辑迁移；这些工作严格留给 Batch 2/3。

### Batch 2：迁移世界交互

目标：

1. 把拖拽、部署、视角、hover、点击、棋盘自适应迁到 `BattlefieldWorldController`
2. world 协作者切到显式注入接口

退出条件：

1. 根场景只做输入转发，不保留世界逻辑
2. 世界交互相关逻辑不再依赖旧继承层

当前执行结果（2026-03-26）：

1. 已将新入口根场景的 `_input / _unhandled_input / _process / _draw` 转发给 `BattlefieldWorldController`，根场景不再自行保存世界交互状态。
2. 已扩充 `BattlefieldSessionState`，承接拖拽态、拖拽来源、世界视角、hover 瞬态、底栏展开态、战斗计时等 Batch 2 所需世界状态。
3. 已扩充 `BattlefieldSceneRefs`，显式收口 `BenchArea`、`BottomPanel`、`ToggleButton`、`DragPreview`、`DebugLabel` 等世界交互直接依赖节点。
4. 已将 `scripts/battle/unit_deploy_manager.gd`、`scripts/battle/drag_controller.gd`、`scripts/battle/battlefield_renderer.gd` 切到 `initialize(refs, state, delegate)` 显式注入接口。
5. 旧 `battlefield_runtime.gd` 的 runtime 协作者装配也已同步改到新接口，不再使用 `configure(host)`。
6. `BattlefieldWorldController` 已接管：
   - 准备期拖拽起手与释放
   - 棋盘部署判定与落位转发
   - 世界缩放、平移、键盘视角移动
   - hover 命中、世界点击命中、底栏展开与棋盘自适应
   - 世界调试文案的最小刷新
7. 结构烟测仍通过：
   - `E:\Godot_v4.6.1\godot.exe --headless --path . --script scripts/tests/m5_battlefield_scene_composition_smoke_test.gd`
8. `tools/architecture_guard.ps1` 已补齐可读性扫描的 UTF-8 显式读取；此前 `readability_guard` 误判 `chinese_comment_ratio` 的根因已消除。
9. 已验证：
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\architecture_guard.ps1 -ReportOnly`
   - `E:\Godot_v4.6.1\godot.exe --headless --path . --script scripts/tests/m5_battlefield_scene_composition_smoke_test.gd`
10. 当前门禁状态：
   - `readability_guard` 对 Batch 2 新增/修改文件已清零
   - `module_split_guard` 仅保留 review 提示，不构成 Batch 2 阻塞
11. 当前结论：
   - Batch 2 的“世界交互迁移主体”已完成，并已通过当前门禁与结构烟测
   - 后续可按施工单进入 Batch 3

### Batch 3：迁移 HUD 与局内编排

目标：

1. `BattlefieldHudPresenter` 接管商店、背包、详情、tooltip、日志、回收区、统计面板
2. `BattlefieldCoordinator` 接管 `_bootstrap_battle_services`、关卡推进、奖励发放、开战/结算、reload 编排
3. 删除 `battle_flow.gd`

退出条件：

1. 根场景不再承接 HUD 和局内编排职责
2. `battle_flow.gd` 从生产主路径删除
3. Batch 3 相关文件的可读性门禁主要由函数入口、关键状态同步点、复杂分支和节点绑定分组说明满足，不允许靠文件尾大段附录过线

### Batch 4：切换入口引用

目标：

1. 所有生产入口切到 `battlefield_scene.tscn`
2. 所有测试入口切到 `battlefield_scene.tscn`

必须切换的引用范围：

1. `main_scene.gd`
2. 所有 `emit_scene_change_requested(...)`
3. `scripts/tests/m5_battle_replay_check.gd`

退出条件：

1. 全仓搜索不再出现生产/测试对 `battlefield.tscn` 的引用
2. 删除旧入口 `scenes/battle/battlefield.tscn`

### Batch 5：删除旧战场链路

目标：

1. 删除 `scripts/board/battlefield.gd`
2. 删除 `scripts/battle/battlefield_runtime.gd`
3. 不保留长期兼容壳

退出条件：

1. 旧链路不再作为生产路径存在
2. Phase 3 不再接手这些旧壳

### Batch 6：清零全部 `phase2` 到期豁免

目标：

1. `terrain_manager.gd` 迁出 `board` 命名空间并归入 combat 侧
2. `combat_manager.gd` 按新结构重新过门禁
3. `unit_base.gd` 完成纯可读性治理
4. 删除全部 `expires_phase=phase2` 条目

退出条件：

1. `tools/baselines/architecture_guard_exceptions.json` 中不再有 `phase2` 到期例外
2. 不再依赖 `scripts/board/terrain_manager.gd` 作为生产主路径

---

## 6. 测试与验收

### 6.1 必须新增或更新的测试

1. 新增战场组合烟测：
   - 实例化 `battlefield_scene.tscn`
   - 断言根场景不继承旧链
   - 断言 `BattlefieldCoordinator`
   - 断言 `BattlefieldWorldController`
   - 断言 `BattlefieldHudPresenter`
   - 断言 `BattlefieldSceneRefs`
   - 断言显式 runtime 节点存在
2. 更新 `scripts/tests/m5_battle_replay_check.gd`
3. 保留并补强输入冲突回归
4. 增加结果阶段回归

### 6.2 回放测试口径

`m5_battle_replay_check.gd` 更新后必须满足：

1. 切到 `battlefield_scene.tscn`
2. 不再调用根场景私有 `_collect_units_from_map`
3. 不再调用根场景私有 `_deploy_ally_unit_to_cell`
4. 统一通过 scene getter + controller/state API 布阵与开战

### 6.3 输入冲突回归范围

以下冲突必须有回归覆盖：

1. 商店面板 vs 战场点击
2. 背包面板 vs 战场点击
3. tooltip vs hover
4. 回收区 vs 拖拽部署
5. 备战区滚轮 vs 世界缩放
6. ESC 关闭详情/商店链

### 6.4 结果阶段回归范围

1. 统计面板只在结果阶段展示
2. 离开结果阶段后单位恢复 idle
3. 重开战场后不残留上一局统计状态

### 6.5 结构验收固定项

Phase 2 最终验收固定包含三组结构检查：

1. 全仓 `rg` 清零旧入口 `battlefield.tscn` 引用
2. `scripts/board/battlefield.gd`、`scripts/battle/battlefield_runtime.gd`、`scripts/combat/battle_flow.gd`、`scripts/board/terrain_manager.gd` 不再作为生产主路径
3. `tools/check.ps1` 默认通过且不依赖 `phase2` 到期例外

---

## 7. 文档治理与防偏离规则

为了保证执行过程不背离，本阶段追加以下文档治理约束：

1. **本文件是 Phase 2 唯一施工单。**
2. `doc/项目代码重构方案.md` 只保留 Phase 2 摘要与跳转说明，不再承载施工细节。
3. 如实现过程中发现接口、批次、验收需要调整，必须先改本文件，再改代码。
4. 新增实现如果无法对应到本文件的职责归属、批次或验收项，视为偏离方案，必须先回到文档补齐。
5. 任何“临时兼容”“先这样跑通再说”的决定，都必须写入本文件的批次与退出条件，不能口头约定。

### 7.1 Batch 3 可读性收口补充约束

1. `20%` 中文注释和 `8%` 空行在 Phase 2 中的目标，是让战场组合化后的方法、状态和节点装配对人类读者可读，而不是让门禁数字过线。
2. Batch 3 及后续批次中，战场相关文件的注释率必须主要来自以下位置：
   - 函数入口职责说明
   - 关键状态字段或状态同步点说明
   - 复杂分支判定依据
   - 节点绑定与运行时装配的分组说明
3. 禁止通过文件尾大段 `附录`、`边界附录`、`职责附录` 一类注释块，重复宣告“只负责/不负责”来充当主要注释来源。
4. 允许保留简短模块定位说明，但命名注释块必须保持短小，只能辅助定位，不能替代贴近实现的函数级注释。
5. 空行必须服务于函数分隔、逻辑分段和阅读节奏，不允许集中补在文件尾或无关区域凑占比。
6. 如果某段注释删掉后，读者对当前函数、当前变量或当前分支的理解没有任何损失，这段注释不应计入 Phase 2 可读性治理目标。

---

## 8. 当前默认假设

1. Phase 1 已通过验收，允许进入 Phase 2。
2. 入口策略锁定为“切新入口”，不保留长期双入口。
3. `terrain_manager.gd` 的目标归属是 combat 侧，而不是继续留在 `board/`。
4. 如果 Batch 0 证明门禁问题来自仓库脚本而不是环境，则必须在仓库内修复；不接受口头豁免。
