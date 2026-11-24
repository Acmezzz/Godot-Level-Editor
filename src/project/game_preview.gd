extends RefCounted
## A game-owned tool receives one immutable request and produces a bounded result.
## The editor never loads a game scene or script into its own process.

const VERSION := 1
const MAX_EDGE := 4096
const MAX_PIXELS := 8 * 1024 * 1024
const MAX_REQUEST := 4 * 1024 * 1024
const MAX_PNG := 36 * 1024 * 1024
const MAX_MAP := 4 * 1024 * 1024
const GENERATE_MAP := "generateMap"
const MAX_REPORT := 4096
const TIMEOUT_MS := 12000
const PNG_SIGNATURE := "89504e470d0a1a0a"

static func declaration(manifest: Dictionary) -> Dictionary:
	var raw = manifest.get("preview", {})
	return raw if raw is Dictionary else {}

static func declaration_issues(manifest: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not manifest.has("preview"):
		return out
	if not manifest.preview is Dictionary:
		out.append(_issue("preview", "must be an object"))
		return out
	var d: Dictionary = manifest.preview
	if d.get("version") != VERSION:
		out.append(_issue("preview.version", "must equal 1"))
	var exe = d.get("executable")
	if not exe is String or exe.strip_edges() == "":
		out.append(_issue("preview.executable", "must be a non-empty executable path"))
	var args = d.get("args", [])
	if not args is Array or not args.all(func(v): return v is String):
		out.append(_issue("preview.args", "must be an array of strings"))
	var capabilities = d.get("capabilities")
	if not capabilities is Array or capabilities.is_empty():
		out.append(_issue("preview.capabilities", "must declare at least one capability ID"))
	else:
		var seen := {}
		for id in capabilities:
			if not id is String or id.strip_edges() == "" or seen.has(id):
				out.append(_issue("preview.capabilities", "must contain unique non-empty strings"))
				break
			seen[id] = true
	return out

static func supports(manifest: Dictionary, capability: String) -> bool:
	var config := declaration(manifest)
	var capabilities = config.get("capabilities", [])
	return capabilities is Array and capabilities.has(capability) and declaration_issues(manifest).is_empty()

static func render(tree: SceneTree, manifest: Dictionary, capability: String, subject: Dictionary,
		viewport: Vector2i, locale: String, keep: Callable) -> Dictionary:
	if not supports(manifest, capability) or OS.has_feature("web"):
		return _failed("游戏工程未提供此预览能力。")
	if capability != GENERATE_MAP and not valid_size(viewport):
		return _failed("预览画幅须在 4096 像素边长和 8388608 像素总量内。")
	var root := str(manifest.get("_dir", ""))
	if root.is_empty():
		return _failed("缺少游戏工程目录。")
	var d := declaration(manifest)
	var executable: String = d.executable.replace("%projectpath%", root)
	if not FileAccess.file_exists(executable):
		return _failed("找不到游戏预览程序：" + executable)
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	if token.length() != 32:
		return _failed("无法生成预览请求标识。")
	var dir := ProjectSettings.globalize_path("user://game-preview/" + token)
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return _failed("无法创建预览临时目录。")
	var request := {"version": VERSION, "token": token, "capability": capability,
		"projectPath": root, "viewport": {"w": viewport.x, "h": viewport.y}, "locale": locale,
		"subject": subject}
	var data := JSON.stringify(request).to_utf8_buffer()
	if data.size() > MAX_REQUEST:
		_cleanup(dir)
		return _failed("预览快照超过 4 MiB。")
	var request_path := dir.path_join("request.json")
	var file := FileAccess.open(request_path, FileAccess.WRITE)
	if file == null:
		_cleanup(dir)
		return _failed("无法写入预览快照。")
	file.store_buffer(data)
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_cleanup(dir)
		return _failed("未能完整写入预览快照。")
	var args := PackedStringArray()
	for value in d.get("args", []):
		args.append(value.replace("%projectpath%", root))
	args.append("--editor-preview=" + request_path)
	var pid := OS.create_process(executable, args)
	if pid <= 0:
		_cleanup(dir)
		return _failed("无法启动游戏预览进程。")
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while OS.is_process_running(pid):
		if not keep.call() or Time.get_ticks_msec() >= deadline:
			OS.kill(pid)
			_cleanup(dir)
			return _failed("游戏预览已取消。" if not keep.call() else "游戏预览超时，未返回画面。")
		await tree.create_timer(0.08).timeout
	var result := _read_result(dir, token, viewport, capability) if keep.call() else _failed("游戏预览已取消。")
	_cleanup(dir)
	return result

static func valid_size(size: Vector2i) -> bool:
	return size.x > 0 and size.y > 0 and size.x <= MAX_EDGE and size.y <= MAX_EDGE \
		and size.x * size.y <= MAX_PIXELS

static func _read_result(dir: String, token: String, viewport: Vector2i, capability := "") -> Dictionary:
	var bytes := _read_bounded(dir.path_join("result.json"), MAX_REPORT)
	if bytes.is_empty():
		return _failed("游戏预览进程已退出，未提供有效回执。")
	var parser := JSON.new()
	if parser.parse(bytes.get_string_from_utf8()) != OK:
		return _failed("游戏预览回执不是有效 JSON。")
	var report = parser.data
	if not report is Dictionary or report.get("version") != VERSION or report.get("token") != token:
		return _failed("游戏预览回执不匹配。")
	if report.get("status") == "error":
		return _failed(str(report.get("message", "游戏预览失败。")).left(250))
	if report.get("status") != "ready":
		return _failed("游戏预览回执状态无效。")
	if capability == GENERATE_MAP:
		var map_bytes := _read_bounded(dir.path_join("map.json"), MAX_MAP)
		return {"map_text": map_bytes.get_string_from_utf8()} if not map_bytes.is_empty() and not 0 in map_bytes \
			else _failed("游戏未返回有效大小的 map.json（最多 4 MiB）。")
	var png := _read_bounded(dir.path_join("frame.png"), MAX_PNG)
	if not _matches_png_size(png, viewport):
		return _failed("游戏未返回符合请求画幅的 PNG。")
	var image := Image.new()
	if image.load_png_from_buffer(png) != OK or image.get_size() != viewport:
		return _failed("无法读取游戏生成的 PNG。")
	return {"image": image, "error": ""}

static func _matches_png_size(bytes: PackedByteArray, expected: Vector2i) -> bool:
	if bytes.size() < 33 or bytes.slice(0, 8).hex_encode() != PNG_SIGNATURE \
			or bytes.slice(12, 16).get_string_from_ascii() != "IHDR":
		return false
	var width := (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19]
	var height := (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23]
	return valid_size(expected) and width == expected.x and height == expected.y

static func _read_bounded(path: String, limit: int) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var length := file.get_length()
	return file.get_buffer(length) if length > 0 and length <= limit else PackedByteArray()

static func _cleanup(dir: String) -> void:
	for name in ["request.json", "result.json", "frame.png", "map.json"]:
		var path := dir.path_join(name)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(dir)

static func _failed(message: String) -> Dictionary:
	return {"error": message}

static func _issue(path: String, message: String) -> Dictionary:
	return {"path": path, "message": message, "severity": "warning"}
