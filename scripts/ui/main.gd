extends Node
## 主界面：世界地图铺满窗口，界面叠在 CanvasLayer 上。
## 布局：顶栏（状态/速度/存读档） | 右侧：升级树 + 国家列表 | 左下：选中国家信息 + 新闻

const CATEGORY_NAMES := {"transmission": "传播途径", "traits": "特性", "abilities": "能力"}
const RIGHT_W := 360.0
const TOP_H := 40.0
const BOTTOM_H := 180.0

var _map: WorldMap
var _camera: MapCamera
var _loaded_map_path := ""

var _info: Label
var _opp_bar: ProgressBar
var _speed_btns: Array[Button] = []
var _tabs: TabContainer
var _right_panel: PanelContainer
var _upgrade_pages: Array[Control] = []
var _upgrade_btns: Dictionary = {}   # id -> Button
var _country_tree: Tree
var _country_items: Dictionary = {}  # id -> TreeItem
var _detail: RichTextLabel
var _start_btn: Button
var _news: RichTextLabel
var _over_dialog: AcceptDialog


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.16, 0.17, 0.19))
	_map = WorldMap.new()
	add_child(_map)
	_camera = MapCamera.new()
	add_child(_camera)
	_camera.clicked.connect(_map.handle_click)
	_camera.view_changed.connect(func() -> void: _map.set_camera_zoom(_camera.zoom.x))
	_map.region_clicked.connect(func(_id: String) -> void: _refresh_detail())

	_build_ui()
	Game.session_started.connect(_on_session_started)
	Game.speed_changed.connect(_on_speed_changed)
	Game.new_game()


# ---------------------------------------------------------------- 搭建

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	# 顶栏
	var top_panel := _panel(root)
	top_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_panel.offset_bottom = TOP_H
	var top := HBoxContainer.new()
	top_panel.add_child(top)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.clip_text = true
	top.add_child(_info)
	var opp_label := Label.new()
	opp_label.text = "反制"
	top.add_child(opp_label)
	_opp_bar = ProgressBar.new()
	_opp_bar.custom_minimum_size = Vector2(140, 0)
	_opp_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_opp_bar.max_value = 100
	top.add_child(_opp_bar)
	for i in Game.SECONDS_PER_DAY.size():
		var b := _add_button(top, "暂停" if i == 0 else "%dx" % i, Game.set_speed.bind(i))
		b.toggle_mode = true
		_speed_btns.append(b)
	_add_button(top, "面板 [Tab]", _toggle_panel)
	_add_button(top, "新游戏", func() -> void: Game.new_game())
	_add_button(top, "存档", func() -> void: _log("已存档" if Game.save_game() else "存档失败"))
	_add_button(top, "读档", func() -> void:
		if not Game.load_game():
			_log("没有存档"))

	# 右侧：升级 + 国家
	var right := _panel(root)
	_right_panel = right
	right.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	right.offset_left = -RIGHT_W
	right.offset_top = TOP_H
	_tabs = TabContainer.new()
	right.add_child(_tabs)
	_country_tree = Tree.new()
	_country_tree.name = "国家"
	_country_tree.columns = 3
	_country_tree.column_titles_visible = true
	_country_tree.hide_root = true
	_country_tree.set_column_title(0, "国家")
	_country_tree.set_column_title(1, "已转化")
	_country_tree.set_column_title(2, "警觉")
	_country_tree.set_column_expand_ratio(0, 2)
	_country_tree.item_selected.connect(_on_country_selected)
	_tabs.add_child(_country_tree)

	# 左下：详情 + 新闻
	var bottom := HBoxContainer.new()
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -BOTTOM_H
	bottom.offset_right = -RIGHT_W
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bottom)
	var detail_panel := _panel(bottom)
	detail_panel.custom_minimum_size = Vector2(320, 0)
	var detail_box := VBoxContainer.new()
	detail_panel.add_child(detail_box)
	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_box.add_child(_detail)
	_start_btn = _add_button(detail_box, "在此国家开始", _on_start_pressed)
	var news_panel := _panel(bottom)
	news_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_news = RichTextLabel.new()
	_news.bbcode_enabled = true
	_news.scroll_following = true
	news_panel.add_child(_news)

	_over_dialog = AcceptDialog.new()
	_over_dialog.title = "对局结束"
	root.add_child(_over_dialog)


func _toggle_panel() -> void:
	_right_panel.visible = not _right_panel.visible


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_TAB:
		_toggle_panel()
		get_viewport().set_input_as_handled()


func _panel(parent: Control) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.11, 0.9)
	sb.set_content_margin_all(6)
	p.add_theme_stylebox_override("panel", sb)
	parent.add_child(p)
	return p


func _add_button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


# ---------------------------------------------------------------- 对局绑定

func _on_session_started(w: SimWorld) -> void:
	if w.map_path != "" and w.map_path != _loaded_map_path:
		_map.load_map(w.map_path)
		_loaded_map_path = w.map_path
		_camera.map_size = _map.map_size
		_camera.fit_world()
	w.day_advanced.connect(func(_d: int) -> void: _refresh())
	w.points_changed.connect(func(_p: int) -> void: _refresh_upgrades())
	w.upgrade_purchased.connect(func(_id: String) -> void: _refresh_upgrades())
	w.region_reached.connect(func(_id: String) -> void: _refresh())
	w.news.connect(_log)
	w.game_over.connect(_on_game_over)
	_map.bind_world(w)
	_news.clear()
	_build_country_rows(w)
	_build_upgrade_tabs(w)
	_log("点击地图选择一个国家，然后点“在此国家开始”。拖动平移，滚轮缩放。" if not w.started else "已读取存档。")
	_refresh()


