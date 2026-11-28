extends RefCounted
## 预检并发布地图和暂存内容；改名时最后删除旧文件。

const Recovery := preload("res://src/map/recovery.gd")
const MapFormat := preload("res://src/map/map_format.gd")

static func prepare(m: Dictionary, name_: String, data: Dictionary, contents: Array,
		old_name := "", old_digest := "", map_baseline := "") -> Dictionary:
	var maps := load("res://src/map/map_store.gd")
	var path: String = maps.path_for(m, name_) if name_ != "" else ""
	if name_ != "" and path == "":
		return {"error": "地图路径非法"}
	var error: String = maps.write_error(m, data) if path != "" else ""
	if error != "":
		return {"error": error}
	var store := load("res://src/content/content_store.gd")
	var entries: Array = []
	for row in contents:
		var content_path: String = store.path_for(m, row.fn_id, row.cid)
		var baseline := str(row.get("baseline", ""))
		if content_path == "" or (not row.get("expect_absent", true) and baseline == ""):
			return {"error": "内容目标或替换基线非法：%s" % row.cid}
		var payload: Dictionary = row.data.duplicate(true)
		payload["id"] = row.cid
		entries.append({"path": content_path, "baseline": baseline, "expect_absent": row.get("expect_absent", true),
			"expect": JSON.stringify(payload, "\t").sha256_text()})
	if path != "":
		entries.append({"path": path, "baseline": map_baseline, "expect_absent": map_baseline == "",
			"expect": MapFormat.encode(data).sha256_text()})
	var old_path: String = maps.path_for(m, old_name) if old_name != "" else ""
	if old_name != "":
		if old_path == "" or old_digest == "":
			return {"error": "缺少改名源文件或摘要"}
		entries.append({"path": old_path, "baseline": old_digest, "op": "delete"})
	return {"plan": {"manifest": m, "name": name_, "data": data.duplicate(true), "path": path,
		"contents": contents.duplicate(true), "entries": entries, "old_name": old_name,
		"old_path": old_path, "old_digest": old_digest}}

static func apply(plan: Dictionary) -> Dictionary:
	var m: Dictionary = plan.manifest
	var maps := load("res://src/map/map_store.gd")
	var problem: String = maps.identity_error(m, plan.name, plan.data, plan.old_name) if plan.path != "" else ""
	if problem != "":
		return {"error": problem, "written_contents": []}
	var log_path := str(plan.get("log_path", ""))
	var checked := preflight(plan)
	if checked.has("error"):
		return {"error": checked.error, "written_contents": []}
	var store := load("res://src/content/content_store.gd")
	var content_by_path := {}
	for row in plan.contents:
		content_by_path[store.path_for(m, row.fn_id, row.cid)] = row
	var writer := func(entry: Dictionary) -> String:
		if content_by_path.has(entry.path):
			var row: Dictionary = content_by_path[entry.path]
			var saved: Dictionary = store.write_ex(m, row.fn_id, row.cid, row.data,
				str(row.get("baseline", "")), false, row.get("expect_absent", true))
			return "" if saved.ok else ("内容目标已变化：%s" if saved.conflict else "内容写入失败：%s") % row.cid
		if entry.get("op") == "delete":
			return "" if DirAccess.remove_absolute(entry.path) == OK else "新地图已写，无法删除旧文件：%s" % entry.path
		return "" if maps.write(m, plan.name, plan.data, plan.old_name) else "地图写入失败：%s" % entry.path
	var result := apply_files(m, plan, checked.merged({"log_path": log_path}),
		"写入地图 " + str(plan.name), {}, writer, plan.get("prior_log", ""), plan.entries.size() > 1)
	var written := []
	for path in result.get("files", []):
		if content_by_path.has(path):
			var row: Dictionary = content_by_path[path]
			written.append({"fn_id": row.fn_id, "cid": row.cid})
	var error: String = result.get("error", "")
	if error == "":
		Recovery.clear_pending(result.pending)
		Recovery.clear_pending(plan.get("prior_log", ""))
		plan.erase("log_path")
		maps.invalidate_code_map()
	elif result.get("pending", "") != "":
		plan["log_path"] = result.pending
	return {"error": error, "written_contents": written}

