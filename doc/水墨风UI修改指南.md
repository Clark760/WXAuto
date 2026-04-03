# 水墨风 UI 修改指南（面向代码 AI）

> **前提**：本文档假设执行者没有美学判断能力，所有视觉决策已经做好。
> 执行者只需严格按照本文档给出的**精确色值、尺寸参数、SVG 代码模板和 GDScript 代码**机械执行即可。
> **不需要也不应该**对颜色、透明度、圆角等参数做任何"更好看"的自主调整。

---

## 0 速查：禁忌清单

在修改 UI 时，以下操作**绝对禁止**：

| 🚫 禁止 | 原因 |
|---------|------|
| 使用纯黑 `#000000` 作为背景 | 水墨风底色是宣纸色，不是黑 |
| 使用纯白 `#FFFFFF` 作为文字色 | 水墨风文字色是墨色，接近深棕而非纯白 |
| 使用饱和度 > 60% 的鲜艳颜色 | 水墨风所有颜色都是低饱和度的 |
| 给面板加 1px 实线边框 | 水墨风用渐隐的笔触边框，不用几何线 |
| 使用圆角 > 6px | 水墨风面板是接近直角的毛边，不是 iOS 圆角 |
| 添加阴影（drop shadow） | 水墨画没有光照阴影概念 |
| 使用渐变背景 | 水墨风底色是均匀的纸色，不用 gradient |

---

## 1 色彩系统

### 1.1 核心调色板（必须严格使用）

所有颜色都以 Godot `Color()` 格式 和 HEX 两种形式给出。**不允许使用表外颜色。**

#### 底色组（用于面板和背景）

| 名称 | HEX | Godot Color | 用途 |
|------|-----|-------------|------|
| 宣纸底 | `#F5EDE0` | `Color(0.96, 0.93, 0.88, 1.0)` | 全局背景、战场底色 |
| 浅卷底 | `#EDE4D3` | `Color(0.93, 0.89, 0.83, 1.0)` | 面板内部填充色 |
| 卷轴底 | `#E5DACA` | `Color(0.90, 0.85, 0.79, 1.0)` | 次要面板 / 内嵌区域 |
| 淡墨底 | `#D6CFC2` | `Color(0.84, 0.81, 0.76, 1.0)` | 禁用 / 更深的内嵌区域 |
| 暗卷底 | `#C8BFB0` | `Color(0.78, 0.75, 0.69, 1.0)` | 分割线、进度条轨道 |

#### 墨色组（用于文字和笔触）

| 名称 | HEX | Godot Color | 用途 |
|------|-----|-------------|------|
| 浓墨 | `#2C2418` | `Color(0.17, 0.14, 0.09, 1.0)` | 标题文字 |
| 次墨 | `#3D3428` | `Color(0.24, 0.20, 0.16, 1.0)` | 正文文字 |
| 淡墨 | `#5C5244` | `Color(0.36, 0.32, 0.27, 1.0)` | 次要文字 / 提示 |
| 枯墨 | `#8A7E6E` | `Color(0.54, 0.49, 0.43, 1.0)` | 占位符 / 禁用状态文字 |
| 极淡墨 | `#A89D8C` | `Color(0.66, 0.62, 0.55, 1.0)` | 装饰性笔画 |

#### 点缀色组（用于品质标识和交互反馈）

| 名称 | HEX | Godot Color | 用途 |
|------|-----|-------------|------|
| 朱砂 | `#B04A3A` | `Color(0.69, 0.29, 0.23, 1.0)` | 伤害数字、危险提示、橙品 |
| 赭石 | `#A06830` | `Color(0.63, 0.41, 0.19, 1.0)` | 金币 / 银两图标 |
| 藤黄 | `#C8A44A` | `Color(0.78, 0.64, 0.29, 1.0)` | MVP / 高亮选中 |
| 石青 | `#4A7A6A` | `Color(0.29, 0.48, 0.42, 1.0)` | 技能释放、治疗 |
| 花青 | `#3A5A6A` | `Color(0.23, 0.35, 0.42, 1.0)` | 蓝品 / 内力条 |
| 紫英 | `#6A4A6A` | `Color(0.42, 0.29, 0.42, 1.0)` | 紫品 |
| 竹青 | `#5A7A4A` | `Color(0.35, 0.48, 0.29, 1.0)` | 绿品 / 增益 |
| 白描 | `#C4BAA8` | `Color(0.77, 0.73, 0.66, 1.0)` | 白品 / 普通品质 |

