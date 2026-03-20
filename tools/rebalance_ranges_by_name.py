#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按“单位名/功法名关键词”批量重设攻击与施法射程。

用法：
    py tools/rebalance_ranges_by_name.py

说明：
1. 单位射程写入 data/units/units_batch_m1.json 的 base_stats.rng。
2. 功法施法距离写入 data/gongfa/gongfa_batch_m3.json 的 skill.range（单位：格）。
3. 规则优先级：名称关键词 > 角色/类型默认值。
4. 仅做数据改写，不改数值公式；实际判定由 GDScript 运行时执行。
"""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
UNITS_PATH = ROOT / "data" / "units" / "units_batch_m1.json"
GONGFA_PATH = ROOT / "data" / "gongfa" / "gongfa_batch_m3.json"

# ===========================
# 射程规则表（可持续扩展）
# ===========================
# 说明：
# 1) 门派规则用于“默认倾向”，不直接覆盖名称强信号。
# 2) 流派规则用于“兵器/招式关键词”，优先级高于门派。
# 3) 所有结果最终会被 clamp 到安全区间。

# 单位：按角色职业给基础盘。
UNIT_ROLE_BASE_RANGE = {
    "vanguard": 1,
    "swordsman": 1,
    "assassin": 1,
    "leader": 2,
    "healer": 3,
    "caster": 3,
    "archer": 4,
}

# 单位：门派偏置（相对职业基础值）。
# 唐门预留为高远程门派；少林/丐帮默认更近战。
UNIT_FACTION_RANGE_BONUS = {
    "tangmen": 1,
    "xingxiu": 1,
    "emei": 1,
    "wudang": 0,
    "huashan": 0,
    "xiaoyao": 0,
    "quanzhen": 0,
    "mingjiao": 0,
    "dalun": 0,
    "gumu": 0,
    "shenlong": 0,
    "none": 0,
    "shaolin": -1,
    "gaibang": -1,
}

# 单位：名称中的“兵器/职业流派”关键字。
UNIT_STYLE_RULES = [
    # 远程强信号
    (["飞镖队", "暗器手", "神射", "弩手", "弓手", "箭手"], 5),
    (["飞镖", "暗器", "弓", "箭", "弩", "镖"], 4),
    # 中远程功能位
    (["奇术师", "术师", "法师", "方士", "医者", "医仙", "毒师", "琴师", "笛师"], 3),
]

# 功法：类型基础射程（格）。
GONGFA_TYPE_BASE_RANGE = {
    "waigong": 2.0,
    "neigong": 3.0,
    "qishu": 4.0,
    "zhenfa": 4.0,
    "qinggong": 1.0,
}

# 功法：门派偏置（相对类型基础值）。
GONGFA_FACTION_RANGE_BONUS = {
    "tangmen": 1.5,  # 唐门默认更远
    "xingxiu": 0.5,
    "emei": 0.5,
    "shaolin": -0.5,
    "gaibang": -0.5,
}

# 功法：流派表（关键词 -> 最小/最大射程约束）。
# 采用“下限/上限”组合，既能拉远远程流派，也能压近掌法拳法。
GONGFA_STYLE_MIN_RANGE = [
    (["六脉", "一阳指", "弹指", "生死符", "火焰刀", "白虹", "剑气", "飞刀"], 5.0),
    (["指", "符", "暗器", "飞", "气"], 4.0),
]
GONGFA_STYLE_MAX_RANGE = [
    (["掌", "拳", "爪", "手", "棒"], 2.0),  # 掌法/拳法默认更近
]


def _contains_any(text: str, keywords: list[str]) -> bool:
    return any(k in text for k in keywords)


def infer_unit_range(unit: dict[str, Any]) -> int:
    name = str(unit.get("name", ""))
    role = str(unit.get("role", "")).strip().lower()
    faction = str(unit.get("faction", "")).strip().lower()

    # 第1层：职业基础。
    rng = int(UNIT_ROLE_BASE_RANGE.get(role, 2))

    # 第2层：门派偏置。
    rng += int(UNIT_FACTION_RANGE_BONUS.get(faction, 0))

    # 第3层：流派关键词（兵器/职业标签），以最小射程拉高功能位。
    for keywords, min_rng in UNIT_STYLE_RULES:
        if _contains_any(name, keywords):
            rng = max(rng, min_rng)

    # 第4层：强近战关键词。仅在没有明显远程关键词时收敛到近战。
    has_ranged_keyword = _contains_any(name, ["飞镖", "暗器", "弓", "箭", "弩", "镖", "奇术师", "术师", "法师", "医者"])
    if (not has_ranged_keyword) and _contains_any(name, ["刺客", "飞贼", "剑客", "刀客", "力士", "拳师", "棍僧"]):
        rng = min(rng, 1)

    return max(1, min(6, rng))


def _has_enemy_target_effect(skill_effects: list[Any]) -> bool:
    enemy_target_ops = {
        "damage_target",
        "debuff_target",
        "teleport_behind",
        "dash_forward",
        "knockback_target",
    }
    for effect in skill_effects:
        if isinstance(effect, dict) and str(effect.get("op", "")) in enemy_target_ops:
            return True
    return False


def infer_gongfa_range(gongfa: dict[str, Any]) -> float:
    name = str(gongfa.get("name", ""))
    gongfa_type = str(gongfa.get("type", "")).strip().lower()
    faction = str(gongfa.get("faction", "")).strip().lower()
    tags = [str(t) for t in gongfa.get("tags", []) if isinstance(t, (str, int, float))]
    skill = gongfa.get("skill", {}) if isinstance(gongfa.get("skill", {}), dict) else {}
    trigger = str(skill.get("trigger", "")).strip().lower()
    effects = skill.get("effects", []) if isinstance(skill.get("effects", []), list) else []

    # 第1层：类型基础射程。
    cast_range = float(GONGFA_TYPE_BASE_RANGE.get(gongfa_type, 2.0))

    # 第2层：门派偏置。
    cast_range += float(GONGFA_FACTION_RANGE_BONUS.get(faction, 0.0))

    # 第3层：tag 语义补充（远程倾向）。
    if any(t in {"ranged", "finger", "hidden"} for t in tags):
        cast_range = max(cast_range, 4.0)

    # 第4层：兵器/招式流派表。
    # 先应用远程下限，再视情况应用近战上限。
    for keywords, min_range in GONGFA_STYLE_MIN_RANGE:
        if _contains_any(name, keywords):
            cast_range = max(cast_range, min_range)

    has_ranged_signal = any(t in {"ranged", "finger", "hidden"} for t in tags) or _contains_any(
        name, ["六脉", "一阳指", "弹指", "生死符", "火焰刀", "白虹", "剑气", "飞刀"]
    )
    if not has_ranged_signal:
        for keywords, max_range in GONGFA_STYLE_MAX_RANGE:
            if _contains_any(name, keywords):
                cast_range = min(cast_range, max_range)

    # 第5层：反击触发一般属于近身博弈。
    if trigger == "on_attacked" and not has_ranged_signal:
        cast_range = min(cast_range, 2.0)

    # 第6层：不依赖敌方目标的技能给 0 格，表示“无需锁敌”。
    if not _has_enemy_target_effect(effects):
        cast_range = 0.0

    return max(0.0, min(8.0, round(cast_range, 1)))


def rewrite_units() -> dict[str, Any]:
    units = json.loads(UNITS_PATH.read_text(encoding="utf-8"))
    changed = 0
    dist = Counter()

    for unit in units:
        if not isinstance(unit, dict):
            continue
        base_stats = unit.get("base_stats", {})
        if not isinstance(base_stats, dict):
            continue

        new_rng = infer_unit_range(unit)
        old_rng = int(float(base_stats.get("rng", 1)))
        base_stats["rng"] = new_rng
        unit["base_stats"] = base_stats
        dist[new_rng] += 1
        if new_rng != old_rng:
            changed += 1

    UNITS_PATH.write_text(json.dumps(units, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {"total": len(units), "changed": changed, "dist": dict(sorted(dist.items()))}


def rewrite_gongfa() -> dict[str, Any]:
    gongfas = json.loads(GONGFA_PATH.read_text(encoding="utf-8"))
    changed = 0
    dist = Counter()

    for gongfa in gongfas:
        if not isinstance(gongfa, dict):
            continue
        skill = gongfa.get("skill", {})
        if not isinstance(skill, dict) or not skill:
            continue
        new_range = infer_gongfa_range(gongfa)
        old_range = float(skill.get("range", -999.0))
        skill["range"] = new_range
        gongfa["skill"] = skill
        dist[new_range] += 1
        if abs(new_range - old_range) > 1e-6:
            changed += 1

    GONGFA_PATH.write_text(json.dumps(gongfas, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {"total": len(gongfas), "changed": changed, "dist": dict(sorted(dist.items(), key=lambda kv: kv[0]))}


def main() -> None:
    unit_result = rewrite_units()
    gongfa_result = rewrite_gongfa()

    print("[RANGE] 单位射程重设完成")
    print("  total=%d changed=%d dist=%s" % (unit_result["total"], unit_result["changed"], unit_result["dist"]))
    print("[RANGE] 功法射程重设完成")
    print("  total=%d changed=%d dist=%s" % (gongfa_result["total"], gongfa_result["changed"], gongfa_result["dist"]))


if __name__ == "__main__":
    main()
