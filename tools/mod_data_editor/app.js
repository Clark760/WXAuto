"use strict";

const state = {
  mods: [],
  categories: [],
  files: [],
  selectedMod: "",
  selectedCategory: "",
  selectedFile: "",
  schema: null,
  document: null,
  rootIsArray: false,
  selectedIndex: 0,
  dirty: false,
  activeTab: "form",
  manifest: null,
  referenceCache: {
    trigger: [],
    effect_op: [],
  },
  effectParamCache: {},
  refPicker: {
    visible: false,
    kind: "",
    title: "",
    source: "remote",
    page: 1,
    pageSize: 30,
    total: 0,
    query: "",
    items: [],
    staticItems: [],
    onPick: null,
  },
};

const BUILTIN_TRIGGER_LABELS = {
  auto_mp_full: "触发·满内力",
  manual: "触发·手动施放",
  auto_hp_below: "触发·低血自动",
  on_hp_below: "触发·血线跌破",
  on_time_elapsed: "触发·达到时点",
  periodic_seconds: "触发·周期轮询",
  passive_aura: "触发·光环轮询",
  on_combat_start: "触发·战斗开始",
  on_attack_hit: "触发·攻击命中",
  on_attacked: "触发·受到攻击",
  on_kill: "触发·击杀",
  on_ally_death: "触发·友方死亡",
  on_crit: "触发·造成暴击",
  on_dodge: "触发·闪避成功",
  on_attack_fail: "触发·攻击失败",
  on_shield_broken: "触发·护盾破裂",
  on_unit_spawned_mid_battle: "触发·战中单位加入",
  on_damage_received: "触发·受到伤害",
  on_heal_received: "触发·受到治疗",
  on_thorns_triggered: "触发·反伤生效",
  on_unit_move_success: "触发·移动成功",
  on_unit_move_failed: "触发·移动失败",
  on_terrain_created: "触发·地形创建",
  on_terrain_enter: "触发·进入地形",
  on_terrain_tick: "触发·地形周期",
  on_terrain_exit: "触发·离开地形",
  on_terrain_expire: "触发·地形结束",
  on_team_alive_count_changed: "触发·存活数变化",
  on_debuff_applied: "触发·施加减益",
  on_buff_expired: "触发·Buff结束",
  on_preparation_started: "全局·备战开始",
  on_stage_combat_started: "全局·关卡开战",
  on_stage_completed: "全局·关卡胜利",
  on_stage_failed: "全局·关卡失败",
  on_stage_loaded: "全局·关卡加载完成",
  on_all_stages_cleared: "全局·序列通关",
};

const BUILTIN_EFFECT_OP_LABELS = {
  stat_add: "属性·固定增益",
  stat_percent: "属性·百分比增益",
  conditional_stat: "属性·条件增益",
  mp_regen_add: "资源·内力恢复",
  hp_regen_add: "资源·生命恢复",
  damage_reduce_flat: "防御·固定减伤",
  damage_reduce_percent: "防御·百分比减伤",
  dodge_bonus: "战斗·闪避增益",
  crit_bonus: "战斗·暴击增益",
  crit_damage_bonus: "战斗·暴伤增益",
  vampire: "战斗·吸血",
  damage_amp_percent: "伤害·增伤",
  damage_amp_vs_debuffed: "伤害·减益增伤",
  tenacity: "战斗·韧性",
  thorns_percent: "反制·百分比反伤",
  thorns_flat: "反制·固定反伤",
  shield_on_combat_start: "护盾·开场护盾",
  execute_threshold: "伤害·斩杀阈值",
  healing_amp: "治疗·治疗增幅",
  mp_on_kill: "资源·击杀回蓝",
  attack_speed_bonus: "战斗·攻速增益",
  range_add: "战斗·射程增益",
  damage_target: "伤害·单体",
  damage_aoe: "伤害·范围",
  damage_chain: "伤害·连锁",
  damage_cone: "伤害·扇形",
  damage_if_debuffed: "伤害·减益增伤",
  damage_if_marked: "伤害·标记增伤",
  damage_target_scaling: "伤害·倍率缩放",
  execute_target: "伤害·斩杀目标",
  aoe_percent_hp_damage: "伤害·百分比生命",
  heal_self: "治疗·自身",
  heal_self_percent: "治疗·自身百分比",
  heal_allies_aoe: "治疗·范围友方",
  heal_target_flat: "治疗·单体",
  heal_lowest_ally: "治疗·最低血友方",
  heal_percent_missing_hp: "治疗·按损失生命",
  drain_mp: "资源·抽蓝",
  shield_self: "护盾·自身",
  shield_allies_aoe: "护盾·范围友方",
  immunity_self: "免疫·自身",
  buff_self: "增益·自身",
  buff_target: "增益·目标",
  buff_allies_aoe: "增益·范围友方",
  debuff_target: "减益·目标",
  debuff_aoe: "减益·范围敌方",
  cleanse_self: "净化·自身",
  cleanse_ally: "净化·友方",
  steal_buff: "净化·偷取增益",
  dispel_target: "净化·驱散目标",
  mark_target: "标记·目标",
  pull_target: "位移·拉拽",
  knockback_aoe: "位移·范围击退",
  knockback_target: "位移·单体击退",
  swap_position: "位移·换位",
  silence_target: "控制·沉默",
  stun_target: "控制·眩晕",
  fear_aoe: "控制·范围恐惧",
  freeze_target: "控制·冻结",
  teleport_behind: "位移·闪现至背后",
  dash_forward: "位移·突进",
  taunt_aoe: "控制·范围嘲讽",
  create_terrain: "地形·创建",
  summon_units: "召唤·单位",
  hazard_zone: "地形·危险区域",
  spawn_vfx: "表现·特效",
  summon_clone: "召唤·分身",
  revive_random_ally: "复活·随机友军",
  resurrect_self: "复活·自身",
  tag_linkage_branch: "联动·Tag分支",
};

const TRIGGER_COMMON_PARAM_HINTS = {
  team_scope: "队伍范围：`ally` 我方 / `enemy` 敌方 / `all` 双方。",
  exclude_self: "是否排除施法者自身。",
  team_alive_count_min: "触发时要求队伍最少存活人数（含边界）。",
  team_alive_count_max: "触发时要求队伍最多存活人数（含边界）。",
};

const TRIGGER_PARAM_HINTS = {
  auto_mp_full: {},
  manual: {},
  auto_hp_below: {
    threshold: "生命阈值，低于该比例时可自动触发。",
  },
  on_hp_below: {
    threshold: "生命比例阈值，通常填 0~1，仅在“上->下”跌破时触发。",
  },
  on_time_elapsed: {
    at_seconds: "战斗进行到第几秒触发。",
  },
  periodic_seconds: {
    interval: "周期触发间隔（秒）。",
  },
  passive_aura: {},
  on_combat_start: {},
  on_attack_hit: {},
  on_attacked: {},
  on_kill: {},
  on_ally_death: {},
  on_crit: {},
  on_dodge: {},
  on_attack_fail: {
    reasons: "失败原因过滤数组，如 `cooldown` / `out_of_range` / `no_target`。",
  },
  on_shield_broken: {},
  on_unit_spawned_mid_battle: {},
  on_damage_received: {
    min_damage: "最小受伤值，低于该值不触发。",
  },
  on_heal_received: {
    min_heal: "最小治疗值，低于该值不触发。",
  },
  on_thorns_triggered: {
    min_reflect: "最小反伤值过滤。",
  },
  on_unit_move_success: {},
  on_unit_move_failed: {
    reasons: "失败原因过滤数组，如 `block` / `conflict` / `stunned`。",
  },
  on_terrain_created: {
    terrain_tags_any: "地形命中：任一标签命中即可。",
    terrain_tags_all: "地形命中：必须同时具备全部标签。",
  },
  on_terrain_enter: {
    terrain_tags_any: "地形命中：任一标签命中即可。",
    terrain_tags_all: "地形命中：必须同时具备全部标签。",
  },
  on_terrain_tick: {
    terrain_tags_any: "地形命中：任一标签命中即可。",
    terrain_tags_all: "地形命中：必须同时具备全部标签。",
  },
  on_terrain_exit: {
    terrain_tags_any: "地形命中：任一标签命中即可。",
    terrain_tags_all: "地形命中：必须同时具备全部标签。",
  },
  on_terrain_expire: {
    terrain_tags_any: "地形命中：任一标签命中即可。",
    terrain_tags_all: "地形命中：必须同时具备全部标签。",
  },
  on_team_alive_count_changed: {},
  on_debuff_applied: {
    debuff_id: "只监听指定 Debuff；留空表示任意 Debuff。",
  },
  on_buff_expired: {
    watch_buff_id: "监听移除的 Buff ID（推荐字段）。",
    buff_id: "兼容旧写法：监听移除的 Buff ID。",
  },
};

const EFFECT_COMMON_PARAM_HINTS = {
  stat: "属性键，例如 `hp` / `atk` / `def` / `mp`。",
  value: "效果数值主参数。",
  duration: "持续时间（秒）。",
  radius: "范围半径（格）。",
  range: "范围距离（格）。",
  damage_type: "伤害类型，如 `external` / `internal` / `true`。",
  buff_id: "Buff / Debuff 的配置ID。",
  shield_buff_id: "护盾关联的 Buff ID。",
  mark_id: "标记ID，用于标记联动。",
  count: "数量。",
  ratio: "比例值，通常填 0~1。",
  percent: "百分比值，通常填 0~1。",
  hp_ratio: "生命比例，通常填 0~1。",
  hp_percent: "生命百分比，通常填 0~1。",
  threshold: "阈值，通常填 0~1。",
  damage: "伤害值。",
  scale_stat: "倍率来源属性。",
  scale_ratio: "倍率系数。",
  scale_source: "倍率来源策略。",
  require_debuff: "要求目标携带的 Debuff ID。",
  bonus_multiplier: "额外增伤倍率。",
  exclude_self: "是否排除施法者自身。",
  jumps: "连锁跳数。",
  chain_count: "连锁次数。",
  decay: "连锁衰减比例。",
  angle: "扇形角度（度）。",
  angle_deg: "扇形角度（度）。",
  cells: "位移格数。",
  distance: "位移距离（格）。",
  distance_cells: "位移距离（格）。",
  vfx_id: "特效配置ID。",
  at: "特效挂点，如 `self` / `target` / `cell`。",
  unit_id: "单位ID。",
  unit_ids: "单位ID数组。",
  units: "召唤单位明细数组。",
  deploy: "召唤部署规则。",
  inherit_ratio: "继承属性比例。",
  terrain_ref_id: "引用地形模板ID。",
  terrain_id: "地形ID。",
  terrain_type: "地形类型。",
  tick_interval: "周期触发间隔（秒）。",
  effects_on_enter: "进入地形时触发的效果数组。",
  effects_on_tick: "地形周期触发效果数组。",
  effects_on_exit: "离开地形时触发效果数组。",
  effects_on_expire: "地形结束时触发效果数组。",
  tags: "标签数组。",
  debuff_ids: "可净化的 Debuff ID 数组。",
  buff_ids: "可驱散的 Buff ID 数组。",
  prefer_ids: "偷取增益时优先 Buff ID 数组。",
  execution_mode: "联动执行模式：`continuous` / `stateful`。",
  team_scope: "联动统计队伍范围：`ally` / `enemy` / `all`。",
  count_mode: "联动计数口径：`provider` / `unit` / `occurrence`。",
  query_type: "查询类型：`match_tags` / `forbid_tags`。",
  tag_match: "标签匹配方式：`any` / `all`。",
  tags_any: "任一标签命中数组。",
  tags_all: "全部标签命中数组。",
  exclude_tags: "排除标签数组。",
  exclude_match: "排除匹配方式：`any` / `all`。",
  unique_source_name: "同名来源去重，只计一次。",
  source_types: "来源类型过滤，如 `trait` / `gongfa` / `equipment` / `buff`。",
  origin_scope: "来源范围过滤，如 `all` / `self` / `nearby`。",
  source_name: "来源名称过滤。",
  queries: "联动查询列表。",
  cases: "联动分支列表（按计数阈值分支）。",
  else_effects: "联动未命中分支时执行的效果数组。",
};

