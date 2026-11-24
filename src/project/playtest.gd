class_name Playtest
## 试玩启动器（A6）：优先用清单的结构化配置 playtest.executable + playtest.args
## （OS.create_process 直启，参数按数组传递，空格路径无需引号转义）；
## 没有结构化配置时退回 playCommand 模板（经 cmd /c 或 sh -c 执行整条命令，
## 此时跟踪到的是包装进程而不是游戏本体，返回 tracked/kind 让 UI 说清楚）。

## 启动并跟踪：返回 {ok, error, pid, program, args, tracked, kind}
## kind = "direct"（结构化配置直启）/ "shell"（playCommand 模板）；
## tracked = false 时 pid 是包装进程，退出状态不代表游戏本身。
## 因此 UI 必须**同时**看 tracked 与 kind 才能说清「跟踪的是谁」：tracked=false 时只能报
## 「包装进程已退出」，不能断言游戏成功/失败。

## 日志尾部读取上限（§5：日志按有界尾部读取，不整份载入）
const TAIL_BYTES := 64 * 1024
const PROTOCOL := 1
const MAX_REPORT_BYTES := 64 * 1024

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
	return report

static func launch_tracked(m: Dictionary, map_path: String, extra_args: PackedStringArray = [], report := {}) -> Dictionary:
	var pt: Dictionary = m.get("playtest", {}) if m.get("playtest", null) is Dictionary else {}
	var project_dir := str(m.get("_dir", ""))
	var exe_rel := str(pt.get("executable", "")).strip_edges()
	var arg_decls: Array = pt.get("args", []) if pt.get("args", null) is Array else []
	var spec_args: PackedStringArray = PackedStringArray()
	for a in arg_decls:
		spec_args.append(EditorManifest.substitute_vars_raw(str(a), map_path, project_dir))
	spec_args.append_array(extra_args)
	if exe_rel != "":
		if not report.is_empty():
			spec_args.append("--editor-playtest=" + Marshalls.utf8_to_base64(JSON.stringify(report)))
		var exe := EditorManifest.substitute_vars_raw(exe_rel, map_path, project_dir)
		if not FileAccess.file_exists(exe):
			return {"ok": false, "error": "找不到试玩可执行文件: " + exe,
				"pid": -1, "program": exe, "args": spec_args, "tracked": true, "kind": "direct"}
		# 注意：OS.create_process 不设工作目录（第 3 参不是 cwd）——子进程继承编辑器自身 cwd，
		# 不保证是项目根。游戏侧读相对路径必须靠显式参数（--path 等，清单 args 里写）。
		var pid := OS.create_process(exe, spec_args)
		if pid == -1:
			return {"ok": false, "error": "进程启动失败: " + exe,
				"pid": -1, "program": exe, "args": spec_args, "tracked": true, "kind": "direct"}
		return {"ok": true, "error": "", "pid": pid, "program": exe,
			"args": spec_args, "tracked": true, "kind": "direct"}
	# —— 退回 playCommand 模板 ——
	var cmd := EditorManifest.resolved_play_command(m, map_path)
	if cmd.strip_edges() == "":
		return {"ok": false, "error": "清单没配 playtest.executable 或 playCommand，无法试玩",
			"pid": -1, "program": "", "args": PackedStringArray(), "tracked": false, "kind": "shell"}
	var exe0 := _first_token(cmd)
	if exe0 != "" and (exe0.contains("/") or exe0.contains("\\")) and not FileAccess.file_exists(exe0):
		return {"ok": false, "error": "找不到游戏可执行文件: " + exe0,
			"pid": -1, "program": exe0, "args": PackedStringArray(), "tracked": false, "kind": "shell"}
	if not extra_args.is_empty():
		cmd += " " + " ".join(extra_args)
	var sh_pid := -1
	if OS.get_name().begins_with("Windows"):
		sh_pid = OS.create_process("cmd", ["/c", cmd])
	else:
		sh_pid = OS.create_process("/bin/sh", ["-c", cmd])
	if sh_pid == -1:
		return {"ok": false, "error": "进程启动失败: " + cmd,
			"pid": -1, "program": exe0, "args": PackedStringArray(), "tracked": false, "kind": "shell"}
	return {"ok": true, "error": "", "pid": sh_pid, "program": exe0,
		"args": PackedStringArray(), "tracked": false, "kind": "shell"}

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

## 取命令首个参数（支持双引号包裹的路径）
static func _first_token(cmd: String) -> String:
	var s := cmd.strip_edges()
	if s == "":
		return ""
	if s.begins_with("\""):
		var end := s.find("\"", 1)
		return s.substr(1, end - 1) if end > 0 else ""
	var sp := s.find(" ")
	return s if sp < 0 else s.substr(0, sp)

## 读试玩日志最后 n 行（游戏侧写 <项目>/editor/playtest.log）；无文件返回空串
## §5：有界尾部读取——日志可能长到几 MB，get_as_text() 每次全量载入会卡交互线程。
## 只读末尾 TAIL_BYTES，丢弃可能被截断的首行。
static func log_tail(project_dir: String, n: int) -> String:
	if project_dir == "":
		return ""
	var path := project_dir.path_join("editor/playtest.log")
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var sz := int(f.get_length())
	var start := maxi(0, sz - TAIL_BYTES)
	f.seek(start)
	var text := f.get_buffer(sz - start).get_string_from_utf8()
	f.close()
	var lines := text.split("\n")
	if start > 0 and not lines.is_empty():
		lines.remove_at(0)   # 首行可能只读到半行
	var out := []
	for i in range(maxi(lines.size() - n, 0), lines.size()):
		var t := str(lines[i]).strip_edges()
		if t != "":
			out.append(t)
	return " | ".join(PackedStringArray(out))
