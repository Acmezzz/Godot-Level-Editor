extends RefCounted
## 地图 JSON 数据层：名称校验后的读写、mtime+尺寸缓存、实体查找、改名、整图复制。
## **改名与复制不是一回事**：rename_map 是**纯 rename**（只换文件名，不迁移任何引用——
## 跨图引用写的是地图码，所以本来就不破）；duplicate_map 是**整图复制**，会发新实例码/内容 ID、
## 重映射组内引用、为目标图重发地图码，并按 A2 顺序先写内容后写地图。
## 以静态函数为主，带少量静态状态：_cache（读缓存）与 project_rev（写盘版本号，派生缓存据此重扫）。
## write_text/write_json 先写临时文件再替换。内容文件轮转深度见 EDITOR_FEATURES §7.3。
## manifest 除取 _maps_dir 外，还随读取传入 map_data_validation 做结构校验（查实体类型/功能声明）。
## 注意：路径引用（preload）而非全局类名，避免 headless 首次扫描时的 class_name 缓存问题。

const ManifestScript := preload("res://src/project/manifest.gd")
const MapValidator := preload("res://src/map/map_data_validation.gd")
const MapFormat := preload("res://src/map/map_format.gd")
const ContentId := preload("res://src/content/content_id.gd")

## 当前地图数据格式版本（常量在 map_format.gd：校验器也要读，反向 preload 会成环）。
const FORMAT_VERSION := MapFormat.VERSION
## 项目数据写盘版本号：每次 write_text 成功 +1。派生缓存（实体引用集等）据此判断是否重扫。
static var project_rev := 0

## ---- 地图数据 mtime+尺寸缓存（read_all 复用） ----
## 刷新链/校验/引用扫描一个会话里反复 read_all——按文件 mtime+size 缓存；
## write_text 等写路径各自维护一致性（写后失效，下次读回源）。read() 单图直读不走缓存。
static var _cache := {}   # path -> {mtime: int, data: Dictionary}

## 按缓存读单图；读失败不缓存（下次重读）
## mtime 是秒级粒度，同秒内外部改文件会被脏缓存吃掉。缓存键补上文件长度——
## 尺寸变了必然重读；同秒且同尺寸的改动仍无法识别（自写路径有显式失效，只影响外部编辑器）。
static func _read_cached(path: String, m: Dictionary, manifest_hash: int) -> Dictionary:
	var mt := FileAccess.get_modified_time(path)
	var sz := _file_size(path)
	var hit = _cache.get(path, null)
	if (hit != null and int(hit.get("mtime", -1)) == mt and int(hit.get("size", -1)) == sz
			and hit.get("manifest_hash", -1) == manifest_hash):
		return hit.get("data", {})
	var result := read_path(path, m)
	if result.ok:
		_cache[path] = {"mtime": mt, "size": sz, "manifest_hash": manifest_hash, "data": result.data}
	return result.data if result.ok else {}

static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n

## R29：人工刷新入口——外部工具同秒同长度改写地图时，浏览缓存（mtime+size）可能拿旧结构；
## 正式写入路径各自失效或直读。需要看到磁盘最新结构时（脚本/诊断）调用它强制重扫。
static func invalidate_read_cache() -> void:
	_cache.clear()
	invalidate_code_map()

## 校验原始地图后再更新内存中的格式版本。
static func decode_text(text: String, source := "", manifest := {}) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		return {"ok": false, "data": {}, "errors": [{"path": source, "message": "JSON must be an object"}], "warnings": [], "migrated": false}
	var data: Dictionary = json.data
	var errors: Array[Dictionary] = []
	var warnings: Array[Dictionary] = []
	for issue in MapValidator.validate(data, manifest, false):
		if str(issue.severity) == "error":
			errors.append(issue)
		else:
			warnings.append(issue)
	var ok := errors.is_empty()
	return {"ok": ok, "data": data if ok else {},
		"errors": errors, "warnings": warnings, "migrated": upgrade(data) if ok else false}

static func read_path(path: String, manifest := {}) -> Dictionary:
	var observed := Recovery.observe(path)
	if observed.state != "present":
		var message := "file not found" if observed.state == "missing" else "file cannot be opened"
		return {"ok": false, "data": {}, "errors": [{"path": path, "message": message}], "warnings": [], "migrated": false}
	var result := decode_text(observed.text, path, manifest)
	result["digest"] = observed.digest
	return result