### 1.2 品质颜色映射（替换现有 `_fallback_quality_color`）

```gdscript
# 替换 battlefield_hud_text_support.gd 中的 _fallback_quality_color
func _fallback_quality_color(quality: String) -> Color:
    match quality:
        "white":
            return Color(0.77, 0.73, 0.66, 0.95)  # 白描
        "green":
            return Color(0.35, 0.48, 0.29, 0.95)  # 竹青
        "blue":
            return Color(0.23, 0.35, 0.42, 0.95)  # 花青
        "purple":
            return Color(0.42, 0.29, 0.42, 0.95)  # 紫英
        "orange":
            return Color(0.69, 0.29, 0.23, 0.95)  # 朱砂
        _:
            return Color(0.54, 0.49, 0.43, 0.95)  # 枯墨
```

### 1.3 战斗日志颜色映射（替换现有 `battle_log_color_hex`）

```gdscript
# 替换 battlefield_hud_text_support.gd 中的 battle_log_color_hex
func battle_log_color_hex(event_type: String) -> String:
    match event_type:
        "damage":
            return "#B04A3A"  # 朱砂
        "skill":
            return "#4A7A6A"  # 石青
        "buff":
            return "#5A7A4A"  # 竹青
        "death":
            return "#8A3030"  # 深朱砂
        "system":
            return "#5C5244"  # 淡墨
        _:
            return "#8A7E6E"  # 枯墨
```

---

## 2 SVG 资源规范

### 2.1 概述

所有 UI 装饰元素用 SVG 文件绘制，放置在 `assets/ui/ink/` 目录下。Godot 4.6 原生支持 SVG 导入为 `Texture2D`，可直接用于 `StyleBoxTexture` 或 `TextureRect`。

### 2.2 SVG 通用规则

| 规则 | 说明 |
|------|------|
| viewBox | 所有 SVG 的 viewBox 从 `0 0` 开始 |
| 颜色 | 只使用第 1 节调色板中的颜色，不使用 `currentColor` |
| 透明度 | 用 `fill-opacity` / `stroke-opacity` 控制，不用 `rgba` |
| 笔画端点 | 统一使用 `stroke-linecap="round"` |
| 笔画连接 | 统一使用 `stroke-linejoin="round"` |
| 文件命名 | 全小写 + 下划线，如 `panel_border_ink.svg` |
| 抗锯齿 | 不添加 `shape-rendering`，用默认抗锯齿 |

### 2.3 面板边框 SVG 模板

以下 SVG 用作 `PanelContainer` 的 `StyleBoxTexture`。边框模拟毛笔笔触，有粗细变化和不规则边缘。

#### 2.3.1 主面板边框（用于商店、详情、仓库面板）

**文件名**：`assets/ui/ink/panel_border_main.svg`

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300">
  <!-- 底纸：浅卷底色 -->
  <rect x="4" y="4" width="392" height="292"
        rx="3" ry="3"
        fill="#EDE4D3" fill-opacity="0.97"/>
  <!-- 左边：从上到下，粗→细→粗 的毛笔竖线 -->
  <path d="M 6,8 C 5,8 4,12 4,20
           L 4,140 C 3.5,150 3.5,160 4,170
           L 4,280 C 4,288 5,292 6,292"
        stroke="#3D3428" stroke-opacity="0.55"
        stroke-width="2.5" fill="none"
        stroke-linecap="round" stroke-linejoin="round"/>
  <!-- 上边：从左到右，行笔→渐淡→收笔 -->
  <path d="M 8,5 C 8,4.5 14,4 30,4
           L 200,3.5 C 260,3.5 350,4 392,5
           C 394,5 396,6 396,8"
        stroke="#3D3428" stroke-opacity="0.50"
        stroke-width="2.2" fill="none"
        stroke-linecap="round" stroke-linejoin="round"/>
  <!-- 右边：略细于左边，表现笔力渐弱 -->
  <path d="M 396,10 L 396,145
           C 396.5,152 396.5,158 396,165
           L 396,290 C 396,292 395,294 394,294"
        stroke="#3D3428" stroke-opacity="0.40"
        stroke-width="1.8" fill="none"
        stroke-linecap="round" stroke-linejoin="round"/>
  <!-- 下边：最淡，枯笔收尾 -->
  <path d="M 392,296 L 200,296.5
           C 100,296.5 40,296 8,295
           C 6,294.5 5,293 5,292"
        stroke="#3D3428" stroke-opacity="0.30"
        stroke-width="1.5" fill="none"
        stroke-linecap="round" stroke-linejoin="round"/>
  <!-- 左上角：浓墨点（起笔顿笔） -->
  <circle cx="6" cy="6" r="3"
          fill="#2C2418" fill-opacity="0.45"/>
