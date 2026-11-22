class_name MapCamera
extends Camera2D
## 地图相机：左键拖动平移，滚轮以光标为中心缩放，WASD/方向键平移。
## 点击（按下与松开之间移动不超过几个像素）时发出 clicked。

signal clicked(world_pos: Vector2)
signal view_changed()

const DRAG_THRESHOLD := 5.0
const ZOOM_STEP := 1.15
const KEY_PAN_SPEED := 900.0  # 屏幕像素/秒

var map_size := Vector2(21600, 10800)
var max_zoom := 3.0

var _pressed := false
var _dragging := false
var _press_pos := Vector2.ZERO


func _ready() -> void:
	get_viewport().size_changed.connect(_clamp_view)


func min_zoom() -> float:
	var vp := get_viewport_rect().size
	return maxf(vp.x / map_size.x, vp.y / map_size.y)


func fit_world() -> void:
	zoom = Vector2.ONE * min_zoom()
	position = map_size / 2.0
	_clamp_view()


func focus_rect(rect: Rect2, padding: float = 1.6) -> void:
	var vp := get_viewport_rect().size
	var z := minf(vp.x / maxf(rect.size.x * padding, 1.0), vp.y / maxf(rect.size.y * padding, 1.0))
	zoom = Vector2.ONE * clampf(z, min_zoom(), 1.0)
	position = rect.get_center()
	_clamp_view()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP when mb.pressed:
				_zoom_at(mb.position, ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN when mb.pressed:
				_zoom_at(mb.position, 1.0 / ZOOM_STEP)
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_pressed = true
					_dragging = false
					_press_pos = mb.position
				elif _pressed:
					_pressed = false
					if not _dragging:
						clicked.emit(_screen_to_world(mb.position))
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _pressed:
		var mm := event as InputEventMouseMotion
		if not _dragging and mm.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_dragging = true
		if _dragging:
			position -= mm.relative / zoom.x
			_clamp_view()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var dir := Vector2(
		float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)))
	if dir != Vector2.ZERO and get_viewport().gui_get_focus_owner() == null:
		position += dir.normalized() * KEY_PAN_SPEED * delta / zoom.x
		_clamp_view()


func _screen_to_world(screen: Vector2) -> Vector2:
	return position + (screen - get_viewport_rect().size / 2.0) / zoom.x


func _zoom_at(screen: Vector2, factor: float) -> void:
	var anchor := _screen_to_world(screen)
	var z := clampf(zoom.x * factor, min_zoom(), max_zoom)
	zoom = Vector2.ONE * z
	position = anchor - (screen - get_viewport_rect().size / 2.0) / z
	_clamp_view()


func _clamp_view() -> void:
	if zoom.x < min_zoom():
		zoom = Vector2.ONE * min_zoom()
	var half := get_viewport_rect().size / 2.0 / zoom.x
	position.x = map_size.x / 2.0 if half.x * 2.0 >= map_size.x else clampf(position.x, half.x, map_size.x - half.x)
	position.y = map_size.y / 2.0 if half.y * 2.0 >= map_size.y else clampf(position.y, half.y, map_size.y - half.y)
	view_changed.emit()
