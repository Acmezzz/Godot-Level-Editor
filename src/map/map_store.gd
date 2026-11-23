extends RefCounted
## 地图 JSON 数据层：名称校验后的读写、mtime+尺寸缓存、实体查找、改名、整图复制。
## **改名与复制不是一回事**：rename_map 是**纯 rename**（只换文件名，不迁移任何引用——
## 跨图引用写的是地图码，所以本来就不破）；duplicate_map 是**整图复制**，会发新实例码/内容 ID、
## 重映射组内引用、为目标图重发地图码，并按 A2 顺序先写内容后写地图。
## 以静态函数为主，带少量静态状态：_cache（读缓存）与 project_rev（写盘版本号，派生缓存据此重扫）。
## 写盘单入口 write_text/write_json：先写 .tmp 再原子替换。两种回滚保险别混：
##   地图 —— write() 先把原文件暂存到 editor/history/maps/<地图码>/（替换成功才计入）；
##   内容 —— ContentStore 覆盖前 rotate_history 出 3 层 .history（与地图同权，误写可回滚）。
## 两者深度与各入口提交的文件集合由 docs/EDITOR_FEATURES.md §7.3 唯一规定，此处不复述数字。
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

## R29：人工刷新入口——外部工具同秒同长度改写地图时，浏览缓存（mtime+size）可能拿旧结构；
## 正式写入路径各自失效或直读。需要看到磁盘最新结构时（脚本/诊断）调用它强制重扫。
static func invalidate_read_cache() -> void:
	_cache.clear()

## 统一文本解码、版本升级与结构校验；错误时不返回可编辑数据。
## 先跑原始文档检查（版本缺失/超前、退役键），再抬版本号并做结构校验（D11）。
static func decode_text(text: String, source := "", manifest := {}) -> Dictionary:
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "data": {}, "errors": [{"path": source, "message": "JSON must be an object"}], "warnings": [], "migrated": false}
	var data: Dictionary = parsed
	var issues := MapValidator.precheck(data)
	var migrated := upgrade(data)
	issues.append_array(MapValidator.validate(data, manifest))
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
		"code": ContentId.new_inst_code(),
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
##   by_name  {图名: 码}   by_code {码: [图名...]}（>1 = 撞码）   map {码: 图名}（= code_map，取字典序末位）
##   unreadable [图名]（文件在、但读不出或结构校验不过 → 引用解析报 unreadable 而非 missing）
##   names [图名]（目录里的全部地图，含读不出的）
## 带缓存（F1/P03）：签名 = 目录列举清单 + 各图 mtime，不再每图 open 取长度——
## 20 图 × 每次调用曾要约 3 ms（打开 20 个文件），而绘制出口角标每帧都要这张表。
## 目录列举能看见新增/删除/改名（文件系统的时间戳精度在目录项上比文件内容可靠），
## mtime 能看见内容改动；写盘路径另调 invalidate_code_map() 显式失效兜住同秒写。
static var _ci_cache := {}
static var _ci_key := "__never__"

## 写盘/改名/删除后调用：下次 code_index 必重算（不依赖 mtime 粒度）。
static func invalidate_code_map() -> void:
	_ci_key = "__never__"

static func code_index(m: Dictionary) -> Dictionary:
	var names := list_maps(m)
	var key := _cm_signature(m, names)
	if _ci_key == key:
		return _ci_cache
	var by_name := {}
	var by_code := {}
	var plain := {}
	var unreadable: Array = []
	for mn in names:
		var n := str(mn)
		var md := _read_cached(path_for(m, n), m)
		if md.is_empty():
			# 图名在目录里但内容读不出（坏 JSON / 校验不过）：不是「没有这张图」
			unreadable.append(n)
			continue
		var c := str((md.get("meta", {}) as Dictionary).get("code", ""))
		if c == "":
			continue
		by_name[n] = c
		plain[c] = n   # 撞码时保留字典序末位（历史行为），冲突由 by_code 摆出全部路径
		if not by_code.has(c):
			by_code[c] = []
		(by_code[c] as Array).append(n)
	_ci_cache = {"by_name": by_name, "by_code": by_code, "map": plain,
		"unreadable": unreadable, "names": names}
	_ci_key = key
	return _ci_cache

