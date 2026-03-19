#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
M3 数据生成脚本
================
用途：
1. 生成功法/联动/Buff 的首批 JSON 数据。
2. 生成对应 JSON Schema，统一字段约束。
3. 全部文件使用 UTF-8（无 BOM）并保留中文，便于直接在 IDE 编辑。

执行方式（按项目要求）：
    py tools/generate_m3_data.py
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def dump_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    path.write_text(text, encoding="utf-8")


def build_gongfa_data() -> list[dict[str, Any]]:
    return [
        {
            "id": "gongfa_jiuyang",
            "name": "九阳神功",
            "type": "neigong",
            "description": "至阳内功，提升生存与内力恢复。",
            "faction": "shaolin",
            "element": "fire",
            "quality": "orange",
            "tags": ["yang", "recovery", "shaolin_core"],
            "passive_effects": [
                {"op": "stat_percent", "stat": "hp", "value": 0.20},
                {"op": "stat_add", "stat": "mp", "value": 80},
                {"op": "mp_regen_add", "value": 5.0},
            ],
            "skill": {
                "trigger": "auto_mp_full",
                "mp_cost": 60,
                "cooldown": 6.0,
                "effects": [
                    {"op": "heal_self_percent", "value": 0.25},
                    {"op": "buff_self", "buff_id": "jiuyang_shield", "duration": 5.0},
                ],
                "vfx_id": "vfx_golden_aura",
            },
            "linkage_tags": ["jiuyang", "yang_gong", "shaolin_neigong"],
        },
        {
            "id": "gongfa_zixia",
            "name": "紫霞神功",
            "type": "neigong",
            "description": "高爆发内功，提升内功攻击与暴击。",
            "faction": "emei",
            "element": "fire",
            "quality": "purple",
            "tags": ["yang", "offensive"],
            "passive_effects": [
                {"op": "stat_percent", "stat": "iat", "value": 0.25},
                {"op": "crit_bonus", "value": 0.10},
            ],
            "skill": {
                "trigger": "auto_mp_full",
                "mp_cost": 50,
                "cooldown": 7.0,
                "effects": [
                    {"op": "damage_aoe", "radius": 3, "value": 120, "damage_type": "internal"},
                    {"op": "spawn_vfx", "vfx_id": "vfx_purple_wave", "at": "self"},
                ],
                "vfx_id": "vfx_purple_glow",
            },
            "linkage_tags": ["zixia", "yang_gong", "emei_neigong"],
        },
        {
            "id": "gongfa_xianglong",
            "name": "降龙十八掌",
            "type": "waigong",
            "description": "高额外功爆发并附带范围震荡。",
            "faction": "gaibang",
            "element": "metal",
            "quality": "orange",
            "tags": ["palm", "aoe"],
            "passive_effects": [{"op": "stat_add", "stat": "atk", "value": 60}],
            "skill": {
                "trigger": "auto_mp_full",
                "mp_cost": 70,
                "cooldown": 8.0,
                "effects": [
                    {"op": "damage_aoe", "radius": 2, "value": 200, "damage_type": "external"},
                    {"op": "spawn_vfx", "vfx_id": "vfx_dragon_palm", "at": "target"},
                ],
                "vfx_id": "vfx_golden_dragon",
            },
            "linkage_tags": ["xianglong", "palm_art", "gaibang_waigong"],
        },
        {
            "id": "gongfa_dugu",
            "name": "独孤九剑",
            "type": "waigong",
            "description": "被攻击时有概率反制一击。",
            "faction": "xiaoyao",
            "element": "metal",
            "quality": "orange",
            "tags": ["sword", "counter"],
            "passive_effects": [
                {"op": "attack_speed_bonus", "value": 0.20},
                {"op": "dodge_bonus", "value": 0.15},
            ],
            "skill": {
                "trigger": "on_attacked",
                "chance": 0.30,
                "mp_cost": 0,
                "cooldown": 4.0,
                "effects": [
                    {"op": "damage_target", "value": 180, "damage_type": "external", "multiplier": 1.5},
                    {"op": "spawn_vfx", "vfx_id": "vfx_sword_flash", "at": "target"},
                ],
                "vfx_id": "vfx_counter_stance",
            },
            "linkage_tags": ["dugu", "sword_art"],
        },
        {
            "id": "gongfa_lingbo",
            "name": "凌波微步",
            "type": "qinggong",
            "description": "提升身法并在受击时获得短暂闪避强化。",
            "faction": "xiaoyao",
            "element": "water",
            "quality": "orange",
            "tags": ["dodge", "movement"],
            "passive_effects": [
                {"op": "stat_percent", "stat": "spd", "value": 0.30},
                {"op": "dodge_bonus", "value": 0.20},
            ],
            "skill": {
                "trigger": "on_attacked",
                "chance": 0.25,
                "mp_cost": 20,
                "cooldown": 5.0,
                "effects": [
                    {"op": "buff_self", "buff_id": "lingbo_evasion", "duration": 2.0},
                    {"op": "spawn_vfx", "vfx_id": "vfx_water_ripple", "at": "self"},
                ],
                "vfx_id": "vfx_water_ripple",
            },
            "linkage_tags": ["lingbo", "xiaoyao_qinggong"],
        },
        {
            "id": "gongfa_tiangang",
            "name": "天罡北斗阵",
            "type": "zhenfa",
            "description": "战斗中持续为周围友军提供护体增益。",
            "faction": "wudang",
            "element": "earth",
            "quality": "purple",
            "tags": ["formation", "defense"],
            "passive_effects": [],
            "skill": {
                "trigger": "passive_aura",
                "mp_cost": 0,
                "cooldown": 1.5,
                "effects": [
                    {"op": "buff_allies_aoe", "buff_id": "tiangang_ward", "radius": 4, "duration": 1.8}
                ],
                "vfx_id": "vfx_star_circle",
            },
            "linkage_tags": ["tiangang", "wudang_zhenfa", "star_formation"],
        },
        {
            "id": "gongfa_qiankun",
            "name": "乾坤大挪移",
            "type": "qishu",
            "description": "偏防守型奇术，被击时强化减伤。",
            "faction": "mingjiao",
            "element": "none",
            "quality": "orange",
            "tags": ["redirect", "special"],
            "passive_effects": [{"op": "damage_reduce_percent", "value": 0.15}],
            "skill": {
                "trigger": "on_attacked",
                "chance": 0.20,
                "mp_cost": 40,
                "cooldown": 6.0,
                "effects": [
                    {"op": "buff_self", "buff_id": "qiankun_redirect", "duration": 2.5},
                    {"op": "spawn_vfx", "vfx_id": "vfx_redirect_swirl", "at": "self"},
                ],
                "vfx_id": "vfx_yin_yang_sphere",
            },
            "linkage_tags": ["qiankun", "mingjiao_qishu"],
        },
        {
            "id": "gongfa_huagong",
            "name": "化功大法",
            "type": "qishu",
            "description": "攻击命中附带吸蚀 debuff 并回复自身。",
            "faction": "xingxiu",
            "element": "water",
            "quality": "purple",
            "tags": ["drain", "debuff"],
            "passive_effects": [],
            "skill": {
                "trigger": "on_attack_hit",
                "chance": 0.30,
                "mp_cost": 30,
                "cooldown": 5.0,
                "effects": [
                    {"op": "debuff_target", "buff_id": "huagong_drain", "duration": 4.0},
                    {"op": "heal_self", "value": 50},
                ],
                "vfx_id": "vfx_dark_mist",
            },
            "linkage_tags": ["huagong", "drain_art", "xingxiu_qishu"],
        },
        {
            "id": "gongfa_taiji_neigong",
            "name": "太极内功",
            "type": "neigong",
            "description": "均衡型内功，提升攻防并增加招架续航。",
            "faction": "wudang",
            "element": "water",
            "quality": "blue",
            "tags": ["wudang", "balance"],
            "passive_effects": [
                {"op": "stat_percent", "stat": "def", "value": 0.15},
                {"op": "stat_percent", "stat": "idr", "value": 0.15},
                {"op": "mp_regen_add", "value": 2.0},
            ],
            "skill": {
                "trigger": "auto_hp_below",
                "threshold": 0.35,
                "mp_cost": 40,
                "cooldown": 8.0,
                "effects": [
                    {"op": "heal_self_percent", "value": 0.18},
                    {"op": "buff_self", "buff_id": "taiji_guard", "duration": 4.0},
                ],
                "vfx_id": "vfx_taiji_ring",
            },
            "linkage_tags": ["taiji", "wudang_neigong", "quanzhen_sword"],
        },
        {
            "id": "gongfa_quanzhen_sword",
            "name": "全真剑法",
            "type": "waigong",
            "description": "标准剑修输出功法，强调攻速与连击。",
            "faction": "wudang",
            "element": "wood",
            "quality": "green",
            "tags": ["sword", "combo"],
            "passive_effects": [
                {"op": "stat_add", "stat": "atk", "value": 30},
                {"op": "attack_speed_bonus", "value": 0.12},
            ],
            "skill": {
                "trigger": "on_attack_hit",
                "chance": 0.25,
                "mp_cost": 20,
                "cooldown": 3.5,
                "effects": [
                    {"op": "damage_target", "value": 95, "damage_type": "external", "multiplier": 1.2},
                    {"op": "spawn_vfx", "vfx_id": "vfx_sword_qi", "at": "target"},
                ],
                "vfx_id": "vfx_sword_qi",
            },
            "linkage_tags": ["quanzhen_sword", "sword_art", "wudang_waigong"],
        },
    ]


