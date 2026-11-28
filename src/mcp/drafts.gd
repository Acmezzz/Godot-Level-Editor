extends RefCounted
## Project-scoped batch drafts. Each history entry is a snapshot of the changed documents.

const Recovery := preload("res://src/map/recovery.gd")
const Maps := preload("res://src/map/map_store.gd")
const Format := preload("res://src/map/map_format.gd")
const Contents := preload("res://src/content/content_store.gd")
const Commit := preload("res://src/project/document_commit.gd")
const Refs := preload("res://src/project/reference_index.gd")

var app

func _init(host: Control) -> void:
	app = host

func folder() -> String:
	return "user://mcp-drafts/" + str(app.manifest._dir).replace("\\", "/").simplify_path().sha256_text()

func path(id: String) -> String:
	return folder().path_join(id + ".json")

func read(id: String) -> Dictionary:
	return Recovery.read_json(path(id)) if Contents.is_valid_id(id) else {}

func state(draft: Dictionary) -> Dictionary:
	return draft.history[int(draft.cursor)].duplicate(true) if not draft.is_empty() else {"maps": {}, "contents": {}, "project": {}}

func info(draft: Dictionary) -> Dictionary:
	var batch: Dictionary = draft.history[int(draft.cursor)]
	return {"id": draft.id, "name": draft.name, "revision": draft.revision,
		"undo": draft.cursor > 0, "redo": draft.cursor + 1 < draft.history.size(),
		"changed": {"maps": batch.maps.keys(), "contents": batch.contents.keys(), "project": batch.project.keys()}}

func list_drafts() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for file in DirAccess.get_files_at(folder()):
		var item := read(file.get_basename())
		if not item.is_empty():
			rows.append(info(item))
	return rows

func manage(args: Dictionary) -> Dictionary:
	var action: String = args.get("action", "list")
	if action == "list":
		return {"drafts": list_drafts(), "editorRecovery": Recovery.list_drafts(app.manifest)}
	var id: String = args.get("draft", "")
	if action == "create":
		id = Crypto.new().generate_random_bytes(12).hex_encode()
		var fresh := {"id": id, "name": args.get("name", "MCP"), "revision": 0,
			"manifestDigest": app.manifest._manifest_digest, "cursor": 0, "history": [state({})]}
		return _saved(fresh)
	var draft := read(id)
	if draft.is_empty():
		return {"error": "草稿不存在：" + id}
	if action in ["open", "save", "diff"]:
		var response := info(draft)
		if action == "diff":
			response["changes"] = state(draft)
		return response
	if draft.revision != args.get("revision"):
		return {"error": "草稿版本已变化。", "current": info(draft)}
	match action:
		"discard":
			return {"discarded": id} if DirAccess.remove_absolute(path(id)) == OK else {"error": "无法移除草稿。"}
		"undo", "redo":
			var next := int(draft.cursor) + (-1 if action == "undo" else 1)
			if next < 0 or next >= draft.history.size():
				return {"error": "没有可用的历史记录。"}
			draft.cursor = next
			draft.revision += 1
			return _saved(draft)
		_:
			return {"error": "未知草稿操作。"}

func append(draft: Dictionary, batch: Dictionary) -> Dictionary:
	var history: Array = draft.history
	history.resize(int(draft.cursor) + 1)
	history.append(batch)
	draft.cursor = history.size() - 1
	draft.revision += 1
	return _saved(draft)

func _saved(draft: Dictionary) -> Dictionary:
	return info(draft) if Recovery.write_json(path(draft.id), draft) else {"error": "无法写入草稿。"}

func candidate(batch: Dictionary) -> Dictionary:
	var result: Dictionary = app.manifest.duplicate(true)
	result.merge(batch.project, true)
	if not batch.maps.is_empty():
		var overlay := {}
		for code in batch.maps:
			var row: Dictionary = batch.maps[code]
			if row.original != "":
				overlay[row.original] = {}
			if not row.get("deleted", false):
				overlay[row.name] = row.data
		result["_map_overrides"] = overlay
	if not batch.contents.is_empty():
		result["_content_overrides"] = batch.contents
	return result

func map_of(batch: Dictionary, code: String) -> Dictionary:
	if batch.maps.has(code):
		var changed: Dictionary = batch.maps[code]
		return {} if changed.get("deleted", false) else changed.duplicate(true)
	var resolved := Refs.resolve_map(app.manifest, code)
	if resolved.status != "ok":
		return {}
	var name_: String = resolved.key
	var seen := Recovery.observe(Maps.path_for(app.manifest, name_))
	var decoded := Maps.decode_text(seen.get("text", ""), name_, app.manifest)
	if not decoded.ok:
		return {}
	return {"name": name_, "original": name_, "baseline": seen.digest, "data": decoded.data}

func content_of(batch: Dictionary, fn: String, id: String) -> Dictionary:
	var key := fn + "/" + id
	if batch.contents.has(key):
		var changed: Dictionary = batch.contents[key]
		return {} if changed.get("deleted", false) else changed.duplicate(true)
	var readback := Contents.read_ex(app.manifest, fn, id)
	if readback.status != "ok":
		return {}
	return {"function": fn, "content": id, "baseline": readback.digest, "data": readback.data}

