extends RefCounted
## A3 恢复层：草稿（editor/drafts）、地图历史（editor/history/maps）、多文件提交日志（editor/pending）。
## 只做路径解析与 JSON/字节读写，不解释业务；不 preload map_store（避免反向依赖成环）。

const DRAFT_DIR := "editor/drafts"
const HISTORY_DIR := "editor/history/maps"
const PENDING_DIR := "editor/pending"
const HISTORY_KEEP := 20

static func _root(m: Dictionary) -> String:
	return str(m.get("_dir", ""))

static func _dir(m: Dictionary, rel: String) -> String:
	var root := _root(m)
	if root == "":
		return ""
	return root.path_join(rel)

# ──────────── 原子读写（本地实现：recovery 不依赖 map_store） ────────────

static func read_text(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t

static func write_text(path: String, text: String) -> bool:
	var dir := path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(text.to_utf8_buffer())
	f.flush()
	var ok := f.get_error() == OK
	f.close()
	if not ok:
		DirAccess.remove_absolute(tmp)
		return false
	if DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	return true

static func read_json(path: String) -> Dictionary:
	var t := read_text(path)
	if t == "":
		return {}
	var parsed = JSON.parse_string(t)
	return parsed if parsed is Dictionary else {}

static func write_json(path: String, data: Dictionary) -> bool:
	return write_text(path, JSON.stringify(data, "\t"))

## 内容摘要（与 map_file 的外部改动基线同算法：整段文本 sha256）。
static func digest(path: String) -> String:
	var t := read_text(path)
	if t == "" and not FileAccess.file_exists(path):
		return ""
	return t.sha256_text()

# ──────────── 草稿：editor/drafts/<地图码>.json ────────────

## 草稿键：有地图码用码（改名不失效），没有码退回图名。
static func draft_key(map_code: String, map_name: String) -> String:
	var k := map_code.strip_edges()
	if k == "":
		k = map_name.strip_edges()
	if k == "":
		return ""
	for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", " "]:
		k = k.replace(ch, "_")
	return k

static func draft_path(m: Dictionary, map_code: String, map_name: String) -> String:
	var key := draft_key(map_code, map_name)
	var dir := _dir(m, DRAFT_DIR)
	if key == "" or dir == "":
		return ""
	return dir.path_join(key + ".json")

## 写草稿：记录目标路径、正式图基线、地图快照、待提交文件及原 ID（A3 恢复所需全部信息）。
static func write_draft(m: Dictionary, map_code: String, map_name: String,
		target_path: String, baseline: String, snapshot: Dictionary,
		pending_files: Array = [], pending_ids: Array = []) -> String:
	var path := draft_path(m, map_code, map_name)
	if path == "":
		return ""
	var payload := {
		"kind": "draft",
		"mapName": map_name,
		"mapCode": map_code,
		"targetPath": target_path,
		"baseline": baseline,
		"snapshot": snapshot,
		"pendingFiles": pending_files,
		"pendingIds": pending_ids,
		"savedAt": Time.get_unix_time_from_system(),
	}
	return path if write_json(path, payload) else ""

static func read_draft(m: Dictionary, map_code: String, map_name: String) -> Dictionary:
	var p := draft_path(m, map_code, map_name)
	return read_json(p) if p != "" else {}

static func remove_draft(m: Dictionary, map_code: String, map_name: String) -> bool:
	var p := draft_path(m, map_code, map_name)
	if p == "" or not FileAccess.file_exists(p):
		return true
	return DirAccess.remove_absolute(p) == OK

## —— 按草稿键（= 文件名，无扩展名）直接寻址（A3）——
## 列表来自 list_drafts（文件名），UI 只有键、没有「当时用的是码还是图名」；
## 再拿空码 + 图名重算路径会算出别的键（带码地图尤其明显），所以键必须能独立解析。
static func draft_path_of_key(m: Dictionary, key: String) -> String:
	var k := key.strip_edges()
	var dir := _dir(m, DRAFT_DIR)
	if k == "" or dir == "":
		return ""
	return dir.path_join(k + ".json")

static func read_draft_key(m: Dictionary, key: String) -> Dictionary:
	var p := draft_path_of_key(m, key)
	return read_json(p) if p != "" else {}

static func remove_draft_key(m: Dictionary, key: String) -> bool:
	var p := draft_path_of_key(m, key)
	if p == "" or not FileAccess.file_exists(p):
		return true
	return DirAccess.remove_absolute(p) == OK

## 列出全部草稿键（供打开项目时提示可恢复项）。
static func list_drafts(m: Dictionary) -> Array:
	var dir := _dir(m, DRAFT_DIR)
	var out: Array = []
	if dir == "":
		return out
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if str(f).ends_with(".json"):
			var base := str(f).get_basename()
			# 冲突备份（<键>.conflict-<时间>）是留档，不是可恢复草稿：列出会让同一份草稿显示两次
			if base.contains(".conflict"):
				continue
			out.append(base)
	out.sort()
	return out

## 旧式草稿（maps/<名>.autosave.json）只在 _autosave_of 命中时作为草稿来源；
## 缺标记的同名文件按普通地图处理（A3）。返回 "" = 不是可归位的草稿。
static func legacy_draft_owner(m: Dictionary, path: String) -> String:
	var data := read_json(path)
	if str(data.get("_autosave_of", "")) == "":
		return ""
	return str(data.get("_autosave_of"))

# ──────────── 地图历史：editor/history/maps/<地图码>/ ────────────

static func _hist_dir(m: Dictionary, map_code: String, map_name: String) -> String:
	var base := _dir(m, HISTORY_DIR)
	if base == "":
		return ""
	var key := draft_key(map_code, map_name)
	return base.path_join(key) if key != "" else ""

static func _hist_stamp() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d-%02d%02d%02d-%03d" % [int(d.year), int(d.month), int(d.day),
		int(d.hour), int(d.minute), int(d.second), Time.get_ticks_msec() % 1000]

