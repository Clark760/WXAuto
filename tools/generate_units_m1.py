#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
M1 角色批量数据生成脚本

用途：
1. 重新生成 data/units/units_batch_m1.json
2. 保证中文 name 字段正确写入 UTF-8（避免问号乱码）
3. 统一角色模板与数值偏置，便于后续批量迭代
"""

from __future__ import annotations

import json
from pathlib import Path


def build_units() -> list[dict]:
    # 使用 Unicode 转义写中文，避免终端编码差异导致脚本内容被替换成问号。
    factions: list[tuple[str, str]] = [
        ("shaolin", "\u5c11\u6797"),   # 少林
        ("wudang", "\u6b66\u5f53"),    # 武当
        ("emei", "\u5ce8\u7709"),      # 峨眉
        ("tangmen", "\u5510\u95e8"),   # 唐门
        ("mojiao", "\u9b54\u6559"),    # 魔教
        ("gaibang", "\u4e10\u5e2e"),   # 丐帮
        ("xiaoyao", "\u900d\u9065"),   # 逍遥
        ("jianghu", "\u6563\u4eba"),   # 散人
    ]

    roles: list[tuple[str, str, dict[str, float]]] = [
        (
            "vanguard",
            "\u5148\u950b",  # 先锋
            {"hp": 780, "mp": 50, "atk": 62, "iat": 20, "def": 48, "idr": 26, "spd": 74, "rng": 1, "mov": 88, "wis": 36},
        ),
        (
            "swordsman",
            "\u5251\u5ba2",  # 剑客
            {"hp": 680, "mp": 70, "atk": 78, "iat": 40, "def": 30, "idr": 24, "spd": 86, "rng": 2, "mov": 96, "wis": 48},
        ),
        (
            "assassin",
            "\u523a\u5ba2",  # 刺客
            {"hp": 560, "mp": 80, "atk": 92, "iat": 38, "def": 20, "idr": 22, "spd": 102, "rng": 1, "mov": 112, "wis": 44},
        ),
        (
            "archer",
            "\u5c04\u624b",  # 射手
            {"hp": 590, "mp": 65, "atk": 84, "iat": 30, "def": 24, "idr": 20, "spd": 90, "rng": 5, "mov": 92, "wis": 42},
        ),
        (
            "caster",
            "\u672f\u5e08",  # 术师
            {"hp": 540, "mp": 105, "atk": 42, "iat": 96, "def": 18, "idr": 36, "spd": 82, "rng": 4, "mov": 86, "wis": 66},
        ),
        (
            "healer",
            "\u533b\u8005",  # 医者
            {"hp": 610, "mp": 110, "atk": 40, "iat": 88, "def": 22, "idr": 34, "spd": 84, "rng": 4, "mov": 88, "wis": 72},
        ),
        (
            "leader",
            "\u7edf\u9886",  # 统领
            {"hp": 760, "mp": 95, "atk": 72, "iat": 58, "def": 38, "idr": 32, "spd": 80, "rng": 3, "mov": 90, "wis": 68},
        ),
    ]

    quality_cycle: list[str] = ["white", "green", "blue", "purple", "orange"]
    quality_cost: dict[str, int] = {"white": 1, "green": 2, "blue": 3, "purple": 4, "orange": 5, "red": 6}

    faction_bias: dict[str, dict[str, float]] = {
        "shaolin": {"hp": 60, "def": 8, "idr": 6},
        "wudang": {"iat": 10, "wis": 8, "spd": 4},
        "emei": {"wis": 10, "mp": 12, "idr": 4},
        "tangmen": {"atk": 8, "spd": 8, "rng": 1},
        "mojiao": {"atk": 12, "iat": 10, "def": -4},
        "gaibang": {"hp": 40, "atk": 6, "mov": 6},
        "xiaoyao": {"spd": 10, "wis": 10, "mov": 8},
        "jianghu": {"atk": 4, "iat": 4, "spd": 2},
    }

    units: list[dict] = []
    index = 1
    for faction_key, faction_name in factions:
        for role_key, role_name, role_stats in roles:
            unit_id = f"unit_{faction_key}_{role_key}_{index:02d}"
            quality = quality_cycle[(index - 1) % len(quality_cycle)]
            stats = dict(role_stats)
            for key, delta in faction_bias.get(faction_key, {}).items():
                stats[key] = max(stats.get(key, 0) + delta, 1)

            unit_record = {
                "id": unit_id,
                "name": f"{faction_name}{role_name}{index:02d}",
                "faction": faction_key,
                "quality": quality,
                "cost": quality_cost[quality],
                "role": role_key,
                "base_star": 1,
                "max_star": 3,
                "base_stats": stats,
                "initial_gongfa": [
                    "gongfa_jingang_huti" if role_key in ("vanguard", "leader") else "gongfa_taiji_jian"
                ],
                "sprite_path": f"assets/sprites/units/{unit_id}.png",
                "portrait_path": f"assets/sprites/portraits/{unit_id}.png",
                "tags": [faction_key, role_key, quality],
                "animation_overrides": {
                    "idle_amplitude": 2.0 + (index % 3) * 0.35,
                    "attack_dash_distance": 5.0 + (index % 2),
                    "bench_tilt_deg": 2.5 + (index % 4) * 0.5,
                },
            }
            units.append(unit_record)
            index += 1

    return units


def main() -> None:
    output_path = Path("data/units/units_batch_m1.json")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    units = build_units()
    output_path.write_text(json.dumps(units, ensure_ascii=False, indent=2), encoding="utf-8")

    with_question = sum(1 for u in units if "?" in str(u.get("name", "")))
    print(f"WROTE={output_path}")
    print(f"COUNT={len(units)}")
    print(f"WITH_QUESTION={with_question}")
    print("SAMPLE=", units[0]["name"], units[1]["name"], units[2]["name"])


if __name__ == "__main__":
    main()

