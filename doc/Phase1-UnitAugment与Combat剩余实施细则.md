# Phase 1 剩余实施细则：UnitAugment 收口与 Combat 真拆分

> 本文档是 Phase 1 剩余工作的唯一实施依据。后续涉及 `UnitAugmentManager` 硬切收口、`CombatManager` facade 化、测试门禁收敛的代码改动，必须以本文档为准，不允许继续沿用旧的 `GongfaManager` / `effect_engine.gd` 时代口径。

> 与既有文档的关系：
> 1. [Phase1-UnitAugment与EffectEngine执行细则](./Phase1-UnitAugment与EffectEngine执行细则.md) 负责约束“命名收敛 + EffectEngine 真正解耦”的第一轮闭环。
> 2. 本文档负责 Phase 1 的剩余内容：系统级硬切命名、`UnitAugmentManager` 真 facade 化、`CombatManager` 真拆分、测试与门禁统一收口。

---

## 1. 目标与锁定决策

### 1.1 本轮目标

本轮必须一次性完成以下三件事：

1. 把系统级 `gongfa` 入口彻底收口到 `UnitAugment` 命名。
2. 把 `gongfa_manager.gd` 的主体职责迁出，落成真正的 `UnitAugmentManager` facade。
3. 把 `combat_manager.gd` 从 God Object 降为 facade + 显式协作服务。

### 1.2 已锁定决策

1. 采用**硬切**，不保留 `GongfaManager` 兼容 alias。
2. Phase 1 剩余内容按“`UnitAugment` + `Combat` 并进”执行，不允许只拆一侧、另一侧继续扩写。
3. `UnitAugmentEffectEngine` 已是唯一正确的效果总入口，本轮不再引入第三个 effect facade 名称。
4. 条目级 `gongfa` 语义保留，系统级命名统一改为 `UnitAugment`。
5. 不改 JSON / Mod schema，不改玩法结果，不改条目级 API 名称。

### 1.3 必须保持不变的条目级语义

以下条目级接口和字段本轮不改名：

1. `equip_gongfa()` / `unequip_gongfa()`
2. `get_gongfa_data()` / `get_all_gongfa()`
3. `gongfa_id`
4. `equipped_gongfa_ids`
5. `runtime_equipped_gongfa_ids`
6. 配表分类 `gongfa`
7. `source_type = "gongfa"`

### 1.4 当前仓库施工基线（2026-03-26）

以下基线用于约束本轮实际施工顺序，避免继续“按感觉拆分”：

1. `UnitAugmentEffectEngine` 已经完成生产入口收口，旧 `scripts/gongfa/effect_engine.gd` 与 `scripts/domain/gongfa/effects/**` 不再作为有效实现目录。
2. `project.godot` 的 autoload 已切到 `UnitAugmentManager`，但生产代码内部仍残留大量 `gongfa_manager` 变量名、上下文键和注释口径。
3. `unit_augment_manager.gd` 已经基本降为 facade，`combat_manager.gd` 也已拆出 runtime / registry / movement / attack / terrain / event bridge 六类服务，但这并不等于 Phase 1 已完成。
4. `scripts/unit_augment/` 中仍有三条关键兼容桥没有切干净：
   - `unit_augment_buff_manager.gd` 仍依赖旧 `scripts/gongfa/buff_manager.gd`
   - `unit_augment_tag_linkage_resolver.gd` 仍依赖旧 `scripts/gongfa/tag_linkage_resolver.gd`
   - `unit_augment_tag_linkage_scheduler.gd` 仍依赖旧 `scripts/gongfa/tag_linkage_runtime_scheduler.gd`
5. `m5_expansion_coverage_check.gd` 当前仍可能通过排除 `scripts/gongfa/` 目录来掩盖旧主路径残留，因此门禁口径还没有和目标结构完全对齐。
6. `tools/baselines/architecture_guard_exceptions.json` 中仍残留旧 `scripts/gongfa/*` 例外和已过期的 `phase1_batch4` 例外；只要这些条目还在，Phase 1 就不能算真正封板。

### 1.5 本轮直接执行顺序

为了避免实现偏离，Phase 1 剩余内容必须按以下顺序推进，不允许跳批次：

