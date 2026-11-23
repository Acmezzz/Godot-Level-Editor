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

## 扫描同步（A4）：diff 约定目录与清单 assets[]。
## 身份规则：
##   1. 路径仍在扫描目录的条目 → 原位保留（含停用记录）；
##   2. 路径消失但指纹在别处唯一命中（同类、同指纹、且该文件未被任何条目占用）
##      → 一对一重链，ID 不变；候选有歧义 → 保留旧 ID 与候选路径，记为待确认；
##   3. 真消失 → 保留条目与 ID，标记 retired（停用）+ 原路径，可恢复；
##   4. 新文件 → 新发码。
## 返回 {added, missing, renamed, retired, ambiguous, changes}。changes = 是否改过清单。
static func sync(m: Dictionary) -> Dictionary:
	var root := str(m.get("_dir", ""))
	var out := {"added": [], "missing": [], "renamed": 0, "retired": [], "ambiguous": [], "changes": false}
	if root == "":
		return out
	var found := {}   # 相对路径 → {kind, shape, stem, md5}
	_walk(root.path_join("assets/tiles"), root, "scene", "tile", found)
	_walk(root.path_join("assets/images"), root, "scene", "image", found)
	_walk(root.path_join("assets/entities"), root, "entity", "", found)
	if not (m.get("assets", null) is Array):
		m["assets"] = []
	var assets: Array = m.get("assets", [])
	# 指纹索引：md5 → [rel...]（同类判定在下面按条目 kind/shape 过滤）
	var by_md5 := {}
	for rel in found:
		var md5 := str((found[rel] as Dictionary).md5)
		if not by_md5.has(md5):
			by_md5[md5] = []
		(by_md5[md5] as Array).append(rel)
	# 被条目占用的文件：重链/新条目都不许再分给别的条目（一对一）。
	var claimed := {}
	# 歧义候选也先占住——用户确认前把候选文件再发一份新 ID，会得到两份指向同一文件的资产。
	# 这里只挡「新条目」，不挡条目自己再解析候选（否则歧义永远无法重新判断）。
	var reserved := {}
	for a in assets:
		if a is Dictionary:
			var r0 := _rel_of(a)
			if r0 != "":
				claimed[r0] = true
			var raw_c = (a as Dictionary).get("relinkCandidates", [])
			if raw_c is PackedStringArray or raw_c is Array:
				for c0 in raw_c:
					reserved[str(c0)] = true
	# —— 先处理消失/改名 ——
	for a in assets:
		if not (a is Dictionary):
			continue
		# 用户在图鉴里删掉的扫描资产：保留条目与 ID 作停用记录（D12）。
		# 文件仍在约定目录时尤其重要——否则下次扫描会把它当新文件再发一个 ID。
		if bool((a as Dictionary).get("disabled", false)):
			continue
		var rel := _rel_of(a)
		if rel == "":
			continue
		if found.has(rel):
			# 文件在原位：停用记录自动解除（文件回来了，原引用直接生效）。
			if (a as Dictionary).has("retired") or (a as Dictionary).has("retiredPath") \
					or (a as Dictionary).has("relinkCandidates"):
				(a as Dictionary).erase("retired")
				(a as Dictionary).erase("retiredPath")
				(a as Dictionary).erase("relinkCandidates")
				out["changes"] = true
			continue
		if FileAccess.file_exists(root.path_join(rel)):
			continue   # 文件真实存在（约定目录之外）：不碰
		# 手写条目（约定目录之外、且没有我们发的指纹）：扫描不接管它的身份，
		# 但缺失要让审计看得见（区分「仍存在」与「已缺失」）。
		var fp := str((a as Dictionary).get("scanFingerprint", ""))
		if fp == "" and not _under_scan_dir(rel):
			(out["missing"] as Array).append(str((a as Dictionary).get("id", "")))
			continue
		var cands: Array = []
		if fp != "" and by_md5.has(fp):
			for c in (by_md5[fp] as Array):
				var cr := str(c)
				if claimed.has(cr):
					continue
				if _compatible(a, found[cr] as Dictionary):
					cands.append(cr)
		if cands.size() == 1:
			var newrel := str(cands[0])
			_set_rel(a, newrel)
			claimed[newrel] = true
			# 停用记录在重链后失效（文件找到了）
			(a as Dictionary).erase("retired")
			(a as Dictionary).erase("retiredPath")
			(a as Dictionary).erase("relinkCandidates")
			out["renamed"] = int(out["renamed"]) + 1
			out["changes"] = true
		elif cands.size() > 1:
			# 有歧义：保留旧 ID 与候选路径，等人工确认（不猜）。
			# 候选集没变就别反复报——每次加载都算「变更」会每次都让清单脏。
			var prev: Array = []
			var raw_prev = (a as Dictionary).get("relinkCandidates", [])
			if raw_prev is PackedStringArray or raw_prev is Array:
				for p in raw_prev:
					prev.append(str(p))
			if bool((a as Dictionary).get("retired", false)) and prev == cands \
					and str((a as Dictionary).get("retiredPath", "")) == rel:
				# 状态没变：不弄脏清单，但报告里继续列出（界面每次加载都能提示）
				(out["ambiguous"] as Array).append({"id": str((a as Dictionary).get("id", "")), "candidates": cands})
				continue
			(a as Dictionary)["retiredPath"] = rel
			(a as Dictionary)["relinkCandidates"] = PackedStringArray(cands)
			(a as Dictionary)["retired"] = true
			# 候选文件占住：确认前不能再给它们发新 ID（否则同一文件两份资产）
			for c1 in cands:
				reserved[str(c1)] = true
			(out["ambiguous"] as Array).append({"id": str((a as Dictionary).get("id", "")), "candidates": cands})
			out["changes"] = true
		else:
			if bool((a as Dictionary).get("retired", false)) and str((a as Dictionary).get("retiredPath", "")) == rel \
					and not (a as Dictionary).has("relinkCandidates"):
				# 已停用且路径没再变：不重复报变更（报告里仍列出，界面可继续提示）
				(out["retired"] as Array).append(str((a as Dictionary).get("id", "")))
				continue
			(a as Dictionary)["retired"] = true
			(a as Dictionary)["retiredPath"] = rel
			(a as Dictionary).erase("relinkCandidates")
			out["missing"].append(str((a as Dictionary).get("id", "")))
			(out["retired"] as Array).append(str((a as Dictionary).get("id", "")))
			out["changes"] = true
	# —— 再补新条目 ——
	for rel in found:
		if claimed.has(str(rel)) or reserved.has(str(rel)):
			continue
		var info: Dictionary = found[rel] as Dictionary
		var stem := str(info.stem)
		var code := ContentId.new_asset_code()
		var e := {"id": code, "name": stem, "scanFingerprint": str(info.md5)}
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
		claimed[str(rel)] = true
		(out["added"] as Array).append(code)
		out["changes"] = true
	# —— 指纹补齐：原位条目缺 scanFingerprint 时按当前文件补（只补不改身份） ——
	for a in assets:
		if not (a is Dictionary):
			continue
		var r := _rel_of(a)
		if r == "" or not found.has(r):
			continue
		if str((a as Dictionary).get("scanFingerprint", "")) == "":
			(a as Dictionary)["scanFingerprint"] = str((found[r] as Dictionary).md5)
			out["changes"] = true
	m["_scan_report"] = out
	return out

