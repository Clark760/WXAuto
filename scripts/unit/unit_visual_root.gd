extends Node2D

const NAME_DRAW_ORIGIN: Vector2 = Vector2(-34.0, -34.0)
const NAME_DRAW_SIZE: Vector2 = Vector2(68.0, 20.0)
const NAME_FONT_SIZE: int = 12

var _name_line: TextLine = TextLine.new()
var _name_line_dirty: bool = true

@export var sprite_texture: Texture2D = null:
	set(value):
		if sprite_texture == value:
			return
		sprite_texture = value
		queue_redraw()

@export var name_text: String = "":
	set(value):
		if name_text == value:
			return
		name_text = value
		_name_line_dirty = true
		queue_redraw()

@export var name_color: Color = Color(1.0, 1.0, 1.0, 1.0):
	set(value):
		if name_color == value:
			return
		name_color = value
		queue_redraw()

@export var labels_visible: bool = true:
	set(value):
		if labels_visible == value:
			return
		labels_visible = value
		queue_redraw()


func _draw() -> void:
	if sprite_texture != null:
		var texture_size: Vector2 = sprite_texture.get_size()
		draw_texture(sprite_texture, texture_size * -0.5)

	if not labels_visible:
		return

	_draw_cached_text_line(
		_name_line,
		"_name_line_dirty",
		name_text,
		NAME_DRAW_ORIGIN,
		NAME_DRAW_SIZE,
		NAME_FONT_SIZE,
		name_color
	)


func get_sprite_texture_size() -> Vector2:
	if sprite_texture == null:
		return Vector2.ZERO
	return sprite_texture.get_size()


func _draw_cached_text_line(
	line: TextLine,
	dirty_flag_name: String,
	text_value: String,
	top_left: Vector2,
	draw_size: Vector2,
	font_size: int,
	draw_color: Color
) -> void:
	if text_value.is_empty():
		return
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return
	if bool(get(dirty_flag_name)):
		line.clear()
		line.width = draw_size.x
		line.alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.add_string(text_value, font, font_size)
		set(dirty_flag_name, false)
	var line_size: Vector2 = line.get_size()
	var draw_pos: Vector2 = Vector2(
		top_left.x,
		top_left.y + (draw_size.y - line_size.y) * 0.5
	)
	line.draw(get_canvas_item(), draw_pos, draw_color)