1. 先完成本文档的执行层补充与锁定。
2. 先做 Batch 2A：生产侧系统级命名硬切。
3. 再做 Batch 2B：`UnitAugmentManager` facade 继续瘦身，清理动态调用与兼容桥残留。
4. 再做 Batch 2C：`UnitAugment` 侧测试、coverage、泄漏门禁与可读性门禁收口。
5. 之后才允许进入 Batch 3：`CombatManager` 真拆分。
6. `Combat` 子服务拆分完成后，执行 Batch 4：测试和门禁总收口。
7. 最后必须执行 Batch 5：旧 `scripts/gongfa/*` 运行时主路径硬删除与 Phase 1 封板。
8. 只有 Batch 5 通过后，才允许进入 Phase 2。

---

## 2. 命名与入口收口规则

### 2.1 必须完成的系统级硬切

1. `project.godot` autoload 必须从 `GongfaManager` 改为 `UnitAugmentManager`。
2. 生产代码中的 `GongfaManager`、`gongfa_manager`、`gongfa_data_reloaded` 必须统一改为：
   - `UnitAugmentManager`
   - `unit_augment_manager`
   - `unit_augment_data_reloaded`
3. 生产代码中不允许继续引用：
   - `res://scripts/gongfa/**`
   - `res://scripts/domain/gongfa/**`
4. `scripts/gongfa/` 不再承载任何生产运行时实现；Phase 1 结束时，旧目录中的 manager、Buff、trigger、tag linkage 旧实现必须全部删除，而不是继续作为 `scripts/unit_augment/*` 的 delegate 来源。

### 2.2 必须保留的对外行为

1. 商店、战场 UI、战斗 runtime 继续通过统一 manager 读取功法/装备/Buff 相关数据。
2. `skill_triggered`、`skill_effect_damage`、`skill_effect_heal`、`buff_event` 四个信号继续保留。
3. 只有系统级重载信号改名为 `unit_augment_data_reloaded`。

### 2.3 禁止事项

1. 不允许同时存在 `GongfaManager` 与 `UnitAugmentManager` 两套生产入口名。
2. 不允许在新代码里继续向 `context` 同时写入 `gongfa_manager` 与 `unit_augment_manager`。
3. 不允许为了“兼容旧测试”保留旧 autoload 查找名；测试应随系统级命名一起迁移。

---

## 3. 目标文件边界

### 3.1 `UnitAugmentManager` 边界

目标文件：`scripts/unit_augment/unit_augment_manager.gd`

职责只允许包含：

1. AutoLoad 生命周期
2. 对外公开 API
3. 信号定义
4. 运行时依赖装配
5. 子服务协调与少量参数归一化

不得包含：

1. 长段属性重算实现
2. 长段触发轮询实现
3. 长段 tag 注册表维护实现
4. 长段 tag linkage 调度实现
5. 长段 battle event 监听桥接
6. 长段 effect 执行细节

必须同时落成以下子服务：

1. `unit_augment_registry.gd`
   - 接管数据重载、功法/Buff/装备映射与查询副本
2. `unit_augment_buff_manager.gd`
   - 接管 Buff 生命周期、源绑定光环、tick 请求生成
   - 必须成为真实实现体，不允许继续 preload 旧 `scripts/gongfa/buff_manager.gd`
3. `unit_augment_unit_state_service.gd`
   - 接管 baseline stats 构建、来源聚合、modifier 应用、运行时状态回写
4. `unit_augment_battle_runtime.gd`
   - 接管 `_process`、`bind_combat_context(...)`、`prepare_battle(...)`、buff tick 请求回放、battle lifecycle
5. `unit_augment_trigger_runtime.gd`
   - 降为 trigger facade，只保留自动触发轮询、事件派发入口和上下文转发
6. `unit_augment_tag_registry_service.gd`
   - 接管 tag -> index 注册表、version、reload 后同步
7. `unit_augment_tag_linkage_resolver.gd`
   - 保留 resolver facade、上下文归一化和对子服务的装配
8. `unit_augment_tag_linkage_scheduler.gd`
   - 保留 watcher、dirty 标记、战斗事件驱动与节流调度
   - 继续留在 `scripts/unit_augment/`，不迁入 `scripts/domain/`

允许补充以下辅助子服务，以满足 facade 真正做薄的要求：

1. `unit_augment_combat_event_bridge.gd`
   - 接管 battle event 监听桥接、combat signal 连接和触发广播整理
2. `unit_augment_trigger_condition_service.gd`
   - 接管 trigger 冷却、次数、阈值、队伍人数与地形过滤判定
