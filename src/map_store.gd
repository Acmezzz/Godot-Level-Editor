extends RefCounted
## 地图 JSON 数据层：名称校验后的读写、mtime+尺寸缓存、实体查找、改名/复制（纯文件操作，引用不迁移）。
## 以静态函数为主，带少量静态状态：_cache（读缓存）与 project_rev（写盘版本号，派生缓存据此重扫）。
## manifest 除取 _maps_dir 外，还随读取传入 map_data_validation 做结构校验（查实体类型/功能声明）。
## 注意：路径引用（preload）而非全局类名，避免 headless 首次扫描时的 class_name 缓存问题。

const ManifestScript := preload("res://src/manifest.gd")
const MapValidator := preload("res://src/map_data_validation.gd")

## 当前地图数据格式版本。老图（无 version 键）视为 1。
## v3：collision 条目 [x,y,(type,(shape))]（solid+矩形可短写 [x,y]）；terrain/decor = [x,y,atlas,ax,ay]。
const FORMAT_VERSION := 3
## 项目数据写盘版本号：每次 write_text 成功 +1。派生缓存（实体引用集等）据此判断是否重扫。
static var project_rev := 0

## ---- 地图数据 mtime+尺寸缓存（read/read_all 复用） ----
## 刷新链/校验/引用扫描一个会话里反复 read_all——按文件 mtime 缓存；
## write_text / write_transaction 各自维护一致性（写后失效，下次读回源）。
static var _cache := {}   # path -> {mtime: int, data: Dictionary}

## 按缓存读单图；读失败不缓存（下次重读）
## mtime 是秒级粒度，同秒内外部改文件会被脏缓存吃掉。缓存键补上文件长度——
## 尺寸变了必然重读；同秒且同尺寸的改动仍无法识别（自写路径有显式失效，只影响外部编辑器）。
static func _read_cached(path: String, m: Dictionary) -> Dictionary:
	var mt := FileAccess.get_modified_time(path)
	var sz := _file_size(path)
	var hit = _cache.get(path, null)
	if hit != null and int(hit.get("mtime", -1)) == mt and int(hit.get("size", -1)) == sz:
		return hit.get("data", {})
	var result := read_path(path, m)
	if result.ok:
		_cache[path] = {"mtime": mt, "size": sz, "data": result.data}
	return result.data if result.ok else {}

static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n

## 统一文本解码、版本升级与结构校验；错误时不返回可编辑数据。
static func decode_text(text: String, source := "", manifest := {}) -> Dictionary:
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "data": {}, "errors": [{"path": source, "message": "JSON must be an object"}], "warnings": [], "migrated": false}
	var data: Dictionary = parsed
	var migrated := upgrade(data)
	var issues := MapValidator.validate(data, manifest)
	var errors: Array[Dictionary] = []
	var warnings: Array[Dictionary] = []
	for issue in issues:
		if str(issue.severity) == "error":
			errors.append(issue)
		else:
			warnings.append(issue)
	return {"ok": errors.is_empty(), "data": data if errors.is_empty() else {},
		"errors": errors, "warnings": warnings, "migrated": migrated}

static func read_path(path: String, manifest := {}) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {"ok": false, "data": {}, "errors": [{"path": path, "message": "file not found"}], "warnings": [], "migrated": false}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "data": {}, "errors": [{"path": path, "message": "file cannot be opened"}], "warnings": [], "migrated": false}
	var text := file.get_as_text()
	file.close()
	return decode_text(text, path, manifest)

## 升级地图数据到当前格式；返回是否改动。
## 老图实体坐标可能存了浮点或中心偏移，统一取整为格坐标。
static func upgrade(data: Dictionary) -> bool:
	var ver := int(data.get("version", 1))
	var changed := false
	if ver < FORMAT_VERSION:
		for ent in data.get("entities", []):
			if not (ent is Dictionary):
				continue
			for key in ["x", "y"]:
				if ent.has(key):
					var v = ent[key]
					if v is float or v is int:
						var iv := int(v)
						if iv != v:
							ent[key] = iv
							changed = true
 # spawn 也取整（与实体同规则），否则读回来会偏移半格
		var sp = data.get("spawn", null)
		if sp is Array and (sp as Array).size() >= 2:
			for i in 2:
				var sv = sp[i]
				if sv is float and int(sv) != float(sv):
					sp[i] = int(sv)
					changed = true
		data["version"] = FORMAT_VERSION
		changed = true
	return changed

