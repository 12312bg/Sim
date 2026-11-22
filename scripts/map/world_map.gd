class_name WorldMap
extends Node2D
## 世界地图视图。图层自下而上：
##   1. 灰色晕渲底图（分块 Sprite2D，带 mipmap）
##   2. 地区着色（国家索引图 + 调色板着色器，按模拟状态更新）
##   3. 细线：海岸线、国界（始终 1 像素）
##   4. 粗线：模拟地区之间的边界（场景把多个国家合并为一个地区时）
##   5. 标注：地区名；放大后再显示国名
## 地图坐标：1 单位 = 1 个底图像素 = 1/60 度。
##
## 地图数据以“国家”为单位；模拟场景的地区可以包含多个国家（Region.countries），
## 着色、点选、标注都按模拟地区进行。

signal region_clicked(region_id: String)
signal region_hovered(region_id: String)

const FILL_SHADER := preload("res://shaders/region_fill.gdshader")

const COLOR_SELECT := Color(1.0, 0.82, 0.2)
const COLOR_COAST := Color(0.12, 0.12, 0.14, 0.75)
const COLOR_COUNTRY := Color(0.12, 0.12, 0.14, 0.75)
const COLOR_COUNTRY_INNER := Color(0.15, 0.15, 0.17, 0.35)
const COLOR_GROUP := Color(0.08, 0.08, 0.1, 0.9)
const GROUP_BORDER_PX := 2.2

var map_size := Vector2(21600, 10800)
var countries_meta: Array = []        # world_map.json 中的 regions（国家）
var country_by_id: Dictionary = {}    # 国家代码 -> meta
var country_by_index: Dictionary = {} # 索引 -> 国家代码
var world: SimWorld
var selected_id := ""                 # 模拟地区 id
var hovered_id := ""
var grouped := false                  # 场景是否把国家合并为地区

var _group_of: Dictionary = {}        # 国家代码 -> 模拟地区 id
var _border_items: Array = []         # [{a, b, pts}]
var _id_image: Image
var _id_scale := 2
var _palette: Image
var _palette_tex: ImageTexture
var _thin: _ThinBorders
var _thick: _ThickBorders
var _labels: _LabelLayer
var _camera_zoom := 1.0
var font: Font


func load_map(path: String) -> void:
	var data: Dictionary = DataLoader.load_json(path)
	map_size = Vector2(data["size"][0], data["size"][1])
	countries_meta = data["regions"]
	for m in countries_meta:
		country_by_id[m["id"]] = m
		country_by_index[int(m["index"])] = m["id"]
	font = ThemeDB.get_project_theme().default_font if ThemeDB.get_project_theme() else ThemeDB.fallback_font

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

	# 3/4. 边界
	for item in data["borders"]:
		var line: Array = item["p"]
		var pts := PackedVector2Array()
		pts.resize(line.size() / 2)
		for i in pts.size():
			pts[i] = Vector2(line[i * 2], line[i * 2 + 1])
		_border_items.append({"a": item["a"], "b": item["b"], "pts": pts})
	_thin = _ThinBorders.new()
	add_child(_thin)
	_thick = _ThickBorders.new()
	_thick.map = self
	add_child(_thick)

	# 5. 标注
	_labels = _LabelLayer.new()
	_labels.map = self
	add_child(_labels)


func bind_world(w: SimWorld) -> void:
	world = w
	selected_id = ""
	hovered_id = ""
	_group_of.clear()
	grouped = false
	for r: Region in w.region_list():
		for c in r.countries:
			_group_of[c] = r.id
		if r.countries != [r.id]:
			grouped = true
	_classify_borders()
	_labels.invalidate()
	refresh()