3. `unit_augment_trigger_execution_service.gd`
   - 接管目标选择、effect context 装配、tag linkage gate、MP 扣除与冷却推进

其中必须继续落定以下边界：

1. `tag_linkage` 的 provider 收集、query 编译、mask 计算和 case 匹配属于纯规则，应进入 `scripts/domain/unit_augment/` 下的新子目录，而不是继续塞在 runtime facade 或旧 `scripts/gongfa/*` 文件里。
2. `unit_augment_tag_linkage_resolver.gd` 只能保留 facade 和上下文桥接，不得长期维持“新壳包旧 resolver”的状态。
3. `unit_augment_tag_linkage_scheduler.gd` 因为直接依赖 combat signal、watcher 状态和 physics frame，仍属于 runtime / adapter，不得为了目录整洁硬迁到 `scripts/domain/`。

### 3.2 `UnitAugmentEffectEngine` 边界

目标文件：`scripts/unit_augment/unit_augment_effect_engine.gd`

职责只允许包含：

1. `create_empty_modifier_bundle()`
2. `apply_passive_effects(...)`
3. `execute_active_effects(...)`
4. 服务装配
5. 少量 facade 级兼容注释

不得包含：

1. `match op`
2. `_execute_*_op`
3. 目标查询 helper
4. Buff 生命周期 helper
5. 地形 / 召唤 / 位移 / 标签联动的实现体

### 3.3 `CombatManager` 边界

目标文件：`scripts/combat/combat_manager.gd`

职责只允许包含：

1. Godot signal 定义
2. 导出参数
3. 公共查询 API
4. 子服务装配
5. 少量 facade 级状态持有

不得包含：

1. `_logic_tick` 的长段调度体
2. `_run_unit_logic` 的长段移动/攻击混合体
3. 大段地形 tick 与 barrier 更新逻辑
4. 大段单位注册、缓存裁剪、组件信号绑定逻辑
5. 攻击结算与死亡收尾的完整实现体

必须同时落成以下子服务：

1. `combat_runtime_service.gd`
   - `_process`、`_logic_tick`、战斗开始/停止、阶段开关、battle summary
2. `combat_unit_registry.gd`
   - 单位注册/反注册、缓存预扫描、组件信号绑定、运行时缓存清理
3. `combat_movement_service.gd`
   - 强制移动、步进移动、恐惧移动、移动失败/成功事件桥接
4. `combat_attack_service.gd`
   - 选敌后的攻击尝试、攻击失败/伤害事件整理、死亡结算入口
5. `combat_terrain_service.gd`
   - 地形 registry、动态/静态地形、terrain tick、阻挡和可视刷新
6. `combat_event_bridge.gd`
   - combat component 信号回调、manager 级信号转发、外部战斗事件兼容

已有并保留的子模块：

1. `cell_occupancy.gd`
2. `combat_pathfinding.gd`
3. `combat_targeting.gd`
4. `combat_metrics.gd`

这些既有模块在本轮必须从“`owner.get/call` 读写 manager 内部状态”的松耦合模式，进一步收口到显式参数或显式依赖，不允许继续把 `CombatManager` 当动态属性容器。

### 3.4 `scripts/domain/` 归位判定

本轮新增一个强制判断：**能不能进入 `scripts/domain/`，看的是依赖性质，不是看名字像不像“服务”**。

允许进入 `scripts/domain/` 的条件：

1. 不直接操作场景树和节点生命周期
2. 不直接 connect / emit runtime signal
3. 不直接依赖 `SceneTree`、AutoLoad、HexGrid、VFXFactory、UI 节点
4. 输入输出可以改写为显式参数，而不是通过 facade 私有字段传递

不得进入 `scripts/domain/` 的情况：

1. 仍直接依赖 `CombatManager` 信号和缓存
2. 仍直接操作单位动画、位移组件、战场坐标或 VFX
3. 仍以 `owner.get(...)` / `owner.call(...)` 把 facade 当动态属性容器

Phase 1 中 `Combat` 的目录归位规则锁定为：

1. `combat_runtime_service.gd`
2. `combat_unit_registry.gd`
3. `combat_movement_service.gd`
4. `combat_attack_service.gd`
5. `combat_terrain_service.gd`
6. `combat_event_bridge.gd`

