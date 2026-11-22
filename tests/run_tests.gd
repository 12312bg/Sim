extends SceneTree
## 无界面测试：
##   godot --headless --path . --import
##   godot --headless --path . -s res://tests/run_tests.gd

const SCENARIO := "res://data/scenarios/default.json"
const UPGRADES := "res://data/upgrades/default.json"

var _failures := 0
var _checks := 0


func _init() -> void:
	for t in ["test_data_loads", "test_upgrade_rules", "test_spread_and_points",
			"test_determinism", "test_game_ends", "test_save_roundtrip", "test_balance_report"]:
		print("== ", t)
		call(t)
	print("\n%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		printerr("  FAIL: ", msg)


func make_world(seed_value: int = 42) -> SimWorld:
	var w := SimWorld.new()
	w.setup(DataLoader.load_scenario(SCENARIO), DataLoader.load_upgrades(UPGRADES), seed_value)
	return w


func run_days(w: SimWorld, n: int) -> void:
	for i in n:
		if w.finished:
			return
		w.step()


func test_data_loads() -> void:
	var w := make_world()
	check(w.regions.size() >= 2, "scenario has regions")
	check(w.links.size() >= 1, "scenario has links")
	check(w.upgrades.order.size() >= 1, "upgrades loaded")
	check(w.points > 0, "starting points from rules")


func test_upgrade_rules() -> void:
	var w := make_world()
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
	var w := make_world()
	w.start_in("midlands")
	var p0 := w.points
	run_days(w, 120)
	var t := w.totals()
	check(t.converted > 1000.0, "converted grows (%.0f)" % t.converted)
	check(t.reached > 1, "spread to other regions (%d)" % t.reached)
	check(w.points > p0, "points earned (%d -> %d)" % [p0, w.points])


func test_determinism() -> void:
	var a := make_world(7)
	var b := make_world(7)
	a.start_in("sunlands")
	b.start_in("sunlands")
	run_days(a, 200)
	run_days(b, 200)
	check(JSON.stringify(a.to_dict()) == JSON.stringify(b.to_dict()), "same seed -> same state")


func test_game_ends() -> void:
	var w := make_world(3)
	w.start_in("jade_delta")
	run_days(w, 3000)
	check(w.finished, "game reaches an outcome within 3000 days (day %d)" % w.day)


func test_save_roundtrip() -> void:
	var a := make_world(11)
	a.start_in("iron_coast")
	run_days(a, 60)
	var saved: Dictionary = JSON.parse_string(JSON.stringify(a.to_dict(), "", true, true))
	var b := make_world(999)
	b.apply_state(saved)
	run_days(a, 80)
	run_days(b, 80)
	check(JSON.stringify(a.to_dict()) == JSON.stringify(b.to_dict()), "save/load continues identically")


## 不是断言：打印几种简单策略的结局，供调参参考。
func test_balance_report() -> void:
	var strategies := {
		"不买升级": [],
		"传播优先": ["potency_1", "land_1", "air_1", "sea_1", "potency_2", "air_2", "sea_2", "land_2", "potency_3",
				"cold_1", "wealth_1", "cold_2", "wealth_2"],
		"隐匿优先": ["stealth_1", "potency_1", "land_1", "air_1", "stealth_2", "sea_1", "potency_2", "wealth_1",
				"cold_1", "air_2", "sea_2", "wealth_2", "cold_2", "potency_3"],
	}
	for name in strategies:
		var wins := 0
		var days := 0
		for s in 20:
			var w := make_world(1000 + s)
			w.start_in("sunlands")
			var queue: Array = strategies[name].duplicate()
			while not w.finished and w.day < 3000:
				while not queue.is_empty() and w.buy_upgrade(queue[0]) == "":
					queue.pop_front()
				w.step()
			wins += 1 if w.won else 0
			days += w.day
		print("  %s: 胜率 %d/20, 平均 %d 天" % [name, wins, days / 20])
