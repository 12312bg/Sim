extends Node
## 主界面：世界地图铺满窗口，界面叠在 CanvasLayer 上。
## 布局：顶栏（日期/统计/速度/存读档） | 右侧：三棵能力树 + 地区列表 | 左下：选中地区详情 + 新闻
## 地图上方是气泡层；开局前弹出新游戏对话框（选主题、给信仰起名）。

const RIGHT_W := 380.0
const TOP_H := 42.0
const BOTTOM_H := 190.0

var _map: WorldMap
var _camera: MapCamera
var _bubbles: BubbleLayer
var _loaded_map_path := ""

var _info: Label
var _era: Label
var _opp_box: HBoxContainer
var _opp_bar: ProgressBar
var _speed_btns: Array[Button] = []
var _tabs: TabContainer
var _right_panel: PanelContainer
var _upgrade_pages: Array[Control] = []
var _upgrade_btns: Dictionary = {}   # id -> Button
var _region_tree: Tree
var _region_items: Dictionary = {}   # id -> TreeItem
var _detail: RichTextLabel
var _legend: RichTextLabel
var _start_btn: Button
var _news: RichTextLabel
var _over_dialog: AcceptDialog
var _new_dialog: ConfirmationDialog
var _theme_pick: OptionButton
var _theme_desc: Label
var _name_edit: LineEdit
var _theme_list: Array[Dictionary] = []


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
	Game.new_game()   # 先用默认主题铺好地图，再弹出新游戏对话框
	_show_new_game_dialog()


# ---------------------------------------------------------------- 搭建

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	_bubbles = BubbleLayer.new()
	_bubbles.map = _map
	root.add_child(_bubbles)

	# 顶栏
	var top_panel := _panel(root)
	top_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_panel.offset_bottom = TOP_H
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	top_panel.add_child(top)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.clip_text = true
	_info.mouse_filter = Control.MOUSE_FILTER_PASS
	top.add_child(_info)
	_era = Label.new()
	top.add_child(_era)
	_opp_box = HBoxContainer.new()
	top.add_child(_opp_box)
	var opp_label := Label.new()
	opp_label.text = "反制"
	_opp_box.add_child(opp_label)
	_opp_bar = ProgressBar.new()
	_opp_bar.custom_minimum_size = Vector2(120, 0)
	_opp_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_opp_bar.max_value = 100
	_opp_box.add_child(_opp_bar)
	for i in 4:
		var b := _add_button(top, "暂停" if i == 0 else "%dx" % i, func() -> void: Game.set_speed(i))
		b.toggle_mode = true
		_speed_btns.append(b)
	_add_button(top, "面板 [Tab]", _toggle_panel)
	_add_button(top, "新游戏", _show_new_game_dialog)
	_add_button(top, "存档", func() -> void: _log("已存档" if Game.save_game() else "存档失败"))
	_add_button(top, "读档", func() -> void:
		if not Game.load_game():
			_log("没有存档"))

	# 右侧：能力树 + 地区列表
	_right_panel = _panel(root)
	_right_panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_right_panel.offset_left = -RIGHT_W
	_right_panel.offset_top = TOP_H
	_tabs = TabContainer.new()
	_right_panel.add_child(_tabs)
	_region_tree = Tree.new()
	_region_tree.name = "地区"
	_region_tree.columns = 4
	_region_tree.column_titles_visible = true
	_region_tree.hide_root = true
	_region_tree.set_column_expand_ratio(0, 3)
	_region_tree.item_selected.connect(_on_region_selected)
	_tabs.add_child(_region_tree)

	# 左下：详情 + 新闻
	var bottom := HBoxContainer.new()
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -BOTTOM_H
	bottom.offset_right = -RIGHT_W
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bottom)
	var detail_panel := _panel(bottom)
	detail_panel.custom_minimum_size = Vector2(340, 0)
	var detail_box := VBoxContainer.new()
	detail_panel.add_child(detail_box)
	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_box.add_child(_detail)
	_legend = RichTextLabel.new()
	_legend.bbcode_enabled = true
	_legend.fit_content = true
	_legend.scroll_active = false
	detail_box.add_child(_legend)
	_start_btn = _add_button(detail_box, "在此地区开始", _on_start_pressed)
	var news_panel := _panel(bottom)
	news_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_news = RichTextLabel.new()
	_news.bbcode_enabled = true
	_news.scroll_following = true
	news_panel.add_child(_news)

	_over_dialog = AcceptDialog.new()
	_over_dialog.title = "对局结束"
	root.add_child(_over_dialog)
	_build_new_game_dialog(root)