以上六个文件在 Phase 1 继续留在 `scripts/combat/`，因为它们属于 runtime / adapter 层，不是纯 domain。

未来可迁入 `scripts/domain/combat/` 的候选，只限于：

1. `cell_occupancy.gd`
2. `combat_pathfinding.gd`
3. `combat_targeting.gd`
4. `combat_metrics.gd`
5. `flow_field.gd`

但前提是先完成显式参数化和去 `owner.get/call`，不能只换目录。

`UnitAugment` 侧在本轮也锁定同样原则：

1. Buff 生命周期、光环实例状态、scheduler watcher 这类直接依赖 live `Node` 和运行时信号的模块，继续留在 `scripts/unit_augment/`。
2. tag linkage 的 provider 收集、query 编译、mask 匹配、case 判定这类纯规则模块，应优先落到 `scripts/domain/unit_augment/`。
3. 任何仍通过 preload 旧 `scripts/gongfa/*` 获取真实实现的包装层，都不算完成迁移。

---

## 4. 实施批次与顺序

### Batch 1：文档与命名骨架先对齐

必须完成：

1. 更新 [项目代码重构方案](./项目代码重构方案.md) 的 Phase 1 章节与验收口径。
2. 在主文档中明确：
   - `UnitAugment` 是系统级唯一名称
   - `UnitAugmentEffectEngine` 已是唯一 effect 入口
   - Phase 1 剩余内容的直接执行依据是本文档
3. 同步修正仍指导错误实现的旧措辞，例如：
   - “保留 `GongfaManager` facade”
   - “`effect_engine.gd` 降为 facade”
   - “拆出 gongfa 子服务”

Batch 1 完成标志：

1. Phase 1 相关文档之间不存在互相冲突的实现指引。

### Batch 2：`UnitAugment` 系统级硬切与 facade 化

必须完成：

1. `project.godot` autoload 改为 `UnitAugmentManager`。
2. 新建 `scripts/unit_augment/unit_augment_manager.gd` 并接管生产入口。
3. 旧 `gongfa_manager.gd` 的职责拆入本文件列出的子服务。
4. 生产代码中的 manager preload、autoload 查找名、signal 连接点、context key 全部切到 `UnitAugment`。
5. facade 内部对子服务全部改用显式 typed 方法，不允许继续通过 `call()` 驱动内部模块。

禁止事项：

1. 不允许把旧 `gongfa_manager.gd` 直接改名后继续原地保留 1000+ 行实现体。
2. 不允许为了过渡在生产代码里同时保留旧路径和新路径。
3. 不允许在 `UnitAugmentManager` facade 中重新长出 `_build_unit_baseline_stats`、`_poll_auto_triggers`、`_rebuild_tag_registry` 这类大段实现体。

Batch 2 完成标志：

1. `UnitAugmentManager` 成为小文件 facade。
2. 生产代码检索不到旧系统级 manager 命名和旧入口路径。

#### Batch 2A：生产侧系统级命名硬切

目标：先把“系统级入口名仍叫 `gongfa_manager`”的问题一次性切干净，避免后续 facade 拆分继续在旧口径上叠代码。

必须修改的文件面：

1. `scripts/battle/battlefield_runtime.gd`
2. `scripts/board/battlefield.gd`
3. `scripts/ui/battlefield_ui.gd`
4. `scripts/combat/battle_flow.gd`
5. `scripts/combat/combat_manager.gd`
6. `scripts/board/terrain_manager.gd`
7. `scripts/economy/shop_manager.gd`
8. 任何仍向生产上下文写入 `gongfa_manager` 的 `scripts/unit_augment/**` 文件

必须完成：

1. 生产变量、参数名、字段名统一改为 `unit_augment_manager`。
2. 生产上下文键统一从 `gongfa_manager` 改为 `unit_augment_manager`。
3. 生产信号连接点统一改用 `unit_augment_data_reloaded`。
4. 注释和维护说明中的系统级旧名称同步修正，避免后续实现继续被错误术语带偏。

禁止事项：

1. 不允许保留“变量仍叫 `gongfa_manager`，但内部其实取的是 `UnitAugmentManager`”这种伪迁移状态。
2. 不允许为兼容旧生产代码继续在新代码里同时写入两套上下文键。
3. 条目级接口如 `equip_gongfa()`、`gongfa_id` 不在本子批次改名，防止把系统级硬切和数据语义硬切绑死。

