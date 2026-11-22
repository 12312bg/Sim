class_name UpgradeTree
extends RefCounted
## 升级树：数据驱动的节点 + 前置条件 + 属性加成汇总。
##
## 每个升级定义（JSON）：
##   id, name, category, cost, requires: [id...], effects: {stat: value}, desc
## effects 的所有数值被累加成一张“属性表”，模拟层只读这张表。

var defs: Dictionary = {}       # id -> Dictionary
var order: Array[String] = []   # 保持数据文件中的顺序，便于 UI 展示
var owned: Dictionary = {}      # id -> true
var _stats_cache: Dictionary = {}
var _dirty := true


func load_defs(list: Array) -> void:
	defs.clear()
	order.clear()
	owned.clear()
	for d in list:
		var id := String(d.get("id", ""))
		assert(id != "", "upgrade without id")
		assert(not defs.has(id), "duplicate upgrade id: %s" % id)
		defs[id] = d
		order.append(id)
	for id in order:
		for req in defs[id].get("requires", []):
			assert(defs.has(req), "upgrade %s requires unknown %s" % [id, req])
	_dirty = true


func categories() -> Array[String]:
	var out: Array[String] = []
	for id in order:
		var c := String(defs[id].get("category", "misc"))
		if not out.has(c):
			out.append(c)
	return out


func is_owned(id: String) -> bool:
	return owned.has(id)


func is_unlocked(id: String) -> bool:
	for req in defs[id].get("requires", []):
		if not owned.has(req):
			return false
	return true


## 需要的最早年份（没有限制时返回一个极小值）。
func min_year(id: String) -> int:
	return int(defs[id].get("min_year", -999999))


func cost_of(id: String) -> int:
	return int(defs[id].get("cost", 0))


## 返回 "" 表示可以购买，否则返回原因。year 为当前年份（不按年份计时的主题传极大值）。
func check_buy(id: String, points: int, year: int = 999999) -> String:
	if not defs.has(id):
		return "未知升级"
	if owned.has(id):
		return "已拥有"
	if not is_unlocked(id):
		return "前置未满足"
	if year < min_year(id):
		return "年代未到"
	if points < cost_of(id):
		return "点数不足"
	return ""


func mark_owned(id: String) -> void:
	owned[id] = true
	_dirty = true


## 所有已拥有升级的 effects 累加结果。
func stats() -> Dictionary:
	if _dirty:
		_stats_cache = {}
		for id in owned:
			var eff: Dictionary = defs[id].get("effects", {})
			for k in eff:
				_stats_cache[k] = float(_stats_cache.get(k, 0.0)) + float(eff[k])
		_dirty = false
	return _stats_cache


func stat(key: String, default_value: float = 0.0) -> float:
	return float(stats().get(key, default_value))