</svg>
```

#### 2.3.2 轻量面板边框（用于 Tooltip、日志面板）

**文件名**：`assets/ui/ink/panel_border_light.svg`

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">
  <rect x="3" y="3" width="194" height="194"
        rx="2" ry="2"
        fill="#EDE4D3" fill-opacity="0.95"/>
  <!-- 只画上边和左边，模拟未画完的速写 -->
  <path d="M 5,5 L 195,4.5"
        stroke="#3D3428" stroke-opacity="0.45"
        stroke-width="1.8" fill="none"
        stroke-linecap="round"/>
  <path d="M 4,6 L 3.5,195"
        stroke="#3D3428" stroke-opacity="0.40"
        stroke-width="1.5" fill="none"
        stroke-linecap="round"/>
  <!-- 右下角提一笔飞白 -->
  <path d="M 196,170 C 196.5,185 196,195 195,197"
        stroke="#5C5244" stroke-opacity="0.20"
        stroke-width="1.0" fill="none"
        stroke-linecap="round"/>
</svg>
```

#### 2.3.3 卡片边框（用于商店卡片、库存条目）

**文件名**：`assets/ui/ink/card_border.svg`

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 140 180">
  <rect x="2" y="2" width="136" height="176"
        rx="2" ry="2"
        fill="#EDE4D3" fill-opacity="0.96"/>
  <!-- 四边简笔框 -->
  <rect x="3" y="3" width="134" height="174"
        rx="2" ry="2"
        fill="none"
        stroke="#5C5244" stroke-opacity="0.35"
        stroke-width="1.2"/>
  <!-- 顶部品质色条区（由代码动态改色） -->
  <rect x="4" y="4" width="132" height="8"
        rx="1" ry="1"
        fill="#C4BAA8" fill-opacity="0.80"/>
</svg>
```

### 2.4 按钮 SVG 模板

#### 2.4.1 标准按钮（Normal / Hover / Pressed 三态）

**文件名**：`assets/ui/ink/btn_normal.svg`

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40">
  <rect x="2" y="2" width="116" height="36"
        rx="3" ry="3"
        fill="#E5DACA" fill-opacity="0.95"/>
  <rect x="2" y="2" width="116" height="36"
        rx="3" ry="3"
        fill="none"
        stroke="#5C5244" stroke-opacity="0.40"
        stroke-width="1.2"/>
</svg>
```

**文件名**：`assets/ui/ink/btn_hover.svg`

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40">
  <rect x="2" y="2" width="116" height="36"
        rx="3" ry="3"
        fill="#D6CFC2" fill-opacity="0.98"/>
  <rect x="2" y="2" width="116" height="36"
        rx="3" ry="3"
        fill="none"
        stroke="#3D3428" stroke-opacity="0.55"
        stroke-width="1.5"/>
</svg>
```

**文件名**：`assets/ui/ink/btn_pressed.svg`

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40">
  <rect x="1" y="1" width="118" height="38"
        rx="3" ry="3"
        fill="#C8BFB0" fill-opacity="0.98"/>
  <rect x="2" y="2" width="116" height="36"
        rx="3" ry="3"
        fill="none"
        stroke="#2C2418" stroke-opacity="0.50"
        stroke-width="1.8"/>
</svg>
```

### 2.5 分割线 SVG

**文件名**：`assets/ui/ink/separator_ink.svg`

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 6">
  <!-- 水墨横线：中间实、两头虚，模拟飞白 -->
  <path d="M 10,3 C 30,2.5 80,3 200,3 C 320,3 370,3.5 390,3"
        stroke="#5C5244" stroke-opacity="0.30"
        stroke-width="1.2" fill="none"
        stroke-linecap="round"/>
