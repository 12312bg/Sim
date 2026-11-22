class_name WorldMap
extends Node2D
## 世界地图视图。图层自下而上：
##   1. 灰色晕渲底图（分块 Sprite2D，带 mipmap）
##   2. 地区着色（索引图 + 调色板着色器，按模拟状态每天更新）
##   3. 矢量边界线（始终 1 像素宽，任意缩放都清晰）
##   4. 国名标注（按缩放级别显示不同 labelrank）
## 地图坐标：1 单位 = 1 个底图像素 = 1/60 度。

signal region_clicked(region_id: String)
signal region_hovered(region_id: String)

const FILL_SHADER := preload("res://shaders/region_fill.gdshader")

const COLOR_REACHED := Color(0.86, 0.12, 0.14)
const COLOR_REMOVED := Color(0.12, 0.06, 0.06)
const COLOR_SELECT := Color(1.0, 0.82, 0.2)
const COLOR_BORDER := Color(0.12, 0.12, 0.14, 0.75)

var map_size := Vector2(21600, 10800)
var regions_meta: Array = []          # world_map.json 中的 regions
var meta_by_id: Dictionary = {}       # id -> meta
var id_by_index: Dictionary = {}      # index -> id
var world: SimWorld
var selected_id := ""
var hovered_id := ""

var _id_image: Image
var _id_scale := 2
var _palette: Image
var _palette_tex: ImageTexture
var _borders: _BorderLayer
var _labels: _LabelLayer
var _camera_zoom := 1.0


func load_map(path: String) -> void:
	var data: Dictionary = DataLoader.load_json(path)
	map_size = Vector2(data["size"][0], data["size"][1])
	regions_meta = data["regions"]
	for m in regions_meta:
		meta_by_id[m["id"]] = m
		id_by_index[int(m["index"])] = m["id"]

	# 1. 底图
	var relief: Dictionary = data["relief"]
	var tile := float(relief["tile"])
	for row in int(relief["rows"]):
		for col in int(relief["cols"]):
			var s := Sprite2D.new()
			s.texture = load(String(relief["pattern"]) % [col, row])
			s.centered = false
			s.position = Vector2(col, row) * tile
			s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			add_child(s)

	# 2. 着色层
	var ids_cfg: Dictionary = data["region_ids"]
	_id_scale = int(ids_cfg["scale"])
	var id_tex: Texture2D = load(String(ids_cfg["path"]))
	_id_image = id_tex.get_image()
	if _id_image.is_compressed():
		_id_image.decompress()
	_palette = Image.create_empty(256, 1, false, Image.FORMAT_RGBA8)
	_palette_tex = ImageTexture.create_from_image(_palette)
	var fill := Sprite2D.new()
	fill.texture = id_tex
	fill.centered = false
	fill.scale = Vector2.ONE * _id_scale
	fill.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var mat := ShaderMaterial.new()
	mat.shader = FILL_SHADER
	mat.set_shader_parameter("region_colors", _palette_tex)
	fill.material = mat
	add_child(fill)

	# 3. 边界
	_borders = _BorderLayer.new()
	for line in data["borders"]:
		var pts := PackedVector2Array()
		pts.resize(line.size() / 2)
		for i in pts.size():
			pts[i] = Vector2(line[i * 2], line[i * 2 + 1])
		_borders.lines.append(pts)
	add_child(_borders)

	# 4. 标注
	_labels = _LabelLayer.new()
	_labels.map = self
	add_child(_labels)


func bind_world(w: SimWorld) -> void:
	world = w
	selected_id = ""
	hovered_id = ""
	refresh()


## 地图坐标 -> 地区 id（海洋或不参与模拟的地区返回 ""）。
func region_at(map_pos: Vector2) -> String:
	if _id_image == null:
		return ""
	var p := Vector2i(map_pos / _id_scale)
	if p.x < 0 or p.y < 0 or p.x >= _id_image.get_width() or p.y >= _id_image.get_height():
		return ""
	var idx := int(round(_id_image.get_pixel(p.x, p.y).r * 255.0))
	var id: String = id_by_index.get(idx, "")
	if id == "" or not meta_by_id[id]["active"]:
		return ""
	return id


