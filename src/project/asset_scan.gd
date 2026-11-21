extends RefCounted
## AssetScan：资产零登记扫描器（2026-11-21 用户模型：文件夹约定 = 注册表，打开项目时扫描）。
## 身份与改名口径见 sync() 前的注释块；这里只留目录约定：
##   assets/tiles/    图片 → 瓦片图集资产（scene / shape=tile）
##   assets/images/   图片 → 图片摆放资产（scene / shape=image）
##   assets/entities/ .tscn → 实体资产（kind=entity）
##   子文件夹递归；图片扩展名 png/jpg/jpeg/webp/bmp/tga（Image.load_from_file 原生可读）。
##   手写清单条目零兼容：约定目录之外的条目扫描完全不碰。
##   变化随下次清单保存落盘（manifest 加载链的 _codes_issued 标记位）。

const ContentId := preload("res://src/content/content_id.gd")
const IMG_EXT := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]

## 扫描同步：diff 约定目录与清单 assets[]：新文件补条目发码、改名重链、消失标缺失。
## 返回 {added: [资产id...], missing: [资产id...], renamed: 重链数}。
static func sync(m: Dictionary) -> Dictionary:
	var root := str(m.get("_dir", ""))
	var out := {"added": [], "missing": [], "renamed": 0}
	if root == "":
		return out
	var found := {}   # 相对路径 → {kind, shape, stem, md5}
	_walk(root.path_join("assets/tiles"), root, "scene", "tile", found)
	_walk(root.path_join("assets/images"), root, "scene", "image", found)
	_walk(root.path_join("assets/entities"), root, "entity", "", found)
	if not (m.get("assets", null) is Array):
		m["assets"] = []
	var assets: Array = m.get("assets", [])
	# 改名重链基础：本轮发现文件里还没被条目指向的（md5 → 相对路径）
	var free_files := {}
	for rel in found:
		free_files[str((found[rel] as Dictionary).md5)] = rel
	var prev_hashes: Dictionary = m.get("_scan_hashes", {})
	# 先重链再补新：重链消费掉的文件不再发新条目；约定目录之外的条目扫描不碰。
	for a in assets:
		if not (a is Dictionary):
			continue
		var rel := _rel_of(a)
		if rel == "" or found.has(rel):
			continue
		if FileAccess.file_exists(root.path_join(rel)):
			continue
		var old_md5 := str(prev_hashes.get(rel, ""))
		if old_md5 != "" and free_files.has(old_md5):
			_set_rel(a, str(free_files[old_md5]))
			free_files.erase(old_md5)
			out["renamed"] = int(out["renamed"]) + 1
		else:
			out["missing"].append(str(a.get("id", "")))
	# 新文件补条目：id = 新发码，name = 文件名；实体条目 id 与实体码段同值。
	for rel in found:
		# 未命中返回 {} 不是 null：{} != null 恒真，按 != null 判会把新文件全跳掉
		if not _entry_with_rel(assets, rel).is_empty():
			continue
		if not free_files.has(str((found[rel] as Dictionary).md5)):
			continue
		var info: Dictionary = found[rel] as Dictionary
		var stem := str(info.stem)
		var code := ContentId.new_asset_code()
		var e := {"id": code, "name": stem}
		if str(info.kind) == "entity":
			e["kind"] = "entity"
			e["prefab"] = rel
			e["code"] = code
		elif str(info.shape) == "tile":
			e["kind"] = "scene"
			e["shape"] = "tile"
			e["atlas"] = rel
		else:
			e["kind"] = "scene"
			e["shape"] = "image"
			e["texture"] = rel
		assets.append(e)
		out["added"].append(code)
	m["_scan_hashes"] = _hashes_of(found)
	return out

## 递归收集目录下的资产文件；rel = 相对工程根路径（/ 分隔）
static func _walk(abs_dir: String, root: String, kind: String, shape: String, found: Dictionary) -> void:
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if dir.current_is_dir():
			if not f.begins_with("."):
				_walk(abs_dir.path_join(f), root, kind, shape, found)
		else:
			var ext := f.get_extension().to_lower()
			var ok: bool = ext == "tscn" if kind == "entity" else IMG_EXT.has(ext)
			if ok:
				var rel := abs_dir.path_join(f).substr(root.length()).replace("\\", "/").lstrip("/")
				found[rel] = {"kind": kind, "shape": shape, "stem": f.get_basename(),
					"md5": str(FileAccess.get_md5(abs_dir.path_join(f)))}
		f = dir.get_next()
	dir.list_dir_end()

## 条目指向的相对路径（atlas / texture / prefab 三选一）
static func _rel_of(a: Dictionary) -> String:
	for key in ["atlas", "texture", "prefab"]:
		var v := str(a.get(key, ""))
		if v != "":
			return v.replace("\\", "/")
	return ""

static func _set_rel(a: Dictionary, rel: String) -> void:
	for key in ["atlas", "texture", "prefab"]:
		if a.has(key):
			a[key] = rel
			return

## 指向 rel 的条目（无则空字典）
static func _entry_with_rel(assets: Array, rel: String) -> Dictionary:
	for a in assets:
		if a is Dictionary and _rel_of(a) == rel:
			return a
	return {}

static func _hashes_of(found: Dictionary) -> Dictionary:
	var out := {}
	for rel in found:
		out[rel] = str((found[rel] as Dictionary).md5)
	return out