const EFFECT_PARAM_HINTS = {
  stat_add: { stat: "要增减的属性键。", value: "固定加成值。" },
  stat_percent: { stat: "要增减的属性键。", value: "百分比加成，填 0~1。" },
  conditional_stat: {
    stat: "要增减的属性键。",
    value: "满足条件时生效的加成值。",
    condition: "触发条件，例如 `hp_below`。",
    threshold: "条件阈值。",
  },
  mp_regen_add: { value: "被动时为每秒回蓝；主动时为立即回蓝量。" },
  hp_regen_add: { value: "每秒回血量。" },
  damage_reduce_flat: { value: "固定减伤值。" },
  damage_reduce_percent: { value: "百分比减伤，填 0~1。" },
  dodge_bonus: { value: "闪避增益，填 0~1。" },
  crit_bonus: { value: "暴击增益，填 0~1。" },
  crit_damage_bonus: { value: "暴伤增益，填 0~1。" },
  vampire: { value: "吸血比例，填 0~1。" },
  damage_amp_percent: { value: "增伤比例，填 0~1。" },
  damage_amp_vs_debuffed: { value: "增伤比例，填 0~1。", require_debuff: "指定 Debuff 才增伤。" },
  tenacity: { value: "韧性比例，填 0~1。" },
  thorns_percent: { value: "反伤比例，填 0~1。" },
  thorns_flat: { value: "固定反伤值。" },
  shield_on_combat_start: { value: "开场护盾值。" },
  execute_threshold: { value: "斩杀阈值比例，填 0~1。" },
  healing_amp: { value: "治疗增幅比例，填 0~1。" },
  mp_on_kill: { value: "击杀回蓝值。" },
  attack_speed_bonus: { value: "攻速加成比例，填 0~1。" },
  range_add: { value: "射程增加格数。" },
  damage_target: { value: "单体伤害值。", damage_type: "伤害类型。" },
  damage_aoe: { value: "范围伤害值。", radius: "范围半径。", damage_type: "伤害类型。" },
  damage_chain: { value: "连锁基础伤害。", radius: "跳转搜索半径。", jumps: "连锁跳数。", chain_count: "连锁次数。", decay: "每跳衰减。", damage_type: "伤害类型。" },
  damage_cone: { value: "扇形伤害值。", radius: "扇形射程。", range: "扇形射程。", angle_deg: "扇形角度。", angle: "扇形角度。", damage_type: "伤害类型。" },
  damage_if_debuffed: { value: "伤害值。", require_debuff: "要求目标带指定 Debuff。", bonus_multiplier: "额外倍率。", damage_type: "伤害类型。" },
  damage_if_marked: { value: "伤害值。", mark_id: "要求目标带指定标记。", bonus_multiplier: "额外倍率。", damage_type: "伤害类型。" },
  damage_target_scaling: { value: "基础伤害。", scale_stat: "缩放属性。", scale_ratio: "缩放系数。", scale_source: "缩放来源。", damage_type: "伤害类型。" },
  execute_target: { threshold: "斩杀阈值比例。", damage: "触发斩杀时伤害。", value: "兼容字段：伤害值。", damage_type: "伤害类型。" },
  aoe_percent_hp_damage: { ratio: "按目标最大生命比例造成伤害。", percent: "兼容字段：比例。", radius: "范围半径。", damage_type: "伤害类型。" },
  heal_self: { value: "自身治疗值。" },
  heal_self_percent: { value: "按自身最大生命比例治疗，填 0~1。" },
  heal_allies_aoe: { value: "治疗值。", radius: "范围半径。", exclude_self: "是否排除自己。" },
  heal_target_flat: { value: "目标治疗值。" },
  heal_lowest_ally: { value: "治疗值。", radius: "搜索半径。" },
  heal_percent_missing_hp: { ratio: "按已损失生命比例治疗。", value: "兼容字段：比例值。" },
  drain_mp: { value: "抽取内力值。" },
  shield_self: { value: "护盾值。", duration: "持续时间。", buff_id: "绑定护盾Buff（可选）。" },
  shield_allies_aoe: { value: "护盾值。", radius: "范围半径。", duration: "持续时间。", buff_id: "绑定护盾Buff。", exclude_self: "是否排除自己。" },
  immunity_self: { duration: "免疫持续时间。", buff_id: "免疫Buff ID。" },
  buff_self: { buff_id: "目标 Buff ID。", duration: "持续时间。" },
  buff_target: { buff_id: "目标 Buff ID。", duration: "持续时间。" },
  buff_allies_aoe: { buff_id: "目标 Buff ID。", duration: "持续时间。", radius: "范围半径。", exclude_self: "是否排除自己。", binding_mode: "是否来源绑定光环。" },
  debuff_target: { buff_id: "目标 Debuff ID。", duration: "持续时间。" },
  debuff_aoe: { buff_id: "目标 Debuff ID。", duration: "持续时间。", radius: "范围半径。", binding_mode: "是否来源绑定光环。" },
  cleanse_self: { count: "净化层数。", debuff_ids: "限定可净化 Debuff ID 列表。" },
  cleanse_ally: { count: "净化层数。", radius: "范围半径。", debuff_ids: "限定可净化 Debuff ID 列表。" },
  steal_buff: { count: "偷取层数。", prefer_ids: "优先偷取 Buff ID 列表。" },
  dispel_target: { count: "驱散层数。", buff_ids: "限定可驱散 Buff ID 列表。" },
  mark_target: { mark_id: "施加标记ID。", duration: "标记持续时间。" },
  pull_target: { cells: "拉拽格数。", distance: "兼容字段：位移距离。" },
  knockback_aoe: { radius: "范围半径。", cells: "击退格数。", distance: "兼容字段：位移距离。" },
  knockback_target: { cells: "击退格数。", distance: "兼容字段：位移距离。" },
  swap_position: {},
  silence_target: { duration: "沉默持续时间。", buff_id: "沉默 Debuff ID（推荐）。" },
  stun_target: { duration: "眩晕持续时间。", buff_id: "眩晕 Debuff ID（推荐）。" },
  fear_aoe: { duration: "恐惧持续时间。", radius: "范围半径。", buff_id: "恐惧 Debuff ID（推荐）。" },
  freeze_target: { duration: "冻结持续时间。", buff_id: "冻结 Debuff ID（推荐）。" },
  teleport_behind: { distance_cells: "落点与目标的间隔格数。", distance: "兼容字段：位移距离。" },
  dash_forward: { distance_cells: "突进距离（格）。", distance: "兼容字段：位移距离。" },
  taunt_aoe: { duration: "嘲讽持续时间。", radius: "范围半径。", buff_id: "嘲讽 Debuff ID（推荐）。" },
  create_terrain: {
    terrain_ref_id: "引用已有地形模板ID。",
    terrain_id: "直接创建的地形ID。",
    terrain_type: "地形类型。",
    radius: "范围半径。",
    duration: "地形持续时间。",
    tick_interval: "地形周期触发间隔。",
    effects_on_enter: "进入地形时触发效果数组。",
    effects_on_tick: "周期触发效果数组。",
    effects_on_exit: "离开地形时触发效果数组。",
    effects_on_expire: "地形结束时触发效果数组。",
    tags: "地形标签数组。",
  },
  summon_units: { unit_ids: "召唤单位ID列表。", units: "召唤单位详细列表。", count: "召唤数量。", team: "召唤阵营。", cells: "部署格数。", deploy: "部署策略。" },
  hazard_zone: { radius: "危险区半径。", duration: "持续时间。", tick_interval: "触发间隔。", effects_on_tick: "周期触发效果数组。", value: "简化写法：每跳伤害值。" },
  spawn_vfx: { vfx_id: "特效ID。", at: "特效挂点。" },
  summon_clone: { count: "分身数量。", inherit_ratio: "继承属性比例。", unit_id: "可选：指定分身模板单位ID。" },
  revive_random_ally: { hp_ratio: "复活后生命比例。", hp_percent: "兼容字段：生命比例。", value: "兼容字段：生命值。" },
  resurrect_self: { hp_ratio: "复活后生命比例。", hp_percent: "兼容字段：生命比例。", resurrect_key: "复活唯一键，避免重复复活冲突。" },
  tag_linkage_branch: {
    execution_mode: "执行模式：`continuous` 连续评估 / `stateful` 状态保持。",
    range: "检索范围（格）。",
    team_scope: "统计队伍范围。",
    count_mode: "计数口径。",
    queries: "联动查询列表。",
    cases: "计数分支列表。",
    else_effects: "未命中分支时执行效果。",
  },
};

const TRIGGER_PARAM_SUGGESTIONS = Object.fromEntries(
  Object.entries(TRIGGER_PARAM_HINTS).map(([trigger, params]) => [
    trigger,
    [...Object.keys(TRIGGER_COMMON_PARAM_HINTS), ...Object.keys(params)],
  ])
);

const EFFECT_PARAM_SUGGESTIONS = Object.fromEntries(
  Object.entries(EFFECT_PARAM_HINTS).map(([op, params]) => [
    op,
    ["op", ...Object.keys(params)],
  ])
);

const TRIGGER_DESCRIPTIONS = {
  auto_mp_full: "内力回满时自动触发，常用于大招自动释放。",
  manual: "手动触发器，一般用于主动施法按钮。",
  auto_hp_below: "生命低于阈值时自动触发，非边沿检测。",
  on_hp_below: "生命从高于阈值跌破到低于阈值时触发一次。",
  on_time_elapsed: "战斗达到指定秒数时触发。",
  periodic_seconds: "按间隔周期触发。",
  passive_aura: "光环轮询触发，适合持续型效果。",
  on_combat_start: "战斗开始时触发。",
  on_attack_hit: "攻击命中后触发。",
  on_attacked: "受到攻击后触发。",
  on_kill: "击杀单位后触发。",
  on_ally_death: "友方单位死亡后触发。",
  on_crit: "造成暴击时触发。",
  on_dodge: "成功闪避时触发。",
  on_attack_fail: "攻击失败时触发，可按失败原因过滤。",
  on_shield_broken: "护盾被打破时触发。",
  on_unit_spawned_mid_battle: "战斗中有新单位加入时触发。",
  on_damage_received: "受到伤害时触发，可按最小伤害过滤。",
  on_heal_received: "受到治疗时触发，可按最小治疗量过滤。",
  on_thorns_triggered: "反伤生效时触发。",
  on_unit_move_success: "单位移动成功时触发。",
  on_unit_move_failed: "单位移动失败时触发，可按失败原因过滤。",
  on_terrain_created: "创建地形时触发。",
  on_terrain_enter: "进入地形时触发。",
  on_terrain_tick: "地形周期触发时触发。",
  on_terrain_exit: "离开地形时触发。",
  on_terrain_expire: "地形结束时触发。",
  on_team_alive_count_changed: "队伍存活人数变化时触发。",
  on_debuff_applied: "施加 Debuff 时触发。",
  on_buff_expired: "Buff 移除或到期时触发。",
  on_preparation_started: "全局事件：进入备战阶段。",
  on_stage_combat_started: "全局事件：关卡战斗开始。",
  on_stage_completed: "全局事件：关卡胜利结算。",
  on_stage_failed: "全局事件：关卡失败结算。",
  on_stage_loaded: "全局事件：关卡加载完成。",
  on_all_stages_cleared: "全局事件：关卡序列全部通关。",
};

const FIXED_FIELD_OPTIONS = {
  damage_type: [
    { value: "external", label: "外功", desc: "受防御、减伤等常规规则影响。" },
    { value: "internal", label: "内功", desc: "走内功伤害通道，通常与内功相关加成联动。" },
    { value: "true", label: "真实", desc: "通常不吃常规减伤，用于穿透型伤害。" },
  ],
  team_scope: [
    { value: "ally", label: "我方", desc: "只统计/作用于我方阵营。" },
    { value: "enemy", label: "敌方", desc: "只统计/作用于敌方阵营。" },
    { value: "all", label: "双方", desc: "同时统计/作用于双方。" },
    { value: "both", label: "双方(兼容)", desc: "历史兼容值，语义同 all。" },
  ],
  count_mode: [
    { value: "provider", label: "按来源计数", desc: "同一来源算 1 次，常用于联动统计。" },
    { value: "unit", label: "按单位计数", desc: "每个单位各算一次。" },
    { value: "occurrence", label: "按命中次数计数", desc: "每次命中/触发都计入。" },
  ],
  execution_mode: [
    { value: "continuous", label: "连续评估", desc: "每次评估都立即按当前条件执行。" },
    { value: "stateful", label: "状态保持", desc: "按状态切换执行，减少抖动。" },
  ],
  query_type: [
    { value: "match_tags", label: "正向匹配", desc: "命中给定 tags 才算满足。" },
    { value: "forbid_tags", label: "反向匹配", desc: "命中给定 tags 时排除。" },
  ],
  tag_match: [
    { value: "any", label: "任一匹配", desc: "满足任意一个标签即可。" },
    { value: "all", label: "全部匹配", desc: "必须满足全部标签。" },
  ],
  exclude_match: [
    { value: "any", label: "命中任一即排除", desc: "命中任一排除标签就剔除。" },
    { value: "all", label: "命中全部才排除", desc: "命中全部排除标签才剔除。" },
  ],
  origin_scope: [
    { value: "all", label: "全部来源", desc: "不限制来源范围。" },
    { value: "self", label: "仅自身", desc: "只统计施法者自身来源。" },
    { value: "nearby", label: "仅附近", desc: "只统计附近来源。" },
  ],
  binding_mode: [
    { value: "", label: "普通模式", desc: "按普通 Buff/Debuff 施加方式处理。" },
    { value: "source_bound_aura", label: "来源绑定光环", desc: "目标离开来源条件后自动移除。" },
  ],
  scale_source: [
    { value: "auto", label: "自动", desc: "由运行时自动判断缩放来源。" },
    { value: "source", label: "施法者", desc: "按施法者属性缩放。" },
    { value: "target", label: "目标", desc: "按目标属性缩放。" },
  ],
};

