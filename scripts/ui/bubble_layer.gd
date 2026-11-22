class_name BubbleLayer
extends Control
## 地图上的可点击气泡。气泡由 SimWorld 产生，这里负责显示、跟随地图位置、点击收集和淡出。
## 气泡大小在屏幕上固定；位置 = 地区标注点 + 按气泡 id 错开的屏幕偏移。

const SIZE := 38.0
const COLOR_POINTS := Color("#e0a526")
const COLOR_EVENT := Color("#7b4bd6")

var map: WorldMap
var _buttons: Dictionary = {}   # bubble id -> Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func bind_world(w: SimWorld) -> void:
	for b in _buttons.values():
		b.queue_free()
	_buttons.clear()
	w.bubble_spawned.connect(_on_spawned)
	w.bubble_changed.connect(_on_changed)
	w.bubble_removed.connect(_on_removed)
	for b in w.bubbles.values():
		_on_spawned(b)


func _on_spawned(b: Dictionary) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(SIZE, SIZE)
	btn.size = Vector2(SIZE, SIZE)
	btn.pivot_offset = Vector2(SIZE, SIZE) / 2.0
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var is_event: bool = b.kind == "event"
	var base := COLOR_EVENT if is_event else COLOR_POINTS
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = base.lightened(0.2) if state == "hover" else base
		sb.set_corner_radius_all(int(SIZE / 2.0))
		sb.set_border_width_all(2)
		sb.border_color = Color(1, 1, 1, 0.9)
		sb.shadow_color = Color(0, 0, 0, 0.35)
		sb.shadow_size = 3
		btn.add_theme_stylebox_override(state, sb)
	btn.add_theme_color_override("font_color", Color.WHITE if is_event else Color(0.15, 0.1, 0.0))
	btn.add_theme_color_override("font_hover_color", Color.WHITE if is_event else Color(0.15, 0.1, 0.0))
	btn.add_theme_font_size_override("font_size", 15)
	btn.pressed.connect(func() -> void: Game.world.collect_bubble(int(b.id)))
	btn.set_meta("bubble", b)
	add_child(btn)
	_buttons[b.id] = btn
	_update_text(btn, b)
	btn.scale = Vector2.ZERO
	create_tween().tween_property(btn, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_changed(b: Dictionary) -> void:
	var btn: Button = _buttons.get(b.id)
	if btn:
		_update_text(btn, b)
		btn.scale = Vector2.ONE * 1.25
		create_tween().tween_property(btn, "scale", Vector2.ONE, 0.15)


func _on_removed(id: int, collected: bool) -> void:
	var btn: Button = _buttons.get(id)
	if btn == null:
		return
	_buttons.erase(id)
	btn.disabled = true
	var tw := create_tween().set_parallel()
	if collected:
		tw.tween_property(btn, "scale", Vector2.ONE * 1.6, 0.2)
	tw.tween_property(btn, "modulate:a", 0.0, 0.2)
	tw.chain().tween_callback(btn.queue_free)


func _update_text(btn: Button, b: Dictionary) -> void:
	var w := Game.world
	if b.kind == "event":
		var ev := w._event_def(String(b.event))
		btn.text = "✦"
		btn.tooltip_text = "%s\n%s\n点击触发" % [ev.get("name", "事件"), w.format_news(String(ev.get("news", "")), String(b.region))]
	else:
		btn.text = "+%d" % int(b.value)
		btn.tooltip_text = "%d %s" % [int(b.value), w.label("points", "点数")]


func _process(_delta: float) -> void:
	if map == null or Game.world == null:
		return
	var xf := get_viewport().get_canvas_transform()
	for id in _buttons:
		var btn: Button = _buttons[id]
		var b: Dictionary = btn.get_meta("bubble")
		var anchor := xf * map.region_anchor(String(b.region))
		# 同一地区可能有多个气泡：按 id 沿螺旋错开
		var k := int(id)
		var offset := Vector2.from_angle(k * 2.39996) * (18.0 + float(k % 4) * 14.0)
		btn.position = anchor + offset - btn.size / 2.0
		var life := Game.bubble_life_left(int(id))
		var alpha := 1.0
		if life < 0.3:
			alpha = 0.45 + 0.55 * absf(sin(Time.get_ticks_msec() / 120.0))
		btn.modulate.a = alpha
