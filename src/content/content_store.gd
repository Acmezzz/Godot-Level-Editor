extends RefCounted
## 内容资源存储层：content/<功能id>/<内容ID>.json 的读写入口。
## 只做路径解析与 JSON 读写，不含业务校验；写盘复用 MapStore.write_json 的原子替换。
## 目录名 = 功能人类 id（给人读的），文件内 "function" 键 = 功能执行码（给代码执行的）。

const Store := preload("res://src/map_store.gd")

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
static func _is_valid_kind(kind: String) -> bool:
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
			if _is_valid_kind(k):
				kinds[k] = true
	elif decl is Array:
		for item in (decl as Array):
			if not (item is Dictionary):
				continue
			var k := str((item as Dictionary).get("id", ""))
			if _is_valid_kind(k):
				kinds[k] = true
	var root := root_dir(m)
	if root != "":
		for dirname in DirAccess.get_directories_at(root):
			if _is_valid_kind(str(dirname)):
				kinds[str(dirname)] = true
	var out: Array = kinds.keys()
	out.sort()
	return out

## 某类资源的目录；种类非法或项目目录缺失返回 ""。
static func dir_for(m: Dictionary, kind: String) -> String:
	if not _is_valid_kind(kind):
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

## 读单个资源；缺失/损坏/非法一律返回 {}。
## 按文件 mtime+尺寸缓存——属性面板/库反复 read 不再逐文件读盘；
## 返回缓存副本防调用方污染；写盘后 mtime 变化自动失效（与 map_store 同款）。
static var _cache := {}   # path -> {mtime: int, data: Dictionary}

static func read(m: Dictionary, kind: String, id: String) -> Dictionary:
	var path := path_for(m, kind, id)
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var mt := FileAccess.get_modified_time(path)
	var sz := _file_size(path)
	var hit = _cache.get(path, null)
	# mtime 秒级粒度，同秒改写会被脏缓存吃掉——缓存键补文件长度兜住绝大多数情形
	if hit != null and int(hit.get("mtime", -1)) == mt and int(hit.get("size", -1)) == sz:
		return (hit.get("data", {}) as Dictionary).duplicate(true)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var data := _decode(text, id)
	if not data.is_empty():
		_cache[path] = {"mtime": mt, "size": sz, "data": data}
	return data

static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n

## 静默解析：JSON.parse_string 遇到坏文件会向引擎打 ERROR 日志，
## 校验页扫描大量资源时会被噪声淹没；JSON.new().parse() 只返回错误码。
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
static func write(m: Dictionary, kind: String, id: String, data: Dictionary) -> bool:
	var path := path_for(m, kind, id)
	if path == "":
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
static func read_all(m: Dictionary, kind: String, bad_out: Array = []) -> Dictionary:
	var out := {}
	for id in list_ids(m, kind):
		var data := read(m, kind, id)
		if data.is_empty():
			bad_out.append({"name": id, "kind": kind, "reason": "无法读取或 JSON 解析失败"})
			continue
		out[id] = data
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