## 相对路径是否位于扫描约定目录之下
static func _under_scan_dir(rel: String) -> bool:
	var r := rel.replace("\\", "/")
	return r.begins_with("assets/tiles/") or r.begins_with("assets/images/") or r.begins_with("assets/entities/")

## 删除扫描资产（D12）：不 erase 条目，改记 disabled + 原 ID + 原路径。
## 文件还在约定目录里时，扫到它也不复活；引用仍按原 ID 解析得到「已停用」。
static func disable(m: Dictionary, aid: String) -> bool:
	for a in (m.get("assets", []) as Array):
		if a is Dictionary and str((a as Dictionary).get("id", "")) == aid:
			var rel := _rel_of(a)
			(a as Dictionary)["disabled"] = true
			if rel != "":
				(a as Dictionary)["retiredPath"] = rel
			(a as Dictionary).erase("retired")
			(a as Dictionary).erase("relinkCandidates")
			return true
	return false

## 反向：恢复被删除/停用的条目（清 disabled，若文件在原位再清停用记录）。
static func enable(m: Dictionary, aid: String) -> bool:
	for a in (m.get("assets", []) as Array):
		if a is Dictionary and str((a as Dictionary).get("id", "")) == aid:
			(a as Dictionary).erase("disabled")
			(a as Dictionary).erase("retired")
			(a as Dictionary).erase("retiredPath")
			(a as Dictionary).erase("relinkCandidates")
			return true
	return false

## 条目与候选文件是否同类（scene/tile、scene/image、entity 三种，形状必须一致）。
static func _compatible(a: Dictionary, info: Dictionary) -> bool:
	var ak := str(a.get("kind", "scene"))
	var ik := str(info.get("kind", "scene"))
	if ak != ik:
		return false
	if ak == "scene":
		return str(a.get("shape", "tile")) == str(info.get("shape", "tile"))
	return true

## 恢复停用条目：按 id 清掉 retired 标记（文件回来时或用户手动确认后调用）。
static func restore(m: Dictionary, aid: String) -> bool:
	for a in (m.get("assets", []) as Array):
		if a is Dictionary and str((a as Dictionary).get("id", "")) == aid:
			(a as Dictionary).erase("retired")
			(a as Dictionary).erase("retiredPath")
			(a as Dictionary).erase("relinkCandidates")
			return true
	return false

## 确认歧义重链：把条目指到候选路径之一（用户选择），清停用状态。
## 逐条局部唯一（V4 P1）：同一文件不能再被第二份资产认领——否则两条资产各自解析、
## 扫描下次还会把其中一条判成重复。已被别人占用的路径直接拒绝（返回 false）。
static func confirm_relink(m: Dictionary, aid: String, rel: String) -> bool:
	var want := rel.replace("\\", "/")
	for other in (m.get("assets", []) as Array):
		if not (other is Dictionary) or str((other as Dictionary).get("id", "")) == aid:
			continue
		if _rel_of(other as Dictionary) == want:
			return false
	for a in (m.get("assets", []) as Array):
		if a is Dictionary and str((a as Dictionary).get("id", "")) == aid:
			_set_rel(a, rel)
			(a as Dictionary).erase("retired")
			(a as Dictionary).erase("retiredPath")
			(a as Dictionary).erase("relinkCandidates")
			return true
	return false

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

