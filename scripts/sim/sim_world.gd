class_name SimWorld
extends RefCounted
## 模拟核心：持有全部状态，按“回合”推进。不依赖场景树，可在无界面测试中直接运行。
## 一回合的长度由主题决定（原型主题 = 一天，宗教主题 = 一年）。
##
## 用法：
##   var w := SimWorld.new()
##   w.setup(scenario_dict, theme_dict, seed, "宗教名")
##   w.start_in("region_id")
##   w.step()                  # 推进一回合
##   w.collect_bubble(id)      # 玩家点击气泡
##
## 气泡只由模拟产生和结算；“多久没点就消失”按现实时间计算，由 Game 调用 discard_bubble。

signal tick_advanced(tick: int)
signal region_reached(region_id: String)
signal points_changed(points: int)
signal upgrade_purchased(upgrade_id: String)
signal opposition_started()
signal era_started(era: String)
signal bubble_spawned(bubble: Dictionary)
signal bubble_changed(bubble: Dictionary)
signal bubble_removed(bubble_id: int, collected: bool)
signal news(text: String)
signal game_over(won: bool, reason: String)

enum WinCondition { CONVERT_ALL, REMOVE_ALL }

var tick: int = 0
var regions: Dictionary = {}          # id -> Region
var region_order: Array[String] = []
var links: Array[Dictionary] = []     # {a, b, type, weight}
var rules: Dictionary = {}
var labels: Dictionary = {}
var theme_id: String = ""
var theme_name: String = ""
var agent_name: String = ""
## 时间设置：{unit: "day"|"year", start, end, seconds_per_tick: [...]}
var time_cfg: Dictionary = {}
var map_colors: Dictionary = {}
var categories: Dictionary = {}       # 升级分类 id -> 显示名
var events: Array = []                # 事件定义
## 场景关联的地图数据（res:// 路径），没有地图的场景为空。
var map_path: String = ""
var upgrades := UpgradeTree.new()
var opposition := Opposition.new()
var points: int = 0
var rng := RandomNumberGenerator.new()
var started: bool = false
var finished: bool = false
var won: bool = false
var grade: String = ""
var win_condition: WinCondition = WinCondition.CONVERT_ALL

## 气泡：id -> {id, kind: "points"|"event", region, value, event}
var bubbles: Dictionary = {}
## 生效中的事件效果：[{name, scope: "global"|"region", region, effects, until}]
var active_effects: Array = []

var _next_bubble_id: int = 1
var _point_progress: float = 0.0  # 尚未兑换成气泡的转化人数
var _population_curve: Array = []  # [[year, scale], ...]，scale 已相对参考年归一化
var _secular_announced: bool = false
var _stats_global: Dictionary = {}
var _stats_region: Dictionary = {}  # region_id -> 合并了地区事件效果的属性


func setup(scenario: Dictionary, theme: Dictionary, seed_value: int = 0, name: String = "") -> void:
	tick = 0
	started = false
	finished = false
	won = false
	grade = ""
	bubbles.clear()
	active_effects.clear()
	_next_bubble_id = 1
	_point_progress = 0.0
	_secular_announced = false
	rng.seed = seed_value

	theme_id = String(theme.get("id", ""))
	theme_name = String(theme.get("name", theme_id))
	rules = DataLoader.merge(scenario.get("rules", {}), theme.get("rules", {}))
	labels = DataLoader.merge(scenario.get("labels", {}), theme.get("labels", {}))
	time_cfg = theme.get("time", {"unit": "day"})
	map_colors = theme.get("map_colors", {})
	categories = theme.get("categories", {})
	events = theme.get("events", [])
	agent_name = name.strip_edges() if name.strip_edges() != "" else String(theme.get("default_agent_name", ""))
	map_path = String(scenario.get("map", ""))
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

	upgrades.load_defs(theme.get("upgrades", []))
	opposition = Opposition.new()
	opposition.configure(rules.get("opposition", {}))
	points = int(rules.get("points", {}).get("start", 0))

	_setup_population_curve(theme.get("population_curve", {}))
	_apply_population()
	_refresh_stats()


# ---------------------------------------------------------------- 查询

## 文案。agent 使用玩家起的名字（加书名号）。
func label(key: String, fallback: String = "") -> String:
	if key == "agent" and agent_name != "":
		return "「%s」" % agent_name
	return String(labels.get(key, fallback))


