extends RefCounted

const Drafts := preload("res://src/mcp/drafts.gd")
const Edits := preload("res://src/mcp/edits.gd")
const Media := preload("res://src/mcp/media.gd")
const ProjectCheck := preload("res://src/project/project_data_check.gd")
const Refs := preload("res://src/project/reference_index.gd")
const Usage := preload("res://src/project/reference_usage.gd")
const Spatial := preload("res://src/project/spatial_reference_check.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")
const Maps := preload("res://src/map/map_store.gd")
const Contents := preload("res://src/content/content_store.gd")
const Recovery := preload("res://src/map/recovery.gd")
const Functions := preload("res://src/content/function_decl.gd")
const Fields := preload("res://src/content/ref_fields.gd")
const Targets := preload("res://src/project/startup_targets.gd")
const Timeline := preload("res://src/content/step_timeline.gd")
const Generators := preload("res://src/project/map_generators.gd")
const Runner := preload("res://src/project/game_preview.gd")
const Assets := preload("res://src/assets/asset_decl.gd")
const Catalog := preload("res://src/content/authoring_catalog.gd")
const CellGraph := preload("res://src/map/cell_graph.gd")

var app
var drafts: RefCounted
var edits: RefCounted
var media: RefCounted

func _init(host: Control) -> void:
	app = host
	drafts = Drafts.new(host)
	edits = Edits.new(drafts)
	media = Media.new(drafts)

static func _tool(name: String, desc: String, fields: Dictionary, required: Array, readonly := false) -> Dictionary:
	var props := {}
	for key in fields:
		var field = fields[key]
		props[key] = {"type": field} if field is String else field
	return {"name": name, "description": desc, "inputSchema": {"type": "object", "properties": props,
		"required": required, "additionalProperties": false}, "annotations": {"readOnlyHint": readonly, "openWorldHint": false}}

static func _enum(values: Array) -> Dictionary:
	return {"type": "string", "enum": values}

static func catalog() -> Array[Dictionary]:
	return [
		_tool("describe_project", "Read project declarations, IDs, capabilities and recent projects; open a project from recent projects by path.", {"path": "string", "section": "string"}, []),
		_tool("query_content", "Read published or draft data. Map keys are stable map codes. Content keys are function ID and content ID.", {
			"kind": _enum(["assets", "functions", "bindings", "maps", "map", "layers", "objects", "tiles", "collision", "ports", "edges", "cells", "references", "timeline",
				"contents", "content", "views", "world", "groups", "candidates", "inbound", "live_map"]),
			"draft": "string", "map": "string", "layer": "string", "instance": "string", "function": "string",
			"content": "string", "view": "string", "types": "array", "domains": "object", "field": "object", "region": "array",
			"asset": "string", "trigger": "string", "mapCodes": "array", "search": "string", "offset": "integer", "limit": "integer"}, ["kind"], true),
		_tool("manage_draft", "Create, reopen, list, diff, undo, redo or discard persistent batch drafts. Undo, redo and discard require the current revision.", {
			"action": _enum(["list", "create", "open", "save", "diff", "undo", "redo", "discard"]),
			"draft": "string", "name": "string", "revision": "integer", "summaryOnly": "boolean"}, ["action"]),
		_tool("apply_changes", "Apply a batch to a draft as one undo step. Use map.create/patch/rename/delete, layer.put/delete/move, tiles.set, collision.set, instance.put/delete, binding.put/delete, content.put/delete, view.put/delete, group.put/delete, slot.set, startup.set or project.set. New IDs may be reused as $alias by specifying as on a previous operation. See MCP documentation for operands.", {
			"draft": "string", "revision": "integer", "operations": {"type": "array", "items": _operation_schema()}}, ["draft", "revision", "operations"]),
		_tool("generate_map", "List generator fields and presets, then generate a new editable map in a draft. Regenerate from sourceMap parameters into a new map.", {
			"generator": "string", "draft": "string", "revision": "integer", "sourceMap": "string",
			"name": "string", "preset": "string", "parameters": "object"}, []),
		_tool("capture_editor", "Inspect UI control paths or capture current window, popup, map canvas, panel or rectangle as PNG. Optionally navigate first; capture a draft map without changing the live editor.", {
			"target": _enum(["window", "popup", "canvas", "control", "tree", "draft_map"]), "control": "string",
			"window": "string",
			"rect": "array", "draft": "string", "map": "string", "panel": "string", "view": "string",
			"function": "string", "content": "string", "instance": "string", "camera": "object",
			"time": "number", "width": "integer", "height": "integer", "delayMs": "integer"}, []),
		_tool("render_preview", "Ask the game's declared renderer for PNG frames and picking regions. Supports mapFrame, screenLayout, timelineFrame, worldFrame and playtestFrame when declared. times are sample positions in seconds, frames or beats; omit unit to use the timeline's unit.", {
			"capability": _enum(["mapFrame", "screenLayout", "timelineFrame", "worldFrame", "playtestFrame"]),
			"draft": "string", "map": "string", "view": "string", "function": "string", "content": "string",
			"instance": "string", "binding": "string", "profile": "string", "locale": "string",
			"camera": "object", "width": "integer", "height": "integer", "times": "array", "unit": _enum(["seconds", "frames", "beats"])}, ["capability"], true),
		_tool("preview_asset", "Inspect declared images/atlas cells, entity shapes, animation frames, and project audio length/waveform/PCM clips.", {
			"asset": "string", "audio": "string", "cell": "array", "frames": "array", "start": "number", "duration": "number"}, [], true),
		_tool("validate", "Check draft or published project, map or content. Returns paths, causes and publication conflicts.", {
			"draft": "string", "map": "string", "function": "string", "content": "string"}, [], true),
		_tool("playtest", "Launch a declared project/map/arrival/content/screen entry, or an unpublished screen snapshot when supported. Check load receipt, capture a declared live frame or stop.", {
			"action": _enum(["start", "status", "capture", "stop"]),
			"entry": _enum(["project", "map", "content", "screen"]), "target": "object",
			"draft": "string", "profile": "string", "locale": "string", "width": "integer", "height": "integer"}, ["action"]),
		_tool("publish", "Validate and publish one exact draft revision to the game's authoring data. previewOnly reports planned files without saving.", {
			"draft": "string", "revision": "integer", "previewOnly": "boolean"}, ["draft", "revision"]),
	]

