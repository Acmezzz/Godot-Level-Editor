extends RefCounted
## 内容资源存储层：content/<功能id>/<内容ID>.json 的读写入口。
## 负责内容身份、JSON 读写和历史；业务字段由声明和游戏处理。
## 目录名 = 功能人类 id（给人读的），文件内 "function" 键 = 功能执行码（给代码执行的）。
## 本模块管辖的文件集合与历史深度见 docs/EDITOR_FEATURES.md §7.3（各入口提交哪些文件 / 历史深度）。

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
	if root != "" and DirAccess.dir_exists_absolute(root):
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

## 读缓存：path -> {digest, data}。
## 命中判据用**全文摘要**而不是 mtime+size（F1/P04）：Windows 的 mtime 是秒级、
## 长度也可能不变，同秒同长度的外部改写会被 mtime+size 当作未改，缓存与基线一起骗人。
## 代价是每次读都要读一遍文本做哈希——内容文件都很小，省下的是 JSON.parse。
## read_ex 命中时返回深拷贝（调用方拿不到缓存原件）；write/rename/remove 显式失效。
static var _cache := {}   # path -> {digest: String, data: Dictionary}

static func clear_read_cache() -> void:
	_cache.clear()

## 整体文本摘要（项目内统一算法：sha256）。
static func file_digest(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t.sha256_text()

## 严格读取：区分「缺失」「损坏」「可写」（C04）。
## status: ok / missing / invalid；invalid 时 data 为空、error 说明原因，调用方不得覆盖原文件。
static func read_ex(m: Dictionary, kind: String, id: String) -> Dictionary:
	var path := path_for(m, kind, id)
	if path == "":
		return {"status": "invalid", "data": {}, "error": "内容目录或 id 非法"}
	var overlay: Dictionary = m.get("_content_overrides", {})
	var key := kind + "/" + id
	if overlay.has(key):
		var row: Dictionary = overlay[key]
		if row.get("deleted", false):
			return {"status": "missing", "data": {}, "error": "已从草稿删除"}
		return {"status": "ok", "data": row.data.duplicate(true), "digest": row.baseline, "error": ""}
	if not FileAccess.file_exists(path):
		return {"status": "missing", "data": {}, "error": "内容文件不存在"}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"status": "invalid", "data": {}, "error": "内容文件无法打开"}
	var text := f.get_as_text()
	f.close()
	var digest := text.sha256_text()
	var hit = _cache.get(path, null)
	if hit != null and str(hit.get("digest", "")) == digest:
		return {"status": "ok", "data": (hit.get("data", {}) as Dictionary).duplicate(true),
			"digest": digest, "error": ""}
	var decoded := _decode(text, id)
	if decoded.has("error"):
		return {"status": "invalid", "data": {}, "digest": digest, "error": decoded.error}
	var data: Dictionary = decoded.data
	_cache[path] = {"digest": digest, "data": data}
	return {"status": "ok", "data": data.duplicate(true), "digest": digest, "error": ""}

## 读单个资源；需要区分缺失和损坏时用 read_ex。
static func read(m: Dictionary, kind: String, id: String) -> Dictionary:
	return read_ex(m, kind, id).data

static func encode(id: String, data: Dictionary) -> String:
	return JSON.stringify(data.merged({"id": id}, true), "\t")

static func _decode(text: String, id: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"error": "JSON 解析失败: " + json.get_error_message()}
	if not json.data is Dictionary:
		return {"error": "内容文件顶层必须是对象"}
	var data: Dictionary = json.data
	var saved_id = data.get("id", "")
	if saved_id != "" and saved_id != id:
		return {"error": "内容 ID 与请求的 ID 不一致"}
	data["id"] = id
	return {"data": data}

## 写单个资源；目录不存在时自动创建。
## 已有文件损坏时拒绝静默覆盖（C04）：除非调用方显式传 allow_repair=true。
static func write(m: Dictionary, kind: String, id: String, data: Dictionary, allow_repair := false) -> bool:
	var res := write_ex(m, kind, id, data, "", allow_repair)
	return bool(res.get("ok", false))

