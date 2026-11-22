class_name Playtest
## 试玩启动器（A6）：优先用清单的结构化配置 playtest.executable + playtest.args
## （OS.create_process 直启，参数按数组传递，空格路径无需引号转义）；
## 没有结构化配置时退回 playCommand 模板（经 cmd /c 或 sh -c 执行整条命令，
## 此时跟踪到的是包装进程而不是游戏本体，返回 tracked_kind 让 UI 说清楚）。

## 启动并跟踪：返回 {ok, error, pid, program, args, tracked, kind}
## kind = "direct"（结构化配置直启）/ "shell"（playCommand 模板）；
## tracked = false 时 pid 是包装进程，退出状态不代表游戏本身。
static func launch_tracked(m: Dictionary, map_path: String, extra_args: PackedStringArray = []) -> Dictionary:
	var pt: Dictionary = m.get("playtest", {}) if m.get("playtest", null) is Dictionary else {}
	var project_dir := str(m.get("_dir", ""))
	var exe_rel := str(pt.get("executable", "")).strip_edges()
	var arg_decls: Array = pt.get("args", []) if pt.get("args", null) is Array else []
	var spec_args: PackedStringArray = PackedStringArray()
	for a in arg_decls:
		spec_args.append(EditorManifest.substitute_vars_raw(str(a), map_path, project_dir))
	spec_args.append_array(extra_args)
	if exe_rel != "":
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

## 轮询某个 pid 是否还活着（Windows: tasklist；其它平台返回 true = 假定运行中）
static func is_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if not OS.get_name().begins_with("Windows"):
		return true
	var out: Array = []
	var code := OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/NH"], out, true)
	if code != 0:
		return true   # 查询失败时不误判为退出
	var text := "\n".join(PackedStringArray(out))
	return text.contains(str(pid))

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
static func log_tail(project_dir: String, n: int) -> String:
	if project_dir == "":
		return ""
	var path := project_dir.path_join("editor/playtest.log")
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var lines := f.get_as_text().split("\n")
	f.close()
	var out := []
	for i in range(maxi(lines.size() - n, 0), lines.size()):
		var t := str(lines[i]).strip_edges()
		if t != "":
			out.append(t)
	return " | ".join(PackedStringArray(out))