退出条件：

1. 生产代码检索不到 `gongfa_manager` 作为系统级变量或上下文键。
2. 生产代码检索不到 `gongfa_data_reloaded`。

#### Batch 2B：`UnitAugmentManager` facade 瘦身与强类型收口

目标：把当前已经长出来的 `UnitAugment` 子服务真正接上，避免 facade 和子服务双份持有实现。

重点文件面：

1. `scripts/unit_augment/unit_augment_manager.gd`
2. `scripts/unit_augment/unit_augment_battle_runtime.gd`
3. `scripts/unit_augment/unit_augment_combat_event_bridge.gd`
4. `scripts/unit_augment/unit_augment_trigger_runtime.gd`
5. `scripts/unit_augment/unit_augment_trigger_execution_service.gd`
6. `scripts/unit_augment/unit_augment_unit_state_service.gd`
7. `scripts/unit_augment/unit_augment_tag_registry_service.gd`
8. `scripts/unit_augment/unit_augment_tag_linkage_resolver.gd`

必须完成：

1. facade 只保留装配、信号、公开 API 和上下文归一化。
2. 新 `unit_augment` 子服务之间的通信改为显式 typed 方法，不继续扩散 `call()`。
3. 旧 resolver 的上下文兼容映射必须在清理旧生产调用点后逐步收口，不能长期保留为默认路径。
4. 每个函数和关键参数都要补足就地中文注释，禁止再用长段文件说明凑注释率。

禁止事项：

1. 不允许把旧 `gongfa_manager.gd` 的函数原样搬进 `unit_augment_manager.gd`。
2. 不允许继续通过“文件头一大段说明 + 函数体无注释”的方式规避可读性门禁。
3. 不允许为了暂时通过 guard 再把多行逻辑压成单行或删除结构空行。

退出条件：

1. `unit_augment_manager.gd` 行数明显下降并继续向 `<= 600` 收敛。
2. 新 `unit_augment` 文件不再新增 architecture guard 的 `dynamic_call` 违规。
3. 新 `unit_augment` 文件通过 readability guard。

#### Batch 2C：`UnitAugment` 测试与门禁收口

目标：在系统级命名和 facade 收口完成后，把测试、覆盖检查和泄漏门禁口径同步到同一套结构。

必须完成：

1. 更新相关测试中的 autoload 查找名、preload 路径、上下文键和断言注释。
2. 扩展 coverage / 结构检查，禁止旧 `scripts/gongfa/*` 系统级入口回流。
3. 把核心 `UnitAugment` 链路继续纳入 `leak_guard_tests.json`，保持“泄漏归零”为长期门禁。
4. 统一修正测试脚本中对旧 effect facade、旧 manager 命名的残留引用。
5. 测试所需数据若主 Mod 不具备，必须在 `mods/test/` 下创建测试专用 Mod；禁止继续把临时数据散落到失效路径、脚本内大段内联 JSON 或一次性假目录假设里。

退出条件：

1. `UnitAugment` 侧核心回归测试与 contract tests 全部通过。
2. 结构扫描与泄漏门禁都使用新口径，不再允许旧命名回流。
3. 新增测试数据来源可追溯到 `mods/test/`，不再依赖仓库外或历史失效路径。

### Batch 3：`CombatManager` 真拆分

必须完成：

1. 建立 `combat_runtime_service.gd`、`combat_unit_registry.gd`、`combat_movement_service.gd`、`combat_attack_service.gd`、`combat_terrain_service.gd`、`combat_event_bridge.gd`。
2. 把 `combat_manager.gd` 中的运行时 tick、单位注册、移动、攻击、地形、事件桥接职责迁出。
3. 保留 `CombatManager` 现有对外方法名和信号名，内部改为显式转发给子服务。
4. 既有 `cell_occupancy`、`pathfinding`、`targeting`、`metrics` 模块同步收口到显式参数风格，不再大量读取 facade 内部动态属性。

禁止事项：

1. 不允许继续向 `combat_manager.gd` 添加新的横切职责。
2. 不允许新 combat 子服务之间再普遍使用 `call()` 通信。
3. 不允许只把长函数拆成若干 helper 但仍留在同一 facade 文件中。

Batch 3 完成标志：

1. `combat_manager.gd` 降为 facade + 装配入口。
2. 移动、攻击、地形、事件桥接各自拥有明确文件边界。