## 暂存原文件快照（写盘前调用）。返回快照路径，"" = 无原文件或暂存失败。
static func stage_snapshot(m: Dictionary, map_code: String, map_name: String, src_path: String) -> String:
	var dir := _hist_dir(m, map_code, map_name)
	if dir == "" or src_path == "" or not FileAccess.file_exists(src_path):
		return ""
	var staging := dir.path_join(".staged-" + _hist_stamp() + ".json")
	var text := read_text(src_path)
	if not write_text(staging, text):
		return ""
	return staging

## 新文件替换成功后，把暂存快照纳入历史并淘汰旧项。
## 原名保留 20 份（文件名带时间戳，字典序 = 时间序）；失败单独返回 false，不阻断保存。
static func commit_snapshot(m: Dictionary, map_code: String, map_name: String,
		staged_path: String, label := "") -> bool:
	if staged_path == "" or not FileAccess.file_exists(staged_path):
		return false
	var dir := staged_path.get_base_dir()
	var tag := label.strip_edges()
	if tag != "":
		tag = "-" + tag
	var final_path := dir.path_join(_hist_stamp() + tag + ".json")
	if DirAccess.rename_absolute(staged_path, final_path) != OK:
		return false
	_prune(dir)
	return true

static func discard_snapshot(staged_path: String) -> void:
	if staged_path != "" and FileAccess.file_exists(staged_path):
		DirAccess.remove_absolute(staged_path)

static func _prune(dir: String) -> void:
	var files: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		var n := str(f)
		if n.begins_with(".staged-"):
			continue   # 暂存由各自提交路径负责，不进历史计数
		if n.ends_with(".json"):
			files.append(n)
	files.sort()
	while files.size() > HISTORY_KEEP:
		DirAccess.remove_absolute(dir.path_join(str(files.pop_front())))

static func list_history(m: Dictionary, map_code: String, map_name: String) -> Array:
	var dir := _hist_dir(m, map_code, map_name)
	var out: Array = []
	if dir == "":
		return out
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		var n := str(f)
		if n.ends_with(".json") and not n.begins_with(".staged-"):
			out.append(n)
	out.sort()
	out.reverse()   # 最新在前
	return out

## 改名后历史随地图码走：码不变则目录不变，此处只在「无码兜底到图名」时需要搬。
static func migrate_history(m: Dictionary, old_code: String, old_name: String, new_code: String, new_name: String) -> void:
	var from := _hist_dir(m, old_code, old_name)
	var to := _hist_dir(m, new_code, new_name)
	if from == "" or to == "" or from == to or not DirAccess.dir_exists_absolute(from):
		return
	DirAccess.make_dir_recursive_absolute(to)
	for n in list_history(m, old_code, old_name):
		DirAccess.rename_absolute(from.path_join(str(n)), to.path_join(str(n)))
	DirAccess.remove_absolute(from)

# ──────────── 多文件提交日志：editor/pending/<stamp>.json ────────────

## 首次改写前登记：各目标基线与预期结果。返回日志路径，"" = 登记失败（调用方应中止提交）。
static func begin_pending(m: Dictionary, reason: String, entries: Array) -> String:
	var dir := _dir(m, PENDING_DIR)
	if dir == "":
		return ""
	var path := dir.path_join("pending-" + _hist_stamp() + ".json")
	var payload := {
		"kind": "pending",
		"reason": reason,
		"startedAt": Time.get_unix_time_from_system(),
		"entries": entries,   # [{path, baseline, expect, kind, id}]
		"done": 0,
	}
	return path if write_json(path, payload) else ""

## 每成功写一个文件就前移进度（崩溃后据此判断「已写/未写」）。
static func mark_pending_done(m: Dictionary, log_path: String, index: int) -> void:
	if log_path == "":
		return
	var d := read_json(log_path)
	if d.is_empty():
		return
	d["done"] = maxi(int(d.get("done", 0)), index + 1)
	write_json(log_path, d)

static func clear_pending(m: Dictionary, log_path: String) -> bool:
	if log_path == "":
		return true
	if not FileAccess.file_exists(log_path):
		return true
	return DirAccess.remove_absolute(log_path) == OK

## 启动时找未完成提交日志；返回 [{path, data, status}]。
## status: done（全部已写）/ partial（部分已写）/ stale（一个都没写）。
static func scan_pending(m: Dictionary) -> Array:
	var dir := _dir(m, PENDING_DIR)
	var out: Array = []
	if dir == "":
		return out
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		var n := str(f)
		if not (n.begins_with("pending-") and n.ends_with(".json")):
			continue
		var p := dir.path_join(n)
		var data := read_json(p)
		if data.is_empty():
			continue
		var entries: Array = data.get("entries", []) if data.get("entries", []) is Array else []
		var written := 0
		for e in entries:
			if not (e is Dictionary):
				continue
			var tgt := str((e as Dictionary).get("path", ""))
			var expect := str((e as Dictionary).get("expect", ""))
			if tgt == "":
				continue
			if expect != "" and FileAccess.file_exists(tgt) and digest(tgt) == expect:
				written += 1
		var status := "stale"
		if written == entries.size() and not entries.is_empty():
			status = "done"
		elif written > 0:
			status = "partial"
		out.append({"path": p, "data": data, "status": status, "written": written})
	out.sort_custom(func(a, b): return str(a.path) < str(b.path))
	return out