def build_linkage_data() -> list[dict[str, Any]]:
    return [
        {
            "id": "linkage_sancai_jian",
            "name": "三才剑阵",
            "type": "faction_combo",
            "description": "3名武当弟子修炼全真剑法时触发。",
            "conditions": {
                "min_count": 3,
                "require_faction": "wudang",
                "require_any_tag": ["quanzhen_sword"],
                "require_adjacent": True,
            },
            "effects": [
                {"op": "stat_percent", "stat": "atk", "value": 0.30, "target": "participants"},
                {"op": "dodge_bonus", "value": 0.15, "target": "participants"},
            ],
            "vfx_id": "vfx_sword_formation",
        },
        {
            "id": "linkage_wood_fire",
            "name": "木火通明",
            "type": "element_resonance",
            "description": "木属性功法与火属性功法相生共鸣。",
            "conditions": {"require_elements": [["wood", "fire"]], "min_count": 2},
            "effects": [{"op": "stat_percent", "stat": "iat", "value": 0.20, "target": "participants"}],
            "vfx_id": "vfx_fire_bloom",
        },
        {
            "id": "linkage_palm_sword_chain",
            "name": "掌剑连击",
            "type": "skill_chain",
            "description": "掌法与剑法角色同时在场。",
            "conditions": {"require_tags_combo": [["palm_art"], ["sword_art"]], "min_count": 2},
            "effects": [
                {"op": "crit_bonus", "value": 0.15, "target": "participants"},
                {"op": "crit_damage_bonus", "value": 0.25, "target": "participants"},
            ],
            "vfx_id": "vfx_combo_spark",
        },
        {
            "id": "linkage_tiangang_quanzhen",
            "name": "北斗护法",
            "type": "formation_boost",
            "description": "天罡北斗阵范围内有全真内功角色。",
            "conditions": {"require_zhenfa_tag": "tiangang", "require_any_tag": ["wudang_neigong"], "min_count": 1},
            "effects": [
                {"op": "stat_percent", "stat": "def", "value": 0.40, "target": "zhenfa_area"},
                {"op": "damage_reduce_percent", "value": 0.10, "target": "zhenfa_area"},
            ],
            "vfx_id": "vfx_star_shield",
        },
        {
            "id": "linkage_shaolin_3",
            "name": "少林三绝",
            "type": "faction_combo",
            "description": "3名少林弟子同时上场。",
            "conditions": {"min_count": 3, "require_faction": "shaolin"},
            "effects": [
                {"op": "stat_add", "stat": "def", "value": 40, "target": "participants"},
                {"op": "stat_add", "stat": "hp", "value": 150, "target": "participants"},
            ],
            "vfx_id": "vfx_golden_bell",
        },
    ]