## 地图文件路径；名称非法时返回 ""（调用方必须检查）
static func path_for(m: Dictionary, name: String) -> String:
	return ManifestScript.map_path(m, name)

## 读地图 JSON；不存在/非法/解析失败都返回 {}
static func read(m: Dictionary, name: String) -> Dictionary:
	var result := read_path(path_for(m, name), m)
	var data = result.data if result.ok else {}
	return data

## 写地图 JSON；名称非法或写盘失败返回 false
## 正式保存轮转备份——写前把当前文件拷进 <maps_dir>/.history/<名>.json.1..3（.1 最新）。
## 无 git 环境的最后保险；autosave/levels/事务写盘不进历史（各有机制）。
const HISTORY_DEPTH := 3

static func write(m: Dictionary, name: String, data: Dictionary) -> bool:
	var path := path_for(m, name)
	if path == "":
		return false
	_rotate_history(path)
	return write_json(path, data)

## 轮转 .3←.2←.1←当前（copy 当前而非 rename：备份失败绝不阻断保存本身）
## 内容文件也要同样的回滚保险（内容条目是可复用资产），所以开放成公开入口。
static func rotate_history(path: String) -> void:
	_rotate_history(path)

static func _rotate_history(path: String) -> void:
	var dir := path.get_base_dir().path_join(".history")
	DirAccess.make_dir_recursive_absolute(dir)
	var base := path.get_file()
	for i in range(HISTORY_DEPTH, 1, -1):
		var src := dir.path_join(base + "." + str(i - 1))
		var dst := dir.path_join(base + "." + str(i))
		if FileAccess.file_exists(src):
			if FileAccess.file_exists(dst):
				DirAccess.remove_absolute(dst)
			DirAccess.rename_absolute(src, dst)
	if not FileAccess.file_exists(path):
		return
	var h1 := dir.path_join(base + ".1")
	if FileAccess.file_exists(h1):
		DirAccess.remove_absolute(h1)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var buf := f.get_buffer(f.get_length())
	f.close()
	if not _write_bytes(h1, buf):
		return  # 备份失败不阻断保存；下次保存再试

## 地图域 JSON 写盘单入口——先写 .tmp 再原子替换，中途崩溃不会留下半截 JSON。
## save / autosave / levels.json / 清单导出等所有项目数据写盘都走这里。
static func write_json(path: String, data: Dictionary) -> bool:
	return write_text(path, JSON.stringify(data, "\t"))

static func write_text(path: String, text: String) -> bool:
	var tmp := path + ".tmp"
	if not _write_bytes(tmp, text.to_utf8_buffer()):
		return false
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return false
	_cache.erase(path)   # 写后失效，下次读回源
	# 任何项目数据落盘都可能改变实体 id 引用（地图 props / 内容步骤）：
	# 版本号 +1；画布的引用集缓存以 project_rev 为失效锚点（经参数传入，避免循环 preload）。
	project_rev += 1
	return true

## 多地图协调写入：先暂存所有新内容和原文件备份，再逐个替换。
## OS 不提供跨文件原子提交；任一替换失败时尽力恢复已提交文件并报告回滚结果。
static func write_transaction(m: Dictionary, updates: Dictionary) -> Dictionary:
	if updates.is_empty():
		return {"ok": true, "rollback_ok": true, "failed_map": ""}
	var txid := str(Time.get_ticks_usec())
	var entries: Array[Dictionary] = []
	var seen_paths := {}
	for map_name in updates:
		var name := str(map_name)
		var path := path_for(m, name)
		if path == "" or seen_paths.has(path):
			return {"ok": false, "rollback_ok": true, "failed_map": name, "error": "invalid or duplicate map path"}
		seen_paths[path] = true
		var entry := {"name": name, "path": path, "stage": path + ".txn-" + txid + ".tmp",
			"backup": path + ".txn-" + txid + ".bak", "existed": FileAccess.file_exists(path)}
		if entry.existed:
			var read_file := FileAccess.open(path, FileAccess.READ)
			if read_file == null:
				_cleanup_transaction(entries)
				return {"ok": false, "rollback_ok": true, "failed_map": name, "error": "cannot read original map"}
			var original := read_file.get_buffer(read_file.get_length())
			read_file.close()
			if not _write_bytes(str(entry.backup), original):
				entries.append(entry)
				_cleanup_transaction(entries)
				return {"ok": false, "rollback_ok": true, "failed_map": name, "error": "cannot stage backup"}
		var content := JSON.stringify(updates[map_name], "\t").to_utf8_buffer()
		if not _write_bytes(str(entry.stage), content):
			entries.append(entry)
			_cleanup_transaction(entries)
			return {"ok": false, "rollback_ok": true, "failed_map": name, "error": "cannot stage map"}
		entries.append(entry)

	var committed: Array[Dictionary] = []
	for entry in entries:
		var err := DirAccess.rename_absolute(str(entry.stage), str(entry.path))
		if err != OK:
			var rollback_ok := _rollback_transaction(committed)
			_cleanup_transaction(entries)
			return {"ok": false, "rollback_ok": rollback_ok, "failed_map": str(entry.name),
				"error": "map replacement failed: " + error_string(err)}
		committed.append(entry)
	_cleanup_transaction(entries)
	return {"ok": true, "rollback_ok": true, "failed_map": ""}