## Apply an already checked file plan. Domain writers keep their own serialization/repair rules.
static func apply_files(m: Dictionary, plan: Dictionary, checked: Dictionary, reason: String,
		context := {}, writer := Callable(), prior_log := "", require_receipt := true) -> Dictionary:
	var log_path: String = checked.log_path
	if log_path == "" and require_receipt:
		log_path = Recovery.begin_pending(m, reason, plan.entries, context)
		if log_path == "":
			return {"error": "无法登记发布。"}
		Recovery.clear_pending(prior_log)
	var written := []
	for entry in plan.entries:
		var target: String = entry.path
		if not checked.done.has(target):
			var error := ""
			if not can_write(Recovery.observe(target), entry.baseline, entry.get("expect_absent", false)):
				error = "写入目标已变化：" + target
			elif writer.is_valid():
				error = writer.call(entry)
			else:
				error = _write_payload(entry, plan.payloads)
			if error != "":
				return {"error": error, "files": written, "pending": log_path}
		written.append(target)
	return {"files": written, "pending": log_path}

static func _write_payload(entry: Dictionary, payloads: Dictionary) -> String:
	var maps := load("res://src/map/map_store.gd")
	var target: String = entry.path
	var remove: bool = entry.get("op") == "delete"
	if entry.baseline != "" and not maps.rotate_history(target) and remove:
		return "无法保留删除前的历史：" + target
	var ok: bool
	if remove:
		ok = DirAccess.remove_absolute(target) == OK
	elif entry.has("case_from"):
		ok = maps.write_case_rename(entry.case_from, target, payloads[target]) == ""
	else:
		ok = maps.write_text(target, payloads[target])
	return "" if ok else "发布未完成：" + target

static func recover_log(plan: Dictionary) -> void:
	var logs := Recovery.scan_pending(plan.manifest)
	logs.reverse()
	for receipt in logs:
		if receipt.data.get("entries", []) == plan.entries:
			plan["log_path"] = receipt.path
			return
		if plan.path == "" or plan.old_path != "":
			continue
		# A revised map can resume its content writes, but only against proven receipts.
		var current_map: Dictionary = plan.entries.back()
		if not receipt.entries.any(func(entry):
			return entry.path == plan.path and entry.get("op", "write") == "write" \
				and entry.baseline == current_map.baseline):
			continue
		var received := {}
		var resumed := false
		for entry in receipt.entries:
			if entry.path != plan.path and (entry.state == "written" \
					or (entry.state == "pending" and entry.has("original_baseline"))):
				received[entry.path] = entry
		for i in plan.contents.size():
			var row: Dictionary = plan.contents[i]
			var entry: Dictionary = plan.entries[i]
			var prior: Dictionary = received.get(entry.path, {})
			if prior.is_empty() or entry.baseline not in [prior.baseline, prior.expect, prior.get("original_baseline", prior.baseline)]:
				continue
			resumed = true
			var digest: String = prior.expect if prior.state == "written" else prior.baseline
			entry["original_baseline"] = prior.get("original_baseline", prior.baseline)
			entry["baseline"] = digest
			entry["expect_absent"] = false
			row["baseline"] = digest
			row["expect_absent"] = false
		if resumed:
			plan["prior_log"] = receipt.path
			return

static func preflight(plan: Dictionary) -> Dictionary:
	var log_path := str(plan.get("log_path", ""))
	var done := {}
	var entries_by_path := {}
	for entry in plan.entries:
		entries_by_path[entry.path] = entry
		var observed := Recovery.observe(entry.path)
		var digest: String = observed.get("digest", "")
		if (digest == entry.get("expect", "!") and (log_path != "" or digest == entry.get("baseline", ""))) \
				or (log_path != "" and entry.get("op") == "delete" and observed.state == "missing"):
			done[entry.path] = true
		elif not can_write(observed, entry.get("baseline", ""), entry.get("expect_absent", false)):
			return {"error": "写入目标已变化：%s" % entry.path}
	return {"done": done, "entries_by_path": entries_by_path}

static func can_write(observed: Dictionary, baseline: String, expect_absent: bool) -> bool:
	if expect_absent:
		return observed.state == "missing"
	return observed.state == "present" and observed.digest == baseline
