extends RefCounted
## Project-scoped draft headers point to independently readable revision snapshots.

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
	if draft.is_empty():
		return {"maps": {}, "contents": {}, "project": {}}
	if draft.has("history"):
		return draft.history[int(draft.cursor)].duplicate(true)
	var snapshot := _snapshot(draft)
	if not snapshot.get("documents") is Dictionary:
		return snapshot
	var batch := state({})
	for domain in batch:
		for key in snapshot.documents[domain]:
			var body := Recovery.read_json(_body_path(draft.id, snapshot.documents[domain][key]))
			if not body.has("value"):
				return {}
			batch[domain][key] = body.value
	return batch

func info(draft: Dictionary) -> Dictionary:
	var changed: Dictionary = draft.changed if draft.has("changed") else _changed(state(draft))
	return {"id": draft.id, "name": draft.name, "revision": draft.revision,
		"undo": draft.cursor > 0, "redo": draft.cursor + 1 < (draft.history if draft.has("history") else draft.snapshots).size(),
		"changed": changed}

static func shallow_batch(batch: Dictionary) -> Dictionary:
	return {"maps": batch.maps.duplicate(), "contents": batch.contents.duplicate(), "project": batch.project.duplicate()}

static func _changed(batch: Dictionary) -> Dictionary:
	return {"maps": batch.maps.keys(), "contents": batch.contents.keys(), "project": batch.project.keys()}

func _snapshot_path(id: String, revision: String) -> String:
	return folder().path_join(id).path_join(revision + ".json")

func _snapshot(draft: Dictionary) -> Dictionary:
	return Recovery.read_json(_snapshot_path(draft.id, draft.snapshots[int(draft.cursor)]))

func _body_path(id: String, key: String) -> String:
	return folder().path_join(id).path_join("body-" + key + ".json")

func _collect_bodies(draft: Dictionary) -> void:
	var reachable := {}
	for revision in draft.get("snapshots", []):
		var snapshot := Recovery.read_json(_snapshot_path(draft.id, revision))
		if snapshot.is_empty():
			return
		for domain in snapshot.get("documents", {}).values():
			for key in domain.values():
				reachable["body-" + key + ".json"] = true
	var dir := folder().path_join(draft.id)
	for file in DirAccess.get_files_at(dir):
		if file.begins_with("body-") and not reachable.has(file):
			DirAccess.remove_absolute(dir.path_join(file))

func _remove_snapshots(id: String, revisions: Array) -> void:
	for revision in revisions:
		DirAccess.remove_absolute(_snapshot_path(id, revision))

func _split_legacy(draft: Dictionary) -> bool:
	if not draft.has("history"):
		return true
	var keys := []
	for i in draft.history.size():
		var key := "legacy-%d" % i
		if not Recovery.write_json(_snapshot_path(draft.id, key), draft.history[i]):
			return false
		keys.append(key)
	draft.erase("history")
	draft["snapshots"] = keys
	return true

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
			"manifestDigest": app.manifest._manifest_digest, "cursor": 0, "snapshots": []}
		return _save_snapshot(fresh, state({}))
	var draft := read(id)
	if draft.is_empty():
		return {"error": "草稿不存在：" + id}
	if action in ["open", "save", "diff"]:
		var response := info(draft)
		if action == "diff":
			var batch := state(draft)
			if batch.is_empty():
				return {"error": "草稿的当前版本不可读。"}
			response["changes"] = batch
			response["summary"] = difference(batch, draft.manifestDigest)
			if args.get("summaryOnly", false):
				response.erase("changes")
		return response
	if draft.revision != args.get("revision"):
		return {"error": "草稿版本已变化。", "current": info(draft)}
	if not completed_publish(draft).is_empty():
		return {"error": "正式文件已发布，请用当前版本重试 publish 完成草稿整理。", "published": true}
	match action:
		"discard":
			if DirAccess.remove_absolute(path(id)) != OK:
				return {"error": "无法移除草稿。"}
			_remove_snapshots(id, draft.get("snapshots", []))
			_collect_bodies({"id": id})
			DirAccess.remove_absolute(folder().path_join(id))
			return {"discarded": id}
		"undo", "redo":
			var next := int(draft.cursor) + (-1 if action == "undo" else 1)
			if next < 0 or next >= (draft.history if draft.has("history") else draft.snapshots).size():
				return {"error": "没有可用的历史记录。"}
			if not _split_legacy(draft):
				return {"error": "无法拆分旧草稿的历史记录。"}
			draft.cursor = next
			draft.revision += 1
			return _saved(draft, state(draft))
		_:
			return {"error": "未知草稿操作。"}

