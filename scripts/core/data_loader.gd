class_name DataLoader
extends RefCounted
## 读取 JSON 内容文件。内容（地区、升级、规则、文案）全部放在 data/ 下，便于不改代码地调参和换主题。


static func load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("data file not found: %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("%s:%d %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


static func load_scenario(path: String) -> Dictionary:
	var d: Variant = load_json(path)
	return d if d is Dictionary else {}


static func load_upgrades(path: String) -> Array:
	var d: Variant = load_json(path)
	if d is Dictionary:
		return d.get("upgrades", [])
	return d if d is Array else []