static func _operation_schema() -> Dictionary:
	return {"type": "object", "required": ["op"], "properties": {
		"op": _enum(["map.create", "map.patch", "map.rename", "map.delete", "layer.put", "layer.delete", "layer.move",
			"tiles.set", "collision.set", "instance.put", "instance.delete", "binding.put", "binding.delete",
			"content.put", "content.delete", "view.put", "view.delete", "group.put", "group.delete", "slot.set",
			"startup.set", "project.set"]),
		"as": {"type": "string", "description": "Return this ID as a batch alias; reference it as $alias."},
		"map": {"type": "string", "description": "Stable map code."},
		"layer": {"type": "string", "description": "Layer ID from query_content."},
		"instance": {"type": "string"}, "binding": {"type": "string"}, "function": {"type": "string"},
		"content": {"type": "string"}, "view": {"type": "string"}, "group": {"type": "string"}, "slot": {"type": "string"},
		"name": {"type": "string"}, "width": {"type": "integer"}, "height": {"type": "integer"},
		"projection": _enum(["orthogonal", "isometric", "hexagonal"]), "topology": _enum(["quads", "triangles"]),
		"objectIndex": {"type": "integer"}, "index": {"type": "integer"}, "world": {"type": "array"},
		"data": {"type": "object", "description": "Patch using the matching document keys returned by query_content. For startup/slot use target; for instance.put use asset, layer, x, y, props and transform."},
		"cells": {"type": "array", "description": "Each row is {x,y,asset,atlas:[col,row],alt} for tiles or {x,y,type} for collision. Use {x,y,remove:true} to erase."},
		"section": _enum(Edits.PROJECT_FIELDS), "value": {"description": "Complete replacement for section."}}}

static func known_tool(name: String) -> bool:
	return catalog().any(func(tool): return tool.name == name)

static func tool_result(result: Dictionary) -> Dictionary:
	var attachments: Array = result.get("_media", [])
	result.erase("_media")
	var content: Array = [{"type": "text", "text": JSON.stringify(result)}]
	content.append_array(attachments)
	return {"isError": result.has("error"), "structuredContent": result, "content": content}

