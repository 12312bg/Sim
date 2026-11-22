class_name SimWorld
extends RefCounted
## 模拟核心：持有全部状态，按“天”推进。不依赖场景树，可在无界面测试中直接运行。
##
## 用法：
##   var w := SimWorld.new()
##   w.setup(scenario_dict, upgrade_list, seed)
##   w.start_in("region_id")
##   w.step()   # 推进一天

signal day_advanced(day: int)
signal region_reached(region_id: String)
signal points_changed(points: int)
signal upgrade_purchased(upgrade_id: String)
signal opposition_started()
signal news(text: String)
signal game_over(won: bool, reason: String)

enum WinCondition { CONVERT_ALL, REMOVE_ALL }

var day: int = 0
var regions: Dictionary = {}          # id -> Region
var region_order: Array[String] = []
var links: Array[Dictionary] = []     # {a, b, type, weight}
var rules: Dictionary = {}
var labels: Dictionary = {}
var upgrades := UpgradeTree.new()
var opposition := Opposition.new()
var points: int = 0
var rng := RandomNumberGenerator.new()
var started: bool = false
var finished: bool = false
var won: bool = false
var win_condition: WinCondition = WinCondition.CONVERT_ALL

var _point_progress: float = 0.0  # 尚未兑换成点数的转化人数


func setup(scenario: Dictionary, upgrade_defs: Array, seed_value: int = 0) -> void:
	day = 0
	started = false
	finished = false
	won = false
	_point_progress = 0.0
	rng.seed = seed_value
	rules = scenario.get("rules", {})
	labels = scenario.get("labels", {})
	win_condition = WinCondition.REMOVE_ALL if rules.get("win_condition", "") == "remove_all" else WinCondition.CONVERT_ALL

	regions.clear()
	region_order.clear()
	for rd in scenario.get("regions", []):
		var r := Region.from_dict(rd)
		assert(not regions.has(r.id), "duplicate region id: %s" % r.id)
		regions[r.id] = r
		region_order.append(r.id)

	links.clear()
	for ld in scenario.get("links", []):
		assert(regions.has(ld.get("a")) and regions.has(ld.get("b")), "link to unknown region: %s" % [ld])
		links.append(ld)

	upgrades.load_defs(upgrade_defs)
	opposition = Opposition.new()
	opposition.configure(rules.get("opposition", {}))
	points = int(rules.get("points", {}).get("start", 0))


func label(key: String, fallback: String) -> String:
	return String(labels.get(key, fallback))


func region_list() -> Array:
	var out := []
	for id in region_order:
		out.append(regions[id])
	return out


func start_in(region_id: String) -> void:
	assert(not started, "already started")
	assert(regions.has(region_id), "unknown region %s" % region_id)
	var r: Region = regions[region_id]
	r.converted = float(rules.get("seed_amount", 1.0))
	started = true
	news.emit("%s 出现在 %s" % [label("agent", "传播体"), r.display_name])
	region_reached.emit(region_id)


func buy_upgrade(upgrade_id: String) -> String:
	var reason := upgrades.check_buy(upgrade_id, points)
	if reason != "":
		return reason
	points -= upgrades.cost_of(upgrade_id)
	upgrades.mark_owned(upgrade_id)
	upgrade_purchased.emit(upgrade_id)
	points_changed.emit(points)
	return ""


func add_points(amount: int) -> void:
	if amount == 0:
		return
	points += amount
	points_changed.emit(points)


## 推进一天。顺序：内部传播 -> 移除 -> 警觉/封锁 -> 跨区传播 -> 反制 -> 点数 -> 结算。
func step() -> void:
	if not started or finished:
		return
	day += 1
	var stats := upgrades.stats()
	var new_converts := 0.0

	for r: Region in region_list():
		var g := SpreadModel.internal_growth(r, stats, rules)
		r.converted += g
		new_converts += g
		var d := SpreadModel.removal(r, stats, rules)
		r.converted -= d
		r.removed += d
		r.awareness = minf(r.awareness + SpreadModel.awareness_gain(r, stats, rules), 1.0)
		_update_closures(r)

	_cross_region_spread(stats)

	if opposition.step(region_list(), stats):
		opposition_started.emit()
		news.emit("%s 已经开始" % label("opposition", "反制"))

	_award_points(new_converts, stats)
	day_advanced.emit(day)
	_check_outcome()