## 按当前场景的分组，把边界分为：海岸线 / 地区内国界 / 地区边界（粗线）。
func _classify_borders() -> void:
	_thin.lines.clear()
	_thin.colors.clear()
	_thick.lines.clear()
	for item in _border_items:
		var b: String = item["b"]
		if b == "":
			_thin.lines.append(item["pts"])
			_thin.colors.append(COLOR_COAST)
			continue
		var ga: String = _group_of.get(item["a"], "")
		var gb: String = _group_of.get(b, "")
		if grouped and ga != "" and gb != "" and ga != gb:
			_thick.lines.append(item["pts"])
		else:
			_thin.lines.append(item["pts"])
			_thin.colors.append(COLOR_COUNTRY_INNER if grouped else COLOR_COUNTRY)
	_thin.queue_redraw()
	_thick.queue_redraw()


## 地图坐标 -> 模拟地区 id（海洋或不参与模拟的国家返回 ""）。
func region_at(map_pos: Vector2) -> String:
	return _group_of.get(country_at(map_pos), "")


func country_at(map_pos: Vector2) -> String:
	if _id_image == null:
		return ""
	var p := Vector2i(map_pos / _id_scale)
	if p.x < 0 or p.y < 0 or p.x >= _id_image.get_width() or p.y >= _id_image.get_height():
		return ""
	return country_by_index.get(int(round(_id_image.get_pixel(p.x, p.y).r * 255.0)), "")


func region_rect(id: String) -> Rect2:
	var r: Region = world.regions.get(id) if world else null
	var b: Array = []
	if r != null and r.map_meta.has("bbox"):
		b = r.map_meta["bbox"]
	elif country_by_id.has(id):
		b = country_by_id[id]["bbox"]
	else:
		return Rect2(Vector2.ZERO, map_size)
	return Rect2(Vector2(b[0], b[1]), Vector2(b[2] - b[0], b[3] - b[1]))


## 模拟地区的标注点（地图坐标）。
func region_anchor(id: String) -> Vector2:
	var r: Region = world.regions.get(id) if world else null
	if r != null and r.map_meta.has("label"):
		return Vector2(r.map_meta["label"][0], r.map_meta["label"][1])
	if country_by_id.has(id):
		var l: Array = country_by_id[id]["label"]
		return Vector2(l[0], l[1])
	return region_rect(id).get_center()


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
	if is_equal_approx(z, _camera_zoom):
		return
	_camera_zoom = z
	if _labels:
		_labels.queue_redraw()
	if _thick:
		_thick.queue_redraw()


func camera_zoom() -> float:
	return _camera_zoom


func handle_click(map_pos: Vector2) -> void:
	var id := region_at(map_pos)
	select(id)
	region_clicked.emit(id)


func _process(_delta: float) -> void:
	if world:
		set_hovered(region_at(get_global_mouse_position()))


## 地区颜色：信徒 / 狂信徒 / 流失者（无神论者）三色按人数加权混合，覆盖率越高越不透明。
func region_color(r: Region) -> Color:
	var living := maxf(r.living(), 1.0)
	var wb := maxf(r.converted - r.zealots, 0.0) / living
	var wz := r.zealots / living
	var wl := r.lapsed / living
	var wr := r.removed / maxf(r.population, 1.0)
	var total := wb + wz + wl
	if total * living < 1.0 and wr <= 0.0:
		return Color(0, 0, 0, 0)
	var cb := Color(world.map_colors.get("converted", "#db1f24"))
	var cz := Color(world.map_colors.get("zealot", "#7a0f14"))
	var cl := Color(world.map_colors.get("lapsed", "#2f7bc4"))
	var rgb := Color(0, 0, 0)
	if total > 0.0:
		rgb = (cb * wb + cz * wz + cl * wl) / total
	var c := Color(rgb.r, rgb.g, rgb.b, 0.15 + 0.5 * clampf(total, 0.0, 1.0))
	if wr > 0.0:
		c = c.lerp(Color(0.12, 0.06, 0.06), wr)
		c.a = maxf(c.a, wr * 0.7)
	return c


## 根据模拟状态重算调色板。
func refresh() -> void:
	if _palette == null:
		return
	_palette.fill(Color(0, 0, 0, 0))
	var colors := {}
	if world:
		for r: Region in world.region_list():
			var c := region_color(r)
			if r.id == hovered_id:
				c = _blend(c, Color(1, 1, 1, 0.15))
			if r.id == selected_id:
				c = _blend(c, Color(COLOR_SELECT, 0.3))
			colors[r.id] = c
	for m in countries_meta:
		var gid: String = _group_of.get(m["id"], "")
		if colors.has(gid):
			_palette.set_pixel(int(m["index"]), 0, colors[gid])
	_palette_tex.update(_palette)


