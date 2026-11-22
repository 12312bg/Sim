extends Node
## 自动加载单例 `Game`：管理当前对局、游戏时钟（暂停/倍速）和存读档。
## 模拟逻辑都在 SimWorld 里；这里只负责“什么时候调用 step()”。

signal session_started(world: SimWorld)
signal speed_changed(speed: int)

const DEFAULT_SCENARIO := "res://data/scenarios/default.json"
const DEFAULT_UPGRADES := "res://data/upgrades/default.json"
const SAVE_PATH := "user://save.json"

## 每档速度对应的“现实秒/游戏日”。索引 0 = 暂停。
const SECONDS_PER_DAY: Array[float] = [0.0, 1.0, 0.4, 0.1]

var world: SimWorld
var speed: int = 0
var scenario_path := DEFAULT_SCENARIO
var upgrades_path := DEFAULT_UPGRADES
var _accum := 0.0


func new_game(seed_value: int = -1, scenario: String = DEFAULT_SCENARIO, upgrades: String = DEFAULT_UPGRADES) -> SimWorld:
	scenario_path = scenario
	upgrades_path = upgrades
	if seed_value < 0:
		seed_value = randi()
	world = SimWorld.new()
	world.setup(DataLoader.load_scenario(scenario), DataLoader.load_upgrades(upgrades), seed_value)
	set_speed(0)
	session_started.emit(world)
	return world


func set_speed(value: int) -> void:
	speed = clampi(value, 0, SECONDS_PER_DAY.size() - 1)
	_accum = 0.0
	speed_changed.emit(speed)


func _process(delta: float) -> void:
	if world == null or not world.started or world.finished or speed == 0:
		return
	_accum += delta
	var spd := SECONDS_PER_DAY[speed]
	# 上限防止掉帧后一次补算太多天。
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
	f.store_string(JSON.stringify({
		"scenario": scenario_path,
		"upgrades": upgrades_path,
		"state": world.to_dict(),
	}, "", true, true))  # full_precision，保证读档后模拟结果一致
	return true


func load_game() -> bool:
	var d: Variant = DataLoader.load_json(SAVE_PATH)
	if not d is Dictionary:
		return false
	new_game(0, d.get("scenario", DEFAULT_SCENARIO), d.get("upgrades", DEFAULT_UPGRADES))
	world.apply_state(d.get("state", {}))
	session_started.emit(world)
	return true