</svg>
```

### 2.6 装饰性元素 SVG

#### 2.6.1 标题装饰横线

**文件名**：`assets/ui/ink/title_stroke.svg`

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 12">
  <!-- 标题下方横笔，粗→细→提 -->
  <path d="M 5,8 C 10,7 30,6 100,6 C 170,6 190,7 195,8"
        stroke="#2C2418" stroke-opacity="0.35"
        stroke-width="2.0" fill="none"
        stroke-linecap="round"/>
  <!-- 起笔处的墨点 -->
  <circle cx="5" cy="8" r="2.5"
          fill="#2C2418" fill-opacity="0.30"/>
</svg>
```

#### 2.6.2 角落装饰（用于大面板四角）

**文件名**：`assets/ui/ink/corner_ornament.svg`

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40">
  <!-- 左上角水墨花纹，竹叶两笔 -->
  <path d="M 5,30 C 8,20 12,12 20,8"
        stroke="#5C5244" stroke-opacity="0.30"
        stroke-width="2.0" fill="none"
        stroke-linecap="round"/>
  <path d="M 8,28 C 14,22 20,16 28,10"
        stroke="#5C5244" stroke-opacity="0.20"
        stroke-width="1.5" fill="none"
        stroke-linecap="round"/>
</svg>
```

---

## 3 Godot Theme 构建

### 3.1 Theme 资源文件

创建 `assets/ui/ink_theme.tres`，所有面板共享同一 Theme。

```gdscript
# scripts/ui/ink_theme_builder.gd
extends RefCounted
class_name InkThemeBuilder

## 创建水墨风全局 Theme。
## 由场景根节点在 _ready() 中调用一次即可。

const PAPER_COLOR := Color(0.96, 0.93, 0.88, 1.0)
const SCROLL_COLOR := Color(0.93, 0.89, 0.83, 1.0)
const DEEP_SCROLL_COLOR := Color(0.90, 0.85, 0.79, 1.0)
const INK_DARK := Color(0.17, 0.14, 0.09, 1.0)
const INK_MID := Color(0.24, 0.20, 0.16, 1.0)
const INK_LIGHT := Color(0.36, 0.32, 0.27, 1.0)
const INK_FAINT := Color(0.54, 0.49, 0.43, 1.0)
const BORDER_COLOR := Color(0.36, 0.32, 0.27, 0.35)
const HOVER_BG := Color(0.84, 0.81, 0.76, 0.98)
const PRESS_BG := Color(0.78, 0.75, 0.69, 0.98)

static func build() -> Theme:
    var theme := Theme.new()

    # ── Label ──
    theme.set_color("font_color", "Label", INK_MID)
    theme.set_font_size("font_size", "Label", 15)

    # ── Button ──
    var btn_normal := _flat_box(DEEP_SCROLL_COLOR, BORDER_COLOR, 3, 1)
    var btn_hover := _flat_box(HOVER_BG, Color(0.24, 0.20, 0.16, 0.50), 3, 1)
    var btn_pressed := _flat_box(PRESS_BG, Color(0.17, 0.14, 0.09, 0.45), 3, 2)
    var btn_disabled := _flat_box(
        Color(0.84, 0.81, 0.76, 0.60),
        Color(0.54, 0.49, 0.43, 0.20),
        3, 1
    )
    theme.set_stylebox("normal", "Button", btn_normal)
    theme.set_stylebox("hover", "Button", btn_hover)
    theme.set_stylebox("pressed", "Button", btn_pressed)
    theme.set_stylebox("disabled", "Button", btn_disabled)
    theme.set_color("font_color", "Button", INK_MID)
    theme.set_color("font_hover_color", "Button", INK_DARK)
    theme.set_color("font_pressed_color", "Button", INK_DARK)
    theme.set_color("font_disabled_color", "Button", INK_FAINT)
    theme.set_font_size("font_size", "Button", 15)

    # ── PanelContainer ──
    var panel := _flat_box(SCROLL_COLOR, BORDER_COLOR, 3, 1)
    panel.content_margin_left = 10
    panel.content_margin_top = 8
    panel.content_margin_right = 10
    panel.content_margin_bottom = 8
    theme.set_stylebox("panel", "PanelContainer", panel)

    # ── LineEdit ──
    var le_normal := _flat_box(PAPER_COLOR, BORDER_COLOR, 2, 1)
    le_normal.content_margin_left = 8
    le_normal.content_margin_right = 8
    le_normal.content_margin_top = 4
    le_normal.content_margin_bottom = 4
    var le_focus := _flat_box(PAPER_COLOR, Color(0.24, 0.20, 0.16, 0.50), 2, 1)
    le_focus.content_margin_left = 8
    le_focus.content_margin_right = 8
    le_focus.content_margin_top = 4
    le_focus.content_margin_bottom = 4
    theme.set_stylebox("normal", "LineEdit", le_normal)
    theme.set_stylebox("focus", "LineEdit", le_focus)
    theme.set_color("font_color", "LineEdit", INK_MID)
    theme.set_color("font_placeholder_color", "LineEdit", INK_FAINT)

    # ── RichTextLabel ──
    theme.set_color("default_color", "RichTextLabel", INK_MID)
    theme.set_font_size("normal_font_size", "RichTextLabel", 14)

    # ── ScrollContainer ──
    var scroll_bg := _flat_box(Color(0.0, 0.0, 0.0, 0.0), Color(0, 0, 0, 0), 0, 0)
    theme.set_stylebox("panel", "ScrollContainer", scroll_bg)

    # ── HSeparator ──
    var sep := StyleBoxLine.new()
    sep.color = Color(0.54, 0.49, 0.43, 0.25)
    sep.thickness = 1
    theme.set_stylebox("separator", "HSeparator", sep)

    # ── ProgressBar ──
    var pb_bg := _flat_box(
        Color(0.78, 0.75, 0.69, 0.50),
        Color(0, 0, 0, 0), 2, 0
    )
    var pb_fill := _flat_box(
        Color(0.69, 0.29, 0.23, 0.80),
        Color(0, 0, 0, 0), 2, 0
    )
    theme.set_stylebox("background", "ProgressBar", pb_bg)
    theme.set_stylebox("fill", "ProgressBar", pb_fill)

    return theme