static func _blend(base: Color, over: Color) -> Color:
	var a := over.a + base.a * (1.0 - over.a)
	if a <= 0.0:
		return Color(0, 0, 0, 0)
	var rgb := (Color(over.r, over.g, over.b) * over.a + Color(base.r, base.g, base.b) * base.a * (1.0 - over.a)) / a
	return Color(rgb.r, rgb.g, rgb.b, a)


# ---------------------------------------------------------------------------

class _ThinBorders extends Node2D:
	var lines: Array[PackedVector2Array] = []
	var colors: Array[Color] = []

	func _draw() -> void:
		# 宽度为负 = 图元线，始终 1 屏幕像素，缩放后依旧锐利。
		for i in lines.size():
			draw_polyline(lines[i], colors[i], -1.0)


class _ThickBorders extends Node2D:
	var lines: Array[PackedVector2Array] = []
	var map: WorldMap

	func _draw() -> void:
		# 固定屏幕宽度：随缩放重绘
		var w := WorldMap.GROUP_BORDER_PX / maxf(map.camera_zoom(), 0.0001)
		for pts in lines:
			draw_polyline(pts, WorldMap.COLOR_GROUP, w, true)


class _LabelLayer extends Node2D:
	const GROUP_FONT_SIZE := 15
	const COUNTRY_FONT_SIZE := 12
	const COUNTRY_ZOOM := 0.35   # 合并地区时，放大到此倍数后显示国名
	var map: WorldMap
	var _items: Array = []       # [{text, pos, size, rank, main}]

	func invalidate() -> void:
		_items.clear()
		queue_redraw()

	func _build() -> void:
		_items.clear()
		var w := map.world
		if w == null:
			return
		if map.grouped:
			var list := w.region_list()
			list.sort_custom(func(a: Region, b: Region) -> bool: return a.population > b.population)
			for r: Region in list:
				_items.append({"text": r.display_name, "pos": map.region_anchor(r.id), "rank": 0, "main": true})
			for m in map.countries_meta:
				if m["active"] and map._group_of.get(m["id"], "") != "":
					var region: Region = w.regions[map._group_of[m["id"]]]
					if region.countries.size() > 1:
						_items.append({"text": m["name"], "pos": Vector2(m["label"][0], m["label"][1]),
							"rank": int(m["labelrank"]), "main": false})
		else:
			var metas := map.countries_meta.duplicate()
			metas.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["labelrank"] < b["labelrank"])
			for m in metas:
				if m["active"]:
					_items.append({"text": m["name"], "pos": Vector2(m["label"][0], m["label"][1]),
						"rank": int(m["labelrank"]), "main": true})

	func _country_rank_limit(z: float) -> int:
		if map.grouped:
			if z < COUNTRY_ZOOM:
				return -1
			return 4 if z < 0.7 else 10
		if z < 0.1:
			return 2
		if z < 0.2:
			return 3
		if z < 0.4:
			return 4
		if z < 0.8:
			return 5
		return 10

	func _draw() -> void:
		if _items.is_empty():
			_build()
		var f := map.font
		var z := map.camera_zoom()
		var inv := Vector2.ONE / z
		var limit := _country_rank_limit(z)
		var placed: Array[Rect2] = []
		for it in _items:
			var main: bool = it["main"] and map.grouped
			if not main and int(it["rank"]) > limit:
				continue
			var fs := GROUP_FONT_SIZE if main else COUNTRY_FONT_SIZE
			var text: String = it["text"]
			var size := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			var anchor: Vector2 = it["pos"]
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
			var color := Color(0.08, 0.08, 0.1) if main or not map.grouped else Color(0.25, 0.25, 0.28)
			draw_string_outline(f, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(1, 1, 1, 0.85))
			draw_string(f, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)
		draw_set_transform(Vector2.ZERO)