func difference(batch: Dictionary, manifest_digest: String) -> Array:
	var result := []
	for code in batch.maps:
		var row: Dictionary = batch.maps[code]
		var previous := Recovery.observe(Maps.path_for(app.manifest, row.original)) if row.original != "" else {}
		var matches: bool = previous.get("digest", "") == row.baseline
		var decoded := Maps.decode_text(previous.text, row.original, app.manifest) if matches and row.original != "" else {}
		_diff_document(result, {"kind": "map", "id": code, "name": row.name}, decoded.get("data", {}), row, matches)
	for key in batch.contents:
		var row: Dictionary = batch.contents[key]
		var previous := Contents.read_ex(app.manifest, row.function, row.content)
		var matches: bool = previous.get("digest", "") == row.baseline
		_diff_document(result, {"kind": "content", "id": row.content, "function": row.function}, previous.get("data", {}), row, matches)
	var project_matches: bool = batch.project.is_empty() or (app.manifest._manifest_digest == manifest_digest \
		and Recovery.digest(str(app.manifest._dir).path_join("editor/editor_manifest.json")) == manifest_digest)
	for key in batch.project:
		var fields := []
		if project_matches:
			_field_diff(app.manifest.get(key), batch.project[key], key, fields)
		result.append({"kind": "project", "id": key, "operation": "update", "fields": fields, "baselineConflict": not project_matches})
	return result

static func _diff_document(result: Array, label: Dictionary, previous: Dictionary, row: Dictionary, matches: bool) -> void:
	var fields := []
	var operation := "delete" if row.get("deleted", false) else ("create" if row.get("baseline", "") == "" else "update")
	if operation == "update" and matches:
		_field_diff(previous, row.data, "", fields)
	result.append(label.merged({"operation": operation, "fields": fields, "baselineConflict": not matches}))

static func _field_diff(before: Variant, after: Variant, field: String, changes: Array) -> void:
	if before == after:
		return
	if before is Dictionary and after is Dictionary:
		var keys: Dictionary = before.duplicate()
		keys.merge(after)
		for key in keys:
			_field_diff(before.get(key), after.get(key), str(key) if field == "" else field + "." + str(key), changes)
	elif before is Array and after is Array and before.size() == after.size() and before.size() <= 256:
		for i in before.size():
			_field_diff(before[i], after[i], "%s[%d]" % [field, i], changes)
	else:
		changes.append({"path": field, "before": _diff_value(before), "after": _diff_value(after)})

static func _diff_value(value: Variant) -> Variant:
	if (value is Array or value is Dictionary) and value.size() > 12:
		return {"count": value.size(), "sample": value.slice(0, 5) if value is Array else value.keys().slice(0, 5)}
	return value

func append(draft: Dictionary, batch: Dictionary, previous := {}) -> Dictionary:
	if not _split_legacy(draft):
		return {"error": "无法拆分旧草稿的历史记录。"}
	var refs: Dictionary = _snapshot(draft).get("documents", {})
	var discarded: Array = draft.snapshots.slice(int(draft.cursor) + 1)
	draft.snapshots.resize(int(draft.cursor) + 1)
	draft.revision += 1
	var result := _save_snapshot(draft, batch, refs, previous)
	if not result.has("error") and not discarded.is_empty():
		_remove_snapshots(draft.id, discarded)
		_collect_bodies(draft)
	return result

func _save_snapshot(draft: Dictionary, batch: Dictionary, refs := {}, previous := {}) -> Dictionary:
	var key := str(int(draft.revision))
	var documents := {}
	for domain in batch:
		var index := {}
		var old: Dictionary = previous.get(domain, {})
		var prior_paths: Dictionary = refs.get(domain, {})
		for id in batch[domain]:
			var value = batch[domain][id]
			if prior_paths.has(id) and old.has(id) and (is_same(old[id], value) or old[id] == value):
				index[id] = prior_paths[id]
				continue
			var text := JSON.stringify({"value": value}, "\t")
			var digest := text.sha256_text()
			var target := _body_path(draft.id, digest)
			if not FileAccess.file_exists(target) and not Recovery.write_text(target, text):
				return {"error": "无法写入草稿文档：%s/%s" % [domain, id]}
			index[id] = digest
		documents[domain] = index
	if not Recovery.write_json(_snapshot_path(draft.id, key), {"documents": documents}):
		return {"error": "无法写入草稿版本。"}
	draft.snapshots.append(key)
	draft.cursor = draft.snapshots.size() - 1
	return _saved(draft, batch)