func _update_closures(r: Region) -> void:
	var threshold := float(rules.get("closure_threshold", 0.6))
	if r.awareness < threshold:
		return
	for t in rules.get("closure_types", []):
		if not r.closed_link_types.has(t):
			r.closed_link_types[t] = true
			news.emit("%s 关闭了 %s 通道" % [r.display_name, t])


func _cross_region_spread(stats: Dictionary) -> void:
	# 先收集再应用，保证同一天内的结果与连接遍历顺序无关（除 RNG 序列外）。
	var to_seed: Array[String] = []
	for link in links:
		var a: Region = regions[link["a"]]
		var b: Region = regions[link["b"]]
		for pair in [[a, b], [b, a]]:
			var src: Region = pair[0]
			var dst: Region = pair[1]
			var p := SpreadModel.link_probability(src, dst, link, stats, rules)
			if p > 0.0 and rng.randf() < p and not to_seed.has(dst.id):
				to_seed.append(dst.id)
	var seed_amount := float(rules.get("seed_amount", 1.0))
	for id in to_seed:
		var r: Region = regions[id]
		r.converted = minf(seed_amount, r.susceptible())
		news.emit("%s 抵达 %s" % [label("agent", "传播体"), r.display_name])
		region_reached.emit(id)
		add_points(int(rules.get("points", {}).get("per_new_region", 0)))


func _award_points(new_converts: float, stats: Dictionary) -> void:
	var cfg: Dictionary = rules.get("points", {})
	var chunk := float(cfg.get("convert_chunk", 0.0))
	var gained := 0
	if chunk > 0.0:
		_point_progress += new_converts
		while _point_progress >= chunk:
			_point_progress -= chunk
			gained += 1
	# 随机“气泡”奖励（暂时自动拾取；UI 交互留到后续迭代）。
	var bubble_chance := float(cfg.get("bubble_chance", 0.0))
	if bubble_chance > 0.0 and rng.randf() < bubble_chance:
		gained += int(cfg.get("bubble_value", 1))
	gained = int(round(gained * (1.0 + float(stats.get("points_bonus", 0.0)))))
	add_points(gained)


func totals() -> Dictionary:
	var t := {"population": 0.0, "converted": 0.0, "removed": 0.0, "susceptible": 0.0, "reached": 0}
	for r: Region in region_list():
		t.population += r.population
		t.converted += r.converted
		t.removed += r.removed
		t.susceptible += r.susceptible()
		if r.has_presence() or r.removed >= 1.0:
			t.reached += 1
	return t


func _check_outcome() -> void:
	var t := totals()
	match win_condition:
		WinCondition.CONVERT_ALL:
			if t.susceptible < 1.0:
				_finish(true, "全世界都已被%s" % label("converted_verb", "转化"))
				return
		WinCondition.REMOVE_ALL:
			if t.population - t.removed < 1.0:
				_finish(true, "已无人幸存")
				return
	if opposition.is_complete():
		_finish(false, "%s 已完成" % label("opposition", "反制"))
	elif t.converted < 1.0:
		_finish(false, "%s 已消亡" % label("agent", "传播体"))


func _finish(is_win: bool, reason: String) -> void:
	finished = true
	won = is_win
	news.emit(reason)
	game_over.emit(is_win, reason)


## 存档：只保存可变状态，静态数据从 scenario 重新加载。
func to_dict() -> Dictionary:
	var rs := []
	for r: Region in region_list():
		rs.append(r.to_dict())
	return {
		"day": day,
		"points": points,
		"started": started,
		"finished": finished,
		"won": won,
		"point_progress": _point_progress,
		"rng_state": str(rng.state),  # 字符串保存，避免 JSON 浮点丢失 64 位精度
		"owned": upgrades.owned.keys(),
		"opposition": opposition.to_dict(),
		"regions": rs,
	}


func apply_state(d: Dictionary) -> void:
	day = int(d.get("day", 0))
	points = int(d.get("points", 0))
	started = bool(d.get("started", false))
	finished = bool(d.get("finished", false))
	won = bool(d.get("won", false))
	_point_progress = float(d.get("point_progress", 0.0))
	if d.has("rng_state"):
		rng.state = String(d["rng_state"]).to_int()
	upgrades.owned.clear()
	for id in d.get("owned", []):
		upgrades.mark_owned(String(id))
	opposition.apply_state(d.get("opposition", {}))
	for rd in d.get("regions", []):
		if regions.has(rd.get("id")):
			regions[rd["id"]].apply_state(rd)