static func _flat_box(
    bg: Color, border: Color,
    corner_radius: int, border_width: int
) -> StyleBoxFlat:
    var box := StyleBoxFlat.new()
    box.bg_color = bg
    box.border_color = border
    box.set_corner_radius_all(corner_radius)
    box.set_border_width_all(border_width)
    return box
```

### 3.2 Theme 挂载方式

在 `battlefield_scene.gd` 的 `_ready()` 中：

```gdscript
# 在场景根脚本中挂载水墨风主题
func _apply_ink_theme() -> void:
    var ink_theme: Theme = InkThemeBuilder.build()
    # 设置根节点 theme，所有子树继承
    # 如果根是 Node2D，需要分别给 CanvasLayer 下的 Control 子树设置
    for layer_name in ["HUDLayer", "ShopPanelLayer", "DetailLayer", "InventoryLayer", "BottomLayer"]:
        var layer: Node = get_node_or_null(layer_name)
        if layer == null:
            continue
        for child in layer.get_children():
            if child is Control:
                (child as Control).theme = ink_theme
```

---

## 4 面板逐项改造清单

### 4.1 全局背景

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `Background.color` | `Color(0.9, 0.87, 0.79, 1)` | `Color(0.96, 0.93, 0.88, 1.0)` 宣纸底 |

### 4.2 HexGrid（战场格子）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `fill_color` | `Color(0.2, 0.19, 0.15, 0.16)` | `Color(0.36, 0.32, 0.27, 0.08)` 极淡墨格 |
| `line_color` | `Color(0.16, 0.15, 0.13, 0.65)` | `Color(0.36, 0.32, 0.27, 0.25)` 淡墨线 |

### 4.3 TopBar（顶部栏）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `self_modulate` | `Color(1, 0.98, 0.94, 0.95)` | 删除（由 Theme 控制） |
| `PhaseLabel.font_color` | `Color(0.16, 0.14, 0.12, 1)` | `Color(0.17, 0.14, 0.09, 1.0)` 浓墨 |
| `RoundLabel.font_color` | `Color(0.2, 0.18, 0.15, 1)` | `Color(0.24, 0.20, 0.16, 1.0)` 次墨 |
| `TimerLabel.font_color` | `Color(0.24, 0.22, 0.2, 1)` | `Color(0.36, 0.32, 0.27, 1.0)` 淡墨 |

### 4.4 BattleLogPanel（战斗日志面板）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `self_modulate` | `Color(1, 0.97, 0.93, 0.94)` | 删除（由 Theme 控制） |
| `LogTitle.font_color` | `Color(0.16, 0.14, 0.12, 1)` | `Color(0.17, 0.14, 0.09, 1.0)` 浓墨 |

### 4.5 ShopPanel（商店面板）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `self_modulate` | `Color(1, 0.98, 0.94, 0.96)` | 删除 |
| `ShopTitle.font_color` | `Color(0.16, 0.14, 0.12, 1)` | `Color(0.17, 0.14, 0.09, 1.0)` 浓墨 |
| `ShopStatus.font_color` | `Color(0.27, 0.24, 0.2, 1)` | `Color(0.36, 0.32, 0.27, 1.0)` 淡墨 |

### 4.6 UnitDetailPanel（角色详情面板）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `self_modulate` | `Color(1, 0.98, 0.95, 0.97)` | 删除 |
| `PortraitColor.color` | `Color(0.24, 0.26, 0.3, 0.95)` | `Color(0.84, 0.81, 0.76, 0.70)` 淡墨底 |
| `UnitDetailMask.color` | `Color(0, 0, 0, 0.45)` | `Color(0.17, 0.14, 0.09, 0.40)` 浓墨遮罩 |
| `PhaseText.font_color` | `Color(0.16, 0.12, 0.1, 1)` | `Color(0.17, 0.14, 0.09, 1.0)` 浓墨 |

### 4.7 InventoryPanel（仓库面板）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `self_modulate` | `Color(1, 0.98, 0.95, 0.96)` | 删除 |

### 4.8 BottomPanel（备战席）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `self_modulate` | `Color(1, 0.98, 0.94, 0.95)` | 删除 |

### 4.9 ItemTooltip（物品悬浮提示）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `self_modulate` | `Color(1, 0.98, 0.95, 0.97)` | 删除 |

### 4.10 TerrainTooltip（地形提示）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `self_modulate` | `Color(1, 0.98, 0.95, 0.96)` | 删除 |

### 4.11 ShopOfferCard（商店卡片）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `ColorBar.color`（白品） | `Color(0.7, 0.7, 0.7, 1)` | `Color(0.77, 0.73, 0.66, 0.80)` 白描 |

### 4.12 InventoryItemCard（库存卡片）

| 属性 | 当前值 | 目标值 |
|------|--------|--------|
| `QualityBar.color`（白品） | `Color(0.7, 0.7, 0.7, 1)` | `Color(0.77, 0.73, 0.66, 0.80)` 白描 |

---

## 5 SVG 导入与 StyleBoxTexture 使用

### 5.1 SVG 导入设置

在 Godot 编辑器中导入 SVG 时，使用以下 `.import` 参数：

```ini
[params]
editor/scale_with_editor_scale=false
editor/convert_colors_with_editor_theme=false
svg/scale=2.0
```

或通过代码设置 import 参数后重新导入。

### 5.2 使用 SVG 作为 StyleBoxTexture 的面板底图

```gdscript
# 用 SVG Texture 替代 StyleBoxFlat 的示例
static func _svg_panel_box(texture_path: String) -> StyleBoxTexture:
    var box := StyleBoxTexture.new()
    box.texture = load(texture_path) as Texture2D
    # 九宫格切分：左/上/右/下 各保留 8px 不拉伸
    box.texture_margin_left = 8.0
    box.texture_margin_top = 8.0
    box.texture_margin_right = 8.0
    box.texture_margin_bottom = 8.0
    # 内容边距
    box.content_margin_left = 12.0
    box.content_margin_top = 10.0
    box.content_margin_right = 12.0
    box.content_margin_bottom = 10.0
    box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
    box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
    return box
