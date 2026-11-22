extends Node
## 自动加载单例 `Game`：管理当前对局、游戏时钟（暂停/倍速）、气泡寿命和存读档。
## 模拟逻辑都在 SimWorld 里；这里只负责“什么时候调用 step()”以及与现实时间相关的事。

signal session_started(world: SimWorld)
signal speed_changed(speed: int)

const DEFAULT_THEME := "res://data/themes/religion.json"
const SAVE_PATH := "user://save.json"
const DEFAULT_SECONDS_PER_TICK: Array = [0.0, 1.0, 0.4, 0.1]

var world: SimWorld
var speed: int = 0
var theme_path := DEFAULT_THEME
var scenario_path := ""
var _accum := 0.0
var _bubble_age: Dictionary = {}  # bubble id -> 已存在的秒数（暂停时不计时）


func themes() -> Array[Dictionary]:
	return DataLoader.list_themes()


## 开新局。scenario 为空时使用主题指定的场景。
func new_game(theme: String = DEFAULT_THEME, agent_name: String = "", seed_value: int = -1, scenario: String = "") -> SimWorld:
	_create_world(theme, agent_name, seed_value, scenario)
	session_started.emit(world)
	return world


func _create_world(theme: String, agent_name: String, seed_value: int, scenario: String) -> void:
	var theme_data := DataLoader.load_theme(theme)
	theme_path = theme
	scenario_path = scenario if scenario != "" else String(theme_data.get("scenario", ""))
	if seed_value < 0:
		seed_value = randi()
	world = SimWorld.new()
	world.setup(DataLoader.load_scenario(scenario_path), theme_data, seed_value, agent_name)
	_bubble_age.clear()
	world.bubble_spawned.connect(func(b: Dictionary) -> void: _bubble_age[b.id] = 0.0)
	world.bubble_changed.connect(func(b: Dictionary) -> void: _bubble_age[b.id] = 0.0)
	world.bubble_removed.connect(func(id: int, _c: bool) -> void: _bubble_age.erase(id))
	set_speed(0)


func seconds_per_tick() -> Array:
	return world.time_cfg.get("seconds_per_tick", DEFAULT_SECONDS_PER_TICK) if world else DEFAULT_SECONDS_PER_TICK


func speed_count() -> int:
	return seconds_per_tick().size()


func set_speed(value: int) -> void:
	speed = clampi(value, 0, speed_count() - 1)
	_accum = 0.0
	speed_changed.emit(speed)


func bubble_lifetime() -> float:
	return float(world.rules.get("bubbles", {}).get("lifetime_seconds", 8.0)) if world else 8.0


## 气泡剩余寿命比例（1 = 刚出现，0 = 即将消失），供界面做淡出。
func bubble_life_left(bubble_id: int) -> float:
	return 1.0 - clampf(float(_bubble_age.get(bubble_id, 0.0)) / bubble_lifetime(), 0.0, 1.0)


func _process(delta: float) -> void:
	if world == null or not world.started or world.finished or speed == 0:
		return
	# 气泡寿命按现实时间计算，与倍速无关
	var expired: Array = []
	for id in _bubble_age:
		_bubble_age[id] += delta
		if _bubble_age[id] >= bubble_lifetime():
			expired.append(id)
	for id in expired:
		world.discard_bubble(id)

	_accum += delta
	var spd := float(seconds_per_tick()[speed])
	# 上限防止掉帧后一次补算太多回合。
	var guard := 0
	while _accum >= spd and guard < 20 and not world.finished:
		_accum -= spd
		world.step()
		guard += 1


func save_game() -> bool:
	if world == null:
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return false
	# 状态用二进制编码（base64）保存：浮点数逐位精确，读档后的模拟结果与不中断时完全一致。
	f.store_string(JSON.stringify({
		"version": 2,
		"theme": theme_path,
		"scenario": scenario_path,
		"state": Marshalls.variant_to_base64(world.to_dict()),
	}, "\t"))
	return true


func load_game() -> bool:
	var d: Variant = DataLoader.load_json(SAVE_PATH)
	if not d is Dictionary:
		return false
	if not d.get("state") is String:
		return false
	var state: Variant = Marshalls.base64_to_variant(d["state"])
	if not state is Dictionary:
		return false
	_create_world(d.get("theme", DEFAULT_THEME), String(state.get("agent_name", "")), 0, d.get("scenario", ""))
	world.apply_state(state)
	for id in world.bubbles:
		_bubble_age[id] = 0.0
	session_started.emit(world)
	return true
