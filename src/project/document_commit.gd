extends RefCounted
## DocumentCommit（§7.1）：提交编排。prepare 冻结 Plan（{token, revision, operation, targets}）；
## apply 按依赖序执行：persist_journal 先于第一次替换 → 逐目标写前复验 → 写入即历史保留
## （MapStore/ContentStore 自带）→ 逐文件记录进度（提交日志）。清单与地图的实际写入是
## UI 侧职责（外部改动确认对话框），经 hooks 协程注入；内容写入在本模块内直接走 ContentStore。
## **一次操作写哪些文件的唯一定义**在 docs/EDITOR_FEATURES.md §7.3「各入口提交哪些文件」；
## 本模块只实现其中「清单 → 内容 → 地图」这一条的编排，不另行维护文件清单。

const Recovery := preload("res://src/map/recovery.gd")
const ContentStore := preload("res://src/content/content_store.gd")

## prepare：按快照 + 磁盘基线冻结 Plan（只读盘点：无 UI 副作用，R28 口径）。
## operation = {reason, manifest, map_name, map_path, map_digest, map_dirty}
func prepare(operation: Dictionary, snap: Dictionary) -> Dictionary:
	var m: Dictionary = operation.get("manifest", {})
	var targets: Array = []
	# 1) 清单补码（内容/地图引用它们之前必须落盘：依赖序第一）
	if bool((snap.get("manifest_changes", {}) as Dictionary).get("codes_pending", false)):
		var mpath := str(m.get("_dir", "")).path_join("editor/editor_manifest.json")
		targets.append({"op": "write", "kind": "manifest", "id": "",
			"path": mpath, "baseline": Recovery.digest(mpath), "expected": ""})
	# 2) 内容目标：prepare 时抓基线摘要，apply 逐条写前复验（§7.1 accepted_state）
	#    V4 P0-1：新内容的目标必须声明「预期不存在」——不能只靠空摘要表达，
	#    否则提交期间出现的同路径文件会被当成合法基线并被覆盖。
	for row in (snap.get("contents", []) as Array):
		var r: Dictionary = row
		var cp := ContentStore.path_for(m, str(r.get("fn_id", "")), str(r.get("cid", "")))
		var exists := FileAccess.file_exists(cp)
		targets.append({"op": "write", "kind": "content", "id": str(r.get("cid", "")),
			"path": cp, "baseline": Recovery.digest(cp) if exists else "", "expected": "",
			"expect_absent": not exists,
			"payload": {"fn_id": str(r.get("fn_id", "")), "cid": str(r.get("cid", "")),
				"data": r.get("data", {}), "expect_absent": not exists}})
	# 3) 地图（只脏图入计划：干净图没有待写项；写前外部改动确认在 hooks.save_map 里）
	if bool(operation.get("map_dirty", false)) and str(operation.get("map_path", "")) != "":
		targets.append({"op": "write", "kind": "map", "id": str(operation.get("map_name", "")),
			"path": str(operation.get("map_path", "")), "baseline": str(operation.get("map_digest", "")), "expected": ""})
	if targets.is_empty():
		return {"status": "empty"}
	return {"status": "ok", "plan": {"token": str(snap.get("token", "")), "revision": int(snap.get("revision", 0)),
		"operation": str(operation.get("reason", "")), "manifest": m, "map_code": str(snap.get("map", "")),
		"targets": targets}}