def build_buff_data() -> list[dict[str, Any]]:
    return [
        {
            "id": "jiuyang_shield",
            "name": "九阳护体",
            "type": "buff",
            "icon": "buff_golden_shield",
            "stackable": False,
            "max_stacks": 1,
            "default_duration": 5.0,
            "effects": [
                {"op": "damage_reduce_percent", "value": 0.30},
                {"op": "stat_percent", "stat": "def", "value": 0.20},
            ],
            "tick_effects": [],
            "tick_interval": 0,
        },
        {
            "id": "tangmen_poison",
            "name": "唐门剧毒",
            "type": "debuff",
            "icon": "debuff_poison",
            "stackable": True,
            "max_stacks": 5,
            "default_duration": 4.0,
            "effects": [{"op": "stat_percent", "stat": "spd", "value": -0.15}],
            "tick_effects": [{"op": "damage_target", "value": 30, "damage_type": "internal"}],
            "tick_interval": 1.0,
        },
        {
            "id": "lingbo_evasion",
            "name": "凌波回风",
            "type": "buff",
            "icon": "buff_wind_step",
            "stackable": False,
            "max_stacks": 1,
            "default_duration": 2.0,
            "effects": [{"op": "dodge_bonus", "value": 0.22}],
            "tick_effects": [],
            "tick_interval": 0,
        },
        {
            "id": "huagong_drain",
            "name": "化功蚀气",
            "type": "debuff",
            "icon": "debuff_drain",
            "stackable": True,
            "max_stacks": 3,
            "default_duration": 4.0,
            "effects": [
                {"op": "stat_percent", "stat": "atk", "value": -0.12},
                {"op": "stat_percent", "stat": "iat", "value": -0.12},
            ],
            "tick_effects": [{"op": "damage_target", "value": 22, "damage_type": "internal"}],
            "tick_interval": 1.0,
        },
        {
            "id": "tiangang_ward",
            "name": "天罡护体",
            "type": "buff",
            "icon": "buff_star_ward",
            "stackable": False,
            "max_stacks": 1,
            "default_duration": 2.0,
            "effects": [
                {"op": "stat_percent", "stat": "def", "value": 0.20},
                {"op": "damage_reduce_percent", "value": 0.08},
            ],
            "tick_effects": [],
            "tick_interval": 0,
        },
        {
            "id": "taiji_guard",
            "name": "太极守势",
            "type": "buff",
            "icon": "buff_taiji_guard",
            "stackable": False,
            "max_stacks": 1,
            "default_duration": 4.0,
            "effects": [
                {"op": "damage_reduce_percent", "value": 0.15},
                {"op": "mp_regen_add", "value": 2.0},
            ],
            "tick_effects": [],
            "tick_interval": 0,
        },
        {
            "id": "qiankun_redirect",
            "name": "挪移回旋",
            "type": "buff",
            "icon": "buff_yinyang",
            "stackable": False,
            "max_stacks": 1,
            "default_duration": 2.5,
            "effects": [
                {"op": "damage_reduce_percent", "value": 0.18},
                {"op": "crit_bonus", "value": 0.08},
            ],
            "tick_effects": [],
            "tick_interval": 0,
        },
    ]