static func code_map(m: Dictionary) -> Dictionary:
	return code_index(m).get("map", {}) as Dictionary

## 签名：图名清单 + 每图 mtime（不 open 文件）。图名清单抓新增/删除/改名，
## mtime 抓内容改动；同秒内的原地改写由写路径的 invalidate_code_map 兜住。
static func _cm_signature(m: Dictionary, names: Array) -> String:
	var parts := PackedStringArray()
	parts.append(str(m.get("_maps_dir", "")))
	parts.append(str(names.size()))
	for mn in names:
		var p := path_for(m, str(mn))
		parts.append("%s@%d" % [str(mn), FileAccess.get_modified_time(p)])
	return "|".join(parts)

## 图名 → 地图码表（code_map 的反向视图；复用同一签名缓存，O(n) 反转一次）
static func name_to_code(m: Dictionary) -> Dictionary:
	var out := {}
	var cm := code_map(m)
	for c in cm:
		out[str(cm[c])] = str(c)
	return out

## 确保这张图有 meta.code：缺就发一个不与全项目冲突的新码并写回 data。
## 返回是否有改动（调用方据此置脏）。就地修改。
## 占用表直接扫全部地图文件（含重复码的影子条目），不只信 code_map 的「一码一图」（D08）。
static func ensure_code(m: Dictionary, data: Dictionary) -> bool:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	if str(meta.get("code", "")) != "":
		return false
	var taken := {}
	for mn in list_maps(m):
		var md := read(m, str(mn))
		var c := str((md.get("meta", {}) as Dictionary).get("code", ""))
		if c != "":
			taken[c] = true
	var code := ContentId.new_inst_code()
	while taken.has(code):
		code = ContentId.new_inst_code()
	meta["code"] = code
	data["meta"] = meta
	return true

## 项目内重复地图码 → {code: [图名...]}（>1 个文件共用同码）。审计/引用解析据此拒绝猜测。
## 引用解析侧的「一码一图」表（code_map）在撞码时只保留最后读到的图名——
## 这正是必须用本函数把全部路径摆出来的原因。
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
	var result := read_path(path_for(m, name), m)
	var data = result.data if result.ok else {}
	return data

## 写地图 JSON；名称非法、写入前校验失败或写盘失败均返回 false。
## 历史（A3）：原文件快照先暂存到 <项目>/editor/history/maps/<地图码>/，
## 新文件原子替换成功后才把快照纳入历史——替换失败时快照丢弃，旧历史条目不减少。
## 无 git 环境的最后保险；草稿（editor/drafts）与内容文件自动写入不进历史（各有机制）。
const Recovery := preload("res://src/map/recovery.gd")
const HISTORY_DEPTH := 3

static func write(m: Dictionary, name: String, data: Dictionary) -> bool:
	var path := path_for(m, name)
	if path == "":
		return false
	# 写前校验序列化结果（D11）：坏图（层栈空/瓦片元组错/退役键）不落盘覆盖好文件。
	if not validate_for_write(data, m):
		return false
	var code := str((data.get("meta", {}) as Dictionary).get("code", ""))
	# maps 目录可能还不存在（新项目/测试临时目录）：写入口负责建，不依赖历史目录副作用
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var staged := Recovery.stage_snapshot(m, code, name, path)
	if not write_json(path, data):
		Recovery.discard_snapshot(staged)   # 替换失败：不把快照计入历史（旧历史不减）
		return false
	if staged != "" and not Recovery.commit_snapshot(m, code, name, staged):
		# 历史落盘失败单独报告，但不影响「保存成功」这个事实
		push_warning("地图历史落盘失败: " + staged)
	return true