## apply：执行冻结 Plan。hooks（全部 Callable）：
##   save_manifest() -> bool（协程；清单写盘含外部改动确认）
##   save_map() -> bool（协程；地图写盘含外部改动确认）
##   flush_one(cid) -> {status: ok|dropped|failed}（单条暂存内容：绑定复核 + 写盘 + 丢弃登记）
## 逐目标写前复验只对内容目标做（清单/地图的外部改动由各自 hook 的确认 UI 处理）；
## 复验不符 → conflict 停，提交日志保留（§7.1 stop_with_conflict）。
func apply(plan: Dictionary, hooks: Dictionary) -> Dictionary:
	var m: Dictionary = plan.get("manifest", {})
	var targets: Array = plan.get("targets", [])
	var written: Array = []
	var conflicts: Array = []
	var receipt := {}
	if targets.is_empty():
		return {"status": "ok", "written": [], "conflicts": [], "receipt": {}}
	var journal: Array = []
	for t in targets:
		var tj: Dictionary = t
		journal.append({"path": str(tj.get("path", "")), "baseline": str(tj.get("baseline", "")),
			"expect": "", "kind": str(tj.get("kind", "")), "id": str(tj.get("id", ""))})
	var log_path := Recovery.begin_pending(m, str(plan.get("operation", "")), journal)
	if log_path == "":
		return {"status": "failed", "written": written, "conflicts": [],
			"error": "提交日志写入失败：已中止（未写任何文件）"}
	for t2 in targets:
		var tgt: Dictionary = t2
		var kind := str(tgt.get("kind", ""))
		var path := str(tgt.get("path", ""))
		if kind == "content":
			# §7.1 accepted_state：写前复验磁盘状态与 prepare 基线一致。
			# 计划里「预期不存在」的新内容：文件在提交期间被别的写入方创建 → 冲突停，
			# 绝不用暂存加载覆盖刚出现的正式文件。
			var exists_now := FileAccess.file_exists(path)
			var conflict := false
			if bool(tgt.get("expect_absent", false)):
				conflict = exists_now
			elif not exists_now:
				# 计划时存在的目标在提交期间消失：不能按新文件静默重建（原内容已不由本计划拥有）
				conflict = str(tgt.get("baseline", "")) != ""
			else:
				conflict = Recovery.digest(path) != str(tgt.get("baseline", ""))
			if conflict:
				conflicts.append({"path": path, "kind": kind,
					"message": "内容文件在提交期间被外部改动：%s" % path})
				return {"status": "conflict", "written": written, "conflicts": conflicts,
					"receipt": {}, "journal": log_path}
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
				return {"status": "failed", "written": written, "conflicts": [],
					"error": "暂存内容写盘失败：%s" % str(tgt.get("id", "")), "journal": log_path}
			if st == "conflict":
				return {"status": "conflict", "written": written, "conflicts": [{"path": path,
					"kind": kind, "message": "内容目标在提交期间被创建或改动：%s" % path}],
					"receipt": {}, "journal": log_path}
			if st == "dropped":
				continue   # 绑定复核丢弃：不写盘、不回填日志（R02），提交继续
			ok = true
			written.append("content")
		elif kind == "map":
			ok = await hooks.save_map.call()
			if ok:
				written.append("map")
		if not ok:
			# 写失败/取消：日志保留（下次启动 scan_pending 判 written/pending/manual）
			return {"status": "cancelled" if kind == "manifest" else "failed",
				"written": written, "conflicts": [],
				"error": "清单补码保存被取消或失败" if kind == "manifest" else "地图保存失败"}
		# 逐文件记录进度（R04）：写成功即回填实际结果摘要。
		# 回填失败 = 日志已不可判读（被外部删/改）：**停在已写状态**，不再往下写，
		# 让下次启动 scan_pending 按「文件摘要 vs 预期」重新判定（§7.1 阶段一）。
		if not Recovery.mark_pending_written(m, log_path, targets.find(tgt), Recovery.digest(path)):
			return {"status": "failed", "written": written, "conflicts": [],
				"error": "提交日志进度回填失败：已写文件保留，其后目标未写（日志已留在 editor/pending 供复核）"}
	Recovery.clear_pending(m, log_path)
	if written.has("map"):
		for t3 in targets:
			if str((t3 as Dictionary).get("kind", "")) == "map":
				receipt = {"map_code": str(plan.get("map_code", "")),
					"absolute_path": str((t3 as Dictionary).get("path", "")),
					"map_digest": Recovery.digest(str((t3 as Dictionary).get("path", "")))}
	return {"status": "ok", "written": written, "conflicts": conflicts, "receipt": receipt}
