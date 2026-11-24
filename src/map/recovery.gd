extends RefCounted
## A3 恢复层，三个互不相同的保险：
##   editor/drafts/<地图码>.json   —— 自动草稿：整图快照 + 目标路径 + 基线摘要 + 待提交内容/预留 ID。
##                                   不自动载入，进项目时报数由用户选 恢复/查看正式图/丢弃。
##   editor/pending/pending-*.json —— 多文件提交日志：逐条记录「要写哪个文件 + 写前/写后摘要」，
##                                   下次启动据此判每一条 written/pending/manual。
## 本模块只做路径解析与 JSON/字节读写，不解释业务；不 preload map_store（避免反向依赖成环）。
## 各入口会提交哪些文件由 docs/EDITOR_FEATURES.md §7.3「各入口提交哪些文件」唯一规定。

const DRAFT_DIR := "editor/drafts"
const PENDING_DIR := "editor/pending"

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
	# V4 P0-3：每次写入用唯一临时名。固定 ".tmp" 会让并发/重入写入互相覆盖，
	# 而提交日志正是用来在崩溃后判读「哪些文件写过」的唯一依据。
	var tmp := path + ".tmp-" + str(Time.get_ticks_usec()) + "-" + str(randi() % 100000)
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

## 读取正文和同源摘要，区分缺失和读失败。
static func observe(path: String) -> Dictionary:
	if path == "" or DirAccess.dir_exists_absolute(path):
		return {"state": "unreadable"}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		var state := "missing" if FileAccess.get_open_error() == ERR_FILE_NOT_FOUND else "unreadable"
		return {"state": state}
	var text := f.get_as_text()
	var err := f.get_error()
	f.close()
	if err != OK and err != ERR_FILE_EOF:
		return {"state": "unreadable"}
	return {"state": "present", "text": text, "digest": text.sha256_text()}

static func digest(path: String) -> String:
	return str(observe(path).get("digest", ""))

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

## 写草稿：记录目标路径、正式图基线、地图快照、待提交内容载荷（R03：数据本体进草稿，
## 恢复时校验绑定后重新暂存，不再只有文件路径）、以及**清单补码是否待写**——
## 地图里可能已经用了刚补发的资产码/功能码，漏了这项恢复后保存会先写地图再补清单。
## codes_map（R07）：上次会话实际补发的声明身份（函数/条件/步骤/音频/时机/资产 id → 码）。
## 只存标记不存映射时重启会重发新码，草稿里的引用随之作废。
static func write_draft(m: Dictionary, map_code: String, map_name: String,
		target_path: String, baseline: String, snapshot: Dictionary,
		pending_contents: Array = [], codes_pending := false, codes_map := {}) -> String:
	var path := draft_path(m, map_code, map_name)
	if path == "":
		return ""
	var payload := {
		"kind": "draft",
		"key": draft_key(map_code, map_name),
		"mapName": map_name,
		"mapCode": map_code,
		"targetPath": target_path,
		"baseline": baseline,
		"snapshot": snapshot,
		"pendingContents": pending_contents,   # [{fn_id, id, data}]（R03）
		"codesPending": codes_pending,
		"codesMap": codes_map,                 # 上次会话已发出的码（R07 恢复合并）
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

static func _log_stamp() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d-%02d%02d%02d-%03d" % [int(d.year), int(d.month), int(d.day),
		int(d.hour), int(d.minute), int(d.second), Time.get_ticks_msec() % 1000]

# ──────────── 多文件提交日志：editor/pending/<stamp>.json ────────────

## 首次改写前登记：各目标基线与预期结果。返回日志路径，"" = 登记失败（调用方应中止提交）。
static func begin_pending(m: Dictionary, reason: String, entries: Array) -> String:
	var dir := _dir(m, PENDING_DIR)
	if dir == "":
		return ""
	var path := dir.path_join("pending-" + _log_stamp() + ".json")
	var payload := {
		"kind": "pending",
		"reason": reason,
		"startedAt": Time.get_unix_time_from_system(),
		"entries": entries,   # [{path, baseline, expect, kind, id}]
		"done": 0,
	}
	return path if write_json(path, payload) else ""

