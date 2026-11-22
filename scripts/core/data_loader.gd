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


static func load_theme(path: String) -> Dictionary:
	var d: Variant = load_json(path)
	return d if d is Dictionary else {}


## 深度合并：override 中的键覆盖 base；两边都是字典时递归合并。返回新字典。
static func merge(base: Dictionary, override: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in override:
		if out.get(k) is Dictionary and override[k] is Dictionary:
			out[k] = merge(out[k], override[k])
		else:
			var v: Variant = override[k]
			out[k] = v.duplicate(true) if (v is Dictionary or v is Array) else v
	return out


## 主题列表：data/themes/index.json 中登记的主题。
static func list_themes(include_hidden: bool = false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var idx: Variant = load_json("res://data/themes/index.json")
	if not idx is Dictionary:
		return out
	for path in idx.get("themes", []):
		var t: Variant = load_json(path)
		if t is Dictionary and (include_hidden or not t.get("hidden", false)):
			t["path"] = path
			out.append(t)
	return out