func region_rect(id: String) -> Rect2:
	var b: Array = meta_by_id[id]["bbox"]
	return Rect2(Vector2(b[0], b[1]), Vector2(b[2] - b[0], b[3] - b[1]))


func select(id: String) -> void:
	selected_id = id
	refresh()


func set_hovered(id: String) -> void:
	if id == hovered_id:
		return
	hovered_id = id
	refresh()
	region_hovered.emit(id)


func set_camera_zoom(z: float) -> void:
	_camera_zoom = z
	if _labels:
		_labels.queue_redraw()


func handle_click(map_pos: Vector2) -> void:
	var id := region_at(map_pos)
	select(id)
	region_clicked.emit(id)


func _process(_delta: float) -> void:
	set_hovered(region_at(get_global_mouse_position()))


## 根据模拟状态重算调色板。
func refresh() -> void:
	if _palette == null:
		return
	_palette.fill(Color(0, 0, 0, 0))
	for m in regions_meta:
		var id: String = m["id"]
		var c := Color(0, 0, 0, 0)
		var r: Region = world.regions.get(id) if world else null
		if r != null:
			if r.has_presence() or r.removed >= 1.0:
				var ratio := r.converted_ratio()
				c = COLOR_REACHED
				c.a = 0.18 + 0.42 * ratio
				var removed_ratio := r.removed / maxf(r.population, 1.0)
				c = c.lerp(COLOR_REMOVED, removed_ratio)
				c.a = maxf(c.a, removed_ratio * 0.7)
			if id == hovered_id:
				c = _blend(c, Color(1, 1, 1, 0.15))
			if id == selected_id:
				c = _blend(c, Color(COLOR_SELECT, 0.3))
		_palette.set_pixel(int(m["index"]), 0, c)
	_palette_tex.update(_palette)


static func _blend(base: Color, over: Color) -> Color:
	var a := over.a + base.a * (1.0 - over.a)
	if a <= 0.0:
		return Color(0, 0, 0, 0)
	var rgb := (Color(over.r, over.g, over.b) * over.a + Color(base.r, base.g, base.b) * base.a * (1.0 - over.a)) / a
	return Color(rgb.r, rgb.g, rgb.b, a)


# ---------------------------------------------------------------------------

class _BorderLayer extends Node2D:
	var lines: Array[PackedVector2Array] = []

	func _draw() -> void:
		# 宽度为负 = 图元线，始终 1 屏幕像素，缩放后依旧锐利。
		for pts in lines:
			draw_polyline(pts, WorldMap.COLOR_BORDER, -1.0)


class _LabelLayer extends Node2D:
	const FONT_SIZE := 14
	var map: WorldMap

	func _max_rank(z: float) -> int:
		if z < 0.1:
			return 2
		if z < 0.2:
			return 3
		if z < 0.4:
			return 4
		if z < 0.8:
			return 5
		return 10

	## 按重要性排序（labelrank 小、人口多的优先），之后放置时跳过与已放置标注重叠的。
	var _order: Array = []

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var z := map._camera_zoom
		var max_rank := _max_rank(z)
		var inv := Vector2.ONE / z
		if _order.size() != map.regions_meta.size():
			_order = map.regions_meta.duplicate()
			_order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				if a["labelrank"] != b["labelrank"]:
					return a["labelrank"] < b["labelrank"]
				return _pop(a) > _pop(b))
		var placed: Array[Rect2] = []
		for m in _order:
			if not m["active"] or int(m["labelrank"]) > max_rank:
				continue
			var text: String = m["name"]
			var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
			var anchor := Vector2(m["label"][0], m["label"][1])
			var rect := Rect2(anchor - size * inv / 2.0, size * inv).grow(3.0 / z)
			var hit := false
			for r in placed:
				if r.intersects(rect):
					hit = true
					break
			if hit:
				continue
			placed.append(rect)
			draw_set_transform(anchor, 0.0, inv)
			var at := Vector2(-size.x / 2.0, size.y / 4.0)
			draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, 4, Color(1, 1, 1, 0.85))
			draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(0.1, 0.1, 0.12))
		draw_set_transform(Vector2.ZERO)

	func _pop(m: Dictionary) -> float:
		if map.world and map.world.regions.has(m["id"]):
			return map.world.regions[m["id"]].population
		return 0.0