func _saved(draft: Dictionary, batch: Dictionary) -> Dictionary:
	if batch.is_empty():
		return {"error": "草稿版本不可读。"}
	draft["changed"] = _changed(batch)
	return info(draft) if Recovery.write_json(path(draft.id), draft) else {"error": "无法写入草稿。"}

func candidate(batch: Dictionary) -> Dictionary:
	var result: Dictionary = app.manifest.duplicate(true)
	result.merge(batch.project.duplicate(true), true)
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
	var by_code: Dictionary = Maps.code_index(manifest).by_code
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
		var problem := Maps.identity_error_in(by_code, row.name, row.data, row.original)
		if problem != "":
			return {"error": problem}
		var case_rename := Maps.is_case_only_rename(old, target)
		Commit.add_write(entries, payloads, target, row.baseline if old == target or case_rename else "", Format.encode(row.data))
		if case_rename:
			entries.back()["case_from"] = old
		elif old != "" and old != target:
			removed.append({"path": old, "baseline": row.baseline, "op": "delete"})
	for row in batch.contents.values():
		var target := Contents.path_for(manifest, row.function, row.content)
		if target == "":
			return {"error": "内容路径非法：" + str(row.content)}
		if row.get("deleted", false):
			if row.baseline != "":
				removed.append({"path": target, "baseline": row.baseline, "op": "delete"})
		else:
			Commit.add_write(entries, payloads, target, row.baseline, Contents.encode(row.content, row.data))
	if not batch.project.is_empty() or manifest.has("_codes_issued"):
		var target := str(manifest._dir).path_join("editor/editor_manifest.json")
		var body: Dictionary = EditorManifest.public_data(candidate(batch))
		Commit.add_write(entries, payloads, target, draft.manifestDigest, JSON.stringify(body, "\t"))
	entries.append_array(removed)
	return {"entries": entries, "payloads": payloads}

func publish(draft: Dictionary, pending: Dictionary, preflight := {}) -> Dictionary:
	if preflight.is_empty():
		preflight = check_plan(pending)
	if preflight.has("error"):
		return preflight
	if pending.entries.is_empty():
		return {"files": [], "draft": draft.id, "revision": draft.revision}
	var result := Commit.apply_files(app.manifest, pending, preflight, "MCP " + str(draft.id),
		{"draft": draft.id, "revision": draft.revision})
	if result.has("error"):
		return result
	return finish_publish(draft, result.files, result.pending)

func completed_publish(draft: Dictionary) -> Dictionary:
	for receipt in Recovery.scan_pending(app.manifest):
		if receipt.data.get("draft") == draft.id and receipt.data.get("revision") == draft.revision and receipt.status == "done":
			return {"files": receipt.entries.map(func(entry): return entry.path), "pending": receipt.path}
	return {}

func finish_publish(draft: Dictionary, files: Array, receipt_path: String) -> Dictionary:
	Maps.refresh_external_maps()
	var published := {"files": files, "published": true, "publishedRevision": int(draft.revision), "draft": draft.id}
	var next := draft.duplicate()
	next.erase("history")
	next["snapshots"] = []
	next["lastPublish"] = published.merged({"pending": receipt_path})
	next.revision += 1
	next.manifestDigest = Recovery.digest(str(app.manifest._dir).path_join("editor/editor_manifest.json"))
	var result := _save_snapshot(next, state({}))
	if result.has("error"):
		return published.merged({"revision": draft.revision, "cleanupPending": true, "warning": result.error})
	_remove_snapshots(draft.id, draft.get("snapshots", []))
	_collect_bodies(next)
	Recovery.clear_pending(receipt_path)
	return result.merged(published)

func last_publish(draft: Dictionary) -> Dictionary:
	var result: Dictionary = draft.lastPublish.duplicate()
	Recovery.clear_pending(result.pending)
	result.erase("pending")
	return info(draft).merged(result)

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