const FIXED_ARRAY_ITEM_OPTIONS = {
  source_types: [
    { value: "trait", label: "特性", desc: "来源类型：特性。" },
    { value: "gongfa", label: "功法", desc: "来源类型：功法。" },
    { value: "equipment", label: "装备", desc: "来源类型：装备。" },
    { value: "buff", label: "Buff", desc: "来源类型：单位当前生效的 Buff / Debuff。" },
    { value: "terrain", label: "地形", desc: "来源类型：地形。" },
    { value: "unit", label: "单位", desc: "来源类型：单位。" },
  ],
};

const TRIGGER_PARAM_FIXED_OPTIONS = {
  on_attack_fail: {
    reasons: [
      { value: "no_target", label: "无目标", desc: "当前没有可攻击目标。" },
      { value: "out_of_range", label: "超出范围", desc: "目标不在可攻击距离内。" },
      { value: "cooldown", label: "冷却中", desc: "技能/攻击处于冷却状态。" },
      { value: "stunned", label: "被控制", desc: "单位被硬控导致无法攻击。" },
    ],
  },
  on_unit_move_failed: {
    reasons: [
      { value: "block", label: "阻挡", desc: "路径或目标格被阻挡。" },
      { value: "conflict", label: "冲突", desc: "目标格冲突或不可占用。" },
      { value: "no_cell", label: "无可用格", desc: "找不到可移动的合法格子。" },
      { value: "in_range_hold", label: "保持站位", desc: "因策略保持原地。" },
      { value: "stunned", label: "被控制", desc: "单位被硬控导致无法移动。" },
    ],
  },
};

const OBJECT_FIELD_HINTS = {
  trigger: "触发器ID（下拉选择）",
  type: "触发器ID（用于 trigger.type）",
  trigger_params: "触发参数对象（参数键按触发器约束）",
  cooldown: "触发冷却（秒）",
  max_trigger_count: "最大触发次数（0 或缺省表示不限）",
  interval_seconds: "触发间隔（秒）",
  initial_delay_seconds: "初始延迟（秒）",
  effects: "效果数组（支持联动 tag_linkage_branch）",
  range: "范围（格）",
  chance: "触发概率（0~1）",
  mp_cost: "消耗内力",
  id: "条目ID",
  name: "名称",
  description: "说明",
  tags: "标签数组",
  skills: "技能数组（每项含 trigger + effects）",
};

const el = {
  statusText: document.getElementById("statusText"),
  schemaInfo: document.getElementById("schemaInfo"),
  modSelect: document.getElementById("modSelect"),
  categorySelect: document.getElementById("categorySelect"),
  fileSelect: document.getElementById("fileSelect"),
  saveBtn: document.getElementById("saveBtn"),
  reloadBtn: document.getElementById("reloadBtn"),
  newFileBtn: document.getElementById("newFileBtn"),
  deleteFileBtn: document.getElementById("deleteFileBtn"),
  arrayPanel: document.getElementById("arrayPanel"),
  itemList: document.getElementById("itemList"),
  addItemBtn: document.getElementById("addItemBtn"),
  cloneItemBtn: document.getElementById("cloneItemBtn"),
  removeItemBtn: document.getElementById("removeItemBtn"),
  formTabBtn: document.getElementById("formTabBtn"),
  rawTabBtn: document.getElementById("rawTabBtn"),
  formTab: document.getElementById("formTab"),
  rawTab: document.getElementById("rawTab"),
  rawEditor: document.getElementById("rawEditor"),
  formatRawBtn: document.getElementById("formatRawBtn"),
  applyRawBtn: document.getElementById("applyRawBtn"),
  manifestIdInput: document.getElementById("manifestIdInput"),
  manifestNameInput: document.getElementById("manifestNameInput"),
  manifestAuthorInput: document.getElementById("manifestAuthorInput"),
  manifestVersionInput: document.getElementById("manifestVersionInput"),
  manifestGameVersionInput: document.getElementById("manifestGameVersionInput"),
  manifestLoadOrderInput: document.getElementById("manifestLoadOrderInput"),
  manifestDescInput: document.getElementById("manifestDescInput"),
  reloadManifestBtn: document.getElementById("reloadManifestBtn"),
  saveManifestBtn: document.getElementById("saveManifestBtn"),
  refPickerMask: document.getElementById("refPickerMask"),
  refPickerTitle: document.getElementById("refPickerTitle"),
  refPickerCloseBtn: document.getElementById("refPickerCloseBtn"),
  refSearchInput: document.getElementById("refSearchInput"),
  refSearchBtn: document.getElementById("refSearchBtn"),
  refList: document.getElementById("refList"),
  refPrevBtn: document.getElementById("refPrevBtn"),
  refNextBtn: document.getElementById("refNextBtn"),
  refPageText: document.getElementById("refPageText"),
  newFileMask: document.getElementById("newFileMask"),
  newFileNameInput: document.getElementById("newFileNameInput"),
  newFileRootType: document.getElementById("newFileRootType"),
  newFileRootHint: document.getElementById("newFileRootHint"),
  newFileConfirmBtn: document.getElementById("newFileConfirmBtn"),
  newFileCancelBtn: document.getElementById("newFileCancelBtn"),
};

function setStatus(message, isError = false) {
  el.statusText.textContent = message;
  el.statusText.style.color = isError ? "#b42318" : "#5a6980";
}

function deepClone(value) {
  return JSON.parse(JSON.stringify(value));
}

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function updateDirty(dirty) {
  state.dirty = dirty;
  el.saveBtn.textContent = dirty ? "保存数据 *" : "保存数据";
}

async function apiGet(url) {
  const response = await fetch(url);
  const json = await response.json();
  if (!response.ok || !json.ok) {
    throw new Error(json.error || `请求失败: ${response.status}`);
  }
  return json;
}

async function apiPost(url, payload) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(payload),
  });
  const json = await response.json();
  if (!response.ok || !json.ok) {
    throw new Error(json.error || `请求失败: ${response.status}`);
  }
  return json;
}

function sortModsInPlace() {
  state.mods.sort((a, b) => {
    const orderA = Number(a.load_order || 0);
    const orderB = Number(b.load_order || 0);
    if (orderA !== orderB) return orderA - orderB;
    return String(a.id || "").localeCompare(String(b.id || ""));
  });
}

function optionElements(items, selected, labelResolver) {
  return items
    .map((item) => {
      const value = String(item.value);
      const label = labelResolver(item);
      const selectedAttr = value === String(selected) ? " selected" : "";
      return `<option value="${escapeHtml(value)}"${selectedAttr}>${escapeHtml(label)}</option>`;
    })
    .join("");
}

function parseRefPath(ref) {
  if (!ref || typeof ref !== "string" || !ref.startsWith("#/")) return null;
  return ref
    .slice(2)
    .split("/")
    .map((x) => x.replaceAll("~1", "/").replaceAll("~0", "~"));
}

function derefSchema(schema, rootSchema) {
  if (!schema || typeof schema !== "object") return {};
  if (!schema.$ref) return schema;
  const parts = parseRefPath(schema.$ref);
  if (!parts) return schema;
  let node = rootSchema;
  for (const p of parts) {
    if (!node || typeof node !== "object" || !(p in node)) {
      return schema;
    }
    node = node[p];
  }
  return derefSchema(node, rootSchema);
}

function effectiveSchema(rawSchema, rootSchema) {
  const schema = derefSchema(rawSchema || {}, rootSchema);
  if (!schema || typeof schema !== "object") return {};
  if (!Array.isArray(schema.allOf)) return schema;
  const merged = { ...schema };
  delete merged.allOf;
  for (const subRaw of schema.allOf) {
    const sub = derefSchema(subRaw, rootSchema);
    if (!sub || typeof sub !== "object") continue;
    if (sub.properties && typeof sub.properties === "object") {
      merged.properties = { ...(merged.properties || {}), ...sub.properties };
    }
    if (Array.isArray(sub.required)) {
      merged.required = Array.from(new Set([...(merged.required || []), ...sub.required]));
    }
  }
  return merged;
}

function schemaTypes(schema) {
  const t = schema.type;
  if (Array.isArray(t)) return t.slice();
  if (typeof t === "string" && t.length > 0) return [t];
  if (schema.properties || schema.additionalProperties) return ["object"];
  if (schema.items) return ["array"];
  return [];
}

function inferTypesFromValue(value) {
  if (value === null) return ["null"];
  if (Array.isArray(value)) return ["array"];
  if (typeof value === "boolean") return ["boolean"];
  if (typeof value === "number") return Number.isInteger(value) ? ["integer"] : ["number"];
  if (typeof value === "string") return ["string"];
  if (isObject(value)) return ["object"];
  return [];
}

function defaultValueForSchema(rawSchema, rootSchema) {
  const schema = effectiveSchema(rawSchema, rootSchema);
  if (Object.prototype.hasOwnProperty.call(schema, "default")) {
    return deepClone(schema.default);
  }
  if (Array.isArray(schema.enum) && schema.enum.length > 0) {
    return deepClone(schema.enum[0]);
  }
  const types = schemaTypes(schema);
  if (types.includes("null")) return null;
  if (types.includes("object")) {
    const required = new Set(Array.isArray(schema.required) ? schema.required : []);
    const props = schema.properties || {};
    const result = {};
    for (const key of Object.keys(props)) {
      if (required.has(key)) {
        result[key] = defaultValueForSchema(props[key], rootSchema);
      }
    }
    return result;
  }
  if (types.includes("array")) return [];
  if (types.includes("boolean")) return false;
  if (types.includes("integer") || types.includes("number")) return 0;
  return "";
}

function docRootSchema() {
  if (!state.schema) return {};
  if (state.rootIsArray) return { type: "array", items: state.schema };
  return state.schema;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function listItemLabel(item, index) {
  if (!isObject(item)) return `[${index}] ${String(item)}`;
  return `[${index}] ${item.name || item.id || item.title || `item_${index}`}`;
}

function createNode(tag, className = "", text = "") {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text) node.textContent = text;
  return node;
}

function encodeFocusSegment(segment) {
  return encodeURIComponent(String(segment == null ? "" : segment));
}

function composeFocusKey(focusPath, control = "") {
  if (!Array.isArray(focusPath) || focusPath.length === 0) return "";
  const base = focusPath.map(encodeFocusSegment).join("/");
  if (!control) return base;
  return `${base}::${encodeFocusSegment(control)}`;
}

function attachFocusKey(node, focusPath, control = "") {
  if (!(node instanceof HTMLElement)) return;
  const key = composeFocusKey(focusPath, control);
  if (!key) return;
  node.setAttribute("data-focus-key", key);
}

function captureEditorFocusSnapshot() {
  const active = document.activeElement;
  if (!(active instanceof HTMLElement)) return null;
  const key = active.getAttribute("data-focus-key");
  if (!key) return null;
  const snapshot = {
    key,
    selectionStart: null,
    selectionEnd: null,
    selectionDirection: "none",
  };
  if (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) {
    try {
      if (typeof active.selectionStart === "number") snapshot.selectionStart = active.selectionStart;
      if (typeof active.selectionEnd === "number") snapshot.selectionEnd = active.selectionEnd;
      if (typeof active.selectionDirection === "string") snapshot.selectionDirection = active.selectionDirection;
    } catch (_err) {
      snapshot.selectionStart = null;
      snapshot.selectionEnd = null;
      snapshot.selectionDirection = "none";
    }
  }
  return snapshot;
}