func invoke(name: String, args: Dictionary) -> Dictionary:
	var specification: Dictionary = {}
	for tool in catalog():
		if tool.name == name:
			specification = tool.inputSchema
			break
	for key in specification.required:
		if not args.has(key):
			return {"error": "缺少参数：" + key}
	for key in args:
		if not specification.properties.has(key):
			return {"error": "未知参数：" + str(key)}
		var field: Dictionary = specification.properties[key]
		if not _is_type(args[key], field.type) or (field.has("enum") and args[key] not in field.enum):
			return {"error": "参数类型或值无效：" + str(key)}
	if name == "describe_project":
		return _describe(args)
	if name == "capture_editor" and not args.has("draft"):
		return await media.capture(args, {})
	if app.manifest.is_empty() or app.manifest.has("_error"):
		return {"error": "请先在编辑器中打开游戏工程。"}
	if name in ["apply_changes", "generate_map", "query_content", "validate", "publish"]:
		Maps.refresh_external_maps()
	if name == "manage_draft":
		return drafts.manage(args)
	var draft: Dictionary = {}
	if args.has("draft"):
		draft = drafts.read(args.draft)
		if draft.is_empty():
			return {"error": "当前工程没有此草稿。"}
		if args.has("revision") and draft.revision != args.revision:
			if name == "publish" and not args.get("previewOnly", false) and draft.revision == args.revision + 1 \
					and draft.get("lastPublish", {}).get("publishedRevision") == args.revision:
				return drafts.last_publish(draft)
			return {"error": "草稿版本已变化。", "current": drafts.info(draft)}
		if name in ["publish", "apply_changes", "generate_map"]:
			var completed: Dictionary = drafts.completed_publish(draft)
			if not completed.is_empty():
				if name == "publish" and not args.get("previewOnly", false):
					return drafts.finish_publish(draft, completed.files, completed.pending)
				return {"error": "正式文件已发布，请用当前版本重试 publish 完成草稿整理。", "published": true}
	var batch: Dictionary = drafts.state(draft)
	if batch.is_empty():
		return {"error": "草稿的当前版本不可读。"}
	match name:
		"query_content": return _query(args, batch)
		"apply_changes": return edits.apply(draft, args.operations, batch)
		"generate_map": return await _generate(args, draft, batch)
		"capture_editor": return await media.capture(args, batch)
		"render_preview": return await media.render(args, batch)
		"preview_asset": return await media.asset(args)
		"validate":
			var result := _validate(args, batch)
			if not draft.is_empty() and not args.has("map") and not args.has("content"):
				var plan: Dictionary = drafts.plan(draft, batch)
				var conflict: Dictionary = plan if plan.has("error") else drafts.check_plan(plan)
				if conflict.has("error"):
					result.issues.append({"severity": "error", "path": "publish", "message": conflict.error})
					result.valid = false
			return result
		"playtest": return await media.playtest(args, batch)
		"publish": return await _publish(args, draft, batch)
	return {"error": "未知操作。"}

static func _is_type(value: Variant, type: String) -> bool:
	match type:
		"integer": return (value is int or value is float) and is_finite(float(value)) and value == floorf(value)
		"number": return (value is int or value is float) and is_finite(float(value))
		"string": return value is String
		"array": return value is Array
		"object": return value is Dictionary
		"boolean": return value is bool
	return false

func _describe(args: Dictionary) -> Dictionary:
	if args.has("path"):
		var path_: String = args.path.replace("\\", "/").simplify_path()
		if path_ != app.cur_project_dir:
			if not app.project_dirs.any(func(p): return str(p).replace("\\", "/").simplify_path() == path_):
				return {"error": "请在编辑器中首次打开该项目，或用 --bird-project 指定。"}
			if _editor_dirty():
				return {"error": "编辑器有未完成的人工作业，请先保存或关闭编辑表单。"}
			if _playing():
				return {"error": "请先结束当前试玩，再切换工程。"}
			var manifest := EditorManifest.load_from(path_)
			if manifest.has("_error"):
				return {"error": manifest._error}
			app._enter_project(path_, manifest)
	var available: Dictionary = app._manifest_write_payload(app.manifest) if not app.manifest.has("_error") else {}
	var response := {"path": app.cur_project_dir,
		"recent": app.project_dirs.map(func(p): return {"path": p, "name": app.project_names.get(p, p)}),
		"map": app.canvas.cur_map_code() if app.map_loaded else "", "dirty": _editor_dirty()}
	if app.manifest.has("_error"):
		response["projectError"] = app.manifest._error
	if args.has("section"):
		if not available.has(args.section):
			return {"error": "该项目没有此声明：" + args.section, "sections": available.keys()}
		response["declaration"] = available[args.section]
	else:
		response["manifest"] = available
	return response

