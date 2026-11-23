extends RefCounted
## DocumentCommit（§7.1）：提交编排。prepare 冻结 Plan（{token, revision, operation, targets}）；
## apply 按依赖序执行：persist_journal 先于第一次替换 → 逐目标写前复验 → 写入即历史保留
## （MapStore/ContentStore 自带）→ 逐文件记录进度（提交日志）。清单与地图的实际写入是
## UI 侧职责（外部改动确认对话框），经 hooks 协程注入；内容写入在本模块内直接走 ContentStore。
## §4.4-4：改名 / 整图复制 / 跨图清理也走本模块的冻结计划（prepare_frozen + frozen_text/rename/delete
## 目标），所以「一次操作写哪些文件」只有这一个执行器，UI 与数据层都调它。
## **一次操作写哪些文件的唯一定义**在 docs/EDITOR_FEATURES.md §7.3「各入口提交哪些文件」；
## 本模块只实现其中「清单 → 内容 → 地图」这一条的编排，不另行维护文件清单。

const Recovery := preload("res://src/map/recovery.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
## ContentStore 只在 prepare 里用来拼内容路径；**不 preload**：content_store 反向 preload 了
## map_store，而 map_store 要复用本模块做改名/复制的冻结计划，静态 preload 会成环。
const CONTENT_STORE_PATH := "res://src/content/content_store.gd"

static func _content_store():
	return load(CONTENT_STORE_PATH)

## prepare：按快照 + 磁盘基线冻结 Plan（只读盘点：无 UI 副作用，R28 口径）。
## operation = {reason, manifest, map_name, map_path, map_digest, map_dirty}
func prepare(operation: Dictionary, snap: Dictionary) -> Dictionary:
	var m: Dictionary = operation.get("manifest", {})
	var targets: Array = []
	# 1) 清单补码（内容/地图引用它们之前必须落盘：依赖序第一）
	if bool((snap.get("manifest_changes", {}) as Dictionary).get("codes_pending", false)):
		var mpath := str(m.get("_dir", "")).path_join("editor/editor_manifest.json")
		targets.append({"op": "write", "kind": "manifest", "id": "",
			"path": mpath, "baseline": Recovery.digest(mpath), "expected": str(operation.get("manifest_expected", ""))})
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
		var expected := JSON.stringify(data, "\t").sha256_text() if not data.is_empty() else ""
		var baseline := str(operation.get("map_digest", ""))
		targets.append({"op": "write", "kind": "map", "id": str(operation.get("map_name", "")),
			"path": str(operation.get("map_path", "")), "baseline": baseline,
			"expected": expected, "expect_absent": baseline == ""})
	if targets.is_empty():
		return {"status": "empty"}
	return {"status": "ok", "plan": {"token": str(snap.get("token", "")), "revision": int(snap.get("revision", 0)),
		"operation": str(operation.get("reason", "")), "manifest": m, "map_code": str(snap.get("map", "")),
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

## apply：执行冻结 Plan。hooks（全部 Callable）：
##   save_manifest() -> bool（协程；清单写盘含外部改动确认）
##   save_map() -> bool（协程；地图写盘含外部改动确认）
##   flush_one(cid) -> {status: ok|dropped|failed}（单条暂存内容：绑定复核 + 写盘 + 丢弃登记）
## 逐目标写前复验只对内容目标做（清单/地图的外部改动由各自 hook 的确认 UI 处理）；
## 复验不符 → conflict 停，提交日志保留（§7.1 stop_with_conflict）。
## §4.4-3 逐目标收据：`targets` 数组对**每个计划目标**给 {path, kind, id, status, digest}
## （status = written / deleted / dropped / pending / conflict / failed）。提前返回（conflict/failed）
## 时也带上已完成的部分——调用方据此知道「哪些落盘了、哪些没有」，不必再猜。
##
## §4.4-4 分批接入口：除「清单 → 内容 → 地图」这条常规链，本执行器也承接
## 改名（写新 + 删旧）、整图复制（N 内容 + 1 地图）、跨图清理（N 地图）等入口。
## 这些入口用 `plan_targets()` 构造计划，目标可带：
##   frozen_text：prepare 时序列化好的字节，apply 直接原样写（不再回读表单/画布）
##   op = "delete"：按 baseline 摘要复验后删除（旧文件已消失 = 冲突，不静默当成功）
func apply(plan: Dictionary, hooks: Dictionary) -> Dictionary:
	var m: Dictionary = plan.get("manifest", {})
	var targets: Array = plan.get("targets", [])
	var written: Array = []
	var conflicts: Array = []
	var receipts: Array = []
	var receipt := {}
	if targets.is_empty():
		return {"status": "ok", "written": [], "conflicts": [], "receipt": {}, "targets": []}
	var journal := _journal_entries(targets)
	var log_path := Recovery.begin_pending(m, str(plan.get("operation", "")), journal)
	if log_path == "":
		return {"status": "failed", "written": written, "conflicts": [],
			"error": "提交日志写入失败：已中止（未写任何文件）",
			"targets": _receipts_pending(targets, "")}
	var guard: Callable = hooks.get("is_current", Callable())
	for t2 in targets:
		var tgt: Dictionary = t2
		if guard.is_valid() and not guard.call():
			return _frozen_fail(tgt, targets, receipts, written, log_path, "提交期间工作副本已变化")
		var kind := str(tgt.get("kind", ""))
		var path := str(tgt.get("path", ""))
		var op := str(tgt.get("op", "write"))
		if op == "rename":
			# 改名：源必须仍是计划时那份（外部改动 → 冲突），目标必须仍不存在。
			var from := str(tgt.get("from", ""))
			var rbase := str(tgt.get("baseline", ""))
			var rconf := ""
			if not FileAccess.file_exists(from):
				rconf = "待改名文件在提交期间已不存在：%s" % from
			elif rbase != "" and Recovery.digest(from) != rbase:
				rconf = "待改名文件在提交期间被外部改动：%s" % from
			elif FileAccess.file_exists(path):
				rconf = "新文件名在提交期间已被占用：%s" % path
			if rconf != "":
				receipts.append(_receipt_of(tgt, "conflict", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "conflict", "written": written, "conflicts": [{"path": path,
					"kind": kind, "message": rconf}],
					"receipt": {}, "journal": log_path, "targets": receipts}
			if DirAccess.rename_absolute(from, path) != OK:
				receipts.append(_receipt_of(tgt, "failed", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "failed", "written": written, "conflicts": [],
					"error": "文件系统重命名失败：%s → %s" % [from, path],
					"journal": log_path, "targets": receipts}
			written.append(kind)
			var rdig := Recovery.digest(path)
			if not Recovery.mark_pending_written(m, log_path, targets.find(tgt), rdig):
				receipts.append(_receipt_of(tgt, "written", rdig))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "failed", "written": written, "conflicts": [],
					"error": "提交日志进度回填失败：改名已完成，请在 editor/pending 复核",
					"journal": log_path, "targets": receipts}
			receipts.append(_receipt_of(tgt, "written", rdig))
			continue
		if op == "delete":
			# 删除目标：计划时的摘要必须仍在（旧文件已消失/被改写都不是「删掉了它的旧内容」）
			var del_base := str(tgt.get("baseline", ""))
			if not FileAccess.file_exists(path):
				receipts.append(_receipt_of(tgt, "conflict", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "conflict", "written": written, "conflicts": [{"path": path,
					"kind": kind, "message": "待删除文件在提交期间已不存在：%s" % path}],
					"receipt": {}, "journal": log_path, "targets": receipts}
			if del_base != "" and Recovery.digest(path) != del_base:
				receipts.append(_receipt_of(tgt, "conflict", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "conflict", "written": written, "conflicts": [{"path": path,
					"kind": kind, "message": "待删除文件在提交期间被外部改动：%s" % path}],
					"receipt": {}, "journal": log_path, "targets": receipts}
			if DirAccess.remove_absolute(path) != OK:
				receipts.append(_receipt_of(tgt, "failed", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "failed", "written": written, "conflicts": [],
					"error": "删除失败：%s" % path, "journal": log_path, "targets": receipts}
			written.append(kind)
			if not Recovery.mark_pending_written(m, log_path, targets.find(tgt), ""):
				receipts.append(_receipt_of(tgt, "deleted", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "failed", "written": written, "conflicts": [],
					"error": "提交日志进度回填失败：已删除文件保留结果，其后目标未处理",
					"journal": log_path, "targets": receipts}
			receipts.append(_receipt_of(tgt, "deleted", ""))
			continue
		if kind == "content":
			# §7.1 accepted_state：写前复验磁盘状态与 prepare 基线一致。
			# 计划里「预期不存在」的新内容：文件在提交期间被别的写入方创建 → 冲突停，
			# 绝不用暂存加载覆盖刚出现的正式文件。
			if not _matches_file(path, bool(tgt.get("expect_absent", false)), str(tgt.get("baseline", ""))):
				conflicts.append({"path": path, "kind": kind,
					"message": "内容文件在提交期间被外部改动：%s" % path})
				receipts.append(_receipt_of(tgt, "conflict", ""))
				receipts.append_array(_receipts_pending(targets, str(path)))
				return {"status": "conflict", "written": written, "conflicts": conflicts,
					"receipt": {}, "journal": log_path, "targets": receipts}
		var ok := false
		if kind == "manifest":
			ok = await hooks.save_manifest.call()
			if ok:
				written.append("manifest")
		elif kind == "content":
			# 写入使用冻结的 payload，不回读当前表单：Plan 里是什么就写什么（R04/A2）。
			var payload: Dictionary = tgt.get("payload", {}) if tgt.get("payload", null) is Dictionary else {}
			var res: Dictionary = hooks.flush_one.call(str(tgt.get("id", "")), payload)
			var st := str(res.get("status", ""))
			if st == "failed":
				receipts.append(_receipt_of(tgt, "failed", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "failed", "written": written, "conflicts": [],
					"error": "暂存内容写盘失败：%s" % str(tgt.get("id", "")),
					"journal": log_path, "targets": receipts}
			if st == "conflict":
				receipts.append(_receipt_of(tgt, "conflict", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "conflict", "written": written, "conflicts": [{"path": path,
					"kind": kind, "message": "内容目标在提交期间被创建或改动：%s" % path}],
					"receipt": {}, "journal": log_path, "targets": receipts}
			if st != "ok" and (st != "dropped" or bool(tgt.get("required", false))):
				receipts.append(_receipt_of(tgt, "failed", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "failed", "written": written, "conflicts": [],
					"error": "地图依赖的暂存内容未写入：%s" % path,
					"journal": log_path, "targets": receipts}
			if st == "dropped":
				# 绑定复核丢弃：不写盘、不回填日志（R02），提交继续。
				# 收据仍要有一条——「计划里有、但故意没写」必须能让调用方看见。
				receipts.append(_receipt_of(tgt, "dropped", ""))
				continue
			ok = true
			written.append("content")
		elif tgt.has("map_data"):
			# §4.4-4：地图文档目标（未落盘改名落盘等）——走 MapStore.write 的同一入口：
			# 写前校验 + 历史快照 + 缓存失效都在那里，不在这里裸写字节。
			# create-only 由 target_absent 表达（新图首次落盘不允许覆盖同名别人的图）。
			if bool(tgt.get("target_absent", false)) and FileAccess.file_exists(path):
				receipts.append(_receipt_of(tgt, "conflict", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "conflict", "written": written, "conflicts": [{"path": path,
					"kind": kind, "message": "目标地图文件在提交期间被创建：%s" % path}],
					"receipt": {}, "journal": log_path, "targets": receipts}
			var md: Dictionary = tgt.get("map_data", {}) if tgt.get("map_data", null) is Dictionary else {}
			var MS := load("res://src/map/map_store.gd")
			ok = not md.is_empty() and MS.write(m, str(tgt.get("id", "")), md)
			if ok:
				written.append(kind)
		elif tgt.has("frozen_text"):
			# §4.4-4：冻结字节目标（改名 / 整图复制 / 跨图清理）——prepare 时序列化好，
			# apply 只按计划写，不回读画布或磁盘。create-only（target_absent）在写前复验。
			if bool(tgt.get("target_absent", false)) and FileAccess.file_exists(path):
				receipts.append(_receipt_of(tgt, "conflict", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "conflict", "written": written, "conflicts": [{"path": path,
					"kind": kind, "message": "目标文件在提交期间被创建：%s" % path}],
					"receipt": {}, "journal": log_path, "targets": receipts}
			var fbase := str(tgt.get("baseline", ""))
			if not bool(tgt.get("target_absent", false)) and fbase != "" \
					and FileAccess.file_exists(path) and Recovery.digest(path) != fbase:
				receipts.append(_receipt_of(tgt, "conflict", ""))
				receipts.append_array(_receipts_pending(targets, path))
				return {"status": "conflict", "written": written, "conflicts": [{"path": path,
					"kind": kind, "message": "目标文件在提交期间被外部改动：%s" % path}],
					"receipt": {}, "journal": log_path, "targets": receipts}
			ok = str(tgt.get("frozen_text", "")) != "" \
				and Recovery.write_text(path, str(tgt.get("frozen_text", "")))
			if ok:
				written.append(kind)
		elif kind == "map":
			ok = await hooks.save_map.call()
			if ok:
				written.append("map")
		if not ok:
			# 写失败/取消：日志保留（下次启动 scan_pending 判 written/pending/manual）
			receipts.append(_receipt_of(tgt, "failed", ""))
			receipts.append_array(_receipts_pending(targets, path))
			return {"status": "cancelled" if kind == "manifest" else "failed",
				"written": written, "conflicts": [],
				"error": "清单补码保存被取消或失败" if kind == "manifest" else "地图保存失败",
				"journal": log_path, "targets": receipts}
		# 逐文件记录进度（R04）：写成功即回填实际结果摘要。
		# 回填失败 = 日志已不可判读（被外部删/改）：**停在已写状态**，不再往下写，
		# 让下次启动 scan_pending 按「文件摘要 vs 预期」重新判定（§7.1 阶段一）。
		var dig := Recovery.digest(path)
		if not Recovery.mark_pending_written(m, log_path, targets.find(tgt), dig):
			receipts.append(_receipt_of(tgt, "written", dig))
			receipts.append_array(_receipts_pending(targets, path))
			return {"status": "failed", "written": written, "conflicts": [],
				"error": "提交日志进度回填失败：已写文件保留，其后目标未写（日志已留在 editor/pending 供复核）",
				"journal": log_path, "targets": receipts}
		receipts.append(_receipt_of(tgt, "written", dig))
	Recovery.clear_pending(m, log_path)
	if written.has("map"):
		for t3 in targets:
			if str((t3 as Dictionary).get("kind", "")) == "map":
				receipt = {"map_code": str(plan.get("map_code", "")),
					"absolute_path": str((t3 as Dictionary).get("path", "")),
					"map_digest": Recovery.digest(str((t3 as Dictionary).get("path", "")))}
	return {"status": "ok", "written": written, "conflicts": conflicts,
		"receipt": receipt, "targets": receipts}

## §4.4-4：非「清单→内容→地图」入口的计划构造（改名 / 整图复制 / 跨图清理）。
## targets 每项 = {path, kind, id, baseline?, expect_absent?, frozen_text?, op?}；
## prepare 会把 baseline 按**此刻磁盘**重算（调用方只给「要写什么、「预期不存在」或「要删」」），
## 之后 apply 按冻结计划执行、逐目标给收据——与常规提交同一套日志与复验口径。
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
			expect = JSON.stringify(row.map_data, "\t").sha256_text()
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
		if op == "rename":
			var from := str(tgt.get("from", ""))
			var rbase := str(tgt.get("baseline", ""))
			if not _matches_file(from, false, rbase) or not _matches_file(path, true, ""):
				return _frozen_conflict(tgt, targets, receipts, log_path,
					"改名源或目标已变化：%s → %s" % [from, path])
			if DirAccess.rename_absolute(from, path) != OK:
				return _frozen_fail(tgt, targets, receipts, written, log_path,
					"文件系统重命名失败：%s → %s" % [from, path])
			written.append(kind)
			if not _frozen_mark(tgt, targets, receipts, written, m, log_path, path):
				return _frozen_log_fail(targets, receipts, written, log_path, path)
			continue
		if op == "delete":
			var del_base := str(tgt.get("baseline", ""))
			if not _matches_file(path, false, del_base):
				return _frozen_conflict(tgt, targets, receipts, log_path,
					"待删除目标已变化：%s" % path)
			if DirAccess.remove_absolute(path) != OK:
				return _frozen_fail(tgt, targets, receipts, written, log_path, "删除失败：%s" % path)
			written.append(kind)
			receipts.append(_receipt_of(tgt, "deleted", ""))
			if not Recovery.mark_pending_written(m, log_path, targets.find(tgt), ""):
				return _frozen_log_fail(targets, receipts, written, log_path, path)
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
			if not _frozen_mark(tgt, targets, receipts, written, m, log_path, p):
				return _frozen_log_fail(targets, receipts, written, log_path, p)
			continue
		# 冻结字节目标（地图文档等）
		if tgt.has("map_data"):
			var md: Dictionary = tgt.get("map_data", {}) if tgt.get("map_data", null) is Dictionary else {}
			var MS := load("res://src/map/map_store.gd")
			if str(MS.path_for(m, str(tgt.get("id", "")))) != path or md.is_empty() \
					or not MS.write(m, str(tgt.get("id", "")), md):
				return _frozen_fail(tgt, targets, receipts, written, log_path,
					"地图写盘失败（写前校验不过或目标不可写）：%s" % path)
			written.append(kind)
			if not _frozen_mark(tgt, targets, receipts, written, m, log_path, path):
				return _frozen_log_fail(targets, receipts, written, log_path, path)
			continue
		if str(tgt.get("frozen_text", "")) == "":
			return _frozen_fail(tgt, targets, receipts, written, log_path,
				"计划缺少冻结字节：%s" % path)
		if not Recovery.write_text(path, str(tgt.get("frozen_text", ""))):
			return _frozen_fail(tgt, targets, receipts, written, log_path, "写盘失败：%s" % path)
		written.append(kind)
		if not _frozen_mark(tgt, targets, receipts, written, m, log_path, path):
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
func _frozen_conflict(tgt: Dictionary, targets: Array, receipts: Array, log_path: String, msg: String) -> Dictionary:
	var written: Array = []
	for row in receipts:
		if row.get("status") in ["written", "deleted"]:
			written.append(row.get("kind", ""))
	receipts.append(_receipt_of(tgt, "conflict", ""))
	receipts.append_array(_receipts_pending(targets, str(tgt.get("path", ""))))
	return {"status": "conflict", "written": written, "conflicts": [{"path": str(tgt.get("path", "")),
		"kind": str(tgt.get("kind", "")), "message": msg}], "receipt": {}, "targets": receipts, "journal": log_path}

func _frozen_fail(tgt: Dictionary, targets: Array, receipts: Array, written: Array, log_path: String,
		msg: String) -> Dictionary:
	receipts.append(_receipt_of(tgt, "failed", ""))
	receipts.append_array(_receipts_pending(targets, str(tgt.get("path", ""))))
	return {"status": "failed", "written": written, "conflicts": [], "error": msg,
		"journal": log_path, "targets": receipts}

## 回填一条成功进度；false = 日志已不可判读（调用方停在已写状态）。
func _frozen_mark(tgt: Dictionary, targets: Array, receipts: Array, _written: Array,
		m: Dictionary, log_path: String, digest_path: String) -> bool:
	var dig := Recovery.digest(digest_path)
	if not Recovery.mark_pending_written(m, log_path, targets.find(tgt), dig):
		receipts.append(_receipt_of(tgt, "written", dig))
		return false
	receipts.append(_receipt_of(tgt, "written", dig))
	return true

func _frozen_log_fail(targets: Array, receipts: Array, written: Array, log_path: String, after: String) -> Dictionary:
	receipts.append_array(_receipts_pending(targets, after))
	return {"status": "failed", "written": written, "conflicts": [],
		"error": "提交日志进度回填失败：已写文件保留，其后目标未写（日志已留在 editor/pending 供复核）",
		"journal": log_path, "targets": receipts}

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
