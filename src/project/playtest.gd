class_name Playtest
## 试玩启动器：清单里的 playCommand 模板 + 变量替换 → 拉起游戏子进程。
## 学自 Ogmo 的 playCommand（ChildProcess.spawn cwd=项目目录）与 Tiled 的 %mapfile% 变量。

## 启动并跟踪：返回 {ok, error, pid}
## 调用方可用 is_alive(pid) 轮询进程退出（仅 Windows 下经 tasklist）。
static func launch_tracked(m: Dictionary, map_path: String, extra_args: PackedStringArray = []) -> Dictionary:
	var cmd := EditorManifest.resolved_play_command(m, map_path)
	if cmd.strip_edges() == "":
		return {"ok": false, "error": "清单里没配 playCommand，无法试玩"}
	# 可执行文件明显不存在时提前报错：cmd /c 即便找不到命令也会成功创建进程
	var exe := _first_token(cmd)
	if exe != "" and (exe.contains("/") or exe.contains("\\")) and not FileAccess.file_exists(exe):
		return {"ok": false, "error": "找不到游戏可执行文件: " + exe}
	if not extra_args.is_empty():
		cmd += " " + " ".join(extra_args)
	# 经 cmd /c 执行整条命令（启动仅 Windows 可用；平台分支见 is_alive），模板里可以直接带引号与参数
	var pid := OS.create_process("cmd", ["/c", cmd])
	if pid == -1:
		return {"ok": false, "error": "进程启动失败: " + cmd}
	return {"ok": true, "error": "", "pid": pid}

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
