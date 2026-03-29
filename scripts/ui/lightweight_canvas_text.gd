extends Node2D
class_name LightweightCanvasText

var _text_line: TextLine = TextLine.new()
var _text_line_dirty: bool = true

@export var text: String = "":
	set(value):
		if text == value:
			return
		text = value
		_text_line_dirty = true
		queue_redraw()

@export var font: Font = null:
	set(value):
		if font == value:
			return
		font = value
		_text_line_dirty = true
		queue_redraw()

@export var font_size: int = 16:
	set(value):
		var next_value: int = maxi(value, 1)
		if font_size == next_value:
			return
		font_size = next_value
		_text_line_dirty = true
		queue_redraw()

@export var draw_size: Vector2 = Vector2(68.0, 20.0):
	set(value):
		if draw_size == value:
			return
		draw_size = value
		_text_line_dirty = true
		queue_redraw()

@export var horizontal_alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT:
	set(value):
		if horizontal_alignment == value:
			return
		horizontal_alignment = value
		_text_line_dirty = true
		queue_redraw()

@export var vertical_alignment: VerticalAlignment = VERTICAL_ALIGNMENT_TOP:
	set(value):
		if vertical_alignment == value:
			return
		vertical_alignment = value
		queue_redraw()

@export var outline_size: int = 0:
	set(value):
		var next_value: int = maxi(value, 0)
		if outline_size == next_value:
			return
		outline_size = next_value
		queue_redraw()

@export var outline_color: Color = Color(0.0, 0.0, 0.0, 0.8):
	set(value):
		if outline_color == value:
			return
		outline_color = value
		queue_redraw()


func _draw() -> void:
	if text.is_empty():
		return

	if not _ensure_text_line():
		return

	var line_size: Vector2 = _text_line.get_size()
	var draw_pos: Vector2 = Vector2(0.0, _resolve_draw_y(line_size.y))

	if outline_size > 0:
		_text_line.draw_outline(get_canvas_item(), draw_pos, outline_size, outline_color)

	_text_line.draw(get_canvas_item(), draw_pos)


func _resolve_font() -> Font:
	if font != null:
		return font
	return ThemeDB.fallback_font


func _resolve_font_size() -> int:
	if font_size > 0:
		return font_size
	return maxi(ThemeDB.fallback_font_size, 1)


func _resolve_draw_y(text_height: float) -> float:
	match vertical_alignment:
		VERTICAL_ALIGNMENT_CENTER:
			return (draw_size.y - text_height) * 0.5
		VERTICAL_ALIGNMENT_BOTTOM:
			return draw_size.y - text_height
		_:
			return 0.0


func _ensure_text_line() -> bool:
	var resolved_font: Font = _resolve_font()
	if resolved_font == null:
		return false
	if not _text_line_dirty:
		return true
	_text_line.clear()
	_text_line.width = draw_size.x
	_text_line.alignment = horizontal_alignment
	_text_line.add_string(text, resolved_font, _resolve_font_size())
	_text_line_dirty = false
	return true