function escapeCssAttrValue(value) {
  if (window.CSS && typeof window.CSS.escape === "function") {
    return window.CSS.escape(value);
  }
  return String(value).replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

function restoreEditorFocusSnapshot(snapshot) {
  if (!snapshot || !snapshot.key) return;
  const selector = `[data-focus-key="${escapeCssAttrValue(snapshot.key)}"]`;
  const target = el.formTab.querySelector(selector);
  if (!(target instanceof HTMLElement)) return;

  target.focus({ preventScroll: true });
  if (
    (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) &&
    typeof snapshot.selectionStart === "number" &&
    typeof snapshot.selectionEnd === "number"
  ) {
    const max = target.value.length;
    const start = Math.max(0, Math.min(snapshot.selectionStart, max));
    const end = Math.max(start, Math.min(snapshot.selectionEnd, max));
    try {
      target.setSelectionRange(start, end, snapshot.selectionDirection || "none");
    } catch (_err) {
      // Ignore controls that do not support selection ranges (for example type=number).
    }
  }
}

function renderPreservingEditorFocus() {
  const snapshot = captureEditorFocusSnapshot();
  render();
  restoreEditorFocusSnapshot(snapshot);
}

function setTab(tab) {
  state.activeTab = tab;
  const formActive = tab === "form";
  el.formTabBtn.classList.toggle("active", formActive);
  el.rawTabBtn.classList.toggle("active", !formActive);
  el.formTab.hidden = !formActive;
  el.rawTab.hidden = formActive;
}

function normalizePathSegment(segment) {
  const text = String(segment || "").trim().toLowerCase();
  if (text === "[]") return "[]";
  if (/^\[\d+\]$/.test(text)) return "[]";
  return text;
}

function inferReferenceKind(pathSegments, currentCategory) {
  const normalized = pathSegments.map(normalizePathSegment);
  const leaf = normalized[normalized.length - 1] || "";
  const parent = normalized[normalized.length - 2] || "";
  if (leaf === "op") return "effect_op";
  if (leaf === "trigger" || (leaf === "type" && parent === "trigger")) return "trigger";
  if (leaf === "buff_id" || leaf === "mark_id") return "buffs";
  if (leaf === "terrain_id" || leaf === "terrain_ref_id") return "terrains";
  if (leaf === "vfx_id") return "vfx";
  if (leaf === "unit_id" || leaf.endsWith("_unit_id")) return "units";
  if (leaf === "tag" || leaf === "tag_id" || leaf === "tags" || parent === "tags") return "tags";
  if (leaf === "stage_id" || parent === "stages") return "stages";
  if (leaf.includes("gongfa") || parent.includes("gongfa")) return "gongfa";
  if (leaf.includes("equip") || leaf.includes("equipment") || parent.includes("equip")) return "equipment";
  if (currentCategory === "units") {
    if (normalized.includes("initial_gongfa") || normalized.includes("gongfa_slots")) return "gongfa";
    if (normalized.includes("equip_slots")) return "equipment";
  }
  return "";
}

function isEffectArrayPath(path) {
  if (!Array.isArray(path) || path.length === 0) return false;
  const leaf = normalizePathSegment(path[path.length - 1]);
  return leaf.includes("effects") || leaf === "passive_effects";
}

function isUnderEffectTree(path) {
  if (!Array.isArray(path) || path.length === 0) return false;
  return path.map(normalizePathSegment).some((seg) => seg.includes("effects") || seg === "passive_effects");
}

function isEffectObjectPath(path) {
  if (!Array.isArray(path) || path.length < 2) return false;
  return normalizePathSegment(path[path.length - 1]) === "[]" && isEffectArrayPath(path.slice(0, -1));
}

function isSkillObjectPath(path) {
  if (!Array.isArray(path) || path.length < 2) return false;
  const normalized = path.map(normalizePathSegment);
  return normalized[normalized.length - 1] === "[]" && normalized[normalized.length - 2] === "skills";
}

function isTraitObjectPath(path) {
  if (!Array.isArray(path) || path.length < 2) return false;
  const normalized = path.map(normalizePathSegment);
  return normalized[normalized.length - 1] === "[]" && normalized[normalized.length - 2] === "traits";
}

function isTriggerObjectPath(path) {
  if (!Array.isArray(path) || path.length === 0) return false;
  return normalizePathSegment(path[path.length - 1]) === "trigger";
}

function isLinkageQueryObjectPath(path) {
  if (!Array.isArray(path) || path.length < 2) return false;
  const normalized = path.map(normalizePathSegment);
  return normalized[normalized.length - 1] === "[]" && normalized[normalized.length - 2] === "queries";
}

function isLinkageCaseObjectPath(path) {
  if (!Array.isArray(path) || path.length < 2) return false;
  const normalized = path.map(normalizePathSegment);
  return normalized[normalized.length - 1] === "[]" && normalized[normalized.length - 2] === "cases";
}

function isLinkageQueriesArrayPath(path) {
  if (!Array.isArray(path) || path.length === 0) return false;
  return normalizePathSegment(path[path.length - 1]) === "queries";
}

function isLinkageCasesArrayPath(path) {
  if (!Array.isArray(path) || path.length === 0) return false;
  return normalizePathSegment(path[path.length - 1]) === "cases";
}

function isTriggerParamsPath(path) {
  if (!Array.isArray(path) || path.length === 0) return false;
  return normalizePathSegment(path[path.length - 1]) === "trigger_params";
}

function fieldKeyFromPath(path) {
  if (!Array.isArray(path) || path.length === 0) return "";
  let leaf = normalizePathSegment(path[path.length - 1]);
  if (leaf === "[]") {
    leaf = normalizePathSegment(path[path.length - 2] || "");
  }
  return leaf;
}

function formatOptionLine(row) {
  const value = String(row.value ?? "");
  const label = String(row.label ?? value);
  const desc = String(row.desc ?? "").trim();
  if (desc) return `${value}(${label})：${desc}`;
  return `${value}(${label})`;
}

function optionSummaryText(options) {
  if (!Array.isArray(options) || options.length === 0) return "";
  return `可选值：${options.map(formatOptionLine).join("；")}`;
}

function fixedOptionsForField(path, contextEffectOp = "", contextTriggerId = "") {
  const key = fieldKeyFromPath(path);
  if (!key) return [];
  if (Object.prototype.hasOwnProperty.call(FIXED_FIELD_OPTIONS, key)) {
    return FIXED_FIELD_OPTIONS[key];
  }
  if (Object.prototype.hasOwnProperty.call(FIXED_ARRAY_ITEM_OPTIONS, key)) {
    return FIXED_ARRAY_ITEM_OPTIONS[key];
  }

  if (key === "reasons") {
    const triggerId = String(contextTriggerId || "").trim();
    const triggerMap = TRIGGER_PARAM_FIXED_OPTIONS[triggerId] || {};
    if (Array.isArray(triggerMap.reasons)) return triggerMap.reasons;
  }
  return [];
}

function lookupCachedReferenceLabel(kind, id) {
  const idText = String(id || "").trim();
  if (!idText) return "";
  const rows = state.referenceCache[kind] || [];
  const found = rows.find((row) => String(row.id || "").toLowerCase() === idText.toLowerCase());
  return found ? String(found.name || "") : "";
}

function effectOpLabel(op) {
  const key = String(op || "").trim();
  if (!key) return "";
  return lookupCachedReferenceLabel("effect_op", key) || BUILTIN_EFFECT_OP_LABELS[key] || "";
}

function triggerLabel(triggerId) {
  const key = String(triggerId || "").trim();
  if (!key) return "";
  return lookupCachedReferenceLabel("trigger", key) || BUILTIN_TRIGGER_LABELS[key] || "";
}

function mergeUniqueKeys(...arrs) {
  return Array.from(new Set(arrs.flat().filter((x) => String(x || "").trim() !== "")));
}

function resolveTriggerIdFromCarrier(value) {
  if (!isObject(value)) return "";
  const triggerId = String(value.trigger ?? value.type ?? "").trim();
  return triggerId;
}

function resolveEffectOpFromObject(value, fallback = "") {
  if (!isObject(value)) return String(fallback || "").trim();
  if (Object.prototype.hasOwnProperty.call(value, "op")) {
    const direct = String(value.op ?? "").trim();
    if (direct) return direct;
  }
  for (const [k, v] of Object.entries(value)) {
    if (normalizePathSegment(k) === "op") {
      const text = String(v ?? "").trim();
      if (text) return text;
    }
  }
  return String(fallback || "").trim();
}

function resolveTriggerIdForPath(path, value, parentValue = null, contextTriggerId = "") {
  const preferred = String(contextTriggerId || "").trim();
  if (preferred) return preferred;
  if (isTriggerParamsPath(path)) {
    return resolveTriggerIdFromCarrier(parentValue);
  }
  if (isSkillObjectPath(path) || isTriggerObjectPath(path)) {
    return resolveTriggerIdFromCarrier(value);
  }
  return "";
}

function objectFieldCandidates(path, currentValue) {
  const existing = isObject(currentValue) ? new Set(Object.keys(currentValue)) : new Set();
  const toRows = (keys) =>
    keys
      .filter((key) => !existing.has(key))
      .map((key) => ({
        id: key,
        name: OBJECT_FIELD_HINTS[key] || "固定结构字段",
        mod: "builtin",
        load_order: "-",
        file: "object_fields",
      }));

  if (isSkillObjectPath(path)) {
    return toRows([
      "trigger",
      "trigger_params",
      "cooldown",
      "max_trigger_count",
      "interval_seconds",
      "initial_delay_seconds",
      "effects",
      "range",
      "chance",
      "mp_cost",
    ]);
  }
  if (isTriggerObjectPath(path)) {
    return toRows([
      "type",
      "trigger_params",
      "cooldown",
      "max_trigger_count",
      "interval_seconds",
      "initial_delay_seconds",
      "effects",
      "range",
      "chance",
      "mp_cost",
    ]);
  }
  if (isTraitObjectPath(path)) {
    return toRows(["id", "name", "description", "tags", "effects", "skills"]);
  }
  if (isLinkageQueryObjectPath(path)) {
    return toRows([
      "query_type",
      "tags",
      "tag_match",
      "exclude_tags",
      "exclude_match",
      "source_types",
      "origin_scope",
      "source_name",
      "team_scope",
      "unique_source_name",
    ]);
  }
  if (isLinkageCaseObjectPath(path)) {
    return toRows(["min_count", "max_count", "effects"]);
  }
  return [];
}

function triggerParamHints(triggerId) {
  const id = String(triggerId || "").trim();
  return {
    ...TRIGGER_COMMON_PARAM_HINTS,
    ...(TRIGGER_PARAM_HINTS[id] || {}),
  };
}

function effectParamHints(op) {
  const id = String(op || "").trim();
  return {
    ...EFFECT_COMMON_PARAM_HINTS,
    ...(EFFECT_PARAM_HINTS[id] || {}),
  };
}

async function loadEffectParamRows(op) {
  const opId = String(op || "").trim();
  if (!opId || !state.selectedMod) return [];
  if (Object.prototype.hasOwnProperty.call(state.effectParamCache, opId)) {
    return Array.isArray(state.effectParamCache[opId]) ? state.effectParamCache[opId] : [];
  }
  try {
    const resp = await apiGet(
      `/api/effect_params?mod=${encodeURIComponent(state.selectedMod)}` +
        `&op=${encodeURIComponent(opId)}` +
        `&scope=before_and_self` +
        `&q=` +
        `&page=1&page_size=1000`
    );
    const rows = Array.isArray(resp.items) ? resp.items : [];
    state.effectParamCache[opId] = rows;
    return rows;
  } catch (_err) {
    state.effectParamCache[opId] = [];
    return [];
  }
}

function triggerParamCandidates(triggerId, currentValue) {
  const id = String(triggerId || "").trim();
  const suggestions = mergeUniqueKeys(
    Object.keys(TRIGGER_COMMON_PARAM_HINTS),
    Object.keys(TRIGGER_PARAM_HINTS[id] || {}),
    TRIGGER_PARAM_SUGGESTIONS[id] || []
  );
  const existing = isObject(currentValue) ? new Set(Object.keys(currentValue)) : new Set();
  return suggestions
    .filter((key) => !existing.has(key))
    .map((key) => ({
      id: key,
      name: triggerParamHints(id)[key] || "触发器参数",
      mod: "builtin",
      load_order: "-",
      file: "trigger_params",
    }));
}

function effectParamCandidates(op, currentValue, path = [], dynamicKeys = []) {
  const id = String(op || "").trim();
  let suggestions = mergeUniqueKeys(
    Object.keys(EFFECT_PARAM_HINTS[id] || {}),
    (EFFECT_PARAM_SUGGESTIONS[id] || []).filter((x) => x !== "op"),
    dynamicKeys
  );
  if (id === "tag_linkage_branch") {
    if (isLinkageQueryObjectPath(path)) {
      suggestions = [
        "query_type",
        "tags",
        "tag_match",
        "exclude_tags",
        "exclude_match",
        "source_types",
        "origin_scope",
        "source_name",
        "team_scope",
        "unique_source_name",
      ];
    } else if (isLinkageCaseObjectPath(path)) {
      suggestions = ["min_count", "max_count", "effects"];
    }
  }
  const existing = isObject(currentValue) ? new Set(Object.keys(currentValue)) : new Set();
  return suggestions
    .filter((key) => key !== "op" && !existing.has(key))
    .map((key) => ({
      id: key,
      name: effectParamHints(id)[key] || "特效参数",
      mod: "builtin",
      load_order: "-",
      file: `effect:${id || "unknown"}`,
    }));
}

function defaultValueByFieldKey(fieldKey) {
  const key = String(fieldKey || "").trim().toLowerCase();
  if (!key) return "";
  if (key === "trigger_params") return {};
  if (key.endsWith("_params")) return {};
  if (key.endsWith("_ids")) return [];
  if (key.endsWith("_types")) return [];
  if (key.endsWith("_tags")) return [];
  if (
    key === "tags" ||
    key === "queries" ||
    key === "cases" ||
    key === "else_effects" ||
    key === "units" ||
    key === "effects" ||
    key === "passive_effects" ||
    key === "skills" ||
    key === "source_types"
  ) {
    return [];
  }
  if (key === "exclude_self" || key === "unique_source_name") return false;
  if (key === "team_scope") return "ally";
  if (key === "count_mode") return "provider";
  if (key === "execution_mode") return "continuous";
  if (key === "query_type") return "match_tags";
  if (key === "tag_match" || key === "exclude_match") return "any";
  if (key === "duration" || key === "radius" || key === "range") return 0;
  if (key === "count" || key === "cells" || key === "distance" || key === "distance_cells" || key === "jumps") return 1;
  if (key === "ratio" || key === "percent" || key === "threshold" || key === "value" || key === "chance") return 0;
  if (key.startsWith("min_")) return 0;
  if (key.endsWith("_interval")) return 1;
  if (key.endsWith("_id")) return "";
  if (key === "damage_type") return "external";
  return "";
}

function contextualFieldHint({ keyName, path, contextEffectOp, contextTriggerId }) {
  const key = String(keyName || "").trim();
  if (!key) return "";
  const leaf = normalizePathSegment(path[path.length - 1] || "");
  const parent = normalizePathSegment(path[path.length - 2] || "");
  if (leaf === "trigger" || (leaf === "type" && parent === "trigger")) {
    const triggerId = String(contextTriggerId || "").trim();
    const label = triggerLabel(triggerId);
    const desc = TRIGGER_DESCRIPTIONS[triggerId] || "触发器决定技能在什么时机触发。";
    if (label) {
      return "触发器：" + label + "。" + desc;
    }
    return desc;
  }
  if (leaf === "op") {
    const label = effectOpLabel(contextEffectOp || "");
    return label ? "特效：" + label : "特效操作符，决定当前效果行为。";
  }
  if (normalizePathSegment(path[path.length - 2] || "") === "trigger_params") {
    const hint = triggerParamHints(contextTriggerId || "")[key] || "";
    const fixedOptions = fixedOptionsForField(path, contextEffectOp || "", contextTriggerId || "");
    const optionText = optionSummaryText(fixedOptions);
    if (hint && optionText) return hint + " " + optionText;
    if (hint) return hint;
    if (optionText) return optionText;
  }
  if (contextEffectOp) {
    const hint = effectParamHints(contextEffectOp)[key] || "";
    const fixedOptions = fixedOptionsForField(path, contextEffectOp || "", contextTriggerId || "");
    const optionText = optionSummaryText(fixedOptions);
    if (hint && optionText) return hint + " " + optionText;
    if (hint) return hint;
    if (optionText) return optionText;
  } else {
    const fixedOptions = fixedOptionsForField(path, contextEffectOp || "", contextTriggerId || "");
    const optionText = optionSummaryText(fixedOptions);
    if (optionText) return optionText;
  }
  return "";
}

function validateRequired(value, rawSchema, rootSchema, path = "$") {
  const issues = [];
  const schema = effectiveSchema(rawSchema, rootSchema);
  const types = schemaTypes(schema);

  if (value === null) {
    if (!types.includes("null")) issues.push(`${path}: 不允许为 null`);
    return issues;
  }

  if (types.includes("object") && isObject(value)) {
    const required = Array.isArray(schema.required) ? schema.required : [];
    for (const key of required) {
      if (!Object.prototype.hasOwnProperty.call(value, key)) issues.push(`${path}.${key}: 必填`);
    }
    const props = schema.properties || {};
    for (const [key, child] of Object.entries(value)) {
      if (props[key]) {
        issues.push(...validateRequired(child, props[key], rootSchema, `${path}.${key}`));
      } else if (isObject(schema.additionalProperties)) {
        issues.push(...validateRequired(child, schema.additionalProperties, rootSchema, `${path}.${key}`));
      }
    }
  }
  if (types.includes("array") && Array.isArray(value)) {
    const itemSchema = schema.items || {};
    value.forEach((item, i) => issues.push(...validateRequired(item, itemSchema, rootSchema, `${path}[${i}]`)));
  }
  return issues;
}

function applyRawToDocument() {
  try {
    const parsed = JSON.parse(el.rawEditor.value);
    state.document = parsed;
    state.rootIsArray = Array.isArray(parsed);
    state.selectedIndex = 0;
    updateDirty(true);
    render();
    setStatus("已应用 JSON 到表单。");
  } catch (err) {
    setStatus(`JSON 解析失败: ${err.message}`, true);
  }
}
function renderSelectors() {
  el.modSelect.innerHTML = optionElements(
    state.mods.map((m) => ({ value: m.folder || m.id, mod: m })),
    state.selectedMod,
    (x) => `${x.mod.folder} | ${x.mod.name} | load_order=${x.mod.load_order}`
  );
  el.categorySelect.innerHTML = optionElements(
    state.categories.map((c) => ({ value: c.id, category: c })),
    state.selectedCategory,
    (x) => `${x.category.id} | ${x.category.title}`
  );
  if (state.files.length === 0) {
    el.fileSelect.innerHTML = `<option value="">(当前分类无文件)</option>`;
    el.fileSelect.value = "";
  } else {
    el.fileSelect.innerHTML = optionElements(
      state.files.map((f) => ({ value: f })),
      state.selectedFile,
      (x) => x.value
    );
  }
  if (el.deleteFileBtn) {
    el.deleteFileBtn.disabled = !state.selectedFile;
  }
  const category = state.categories.find((x) => x.id === state.selectedCategory);
  el.schemaInfo.textContent = category ? `Schema: ${category.schema_file}` : "";
}

function renderManifestForm() {
  const manifest = state.manifest;
  if (!manifest || typeof manifest !== "object") {
    el.manifestIdInput.value = "";
    el.manifestNameInput.value = "";
    el.manifestAuthorInput.value = "";
    el.manifestVersionInput.value = "";
    el.manifestGameVersionInput.value = "";
    el.manifestLoadOrderInput.value = "0";
    el.manifestDescInput.value = "";
    return;
  }
  el.manifestIdInput.value = String(manifest.id ?? "");
  el.manifestNameInput.value = String(manifest.name ?? "");
  el.manifestAuthorInput.value = String(manifest.author ?? "");
  el.manifestVersionInput.value = String(manifest.version ?? "");
  el.manifestGameVersionInput.value = String(manifest.game_version_min ?? "");
  el.manifestLoadOrderInput.value = String(Number(manifest.load_order ?? 0));
  el.manifestDescInput.value = String(manifest.description ?? "");
}

function collectManifestFromForm() {
  const source = isObject(state.manifest) ? deepClone(state.manifest) : {};
  source.id = el.manifestIdInput.value.trim();
  source.name = el.manifestNameInput.value.trim();
  source.author = el.manifestAuthorInput.value.trim();
  source.version = el.manifestVersionInput.value.trim();
  source.game_version_min = el.manifestGameVersionInput.value.trim();
  source.description = el.manifestDescInput.value;
  const loadOrderRaw = el.manifestLoadOrderInput.value.trim();
  source.load_order = loadOrderRaw === "" ? 0 : parseInt(loadOrderRaw, 10) || 0;
  return source;
}

function renderArrayPanel() {
  const show = state.rootIsArray && Array.isArray(state.document);
  el.arrayPanel.hidden = !show;
  if (!show) {
    el.itemList.innerHTML = "";
    return;
  }
  const html = state.document
    .map((item, index) => {
      const active = index === state.selectedIndex ? " active" : "";
      return `<button type="button" class="item-entry${active}" data-index="${index}">${escapeHtml(
        listItemLabel(item, index)
      )}</button>`;
    })
    .join("");
  el.itemList.innerHTML = html;
}

function renderRawEditor() {
  if (state.document == null) {
    el.rawEditor.value = "";
    return;
  }
  if (document.activeElement !== el.rawEditor) {
    el.rawEditor.value = JSON.stringify(state.document, null, 2);
  }
}

function renderReferenceModal() {
  const picker = state.refPicker;
  el.refPickerMask.hidden = !picker.visible;
  if (!picker.visible) return;

  el.refPickerTitle.textContent = picker.title || "引用选择";
  el.refSearchInput.value = picker.query;
  el.refPageText.textContent = `第 ${picker.page} 页，每页 ${picker.pageSize} 条，共 ${picker.total} 条`;
  el.refPrevBtn.disabled = picker.page <= 1;
  el.refNextBtn.disabled = picker.page * picker.pageSize >= picker.total;

  if (!Array.isArray(picker.items) || picker.items.length === 0) {
    el.refList.innerHTML = `<div class="ref-entry"><div class="id">没有匹配项</div><div class="meta">请尝试更换关键词</div></div>`;
    return;
  }
  el.refList.innerHTML = picker.items
    .map(
      (item) => `
      <button type="button" class="ref-entry" data-ref-id="${escapeHtml(item.id)}">
        <div class="id">${escapeHtml(item.id)}</div>
        <div>${escapeHtml(item.name || "")}</div>
        <div class="meta">mod=${escapeHtml(item.mod || "")} | load_order=${escapeHtml(
        item.load_order ?? ""
      )} | file=${escapeHtml(item.file || "")}</div>
      </button>
    `
    )
    .join("");
}

function renderEditorPanel() {
  el.formTab.innerHTML = "";
  if (!state.schema) {
    el.formTab.appendChild(createNode("p", "muted", "请选择 Mod 和分类。"));
    return;
  }
  if (state.document == null) {
    el.formTab.appendChild(createNode("p", "muted", "当前分类没有文件，点击“新建”创建 JSON 文件。"));
    return;
  }

  const rootSchema = docRootSchema();
  const issues = validateRequired(state.document, rootSchema, rootSchema);
  if (issues.length > 0) {
    const box = createNode("div", "validation");
    box.textContent = `必填校验提醒（仅提示，不会阻止保存）:\n${issues.join("\n")}`;
    el.formTab.appendChild(box);
  }

  if (state.rootIsArray) {
    if (!Array.isArray(state.document) || state.document.length === 0) {
      el.formTab.appendChild(createNode("p", "muted", "当前数组为空，请先新增条目。"));
      return;
    }
    state.selectedIndex = Math.max(0, Math.min(state.selectedIndex, state.document.length - 1));
    const item = state.document[state.selectedIndex];
    el.formTab.appendChild(createNode("p", "muted", `正在编辑条目 #${state.selectedIndex}`));
    const field = buildFieldNode({
      keyName: `item[${state.selectedIndex}]`,
      path: ["$root", "[]"],
      focusPath: ["$root", `[${state.selectedIndex}]`],
      value: item,
      schema: state.schema,
      rootSchema,
      required: true,
      onChange: (next) => {
        state.document[state.selectedIndex] = next;
        updateDirty(true);
        renderPreservingEditorFocus();
      },
    });
    el.formTab.appendChild(field);
    return;
  }

  const field = buildFieldNode({
    keyName: "root",
    path: ["$root"],
    focusPath: ["$root"],
    value: state.document,
    schema: state.schema,
    rootSchema,
    required: true,
    onChange: (next) => {
      state.document = next;
      updateDirty(true);
      renderPreservingEditorFocus();
    },
  });
  el.formTab.appendChild(field);
}

function render() {
  renderSelectors();
  renderManifestForm();
  renderArrayPanel();
  renderEditorPanel();
  renderRawEditor();
  renderReferenceModal();
}

function openReferencePicker(kind, title, onPick) {
  state.refPicker.visible = true;
  state.refPicker.kind = kind;
  state.refPicker.title = title;
  state.refPicker.source = "remote";
  state.refPicker.page = 1;
  state.refPicker.query = "";
  state.refPicker.items = [];
  state.refPicker.staticItems = [];
  state.refPicker.total = 0;
  state.refPicker.onPick = onPick;
  fetchReferencePage();
}

function openStaticPicker(title, staticItems, onPick) {
  state.refPicker.visible = true;
  state.refPicker.kind = "__static__";
  state.refPicker.title = title;
  state.refPicker.source = "static";
  state.refPicker.page = 1;
  state.refPicker.query = "";
  state.refPicker.items = [];
  state.refPicker.staticItems = Array.isArray(staticItems) ? staticItems : [];
  state.refPicker.total = 0;
  state.refPicker.onPick = onPick;
  fetchReferencePage();
}

function closeReferencePicker() {
  state.refPicker.visible = false;
  state.refPicker.onPick = null;
  state.refPicker.source = "remote";
  state.refPicker.staticItems = [];
  renderReferenceModal();
}

function normalizeNewFileName(rawName) {
  let base = String(rawName || "").trim();
  if (!base) return "";
  if (base.toLowerCase().endsWith(".json")) {
    base = base.slice(0, -5).trim();
  }
  if (!base) return "";
  return `${base}.json`;
}

function openNewFileDialog() {
  if (!el.newFileMask || !el.newFileNameInput || !el.newFileRootType || !el.newFileRootHint) {
    setStatus("新建弹窗未初始化。", true);
    return;
  }
  const inherited = state.document != null;
  const rootType = inherited ? (Array.isArray(state.document) ? "array" : "object") : "array";
  el.newFileNameInput.value = "";
  el.newFileRootType.value = rootType;
  el.newFileRootType.disabled = inherited;
  el.newFileRootHint.textContent = inherited
    ? `根类型将沿用当前文件：${rootType}`
    : "可选择新文件根类型。";
  el.newFileMask.hidden = false;
  window.requestAnimationFrame(() => {
    el.newFileNameInput.focus();
  });
}

function closeNewFileDialog() {
  if (!el.newFileMask) return;
  el.newFileMask.hidden = true;
}

function filterStaticPickerRows(rows, query, page, pageSize) {
  const q = String(query || "").trim().toLowerCase();
  let filtered = rows;
  if (q) {
    filtered = rows.filter(
      (row) =>
        String(row.id || "")
          .toLowerCase()
          .includes(q) ||
        String(row.name || "")
          .toLowerCase()
          .includes(q)
    );
  }
  const total = filtered.length;
  const safePage = Math.max(1, Number(page || 1));
  const safePageSize = Math.max(1, Number(pageSize || 30));
  const start = (safePage - 1) * safePageSize;
  const end = start + safePageSize;
  return {
    total,
    items: filtered.slice(start, end),
  };
}

async function fetchReferencePage() {
  if (!state.refPicker.visible || !state.refPicker.kind) return;
  try {
    setStatus("正在加载列表...");
    if (state.refPicker.source === "static") {
      const result = filterStaticPickerRows(
        state.refPicker.staticItems,
        state.refPicker.query,
        state.refPicker.page,
        state.refPicker.pageSize
      );
      state.refPicker.total = result.total;
      state.refPicker.items = result.items;
      renderReferenceModal();
      setStatus("列表已更新。");
      return;
    }

    if (!state.selectedMod) return;
    const url =
      `/api/references?mod=${encodeURIComponent(state.selectedMod)}` +
      `&kind=${encodeURIComponent(state.refPicker.kind)}` +
      `&scope=before_and_self` +
      `&q=${encodeURIComponent(state.refPicker.query)}` +
      `&page=${state.refPicker.page}` +
      `&page_size=${state.refPicker.pageSize}`;
    const resp = await apiGet(url);
    state.refPicker.total = Number(resp.total || 0);
    state.refPicker.items = Array.isArray(resp.items) ? resp.items : [];
    renderReferenceModal();
    setStatus("列表已更新。");
  } catch (err) {
    setStatus(err.message, true);
  }
}

function primitiveInput({ value, schema, rootSchema, path, focusPath = [], onChange, contextTriggerId = "", contextEffectOp = "" }) {
  const node = createNode("div");
  const schemaTypeList = schemaTypes(schema);
  const types = schemaTypeList.length > 0 ? schemaTypeList : inferTypesFromValue(value);
  const enumValues = Array.isArray(schema.enum) ? schema.enum : null;
  const nullable = types.includes("null");
  const nonNullTypes = types.filter((x) => x !== "null");
  const activeType = value === null ? nonNullTypes[0] || "string" : nonNullTypes[0] || "string";
  const refKind = inferReferenceKind(path, state.selectedCategory);
  const fixedOptions = activeType === "string" ? fixedOptionsForField(path, contextEffectOp, contextTriggerId) : [];

  if (nullable) {
    const row = createNode("label", "row");
    const cb = document.createElement("input");
    cb.type = "checkbox";
    attachFocusKey(cb, focusPath, "null_toggle");
    cb.checked = value === null;
    cb.addEventListener("change", () => {
      if (cb.checked) {
        onChange(null);
      } else {
        onChange(defaultValueForSchema({ ...schema, type: activeType }, rootSchema));
      }
    });
    row.appendChild(cb);
    row.appendChild(createNode("span", "muted", "设为 null"));
    node.appendChild(row);
    if (value === null) return node;
  }

  if ((refKind === "trigger" || refKind === "effect_op") && activeType === "string") {
    const wrap = createNode("div", "inline-ref");
    const options = state.referenceCache[refKind] || [];
    const select = document.createElement("select");
    attachFocusKey(select, focusPath, "select");
    const currentValue = String(value == null ? "" : value);
    const hasCurrent = options.some((row) => String(row.id || "") === currentValue);

    if (!hasCurrent) {
      const currentOption = document.createElement("option");
      currentOption.value = currentValue;
      currentOption.textContent = currentValue || "(空)";
      currentOption.selected = true;
      select.appendChild(currentOption);
    }
    options.forEach((row) => {
      const op = document.createElement("option");
      op.value = String(row.id || "");
      const label = String(row.name || row.id || "");
      op.textContent = label && label !== String(row.id || "") ? String(row.id || "") + " | " + label : String(row.id || "");
      if (String(row.id || "") === currentValue) op.selected = true;
      select.appendChild(op);
    });
    select.addEventListener("change", () => onChange(select.value));
    wrap.appendChild(select);

    const btn = createNode("button", "", "列表选择");
    btn.type = "button";
    btn.addEventListener("click", () => {
      openReferencePicker(refKind, refKind + " 引用选择", (pickedId) => onChange(String(pickedId)));
    });
    wrap.appendChild(btn);
    node.appendChild(wrap);
    return node;
  }

  if (enumValues && enumValues.length > 0) {
    const wrap = createNode("div", "inline-ref");
    const select = document.createElement("select");
    attachFocusKey(select, focusPath, "select");
    enumValues.forEach((optionValue) => {
      const op = document.createElement("option");
      op.value = String(optionValue);
      op.textContent = String(optionValue);
      if (String(value) === String(optionValue)) op.selected = true;
      select.appendChild(op);
    });
    select.addEventListener("change", () => onChange(select.value));
    wrap.appendChild(select);

    if (refKind && refKind !== "trigger" && refKind !== "effect_op") {
      const btn = createNode("button", "", "列表选择");
      btn.type = "button";
      btn.addEventListener("click", () => {
        openReferencePicker(refKind, refKind + " 引用选择", (pickedId) => onChange(String(pickedId)));
      });
      wrap.appendChild(btn);
    }
    node.appendChild(wrap);
    return node;
  }

  if (activeType === "string" && fixedOptions.length > 0) {
    const wrap = createNode("div", "inline-ref");
    const select = document.createElement("select");
    attachFocusKey(select, focusPath, "select");
    const currentValue = String(value == null ? "" : value);
    const hasCurrent = fixedOptions.some((row) => String(row.value) === currentValue);

    if (!hasCurrent) {
      const fallbackOption = document.createElement("option");
      fallbackOption.value = currentValue;
      fallbackOption.textContent = currentValue ? currentValue + " | 当前值(未定义)" : "(空)";
      fallbackOption.selected = true;
      select.appendChild(fallbackOption);
    }
    fixedOptions.forEach((row) => {
      const op = document.createElement("option");
      op.value = String(row.value);
      const label = String(row.label || row.value);
      op.textContent = String(row.value) + " | " + label;
      if (String(row.value) === currentValue) op.selected = true;
      select.appendChild(op);
    });
    select.addEventListener("change", () => onChange(select.value));
    wrap.appendChild(select);
    node.appendChild(wrap);

    const guide = optionSummaryText(fixedOptions);
    if (guide) node.appendChild(createNode("div", "muted", guide));
    return node;
  }

  if (activeType === "boolean") {
    const row = createNode("label", "row");
    const cb = document.createElement("input");
    cb.type = "checkbox";
    attachFocusKey(cb, focusPath, "checkbox");
    cb.checked = Boolean(value);
    cb.addEventListener("change", () => onChange(cb.checked));
    row.appendChild(cb);
    row.appendChild(createNode("span", "", "true / false"));
    node.appendChild(row);
    return node;
  }

  if (activeType === "integer" || activeType === "number") {
    const input = document.createElement("input");
    input.type = "number";
    attachFocusKey(input, focusPath, "input");
    input.step = activeType === "integer" ? "1" : "any";
    if (typeof schema.minimum === "number") input.min = String(schema.minimum);
    if (typeof schema.maximum === "number") input.max = String(schema.maximum);
    input.value = value == null ? "" : String(value);
    input.addEventListener("input", () => {
      const raw = input.value.trim();
      if (!raw) {
        onChange(0);
        return;
      }
      const num = activeType === "integer" ? parseInt(raw, 10) : parseFloat(raw);
      onChange(Number.isNaN(num) ? 0 : num);
    });
    node.appendChild(input);
    return node;
  }

  const wrap = createNode("div", "inline-ref");
  const input = document.createElement("input");
  input.type = "text";
  attachFocusKey(input, focusPath, "input");
  input.value = value == null ? "" : String(value);
  let composing = false;
  let lastEmittedValue = input.value;
  const emitIfChanged = () => {
    const nextValue = input.value;
    if (nextValue === lastEmittedValue) return;
    lastEmittedValue = nextValue;
    onChange(nextValue);
  };
  input.addEventListener("compositionstart", () => {
    composing = true;
  });
  input.addEventListener("compositionend", () => {
    composing = false;
    emitIfChanged();
  });
  input.addEventListener("input", (ev) => {
    if (composing || ev.isComposing) return;
    emitIfChanged();
  });
  wrap.appendChild(input);

  if (refKind && refKind !== "trigger" && refKind !== "effect_op") {
    const btn = createNode("button", "", "列表选择");
    btn.type = "button";
    btn.addEventListener("click", () => {
      openReferencePicker(refKind, refKind + " 引用选择", (pickedId) => onChange(String(pickedId)));
    });
    wrap.appendChild(btn);
  }
  node.appendChild(wrap);
  return node;
}

function buildFieldNode({
  keyName,
  path,
  focusPath = [],
  value,
  schema: rawSchema,
  rootSchema,
  required,
  onChange,
  parentValue = null,
  contextTriggerId = "",
  contextEffectOp = "",
}) {
  const schema = effectiveSchema(rawSchema, rootSchema);
  const typeList = schemaTypes(schema);
  const types = typeList.length > 0 ? typeList : inferTypesFromValue(value);
  const node = createNode("div", "field");

  const label = createNode("div", "label");
  label.appendChild(createNode("span", "", keyName));
  if (required) label.appendChild(createNode("span", "required", "*"));
  if (schema.type) {
    const t = Array.isArray(schema.type) ? schema.type.join("|") : schema.type;
    label.appendChild(createNode("span", "badge", t));
  }
  node.appendChild(label);

  const hintText = contextualFieldHint({
    keyName,
    path,
    contextTriggerId,
    contextEffectOp,
  });
  const descParts = [];
  if (schema.description) descParts.push(schema.description);
  if (hintText && hintText !== schema.description) descParts.push(hintText);
  if (descParts.length > 0) node.appendChild(createNode("div", "muted", descParts.join(" | ")));

  if (types.includes("object")) {
    node.appendChild(
      objectEditor({
        value: isObject(value) ? value : {},
        schema,
        rootSchema,
        path,
        focusPath,
        onChange,
        parentValue,
        contextTriggerId,
        contextEffectOp,
      })
    );
    return node;
  }

  if (types.includes("array")) {
    node.appendChild(
      arrayEditor({
        value: Array.isArray(value) ? value : [],
        schema,
        rootSchema,
        path,
        focusPath,
        onChange,
        parentValue,
        contextTriggerId,
        contextEffectOp,
      })
    );
    return node;
  }

  node.appendChild(
    primitiveInput({
      value,
      schema,
      rootSchema,
      path,
      focusPath,
      onChange,
      contextTriggerId,
      contextEffectOp,
    })
  );
  return node;
}

function objectEditor({
  value,
  schema,
  rootSchema,
  path,
  focusPath = [],
  onChange,
  parentValue = null,
  contextTriggerId = "",
  contextEffectOp = "",
}) {
  const box = createNode("div", "object-box");
  const requiredSet = new Set(Array.isArray(schema.required) ? schema.required : []);
  const props = isObject(schema.properties) ? schema.properties : {};

  const inlineEffectOp = isUnderEffectTree(path) ? resolveEffectOpFromObject(value) : "";
  const localEffectOp = inlineEffectOp || contextEffectOp;
  const localTriggerId = resolveTriggerIdForPath(path, value, parentValue, contextTriggerId);

  if (isTriggerParamsPath(path)) {
    const triggerId = String(localTriggerId || "").trim();
    const triggerName = triggerLabel(triggerId) || triggerId || "未选择";
    const triggerDesc =
      TRIGGER_DESCRIPTIONS[triggerId] || "请先在上方选择 trigger，随后在这里配置对应 trigger_params。";
    box.appendChild(createNode("div", "muted", `当前触发器：${triggerName} | ${triggerDesc}`));
    const hintKeys = Object.keys(triggerParamHints(triggerId));
    if (hintKeys.length > 0) {
      box.appendChild(createNode("div", "muted", `可配置参数：${hintKeys.join("、")}`));
    }
  }

  Object.keys(props).forEach((key) => {
    const childSchema = props[key];
    const childValue = Object.prototype.hasOwnProperty.call(value, key)
      ? value[key]
      : defaultValueForSchema(childSchema, rootSchema);
    box.appendChild(
      buildFieldNode({
        keyName: key,
        path: [...path, key],
        focusPath: [...focusPath, key],
        value: childValue,
        schema: childSchema,
        rootSchema,
        required: requiredSet.has(key),
        onChange: (next) => {
          const clone = { ...value, [key]: next };
          onChange(clone);
        },
        parentValue: value,
        contextTriggerId:
          localTriggerId ||
          (key === "trigger" && isObject(childValue) ? resolveTriggerIdFromCarrier(childValue) : "") ||
          (key === "trigger" || key === "type" ? String(childValue || "").trim() : ""),
        contextEffectOp: key === "op" ? String(childValue || "") : localEffectOp,
      })
    );
  });

  const additionalSchema = schema.additionalProperties;
  const extras = Object.keys(value).filter((k) => !Object.prototype.hasOwnProperty.call(props, k));
  extras.forEach((key) => {
    const childSchema = isObject(additionalSchema) ? additionalSchema : {};
    const field = buildFieldNode({
      keyName: key,
      path: [...path, key],
      focusPath: [...focusPath, key],
      value: value[key],
      schema: childSchema,
      rootSchema,
      required: false,
      onChange: (next) => {
        const clone = { ...value, [key]: next };
        onChange(clone);
      },
      parentValue: value,
      contextTriggerId: localTriggerId,
      contextEffectOp: localEffectOp,
    });
    const actions = createNode("div", "field-actions");
    const removeBtn = createNode("button", "danger", "删除字段");
    removeBtn.type = "button";
    removeBtn.addEventListener("click", () => {
      const clone = { ...value };
      delete clone[key];
      onChange(clone);
    });
    actions.appendChild(removeBtn);
    field.appendChild(actions);
    box.appendChild(field);
  });

  if (additionalSchema !== false) {
    const actions = createNode("div", "field-actions");
    const addBtn = createNode("button", "", "新增字段");
    addBtn.type = "button";
    addBtn.addEventListener("click", async () => {
      const fallbackSchema = isObject(additionalSchema) ? additionalSchema : {};
      const effectiveEffectOp = resolveEffectOpFromObject(value, localEffectOp);

      if (isEffectObjectPath(path) && !effectiveEffectOp) {
        openReferencePicker("effect_op", "Effect OP 选择", (pickedId) => {
          const clone = { ...value, op: String(pickedId) };
          onChange(clone);
        });
        return;
      }

      if (isTriggerParamsPath(path)) {
        if (!String(localTriggerId || "").trim()) {
          setStatus("请先选择 trigger，再配置 trigger_params。", true);
          return;
        }
        const candidates = triggerParamCandidates(localTriggerId, value);
        if (candidates.length > 0) {
          openStaticPicker("trigger_params 参数选择", candidates, (pickedKey) => {
            const key = String(pickedKey || "").trim();
            if (!key) return;
            if (Object.prototype.hasOwnProperty.call(value, key)) {
              setStatus(`字段已存在: ${key}`, true);
              return;
            }
            const clone = { ...value };
            clone[key] = defaultValueByFieldKey(key);
            onChange(clone);
          });
          return;
        }
        setStatus("当前触发器参数已全部添加。", true);
        return;
      }

      if (effectiveEffectOp) {
        const dynamicRows = await loadEffectParamRows(effectiveEffectOp);
        const dynamicKeys = dynamicRows
          .map((row) => String(row.id || "").trim())
          .filter((x) => x.length > 0);
        const candidates = effectParamCandidates(effectiveEffectOp, value, path, dynamicKeys);
        if (candidates.length > 0) {
          openStaticPicker(`${effectiveEffectOp} 参数选择`, candidates, (pickedKey) => {
            const key = String(pickedKey || "").trim();
            if (!key) return;
            if (Object.prototype.hasOwnProperty.call(value, key)) {
              setStatus(`字段已存在: ${key}`, true);
              return;
            }
            const clone = { ...value };
            clone[key] = defaultValueByFieldKey(key);
            onChange(clone);
          });
          return;
        }
        setStatus(`特效 ${effectiveEffectOp} 暂无可添加参数（可能该 op 只需 op 本身）。`, true);
        return;
      }

      const objectCandidates = objectFieldCandidates(path, value);
      if (objectCandidates.length > 0) {
        openStaticPicker("固定字段选择", objectCandidates, (pickedKey) => {
          const key = String(pickedKey || "").trim();
          if (!key) return;
          if (Object.prototype.hasOwnProperty.call(value, key)) {
            setStatus(`字段已存在: ${key}`, true);
            return;
          }
          const clone = { ...value };
          clone[key] = defaultValueByFieldKey(key);
          onChange(clone);
        });
        return;
      }

      if (isUnderEffectTree(path)) {
        setStatus("该位置字段受特效定义约束，请先选择 op，并从固定参数列表添加。", true);
        return;
      }

      const key = window.prompt("请输入字段名");
      if (!key) return;
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        setStatus(`字段已存在: ${key}`, true);
        return;
      }
      const clone = { ...value };
      clone[key] = defaultValueForSchema(fallbackSchema, rootSchema);
      onChange(clone);
    });
    actions.appendChild(addBtn);
    box.appendChild(actions);
  }
  return box;
}