def build_gongfa_schema() -> dict[str, Any]:
    return {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "title": "GongfaSchema",
        "description": "M3 功法数据结构定义",
        "type": "object",
        "required": ["id", "name", "type", "element", "quality", "passive_effects", "skill", "linkage_tags"],
        "properties": {
            "id": {"type": "string", "pattern": "^[a-z0-9_]+$"},
            "name": {"type": "string", "minLength": 1},
            "type": {"type": "string", "enum": ["neigong", "waigong", "qinggong", "zhenfa", "qishu"]},
            "description": {"type": "string"},
            "faction": {"type": "string"},
            "element": {"type": "string", "enum": ["metal", "wood", "water", "fire", "earth", "none"]},
            "quality": {"type": "string", "enum": ["white", "green", "blue", "purple", "orange", "red"]},
            "tags": {"type": "array", "items": {"type": "string"}},
            "passive_effects": {"type": "array", "items": {"type": "object", "required": ["op"]}},
            "skill": {"type": "object", "required": ["trigger", "effects"]},
            "linkage_tags": {"type": "array", "items": {"type": "string"}},
        },
        "additionalProperties": True,
    }


def build_linkage_schema() -> dict[str, Any]:
    return {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "title": "LinkageSchema",
        "description": "M3 联动关系数据结构定义",
        "type": "object",
        "required": ["id", "name", "type", "conditions", "effects"],
        "properties": {
            "id": {"type": "string", "pattern": "^[a-z0-9_]+$"},
            "name": {"type": "string"},
            "type": {"type": "string", "enum": ["faction_combo", "element_resonance", "skill_chain", "formation_boost"]},
            "description": {"type": "string"},
            "conditions": {"type": "object"},
            "effects": {"type": "array", "items": {"type": "object", "required": ["op"]}},
            "vfx_id": {"type": "string"},
        },
        "additionalProperties": True,
    }


def build_buff_schema() -> dict[str, Any]:
    return {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "title": "BuffSchema",
        "description": "M3 Buff / Debuff 数据结构定义",
        "type": "object",
        "required": ["id", "name", "type", "stackable", "max_stacks", "effects", "tick_effects", "tick_interval"],
        "properties": {
            "id": {"type": "string", "pattern": "^[a-z0-9_]+$"},
            "name": {"type": "string"},
            "type": {"type": "string", "enum": ["buff", "debuff"]},
            "icon": {"type": "string"},
            "stackable": {"type": "boolean"},
            "max_stacks": {"type": "integer", "minimum": 1},
            "default_duration": {"type": "number"},
            "effects": {"type": "array", "items": {"type": "object", "required": ["op"]}},
            "tick_effects": {"type": "array", "items": {"type": "object", "required": ["op"]}},
            "tick_interval": {"type": "number", "minimum": 0},
        },
        "additionalProperties": True,
    }


def main() -> None:
    dump_json(ROOT / "data/gongfa/gongfa_batch_m3.json", build_gongfa_data())
    dump_json(ROOT / "data/linkages/linkages_batch_m3.json", build_linkage_data())
    dump_json(ROOT / "data/buffs/buffs_batch_m3.json", build_buff_data())

    dump_json(ROOT / "data/gongfa/_schema/gongfa.schema.json", build_gongfa_schema())
    dump_json(ROOT / "data/linkages/_schema/linkage.schema.json", build_linkage_schema())
    dump_json(ROOT / "data/buffs/_schema/buff.schema.json", build_buff_schema())

    print("M3 数据与 Schema 已生成。")


if __name__ == "__main__":
    main()