## 每个文件写成功后把**实际结果摘要**记进日志（A3）：重启时逐条比对就能分清
## 已写（摘要相符）/ 未写（仍与基线相符）/ 已变（两者都不符 → 外部改过或写了一半 → 人工复核）。
## 只记摘要，不重放内容：同 ID 重试仍走各自的补写路径（内容页暂存 / 地图保存）。
## 回填某条目标的写后摘要（R04）。返回是否真的写进日志：
## 日志被外部删掉/改写导致回填失败时，调用方必须停手——继续写下去会留下
## 「文件已替换、日志却说没写」的不可判读状态。
static func mark_pending_written(m: Dictionary, log_path: String, index: int, result_digest: String) -> bool:
	if log_path == "":
		return false
	var d := read_json(log_path)
	if d.is_empty():
		return false
	var entries: Array = d.get("entries", []) if d.get("entries", []) is Array else []
	if index < 0 or index >= entries.size() or not (entries[index] is Dictionary):
		return false
	(entries[index] as Dictionary)["expect"] = result_digest
	d["entries"] = entries
	d["done"] = maxi(int(d.get("done", 0)), index + 1)
	return write_json(log_path, d)

static func clear_pending(m: Dictionary, log_path: String) -> bool:
	if log_path == "":
		return true
	if not FileAccess.file_exists(log_path):
		return true
	return DirAccess.remove_absolute(log_path) == OK

## 启动时找未完成提交日志；返回 [{path, data, status, written, pending, manual, entries}]。
## 每条按「当前文件摘要 vs 登记的预期/基线」判定（A3）：
##   written 已写（摘要 == 写后预期）/ pending 未写（摘要仍 == 提交前基线）/
##   manual 两边都不符（外部改过或写了一半）→ 不能自动重放，交人工复核。
## status 汇总：done（全 written）/ partial（有写有没写）/ stale（全没写）/ manual（有对不上的）。
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
			# §4.4 五态之一：日志本身读不出（截断/坏 JSON）——不能静默跳过，
			# 否则用户以为没有待办，实际是一份无法判读的提交记录躺在盘上。
			out.append({"path": p, "data": {}, "status": "corrupt", "written": 0,
				"pending": 0, "manual": 1, "entries": [], "skipped": [], "external": []})
			continue
		var entries: Array = data.get("entries", []) if data.get("entries", []) is Array else []
		var written := 0
		var pending := 0
		var manual := 0
		var judged: Array = []
		for e in entries:
			if not (e is Dictionary):
				continue
			var entry := e as Dictionary
			var tgt := str(entry.get("path", ""))
			var expect := str(entry.get("expect", ""))
			var base := str(entry.get("baseline", ""))
			var op := str(entry.get("op", "write"))
			var seen := observe(tgt)
			var cur := str(seen.get("digest", ""))
			var state := "manual"
			if op == "delete":
				if seen.state == "missing":
					state = "written"
				elif base != "" and cur == base:
					state = "pending"
			elif op == "rename":
				var src := observe(str(entry.get("from", "")))
				if src.state == "missing" and expect != "" and cur == expect:
					state = "written"
				elif seen.state == "missing" and base != "" and src.get("digest", "") == base:
					state = "pending"
			elif seen.state == "missing" and base == "" \
					and (bool(entry.get("expect_absent", false)) or expect == ""):
				state = "pending"
			elif expect != "" and cur == expect:
				state = "written"
			elif base != "" and cur == base:
				state = "pending"
			match state:
				"written": written += 1
				"pending": pending += 1
				"manual": manual += 1
			var copy := entry.duplicate()
			copy["state"] = state
			judged.append(copy)
		var status := "stale"
		if manual > 0:
			status = "manual"
		elif written == entries.size() and not entries.is_empty():
			status = "done"
		elif written > 0:
			status = "partial"
		# §4.4：待办项按「是否仍可无风险继续」再分一档——基线/预期都空的目标（新建文件）
		# 目标不在就是待写；目标已在但内容不符才是「外部改变」。
		var skipped: Array = []
		var external: Array = []
		for j in judged:
			var jd: Dictionary = j
			if str(jd.get("state", "")) != "manual":
				continue
			var jt := str(jd.get("path", ""))
			# 目标已不在且没登记基线：这份计划已经不可能按原意落地（跳过），不是冲突
			if jt != "" and not FileAccess.file_exists(jt) and str(jd.get("baseline", "")) == "":
				skipped.append(jd)
			else:
				external.append(jd)
		out.append({"path": p, "data": data, "status": status, "written": written,
			"pending": pending, "manual": manual, "entries": judged,
			"skipped": skipped, "external": external})
	out.sort_custom(func(a, b): return str(a.path) < str(b.path))
	return out

