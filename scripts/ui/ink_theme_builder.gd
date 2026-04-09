extends RefCounted
class_name InkThemeBuilder

## 创建水墨风全局 Theme。
## 由场景根节点在 _ready() 中调用一次即可。
# 设计约束：
# 1. 所有公开入口都优先尝试加载 `assets/ui/ink/` 下的 SVG 资源。
# 2. 任一 SVG 缺失时必须平滑回退到 StyleBoxFlat，不能让场景初始化报错。
# 3. 颜色口径统一复用这里的常量和品质色函数，避免卡片、按钮、面板各自飘色。
# 4. 这个 builder 只负责“视觉投影”，不读取业务状态，也不依赖运行时服务。
# 资源分层：
# 1. `main panel` 负责大面板笔触边框和内容留白。
# 2. `light panel` 负责 tooltip / log 这类轻量浮层。
# 3. `card panel` 负责小卡片、槽位、列表条目的统一边框。
# 4. `button` 三态和 `separator` 分割线单独建样式，避免继承主面板后出现内容边距不合适。

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
const MAIN_PANEL_TEXTURE_PATH := "res://assets/ui/ink/panel_border_main.svg"
const LIGHT_PANEL_TEXTURE_PATH := "res://assets/ui/ink/panel_border_light.svg"
const CARD_PANEL_TEXTURE_PATH := "res://assets/ui/ink/card_border.svg"
const BUTTON_NORMAL_TEXTURE_PATH := "res://assets/ui/ink/btn_normal.svg"
const BUTTON_HOVER_TEXTURE_PATH := "res://assets/ui/ink/btn_hover.svg"
const BUTTON_PRESSED_TEXTURE_PATH := "res://assets/ui/ink/btn_pressed.svg"
const SEPARATOR_TEXTURE_PATH := "res://assets/ui/ink/separator_ink.svg"

# 构建全局水墨主题：优先吃 SVG 资源，资源缺失时自动回退到平面样式。
static func build() -> Theme:
	var theme := Theme.new()

	# ── Label ──
	theme.set_color("font_color", "Label", INK_MID)
	theme.set_font_size("font_size", "Label", 15)

	# ── Button ──
	var btn_normal := make_button_normal_style()
	var btn_hover := make_button_hover_style()
	var btn_pressed := make_button_pressed_style()
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
	var panel := make_main_panel_style()
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
	theme.set_stylebox("separator", "HSeparator", make_separator_style())

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


# 主面板边框用于商店、详情、仓库等大块 UI 容器。
static func make_main_panel_style() -> StyleBox:
	var fallback := _flat_box(SCROLL_COLOR, BORDER_COLOR, 3, 1)
	fallback.content_margin_left = 12
	fallback.content_margin_top = 10
	fallback.content_margin_right = 12
	fallback.content_margin_bottom = 10
	return _svg_box_or_fallback(
		MAIN_PANEL_TEXTURE_PATH,
		fallback,
		Vector4(8, 8, 8, 8),
		Vector4(12, 10, 12, 10)
	)


# 轻量面板边框用于日志和 tooltip，视觉上比主面板更轻。
static func make_light_panel_style() -> StyleBox:
	var fallback := _flat_box(SCROLL_COLOR, Color(0.24, 0.20, 0.16, 0.28), 2, 1)
	fallback.content_margin_left = 10
	fallback.content_margin_top = 8
	fallback.content_margin_right = 10
	fallback.content_margin_bottom = 8
	return _svg_box_or_fallback(
		LIGHT_PANEL_TEXTURE_PATH,
		fallback,
		Vector4(6, 6, 6, 6),
		Vector4(10, 8, 10, 8)
	)


# 卡片边框用于商店卡、库存卡和备战席槽位。
static func make_card_panel_style() -> StyleBox:
	var fallback := _flat_box(SCROLL_COLOR, Color(0.36, 0.32, 0.27, 0.22), 2, 1)
	fallback.content_margin_left = 6
	fallback.content_margin_top = 6
	fallback.content_margin_right = 6
	fallback.content_margin_bottom = 6
	return _svg_box_or_fallback(
		CARD_PANEL_TEXTURE_PATH,
		fallback,
		Vector4(4, 4, 4, 4),
		Vector4(6, 6, 6, 6)
	)