function arrayEditor({
  value,
  schema,
  rootSchema,
  path,
  focusPath = [],
  onChange,
  parentValue = null,
  contextTriggerId = "",
  contextEffectOp = "",
}) {
  const box = createNode("div", "array-box");
  const itemSchema = schema.items || {};
  const itemRefKind = inferReferenceKind([...path, "[]"], state.selectedCategory);
  const itemTypeList = schemaTypes(effectiveSchema(itemSchema, rootSchema));
  const itemTypes = itemTypeList.length > 0 ? itemTypeList : inferTypesFromValue(value[0]);
  const itemFixedOptions = fixedOptionsForField([...path, "[]"], contextEffectOp, contextTriggerId);
  const effectArray = isEffectArrayPath(path);
  const linkageQueriesArray = isLinkageQueriesArrayPath(path);
  const linkageCasesArray = isLinkageCasesArrayPath(path);

  value.forEach((item, index) => {
    const field = buildFieldNode({
      keyName: `[${index}]`,
      path: [...path, "[]"],
      focusPath: [...focusPath, `[${index}]`],
      value: item,
      schema: itemSchema,
      rootSchema,
      required: false,
      onChange: (next) => {
        const clone = value.slice();
        clone[index] = next;
        onChange(clone);
      },
      parentValue: value,
      contextTriggerId,
      contextEffectOp,
    });
    const actions = createNode("div", "field-actions");
    const removeBtn = createNode("button", "danger", "删除");
    removeBtn.type = "button";
    removeBtn.addEventListener("click", () => {
      const clone = value.slice();
      clone.splice(index, 1);
      onChange(clone);
    });
    actions.appendChild(removeBtn);

    const cloneBtn = createNode("button", "", "克隆");
    cloneBtn.type = "button";
    cloneBtn.addEventListener("click", () => {
      const clone = value.slice();
      clone.splice(index + 1, 0, deepClone(item));
      onChange(clone);
    });
    actions.appendChild(cloneBtn);
    field.appendChild(actions);
    box.appendChild(field);
  });

  const actions = createNode("div", "field-actions");
  let addBtnText = "新增项";
  if (effectArray) {
    addBtnText = "新增 Effect（选择op）";
  } else if (linkageQueriesArray) {
    addBtnText = "新增 query";
  } else if (linkageCasesArray) {
    addBtnText = "新增 case";
  }
  const addBtn = createNode("button", "", addBtnText);
  addBtn.type = "button";
  addBtn.addEventListener("click", () => {
    const clone = value.slice();
    if (effectArray) {
      openReferencePicker("effect_op", "Effect OP 选择", (pickedId) => {
        const nextClone = value.slice();
        nextClone.push({ op: String(pickedId) });
        onChange(nextClone);
      });
      return;
    }
    if (linkageQueriesArray) {
      clone.push({});
      onChange(clone);
      return;
    }
    if (linkageCasesArray) {
      clone.push({ effects: [] });
      onChange(clone);
      return;
    }
    if (itemTypes.includes("string") && itemFixedOptions.length > 0) {
      const currentSet = new Set(clone.map((x) => String(x)));
      const firstAvailable = itemFixedOptions.find((x) => !currentSet.has(String(x.value)));
      clone.push(String((firstAvailable || itemFixedOptions[0]).value));
    } else {
      clone.push(defaultValueForSchema(itemSchema, rootSchema));
    }
    onChange(clone);
  });
  actions.appendChild(addBtn);

  if (itemRefKind && itemTypes.includes("string")) {
    const pickerBtn = createNode("button", "", "从引用列表添加");
    pickerBtn.type = "button";
    pickerBtn.addEventListener("click", () => {
      openReferencePicker(itemRefKind, `${itemRefKind} 引用选择`, (pickedId) => {
        const clone = value.slice();
        clone.push(String(pickedId));
        onChange(clone);
      });
    });
    actions.appendChild(pickerBtn);
  }

  if (itemTypes.includes("string") && itemFixedOptions.length > 0) {
    const fixedBtn = createNode("button", "", "从固定选项添加");
    fixedBtn.type = "button";
    fixedBtn.addEventListener("click", () => {
      const existing = new Set(value.map((x) => String(x)));
      const candidates = itemFixedOptions
        .filter((row) => !existing.has(String(row.value)))
        .map((row) => ({
          id: String(row.value),
          name: `${row.label || row.value}${row.desc ? ` - ${row.desc}` : ""}`,
          mod: "builtin",
          load_order: "-",
          file: "options",
        }));
      if (candidates.length === 0) {
        setStatus("固定选项已全部添加。", true);
        return;
      }
      openStaticPicker("固定选项选择", candidates, (pickedId) => {
        const clone = value.slice();
        clone.push(String(pickedId));
        onChange(clone);
      });
    });
    actions.appendChild(fixedBtn);
  }
  box.appendChild(actions);
  return box;
}
async function loadBootstrap() {
  const resp = await apiGet("/api/bootstrap");
  state.mods = Array.isArray(resp.mods) ? resp.mods : [];
  state.categories = Array.isArray(resp.categories) ? resp.categories : [];
  sortModsInPlace();

  if (!state.selectedMod && state.mods.length > 0) {
    state.selectedMod = String(state.mods[0].folder || state.mods[0].id || "");
  }
  if (!state.selectedCategory && state.categories.length > 0) {
    state.selectedCategory = String(state.categories[0].id || "");
  }
}

