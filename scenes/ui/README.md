# scenes/ui

本目录承接可编辑的 UI 子场景。

目标：

1. 所有可视 UI 结构优先定义在 `tscn`
2. 脚本只做 `setup(view_model)`、`refresh(view_model)`、`bind(actions)` 一类绑定职责
3. 后续库存卡片、商店卡片、槽位行、tooltip、详情面板等都应逐步迁入这里
