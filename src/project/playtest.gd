class_name Playtest
## 通过清单中的可执行文件和参数启动游戏。

const PROTOCOL := 1
const MAX_REPORT_BYTES := 64 * 1024

static func allows_entry(m: Dictionary, function_id: String) -> bool:
	var config: Dictionary = m.get("playtest", {})
	return config.get("projectEntry", false) and config.get("entryFunctions", []).has(function_id)

static func allows_content_map(m: Dictionary, function_id: String) -> bool:
	return allows_entry(m, function_id) and m.get("playtest", {}).get("contentEntryMap") == true

static func entry_arg(function_id: String, content_id: String, content_map := "") -> String:
	var entry := {"function": function_id, "content": content_id}
	if not content_map.is_empty():
		entry["contentMap"] = content_map
	return _encode_entry(entry)

static func allows_view_entry(m: Dictionary) -> bool:
	return m.get("playtest", {}).get("viewEntry", false) == true

static func allows_map_entry(m: Dictionary) -> bool:
	return m.get("playtest", {}).get("mapEntry", false) == true

static func map_entry_domains(m: Dictionary) -> Dictionary:
	return {"maps": allows_map_entry(m), "arrivalPorts": m.get("playtest", {}).get("mapEntryPorts", [])}

static func map_entry_arg(target: Dictionary) -> String:
	return _encode_entry(target)

static func allows_view_draft(m: Dictionary) -> bool:
	var config: Dictionary = m.get("playtest", {})
	return config.get("viewDraft", false) == true and config.get("report", false) == true

static func view_entry_arg(view_id: String, draft_path := "") -> String:
	var entry := {"view": view_id}
	if draft_path != "":
		entry["viewDraft"] = ProjectSettings.globalize_path(draft_path)
	return _encode_entry(entry)

static func view_draft_path(request: Dictionary) -> String:
	return str(request.path).get_basename() + ".view.json"

static func clear_view_draft(request: Dictionary) -> void:
	if request.has("viewDigest"):
		DirAccess.remove_absolute(view_draft_path(request))

static func _encode_entry(target: Dictionary) -> String:
	var entry := target.merged({"version": PROTOCOL})
	return "--editor-entry=" + Marshalls.utf8_to_base64(JSON.stringify(entry))

static func request_report(m: Dictionary, map_digest: String) -> Dictionary:
	var pt = m.get("playtest", {})
	if not pt is Dictionary or not bool(pt.get("report", false)):
		return {}
	var dir := str(m.get("_dir", ""))
	if dir == "" or str(pt.get("executable", "")).strip_edges() == "":
		return {}
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	if token.length() != 32:
		return {}
	var path := dir.path_join("editor/playtest-reports/" + token + ".json")
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		return {}
	return {"version": PROTOCOL, "token": token, "path": path, "mapDigest": map_digest,
		"manifestDigest": FileAccess.get_sha256(dir.path_join("editor/editor_manifest.json"))}

static func read_report(request: Dictionary) -> Dictionary:
	if request.is_empty():
		return {}
	var f := FileAccess.open(str(request.path), FileAccess.READ)
	if f == null:
		return {}
	if f.get_length() > MAX_REPORT_BYTES:
		return {"status": "invalid", "message": "加载回执超过大小上限"}
	var parser := JSON.new()
	if parser.parse(f.get_as_text()) != OK:
		return {"status": "invalid", "message": "加载回执不是有效 JSON"}
	var report = parser.data
	if not report is Dictionary or report.get("version") != PROTOCOL or report.get("token") != request.token:
		return {"status": "invalid", "message": "加载回执的版本或试玩标识不匹配"}
	var result := str(report.get("status", ""))
	if result == "error":
		return {"status": "error", "message": str(report.get("message", "")).left(250)}
	if result != "ready":
		return {"status": "invalid", "message": "加载回执状态无效"}
	for key in ["mapDigest", "manifestDigest"]:
		if str(report.get(key, "")) != str(request[key]):
			return {"status": "invalid", "message": "游戏加载的磁盘版本与本次试玩不一致"}
	if request.has("viewDigest") and report.get("viewDigest") != request.viewDigest:
		return {"status": "invalid", "message": "游戏没有加载本次屏幕草稿的快照"}
	return report

## Author locations are optional and do not affect successful load receipts.
static func observations(report: Dictionary) -> Array:
	if report.get("status") != "ready" or not report.get("observations") is Array:
		return []
	var out := []
	for row in report.observations.slice(0, 100):
		if not row is Dictionary or not row.get("message") is String or row.message.is_empty():
			continue
		var entry := {"message": row.message.left(500)}
		var step = row.get("step")
		var valid_step: bool = (step is int or step is float) and step >= 0 and step <= 2147483647 and int(step) == step
		if valid_step and (row.get("function") is String and row.get("content") is String
				and row.get("stepCode") is String and row.get("contentDigest") is String
				and row.contentDigest.length() == 64):
			entry.merge({"function": row.function, "content": row.content, "step": int(step),
				"stepCode": row.stepCode, "contentDigest": row.contentDigest})
		out.append(entry)
	return out

static func launch_tracked(m: Dictionary, map_path: String, extra_args: PackedStringArray = [], report := {}) -> Dictionary:
	var pt: Dictionary = m.get("playtest", {})
	var executable := str(pt.get("executable", "")).strip_edges()
	if executable == "":
		return {"ok": false, "error": "清单没有配置 playtest.executable。"}
	var project_dir := str(m.get("_dir", ""))
	var exe := EditorManifest.substitute_vars_raw(executable, map_path, project_dir)
	if not FileAccess.file_exists(exe):
		return {"ok": false, "error": "找不到试玩可执行文件: " + exe}
	var args := PackedStringArray()
	for arg in pt.get("args", []):
		args.append(EditorManifest.substitute_vars_raw(arg, map_path, project_dir))
	args.append_array(extra_args)
	if not report.is_empty():
		args.append("--editor-playtest=" + Marshalls.utf8_to_base64(JSON.stringify(report)))
	var pid := OS.create_process(exe, args)
	if pid == -1:
		return {"ok": false, "error": "进程启动失败: " + exe}
	return {"ok": true, "pid": pid, "program": exe}

## 此平台能否跟踪进程退出（R24）：查不了就明说，不给假的「仍在运行」。
## §5：存活查询改用 OS.is_process_running（纯系统调用，不再 spawn tasklist 子进程），
## 桌面平台都能跟踪；只有 web 导出没有进程可见性。
static func tracking_available() -> bool:
	return not OS.has_feature("web")

## 轮询某个 pid 是否还活着。
## §5「进程查询移出交互路径」：原实现每次 OS.execute("tasklist") 同步开子进程（~几十 ms，
## 主线程卡顿），改为 OS.is_process_running——一次系统调用，无子进程、无输出解析。
## web 平台无法查询：返回 true = 假定运行中（tracking_available 已让 UI 说明）。
static func is_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if OS.has_feature("web"):
		return true
	return OS.is_process_running(pid)