async function loadFilesForSelection() {
  if (!state.selectedMod || !state.selectedCategory) {
    state.files = [];
    state.selectedFile = "";
    return;
  }
  const resp = await apiGet(
    `/api/files?mod=${encodeURIComponent(state.selectedMod)}&category=${encodeURIComponent(state.selectedCategory)}`
  );
  state.files = Array.isArray(resp.files) ? resp.files : [];
  if (!state.files.includes(state.selectedFile)) {
    state.selectedFile = state.files[0] || "";
  }
}

async function loadSchemaAndDocument() {
  if (!state.selectedCategory || !state.selectedMod) {
    state.schema = null;
    state.document = null;
    state.rootIsArray = false;
    return;
  }
  const schemaResp = await apiGet(`/api/schema?category=${encodeURIComponent(state.selectedCategory)}`);
  state.schema = schemaResp.schema;

  if (!state.selectedFile) {
    state.document = null;
    state.rootIsArray = false;
    state.selectedIndex = 0;
    return;
  }
  const docResp = await apiGet(
    `/api/document?mod=${encodeURIComponent(state.selectedMod)}&category=${encodeURIComponent(
      state.selectedCategory
    )}&file=${encodeURIComponent(state.selectedFile)}`
  );
  state.document = docResp.document;
  state.rootIsArray = Array.isArray(state.document);
  if (state.rootIsArray && Array.isArray(state.document) && state.document.length === 0) {
    state.document.push(defaultValueForSchema(state.schema, state.schema));
  }
  state.selectedIndex = 0;
}