func _editor_dirty() -> bool:
	return app._has_open_editor_form() or (app.map_loaded and (app.canvas.modified_flag or app.canvas.doc_busy \
		or app.project_shell.content_editor.has_staged_for_current_doc()))

func _playing() -> bool:
	return app._playtest_ctrl._play_pid > 0 and Playtest.is_alive(app._playtest_ctrl._play_pid)

func _query(args: Dictionary, batch: Dictionary) -> Dictionary:
	var m: Dictionary = drafts.candidate(batch)
	var fn: String = args.get("function", "")
	var cid: String = args.get("content", "")
	var code: String = args.get("map", "")
	match args.kind:
		"live_map":
			if not app.map_loaded:
				return {"error": "当前未打开地图。"}
			var canvas: EditorCanvas = app.canvas
			var snapshot := canvas.extract(true)
			if snapshot.is_empty():
				if not canvas.is_map_ready():
					return {"error": "画布正在重建，请稍后重试。"}
				return {"error": "画布上的拖动尚未完成，请稍后重试。"}
			return {"data": snapshot}
		"maps": return _page(drafts.maps_of(batch), args)
		"assets", "functions":
			var working: Dictionary = drafts.map_of(batch, code).get("data", {}) if code != "" else {}
			if code != "" and working.is_empty():
				return {"error": "地图不存在：" + code}
			if args.kind == "assets":
				var rows := Catalog.asset_rows(m, working)
				for row in rows:
					var decl: Dictionary = row.decl
					row["tags"] = decl.get("tags", [])
					row["disabled"] = decl.get("disabled", false)
					row.erase("decl")
				return _page(rows, args)
			var existing: Array = []
			if args.has("instance"):
				for obj in working.get("objects", []):
					if obj.get("code") == args.instance:
						existing = obj.get("functions", [])
						break
			return _page(Catalog.functions(m, existing, working, args.get("trigger", "")), args)
		"objects", "bindings":
			return _objects(m, batch, args)
		"views":
			var rows: Array = m.get("views", [])
			if not args.has("view"):
				return _page(rows, args)
			for row in rows:
				if row.view_id == args.view:
					return {"data": row}
			return {"error": "屏幕不存在。"}
		"world": return {"data": m.get("worldLayout", {})}
		"groups": return {"data": m.get("eventLayers", {}), "drawings": drafts.event_drawings(batch, m, code) if code != "" else []}
		"contents":
			var rows := []
			for kind in ([fn] if fn != "" else Contents.declared_kinds(m)):
				for id in Contents.list_ids(m, kind):
					var item := Contents.read_ex(m, kind, id)
					rows.append({"function": kind, "content": id, "name": item.data.get("name", "") if item.status == "ok" else "",
						"status": item.status})
			return _page(rows, args)
		"content", "timeline":
			var body: Dictionary = drafts.content_of(batch, fn, cid)
			if body.is_empty():
				return {"error": "内容不存在。"}
			return {"data": body.data} if args.kind == "content" else {"data": Timeline.to_timeline(body.data.get("steps", []))}
		"candidates":
			var working: Dictionary = drafts.map_of(batch, code).get("data", {}) if code != "" else {}
			if args.has("domains"):
				var options := Targets.destination_options(m, args.domains, working)
				return _page(options, args)
			if args.has("field"):
				return _page(app.project_shell.content_editor.project_reference_options(args.field, code, m), args)
			return {"error": "需要 domains 或 field。"}
		"inbound":
			if args.has("view"):
				return {"data": Usage.view_inbound_refs(m, args.view, [])}
			if fn != "" and cid != "":
				return {"data": Usage.inbound_content(m, fn, cid)}
			return {"error": "需要 view 或 function/content。"}
	var row: Dictionary = drafts.map_of(batch, code)
	if row.is_empty():
		return {"error": "地图不存在：" + code}
	var data: Dictionary = row.data
	var layer: String = args.get("layer", "")
	match args.kind:
		"map": return {"name": row.name, "data": data}
		"layers": return _page(data.meta.layers, args)
		"ports": return _page(Fields.port_options(m, code, data.get("objects", []), args.get("types", [])), args)
		"edges": return _page(Fields.edge_candidates_of(data, m), args)
		"cells": return _page(CellGraph.cell_options(CellGraph.graph_of(data.meta)), args)
		"references": return _page(Spatial.map_links(m, data), args)
		"tiles": return _page(data.get("tiles", {}).get(layer, []), args)
		"collision": return _page(data.get("collision", []), args)
	return {"error": "未知查询。"}

