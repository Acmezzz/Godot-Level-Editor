extends RefCounted
## 普通保存按清单、内容、地图写入；改名和复制用独立冻结计划。

const Recovery := preload("res://src/map/recovery.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const MapFormat := preload("res://src/map/map_format.gd")
## ContentStore 只在 prepare 里用来拼内容路径；**不 preload**：content_store 反向 preload 了
## map_store，而 map_store 要复用本模块做改名/复制的冻结计划，静态 preload 会成环。
const CONTENT_STORE_PATH := "res://src/content/content_store.gd"

static func _content_store():
	return load(CONTENT_STORE_PATH)

## prepare：按快照 + 磁盘基线冻结 Plan（只读盘点：无 UI 副作用，R28 口径）。
## operation = {manifest, map_name, map_path, map_dirty, map_snapshot}
func prepare(operation: Dictionary, snap: Dictionary) -> Dictionary:
	var m: Dictionary = operation.get("manifest", {})
	var targets: Array = []
	# 1) 清单补码（内容/地图引用它们之前必须落盘：依赖序第一）
	if bool((snap.get("manifest_changes", {}) as Dictionary).get("codes_pending", false)):
		var mpath := str(m.get("_dir", "")).path_join("editor/editor_manifest.json")
		targets.append({"op": "write", "kind": "manifest", "id": "",
			"path": mpath})
	var dependencies := _bound_content(operation.get("map_snapshot", {}))
	# 2) 暂存内容先于地图写盘；内部索引不能作为文件身份。
	#    V4 P0-1：新内容的目标必须声明「预期不存在」——不能只靠空摘要表达，
	#    否则提交期间出现的同路径文件会被当成合法基线并被覆盖。
	for row in (snap.get("contents", []) as Array):
		var r: Dictionary = row
		var cp: String = _content_store().path_for(m, str(r.get("fn_id", "")), str(r.get("cid", "")))
		if cp == "":
			return {"status": "failed", "error": "暂存内容目标非法：%s/%s" % [r.get("fn_id", ""), r.get("cid", "")]}
		var expect_absent := bool(r.get("expect_absent", true))
		var baseline := str(r.get("baseline", ""))
		if not expect_absent and baseline == "":
			return {"status": "failed", "error": "暂存内容缺少替换基线：%s" % cp}
		var binding := [FunctionDecls.fn_code(m, str(r.get("fn_id", ""))), str(r.get("cid", ""))]
		var required := dependencies.has(binding)
		targets.append({"op": "write", "kind": "content", "id": str(r.get("cid", "")),
			"path": cp, "baseline": baseline, "expected": "",
			"expect_absent": expect_absent, "required": required,
			"payload": {"fn_id": str(r.get("fn_id", "")), "cid": str(r.get("cid", "")),
				"data": r.get("data", {}), "expect_absent": expect_absent, "baseline": baseline, "required": required}})
	# 3) 地图（只脏图入计划：干净图没有待写项；写前外部改动确认在 hooks.save_map 里）
	if bool(operation.get("map_dirty", false)) and str(operation.get("map_path", "")) != "":
		var data: Dictionary = operation.get("map_snapshot", {})
		if not data.is_empty():
			var maps := load("res://src/map/map_store.gd")
			var problem: String = maps.identity_error(m, str(operation.get("map_name", "")), data)
			if problem != "":
				return {"status": "failed", "error": problem}
		targets.append({"op": "write", "kind": "map", "id": str(operation.get("map_name", "")),
			"path": str(operation.get("map_path", ""))})
	if targets.is_empty():
		return {"status": "empty"}
	return {"status": "ok", "plan": {"map_code": str(snap.get("map", "")),
		"targets": targets}}

static func _bound_content(data: Dictionary) -> Dictionary:
	var keys := {}
	for obj in data.get("objects", []):
		if not (obj is Dictionary) or not (obj.get("functions", null) is Array):
			continue
		for binding in obj["functions"]:
			if binding is Dictionary:
				var code := str(binding.get("fn", ""))
				var cid := str(binding.get("content", ""))
				if cid != "":
					keys[[code, cid]] = true
	return keys

## 清单和地图的外部改动确认由写入入口处理。
func apply(plan: Dictionary, hooks: Dictionary) -> Dictionary:
	var targets: Array = plan.targets
	var written: Array = []
	var receipts: Array = []
	var receipt := {}
	for target: Dictionary in targets:
		var kind: String = target.kind
		var path: String = target.path
		var status := "ok"
		var error := ""
		if not hooks.is_current.call():
			status = "failed"
			error = "提交期间工作副本已变化"
		elif kind == "manifest":
			if not await hooks.save_manifest.call():
				status = "cancelled"
				error = "清单补码保存被取消或失败"
		elif kind == "map":
			if not await hooks.save_map.call():
				status = "failed"
				error = "地图保存失败"
		else:
			status = str(hooks.flush_one.call(target.id, target.payload).status)
			if status == "conflict":
				error = "内容文件在提交期间被外部改动：%s" % path
			elif status != "ok" and (status != "dropped" or target.required):
				status = "failed"
				error = "暂存内容未写入：%s" % path
		if error != "":
			receipts.append(_receipt_of(target, "conflict" if status == "conflict" else "failed", ""))
			receipts.append_array(_receipts_pending(targets, path))
			return {"status": status, "written": written, "error": error, "targets": receipts}
		if status == "dropped":
			receipts.append(_receipt_of(target, "dropped", ""))
			continue
		var digest := Recovery.digest(path)
		written.append(kind)
		receipts.append(_receipt_of(target, "written", digest))
		if kind == "map":
			receipt = {"map_code": plan.map_code, "absolute_path": path, "map_digest": digest}
	return {"status": "ok", "written": written, "receipt": receipt, "targets": receipts}

## §4.4-4：非「清单→内容→地图」入口的计划构造（改名 / 整图复制 / 跨图清理）。
## targets 每项 = {path, kind, id, baseline?, expect_absent?, frozen_text?, op?}；
## prepare 会把 baseline 按**此刻磁盘**重算（调用方只给「要写什么、「预期不存在」或「要删」」），
## apply_frozen 按计划复验并写入，逐目标记录结果。
## 返回 {status: ok|empty, plan}。
static func prepare_frozen(reason: String, manifest: Dictionary, targets: Array) -> Dictionary:
	var out: Array = []
	for t in targets:
		var td: Dictionary = (t as Dictionary).duplicate(true)
		# content 目标只给 {fn_id, id, data}：路径由 ContentStore 派生（入口不重复拼路径）
		if str(td.get("kind", "")) == "content":
			var content_path: String = _content_store().path_for(manifest,
				str(td.get("fn_id", "")), str(td.get("id", "")))
			if content_path == "" or str(td.get("path", content_path)) not in ["", content_path]:
				return {"status": "failed", "error": "冻结内容目标非法：%s" % str(td.get("id", ""))}
			td["path"] = content_path
			if not td.has("expect_absent"):
				td["expect_absent"] = true
		var p := str(td.get("path", ""))
		var op := str(td.get("op", "write"))
		if p == "" or not op in ["write", "delete", "rename"]:
			return {"status": "failed", "error": "冻结目标非法：%s" % str(td.get("id", ""))}
		var source := str(td.get("from", "")) if op == "rename" else p
		td["target_absent"] = op == "rename" or bool(td.get("expect_absent", false))
		if op != "write" or not td.target_absent:
			if not td.has("baseline"):
				td["baseline"] = Recovery.digest(source)
			if str(td.get("baseline", "")) == "" or source == "":
				return {"status": "failed", "error": "无法取得冻结目标的替换基线：%s" % source}
		elif not td.has("baseline"):
			td["baseline"] = ""
		td.erase("expect_absent")
		out.append(td)
	if out.is_empty():
		return {"status": "empty"}
	return {"status": "ok", "plan": {"token": "", "revision": 0, "operation": reason,
		"manifest": manifest, "map_code": "", "targets": out}}

## 改名落盘 = 一次文件系统重命名（原子，不会留下「新旧都在」的中间态）。
## §4.4-4：改名以前在 MapStore 里手写 begin_pending/mark_pending_written；
## 现在作为一条 rename 目标进冻结计划，与其它入口共用同一套日志与收据。
## from = 旧路径，path = 新路径。新路径必须不存在（create-only）。
static func rename_target(old_path: String, new_path: String, name_: String) -> Dictionary:
	return {"path": new_path, "kind": "map", "id": name_, "op": "rename",
		"from": old_path, "expect_absent": true}

## §4.4-4：**同步**执行冻结计划——给改名 / 整图复制 / 跨图清理这些数据层入口用
## （它们不在 UI 协程里，也不能让钩子插进来改计划）。支持的目标类型：
##   op = "rename"  {path: 新路径, from: 旧路径}          —— 源摘要复验后原子重命名
##   op = "delete"  {path, baseline}                      —— 摘要复验后删除
##   kind = "content" {fn_id, id, data}                    —— ContentStore 新建（逐条回填日志）
##   frozen_text    {path, frozen_text, target_absent?}   —— 原样写冻结字节
## 与 apply 同一套日志/复验/收据口径；返回结构也一致（status/written/conflicts/error/journal/targets）。
static func _matches_file(path: String, expect_absent: bool, baseline: String) -> bool:
	var observed := Recovery.observe(path)
	if expect_absent:
		return observed.state == "missing"
	return observed.state == "present" and baseline != "" and observed.digest == baseline

static func _journal_entries(targets: Array) -> Array:
	var entries: Array = []
	for target in targets:
		var row: Dictionary = target
		var op := str(row.get("op", "write"))
		var baseline := str(row.get("baseline", ""))
		var expect := str(row.get("expected", ""))
		if op == "rename":
			expect = baseline
		elif row.has("frozen_text"):
			expect = str(row.frozen_text).sha256_text()
		elif row.has("map_data"):
			expect = MapFormat.encode(row.map_data).sha256_text()
		elif row.get("kind") == "content":
			var data: Dictionary = row.get("payload", row).get("data", {}).duplicate(true)
			data["id"] = str(row.get("id", ""))
			expect = JSON.stringify(data, "\t").sha256_text()
		entries.append({"path": str(row.get("path", "")), "baseline": baseline, "expect": expect,
			"kind": str(row.get("kind", "")), "id": str(row.get("id", "")), "op": op,
			"from": str(row.get("from", "")),
			"expect_absent": bool(row.get("target_absent", row.get("expect_absent", false)))})
	return entries

func apply_frozen(plan: Dictionary) -> Dictionary:
	var m: Dictionary = plan.get("manifest", {})
	var targets: Array = plan.get("targets", [])
	var written: Array = []
	var receipts: Array = []
	var receipt := {}
	if targets.is_empty():
		return {"status": "ok", "written": [], "conflicts": [], "receipt": {}, "targets": []}
	var maps := load("res://src/map/map_store.gd")
	var planned_codes := {}
	for i in targets.size():
		var target: Dictionary = targets[i]
		if not target.has("map_data"):
			continue
		var move_from := str(target.get("move_from", ""))
		var problem: String = maps.identity_error(m, str(target.id), target.map_data, move_from)
		var code := str(target.map_data.get("meta", {}).get("code", ""))
		if code != "" and planned_codes.has(code):
			problem = "提交计划中的多个地图目标使用同一个地图码：%s" % code
		if code != "":
			planned_codes[code] = true
		if problem == "" and move_from != "":
			var old_path: String = maps.path_for(m, move_from)
			var deletion: Array = targets.filter(func(row): return row.get("kind") == "map" and row.get("op") == "delete" and row.path == old_path)
			if old_path == "" or deletion.size() != 1 or targets.find(deletion[0]) <= i \
					or not _matches_file(old_path, false, str(deletion[0].get("baseline", ""))) \
					or str(maps.read(m, move_from).get("meta", {}).get("code", "")) != code:
				problem = "改名源文件已变化或不在删除计划中：%s" % move_from
		if problem != "":
			return {"status": "failed", "written": [], "error": problem, "targets": _receipts_pending(targets, "")}
	var journal := _journal_entries(targets)
	var log_path := Recovery.begin_pending(m, str(plan.get("operation", "")), journal)
	if log_path == "":
		return {"status": "failed", "written": [], "conflicts": [],
			"error": "提交日志写入失败：已中止（未写任何文件）",
			"targets": _receipts_pending(targets, "")}
	for t2 in targets:
		var tgt: Dictionary = t2
		var kind := str(tgt.get("kind", ""))
		var path := str(tgt.get("path", ""))
		var op := str(tgt.get("op", "write"))
		if op in ["rename", "delete"]:
			var result := _apply_file_operation(tgt, targets, receipts, written, m, log_path, journal)
			if not result.is_empty():
				return result
			continue
		var absent := bool(tgt.get("target_absent", false))
		var baseline := str(tgt.get("baseline", ""))
		if not _matches_file(path, absent, baseline):
			return _frozen_conflict(tgt, targets, receipts, log_path, "写入目标已变化：%s" % path)
		if kind == "content":
			var cs = _content_store()
			var p: String = cs.path_for(m, str(tgt.get("fn_id", "")), str(tgt.get("id", "")))
			if p != path:
				return _frozen_fail(tgt, targets, receipts, written, log_path, "内容路径与计划不符：%s" % path)
			var wr: Dictionary = cs.write_ex(m, str(tgt.get("fn_id", "")), str(tgt.get("id", "")),
				tgt.get("data", {}) as Dictionary, baseline, false, absent)
			if bool(wr.get("conflict", false)):
				return _frozen_conflict(tgt, targets, receipts, log_path, "内容目标已变化：%s" % p)
			if not bool(wr.get("ok", false)):
				return _frozen_fail(tgt, targets, receipts, written, log_path,
					"内容写入失败：%s" % str(tgt.get("id", "")))
			written.append("content")
			if not _frozen_mark(tgt, journal, receipts, m, log_path, p):
				return _frozen_log_fail(targets, receipts, written, log_path, p)
			continue
		# 冻结字节目标（地图文档等）
		if tgt.has("map_data"):
			var md: Dictionary = tgt.get("map_data", {}) if tgt.get("map_data", null) is Dictionary else {}
			var MS := load("res://src/map/map_store.gd")
			if str(MS.path_for(m, str(tgt.get("id", "")))) != path or md.is_empty() \
					or not MS.write(m, str(tgt.get("id", "")), md, str(tgt.get("move_from", ""))):
				return _frozen_fail(tgt, targets, receipts, written, log_path,
					"地图写盘失败（写前校验不过或目标不可写）：%s" % path)
			written.append(kind)
			if not _frozen_mark(tgt, journal, receipts, m, log_path, path):
				return _frozen_log_fail(targets, receipts, written, log_path, path)
			continue
		if str(tgt.get("frozen_text", "")) == "":
			return _frozen_fail(tgt, targets, receipts, written, log_path,
				"计划缺少冻结字节：%s" % path)
		if not Recovery.write_text(path, str(tgt.get("frozen_text", ""))):
			return _frozen_fail(tgt, targets, receipts, written, log_path, "写盘失败：%s" % path)
		written.append(kind)
		if not _frozen_mark(tgt, journal, receipts, m, log_path, path):
			return _frozen_log_fail(targets, receipts, written, log_path, path)
	Recovery.clear_pending(m, log_path)
	if written.has("map"):
		for t3 in targets:
			if str((t3 as Dictionary).get("kind", "")) == "map":
				receipt = {"map_code": "", "absolute_path": str((t3 as Dictionary).get("path", "")),
					"map_digest": Recovery.digest(str((t3 as Dictionary).get("path", "")))}
				break
	return {"status": "ok", "written": written, "conflicts": [], "receipt": receipt,
		"journal": log_path, "targets": receipts}

## 冻结计划的三种提前返回，收据口径与 apply 一致（已完成部分 + 其后 pending）。
func _apply_file_operation(tgt: Dictionary, targets: Array, receipts: Array,
		written: Array, m: Dictionary, log_path: String, journal: Array) -> Dictionary:
	var path := str(tgt.get("path", ""))
	var baseline := str(tgt.get("baseline", ""))
	var deleting: bool = tgt.get("op") == "delete"
	var source := path if deleting else str(tgt.get("from", ""))
	if not _matches_file(source, false, baseline) or (not deleting and not _matches_file(path, true, "")):
		return _frozen_conflict(tgt, targets, receipts, log_path, "改名或删除目标已变化：%s" % source)
	var err := DirAccess.remove_absolute(path) if deleting else DirAccess.rename_absolute(source, path)
	if err != OK:
		return _frozen_fail(tgt, targets, receipts, written, log_path, "无法改名或删除：%s" % source)
	written.append(str(tgt.get("kind", "")))
	var digest := "" if deleting else Recovery.digest(path)
	receipts.append(_receipt_of(tgt, "deleted" if deleting else "written", digest))
	if not _mark_unpredicted(m, log_path, journal, receipts.size() - 1, digest):
		return _frozen_log_fail(targets, receipts, written, log_path, path)
	return {}

func _frozen_conflict(tgt: Dictionary, targets: Array, receipts: Array, log_path: String, msg: String) -> Dictionary:
	var written: Array = []
	for row in receipts:
		if row.get("status") in ["written", "deleted"]:
			written.append(row.get("kind", ""))
	var failed := _receipt_of(tgt, "conflict", "")
	failed["message"] = msg
	receipts.append(failed)
	receipts.append_array(_receipts_pending(targets, str(tgt.get("path", ""))))
	return {"status": "conflict", "written": written, "conflicts": [{"path": str(tgt.get("path", "")),
		"kind": str(tgt.get("kind", "")), "message": msg}], "receipt": {}, "targets": receipts, "journal": log_path}

func _frozen_fail(tgt: Dictionary, targets: Array, receipts: Array, written: Array, log_path: String,
		msg: String) -> Dictionary:
	var failed := _receipt_of(tgt, "failed", "")
	failed["message"] = msg
	receipts.append(failed)
	receipts.append_array(_receipts_pending(targets, str(tgt.get("path", ""))))
	return {"status": "failed", "written": written, "conflicts": [], "error": msg,
		"journal": log_path, "targets": receipts}

## 回填一条成功进度；false = 日志已不可判读（调用方停在已写状态）。
func _frozen_mark(tgt: Dictionary, journal: Array, receipts: Array,
		m: Dictionary, log_path: String, digest_path: String) -> bool:
	var dig := Recovery.digest(digest_path)
	if not _mark_unpredicted(m, log_path, journal, receipts.size(), dig):
		receipts.append(_receipt_of(tgt, "written", dig))
		return false
	receipts.append(_receipt_of(tgt, "written", dig))
	return true

func _frozen_log_fail(targets: Array, receipts: Array, written: Array, log_path: String, after: String) -> Dictionary:
	receipts.append_array(_receipts_pending(targets, after))
	return {"status": "failed", "written": written, "conflicts": [],
		"error": "提交日志进度回填失败：已写文件保留，其后目标未写（日志已留在 editor/pending 供复核）",
		"journal": log_path, "targets": receipts}

## 摘要已在写前日志登记时，重启可直接核对磁盘，无须重写日志。
static func _mark_unpredicted(m: Dictionary, path: String, journal: Array, index: int, digest: String) -> bool:
	if index < 0 or index >= journal.size():
		return false
	var entry: Dictionary = journal[index]
	if str(entry.get("op", "")) == "delete" or (digest != "" and digest == str(entry.get("expect", ""))):
		return true
	return Recovery.mark_pending_written(m, path, index, digest)

## 单目标收据：{kind, id, path, status, digest}。digest 只在真写了文件时给。
static func _receipt_of(tgt: Dictionary, status: String, dig: String) -> Dictionary:
	return {"kind": str(tgt.get("kind", "")), "id": str(tgt.get("id", "")), "fn_id": str(tgt.get("fn_id", "")),
		"path": str(tgt.get("path", "")), "status": status, "digest": dig}

## 停在某目标之后：其后目标全部记为 pending（含因提前返回而没轮到的）。
## after_path = "" 表示一个都还没轮上（整份计划都是 pending）。
static func _receipts_pending(targets: Array, after_path: String) -> Array:
	var out: Array = []
	if after_path == "":
		for t in targets:
			out.append(_receipt_of(t as Dictionary, "pending", ""))
		return out
	var seen := false
	for t in targets:
		var td: Dictionary = t
		if not seen:
			if str(td.get("path", "")) == after_path:
				seen = true
			continue
		out.append(_receipt_of(td, "pending", ""))
	return out