```

### 5.3 用 SVG StyleBox 替换 Theme 中的 StyleBoxFlat（可选升级）

当 SVG 资源就位后，在 `InkThemeBuilder.build()` 中替换面板样式：

```gdscript
# 在 build() 中替换 PanelContainer 的 StyleBox
var svg_panel: StyleBoxTexture = _svg_panel_box("res://assets/ui/ink/panel_border_main.svg")
theme.set_stylebox("panel", "PanelContainer", svg_panel)

# 按钮也可以用 SVG 三态
var svg_btn_n: StyleBoxTexture = _svg_panel_box("res://assets/ui/ink/btn_normal.svg")
var svg_btn_h: StyleBoxTexture = _svg_panel_box("res://assets/ui/ink/btn_hover.svg")
var svg_btn_p: StyleBoxTexture = _svg_panel_box("res://assets/ui/ink/btn_pressed.svg")
theme.set_stylebox("normal", "Button", svg_btn_n)
theme.set_stylebox("hover", "Button", svg_btn_h)
theme.set_stylebox("pressed", "Button", svg_btn_p)
```

---

## 6 字体建议

### 6.1 推荐字体

| 字体 | 用途 | 获取 |
|------|------|------|
| **方正清刻本悦宋** | 标题 | 免费商用，需下载 |
| **思源宋体 (Noto Serif CJK SC)** | 正文 | Google Fonts 免费 |
| **霞鹜文楷 (LXGW WenKai)** | 备选正文（更手写感） | GitHub 开源免费 |

### 6.2 字体挂载

```gdscript
# 在 InkThemeBuilder.build() 中设置字体
var title_font: FontFile = load("res://assets/fonts/your_title_font.ttf") as FontFile
var body_font: FontFile = load("res://assets/fonts/your_body_font.ttf") as FontFile