## 升级地图数据到当前格式；返回是否改动。
## v4 起零兼容：旧格式（terrain/decor 顶层键、无 meta.layers、浮点坐标）一律不迁移，
## 只把版本号抬到当前值，结构问题交 validate 报错拒绝。
static func upgrade(data: Dictionary) -> bool:
	var ver := int(data.get("version", 1))
	if ver >= FORMAT_VERSION:
		return false
	data["version"] = FORMAT_VERSION
	return true

## 新建地图模板：两层用户层栈（「资产层」+「FL」，底→顶，层码用 ContentId 发放），
## tiles/collision/objects 均空。新建地图入口用它组装，保证 meta.layers 从出生就是当前契约。
## `proj` = 逐图格投影（B1）："" = 沿用项目默认（不写键）；显式选择（含正交）原样写盘。
## `topo` = 格拓扑（B3）：triangles 写 meta.gridTopology；quads 缺省不写键。
static func new_map(name: String, w: int, h: int, proj := "", topo := "") -> Dictionary:
	var meta := {
		"code": allocate_code({}),
		"name": name,
		"w": w,
		"h": h,
		"layers": [
			{"id": ContentId.new_inst_code(), "name": "资产层", "visible": true},
			{"id": ContentId.new_inst_code(), "name": "FL", "visible": true},
		],
	}
	# R17：显式选择必须原样落盘。缺键才是「沿用项目默认」——面板里亲手点「正交」
	# 与「不选投影」是两种意图，在非正交默认项目里不能都变成同一结果。
	if proj == "orthogonal" or proj == "isometric" or proj == "hexagonal":
		meta["gridProjection"] = proj
	# B3：三角拓扑（缺省 quads 不写冗余键）；hex 没有平行四边形列，组合不成立
	if topo == "triangles" and proj != "hexagonal":
		meta["gridTopology"] = "triangles"
	return {
		"version": FORMAT_VERSION,
		"meta": meta,
		"spawn": [2, 2],
		"tiles": {},
		"collision": [],
		"objects": [],
	}

## —— 地图码（v7）：meta.code 4 位码，项目内唯一。跨图引用（target_map / map_ref 字段）写码，
## 改名（文件名/显示名）不再破坏引用——与实例码/功能码同一身份原则，地图不再是「以名为身份」的例外。

## 全项目地图码索引。一次扫描同时给出四张视图，避免 code_map / code_conflicts /
## 引用解析各扫一遍盘（§5「引用扫描反复读盘」：原先每个引用要读全部地图文件两次）：
##   by_name {图名: 码}；by_code {码: [图名...]}；map {唯一的码: 图名}。
##   unreadable [图名]（文件在、但读不出或结构校验不过 → 引用解析报 unreadable 而非 missing）
##   names [图名]（目录里的全部地图，含读不出的）
## 按清单和地图目录缓存；编辑器写盘、应用回焦和关键查询显式失效，
## 绘制出口角标时复用索引，不反复枚举全项目。
static var _ci_cache := {}
static var _ci_key := "__never__"

## 写盘/改名/删除后调用：下次 code_index 必重算（不依赖 mtime 粒度）。
static func invalidate_code_map() -> void:
	_ci_key = "__never__"

static func refresh_external_maps() -> void:
	invalidate_read_cache()

static func code_index(m: Dictionary) -> Dictionary:
	var manifest_hash := m.hash()
	var key := "%s:%s" % [m.get("_maps_dir", ""), manifest_hash]
	if _ci_key == key:
		return _ci_cache
	var names := list_maps(m)
	var by_name := {}
	var by_code := {}
	var unreadable: Array = []
	var paths := {}
	for mn in names:
		var n := str(mn)
		var path := path_for(m, n)
		paths[path] = true
		var md := _map_snapshot(m, n, path, manifest_hash)
		if md.is_empty():
			# 图名在目录里但内容读不出（坏 JSON / 校验不过）：不是「没有这张图」
			unreadable.append(n)
			continue
		var c := str((md.get("meta", {}) as Dictionary).get("code", ""))
		if c == "":
			continue
		by_name[n] = c
		if not by_code.has(c):
			by_code[c] = []
		(by_code[c] as Array).append(n)
	var unique := {}
	for code in by_code:
		if by_code[code].size() == 1:
			unique[code] = by_code[code][0]
	_ci_cache = {"by_name": by_name, "by_code": by_code, "map": unique,
		"unreadable": unreadable, "names": names, "paths": paths}
	_ci_key = key
	return _ci_cache

static func code_map(m: Dictionary) -> Dictionary:
	return code_index(m).get("map", {}) as Dictionary

