class_name SpreadModel
extends RefCounted
## 传播规则：纯函数，无状态。所有调参系数来自 scenario 的 rules。
##
## 属性键（由升级累加，均为加法）：
##   spread                 地区内部传播率加成
##   cross_<type>           跨地区连接加成（cross_land / cross_sea / cross_air ...）
##   resist_<trait>_<value> 抵消某类地区特征带来的阻力，如 resist_climate_cold
##   visibility             可见度（越高越容易被发现）
##   lethality              转化者 -> 移除者 的速率
##   counter_resist         减缓全球反制进度（0..1）
##   points_bonus           点数获取倍率加成


## 地区环境系数：1 + spread - (特征阻力 - 对应抗性)，下限 0.05。
static func environment_factor(region: Region, stats: Dictionary, rules: Dictionary) -> float:
	var factor := 1.0 + float(stats.get("spread", 0.0))
	var trait_resist: Dictionary = rules.get("trait_resist", {})
	for trait_key in region.traits:
		var value := String(region.traits[trait_key])
		var penalty := float(trait_resist.get(trait_key, {}).get(value, 0.0))
		var counter := float(stats.get("resist_%s_%s" % [trait_key, value], 0.0))
		factor -= maxf(penalty - counter, 0.0)
	return maxf(factor, 0.05)


## 地区内部一日的新增转化（logistic 形式）。
static func internal_growth(region: Region, stats: Dictionary, rules: Dictionary) -> float:
	if region.converted <= 0.0:
		return 0.0
	var living := region.living()
	if living <= 0.0:
		return 0.0
	var s := region.susceptible()
	var beta := float(rules.get("base_spread", 0.1)) * environment_factor(region, stats, rules)
	var gained := region.converted * beta * (s / living)
	gained = minf(gained, s)
	# 剩余不足 1 人时直接收尾，避免浮点永远逼近不到终点。
	if s - gained < 1.0:
		gained = s
	return gained


## 一日的移除（死亡等）。
static func removal(region: Region, stats: Dictionary, rules: Dictionary) -> float:
	var rate := float(rules.get("base_lethality", 0.0)) + float(stats.get("lethality", 0.0))
	if rate <= 0.0:
		return 0.0
	return minf(region.converted * rate, region.converted)


## 一日的警觉度增长。
static func awareness_gain(region: Region, stats: Dictionary, rules: Dictionary) -> float:
	var vis := maxf(float(rules.get("base_visibility", 0.2)) + float(stats.get("visibility", 0.0)), 0.0)
	var rate := float(rules.get("awareness_rate", 0.02))
	var pressure := region.converted_ratio() + float(stats.get("lethality", 0.0)) * 10.0
	return rate * vis * minf(pressure, 1.0) * (1.0 - region.awareness)


## 一条连接一天内把传播体带到目标地区的概率。
static func link_probability(src: Region, dst: Region, link: Dictionary, stats: Dictionary, rules: Dictionary) -> float:
	if not src.has_presence() or dst.has_presence() or dst.living() <= 0.0:
		return 0.0
	var t := String(link.get("type", "land"))
	var p := float(rules.get("cross_base", 0.05)) * float(link.get("weight", 1.0))
	p *= maxf(1.0 + float(stats.get("cross_" + t, 0.0)), 0.0)
	p *= presence_factor(src, rules)
	if src.is_link_closed(t) or dst.is_link_closed(t):
		p *= 1.0 - float(rules.get("closure_strength", 0.9))
	return clampf(p, 0.0, 1.0)


## 源地区“输出强度”0..1：按转化人数的数量级计算，早期少量转化者也能偶尔外溢。
## 1 人 -> 0，满员 -> 1，指数 cross_presence_exponent 调整曲线陡峭度。
static func presence_factor(src: Region, rules: Dictionary) -> float:
	var l := src.living()
	if l <= 1.0 or src.converted <= 0.0:
		return 0.0
	var f := clampf(log(1.0 + src.converted) / log(1.0 + l), 0.0, 1.0)
	return pow(f, float(rules.get("cross_presence_exponent", 1.0)))
