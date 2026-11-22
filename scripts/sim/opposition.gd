class_name Opposition
extends RefCounted
## 反制力量：Plague 中的“解药研究”，Religion 中的“科学/怀疑论”。
## 全球警觉度达到阈值后启动，进度到 1.0 时玩家失败。

var progress: float = 0.0
var active: bool = false

var start_awareness: float = 0.15
var base_rate: float = 0.004


func configure(cfg: Dictionary) -> void:
	start_awareness = float(cfg.get("start_awareness", start_awareness))
	base_rate = float(cfg.get("base_rate", base_rate))


## 返回 true 表示本日刚刚启动。
func step(regions: Array, stats: Dictionary) -> bool:
	var total_living := 0.0
	var weighted_awareness := 0.0
	var research := 0.0
	for r: Region in regions:
		var l := r.living()
		total_living += l
		weighted_awareness += r.awareness * l
		research += r.awareness * r.counter_weight * l
	if total_living <= 0.0:
		return false
	var just_started := false
	if not active and weighted_awareness / total_living >= start_awareness:
		active = true
		just_started = true
	if active:
		var slow := clampf(float(stats.get("counter_resist", 0.0)), 0.0, 0.95)
		progress += base_rate * (research / total_living) * (1.0 - slow)
		progress = minf(progress, 1.0)
	return just_started


func is_complete() -> bool:
	return progress >= 1.0


func to_dict() -> Dictionary:
	return {"progress": progress, "active": active}


func apply_state(d: Dictionary) -> void:
	progress = float(d.get("progress", 0.0))
	active = bool(d.get("active", false))
