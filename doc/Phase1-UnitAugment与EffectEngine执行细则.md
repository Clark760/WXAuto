# Phase 1 迭代 1 执行细则：UnitAugment 命名收敛与 EffectEngine 真正解耦

> 本文档是 Phase 1 迭代 1 的唯一实施依据。后续涉及 `gongfa` 伞形子系统重命名、`effect_engine` 解耦、测试迁移与门禁验收的代码改动，必须以本文档为准，不允许边做边改口径。

> Phase 1 剩余内容的当前执行依据见：
> [Phase1-UnitAugment与Combat剩余实施细则](./Phase1-UnitAugment与Combat剩余实施细则.md)
>
> 说明：
> 1. 本文档继续保留，用于约束“命名收敛 + EffectEngine 真拆分”的起点和边界。
> 2. `UnitAugmentManager` 真 facade 化、`CombatManager` 真拆分、测试与门禁总收口，统一按新文档执行。

> 本文档解决两个历史偏差：
> 1. 伞形系统仍沿用早期 `gongfa` 命名，已经不能准确描述“功法 + 装备 + 特性 + Buff + 触发/效果执行”的真实职责。
> 2. `effect_engine.gd` 曾通过删注释、删空行、合并多语句的方式被压到阈值内，而不是完成真正的模块拆分。

---

## 1. 目标与锁定决策

### 1.1 本迭代目标

本迭代只做一个最小闭环，但要求闭环完整：

1. 把系统级 `gongfa` 命名硬切为 `UnitAugment`。
2. 把 `effect_engine` 从“实现体”改造成“facade + dispatcher + typed services”。
3. 把 `gongfa_manager` 同步降为真正 facade，避免继续依赖旧 1000+ 行 God Object。
4. 保持玩法、JSON、Mod schema、实际条目语义不变。

### 1.2 已锁定决策

1. 新伞形系统名固定为 `UnitAugment`。
2. 本轮只改**代码层命名**，不改 JSON / Mod / 数据字段里的 `gongfa` 语义。
3. 采用**硬切**，不保留 `GongfaManager` / `GongfaEffectEngine` 兼容别名。
4. Facade 不允许继续承担实现体；如果某个文件仍保留大段 `op` 分支、查询 helper、状态机 helper，则视为拆分失败。

### 1.3 不变项

以下语义本轮必须保持不变：

1. `gongfa_id`
2. `gongfa_slots`
3. `runtime_equipped_gongfa_ids`
4. `equip_gongfa()` / `unequip_gongfa()`
5. `get_gongfa_data()` / `get_all_gongfa()`
6. 配表分类 `gongfa`
7. 真实条目级 `source_type = "gongfa"`

---

## 2. 命名与接口收敛规则

### 2.1 必须重命名的系统级标识

| 旧标识 | 新标识 | 说明 |
|---|---|---|
| `GongfaManager` | `UnitAugmentManager` | AutoLoad 与伞形系统入口 |
| `GongfaEffectEngine` | `UnitAugmentEffectEngine` | 效果总入口 facade |
| `GongfaRegistry` | `UnitAugmentRegistry` | 数据聚合注册器 |
| `GongfaBuffManager` | `UnitAugmentBuffManager` | Buff 生命周期与光环跟踪 |
| `scripts/gongfa/` | `scripts/unit_augment/` | 伞形系统代码目录 |
| `scripts/domain/gongfa/effects/` | `scripts/domain/unit_augment/effects/` | effect 领域目录 |
| `gongfa_manager` | `unit_augment_manager` | context key / 局部变量 / 注入名 |
| `gongfa_data_reloaded` | `unit_augment_data_reloaded` | 系统级 reload 事件 |

### 2.2 必须保留的条目级接口

以下接口虽然带 `gongfa`，但表示“功法条目”而不是“伞形系统”，因此本轮不改名：

1. `equip_gongfa()`
2. `unequip_gongfa()`
3. `get_gongfa_data()`
4. `get_all_gongfa()`
5. `gongfa_id`
6. `equipped_gongfa_ids`
7. `runtime_equipped_gongfa_ids`

### 2.3 信号命名规则

1. 继续保留：
   - `skill_triggered`
   - `skill_effect_damage`
   - `skill_effect_heal`
   - `buff_event`
2. 必须改名：
   - `gongfa_data_reloaded` -> `unit_augment_data_reloaded`
3. 任何新信号如果表达的是“系统级重载/系统级协调”，一律使用 `unit_augment_*` 前缀。

---

## 3. 目标文件边界

### 3.1 `UnitAugmentManager` 边界

新文件：`scripts/unit_augment/unit_augment_manager.gd`

职责只允许包含：

