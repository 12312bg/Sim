extends SceneTree
## 无界面测试：
##   godot --headless --path . --import
##   godot --headless --path . -s res://tests/run_tests.gd
## 只跑名字包含关键字的测试：在命令末尾加 -- religion

const PROTO_SCENARIO := "res://data/scenarios/default.json"
const PROTO_THEME := "res://data/themes/prototype.json"
const RELIGION_THEME := "res://data/themes/religion.json"

var _failures := 0
var _checks := 0


func _init() -> void:
	var only := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		only = args[0]
	for t in ["test_data_loads", "test_upgrade_rules", "test_spread_and_points", "test_determinism",
			"test_game_ends", "test_save_roundtrip", "test_bubbles",
			"test_religion_setup", "test_religion_population", "test_religion_secularism",
			"test_religion_year_gates", "test_religion_events", "test_religion_ends", "test_religion_save",
			"test_balance_report", "test_religion_balance_report"]:
		if only != "" and not t.contains(only):
			continue
		print("== ", t)
		call(t)
	print("\n%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		printerr("  FAIL: ", msg)


func make_proto(seed_value: int = 42) -> SimWorld:
	var w := SimWorld.new()
	w.setup(DataLoader.load_scenario(PROTO_SCENARIO), DataLoader.load_theme(PROTO_THEME), seed_value)
	return w


func make_religion(seed_value: int = 42, name: String = "测试之信") -> SimWorld:
	var theme := DataLoader.load_theme(RELIGION_THEME)
	var w := SimWorld.new()
	w.setup(DataLoader.load_scenario(theme["scenario"]), theme, seed_value, name)
	return w


## 推进若干回合；collect=true 时模拟“完美玩家”，每回合收集所有气泡。
func run_ticks(w: SimWorld, n: int, collect: bool = true) -> void:
	for i in n:
		if w.finished:
			return
		w.step()
		if collect:
			w.collect_all_bubbles()


# ---------------------------------------------------------------- 原型主题

func test_data_loads() -> void:
	var w := make_proto()
	check(w.regions.size() >= 2, "scenario has regions")
	check(w.links.size() >= 1, "scenario has links")
	check(w.upgrades.order.size() >= 1, "upgrades loaded")
	check(w.points > 0, "starting points from rules")
	check(not w.uses_years() and w.date_text() == "第 0 天", "prototype counts days")
	var visible := DataLoader.list_themes()
	check(visible.size() == 1 and visible[0]["id"] == "religion", "only religion is listed to players")


func test_upgrade_rules() -> void:
	var w := make_proto()
	w.points = 100
	check(w.buy_upgrade("land_2") == "前置未满足", "prereq enforced")
	check(w.buy_upgrade("land_1") == "", "can buy root upgrade")
	check(w.points == 95, "cost deducted")
	check(w.buy_upgrade("land_1") == "已拥有", "cannot double buy")
	check(w.buy_upgrade("land_2") == "", "prereq satisfied")
	check(is_equal_approx(w.upgrades.stat("cross_land"), 1.4), "effects aggregate")
	w.points = 0
	check(w.buy_upgrade("sea_1") == "点数不足", "insufficient points")


func test_spread_and_points() -> void:
	var w := make_proto()
	w.start_in("midlands")
	var p0 := w.points
	run_ticks(w, 120)
	var t := w.totals()
	check(t.converted > 1000.0, "converted grows (%.0f)" % t.converted)
	check(t.reached > 1, "spread to other regions (%d)" % t.reached)
	check(w.points > p0, "points earned via bubbles (%d -> %d)" % [p0, w.points])


func test_determinism() -> void:
	var a := make_proto(7)
	var b := make_proto(7)
	a.start_in("sunlands")
	b.start_in("sunlands")
	run_ticks(a, 200)
	run_ticks(b, 200)
	check(JSON.stringify(a.to_dict()) == JSON.stringify(b.to_dict()), "same seed -> same state")


func test_game_ends() -> void:
	var w := make_proto(3)
	w.start_in("jade_delta")
	run_ticks(w, 3000)
	check(w.finished, "game reaches an outcome within 3000 days (day %d)" % w.tick)


func test_save_roundtrip() -> void:
	var a := make_proto(11)
	a.start_in("iron_coast")
	run_ticks(a, 150, false)  # 不收集，让存档里带着待收集的气泡
	check(not a.bubbles.is_empty(), "bubbles pending before save")
	var saved: Dictionary = Marshalls.base64_to_variant(Marshalls.variant_to_base64(a.to_dict()))
	var b := make_proto(999)
	b.apply_state(saved)
	check(b.bubbles.size() == a.bubbles.size(), "bubbles restored")
	run_ticks(a, 80)
	run_ticks(b, 80)
	check(JSON.stringify(a.to_dict()) == JSON.stringify(b.to_dict()), "save/load continues identically")


func test_bubbles() -> void:
	var w := make_proto(5)
	w.start_in("midlands")
	run_ticks(w, 150, false)
	var n := w.bubbles.size()
	check(n > 0, "point bubbles appear (%d)" % n)
	check(n <= int(w.rules["bubbles"]["max"]), "bubble count capped")
	var id: int = w.bubbles.keys()[0]
	var value := int(w.bubbles[id].value)
	var before := w.points
	check(w.collect_bubble(id) and w.points == before + value, "collecting adds its value")
	check(not w.collect_bubble(id), "cannot collect twice")
	var id2: int = w.bubbles.keys()[0] if not w.bubbles.is_empty() else -1
	if id2 >= 0:
		before = w.points
		w.discard_bubble(id2)
		check(w.points == before and not w.bubbles.has(id2), "discarded bubble gives nothing")


# ---------------------------------------------------------------- 宗教主题

func test_religion_setup() -> void:
	var w := make_religion()
	check(w.regions.size() >= 40 and w.regions.size() <= 50, "about 45 cultural regions (%d)" % w.regions.size())
	check(w.regions.has("china") and "CHN" in w.regions["china"].countries, "China region contains CHN")
	check(w.uses_years() and w.date_text() == "公元前 1000 年", "starts at 1000 BC (%s)" % w.date_text())
	check(w.label("agent") == "「测试之信」", "player-named religion")
	check(w.upgrades.categories() == ["transmission", "doctrine", "adaptation"], "three trees")
	check(not w.opposition.enabled, "opposition replaced by secularism")
	var map: Dictionary = DataLoader.load_json(w.map_path)
	var active := {}
	for m in map["regions"]:
		if m["active"]:
			active[m["id"]] = true
	var assigned := 0
	for r: Region in w.region_list():
		for c in r.countries:
			check(active.has(c), "country %s exists on map" % c)
			assigned += 1
	check(assigned == active.size(), "every active country belongs to exactly one region (%d/%d)" % [assigned, active.size()])
	var linked := {}
	for l in w.links:
		linked[l["a"]] = true
		linked[l["b"]] = true
	check(linked.size() == w.regions.size(), "every region has a link")


func test_religion_population() -> void:
	var w := make_religion()
	var p0: float = w.totals().population
	check(p0 > 40e6 and p0 < 60e6, "world population ~50M in 1000 BC (%.0fM)" % (p0 / 1e6))
	w.start_in("china")
	w.tick = 3018  # 2018 年；下一步到 2019 = 参考年
	w.step()
	var p1: float = w.totals().population
	check(absf(p1 - 7.67e9) / 7.67e9 < 0.02, "population back to modern in 2019 (%.2fB)" % (p1 / 1e9))


func test_religion_secularism() -> void:
	var w := make_religion()
	w.start_in("france")
	var fr: Region = w.regions["france"]
	w.tick = 2700  # 1700 年
	w.rules["zeal_decay"] = 0.0  # 排除狂热冷却，只观察世俗化
	fr.converted = fr.population * 0.9
	fr.zealots = fr.population * 0.3
	var z0 := fr.zealots / fr.population
	run_ticks(w, 50)
	check(fr.lapsed > 0.0, "atheists appear after 1650 (%.1f%%)" % (fr.lapsed_ratio() * 100.0))
	check(absf(fr.zealots / fr.population - z0) < 0.01, "zealots are immune to secularism")
	var rich_rate := SpreadModel.secular_rate(1900, w.regions["france"], {}, w.rules)
	var poor_rate := SpreadModel.secular_rate(1900, w.regions["sahel"], {}, w.rules)
	var late_rate := SpreadModel.secular_rate(2000, w.regions["france"], {}, w.rules)
	check(rich_rate > poor_rate * 2.0, "rich regions secularize faster")
	check(late_rate > rich_rate, "secularism accelerates over time")
	check(SpreadModel.secular_rate(1600, w.regions["france"], {}, w.rules) == 0.0, "no secularism before 1650")
	var lapsed0 := fr.lapsed
	w.points = 1000
	check(w.buy_upgrade("dc_creed") == "" and w.buy_upgrade("dc_forgive") == "" and w.buy_upgrade("dc_revival") == "", "buy revival")
	var back := SpreadModel.revival(fr, w.stats_for("france"), w.rules)
	check(back > 0.0 and back < lapsed0, "atheists flow back with revival (%.0f)" % back)


func test_religion_year_gates() -> void:
	var w := make_religion()
	w.points = 1000
	w.start_in("china")
	check(w.buy_upgrade("tr_word") == "" and w.buy_upgrade("tr_scroll") == "", "early upgrades available")
	check(w.buy_upgrade("tr_print") == "年代未到", "printing locked before 1450")
	w.tick = 2460  # 1460 年
	check(w.buy_upgrade("tr_print") == "", "printing unlocked after 1450")


func test_religion_events() -> void:
	var w := make_religion(21)
	w.start_in("india")
	var india: Region = w.regions["india"]
	india.converted = india.population * 0.2
	var ev := {}
	for e in w.events:
		if e["id"] == "miracle":
			ev = e
	var before := float(w.stats_for("india").get("spread", 0.0))
	w._apply_event(ev, "india")
	check(float(w.stats_for("india").get("spread", 0.0)) > before, "regional event boosts local stats")
	check(float(w.stats_for("china").get("spread", 0.0)) == float(w.upgrades.stat("spread")), "other regions unaffected")
	run_ticks(w, int(ev["duration"]) + 1)
	check(float(w.stats_for("india").get("spread", 0.0)) == float(w.upgrades.stat("spread")), "effect expires")
	var spawned := [0]  # lambda 按值捕获局部变量，用数组计数
	var w2 := make_religion(22)
	w2.start_in("india")
	w2.bubble_spawned.connect(func(b: Dictionary) -> void:
		if b.kind == "event":
			spawned[0] += 1)
	run_ticks(w2, 600)
	check(spawned[0] > 3, "event bubbles appear over centuries (%d)" % spawned[0])


func test_religion_ends() -> void:
	var w := make_religion(8)
	w.start_in("persia")
	run_ticks(w, 3200)
	check(w.finished, "religion game ends by 2100 (%s)" % w.date_text())
	check(w.grade != "", "has a grade (%s)" % w.grade)


func test_religion_save() -> void:
	var a := make_religion(13)
	a.start_in("nile")
	a.points = 200
	a.buy_upgrade("dc_creed")
	a.buy_upgrade("dc_prophecy")
	run_ticks(a, 2750, false)  # 进入世俗化时代，并留下待收集的气泡
	var saved: Dictionary = Marshalls.base64_to_variant(Marshalls.variant_to_base64(a.to_dict()))
	var b := make_religion(1, "")
	b.apply_state(saved)
	check(b.label("agent") == a.label("agent"), "religion name restored")
	run_ticks(a, 100)
	run_ticks(b, 100)
	check(JSON.stringify(a.to_dict()) == JSON.stringify(b.to_dict()), "religion save/load continues identically")


# ---------------------------------------------------------------- 平衡报告（不是断言）

func test_balance_report() -> void:
	_report(make_proto, "sunlands", {
		"不买升级": [],
		"传播优先": ["potency_1", "land_1", "air_1", "sea_1", "potency_2", "air_2", "sea_2", "land_2", "potency_3",
				"cold_1", "wealth_1", "cold_2", "wealth_2"],
		"隐匿优先": ["stealth_1", "potency_1", "land_1", "air_1", "stealth_2", "sea_1", "potency_2", "wealth_1",
				"cold_1", "air_2", "sea_2", "wealth_2", "cold_2", "potency_3"],
	}, 3000)


func test_religion_balance_report() -> void:
	_report(make_religion, "fertile", {
		"不买升级": [],
		"只买传播": ["tr_word", "tr_caravan", "tr_ship", "tr_scroll", "tr_silk", "tr_pilgrim", "tr_ocean", "tr_print",
				"tr_radio", "tr_net"],
		"传播+适应": ["tr_word", "tr_caravan", "ad_local", "tr_ship", "tr_scroll", "ad_city", "ad_north", "tr_silk",
				"tr_pilgrim", "ad_elite", "ad_tolerance", "tr_ocean", "tr_print", "ad_frost", "ad_philo", "ad_charity",
				"ad_reason", "ad_modern", "tr_radio", "tr_net"],
		"均衡": ["tr_word", "dc_creed", "tr_caravan", "ad_local", "tr_ship", "tr_scroll", "dc_prophecy", "ad_city",
				"tr_silk", "dc_mystic", "ad_north", "tr_pilgrim", "dc_ritual", "ad_elite", "dc_martyr", "tr_ocean",
				"tr_print", "dc_order", "ad_philo", "ad_charity", "dc_forgive", "ad_reason", "dc_revival", "dc_canon",
				"ad_modern", "ad_tolerance", "ad_frost", "dc_ascetic", "tr_radio", "tr_net"],
	}, 3200)


func _report(factory: Callable, start: String, strategies: Dictionary, max_ticks: int) -> void:
	for name in strategies:
		var wins := 0
		var ticks := 0
		var grades := {}
		var runs := 12
		for s in runs:
			var w: SimWorld = factory.call(1000 + s)
			w.start_in(start)
			var queue: Array = strategies[name].duplicate()
			while not w.finished and w.tick < max_ticks:
				while not queue.is_empty() and w.buy_upgrade(queue[0]) == "":
					queue.pop_front()
				w.step()
				w.collect_all_bubbles()
			wins += 1 if w.won else 0
			ticks += w.tick
			grades[w.grade] = int(grades.get(w.grade, 0)) + 1
		var w0: SimWorld = factory.call(0)
		var end_text := ""
		if w0.uses_years():
			w0.tick = ticks / runs
			end_text = "（平均结束于 %s）" % w0.date_text()
		print("  %s: 胜率 %d/%d, 平均 %d 回合%s, 评级 %s" % [name, wins, runs, ticks / runs, end_text, grades])