#### Batch 3A：Runtime 与 Registry 先切

目标：先把最容易继续膨胀的战斗主循环和单位注册职责迁出，给后续移动、攻击、地形拆分腾出稳定接口。

重点文件面：

1. `scripts/combat/combat_manager.gd`
2. `scripts/combat/combat_runtime_service.gd`
3. `scripts/combat/combat_unit_registry.gd`
4. `scripts/combat/cell_occupancy.gd`
5. `scripts/combat/combat_metrics.gd`

必须完成：

1. `_process`、`_logic_tick`、战斗开始/停止、战报汇总优先迁入 `combat_runtime_service.gd`。
2. 单位注册、反注册、缓存裁剪、组件信号绑定优先迁入 `combat_unit_registry.gd`。
3. 既有辅助模块改为接收显式参数，不继续隐式读取 facade 内部状态。

退出条件：

1. `combat_manager.gd` 不再持有完整 `_logic_tick` 长段实现。
2. 单位注册主链路从 facade 移出。

#### Batch 3B：移动、攻击、地形与事件桥接拆分

目标：把战斗规则性最强的几段实现体移出 `combat_manager.gd`，完成真正意义上的 combat facade 化。

重点文件面：

1. `scripts/combat/combat_movement_service.gd`
2. `scripts/combat/combat_attack_service.gd`
3. `scripts/combat/combat_terrain_service.gd`
4. `scripts/combat/combat_event_bridge.gd`
5. `scripts/combat/combat_targeting.gd`
6. `scripts/board/terrain_manager.gd`

必须完成：

1. `_run_unit_logic` 中的移动 / 攻击混合体拆为显式服务调用。
2. `_tick_terrain` 与 barrier / terrain registry 更新迁入地形服务。
3. signal relay、外部战斗事件兼容和组件回调迁入 `combat_event_bridge.gd`。

退出条件：

1. `combat_manager.gd` 中不再存在移动、攻击、地形三大块长段实现。
2. `terrain_manager.gd` 与 `CombatManager` 的交互只通过新上下文和显式接口完成。

#### Batch 3C：Combat 子模块归位审计

目标：在 `CombatManager` facade 化之后，明确哪些实现属于 runtime / adapter，哪些实现未来应进入 `scripts/domain/combat/`，防止后续再次出现“目录名像 domain，实际仍是 runtime”的伪分层。

必须完成：

1. 在文档和目录说明中写清 `scripts/domain/` 的准入条件。
2. 对当前 `scripts/combat/` 子模块做一次归位审计，给出“留在 combat”与“未来可迁入 domain”的明确名单。
3. 不做仅改路径不改耦合的假迁移。

当前锁定结论：

1. 继续留在 `scripts/combat/`：
   - `combat_runtime_service.gd`
   - `combat_unit_registry.gd`
   - `combat_movement_service.gd`
   - `combat_attack_service.gd`
   - `combat_terrain_service.gd`
   - `combat_event_bridge.gd`
2. 未来迁入 `scripts/domain/combat/` 的候选：
   - `cell_occupancy.gd`
   - `combat_pathfinding.gd`
   - `combat_targeting.gd`
   - `combat_metrics.gd`
   - `flow_field.gd`

退出条件：

1. 文档对 `scripts/domain/` 的判定标准已统一。
2. 当前没有“应该立即搬目录但还没搬”的误判项。
3. 后续迁移目标已经被明确记录，而不是继续靠口头记忆。

#### Batch 4C：`app / infra / scenes/ui` 偏离防控

目标：在进入 Phase 2/3/4 之前，先把 `scripts/app/`、`scripts/infra/`、`scenes/ui/` 三个冻结目录的准入规则写清，避免后续继续在旧目录长歪。

必须完成：

1. 文档里明确这三个目录的准入/禁入边界。
2. 检查当前仓库是否已经出现“该进 `app` / `infra` / `scenes/ui` 却被悄悄写回旧目录”的新实现。
3. 对“暂时不迁移”的结论写明原因，避免以后误以为是遗漏。

当前锁定结论：

1. `scripts/app/` 当前仍是冻结落点，Phase 1 不强行提前承接 `BattlefieldCoordinator` 一类重组。
2. `scripts/infra/` 当前仍是冻结落点，Phase 1 不把未收口完成的旧兼容胶水提前塞入。
3. `scenes/ui/` 当前仍是冻结落点，Phase 1 不提前启动 UI 全量场景化，但后续新增生产可见 UI 不得继续绕开它。