func _build_new_game_dialog(root: Control) -> void:
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "新游戏"
	_new_dialog.ok_button_text = "开始"
	_new_dialog.cancel_button_text = "取消"
	_new_dialog.min_size = Vector2i(460, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_new_dialog.add_child(box)
	var l1 := Label.new()
	l1.text = "主题"
	box.add_child(l1)
	_theme_pick = OptionButton.new()
	box.add_child(_theme_pick)
	_theme_desc = Label.new()
	_theme_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_theme_desc.custom_minimum_size = Vector2(420, 0)
	_theme_desc.modulate = Color(1, 1, 1, 0.75)
	box.add_child(_theme_desc)
	var l2 := Label.new()
	l2.text = "名称"
	box.add_child(l2)
	_name_edit = LineEdit.new()
	_name_edit.max_length = 12
	box.add_child(_name_edit)
	_theme_pick.item_selected.connect(_on_theme_picked)
	_new_dialog.confirmed.connect(_on_new_game_confirmed)
	_name_edit.text_submitted.connect(func(_t: String) -> void:
		_new_dialog.hide()
		_on_new_game_confirmed())
	root.add_child(_new_dialog)


func _show_new_game_dialog() -> void:
	Game.set_speed(0)
	_theme_list = Game.themes()
	_theme_pick.clear()
	for t in _theme_list:
		_theme_pick.add_item(String(t.get("name", t.get("id", ""))))
	_theme_pick.select(0)
	_on_theme_picked(0)
	_new_dialog.popup_centered()
	_name_edit.grab_focus()


func _on_theme_picked(i: int) -> void:
	var t: Dictionary = _theme_list[i]
	_theme_desc.text = String(t.get("desc", ""))
	_name_edit.text = ""
	_name_edit.placeholder_text = "留空则使用「%s」" % t.get("default_agent_name", "")


func _on_new_game_confirmed() -> void:
	var t: Dictionary = _theme_list[_theme_pick.selected]
	Game.new_game(String(t["path"]), _name_edit.text)


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
	w.tick_advanced.connect(func(_t: int) -> void: _refresh())
	w.points_changed.connect(func(_p: int) -> void:
		_refresh_top()
		_refresh_upgrades())
	w.upgrade_purchased.connect(func(_id: String) -> void: _refresh_upgrades())
	w.region_reached.connect(func(_id: String) -> void: _refresh())
	w.news.connect(_log)
	w.game_over.connect(_on_game_over)
	_map.bind_world(w)
	_bubbles.bind_world(w)
	_news.clear()
	_build_region_rows(w)
	_build_upgrade_tabs(w)
	_legend.text = _legend_text(w)
	_opp_box.visible = w.opposition.enabled
	_start_btn.text = "在此地区开始"
	if w.started:
		_log("已读取存档。")
	else:
		_log("[b]%s[/b]：点击地图选择起源地区，然后点“在此地区开始”。拖动平移，滚轮缩放。" % w.label("agent"))
	_refresh()


func _legend_text(w: SimWorld) -> String:
	var items := [["converted", w.label("converted", "已转化")]]
	if w.uses_secularism():
		items.append(["zealot", w.label("zealot", "狂信徒")])
		items.append(["lapsed", w.label("lapsed", "无神论者")])
	var parts := PackedStringArray()
	for it in items:
		parts.append("[color=%s]■[/color] %s" % [w.map_colors.get(it[0], "#ffffff"), it[1]])
	return "  ".join(parts)


func _build_region_rows(w: SimWorld) -> void:
	_region_tree.clear()
	_region_items.clear()
	var titles := ["地区", w.label("converted", "已转化"), w.label("zealot", "狂信徒"), w.label("lapsed", "无神论者")]
	if not w.uses_secularism():
		titles = ["地区", w.label("converted", "已转化"), "警觉", ""]
	for i in 4:
		_region_tree.set_column_title(i, titles[i])
	var root := _region_tree.create_item()
	var list := w.region_list()
	list.sort_custom(func(a: Region, b: Region) -> bool: return a.base_population > b.base_population)
	for r: Region in list:
		var it := _region_tree.create_item(root)
		it.set_metadata(0, r.id)
		it.set_text(0, r.display_name)
		_region_items[r.id] = it


func _build_upgrade_tabs(w: SimWorld) -> void:
	for page in _upgrade_pages:
		_tabs.remove_child(page)  # 立即移除，避免与新分页重名
		page.queue_free()
	_upgrade_pages.clear()
	_upgrade_btns.clear()
	var boxes := {}
	var at := 0
	for cat in w.upgrades.categories():
		var scroll := ScrollContainer.new()
		scroll.name = String(w.categories.get(cat, cat))
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(box)
		_tabs.add_child(scroll)
		_tabs.move_child(scroll, at)
		_tabs.set_tab_title(at, String(w.categories.get(cat, cat)))
		at += 1
		_upgrade_pages.append(scroll)
		boxes[cat] = box
	_tabs.current_tab = 0
	for id in w.upgrades.order:
		var d: Dictionary = w.upgrades.defs[id]
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = _upgrade_tooltip(w, d)
		b.pressed.connect(func() -> void:
			var reason := Game.world.buy_upgrade(id)
			if reason != "":
				_log("无法购买 %s：%s" % [d.get("name", id), reason]))
		boxes[String(d.get("category", "misc"))].add_child(b)
		_upgrade_btns[id] = b


const STAT_NAMES := {
	"spread": "地区内传播", "cross_land": "陆路传播", "cross_sea": "海路传播", "cross_air": "远途传播",
	"zeal": "狂热度", "zealot_spread": "狂信徒传教力", "secular_resist": "抵御世俗化", "revival": "无神论者回流",
	"points_bonus": "信仰点获取", "resist_climate_hot": "炎热地区适应", "resist_climate_cold": "寒冷地区适应",
	"resist_climate_temperate": "温带地区适应", "resist_wealth_rich": "富裕社会适应", "resist_wealth_mid": "中等收入社会适应",
	"resist_wealth_poor": "贫困社会适应", "visibility": "可见度", "lethality": "致命性", "counter_resist": "减缓反制",
}


func _upgrade_tooltip(w: SimWorld, d: Dictionary) -> String:
	var lines := PackedStringArray([String(d.get("desc", ""))])
	var eff: Dictionary = d.get("effects", {})
	for k in eff:
		var v := float(eff[k])
		lines.append("%s %s%s" % [STAT_NAMES.get(k, k), "+" if v >= 0.0 else "", str(v)])
	var reqs: Array = d.get("requires", [])
	if not reqs.is_empty():
		var names := PackedStringArray()
		for r in reqs:
			names.append(String(w.upgrades.defs[r].get("name", r)))
		lines.append("前置：" + "、".join(names))
	if d.has("min_year"):
		lines.append("公元 %d 年后可用" % int(d["min_year"]))
	return "\n".join(lines)


# ---------------------------------------------------------------- 刷新

func _refresh() -> void:
	var w := Game.world
	if w == null:
		return
	_refresh_top()
	for id in _region_items:
		var r: Region = w.regions[id]
		var it: TreeItem = _region_items[id]
		if w.uses_secularism():
			it.set_text(1, _pct(r.converted_ratio(), r.converted))
			it.set_text(2, _pct(r.zealot_ratio(), r.zealots))
			it.set_text(3, _pct(r.lapsed_ratio(), r.lapsed))
		else:
			it.set_text(1, _pct(r.converted_ratio(), r.converted))
			it.set_text(2, "%.0f%%" % (r.awareness * 100.0))
	_map.refresh()
	_refresh_detail()
	_refresh_upgrades()


func _refresh_top() -> void:
	var w := Game.world
	var t := w.totals()
	var living: float = maxf(t.living, 1.0)
	var parts := PackedStringArray([
		w.date_text(),
		"%s %d" % [w.label("points", "点数"), w.points],
		"%s %s (%.1f%%)" % [w.label("converted", "已转化"), _fmt(t.converted), t.converted / living * 100.0],
	])
	if w.uses_secularism():
		parts.append("%s %.1f%%" % [w.label("zealot", "狂信徒"), t.zealots / living * 100.0])
		parts.append("%s %.1f%%" % [w.label("lapsed", "无神论者"), t.lapsed / living * 100.0])
	elif t.removed > 0.0:
		parts.append("%s %s" % [w.label("removed", "已移除"), _fmt(t.removed)])
	_info.text = "   ".join(parts)
	_info.tooltip_text = "覆盖 %d/%d 个地区\n世界人口 %s\n%s %s   %s %s" % [t.reached, w.regions.size(), _fmt(t.population), w.label("zealot", "狂信徒"), _fmt(t.zealots),
		w.label("lapsed", "无神论者"), _fmt(t.lapsed)]
	if w.uses_secularism():
		var start := int(w.rules["secularism"].get("start_year", 0))
		_era.text = "%s：%s" % [w.label("secularism", "世俗化"), "进行中" if w.secular_era() else "公元 %d 年起" % start]
		_era.modulate = Color(0.55, 0.75, 1.0) if w.secular_era() else Color(1, 1, 1, 0.6)
	else:
		_era.text = ""
	_opp_bar.value = w.opposition.progress * 100.0


func _refresh_detail() -> void:
	var w := Game.world
	var id := _map.selected_id
	_start_btn.disabled = w == null or w.started or id == ""
	_start_btn.visible = w != null and not w.started
	if w == null or id == "" or not w.regions.has(id):
		_detail.text = "[color=#999]点击地图上的地区查看详情[/color]"
		return
	var r: Region = w.regions[id]
	var climate: String = {"hot": "炎热", "temperate": "温和", "cold": "寒冷"}.get(r.traits.get("climate", ""), "?")
	var wealth: String = {"rich": "富裕", "mid": "中等", "poor": "贫困"}.get(r.traits.get("wealth", ""), "?")
	var lines := PackedStringArray()
	lines.append("[b]%s[/b]   人口 %s   %s / %s" % [r.display_name, _fmt(r.population), climate, wealth])
	lines.append("%s %s (%.1f%%)" % [w.label("converted", "已转化"), _fmt(r.converted), r.converted_ratio() * 100.0])
	if w.uses_secularism():
		lines.append("%s %s (%.1f%%)   %s %s (%.1f%%)" % [w.label("zealot", "狂信徒"), _fmt(r.zealots), r.zealot_ratio() * 100.0,
			w.label("lapsed", "无神论者"), _fmt(r.lapsed), r.lapsed_ratio() * 100.0])
	if w.uses_awareness():
		var closed := "、".join(PackedStringArray(r.closed_link_types.keys()))
		lines.append("警觉 %.0f%%%s" % [r.awareness * 100.0, ("   已封锁：" + closed) if closed != "" else ""])
	for e in w.active_effects:
		if e.scope == "global" or e.region == id:
			lines.append("[color=#b89cff]✦ %s[/color]（剩 %d 年）" % [e.name, int(e.until) - w.tick])
	if r.countries.size() > 1:
		var names := PackedStringArray()
		for c in r.countries:
			if _map.country_by_id.has(c):
				names.append(String(_map.country_by_id[c]["name"]))
		lines.append("[color=#999]包含：%s[/color]" % "、".join(names))
	_detail.text = "\n".join(lines)


func _refresh_upgrades() -> void:
	var w := Game.world
	if w == null:
		return
	var y := w.year()
	for id in _upgrade_btns:
		var b: Button = _upgrade_btns[id]
		var d: Dictionary = w.upgrades.defs[id]
		var owned := w.upgrades.is_owned(id)
		var state := ""
		if owned:
			state = "✔ "
		elif not w.upgrades.is_unlocked(id):
			state = "🔒 "
		elif y < w.upgrades.min_year(id):
			state = "⏳%d " % w.upgrades.min_year(id)
		b.text = "%s%s  [%d]" % [state, d.get("name", id), int(d.get("cost", 0))]
		b.disabled = owned or w.upgrades.check_buy(id, w.points, y) != ""


func _on_region_selected() -> void:
	var it := _region_tree.get_selected()
	if it == null:
		return
	var id := String(it.get_metadata(0))
	_map.select(id)
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
	var w := Game.world
	var head := "胜利！" if won else "失败"
	if w.grade != "":
		head += "  评级 %s" % w.grade
	_over_dialog.dialog_text = "%s\n%s\n%s" % [head, reason, w.date_text()]
	_over_dialog.popup_centered()


func _log(text: String) -> void:
	var date: String = Game.world.date_text() if Game.world else ""
	_news.append_text("[color=#888]%s[/color] %s\n" % [date, text])


static func _pct(ratio: float, count: float) -> String:
	return "-" if count < 1.0 else "%.1f%%" % (ratio * 100.0)


static func _fmt(n: float) -> String:
	if n >= 1e9:
		return "%.2fB" % (n / 1e9)
	if n >= 1e6:
		return "%.1fM" % (n / 1e6)
	if n >= 1e3:
		return "%.1fK" % (n / 1e3)
	return "%d" % int(n)