func _build_country_rows(w: SimWorld) -> void:
	_country_tree.clear()
	_country_items.clear()
	var root := _country_tree.create_item()
	var list := w.region_list()
	list.sort_custom(func(a: Region, b: Region) -> bool: return a.population > b.population)
	for r: Region in list:
		var it := _country_tree.create_item(root)
		it.set_metadata(0, r.id)
		it.set_text(0, r.display_name)
		_country_items[r.id] = it


func _build_upgrade_tabs(w: SimWorld) -> void:
	for page in _upgrade_pages:
		page.queue_free()
	_upgrade_pages.clear()
	_upgrade_btns.clear()
	var boxes := {}
	var at := 0
	for cat in w.upgrades.categories():
		var scroll := ScrollContainer.new()
		scroll.name = CATEGORY_NAMES.get(cat, cat)
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(box)
		_tabs.add_child(scroll)
		_tabs.move_child(scroll, at)
		at += 1
		_upgrade_pages.append(scroll)
		boxes[cat] = box
	_tabs.current_tab = 0
	for id in w.upgrades.order:
		var d: Dictionary = w.upgrades.defs[id]
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = "%s\n效果：%s" % [d.get("desc", ""), JSON.stringify(d.get("effects", {}))]
		b.pressed.connect(func() -> void:
			var reason := Game.world.buy_upgrade(id)
			if reason != "":
				_log("无法购买 %s：%s" % [d.get("name", id), reason]))
		boxes[String(d.get("category", "misc"))].add_child(b)
		_upgrade_btns[id] = b


# ---------------------------------------------------------------- 刷新

func _refresh() -> void:
	var w := Game.world
	if w == null:
		return
	var t := w.totals()
	_info.text = "第 %d 天   %s %d   %s %s / %s   %s %s   覆盖 %d/%d 国" % [
		w.day, w.label("points", "点数"), w.points,
		w.label("converted", "已转化"), _fmt(t.converted), _fmt(t.population),
		w.label("removed", "已移除"), _fmt(t.removed),
		t.reached, w.regions.size()]
	_opp_bar.value = w.opposition.progress * 100.0
	_opp_bar.tooltip_text = "%s：%s" % [w.label("opposition", "反制"), "进行中" if w.opposition.active else "未开始"]
	for id in _country_items:
		var r: Region = w.regions[id]
		var it: TreeItem = _country_items[id]
		it.set_text(1, "%.1f%%" % (r.converted_ratio() * 100.0) if r.converted > 0.0 else "-")
		it.set_text(2, "%.0f%%" % (r.awareness * 100.0))
	_map.refresh()
	_refresh_detail()
	_refresh_upgrades()


func _refresh_detail() -> void:
	var w := Game.world
	var id := _map.selected_id
	_start_btn.disabled = w == null or w.started or id == ""
	if w == null or id == "" or not w.regions.has(id):
		_detail.text = "[color=#999]点击地图上的国家查看详情[/color]"
		return
	var r: Region = w.regions[id]
	var climate: String = {"hot": "炎热", "temperate": "温和", "cold": "寒冷"}.get(r.traits.get("climate", ""), "?")
	var wealth: String = {"rich": "富裕", "mid": "中等", "poor": "贫困"}.get(r.traits.get("wealth", ""), "?")
	var closed := "、".join(PackedStringArray(r.closed_link_types.keys()))
	_detail.text = "[b]%s[/b]\n人口 %s   %s / %s\n%s %s (%.1f%%)\n%s %s\n警觉 %.0f%%%s" % [
		r.display_name, _fmt(r.population), climate, wealth,
		w.label("converted", "已转化"), _fmt(r.converted), r.converted_ratio() * 100.0,
		w.label("removed", "已移除"), _fmt(r.removed),
		r.awareness * 100.0, ("   已封锁：" + closed) if closed != "" else ""]


func _refresh_upgrades() -> void:
	var w := Game.world
	if w == null:
		return
	for id in _upgrade_btns:
		var b: Button = _upgrade_btns[id]
		var d: Dictionary = w.upgrades.defs[id]
		var owned := w.upgrades.is_owned(id)
		var state := "✔" if owned else ("🔒" if not w.upgrades.is_unlocked(id) else "")
		b.text = "%s %s  [%d]" % [state, d.get("name", id), int(d.get("cost", 0))]
		b.disabled = owned or w.upgrades.check_buy(id, w.points) != ""


func _on_country_selected() -> void:
	var it := _country_tree.get_selected()
	if it == null:
		return
	var id := String(it.get_metadata(0))
	_map.select(id)
	if _map.meta_by_id.has(id):
		_camera.focus_rect(_map.region_rect(id))
	_refresh_detail()


func _on_start_pressed() -> void:
	if _map.selected_id == "":
		return
	Game.world.start_in(_map.selected_id)
	Game.set_speed(1)
	_refresh()


func _on_speed_changed(s: int) -> void:
	for i in _speed_btns.size():
		_speed_btns[i].set_pressed_no_signal(i == s)


func _on_game_over(won: bool, reason: String) -> void:
	Game.set_speed(0)
	_over_dialog.dialog_text = "%s\n%s\n第 %d 天" % ["胜利！" if won else "失败", reason, Game.world.day]
	_over_dialog.popup_centered()


func _log(text: String) -> void:
	var day := Game.world.day if Game.world else 0
	_news.append_text("[color=#888]D%d[/color] %s\n" % [day, text])


static func _fmt(n: float) -> String:
	if n >= 1e9:
		return "%.2fB" % (n / 1e9)
	if n >= 1e6:
		return "%.1fM" % (n / 1e6)
	if n >= 1e3:
		return "%.1fK" % (n / 1e3)
	return "%d" % int(n)
