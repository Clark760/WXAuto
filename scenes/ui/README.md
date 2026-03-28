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

1. Phase 3 Batch 1 已建立第一批子场景骨架（卡片、槽位行、tooltip 行、回收区、统计面板）。
2. 当前这些子场景仍是占位实现，后续 Batch 2/3/4 会逐步替换现有动态拼 UI 逻辑。
3. 新增生产可见 UI 不得绕开本目录，且必须遵守 `setup/refresh/bind` 契约。
