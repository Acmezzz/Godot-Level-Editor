extends RefCounted
## 内容资源存储层：content/<功能id>/<内容ID>.json 的读写入口。
## 只做路径解析与 JSON 读写，不含业务校验；写盘复用 MapStore.write_json 的原子替换。
## 目录名 = 功能人类 id（给人读的），文件内 "function" 键 = 功能执行码（给代码执行的）。

const Store := preload("res://src/map/map_store.gd")

const DEFAULT_CONTENT_DIR := "content"

## 资源 id 规则：字母/数字/下划线/点/连字符；不能以点开头或结尾，不能含路径分隔符。
static func is_valid_id(id: String) -> bool:
	if id == "" or id != id.strip_edges():
		return false
	if id.begins_with(".") or id.ends_with("."):
		return false
	if id.contains("..") or id.contains("/") or id.contains("\\") or id.contains(":"):
		return false
	for ch in id:
		if not (_is_id_char(ch) or ch == "." or ch == "-"):
			return false
	return true

static func _is_id_char(ch: String) -> bool:
	if ch.length() != 1:
		return false
	var code := ch.unicode_at(0)
	return (code >= 48 and code <= 57) \
		or (code >= 65 and code <= 90) \
		or (code >= 97 and code <= 122) \
		or ch == "_"

## kind 直接拼进目录名，比内容 id 更严：不允许点，避免把 dlg.one 之类 id 当目录。
## 公开给清单校验用（C07）：功能 id 既是内容目录名，就必须过这一条——
## 否则声明能载入、内容目录却建不出来，第一次编辑才失败。
static func is_valid_kind(kind: String) -> bool:
	return is_valid_id(kind) and not kind.contains(".")

## 内容根目录：清单可用 contentDir 覆盖；缺省 <项目>/content。
static func root_dir(m: Dictionary) -> String:
	var project := str(m.get("_dir", ""))
	if project == "":
		return ""
	var rel := str(m.get("contentDir", DEFAULT_CONTENT_DIR))
	if rel == "":
		rel = DEFAULT_CONTENT_DIR
	if rel.begins_with("/") or rel.begins_with("\\") or rel.contains(".."):
		return ""
	return project.path_join(rel)

## 声明 + 磁盘子目录的并集（排序去重）。
## 目录由功能声明驱动，但磁盘上已有内容的目录也必须保留——升级/手改清单时不能让旧内容消失。
static func declared_kinds(m: Dictionary) -> Array:
	var kinds := {}
	var decl = m.get("functions", null)
	if decl is Dictionary:
		for key in (decl as Dictionary):
			var k := str(key)
			if is_valid_kind(k):
				kinds[k] = true
	elif decl is Array:
		for item in (decl as Array):
			if not (item is Dictionary):
				continue
			var k := str((item as Dictionary).get("id", ""))
			if is_valid_kind(k):
				kinds[k] = true
	var root := root_dir(m)
	if root != "":
		for dirname in DirAccess.get_directories_at(root):
			if is_valid_kind(str(dirname)):
				kinds[str(dirname)] = true
	var out: Array = kinds.keys()
	out.sort()
	return out

## 某类资源的目录；种类非法或项目目录缺失返回 ""。
static func dir_for(m: Dictionary, kind: String) -> String:
	if not is_valid_kind(kind):
		return ""
	var root := root_dir(m)
	if root == "":
		return ""
	return root.path_join(kind)

## 资源文件路径；id 或种类非法返回 ""。
static func path_for(m: Dictionary, kind: String, id: String) -> String:
	if not is_valid_id(id):
		return ""
	var dir := dir_for(m, kind)
	if dir == "":
		return ""
	return dir.path_join(id + ".json").simplify_path()

## 读缓存：path -> {mtime, size, data}。read_ex 命中缓存时返回副本，
## 写盘/改名/删除显式失效（见 write/rename/remove）。
static var _cache := {}   # path -> {mtime: int, size: int, data: Dictionary}

## 严格读取：区分「缺失」「损坏」「可写」（C04）。
## status: ok / missing / invalid；invalid 时 data 为空、error 说明原因，调用方不得覆盖原文件。
static func read_ex(m: Dictionary, kind: String, id: String) -> Dictionary:
	var path := path_for(m, kind, id)
	if path == "":
		return {"status": "invalid", "data": {}, "error": "内容目录或 id 非法"}
	if not FileAccess.file_exists(path):
		return {"status": "missing", "data": {}, "error": "内容文件不存在"}
	var mt := FileAccess.get_modified_time(path)
	var sz := _file_size(path)
	var hit = _cache.get(path, null)
	if hit != null and int(hit.get("mtime", -1)) == mt and int(hit.get("size", -1)) == sz:
		return {"status": "ok", "data": (hit.get("data", {}) as Dictionary).duplicate(true), "error": ""}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"status": "invalid", "data": {}, "error": "内容文件无法打开"}
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"status": "invalid", "data": {}, "error": "JSON 解析失败: " + json.get_error_message()}
	if not (json.data is Dictionary):
		return {"status": "invalid", "data": {}, "error": "内容文件顶层必须是对象"}
	var data: Dictionary = json.data
	if str(data.get("id", "")) == "":
		data["id"] = id
	_cache[path] = {"mtime": mt, "size": sz, "data": data}
	return {"status": "ok", "data": data.duplicate(true), "error": ""}

