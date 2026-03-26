# mods/test

这里存放测试专用 Mod。

规则：

1. 当回归测试缺少最小必需数据时，优先在这里补测试 Mod。
2. 测试 Mod 只保留最小数据集，不把临时测试数据塞回 `mods/base/`。
3. 测试脚本应显式说明自己依赖的 `mods/test` 数据路径。
4. `test_mod_m5_replay` 为 `scripts/tests/m5_battle_replay_check.gd` 提供最小 `units/gongfa/equipment` 数据。