async function loadManifest() {
  if (!state.selectedMod) {
    state.manifest = null;
    return;
  }
  const resp = await apiGet(`/api/mod_manifest?mod=${encodeURIComponent(state.selectedMod)}`);
  state.manifest = isObject(resp.manifest) ? resp.manifest : {};
}

async function refreshReferenceCache() {
  if (!state.selectedMod) {
    state.referenceCache.trigger = [];
    state.referenceCache.effect_op = [];
    return;
  }
  const kinds = ["trigger", "effect_op"];
  const requests = kinds.map(async (kind) => {
    try {
      const resp = await apiGet(
        `/api/references?mod=${encodeURIComponent(state.selectedMod)}` +
          `&kind=${encodeURIComponent(kind)}` +
          `&scope=before_and_self` +
          `&q=` +
          `&page=1&page_size=1000`
      );
      state.referenceCache[kind] = Array.isArray(resp.items) ? resp.items : [];
    } catch (_err) {
      state.referenceCache[kind] = [];
    }
  });
  await Promise.all(requests);
}

async function reloadAll() {
  try {
    setStatus("正在加载数据...");
    state.effectParamCache = {};
    await loadBootstrap();
    await loadFilesForSelection();
    await Promise.all([loadSchemaAndDocument(), loadManifest(), refreshReferenceCache()]);
    updateDirty(false);
    render();
    setStatus("加载完成。");
  } catch (err) {
    setStatus(err.message, true);
  }
}