## 读单个资源；缺失/损坏/非法一律返回 {}（旧调用兼容；需要区分状态请用 read_ex）。
static func read(m: Dictionary, kind: String, id: String) -> Dictionary:
	var res := read_ex(m, kind, id)
	return res.data if str(res.status) == "ok" else {}

static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n

## 静默解析：JSON.parse_string 遇到坏文件会向引擎打 ERROR 日志，
## 校验页扫描大量资源时会被噪声淹没；JSON.new().parse() 只返回错误码。
## 仅 read_all 的宽松路径使用；read_ex 自带严格状态。
static func _decode(text: String, id: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	if not (json.data is Dictionary):
		return {}
	var data: Dictionary = json.data
	# 文件内 id 缺失时用文件名补齐，便于下游统一读取。
	if str(data.get("id", "")) == "":
		data["id"] = id
	return data

## 写单个资源；目录不存在时自动创建。
## 已有文件损坏时拒绝静默覆盖（C04）：除非调用方显式传 allow_repair=true。
static func write(m: Dictionary, kind: String, id: String, data: Dictionary, allow_repair := false) -> bool:
	var path := path_for(m, kind, id)
	if path == "":
		return false
	if FileAccess.file_exists(path) and not allow_repair:
		var cur := read_ex(m, kind, id)
		if str(cur.status) == "invalid":
			return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if FileAccess.file_exists(path):
		# 内容文件与地图同权——误写可回滚（3 层 .history，最新 .1）
		Store.rotate_history(path)
	var payload := data.duplicate(true)
	payload["id"] = id
	_cache.erase(path)   # D3：写后失效（同秒重写也不吃脏缓存）
	return Store.write_json(path, payload)

## 列出某类资源的 id（不含扩展名，排序）。
## D3 修订：目录 mtime 在 Windows 上不可靠——list 不缓存（DirAccess 扫描本身很便宜），
## 只保留 read 的文件级 mtime 缓存；写/改名/删除显式失效。
static func list_ids(m: Dictionary, kind: String) -> Array:
	var out: Array = []
	var dir_path := dir_for(m, kind)
	if dir_path == "":
		return out
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if not str(f).ends_with(".json"):
			continue
		var id := str(f).get_basename()
		if is_valid_id(id):
			out.append(id)
	out.sort()
	return out

## 读某类全部资源；坏文件不进结果但记入 bad_out（与 MapStore.read_all 一致）。
## 条目带 status/error，调用方可区分「缺失」与「损坏」（C04）。
static func read_all(m: Dictionary, kind: String, bad_out: Array = []) -> Dictionary:
	var out := {}
	for id in list_ids(m, kind):
		var res := read_ex(m, kind, str(id))
		if str(res.status) != "ok":
			bad_out.append({"name": id, "kind": kind, "reason": str(res.error),
				"status": str(res.status)})
			continue
		out[id] = res.data
	return out

## 改名：复制到新 id 后删旧文件；任一步失败回滚为原状。
static func rename(m: Dictionary, kind: String, old_id: String, new_id: String) -> bool:
	if not is_valid_id(new_id) or old_id == new_id:
		return false
	var old_path := path_for(m, kind, old_id)
	var new_path := path_for(m, kind, new_id)
	if old_path == "" or new_path == "" or not FileAccess.file_exists(old_path):
		return false
	if FileAccess.file_exists(new_path):
		return false
	var data := read(m, kind, old_id)
	if data.is_empty():
		return false
	if not write(m, kind, new_id, data):
		return false
	_cache.erase(old_path)   # D3：改名后旧路径失效
	if DirAccess.remove_absolute(old_path) != OK:
		DirAccess.remove_absolute(new_path)
		return false
	return true

## 删除资源；文件不存在视为成功（幂等）。
static func remove(m: Dictionary, kind: String, id: String) -> bool:
	var path := path_for(m, kind, id)
	if path == "":
		return false
	if not FileAccess.file_exists(path):
		return true
	var ok := DirAccess.remove_absolute(path) == OK
	_cache.erase(path)   # D3：删除后失效
	return ok
