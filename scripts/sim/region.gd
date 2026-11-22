class_name Region
extends RefCounted
## 一个地区（国家）。只保存状态，不包含规则；规则在 SpreadModel 里。
##
## 人口划分（互不重叠）：
##   susceptible（未转化）  = population - converted - lapsed - removed
##   converted（已转化：信徒），其中 zealots（狂信徒）是 converted 的子集
##   lapsed（流失者：宗教主题中的无神论者），可通过“回流”重新转化
##   removed（移除：死亡等，原型主题使用）

var id: String = ""
var display_name: String = ""
## 数据中的人口（现代）；主题有人口曲线时，population = base_population × 年代系数。
var base_population: float = 0.0
var population: float = 0.0
var converted: float = 0.0
var zealots: float = 0.0
var lapsed: float = 0.0
var removed: float = 0.0
## 0..1，本地社会对“传播体”的警觉程度。驱动反制与封锁（宗教主题不使用）。
var awareness: float = 0.0
## 地区特征，例如 {"climate": "hot", "wealth": "poor"}。键值完全由数据决定。
var traits: Dictionary = {}
## 对全球反制进度的贡献权重（富裕地区研究能力更强）。
var counter_weight: float = 1.0
## 当前被封锁的连接类型（"air"、"sea"…）。
var closed_link_types: Dictionary = {}
## 地图上属于本地区的国家代码（国家级场景中就是自己）。
var countries: Array = []
## 场景提供的地图信息（标注点、范围框）；国家级场景为空，由地图数据提供。
var map_meta: Dictionary = {}


static func from_dict(d: Dictionary) -> Region:
	var r := Region.new()
	r.id = String(d.get("id", ""))
	r.display_name = String(d.get("name", r.id))
	r.base_population = float(d.get("population", 0))
	r.population = r.base_population
	r.traits = d.get("traits", {}).duplicate()
	r.counter_weight = float(d.get("counter_weight", 1.0))
	r.countries = d.get("countries", [r.id]).duplicate()
	r.map_meta = d.get("map", {}).duplicate(true)
	return r


func living() -> float:
	return maxf(population - removed, 0.0)


func susceptible() -> float:
	return maxf(population - converted - lapsed - removed, 0.0)


## 已转化人口占存活人口的比例。
func converted_ratio() -> float:
	var l := living()
	return converted / l if l > 0.0 else 0.0


func zealot_ratio() -> float:
	var l := living()
	return zealots / l if l > 0.0 else 0.0


func lapsed_ratio() -> float:
	var l := living()
	return lapsed / l if l > 0.0 else 0.0


func has_presence() -> bool:
	return converted >= 1.0


func is_link_closed(link_type: String) -> bool:
	return closed_link_types.has(link_type)


## 人口变化时各类人群等比例缩放（新生人口继承父辈的信仰状态）。
func rescale(new_population: float) -> void:
	if population <= 0.0:
		population = new_population
		return
	var g := new_population / population
	population = new_population
	converted *= g
	zealots *= g
	lapsed *= g
	removed *= g


func to_dict() -> Dictionary:
	return {
		"id": id,
		"population": population,
		"converted": converted,
		"zealots": zealots,
		"lapsed": lapsed,
		"removed": removed,
		"awareness": awareness,
		"closed_link_types": closed_link_types.keys(),
	}


func apply_state(d: Dictionary) -> void:
	population = float(d.get("population", population))
	converted = float(d.get("converted", 0.0))
	zealots = float(d.get("zealots", 0.0))
	lapsed = float(d.get("lapsed", 0.0))
	removed = float(d.get("removed", 0.0))
	awareness = float(d.get("awareness", 0.0))
	closed_link_types.clear()
	for t in d.get("closed_link_types", []):
		closed_link_types[String(t)] = true