func _objects(m: Dictionary, batch: Dictionary, args: Dictionary) -> Dictionary:
	var rows := []
	var map_codes: Array = args.get("mapCodes", [])
	if args.has("map"):
		map_codes = [args.map]
	elif map_codes.is_empty():
		map_codes = drafts.maps_of(batch).map(func(row): return row.map)
	var layer: String = args.get("layer", "")
	var fn: String = args.get("function", "")
	var asset: String = args.get("asset", "")
	var fn_code := Functions.fn_code(m, fn)
	var assets := Assets.all(m)
	var functions := {}
	for declaration in Functions.functions(m).values():
		functions[declaration.code] = declaration.id
	for code in map_codes:
		if not code is String:
			return {"error": "mapCodes 必须是地图码数组。"}
		var map: Dictionary = drafts.map_of(batch, code)
		if map.is_empty():
			return {"error": "地图不存在：" + code}
		var data: Dictionary = map.data
		for i in data.get("objects", []).size():
			var item: Dictionary = data.objects[i]
			var effective_layer := MapViewData.object_layer(item, data.meta.layers)
			if (layer != "" and effective_layer != layer) or (asset != "" and item.asset != asset) \
					or (args.has("instance") and item.get("code") != args.instance):
				continue
			var base := {"map": code, "mapName": map.name, "objectIndex": i, "assetName": Assets.label_of_decl(assets.get(item.asset, {}), item.asset),
				"layer": effective_layer}
			var bindings: Array = item.get("functions", [])
			if args.kind == "objects":
				if fn == "" or bindings.any(func(binding): return binding.get("fn") == fn_code):
					rows.append(item.merged(base, true))
				continue
			for index in bindings.size():
				var binding: Dictionary = bindings[index]
				if (fn != "" and binding.fn != fn_code) or (args.has("trigger") and binding.get("trigger", "") != args.trigger) \
						or (args.has("content") and binding.get("content", "") != args.content):
					continue
				rows.append(binding.merged(base.merged({"instance": item.get("code", ""), "sequence": index + 1,
					"function": functions.get(binding.fn, ""), "asset": item.asset}), true))
	return _page(rows, args)

func _page(rows: Array, args: Dictionary) -> Dictionary:
	if args.has("region"):
		var region: Array = args.region
		if region.size() != 4 or not region.all(func(n): return _is_type(n, "number")):
			return {"error": "region 必须是 [x,y,w,h]。"}
		var bounds := Rect2(region[0], region[1], region[2], region[3])
		rows = rows.filter(func(row):
			if row is Dictionary and row.has("x") and row.has("y"):
				return bounds.has_point(Vector2(row.x, row.y))
			return row is Array and row.size() >= 2 and bounds.has_point(Vector2(row[0], row[1])))
	if args.get("search", "") != "":
		var needle: String = args.search.to_lower()
		rows = rows.filter(func(row): return JSON.stringify(row).to_lower().contains(needle))
	var offset := clampi(int(args.get("offset", 0)), 0, rows.size())
	var limit := clampi(int(args.get("limit", 200)), 1, 1000)
	return {"items": rows.slice(offset, offset + limit), "total": rows.size(), "offset": offset}

func _validate(args: Dictionary, batch: Dictionary) -> Dictionary:
	return ProjectCheck.check(drafts.candidate(batch), args)