async function onModChanged() {
  try {
    state.selectedMod = el.modSelect.value;
    state.effectParamCache = {};
    await loadFilesForSelection();
    await Promise.all([loadSchemaAndDocument(), loadManifest(), refreshReferenceCache()]);
    updateDirty(false);
    render();
    setStatus("已切换 Mod。");
  } catch (err) {
    setStatus(err.message, true);
  }
}

async function onCategoryChanged() {
  try {
    state.selectedCategory = el.categorySelect.value;
    await loadFilesForSelection();
    await loadSchemaAndDocument();
    updateDirty(false);
    render();
    setStatus("已切换分类。");
  } catch (err) {
    setStatus(err.message, true);
  }
}

async function onFileChanged() {
  try {
    state.selectedFile = el.fileSelect.value;
    await loadSchemaAndDocument();
    updateDirty(false);
    render();
    setStatus("已切换文件。");
  } catch (err) {
    setStatus(err.message, true);
  }
}

async function onSaveDocument() {
  if (!state.selectedMod || !state.selectedCategory || !state.selectedFile) {
    setStatus("请先选择要保存的文件。", true);
    return;
  }
  try {
    setStatus("正在保存数据...");
    await apiPost("/api/document", {
      mod: state.selectedMod,
      category: state.selectedCategory,
      file: state.selectedFile,
      document: state.document,
    });
    updateDirty(false);
    setStatus("数据已保存。");
  } catch (err) {
    setStatus(err.message, true);
  }
}

async function onNewFile() {
  if (!state.selectedMod || !state.selectedCategory || !state.schema) {
    setStatus("请先选择 Mod 和分类。", true);
    return;
  }
  openNewFileDialog();
}

async function onConfirmNewFileDialog() {
  if (!el.newFileNameInput || !el.newFileRootType) {
    setStatus("新建弹窗未初始化。", true);
    return;
  }
  const fileName = normalizeNewFileName(el.newFileNameInput.value);
  if (!fileName) {
    setStatus("请输入文件名。", true);
    el.newFileNameInput.focus();
    return;
  }

  try {
    const rootIsArray = el.newFileRootType.value !== "object";
    const root = rootIsArray
      ? [defaultValueForSchema(state.schema, state.schema)]
      : defaultValueForSchema(state.schema, state.schema);

    setStatus("正在创建文件...");
    await apiPost("/api/document", {
      mod: state.selectedMod,
      category: state.selectedCategory,
      file: fileName,
      document: root,
    });
    closeNewFileDialog();
    state.selectedFile = fileName;
    await loadFilesForSelection();
    await loadSchemaAndDocument();
    updateDirty(false);
    render();
    setStatus(`已创建文件: ${fileName}`);
  } catch (err) {
    setStatus(err.message, true);
  }
}

async function onDeleteFile() {
  if (!state.selectedMod || !state.selectedCategory || !state.selectedFile) {
    setStatus("请先选择要删除的文件。", true);
    return;
  }
  const fileName = String(state.selectedFile || "");
  const ok = window.confirm(`确定删除文件 ${fileName} ? 此操作不可恢复。`);
  if (!ok) return;

  try {
    setStatus("正在删除文件...");
    await apiPost("/api/document_delete", {
      mod: state.selectedMod,
      category: state.selectedCategory,
      file: fileName,
    });
    await loadFilesForSelection();
    await loadSchemaAndDocument();
    updateDirty(false);
    render();
    setStatus(`已删除文件: ${fileName}`);
  } catch (err) {
    setStatus(err.message, true);
  }
}

async function onSaveManifest() {
  if (!state.selectedMod) {
    setStatus("请先选择 Mod。", true);
    return;
  }
  try {
    const manifest = collectManifestFromForm();
    setStatus("正在保存 Mod 信息...");
    await apiPost("/api/mod_manifest", {
      mod: state.selectedMod,
      manifest,
    });
    await loadBootstrap();
    await loadManifest();
    sortModsInPlace();
    render();
    setStatus("Mod 信息已保存。");
  } catch (err) {
    setStatus(err.message, true);
  }
}

function bindEvents() {
  el.reloadBtn.addEventListener("click", reloadAll);
  el.saveBtn.addEventListener("click", onSaveDocument);
  el.modSelect.addEventListener("change", onModChanged);
  el.categorySelect.addEventListener("change", onCategoryChanged);
  el.fileSelect.addEventListener("change", onFileChanged);
  el.newFileBtn.addEventListener("click", onNewFile);
  if (el.deleteFileBtn) {
    el.deleteFileBtn.addEventListener("click", onDeleteFile);
  }
  if (el.newFileConfirmBtn) {
    el.newFileConfirmBtn.addEventListener("click", onConfirmNewFileDialog);
  }
  if (el.newFileCancelBtn) {
    el.newFileCancelBtn.addEventListener("click", closeNewFileDialog);
  }
  if (el.newFileNameInput) {
    el.newFileNameInput.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.preventDefault();
        onConfirmNewFileDialog();
      } else if (ev.key === "Escape") {
        closeNewFileDialog();
      }
    });
  }
  if (el.newFileMask) {
    el.newFileMask.addEventListener("click", (ev) => {
      if (ev.target === el.newFileMask) closeNewFileDialog();
    });
  }

  el.formTabBtn.addEventListener("click", () => setTab("form"));
  el.rawTabBtn.addEventListener("click", () => setTab("raw"));

  el.formatRawBtn.addEventListener("click", () => {
    try {
      const parsed = JSON.parse(el.rawEditor.value);
      el.rawEditor.value = JSON.stringify(parsed, null, 2);
      setStatus("JSON 已格式化。");
    } catch (err) {
      setStatus(`JSON 解析失败: ${err.message}`, true);
    }
  });
  el.applyRawBtn.addEventListener("click", applyRawToDocument);

  el.addItemBtn.addEventListener("click", () => {
    if (!Array.isArray(state.document)) return;
    state.document.push(defaultValueForSchema(state.schema, state.schema));
    state.selectedIndex = state.document.length - 1;
    updateDirty(true);
    render();
  });
  el.cloneItemBtn.addEventListener("click", () => {
    if (!Array.isArray(state.document) || state.document.length === 0) return;
    const src = state.document[state.selectedIndex] ?? state.document[0];
    state.document.splice(state.selectedIndex + 1, 0, deepClone(src));
    state.selectedIndex += 1;
    updateDirty(true);
    render();
  });
  el.removeItemBtn.addEventListener("click", () => {
    if (!Array.isArray(state.document) || state.document.length === 0) return;
    const ok = window.confirm(`确定删除当前条目 #${state.selectedIndex} ?`);
    if (!ok) return;
    state.document.splice(state.selectedIndex, 1);
    state.selectedIndex = Math.max(0, Math.min(state.selectedIndex, state.document.length - 1));
    updateDirty(true);
    render();
  });
  el.itemList.addEventListener("click", (ev) => {
    const target = ev.target;
    if (!(target instanceof HTMLElement)) return;
    const idx = target.getAttribute("data-index");
    if (idx == null) return;
    const next = Number(idx);
    if (!Number.isNaN(next)) {
      state.selectedIndex = next;
      render();
    }
  });

  el.reloadManifestBtn.addEventListener("click", async () => {
    try {
      await loadManifest();
      renderManifestForm();
      setStatus("Mod 信息已重载。");
    } catch (err) {
      setStatus(err.message, true);
    }
  });
  el.saveManifestBtn.addEventListener("click", onSaveManifest);

  el.refPickerCloseBtn.addEventListener("click", closeReferencePicker);
  el.refSearchBtn.addEventListener("click", async () => {
    state.refPicker.page = 1;
    state.refPicker.query = el.refSearchInput.value.trim();
    await fetchReferencePage();
  });
  el.refSearchInput.addEventListener("keydown", async (ev) => {
    if (ev.key === "Enter") {
      state.refPicker.page = 1;
      state.refPicker.query = el.refSearchInput.value.trim();
      await fetchReferencePage();
    }
  });
  el.refPrevBtn.addEventListener("click", async () => {
    if (state.refPicker.page <= 1) return;
    state.refPicker.page -= 1;
    await fetchReferencePage();
  });
  el.refNextBtn.addEventListener("click", async () => {
    if (state.refPicker.page * state.refPicker.pageSize >= state.refPicker.total) return;
    state.refPicker.page += 1;
    await fetchReferencePage();
  });
  el.refList.addEventListener("click", (ev) => {
    const target = ev.target;
    if (!(target instanceof HTMLElement)) return;
    const button = target.closest(".ref-entry");
    if (!(button instanceof HTMLElement)) return;
    const pickedId = button.getAttribute("data-ref-id");
    if (!pickedId) return;
    if (typeof state.refPicker.onPick === "function") {
      state.refPicker.onPick(pickedId);
    }
    closeReferencePicker();
    setStatus(`已选择引用: ${pickedId}`);
  });
  el.refPickerMask.addEventListener("click", (ev) => {
    if (ev.target === el.refPickerMask) closeReferencePicker();
  });

  window.addEventListener("beforeunload", (ev) => {
    if (!state.dirty) return;
    ev.preventDefault();
    ev.returnValue = "";
  });
}

async function start() {
  bindEvents();
  closeReferencePicker();
  await reloadAll();
}

start();