退出条件：

1. 三个目录的边界说明已经固化到主文档、实施细则和目录 README。
2. 当前没有需要立即移动的 Phase 1 范围内文件。

### Batch 4：测试与门禁收口

必须完成：

1. 更新所有 preload 路径、mock 类名、autoload 查找名、signal 断言、context key。
2. 更新 `m5_expansion_coverage_check.gd` 的扫描策略，断言旧 effect/manager 路径和旧系统级命名不再回流。
3. 把重命名后的关键回归测试继续纳入 `leak_guard_tests.json`，保持“泄漏归零”长期门禁。
4. 通过 `architecture_guard`、`check.ps1` 与本文档列出的关键回归测试。

Batch 4 完成标志：

1. 新命名、拆分结构、测试口径和门禁配置完全一致。

#### Batch 4A：结构门禁收口

必须完成：

1. `architecture_guard` 与 `readability_guard` 的基线按新结构更新。
2. 新 guard 只接受真实拆分，不接受通过排版压缩获得的“假降行数”。
3. 对 `scripts/gongfa/*` 系统级入口、旧上下文键和旧 effect 路径补充覆盖断言。

#### Batch 4B：行为与泄漏门禁收口

必须完成：

1. 核心 `UnitAugment` 与 `Combat` 链路继续纳入 `leak_guard_tests.json`。
2. `check.ps1` 默认流程对结构门禁、行为回归和泄漏门禁给出统一出口码。
3. 所有新增或重写文件的中文注释分布必须满足“函数注释 + 关键参数注释”为主的规范。

#### Batch 5：旧 `scripts/gongfa/*` 运行时主路径硬删除与封板

目标：把“新入口名已经切了，但真实运行时还藏在旧目录里”的伪收口状态一次性结束，为 Phase 2 提供干净基线。

必须完成：

1. `unit_augment_buff_manager.gd` 不再 preload 或 delegate 到旧 `scripts/gongfa/buff_manager.gd`。
2. `unit_augment_tag_linkage_resolver.gd` 不再 preload 或 delegate 到旧 `scripts/gongfa/tag_linkage_resolver.gd`。
3. `unit_augment_tag_linkage_scheduler.gd` 不再 preload 或 delegate 到旧 `scripts/gongfa/tag_linkage_runtime_scheduler.gd`。
4. 旧 `scripts/gongfa/` 中仍承载运行时职责的文件全部删除，不保留“未引用但仍在仓库”的过渡残留。
5. `m5_expansion_coverage_check.gd` 不允许再通过排除 `scripts/gongfa/` 目录来声称“旧路径未回流”。
6. `tools/baselines/architecture_guard_exceptions.json` 中与 `scripts/gongfa/*` 和已过期 `phase1_batch4` 有关的条目全部清零或改到真实后续阶段。

禁止事项：

1. 不允许通过“保留 wrapper，但把旧 preload 藏在内部”伪装成已切到 `UnitAugment`。
2. 不允许把旧 `scripts/gongfa/*` 文件留在仓库里，同时在 coverage 中把该目录整体排除。
3. 不允许把本该删除的 Phase 1 例外，靠改 `expires_phase` 文案继续续命。

退出条件：

1. 仓库中不再存在 `scripts/gongfa/*` 运行时代码目录。
2. 生产代码和测试代码都检索不到 `res://scripts/gongfa/`、`gongfa_manager`、`gongfa_data_reloaded` 作为系统级路径或命名。
3. `architecture_guard_exceptions.json` 中不存在任何已过期的 `phase1_batch4` 条目。
4. 通过本文档列出的结构、回归和泄漏门禁后，Phase 1 才允许封板。

---

## 5. 验收清单

### 5.1 结构验收

1. `scripts/unit_augment/unit_augment_manager.gd` 是 facade，不含长段业务实现。
2. `scripts/unit_augment/unit_augment_effect_engine.gd` 继续保持 facade，不重新长出 helper。
3. `scripts/combat/combat_manager.gd` 是 facade，不再同时承担 tick、移动、攻击、地形、事件桥接五类实现体。
4. 生产代码不再依赖 `scripts/gongfa/*` 作为系统级主路径。
5. `scripts/unit_augment/*` 不再通过 preload、delegate 或包装层依赖旧 `scripts/gongfa/*` 作为真实实现来源。
6. `scripts/gongfa/` 运行时代码目录已删除，而不是仅变成“未引用残留”。

