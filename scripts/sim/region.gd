class_name Region
extends RefCounted
## 一个地区（国家/省份）。只保存状态，不包含规则；规则在 SpreadModel 里。
##
## 人口按三类划分：
##   susceptible（未转化） -> converted（已转化：感染者/信徒） -> removed（移除：死亡/离开）
## Religion 类玩法可以不使用 removed；Plague 类玩法通过 lethality 把 converted 推向 removed。

var id: String = ""
var display_name: String = ""
var population: float = 0.0
var converted: float = 0.0
var removed: float = 0.0
## 0..1，本地社会对“传播体”的警觉程度。驱动反制与封锁。
var awareness: float = 0.0
## 地区特征，例如 {"climate": "hot", "wealth": "poor"}。键值完全由数据决定。
var traits: Dictionary = {}
## 对全球反制进度的贡献权重（富裕地区研究能力更强）。
var counter_weight: float = 1.0
## 当前被封锁的连接类型（"air"、"sea"…）。
var closed_link_types: Dictionary = {}


static func from_dict(d: Dictionary) -> Region:
	var r := Region.new()
	r.id = String(d.get("id", ""))
	r.display_name = String(d.get("name", r.id))
	r.population = float(d.get("population", 0))
	r.traits = d.get("traits", {}).duplicate()
	r.counter_weight = float(d.get("counter_weight", 1.0))
	return r


func living() -> float:
	return maxf(population - removed, 0.0)


func susceptible() -> float:
	return maxf(population - converted - removed, 0.0)


## 已转化人口占存活人口的比例。
func converted_ratio() -> float:
	var l := living()
	return converted / l if l > 0.0 else 0.0


func has_presence() -> bool:
	return converted >= 1.0


func is_link_closed(link_type: String) -> bool:
	return closed_link_types.has(link_type)


func to_dict() -> Dictionary:
	return {
		"id": id,
		"converted": converted,
		"removed": removed,
		"awareness": awareness,
		"closed_link_types": closed_link_types.keys(),
	}


func apply_state(d: Dictionary) -> void:
	converted = float(d.get("converted", 0.0))
	removed = float(d.get("removed", 0.0))
	awareness = float(d.get("awareness", 0.0))
	closed_link_types.clear()
	for t in d.get("closed_link_types", []):
		closed_link_types[String(t)] = true