## 带基线的写入（F1/P04）：base_digest = 调用方读到内容时的文本摘要。
## 磁盘现状与基线不同 = 打开后被外部改过，不写、返回 conflict——
## 只看 mtime+size 会漏掉同秒同长度的外部编辑，摘要不会。
## base_digest 为空（新建/无基线）时行为与 write 相同。
static func write_ex(m: Dictionary, kind: String, id: String, data: Dictionary,
		base_digest: String, allow_repair := false, expect_absent := false) -> Dictionary:
	var path := path_for(m, kind, id)
	if path == "":
		return {"ok": false, "conflict": false}
	# V4 P0-1：create-only 写。新建内容在发号时目标本不存在；若提交期间别处创建了同路径
	# 文件，必须报冲突而不是覆盖（base_digest 为空只能表达「无基线」，不能表达「应不存在」）。
	var observed := Store.Recovery.observe(path)
	if expect_absent and observed.state != "missing":
		return {"ok": false, "conflict": true, "reason": "target occupied or unreadable"}
	if base_digest != "" and (observed.state != "present" or observed.digest != base_digest):
		return {"ok": false, "conflict": true}
	if observed.state == "unreadable":
		return {"ok": false, "conflict": false}
	if observed.state == "present" and not allow_repair and _decode(observed.text, id).has("error"):
		return {"ok": false, "conflict": false}
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if FileAccess.file_exists(path):
		# 内容文件与地图同权——误写可回滚（3 层 .history，最新 .1）
		Store.rotate_history(path)
	# 基线存在（替换已存在文件）的写入失败要可诊断；新建按 create-only 语义已在上面拦截。
	_cache.erase(path)   # D3：写后失效（同秒重写也不吃脏缓存）
	return {"ok": Store.write_text(path, encode(id, data)), "conflict": false}

## 列出某类资源的 id（不含扩展名，排序）。
## D3 修订：目录 mtime 在 Windows 上不可靠——list 不缓存（DirAccess 扫描本身很便宜），
## 只保留 read 的文件级 mtime 缓存；写/改名/删除显式失效。
static func list_ids(m: Dictionary, kind: String) -> Array:
	var out: Array = []
	var dir_path := dir_for(m, kind)
	if dir_path == "":
		return out
	var d := DirAccess.open(dir_path)
	for f in (d.get_files() if d != null else PackedStringArray()):
		if not str(f).ends_with(".json"):
			continue
		var id := str(f).get_basename()
		if is_valid_id(id):
			out.append(id)
	for row in m.get("_content_overrides", {}).values():
		if row.function != kind:
			continue
		if row.get("deleted", false):
			out.erase(row.content)
		elif not out.has(row.content):
			out.append(row.content)
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

## 删除资源；文件不存在视为成功（幂等）。
## §7.2「删除前由提交器保存历史」：先轮转一份快照，**拿不到快照就拒绝删**
## （删掉之后没有「当前」可再备份，事后无法找回）。返回 {ok, backed_up, error}：
##   ok        = 目标文件已不存在（删成功或本来就没有）
##   backed_up = 删除前是否真的留下了 .history/<name>.1
## 部分成功按文件报：调用方逐条显示，不合并成一句「删除完成」。
static func remove_ex(m: Dictionary, kind: String, id: String) -> Dictionary:
	var path := path_for(m, kind, id)
	if path == "":
		return {"ok": false, "backed_up": false, "error": "内容路径非法"}
	if not FileAccess.file_exists(path):
		_cache.erase(path)
		return {"ok": true, "backed_up": false, "error": ""}
	if not Store.rotate_history(path):
		return {"ok": false, "backed_up": false,
			"error": "删除前无法备份（.history 写不进去），已中止——文件原样保留"}
	_cache.erase(path)   # D3：删除后失效
	if DirAccess.remove_absolute(path) != OK:
		return {"ok": false, "backed_up": true, "error": "文件不可删（可能被占用），备份已留"}
	return {"ok": true, "backed_up": true, "error": ""}