### 5.2 行数与可读性验收

1. `UnitAugmentManager` 目标 `<= 600` 行。
2. `CombatManager` 目标 `<= 900` 行。
3. 新增或重写文件必须满足 [GDScript可读性与编码规范](./GDScript可读性与编码规范.md)。
4. 禁止通过删除中文注释、删除空行、合并多语句的方式压到阈值以内。
5. 任何作为替代实现落地的新文件，都必须用函数级与关键参数级中文注释承担注释率，不能靠 wrapper 头注释过线。

### 5.3 回归测试

测试数据规则：

1. 回归测试默认优先复用生产 Mod 数据。
2. 如果测试缺失最小必需数据，必须在 `mods/test/` 下补测试专用 Mod，而不是把测试数据硬编码进脚本。
3. 测试专用 Mod 只承载测试场景最小数据集，不得反向污染 `mods/base/`。

`UnitAugment` 侧必须覆盖：

1. `scripts/tests/m5_effect_engine_smoke_test.gd`
2. `scripts/tests/m5_effect_engine_facade_contract_test.gd`
3. `scripts/tests/m5_source_bound_aura_test.gd`
4. `scripts/tests/m5_trigger_pipeline_regression_test.gd`
5. `scripts/tests/m5_tag_linkage_effect_test.gd`
6. `scripts/tests/m5_tag_linkage_scheduler_test.gd`
7. `scripts/tests/m5_equip_slot_refactor_test.gd`
8. `scripts/tests/m5_buff_source_bucket_test.gd`

`Combat` 主链路必须覆盖：

1. `scripts/tests/m5_battle_replay_check.gd`
2. `scripts/tests/m5_battle_statistics_regression_test.gd`
3. `scripts/tests/m5_combat_death_signal_regression_test.gd`
4. `scripts/tests/m5_result_victory_idle_regression_test.gd`
5. `scripts/tests/m5_terrain_effect_rework_test.gd`
6. `scripts/tests/m5_terrain_source_fallback_test.gd`
7. `scripts/tests/m5_trait_terrain_tag_support_test.gd`
8. `scripts/tests/m5_unique_unit_deploy_test.gd`

### 5.4 契约验收

以下行为必须保持不变：

1. `UnitAugmentEffectEngine.execute_active_effects()` 的 `summary` 字段集合不变。
2. `source_bound_aura` 的 provider 死亡清理和条件丢失清理不回归。
3. 商店、战场 UI、战斗 runtime 仍能通过 `UnitAugmentManager` 读取功法/装备数据并执行现有行为。
4. 战斗启动 / 停止、移动、攻击、地形 tick、死亡事件、战斗总结的行为不回归。
5. `m5_expansion_coverage_check.gd` 的旧路径回流断言不能依赖“扫描时排除旧目录”这种自屏蔽策略。

---

## 6. 偏离防控规则

出现以下任一情况，视为偏离本文档，必须停止继续叠代码并先修正结构：

1. 新代码重新引入 `GongfaManager` 作为系统级生产入口。
2. `UnitAugmentManager` facade 内再次堆入属性重算、触发轮询或标签联动的大段实现体。
3. `CombatManager` 只做表面 helper 拆分，但 `_logic_tick` / `_run_unit_logic` / `_tick_terrain` 仍保留为长段核心实现。
4. 新的子服务之间重新退化为普遍 `call()` 通信。
5. 为了压线继续牺牲中文注释、空行和结构分段。
6. 未完成 Batch 2 就提前开始大规模 `Combat` 真拆分。
7. 把必须写在函数和关键参数旁的中文注释，重新堆回文件头说明或“维护约束”段落凑比例。
8. 在宣布 Phase 1 完成前，仍保留 `scripts/gongfa/*` 作为真实运行时主路径或继续持有已过期例外。

如果实现中遇到无法当轮完全拆开的耦合点，允许的唯一折中方式是：

1. 把兼容性交互留在 facade 外围或 runtime gateway。
2. 保持新领域服务和新运行时服务使用显式 typed 方法。
3. 在同一轮中把残余耦合点记录到本文档的后续阶段补充，而不是偷偷继续塞回旧 God Object。