## 签名：图名清单 + 每图 mtime（不 open 文件）。图名清单抓新增/删除/改名，
## mtime 抓内容改动；同秒内的原地改写由写路径的 invalidate_code_map 兜住。
## 每个可读文件的地图码；重复码也保留，以便解析时明确报告冲突。
static func name_to_code(m: Dictionary) -> Dictionary:
	return code_index(m).by_name

## 确保这张图有 meta.code：缺就发一个不与全项目冲突的新码并写回 data。
## 返回是否有改动（调用方据此置脏）。就地修改。
## 占用表直接扫全部地图文件（含重复码的影子条目），不只信 code_map 的「一码一图」（D08）。
static func ensure_code(m: Dictionary, data: Dictionary) -> bool:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	if str(meta.get("code", "")) != "":
		return false
	meta["code"] = allocate_code(m)
	data["meta"] = meta
	return true

static func allocate_code(m: Dictionary, extra_occupied := "") -> String:
	var taken: Dictionary = code_index(m).by_code if str(m.get("_maps_dir", "")) != "" else {}
	var code := ContentId.new_map_code()
	while taken.has(code) or code == extra_occupied:
		code = ContentId.new_map_code()
	return code

static func identity_error(m: Dictionary, name: String, data: Dictionary, move_from := "") -> String:
	refresh_external_maps()
	return identity_error_in(code_index(m).by_code, name, data, move_from)

static func identity_error_in(by_code: Dictionary, name: String, data: Dictionary, move_from := "") -> String:
	var code := str(data.get("meta", {}).get("code", ""))
	if code == "":
		return ""
	var matches := PackedStringArray()
	for other in by_code.get(code, []):
		if other != name and other != move_from:
			matches.append(str(other))
	if matches.is_empty():
		return ""
	return "地图码 %s 已由其他地图使用：%s" % [code, "、".join(matches)]

## 项目内的重复地图码及冲突文件。
static func code_conflicts(m: Dictionary) -> Dictionary:
	var by_code: Dictionary = code_index(m).get("by_code", {})
	var out := {}
	for c in by_code:
		if (by_code[c] as Array).size() > 1:
			out[c] = by_code[c]
	return out

## 地图文件路径；名称非法时返回 ""（调用方必须检查）
static func path_for(m: Dictionary, name: String) -> String:
	return ManifestScript.map_path(m, name)

## 读地图 JSON；不存在/非法/解析失败都返回 {}
static func read(m: Dictionary, name: String) -> Dictionary:
	if m.get("_map_overrides", {}).has(name):
		return m._map_overrides[name].duplicate(true)
	var result := read_path(path_for(m, name), m)
	var data = result.data if result.ok else {}
	return data

## 写地图 JSON；名称非法、写入前校验失败或写盘失败均返回 false。
const Recovery := preload("res://src/map/recovery.gd")
const HISTORY_DEPTH := 3

static func write(m: Dictionary, name: String, data: Dictionary, move_from := "") -> bool:
	var path := path_for(m, name)
	if path == "":
		return false
	# 写前校验序列化结果（D11）：坏图（层栈空/瓦片元组错/退役键）不落盘覆盖好文件。
	if not validate_for_write(data, m) or identity_error(m, name, data, move_from) != "":
		return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if FileAccess.file_exists(path):
		rotate_history(path)
	if not write_text(path, MapFormat.encode(data)):
		return false
	invalidate_code_map()
	return true

## 校验待写文档；返回首个错误文本，"" = 通过。
static func write_error(m: Dictionary, data: Dictionary) -> String:
	for issue in MapValidator.validate(data, m):
		if str(issue.severity) == "error":
			return "%s: %s" % [str(issue.path), str(issue.message)]
	return ""

static func validate_for_write(data: Dictionary, m: Dictionary) -> bool:
	return write_error(m, data) == ""

## 轮转 .3←.2←.1←当前（copy 当前而非 rename：备份失败绝不阻断保存本身）
## 内容文件也要同样的回滚保险（内容条目是可复用资产），所以开放成公开入口。
## 返回值 = **当前文件的快照此刻确实存在**（`.1`）。保存路径可以忽略（备份失败不拦保存）；
## 删除路径必须看它——删掉就没有「当前」可再备份，所以删除前要先确认拿到了这份快照。
static func rotate_history(path: String) -> bool:
	return _rotate_history(path)