## 带 {agent} / {region} 占位符的新闻文案。
func format_news(template: String, region_id: String = "") -> String:
	var region_name: String = regions[region_id].display_name if regions.has(region_id) else ""
	return template.format({"agent": label("agent", "传播体"), "region": region_name})


func region_list() -> Array:
	var out := []
	for id in region_order:
		out.append(regions[id])
	return out


func uses_years() -> bool:
	return time_cfg.get("unit", "day") == "year"


## 当前年份（按天计时的主题返回极大值，便于年份门槛判断）。
func year() -> int:
	return int(time_cfg.get("start", 0)) + tick if uses_years() else 999999


func date_text() -> String:
	if not uses_years():
		return "第 %d 天" % tick
	var y := year()
	return "公元前 %d 年" % -y if y < 0 else "公元 %d 年" % y


func uses_secularism() -> bool:
	return not rules.get("secularism", {}).is_empty()


func secular_era() -> bool:
	return uses_secularism() and year() >= int(rules["secularism"].get("start_year", 0))


func uses_awareness() -> bool:
	return float(rules.get("awareness_rate", 0.02)) > 0.0


func stats_for(region_id: String) -> Dictionary:
	return _stats_region.get(region_id, _stats_global)


func totals() -> Dictionary:
	var t := {"population": 0.0, "living": 0.0, "converted": 0.0, "zealots": 0.0, "lapsed": 0.0,
		"removed": 0.0, "susceptible": 0.0, "reached": 0}
	for r: Region in region_list():
		t.population += r.population
		t.living += r.living()
		t.converted += r.converted
		t.zealots += r.zealots
		t.lapsed += r.lapsed
		t.removed += r.removed
		t.susceptible += r.susceptible()
		if r.has_presence() or r.removed >= 1.0:
			t.reached += 1
	return t


# ---------------------------------------------------------------- 玩家操作

func start_in(region_id: String) -> void:
	assert(not started, "already started")
	assert(regions.has(region_id), "unknown region %s" % region_id)
	var r: Region = regions[region_id]
	r.converted = minf(float(rules.get("seed_amount", 1.0)), r.susceptible())
	started = true
	news.emit(format_news(label("news_start", "{agent} 出现在 {region}"), region_id))
	region_reached.emit(region_id)


func buy_upgrade(upgrade_id: String) -> String:
	var reason := upgrades.check_buy(upgrade_id, points, year())
	if reason != "":
		return reason
	points -= upgrades.cost_of(upgrade_id)
	upgrades.mark_owned(upgrade_id)
	_refresh_stats()
	upgrade_purchased.emit(upgrade_id)
	points_changed.emit(points)
	return ""


func add_points(amount: int) -> void:
	if amount == 0:
		return
	points += amount
	points_changed.emit(points)


func collect_bubble(bubble_id: int) -> bool:
	if not bubbles.has(bubble_id) or finished:
		return false
	var b: Dictionary = bubbles[bubble_id]
	bubbles.erase(bubble_id)
	match String(b.kind):
		"points":
			add_points(int(b.value))
		"event":
			_apply_event(_event_def(String(b.event)), String(b.region))
	bubble_removed.emit(bubble_id, true)
	return true


func discard_bubble(bubble_id: int) -> void:
	if bubbles.erase(bubble_id):
		bubble_removed.emit(bubble_id, false)


func collect_all_bubbles() -> void:
	for id in bubbles.keys():
		collect_bubble(id)


# ---------------------------------------------------------------- 推进

