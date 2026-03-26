# scenes/ui

本目录承接可编辑的 UI 子场景。

目标：

1. 所有可视 UI 结构优先定义在 `tscn`
2. 脚本只做 `setup(view_model)`、`refresh(view_model)`、`bind(actions)` 一类绑定职责
3. 后续库存卡片、商店卡片、槽位行、tooltip、详情面板等都应逐步迁入这里
4. 如果存在列表复用或池化，复用的也必须是 `PackedScene` 子场景实例，而不是脚本硬拼裸控件树

禁止放入：

1. 业务规则
2. 应用编排
3. 直接访问 `CombatManager` / `UnitAugmentManager` 的 UI 业务脚本
4. 只有脚本没有对应 `tscn` 结构的“假场景化”实现

当前阶段说明：

1. 本目录在 Phase 1 仍是冻结落点，尚未开始 UI 全量场景化迁移。
2. 这不构成当前阻塞，但后续新增生产可见 UI 不得继续绕开本目录。