if title_font != null:
    theme.set_font("font", "Label", body_font)
    # 标题字体通过 theme_override 单独设置
```

在不确定是否有字体文件时，**跳过字体设置**，让 Godot 使用默认字体。不要因为缺字体而报错。

---

## 7 装饰性 TextureRect 布局

### 7.1 角落装饰放置

对于需要角落装饰的大面板（商店、详情），用 `TextureRect` 绝对定位在四角：

```gdscript
# 为面板添加四角水墨装饰
func _add_corner_ornaments(panel: Control) -> void:
    var tex: Texture2D = load("res://assets/ui/ink/corner_ornament.svg") as Texture2D
    if tex == null:
        return
    var corners: Array[Dictionary] = [
        {"anchor": Vector2(0, 0), "flip_h": false, "flip_v": false},   # 左上
        {"anchor": Vector2(1, 0), "flip_h": true,  "flip_v": false},   # 右上
        {"anchor": Vector2(0, 1), "flip_h": false, "flip_v": true},    # 左下
        {"anchor": Vector2(1, 1), "flip_h": true,  "flip_v": true},    # 右下
    ]
    for corner in corners:
        var rect := TextureRect.new()
        rect.texture = tex
        rect.stretch_mode = TextureRect.STRETCH_KEEP
        rect.modulate.a = 0.6
        rect.flip_h = bool(corner["flip_h"])
        rect.flip_v = bool(corner["flip_v"])
        rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
        rect.anchors_preset = Control.PRESET_TOP_LEFT
        rect.position = Vector2(
            float(corner["anchor"].x) * (panel.size.x - 40),
            float(corner["anchor"].y) * (panel.size.y - 40)
        )
        panel.add_child(rect)
```

### 7.2 标题下划线装饰

```gdscript
# 在标题 Label 下方添加水墨横笔装饰
func _add_title_stroke(parent: Control, after_node: Node) -> void:
    var tex: Texture2D = load("res://assets/ui/ink/title_stroke.svg") as Texture2D
    if tex == null:
        return
    var rect := TextureRect.new()
    rect.texture = tex
    rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    rect.custom_minimum_size = Vector2(180, 12)
    rect.modulate.a = 0.7
    rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var idx: int = after_node.get_index() + 1
    parent.add_child(rect)
    parent.move_child(rect, idx)
```

---

## 8 .tscn 批量修改脚本

以下 GDScript 可在编辑器中作为 EditorScript 运行，一次性完成现有场景的颜色校准：

```gdscript
# tools/apply_ink_colors_to_scene.gd
# 使用方式：在 Godot 编辑器中通过 File → Run Script 执行
@tool
extends EditorScript

const COLOR_MAP: Dictionary = {
    # 背景
    "Background": Color(0.96, 0.93, 0.88, 1.0),
    # 格子
    "HexGrid/fill_color": Color(0.36, 0.32, 0.27, 0.08),
    "HexGrid/line_color": Color(0.36, 0.32, 0.27, 0.25),
    # 遮罩
    "UnitDetailMask": Color(0.17, 0.14, 0.09, 0.40),
    # 肖像
    "PortraitColor": Color(0.84, 0.81, 0.76, 0.70),
}

const SELF_MODULATE_REMOVE: Array[String] = [
    "TopBar",
    "BattleLogPanel",
    "ShopPanel",
    "UnitDetailPanel",
    "InventoryPanel",
    "BottomPanel",
    "ItemTooltip",
    "TerrainTooltip",
]