func maps_of(batch: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var seen := {}
	for entry in Refs.map_target_options(app.manifest):
		seen[entry.code] = true
		var row: Dictionary = batch.maps.get(entry.code, {})
		if not row.get("deleted", false):
			rows.append({"map": entry.code, "name": row.get("name", entry.name), "changed": not row.is_empty()})
	for code in batch.maps:
		var row: Dictionary = batch.maps[code]
		if not seen.has(code) and not row.get("deleted", false):
			rows.append({"map": code, "name": row.name, "changed": true})
	return rows

func event_drawings(batch: Dictionary, manifest: Dictionary, code: String) -> Array:
	var out := []
	for drawing in preload("res://src/project/event_layers.gd").drawings_for_map(manifest, code):
		var map := map_of(batch, drawing.map)
		if not map.is_empty():
			out.append(drawing.merged({"data": map.data}))
	return out

func plan(draft: Dictionary, batch: Dictionary) -> Dictionary:
	var manifest: Dictionary = app.manifest
	var entries := []
	var payloads := {}
	var removed := []
	var occupied_names := {}
	for code in batch.maps:
		var row: Dictionary = batch.maps[code]
		var old := Maps.path_for(manifest, row.original) if row.original != "" else ""
		if row.get("deleted", false):
			if old != "":
				removed.append({"path": old, "baseline": row.baseline, "op": "delete"})
			continue
		var target := Maps.path_for(manifest, row.name)
		var target_key := target.to_lower() if OS.get_name() == "Windows" else target
		if target == "" or occupied_names.has(target_key):
			return {"error": "地图名非法或重复：" + str(row.name)}
		occupied_names[target_key] = true
		var problem := Maps.identity_error(manifest, row.name, row.data, row.original)
		if problem != "":
			return {"error": problem}
		_put(entries, payloads, target, row.baseline if old == target else "", Format.encode(row.data))
		if old != "" and old != target:
			removed.append({"path": old, "baseline": row.baseline, "op": "delete"})
	for row in batch.contents.values():
		var target := Contents.path_for(manifest, row.function, row.content)
		if target == "":
			return {"error": "内容路径非法：" + str(row.content)}
		if row.get("deleted", false):
			if row.baseline != "":
				removed.append({"path": target, "baseline": row.baseline, "op": "delete"})
		else:
			_put(entries, payloads, target, row.baseline, JSON.stringify(row.data, "\t"))
	if not batch.project.is_empty() or manifest.has("_codes_issued"):
		var target := str(manifest._dir).path_join("editor/editor_manifest.json")
		var body: Dictionary = app._manifest_write_payload(candidate(batch))
		_put(entries, payloads, target, draft.manifestDigest, JSON.stringify(body, "\t"))
	entries.append_array(removed)
	return {"entries": entries, "payloads": payloads}

func _put(entries: Array, payloads: Dictionary, target: String, baseline: String, text: String) -> void:
	entries.append({"path": target, "baseline": baseline, "expect_absent": baseline == "", "expect": text.sha256_text()})
	payloads[target] = text

func publish(draft: Dictionary, pending: Dictionary) -> Dictionary:
	var entries: Array = pending.entries
	var preflight := check_plan(pending)
	if preflight.has("error"):
		return preflight
	if entries.is_empty():
		return {"files": [], "draft": draft.id, "revision": draft.revision}
	var receipt_path: String = preflight.log_path
	if receipt_path == "":
		receipt_path = Recovery.begin_pending(app.manifest, "MCP " + str(draft.id), entries)
	if receipt_path == "":
		return {"error": "无法登记发布。"}
	var written := []
	for entry in entries:
		var target: String = entry.path
		if not preflight.done.has(target):
			if not Commit.can_write(Recovery.observe(target), entry.baseline, entry.get("expect_absent", false)):
				return {"error": "写入目标已变化：" + target, "files": written, "pending": receipt_path}
			var remove: bool = entry.get("op") == "delete"
			if entry.baseline != "" and not Maps.rotate_history(target) and remove:
				return {"error": "无法保留删除前的历史：" + target, "files": written, "pending": receipt_path}
			var ok := DirAccess.remove_absolute(target) == OK if remove else Maps.write_text(target, pending.payloads[target])
			if not ok:
				return {"error": "发布未完成：" + target, "files": written, "pending": receipt_path}
		written.append(target)
	Recovery.clear_pending(receipt_path)
	Maps.refresh_external_maps()
	var published_revision: int = int(draft.revision)
	draft.history = [state({})]
	draft.cursor = 0
	draft.revision += 1
	draft.manifestDigest = Recovery.digest(str(app.manifest._dir).path_join("editor/editor_manifest.json"))
	var result := _saved(draft)
	return result.merged({"files": written, "publishedRevision": published_revision}, true)

func check_plan(pending: Dictionary) -> Dictionary:
	var plan_ := {"entries": pending.entries, "log_path": ""}
	for receipt in Recovery.scan_pending(app.manifest):
		if receipt.data.get("entries") == pending.entries:
			plan_["log_path"] = receipt.path
			break
	var manifest_path := str(app.manifest._dir).path_join("editor/editor_manifest.json")
	if not pending.entries.any(func(entry): return entry.path == manifest_path) \
			and Recovery.digest(manifest_path) != app.manifest._manifest_digest:
		return {"error": "游戏清单已从外部修改，请重新打开工程后再发布。"}
	return Commit.preflight(plan_).merged({"log_path": plan_.log_path})