## 推进一回合。顺序：人口 -> 各地区（传播/狂热/世俗化/回流/移除/警觉）-> 跨区传播 -> 反制 -> 气泡与事件 -> 结算。
func step() -> void:
	if not started or finished:
		return
	tick += 1
	_apply_population()
	_expire_effects()
	var y := year()
	if uses_secularism() and secular_era() and not _secular_announced:
		_secular_announced = true
		news.emit(format_news(label("news_secular", "世俗化浪潮兴起")))
		era_started.emit("secular")

	var new_by_region: Dictionary = {}
	var new_total := 0.0
	var sec_cfg: Dictionary = rules.get("secularism", {})
	for r: Region in region_list():
		var stats := stats_for(r.id)
		var gained := SpreadModel.internal_growth(r, stats, rules)
		r.converted += gained

		r.zealots = clampf(r.zealots + SpreadModel.zeal_change(r, stats, rules), 0.0, r.converted)

		var rate := SpreadModel.secular_rate(y, r, stats, rules)
		if rate > 0.0:
			var from_believers := (r.converted - r.zealots) * rate
			var from_others := r.susceptible() * rate * float(sec_cfg.get("susceptible_factor", 1.0))
			# 狂信徒不受世俗化影响
			r.converted -= from_believers
			r.lapsed += from_believers + from_others

		var back := SpreadModel.revival(r, stats, rules)
		r.lapsed -= back
		r.converted += back
		gained += back

		var d := SpreadModel.removal(r, stats, rules)
		if d > 0.0:
			r.zealots -= d * r.zealots / maxf(r.converted, 1e-9)
			r.converted -= d
			r.removed += d

		r.awareness = minf(r.awareness + SpreadModel.awareness_gain(r, stats, rules), 1.0)
		_update_closures(r)
		if gained > 0.0:
			new_by_region[r.id] = gained
			new_total += gained

	_cross_region_spread()

	if opposition.step(region_list(), _stats_global):
		opposition_started.emit()
		news.emit("%s 已经开始" % label("opposition", "反制"))

	_spawn_point_bubbles(new_by_region, new_total)
	_maybe_spawn_event()
	tick_advanced.emit(tick)
	_check_outcome()


func _update_closures(r: Region) -> void:
	var threshold := float(rules.get("closure_threshold", 0.6))
	if not uses_awareness() or r.awareness < threshold:
		return
	for t in rules.get("closure_types", []):
		if not r.closed_link_types.has(t):
			r.closed_link_types[t] = true
			news.emit("%s 关闭了%s通道" % [r.display_name, label("link_" + String(t), String(t))])


func _cross_region_spread() -> void:
	# 先收集再应用，保证同一回合内的结果与连接遍历顺序无关（除 RNG 序列外）。
	var to_seed: Array[String] = []
	for link in links:
		var a: Region = regions[link["a"]]
		var b: Region = regions[link["b"]]
		for pair in [[a, b], [b, a]]:
			var src: Region = pair[0]
			var dst: Region = pair[1]
			var p := SpreadModel.link_probability(src, dst, link, stats_for(src.id), rules)
			if p > 0.0 and rng.randf() < p and not to_seed.has(dst.id):
				to_seed.append(dst.id)
	var seed_amount := float(rules.get("seed_amount", 1.0))
	for id in to_seed:
		var r: Region = regions[id]
		r.converted = minf(seed_amount, r.susceptible())
		if r.converted <= 0.0:
			continue
		news.emit(format_news(label("news_arrive", "{agent} 抵达 {region}"), id))
		region_reached.emit(id)
		var v := int(rules.get("points", {}).get("per_new_region", 0))
		if v > 0:
			_spawn_bubble("points", id, v)


# ---------------------------------------------------------------- 人口

func _setup_population_curve(cfg: Dictionary) -> void:
	_population_curve.clear()
	if cfg.is_empty() or not uses_years():
		return
	var pts: Array = cfg.get("points", [])
	var ref_year := int(cfg.get("reference_year", 2019))
	var ref := _interp_log(pts, ref_year)
	for p in pts:
		_population_curve.append([int(p[0]), float(p[1]) / ref])


func _apply_population() -> void:
	if _population_curve.is_empty():
		return
	var s := _interp_log(_population_curve, year())
	for r: Region in region_list():
		r.rescale(r.base_population * s)


## 分段对数线性插值。
static func _interp_log(pts: Array, x: int) -> float:
	if pts.is_empty():
		return 1.0
	if x <= int(pts[0][0]):
		return float(pts[0][1])
	for i in range(1, pts.size()):
		if x <= int(pts[i][0]):
			var x0 := float(pts[i - 1][0])
			var x1 := float(pts[i][0])
			var t := (float(x) - x0) / maxf(x1 - x0, 1.0)
			return exp(lerpf(log(float(pts[i - 1][1])), log(float(pts[i][1])), t))
	return float(pts[-1][1])


# ---------------------------------------------------------------- 属性与事件效果