## 校验待写文档；返回首个错误文本，"" = 通过。
static func write_error(m: Dictionary, data: Dictionary) -> String:
	var issues := MapValidator.precheck(data)
	issues.append_array(MapValidator.validate(data, m))
	for issue in issues:
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
	# V4 P0-3：唯一临时名。固定后缀会让地图/清单/内容/历史同时写同目录时互相截断，
	# 且残留的旧 .tmp 可能被当成合法中间态。
	var tmp := path + ".tmp-" + str(Time.get_ticks_usec()) + "-" + str(randi() % 100000)
	if not _write_bytes(tmp, text.to_utf8_buffer()):
		return false
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return false
	_cache.erase(path)   # 写后失效，下次读回源
	invalidate_code_map()   # 码表签名依赖 mtime，同秒改写也可能撞上——写路径直接置失效
	# 任何项目数据落盘都可能改变实体 id 引用（地图 props / 内容步骤）：
	# 版本号 +1；画布的引用集缓存以 project_rev 为失效锚点（经参数传入，避免循环 preload）。
	project_rev += 1
	return true

## 多文件提交的协调写入与崩溃恢复不在这里：全部走 DocumentCommit 的冻结计划
## （prepare_frozen + apply_frozen，见 src/project/document_commit.gd），提交日志由它统一登记。
## 本函数只负责把一段字节写进一个文件。
static func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	return ok

## 在地图数据里按实例码查找；返回空字典表示没有
static func find_entity(data: Dictionary, ent_id: String) -> Dictionary:
	for obj in data.get("objects", []):
		if obj is Dictionary and str((obj as Dictionary).get("code", "")) == ent_id:
			return obj
	return {}

## 已有地图名列表（不含扩展名，排序）。
## `foo.autosave.json` 只有在带 `_autosave_of` 时才是旧式草稿（跳过）；
## 缺标记的是普通地图（图名就叫 foo.autosave），必须列出（A3）。
static func list_maps(m: Dictionary) -> Array:
	var out := []
	var dir := DirAccess.open(str(m.get("_maps_dir", "")))
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		if f.ends_with(".autosave.json") and _is_legacy_draft(str(m.get("_maps_dir", "")).path_join(f)):
			continue
		out.append(f.get_basename())
	out.sort()
	return out

static func _is_legacy_draft(path: String) -> bool:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return false   # 读不出就别猜：按普通地图处理，交给读取路径报错
	var data = JSON.parse_string(text)
	return data is Dictionary and str((data as Dictionary).get("_autosave_of", "")) != ""

## 纯 rename——只改文件名，不迁移引用（拍板：改名不迁移）。
## 返回错误信息；"" = 成功。
## §4.4-4：落盘编排交给 DocumentCommit 的冻结计划（rename 目标 + 日志 + 收据），
## 本函数只做前置校验与收尾（缓存失效、显示名回写、旧位置历史清理）。
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
	# R06：改名 = 一次多文件提交（这里是单次原子 rename + 删除效果）——进提交日志，
	# 中途失败可辨认可清理；日志不可写时中止（与正式提交同一门槛）。
	var DC := preload("res://src/project/document_commit.gd").new()
	var prep: Dictionary = DC.prepare_frozen("地图改名 %s → %s" % [old_name, new_name], m,
		[preload("res://src/project/document_commit.gd").rename_target(src, dst, new_name)])
	if str(prep.get("status", "")) != "ok":
		return "提交计划为空：改名已中止"
	var res: Dictionary = DC.apply_frozen(prep.get("plan", {}) as Dictionary)
	if str(res.get("status", "")) != "ok":
		var why := str(res.get("error", ""))
		if why == "":
			var cs: Array = res.get("conflicts", [])
			why = str((cs[0] as Dictionary).get("message", "")) if not cs.is_empty() else "改名失败"
		return why
	# 文件内 meta.name 同步改名（A3）：只改文件名会让重开/历史查询拿到旧名。
	# R06：回写失败不得报成功——文件已在新名下，显示名未更新要显式报告。
	var renamed := read(m, new_name)
	if not renamed.is_empty() and str((renamed.get("meta", {}) as Dictionary).get("name", "")) != new_name:
		renamed.meta.name = new_name
		if not write_json(dst, renamed):
			return "改名后显示名回写失败（文件已在新名字下，显示名未更新）"
	_cache.erase(src)
	_cache.erase(dst)
	invalidate_code_map()   # 改名换了文件：码表按图名做键，必须重算
	# 旧位置历史（maps/.history/<旧名>.json.N）清掉不留孤儿；
	# 新的按码历史（editor/history/maps/<码>/）不动——码不变，改名后可继续查
	var hist_dir := str(m.get("_maps_dir", "")).path_join(".history")
	for i in HISTORY_DEPTH:
		var hp := hist_dir.path_join("%s.json.%d" % [old_name, i + 1])
		if FileAccess.file_exists(hp):
			DirAccess.remove_absolute(hp)
	return ""