1. AutoLoad 生命周期
2. 对外公开 API
3. 信号定义
4. 运行时依赖装配
5. 子服务协调

不得包含：

1. 长段属性重算实现
2. 长段触发轮询实现
3. 长段 tag 注册表维护实现
4. 长段 tag linkage 调度实现
5. 长段 effect 执行细节

必须同时拆出的子服务：

1. `unit_augment_unit_state_service.gd`
   - 单位状态缓存
   - baseline stats 构建
   - 功法 / 装备 / 特性来源聚合
   - 重算与回写入口
2. `unit_augment_battle_runtime.gd`
   - `_process` 驱动
   - buff tick 请求回放
   - prepare / bind / battle lifecycle
3. `unit_augment_tag_registry_service.gd`
   - tag -> index 注册表
   - version 维护
   - reload 后同步
4. `unit_augment_trigger_runtime.gd`
   - trigger 上下文装配
   - 触发执行入口
   - 战斗事件监听桥接

### 3.2 `UnitAugmentEffectEngine` 边界

新文件：`scripts/unit_augment/unit_augment_effect_engine.gd`

职责只允许包含：

1. `create_empty_modifier_bundle()`
2. `apply_passive_effects(...)`
3. `execute_active_effects(...)`
4. 服务实例装配
5. 少量兼容性说明注释

不得包含：

1. `_execute_*_op`
2. `_collect_*`
3. `_find_*`
4. `_apply_*`
5. `match op`
6. 标签联动状态机细节
7. 目标查询、位移、召唤、地形、Buff 生命周期 helper

### 3.3 Effect 领域服务边界

目录：`scripts/domain/unit_augment/effects/`

必须落成以下文件：

1. `passive_effect_applier.gd`
   - 仅负责被动 modifier 叠加
2. `active_effect_dispatcher.gd`
   - 仅负责 `op -> handler` 路由
   - 不写任何具体 op 实现
3. `effect_summary_collector.gd`
   - 统一维护 summary 初始化与 event 归档
4. `target_query_service.gd`
   - 目标收集、邻近查询、位置与距离
5. `hex_spatial_service.gd`
   - 格子邻居、半径格、落点和距离
6. `damage_resource_ops.gd`
   - damage / heal / mp / shield / immunity
7. `buff_control_ops.gd`
   - buff / debuff / cleanse / dispel / steal / mark / source_bound_aura
8. `movement_control_ops.gd`
   - teleport / dash / knockback / pull / swap / taunt / control state
9. `summon_terrain_ops.gd`
   - summon / clone / revive / create_terrain / hazard
10. `tag_linkage_ops.gd`
   - tag gate / branch / stateful branch / linkage child effects

### 3.4 Runtime Gateway 边界

新文件：`scripts/unit_augment/unit_augment_effect_runtime_gateway.gd`

职责：

1. 承接领域服务对 `Node` / `CombatManager` / `BuffManager` / `Battlefield` / `VfxFactory` 的调用
2. 统一处理对现有运行时对象的兼容性交互
3. 允许保留必要的 `call()`，但只允许出现在 gateway 这类兼容边界内

禁止事项：

1. 不允许把业务判断重新堆回 gateway
2. 不允许把 `summary` 汇总逻辑写回 gateway
3. 不允许让 gateway 自己做 `match op`

---

## 4. 实施批次与顺序

### Batch 0：文档与约束先行

必须完成：

1. 新增本文档。
2. 在 [项目代码重构方案](./项目代码重构方案.md) 的 Phase 1 章节增加本文档入口。
3. 在 [架构约束执行细则](./架构约束执行细则.md) 中继续强调：
   - 不允许通过压缩排版过线
   - Facade 不得承载实现体

Batch 0 完成标志：

1. 任何后续提交都可以引用本文档中的“边界”和“验收条件”。

### Batch 1：命名骨架硬切

必须完成：

1. 新建 `scripts/unit_augment/` 与 `scripts/domain/unit_augment/effects/`。
2. `project.godot` autoload 改为 `UnitAugmentManager`。
3. 生产代码中 `GongfaManager`、`gongfa_manager`、`res://scripts/gongfa/`、`res://scripts/domain/gongfa/` 改为新命名。
4. `gongfa_data_reloaded` 改为 `unit_augment_data_reloaded`，并同步所有连接点。

禁止事项：

1. 不允许保留 `GongfaManager` 兼容 alias。
2. 不允许同时存在两套生产调用名。

Batch 1 完成标志：

1. 生产代码检索不到旧系统级命名引用。

### Batch 2：EffectEngine 真正拆分

必须完成：