func _refresh_stats() -> void:
	_stats_global = upgrades.stats().duplicate()
	_stats_region.clear()
	for e in active_effects:
		if e.scope == "global":
			_add_effects(_stats_global, e.effects)
	for e in active_effects:
		if e.scope == "region" and regions.has(e.region):
			if not _stats_region.has(e.region):
				_stats_region[e.region] = _stats_global.duplicate()
			_add_effects(_stats_region[e.region], e.effects)


static func _add_effects(target: Dictionary, effects: Dictionary) -> void:
	for k in effects:
		target[k] = float(target.get(k, 0.0)) + float(effects[k])


func _expire_effects() -> void:
	var before := active_effects.size()
	active_effects = active_effects.filter(func(e: Dictionary) -> bool: return int(e.until) > tick)
	if active_effects.size() != before:
		_refresh_stats()


func _event_def(event_id: String) -> Dictionary:
	for e in events:
		if e.get("id", "") == event_id:
			return e
	return {}


func _apply_event(ev: Dictionary, region_id: String) -> void:
	if ev.is_empty():
		return
	var r: Region = regions.get(region_id)
	add_points(int(ev.get("points", 0)))
	if ev.has("effects") and int(ev.get("duration", 0)) > 0:
		active_effects.append({
			"name": ev.get("name", ""),
			"scope": ev.get("scope", "region"),
			"region": region_id,
			"effects": ev["effects"],
			"until": tick + int(ev["duration"]),
		})
		_refresh_stats()
	if r != null:
		if ev.has("convert_fraction"):
			var add := r.susceptible() * float(ev["convert_fraction"])
			r.converted += add
		if ev.has("zealot_fraction"):
			r.zealots = minf(r.zealots + (r.converted - r.zealots) * float(ev["zealot_fraction"]), r.converted)
	news.emit("【%s】%s" % [ev.get("name", ""), format_news(String(ev.get("news", "")), region_id)])


# ---------------------------------------------------------------- 气泡

func _spawn_bubble(kind: String, region_id: String, value: int, event_id: String = "") -> void:
	var cfg: Dictionary = rules.get("bubbles", {})
	var max_count := int(cfg.get("max", 8))
	if kind == "points":
		# 同一地区已有信仰点气泡：合并数值；气泡已满：并入最早的一个
		var target: Dictionary = {}
		for b in bubbles.values():
			if b.kind == "points" and b.region == region_id:
				target = b
				break
		if target.is_empty() and bubbles.size() >= max_count:
			for id in bubbles.keys():
				if bubbles[id].kind == "points":
					target = bubbles[id]
					break
		if not target.is_empty():
			target.value = int(target.value) + value
			bubble_changed.emit(target)
			return
	if bubbles.size() >= max_count:
		return
	var b := {"id": _next_bubble_id, "kind": kind, "region": region_id, "value": value, "event": event_id}
	_next_bubble_id += 1
	bubbles[b.id] = b
	bubble_spawned.emit(b)


func _spawn_point_bubbles(new_by_region: Dictionary, new_total: float) -> void:
	var cfg: Dictionary = rules.get("points", {})
	var ratio := float(cfg.get("convert_chunk_ratio", 0.0))
	if ratio <= 0.0 or new_total <= 0.0:
		return
	var chunk := ratio * maxf(totals().living, 1.0)
	_point_progress += new_total
	var count := 0
	while _point_progress >= chunk:
		_point_progress -= chunk
		count += 1
	if count == 0:
		return
	var bonus := maxf(float(stats_for("").get("points_bonus", 0.0)), 0.0)
	var value := count + int(floor(count * bonus))
	if rng.randf() < fmod(count * bonus, 1.0):
		value += 1
	_spawn_bubble("points", _weighted_pick(new_by_region), value)


func _maybe_spawn_event() -> void:
	var chance := float(rules.get("events", {}).get("chance", 0.0))
	if chance <= 0.0 or events.is_empty() or rng.randf() >= chance:
		return
	var y := year()
	var pool := {}
	for i in events.size():
		var e: Dictionary = events[i]
		if y < int(e.get("min_year", -999999)) or y > int(e.get("max_year", 999999)):
			continue
		pool[i] = float(e.get("weight", 1.0))
	if pool.is_empty():
		return
	var ev: Dictionary = events[int(_weighted_pick(pool))]
	var weights := {}
	for r: Region in region_list():
		if r.has_presence():
			weights[r.id] = r.converted
	if weights.is_empty():
		return
	_spawn_bubble("event", _weighted_pick(weights), 0, String(ev.get("id", "")))