static func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	return ok

static func _rollback_transaction(committed: Array[Dictionary]) -> bool:
	var ok := true
	for i in range(committed.size() - 1, -1, -1):
		var entry: Dictionary = committed[i]
		var path := str(entry.path)
		if bool(entry.existed):
			var backup_file := FileAccess.open(str(entry.backup), FileAccess.READ)
			if backup_file == null:
				ok = false
				continue
			var backup := backup_file.get_buffer(backup_file.get_length())
			backup_file.close()
			if not _write_bytes(path, backup):
				ok = false
		else:
			if FileAccess.file_exists(path) and DirAccess.remove_absolute(path) != OK:
				ok = false
	return ok

static func _cleanup_transaction(entries: Array[Dictionary]) -> void:
	for entry in entries:
		_cache.erase(str(entry.get("path", "")))   # 事务落盘后失效对应缓存
		for key in ["stage", "backup"]:
			var path := str(entry.get(key, ""))
			if path != "" and FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)

## 在地图数据里按实体 id 查找；返回空字典表示没有
static func find_entity(data: Dictionary, ent_id: String) -> Dictionary:
	for ent in data.get("entities", []):
		if ent is Dictionary and str(ent.get("id", "")) == ent_id:
			return ent
	return {}

## 已有地图名列表（不含扩展名，排序）
static func list_maps(m: Dictionary) -> Array:
	var out := []
	var dir := DirAccess.open(str(m.get("_maps_dir", "")))
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".json") and not f.ends_with(".autosave.json"):
			out.append(f.get_basename())
	out.sort()
	return out

## 纯 rename——只改文件名，不迁移引用（拍板：改名不迁移）。
## 返回错误信息；"" = 成功。
static func rename_map(m: Dictionary, old_name: String, new_name: String) -> String:
	new_name = new_name.strip_edges()
	if not ManifestScript.is_valid_map_name(new_name):
		return "名称非法"
	if old_name == new_name:
		return ""
	if FileAccess.file_exists(path_for(m, new_name)):
		return "同名地图已存在"
	var src := path_for(m, old_name)
	if src == "" or not FileAccess.file_exists(src):
		return "原图不存在"
	var dst := path_for(m, new_name)
	if DirAccess.rename_absolute(src, dst) != OK:
		return "文件系统重命名失败"
	_cache.erase(src)
	_cache.erase(dst)
	return ""

## 复制地图文件（新名冲突拒绝）；内容原样复制，引用不动。
static func duplicate_map(m: Dictionary, old_name: String, new_name: String) -> String:
	new_name = new_name.strip_edges()
	if not ManifestScript.is_valid_map_name(new_name):
		return "名称非法"
	if old_name == new_name:
		return "同名地图已存在"
	if FileAccess.file_exists(path_for(m, new_name)):
		return "同名地图已存在"
	var src := path_for(m, old_name)
	if src == "" or not FileAccess.file_exists(src):
		return "原图不存在"
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return "原图读取失败"
	var buf := f.get_buffer(f.get_length())
	f.close()
	if not _write_bytes(path_for(m, new_name), buf):
		return "复制写盘失败"
	_cache.erase(path_for(m, new_name))
	return ""

## 读所有地图 → {地图名: data}。坏图（无法读取/JSON 解析失败/非对象）不进结果，
## 但记录进 bad_out（坏图不再对校验页/世界页隐身）。读取走 mtime 缓存。
static func read_all(m: Dictionary, bad_out: Array = []) -> Dictionary:
	var out := {}
	for name in list_maps(m):
		var path := path_for(m, name)
		if path == "" or not FileAccess.file_exists(path):
			continue
		var data := _read_cached(path, m)
		if data.is_empty():
			bad_out.append({"name": name, "reason": "无法读取或校验失败"})
			continue
		out[name] = data
	return out