1. 建立 `UnitAugmentEffectEngine` facade。
2. 建立 `UnitAugmentEffectRuntimeGateway`。
3. 把旧 `effect_engine.gd` 中所有 helper 迁移到 gateway 或领域服务。
4. 把旧 `ActiveEffectDispatcher` 中的 `match op` 逻辑拆入分组 ops。
5. 废弃 `EffectOpHandlers` 的混合角色，拆成 `effect_summary_collector + ops`。

禁止事项：

1. 不允许把旧 helper 原样挪到新的 facade。
2. 不允许 dispatcher 继续承担具体 op 实现。
3. 不允许出现“单个新文件 400+ 行但仍然职责混杂”的伪拆分。

Batch 2 完成标志：

1. `UnitAugmentEffectEngine` 不再包含业务 helper。
2. dispatcher 仅做路由。
3. effect 相关模块命名和职责一一对应。

### Batch 3：Manager facade 化

必须完成：

1. 建立 `UnitAugmentManager` facade。
2. 把旧 `gongfa_manager.gd` 中的状态、轮询、tag、trigger 逻辑迁入子服务。
3. `passive_applier` 改为直接 typed 调用 effect engine，不再通过 `call()` 驱动内部模块。
4. facade 内部对子服务改为显式方法调用。

禁止事项：

1. 不允许把旧 1000+ 行 manager 直接改名后原地保留。
2. 不允许新增 `call()` 作为内部模块通信方式。

Batch 3 完成标志：

1. `UnitAugmentManager` 成为小文件 facade。
2. 旧 manager 的主体职责已迁出。

### Batch 4：测试与门禁收口

必须完成：

1. 更新所有 preload 路径、mock 类名、autoload 查找名、signal 断言、context key。
2. 更新 `m5_expansion_coverage_check.gd` 的扫描策略，改为扫描新的分布式 effect 目录。
3. 通过 `architecture_guard`、`check.ps1` 与关键回归测试。

Batch 4 完成标志：

1. 新命名、拆分结构和测试口径一致。

---

## 5. 验收清单

### 5.1 结构验收

1. `scripts/unit_augment/unit_augment_effect_engine.gd` 是 facade，不含 helper 实现。
2. `scripts/unit_augment/unit_augment_manager.gd` 是 facade，不含长段业务实现。
3. `scripts/domain/unit_augment/effects/` 中各文件职责单一、命名直观。
4. 生产代码不再依赖 `scripts/gongfa/*` 作为主路径。

### 5.2 行数与可读性验收

1. `UnitAugmentEffectEngine` 目标 `<= 300` 行。
2. `UnitAugmentManager` 目标 `<= 600` 行。
3. 新增或改动文件必须满足 [GDScript可读性与编码规范](./GDScript可读性与编码规范.md)。
4. 禁止出现“为了过线而删除中文注释、空行、换行”的痕迹。

### 5.3 回归测试

必须覆盖：

1. `scripts/tests/m5_effect_engine_smoke_test.gd`
2. `scripts/tests/m5_effect_engine_facade_contract_test.gd`
3. `scripts/tests/m5_source_bound_aura_test.gd`
4. `scripts/tests/m5_tag_linkage_effect_test.gd`
5. `scripts/tests/m5_tag_linkage_scheduler_test.gd`
6. `scripts/tests/m5_trigger_pipeline_regression_test.gd`
7. `scripts/tests/m5_terrain_effect_rework_test.gd`
8. `scripts/tests/m5_battle_replay_check.gd`

### 5.4 契约验收

以下行为必须保持不变：

1. `execute_active_effects()` 的 `summary` 字段集合不变。
2. `damage/heal/mp/buff/debuff/summon/hazard` 的累计口径不变。
3. `source_bound_aura` 的 provider 死亡清理与条件丢失清理不回归。
4. `tag_linkage_branch` 的普通模式和 stateful 模式不回归。
5. 商店、战场 UI、战斗 runtime 仍能通过 `UnitAugmentManager` 读取功法/装备数据并执行现有行为。

---

## 6. 偏离防控规则

出现以下任一情况，视为偏离本文档，必须停止继续叠代码并先修正结构：

1. 新 facade 中重新出现 `_execute_*_op`、`_collect_*`、`_find_*` 一类实现体。
2. dispatcher 再次膨胀成 `match op` 巨型分发器。
3. 内部模块通信重新退化为普遍 `call()`。
4. 新旧命名混用，代码里同时存在 `GongfaManager` 与 `UnitAugmentManager`。
5. 通过压缩排版而不是迁移职责来满足行数门禁。

如果实现中遇到无法当轮消化的耦合点，允许做的唯一折中方式是：

1. 把兼容性交互留在 `UnitAugmentEffectRuntimeGateway` 或 facade 外围。
2. 继续保持领域服务纯强类型接口。
3. 绝不把新耦合重新写回 facade 本体。