static func _rotate_history(path: String) -> bool:
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
	var h1 := dir.path_join(base + ".1")
	if not FileAccess.file_exists(path):
		return true   # 没有当前文件 = 无可备份（幂等路径）
	if FileAccess.file_exists(h1):
		DirAccess.remove_absolute(h1)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var buf := f.get_buffer(f.get_length())
	f.close()
	if not _write_bytes(h1, buf):
		return false  # 备份失败不阻断保存；下次保存再试
	return FileAccess.file_exists(h1)

## 地图域 JSON 写盘单入口——先写 .tmp 再原子替换，中途崩溃不会留下半截 JSON。
## save / autosave / 内容文件 / 导出清单等所有项目数据写盘都走这里。
static func write_json(path: String, data: Dictionary) -> bool:
	return write_text(path, JSON.stringify(data, "\t"))

## 测试注入（生产恒为空）：命中前缀的写盘直接失败。唯一临时名上线后，
## 「占用固定 .tmp 路径」已无法稳定注入写失败，写失败用例改走这里。
static var test_fail_prefix := ""

static func write_text(path: String, text: String) -> bool:
	if test_fail_prefix != "" and path.begins_with(test_fail_prefix):
		return false
	if not Recovery.write_text(path, text):
		return false
	_cache.erase(path)
	if _ci_cache.get("paths", {}).has(path):
		invalidate_code_map()
	# 任何项目数据落盘都可能改变实体 id 引用（地图 props / 内容步骤）：
	# 版本号 +1；画布的引用集缓存以 project_rev 为失效锚点（经参数传入，避免循环 preload）。
	project_rev += 1
	return true

static func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	return ok

## 已有地图名列表（不含扩展名，排序）。
## `foo.autosave.json` 只有在带 `_autosave_of` 时才是旧式草稿（跳过）；
## 缺标记的是普通地图（图名就叫 foo.autosave），必须列出（A3）。
static func list_maps(m: Dictionary) -> Array:
	var out := []
	var dir := DirAccess.open(str(m.get("_maps_dir", "")))
	for f in (dir.get_files() if dir != null else PackedStringArray()):
		if not f.ends_with(".json"):
			continue
		if f.ends_with(".autosave.json") and _is_legacy_draft(str(m.get("_maps_dir", "")).path_join(f)):
			continue
		out.append(f.get_basename())
	var overrides: Dictionary = m.get("_map_overrides", {})
	for name in overrides:
		if overrides[name].is_empty():
			out.erase(name)
		elif not out.has(name):
			out.append(name)
	out.sort()
	return out

static func _is_legacy_draft(path: String) -> bool:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return false   # 读不出就别猜：按普通地图处理，交给读取路径报错
	var json := JSON.new()
	return json.parse(text) == OK and json.data is Dictionary and str((json.data as Dictionary).get("_autosave_of", "")) != ""

static func same_directory(a: String, b: String) -> bool:
	return a.nocasecmp_to(b) == 0 if OS.get_name() == "Windows" else a == b

## 改名保留地图码和引用，计划内写入新名称后再删除旧文件。
## 返回错误信息，空串表示两个目标均已完成。
static func rename_map(m: Dictionary, old_name: String, new_name: String, baseline := "") -> String:
	new_name = new_name.strip_edges()
	if not ManifestScript.is_valid_map_name(new_name):
		return "名称非法"
	if old_name == new_name:
		return ""
	var src := path_for(m, old_name)
	if src == "" or not FileAccess.file_exists(src):
		return "原图不存在"
	var original := read_path(src, m)
	if not original.ok:
		return "原图无法读取或校验失败"
	if baseline != "" and original.digest != baseline:
		return "原图已被外部修改，请重新打开后再改名"
	var renamed: Dictionary = original.data
	renamed.meta.name = new_name
	var dst := path_for(m, new_name)
	if is_case_only_rename(src, dst):
		if new_name in list_maps(m):
			return "同名地图已存在"
		return write_case_rename(src, dst, MapFormat.encode(renamed))
	var DC := preload("res://src/project/document_commit.gd")
	var prep := DC.prepare(m, new_name, renamed, [], old_name, original.digest)
	if prep.has("error"):
		return prep.error
	if FileAccess.file_exists(path_for(m, new_name)):
		DC.recover_log(prep.plan)
	var res := DC.apply(prep.plan)
	if res.error != "":
		return res.error
	_cache.erase(src)
	invalidate_code_map()   # 改名换了文件：码表按图名做键，必须重算
	return ""

static func is_case_only_rename(src: String, dst: String) -> bool:
	return OS.get_name() == "Windows" and src != dst and src.nocasecmp_to(dst) == 0