## 复制地图（C2）：整图走 ClonePlan——实例码与附属内容全部独立、组内引用重映射，
## 目标图重发地图码。内容先写（A2），再写地图；任何一步失败都不留新地图文件。
## 返回错误信息（"" = 成功）；conflicts_out 收计划冲突给人看。
## staged_contents：会话里未落盘的暂存内容 {cid: data}——未保存的绑定内容也要复制
## （只读磁盘会把它们判成缺失，V4 P1）。
static func duplicate_map(m: Dictionary, old_name: String, new_name: String,
		conflicts_out: Array = [], src_data: Dictionary = {}, staged_contents := {}) -> String:
	new_name = new_name.strip_edges()
	if not ManifestScript.is_valid_map_name(new_name):
		return "名称非法"
	if old_name == new_name:
		return "同名地图已存在"
	if FileAccess.file_exists(path_for(m, new_name)):
		return "同名地图已存在"
	var src := path_for(m, old_name)
	if src == "" or (src_data.is_empty() and not FileAccess.file_exists(src)):
		return "原图不存在"
	var d: Dictionary = src_data if not src_data.is_empty() else read(m, old_name)
	if d.is_empty():
		return "原图解析失败"
	# 地图码项目内唯一：新码避开全部现有码（含原图码）
	var taken := code_map(m)
	var code := ContentId.new_inst_code()
	while taken.has(code):
		code = ContentId.new_inst_code()
	var ClonePlan := preload("res://src/content/clone_plan.gd")
	var plan: Dictionary = ClonePlan.whole_map_document(
		{"data": d, "manifest": m, "map": old_name}, new_name, code, staged_contents)
	if str(plan.get("status", "")) != "ok":
		conflicts_out.append_array(plan.get("conflicts", []))
		return "复制计划有冲突（见问题列表）"
	# R06/§4.4-4：复制 = 一次多文件冻结计划（内容 N 份 + 地图 1 份），
	# 交给 DocumentCommit 执行——同一套日志、写前复验与逐目标收据。
	# A2 依赖序：内容在前（失败即停，地图文件未动），地图在后。
	var frozen := []
	for pc in (plan.get("pending_contents", []) as Array):
		var pd: Dictionary = pc
		frozen.append({"kind": "content", "fn_id": str(pd.get("fn_id", "")),
			"id": str(pd.get("id", "")), "data": pd.get("data", {})})
	var doc: Dictionary = plan.get("document", {}) if plan.get("document", {}) is Dictionary else {}
	if doc.is_empty():
		return "复制文档组装失败"
	var mpath := path_for(m, new_name)
	frozen.append({"kind": "map", "id": new_name, "path": mpath, "expect_absent": true,
		"frozen_text": JSON.stringify(doc, "\t") + "\n"})
	var DC := preload("res://src/project/document_commit.gd").new()
	var prep: Dictionary = DC.prepare_frozen("整图复制 %s → %s" % [old_name, new_name], m, frozen)
	if str(prep.get("status", "")) != "ok":
		return "提交计划为空：复制已中止"
	var res: Dictionary = DC.apply_frozen(prep.get("plan", {}) as Dictionary)
	if str(res.get("status", "")) != "ok":
		var why := str(res.get("error", ""))
		if why == "":
			var cs: Array = res.get("conflicts", [])
			why = str((cs[0] as Dictionary).get("message", "")) if not cs.is_empty() else "复制失败"
		return why
	_cache.erase(mpath)
	invalidate_code_map()
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

## R29：审计/破坏性操作读磁盘实际内容——不走 mtime+size 浏览缓存。
## 自检结果驱动「清除悬空引用」等写盘动作，旧结构会把好引用当悬空清掉。
## 实现上直接清缓存后复用 read_all（浏览路径下次照常重建缓存）。
static func read_all_fresh(m: Dictionary, bad_out: Array = []) -> Dictionary:
	_cache.clear()
	return read_all(m, bad_out)