const FONT_COLOR_MAP: Dictionary = {
    # 标题级
    "PhaseLabel": Color(0.17, 0.14, 0.09, 1.0),
    "LogTitle": Color(0.17, 0.14, 0.09, 1.0),
    "ShopTitle": Color(0.17, 0.14, 0.09, 1.0),
    "DetailTitle": Color(0.17, 0.14, 0.09, 1.0),
    "PhaseText": Color(0.17, 0.14, 0.09, 1.0),
    # 正文级
    "RoundLabel": Color(0.24, 0.20, 0.16, 1.0),
    # 次要级
    "TimerLabel": Color(0.36, 0.32, 0.27, 1.0),
    "ShopStatus": Color(0.36, 0.32, 0.27, 1.0),
}

func _run() -> void:
    var scene_root: Node = get_editor_interface().get_edited_scene_root()
    if scene_root == null:
        push_error("No scene is open.")
        return

    # 删除 self_modulate
    for node_path in SELF_MODULATE_REMOVE:
        var node: Node = _find_node_recursive(scene_root, node_path)
        if node != null and node is CanvasItem:
            (node as CanvasItem).self_modulate = Color(1, 1, 1, 1)

    # 设置颜色
    for node_path in COLOR_MAP.keys():
        if "/" in node_path:
            var parts: PackedStringArray = node_path.split("/")
            var node: Node = _find_node_recursive(scene_root, parts[0])
            if node != null:
                node.set(parts[1], COLOR_MAP[node_path])
        else:
            var node: Node = _find_node_recursive(scene_root, node_path)
            if node != null and node is ColorRect:
                (node as ColorRect).color = COLOR_MAP[node_path]

    # 设置字体颜色
    for node_path in FONT_COLOR_MAP.keys():
        var node: Node = _find_node_recursive(scene_root, node_path)
        if node != null and node is Label:
            (node as Label).add_theme_color_override("font_color", FONT_COLOR_MAP[node_path])

    print("Ink color pass complete.")


func _find_node_recursive(root: Node, target_name: String) -> Node:
    if root.name == target_name:
        return root
    for child in root.get_children():
        var found: Node = _find_node_recursive(child, target_name)
        if found != null:
            return found
    return null
```

---

## 9 验收核对表

执行完毕后，逐项核查：

| # | 检查项 | 通过标准 |
|---|--------|----------|
| 1 | 背景颜色 | 显示为温暖的米色宣纸底 `#F5EDE0`，不是灰色也不是纯白 |
| 2 | 所有面板 | 面板底色统一为 `#EDE4D3`，没有面板拥有不同底色 |
| 3 | 面板边框 | 面板有低透明度的`淡墨`色边框，不是黑色实线 |
| 4 | 标题文字 | 所有标题 Label 使用`浓墨` `#2C2418`，肉眼看起来接近深棕而非纯黑 |
| 5 | 正文文字 | 正文 Label 使用`次墨` `#3D3428` |
| 6 | 按钮 normal | 按钮底色为`卷轴底` `#E5DACA`，不是 Godot 默认灰色 |
| 7 | 按钮 hover | 鼠标悬停时按钮加深到`淡墨底` `#D6CFC2`，边框加深 |
| 8 | 品质色条 | 白品为`白描`色、绿品为`竹青`色、蓝品为`花青`色，均为低饱和度 |
| 9 | 日志颜色 | 伤害为`朱砂`色（暗红非亮红），技能为`石青`色（暗青绿非亮蓝） |
| 10 | 六边格子 | 格线几乎看不见（opacity 0.25），填充色更淡（opacity 0.08） |
| 11 | 没有纯黑 | 整个 UI 中不存在 `#000000` |
| 12 | 没有纯白 | 整个 UI 中不存在 `#FFFFFF` |
| 13 | 没有鲜色 | 没有饱和度 > 60% 的颜色（例如不存在纯红 `#FF0000`） |
| 14 | `self_modulate` 已清除 | 所有面板的 `self_modulate` 恢复为默认 `(1,1,1,1)` |

---

## 10 实施优先级

```
Step 1（10 分钟）：运行 tools/apply_ink_colors_to_scene.gd
  → 所有面板颜色一次性校准

Step 2（15 分钟）：创建 InkThemeBuilder，挂载到场景根
  → 按钮、分割线、输入框统一为水墨风

Step 3（20 分钟）：创建 assets/ui/ink/ 目录，放入 SVG 文件
  → 面板获得毛笔笔触边框

Step 4（10 分钟）：替换 quality_color 和 battle_log_color_hex
  → 品质色和日志色统一为水墨调色板

Step 5（可选）：添加角落装饰和标题横笔
  → 锦上添花，不影响功能
```