static func write_case_rename(src: String, dst: String, text: String) -> String:
	var temp := src + ".case-" + str(Time.get_ticks_usec())
	if DirAccess.rename_absolute(src, temp) != OK:
		return "无法移动原图"
	if DirAccess.rename_absolute(temp, dst) != OK:
		DirAccess.rename_absolute(temp, src)
		return "无法写入新图名"
	if not write_text(dst, text):
		if DirAccess.rename_absolute(dst, temp) == OK:
			DirAccess.rename_absolute(temp, src)
		return "无法更新图内名称"
	_cache.erase(src)
	invalidate_code_map()
	return ""

## 复制地图（C2）：整图走 ClonePlan——实例码与附属内容全部独立、组内引用重映射，
## 此准备阶段只检查与冻结目标，调用方可先发布这些目标依赖的清单。
static func prepare_duplicate(m: Dictionary, old_name: String, new_name: String,
		src_data: Dictionary = {}, staged_contents := {}) -> Dictionary:
	new_name = new_name.strip_edges()
	if not ManifestScript.is_valid_map_name(new_name):
		return {"error": "名称非法"}
	if old_name == new_name:
		return {"error": "同名地图已存在"}
	if FileAccess.file_exists(path_for(m, new_name)):
		return {"error": "同名地图已存在"}
	var src := path_for(m, old_name)
	if src == "" or (src_data.is_empty() and not FileAccess.file_exists(src)):
		return {"error": "原图不存在"}
	var d: Dictionary = src_data if not src_data.is_empty() else read(m, old_name)
	if d.is_empty():
		return {"error": "原图解析失败"}
	# 地图码项目内唯一：新码避开全部现有码（含原图码）
	var code := allocate_code(m, str(d.get("meta", {}).get("code", "")))
	var ClonePlan := preload("res://src/content/clone_plan.gd")
	var plan: Dictionary = ClonePlan.whole_map_document(
		{"data": d, "manifest": m, "map": old_name}, new_name, code, staged_contents)
	if str(plan.get("status", "")) != "ok":
		return {"error": "复制计划有冲突", "conflicts": plan.get("conflicts", [])}
	var contents: Array = []
	for row in plan.pending_contents:
		contents.append({"fn_id": row.fn_id, "cid": row.id, "data": row.data})
	var DC := preload("res://src/project/document_commit.gd")
	return DC.prepare(m, new_name, plan.document, contents)

static func apply_duplicate(plan: Dictionary) -> String:
	var DC := preload("res://src/project/document_commit.gd")
	return DC.apply(plan).error

static func duplicate_map(m: Dictionary, old_name: String, new_name: String,
		conflicts_out: Array = [], src_data: Dictionary = {}, staged_contents := {}) -> String:
	var prep := prepare_duplicate(m, old_name, new_name, src_data, staged_contents)
	if not prep.has("plan"):
		conflicts_out.append_array(prep.get("conflicts", []))
		return str(prep.error)
	if bool(m.get("_codes_issued", false)):
		return "副本依赖的清单尚未发布"
	return apply_duplicate(prep.plan)

## 读所有地图 → {地图名: data}。坏图（无法读取/JSON 解析失败/非对象）不进结果，
## 但记录进 bad_out（坏图不再对校验页/世界页隐身）。读取走 mtime 缓存。
static func read_all(m: Dictionary, bad_out: Array = []) -> Dictionary:
	var out := {}
	var manifest_hash := m.hash()
	for name in list_maps(m):
		var path := path_for(m, name)
		if path == "" or (not m.get("_map_overrides", {}).has(name) and not FileAccess.file_exists(path)):
			continue
		var data := _map_snapshot(m, name, path, manifest_hash)
		if data.is_empty():
			bad_out.append({"name": name, "reason": "无法读取或校验失败"})
			continue
		out[name] = data
	return out

static func _map_snapshot(m: Dictionary, name: String, path: String, manifest_hash: int) -> Dictionary:
	if m.get("_map_overrides", {}).has(name):
		return m._map_overrides[name]
	return _read_cached(path, m, manifest_hash)

## R29：审计/破坏性操作读磁盘实际内容——不走 mtime+size 浏览缓存。
## 自检结果驱动「清除悬空引用」等写盘动作，旧结构会把好引用当悬空清掉。
## 实现上直接清缓存后复用 read_all（浏览路径下次照常重建缓存）。
static func read_all_fresh(m: Dictionary, bad_out: Array = []) -> Dictionary:
	_cache.clear()
	return read_all(m, bad_out)