func _publish(args: Dictionary, draft: Dictionary, batch: Dictionary) -> Dictionary:
	if not args.get("previewOnly", false) and _editor_dirty():
		return {"error": "当前编辑器有人工作业或编辑表单，请先保存或关闭后再发布。"}
	if not args.get("previewOnly", false) and _playing():
		return {"error": "请先结束试玩，再发布和重新加载工程。"}
	var checked := _validate({}, batch)
	if not checked.valid:
		return checked.merged({"error": "校验未通过，未发布。"})
	var plan: Dictionary = drafts.plan(draft, batch)
	if plan.has("error"):
		return plan
	var preflight: Dictionary = drafts.check_plan(plan)
	if preflight.has("error"):
		return preflight
	if args.get("previewOnly", false):
		return {"entries": plan.entries, "revision": draft.revision, "issues": checked.issues}
	var current: String = app.canvas.cur_map_code() if app.map_loaded else ""
	var result: Dictionary = drafts.publish(draft, plan, preflight)
	if result.get("published", false) and not result.files.is_empty():
		var root: String = app.manifest._dir
		var reloaded := EditorManifest.load_from(root)
		if not reloaded.has("_error"):
			app._enter_project(root, reloaded)
			if current != "" and Refs.resolve_map(reloaded, current).status == "ok":
				await app._map_file_ctrl.open_map_by_code(current)
	return result

func _generate(args: Dictionary, draft: Dictionary, batch: Dictionary) -> Dictionary:
	var m: Dictionary = drafts.candidate(batch)
	var pool: Dictionary = m.get("mapGenerators", {})
	var id: String = args.get("generator", "")
	var params := {}
	if args.has("sourceMap"):
		var source: Dictionary = drafts.map_of(batch, args.sourceMap)
		if source.is_empty():
			return {"error": "生成源地图不存在。"}
		var origin := Generators.origin(source.data)
		if origin.is_empty():
			return {"error": "源地图没有生成参数。"}
		id = origin.generator
		params = origin.parameters.duplicate(true)
	if id == "":
		return {"generators": pool.keys(), "available": Runner.supports(m, Runner.GENERATE_MAP)}
	if not pool.has(id):
		return {"error": "生成器未声明：" + id}
	var fields := Generators.fields_for(m, id)
	var presets := Generators.presets(m, id)
	if not args.has("name"):
		return {"generator": id, "fields": fields, "presets": presets, "parameters": params}
	if not args.has("revision") or draft.is_empty() or not EditorManifest.is_valid_map_name(args.name):
		return {"error": "生成需要有效的 name、draft、revision。"}
	if drafts.maps_of(batch).any(func(row): return str(row.name).to_lower() == args.name.to_lower()):
		return {"error": "地图名已使用。"}
	if args.has("preset"):
		var index := presets.find_custom(func(row): return row.id == args.preset)
		if index < 0:
			return {"error": "预设不存在。"}
		params.merge(presets[index].parameters, true)
	params.merge(args.get("parameters", {}), true)
	for field in fields:
		if not params.has(field.id):
			params[field.id] = Generators.default_value(field)
		if not Generators.valid_value(field, params[field.id]):
			return {"error": "无效的生成参数：" + str(field.id)}
	var code: String = edits.new_map_code(batch)
	var subject := {"generator": id, "parameters": params, "manifest": app._manifest_write_payload(drafts.candidate(batch)),
		"target": {"name": args.name, "code": code, "version": Maps.FORMAT_VERSION}}
	var result := await Runner.render(app.get_tree(), m, Runner.GENERATE_MAP, subject, Vector2i.ZERO, "",
		func() -> bool: return app.manifest.get("_dir") == m._dir)
	if result.has("error"):
		return result
	var decoded := Maps.decode_text(result.map_text, "map.json", m)
	if not decoded.ok:
		return {"error": "游戏生成的地图数据无效。", "issues": decoded.errors}
	var map: Dictionary = decoded.data
	if map.meta.get("code", code) != code:
		return {"error": "游戏生成结果使用了不同地图码。"}
	map.meta.name = args.name
	map.meta.code = code
	Generators.remember(map, id, params)
	var previous: Dictionary = drafts.shallow_batch(batch)
	batch.maps[code] = {"name": args.name, "original": "", "baseline": "", "data": map}
	return drafts.append(draft, batch, previous).merged({"map": code, "warnings": decoded.warnings})