# 按钮 normal 态优先使用 SVG，保证卷轴底和笔触边框一致。
static func make_button_normal_style() -> StyleBox:
	var fallback := _flat_box(DEEP_SCROLL_COLOR, BORDER_COLOR, 3, 1)
	fallback.content_margin_left = 10
	fallback.content_margin_top = 6
	fallback.content_margin_right = 10
	fallback.content_margin_bottom = 6
	return _svg_box_or_fallback(
		BUTTON_NORMAL_TEXTURE_PATH,
		fallback,
		Vector4(4, 4, 4, 4),
		Vector4(10, 6, 10, 6)
	)


# 按钮 hover 态只在底色和边框笔力上做轻度加深。
static func make_button_hover_style() -> StyleBox:
	var fallback := _flat_box(HOVER_BG, Color(0.24, 0.20, 0.16, 0.50), 3, 1)
	fallback.content_margin_left = 10
	fallback.content_margin_top = 6
	fallback.content_margin_right = 10
	fallback.content_margin_bottom = 6
	return _svg_box_or_fallback(
		BUTTON_HOVER_TEXTURE_PATH,
		fallback,
		Vector4(4, 4, 4, 4),
		Vector4(10, 6, 10, 6)
	)


# 按钮 pressed 态进一步压深底色，模拟落笔压实的感觉。
static func make_button_pressed_style() -> StyleBox:
	var fallback := _flat_box(PRESS_BG, Color(0.17, 0.14, 0.09, 0.45), 3, 2)
	fallback.content_margin_left = 10
	fallback.content_margin_top = 6
	fallback.content_margin_right = 10
	fallback.content_margin_bottom = 6
	return _svg_box_or_fallback(
		BUTTON_PRESSED_TEXTURE_PATH,
		fallback,
		Vector4(4, 4, 4, 4),
		Vector4(10, 6, 10, 6)
	)


# 分割线样式单独抽出来，避免 HSeparator 继续走默认直线。
static func make_separator_style() -> StyleBox:
	var texture: Texture2D = _load_optional_texture(SEPARATOR_TEXTURE_PATH)
	if texture == null:
		var fallback := StyleBoxLine.new()
		fallback.color = Color(0.54, 0.49, 0.43, 0.25)
		fallback.thickness = 1
		return fallback
	var box := StyleBoxTexture.new()
	box.texture = texture
	box.texture_margin_left = 10.0
	box.texture_margin_right = 10.0
	box.texture_margin_top = 1.0
	box.texture_margin_bottom = 1.0
	box.content_margin_left = 0.0
	box.content_margin_right = 0.0
	box.content_margin_top = 2.0
	box.content_margin_bottom = 2.0
	box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	return box


# 品质色统一收口，供卡片、备战席和拖拽预览复用同一调色板。
static func quality_color(quality: String, alpha: float = 0.95) -> Color:
	var clamped_alpha: float = clampf(alpha, 0.0, 1.0)
	match quality:
		"white":
			return Color(0.77, 0.73, 0.66, clamped_alpha)
		"green":
			return Color(0.35, 0.48, 0.29, clamped_alpha)
		"blue":
			return Color(0.23, 0.35, 0.42, clamped_alpha)
		"purple":
			return Color(0.42, 0.29, 0.42, clamped_alpha)
		"orange":
			return Color(0.69, 0.29, 0.23, clamped_alpha)
		_:
			return Color(0.54, 0.49, 0.43, clamped_alpha)


# 平面回退样式只负责兜底，不承载最终笔触效果。
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


# SVG 样式加载失败时自动回退，保证缺资源也不会把 UI 跑崩。
static func _svg_box_or_fallback(
	texture_path: String,
	fallback: StyleBox,
	texture_margins: Vector4,
	content_margins: Vector4
) -> StyleBox:
	var texture: Texture2D = _load_optional_texture(texture_path)
	if texture == null:
		return fallback
	var box := StyleBoxTexture.new()
	box.texture = texture
	box.texture_margin_left = texture_margins.x
	box.texture_margin_top = texture_margins.y
	box.texture_margin_right = texture_margins.z
	box.texture_margin_bottom = texture_margins.w
	box.content_margin_left = content_margins.x
	box.content_margin_top = content_margins.y
	box.content_margin_right = content_margins.z
	box.content_margin_bottom = content_margins.w
	box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	return box


# 只有在当前运行环境确实支持把资源当作 Texture2D 读出来时，才尝试加载 SVG。
static func _load_optional_texture(texture_path: String) -> Texture2D:
	if not ResourceLoader.exists(texture_path, "Texture2D"):
		return null
	return load(texture_path) as Texture2D
