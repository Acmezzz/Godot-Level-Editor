extends RefCounted
## 写入新地图及其内容；已落盘地图改名时最后删除旧文件。

const Recovery := preload("res://src/map/recovery.gd")
const MapFormat := preload("res://src/map/map_format.gd")

static func prepare(m: Dictionary, name_: String, data: Dictionary, contents: Array,
		old_name := "", old_digest := "") -> Dictionary:
	var maps := load("res://src/map/map_store.gd")
	var path: String = maps.path_for(m, name_)
	if path == "":
		return {"error": "地图路径非法"}
	var error: String = maps.write_error(m, data)
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
	entries.append({"path": path, "baseline": "", "expect_absent": true,
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
	var problem: String = maps.identity_error(m, plan.name, plan.data, plan.old_name)
	if problem != "":
		return {"error": problem}
	if Recovery.observe(plan.path).state != "missing":
		return {"error": "同名地图已存在或目标不可读：%s" % plan.path}
	if plan.old_path != "" and Recovery.digest(plan.old_path) != plan.old_digest:
		return {"error": "改名源文件已变化：%s" % plan.old_path}
	var log_path := Recovery.begin_pending(m, "写入地图 " + str(plan.name), plan.entries)
	if log_path == "":
		return {"error": "无法登记多文件写入"}
	var store := load("res://src/content/content_store.gd")
	var written: Array = []
	var error := ""
	for row in plan.contents:
		var result: Dictionary = store.write_ex(m, row.fn_id, row.cid, row.data,
			str(row.get("baseline", "")), false, row.get("expect_absent", true))
		if not result.ok:
			error = ("内容目标已变化：%s" if result.conflict else "内容写入失败：%s") % row.cid
			break
		written.append({"fn_id": row.fn_id, "cid": row.cid})
	if error == "":
		if Recovery.observe(plan.path).state != "missing":
			error = "地图写入目标已变化：%s" % plan.path
		elif not maps.write(m, plan.name, plan.data, plan.old_name):
			error = "地图写入失败：%s" % plan.path
		elif plan.old_path != "" and (Recovery.digest(plan.old_path) != plan.old_digest
				or DirAccess.remove_absolute(plan.old_path) != OK):
			error = "新地图已写，旧文件已变化或无法删除：%s" % plan.old_path
	if error == "":
		Recovery.clear_pending(log_path)
	return {"error": error, "written_contents": written}
