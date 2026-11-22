extends Control
## 调试用主界面：纯代码搭建，先验证玩法循环，美术与地图之后替换。
## 布局：顶栏（状态/速度/存读档） | 左：地区表 | 右：升级树 | 底：新闻滚动

const CATEGORY_NAMES := {"transmission": "传播途径", "traits": "特性", "abilities": "能力"}

var _info: Label
var _opp_bar: ProgressBar
var _start_btn: Button
var _speed_btns: Array[Button] = []
var _region_tree: Tree
var _region_items: Dictionary = {}   # id -> TreeItem
var _upgrade_tabs: TabContainer
var _upgrade_btns: Dictionary = {}   # id -> Button
var _news: RichTextLabel
var _over_dialog: AcceptDialog


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	Game.session_started.connect(_on_session_started)
	Game.speed_changed.connect(_on_speed_changed)
	Game.new_game()


# ---------------------------------------------------------------- 搭建

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.1, 0.12)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# 顶栏
	var top := HBoxContainer.new()
	root.add_child(top)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_info)
	_opp_bar = ProgressBar.new()
	_opp_bar.custom_minimum_size = Vector2(160, 0)
	_opp_bar.max_value = 100
	_opp_bar.tooltip_text = "反制进度"
	top.add_child(_opp_bar)
	_start_btn = _add_button(top, "在选中地区开始", _on_start_pressed)
	for i in Game.SECONDS_PER_DAY.size():
		var b := _add_button(top, "暂停" if i == 0 else "%dx" % i, Game.set_speed.bind(i))
		b.toggle_mode = true
		_speed_btns.append(b)
	_add_button(top, "新游戏", func() -> void: Game.new_game())
	_add_button(top, "存档", func() -> void: _log("已存档" if Game.save_game() else "存档失败"))
	_add_button(top, "读档", func() -> void:
		if not Game.load_game():
			_log("没有存档"))

	# 中部
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	_region_tree = Tree.new()
	_region_tree.columns = 5
	_region_tree.column_titles_visible = true
	_region_tree.hide_root = true
	_region_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in 5:
		_region_tree.set_column_title(i, ["地区", "人口", "已转化", "警觉", "封锁"][i])
	_region_tree.set_column_expand_ratio(0, 2)
	split.add_child(_region_tree)

	_upgrade_tabs = TabContainer.new()
	_upgrade_tabs.custom_minimum_size = Vector2(360, 0)
	split.add_child(_upgrade_tabs)

	# 底部新闻
	_news = RichTextLabel.new()
	_news.custom_minimum_size = Vector2(0, 120)
	_news.scroll_following = true
	root.add_child(_news)

	_over_dialog = AcceptDialog.new()
	_over_dialog.title = "对局结束"
	add_child(_over_dialog)


func _add_button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


# ---------------------------------------------------------------- 对局绑定

func _on_session_started(w: SimWorld) -> void:
	w.day_advanced.connect(func(_d: int) -> void: _refresh())
	w.points_changed.connect(func(_p: int) -> void: _refresh_upgrades())
	w.upgrade_purchased.connect(func(_id: String) -> void: _refresh_upgrades())
	w.region_reached.connect(func(_id: String) -> void: _refresh())
	w.news.connect(_log)
	w.game_over.connect(_on_game_over)
	_news.clear()
	_build_region_rows(w)
	_build_upgrade_tabs(w)
	_log("选择一个地区，然后点击“在选中地区开始”。" if not w.started else "已读取存档。")
	_refresh()


func _build_region_rows(w: SimWorld) -> void:
	_region_tree.clear()
	_region_items.clear()
	var root := _region_tree.create_item()
	for r: Region in w.region_list():
		var it := _region_tree.create_item(root)
		it.set_metadata(0, r.id)
		_region_items[r.id] = it


func _build_upgrade_tabs(w: SimWorld) -> void:
	for c in _upgrade_tabs.get_children():
		c.queue_free()
	_upgrade_btns.clear()
	var boxes := {}
	for cat in w.upgrades.categories():
		var scroll := ScrollContainer.new()
		scroll.name = CATEGORY_NAMES.get(cat, cat)
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(box)
		_upgrade_tabs.add_child(scroll)
		boxes[cat] = box
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
	_info.text = "第 %d 天   %s %d   %s %s / %s   %s %s   覆盖 %d/%d 地区" % [
		w.day, w.label("points", "点数"), w.points,
		w.label("converted", "已转化"), _fmt(t.converted), _fmt(t.population),
		w.label("removed", "已移除"), _fmt(t.removed),
		t.reached, w.regions.size()]
	_opp_bar.value = w.opposition.progress * 100.0
	_opp_bar.tooltip_text = "%s：%s" % [w.label("opposition", "反制"), "进行中" if w.opposition.active else "未开始"]
	_start_btn.disabled = w.started
	for r: Region in w.region_list():
		var it: TreeItem = _region_items[r.id]
		it.set_text(0, r.display_name)
		it.set_text(1, _fmt(r.living()))
		it.set_text(2, "%s (%.1f%%)" % [_fmt(r.converted), r.converted_ratio() * 100.0])
		it.set_text(3, "%.0f%%" % (r.awareness * 100.0))
		it.set_text(4, ",".join(PackedStringArray(r.closed_link_types.keys())))
	_refresh_upgrades()


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


func _on_start_pressed() -> void:
	var it := _region_tree.get_selected()
	if it == null:
		_log("请先在左侧选择一个地区。")
		return
	Game.world.start_in(String(it.get_metadata(0)))
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