## 按权重随机选一个键（确定性：遍历顺序固定）。
func _weighted_pick(weights: Dictionary) -> Variant:
	var total := 0.0
	for k in weights:
		total += float(weights[k])
	var x := rng.randf() * total
	var last: Variant = null
	for k in weights:
		last = k
		x -= float(weights[k])
		if x <= 0.0:
			return k
	return last


# ---------------------------------------------------------------- 结算

func _check_outcome() -> void:
	var t := totals()
	match win_condition:
		WinCondition.CONVERT_ALL:
			var share := float(rules.get("win_share", 1.0))
			if t.living > 0.0 and t.converted >= t.living * share - 1.0:
				_finish(true, "全世界都已%s%s" % [label("converted_verb", "转化"), label("agent", "")], "S")
				return
		WinCondition.REMOVE_ALL:
			if t.living < 1.0:
				_finish(true, "已无人幸存", "S")
				return
	if opposition.is_complete():
		_finish(false, "%s 已完成" % label("opposition", "反制"))
	elif t.converted < 1.0:
		_finish(false, "%s 已消亡" % label("agent", "传播体"))
	elif uses_years() and time_cfg.has("end") and year() >= int(time_cfg["end"]):
		var share: float = t.converted / maxf(t.living, 1.0)
		var g := "D"
		for pair in rules.get("end_grades", []):
			if share >= float(pair[0]):
				g = String(pair[1])
				break
		var ok := share >= float(rules.get("end_win_share", 0.5))
		_finish(ok, "%s 到来，%s占世界人口 %.1f%%，评级 %s" % [date_text(), label("converted", "信徒"), share * 100.0, g], g)


func _finish(is_win: bool, reason: String, result_grade: String = "") -> void:
	finished = true
	won = is_win
	grade = result_grade
	news.emit(reason)
	game_over.emit(is_win, reason)


# ---------------------------------------------------------------- 存档

## 存档：只保存可变状态，静态数据从 scenario/theme 重新加载。
func to_dict() -> Dictionary:
	var rs := []
	for r: Region in region_list():
		rs.append(r.to_dict())
	return {
		"tick": tick,
		"points": points,
		"started": started,
		"finished": finished,
		"won": won,
		"grade": grade,
		"agent_name": agent_name,
		"point_progress": _point_progress,
		"secular_announced": _secular_announced,
		"rng_state": str(rng.state),  # 字符串保存，避免 JSON 浮点丢失 64 位精度
		"owned": upgrades.owned.keys(),
		"opposition": opposition.to_dict(),
		"regions": rs,
		"bubbles": bubbles.values(),
		"next_bubble_id": _next_bubble_id,
		"active_effects": active_effects,
	}


func apply_state(d: Dictionary) -> void:
	tick = int(d.get("tick", 0))
	points = int(d.get("points", 0))
	started = bool(d.get("started", false))
	finished = bool(d.get("finished", false))
	won = bool(d.get("won", false))
	grade = String(d.get("grade", ""))
	agent_name = String(d.get("agent_name", agent_name))
	_point_progress = float(d.get("point_progress", 0.0))
	_secular_announced = bool(d.get("secular_announced", false))
	if d.has("rng_state"):
		rng.state = String(d["rng_state"]).to_int()
	upgrades.owned.clear()
	for id in d.get("owned", []):
		upgrades.mark_owned(String(id))
	opposition.apply_state(d.get("opposition", {}))
	for rd in d.get("regions", []):
		if regions.has(rd.get("id")):
			regions[rd["id"]].apply_state(rd)
	bubbles.clear()
	for b in d.get("bubbles", []):
		var bb: Dictionary = b.duplicate()
		bb.id = int(bb.id)
		bb.value = int(bb.value)
		bubbles[bb.id] = bb
	_next_bubble_id = int(d.get("next_bubble_id", 1))
	active_effects = []
	for e in d.get("active_effects", []):
		var ee: Dictionary = e.duplicate(true)
		ee.until = int(ee.until)
		active_effects.append(ee)
	_refresh_stats()
