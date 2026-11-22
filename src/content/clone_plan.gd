extends RefCounted
## C2 复制计划：把「复制一批实例 / 整张图」变成一份可校验、可预演的数据计划。
##
## build(src, dst, codes, include_world) 输入两份文档上下文，输出：
##   {status, instance_map, content_map, map_patch, pending_contents, conflicts}
##   src/dst = {data: 地图文档, map: 图名, manifest: 清单}；直接传地图文档也接受。
##   status = "ok" | "conflict"（冲突时不应用任何改动）
##   instance_map 旧实例码 → 新实例码（只为本次复制集合内的实体发行）
##   content_map  旧内容 ID → 新内容 ID（附属内容独立成文件）
##   map_patch    {objects, tiles?, collision?, spawn?}：目标文档要写入的段
##   pending_contents [{fn_id, id, data}]：先写内容、后写地图（A2 顺序）
##   conflicts    [{kind, id, message}]
##
## 引用重映射按 C1 声明规则（C05：不做字符串盲扫）：只改声明为引用
## （entity_inst / content）的字段；组内引用换到副本，组外引用保留原目标。
## 配对了地图字段（mapField）的实例引用同时维护目标图：
##   组内 → 指向副本所在的图；跨图时的组外 → 指向源图；无配对且跨图 = 冲突。
##
## 整图复制走 whole_map_document：保留图片/瓦片/碰撞/出生点与游戏侧自定义键，
## 实例与附属内容全部独立，目标图重发地图码（由调用方先发行）。

const ContentStore := preload("res://src/content/content_store.gd")
const ContentId := preload("res://src/content/content_id.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")

static func _data(ctx: Dictionary) -> Dictionary:
	if ctx.get("data", null) is Dictionary:
		return ctx.get("data") as Dictionary
	return ctx

static func _map_name(ctx: Dictionary) -> String:
	return str(ctx.get("map", ""))

static func _manifest(ctx: Dictionary) -> Dictionary:
	var m = ctx.get("manifest", null)
	return m as Dictionary if m is Dictionary else {}

## 源图身份键：地图码优先，老图无码用图名兜底（两处引用解析都接受）。
static func _source_key(sdata: Dictionary, src_map: String) -> String:
	var meta = sdata.get("meta", null)
	var code := str((meta as Dictionary).get("code", "")) if meta is Dictionary else ""
	return code if code != "" else src_map

## 发行一个未占用实例码；重试耗尽返回 ""。
static func _fresh_code(taken: Dictionary) -> String:
	for i in 64:
		var c := ContentId.new_inst_code()
		if not taken.has(c):
			return c
	return ""

## 声明数组里按人类字段 id 找声明，返回它的值键（内容/步骤值键=code，实例 props 键=id）。
static func _key_of(decls: Array, want_id: String) -> String:
	if want_id == "":
		return ""
	for fd in decls:
		if fd is Dictionary and str((fd as Dictionary).get("id", "")) == want_id:
			var c := str((fd as Dictionary).get("code", ""))
			return c if c != "" else want_id
	return ""

## 内容里该功能可填的全部字段声明（功能字段 + 引用到的条件字段）。
static func _content_decls(manifest: Dictionary, fn_id: String) -> Array:
	var out: Array = []
	out.append_array(FunctionDecls.function_fields(manifest, fn_id))
	var conds = FunctionDecls.function_decl(manifest, fn_id).get("conditions", null)
	for cid in (conds as Array) if conds is Array else []:
		var cd: Dictionary = ConditionDecls.condition_decl(manifest, str(cid))
		if not cd.is_empty() and cd.get("fields", []) is Array:
			out.append_array(cd.get("fields", []) as Array)
	return out

## 值里是否有任何一项命中映射表（判「组内」用）。
static func _touches(v, id_map: Dictionary) -> bool:
	if id_map.is_empty():
		return false
	if v is Array:
		for it in (v as Array):
			if it is String and id_map.has(it):
				return true
		return false
	return v is String and id_map.has(v)

## 按映射表换值（多选数组逐元素；未命中原样）。
static func _swap(v, id_map: Dictionary):
	if v is Array:
		var out: Array = []
		for it in (v as Array):
			out.append(id_map.get(str(it), it) if it is String else it)
		return out
	if v is String and id_map.has(v):
		return id_map[v]
	return v

static func _is_empty_value(v) -> bool:
	if v == null:
		return true
	if v is String:
		return str(v) == ""
	if v is Array:
		return (v as Array).is_empty()
	return false

## 主入口。codes 为空 = 源文档里的对象全部参与（配合 include_world 做整图）；
## 非空只复制这些实例码（缺码的实例 = 冲突）。清单可缺省（纯数据对拷）。
## staged_contents（R12）：会话里的暂存内容 {内容ID: data}——未落盘的绑定内容也从这里读，
## 不再把有效内容报成缺失。
static func build(src: Dictionary, dst: Dictionary, codes: PackedStringArray = PackedStringArray(),
		include_world := false, staged_contents := {}) -> Dictionary:
	var sdata := _data(src)
	var ddata := _data(dst)
	var m := _manifest(src) if not _manifest(src).is_empty() else _manifest(dst)
	var src_map := _map_name(src)
	var dst_map := _map_name(dst)
	# codes 空 = 源文档里的对象全部参与复制（剪贴板/区域粘贴的源文档只含待复制行）。
	# include_world 才决定是否连瓦片/碰撞/出生点一起带（整图复制）。
	var copy_all := codes.is_empty()
	var conflicts: Array = []
	# —— 选行：整图 = 全部；否则只取集合内且有码的实体行 ——
	var src_rows: Array = sdata.get("objects", []) if sdata.get("objects", []) is Array else []
	var wanted := {}
	for c in codes:
		if str(c) != "":
			wanted[str(c)] = true
	var selected: Array = []
	var src_by_code := {}
	for row in src_rows:
		if not (row is Dictionary):
			continue
		var r: Dictionary = row
		var code := str(r.get("code", ""))
		if code != "":
			if src_by_code.has(code):
				conflicts.append({"kind": "duplicate_code", "id": code,
					"message": "源图里实例码重复：%s" % code})
				continue
			src_by_code[code] = r
		if copy_all or (code != "" and wanted.has(code)):
			selected.append(r)
	if not copy_all:
		for c in wanted:
			if not src_by_code.has(c):
				conflicts.append({"kind": "missing_instance", "id": str(c),
					"message": "源图里没有实例 %s" % str(c)})
	var src_codes := {}
	for c0 in src_by_code:
		src_codes[str(c0)] = true
	# —— 发行新实例码：避开目标已有码与本次已发行 ——
	var taken := {}
	for row2 in (ddata.get("objects", []) as Array):
		if row2 is Dictionary:
			var dc := str((row2 as Dictionary).get("code", ""))
			if dc != "":
				taken[dc] = true
	var instance_map := {}
	for r3 in selected:
		var old_code := str((r3 as Dictionary).get("code", ""))
		if old_code == "":
			continue   # 场景图片实例没有身份码，不发行
		var nc := _fresh_code(taken)
		if nc == "":
			conflicts.append({"kind": "code_exhausted", "id": old_code,
				"message": "新实例码发行失败（重试耗尽）"})
			continue
		taken[nc] = true
		instance_map[old_code] = nc
	# —— 内容克隆：每份被复制的绑定内容各生成独立文件 ——
	var pending: Array = []
	var content_map := {}
	var seen_cid := {}
	for r4 in selected:
		var row4: Dictionary = r4
		var new_code := str(instance_map.get(str(row4.get("code", "")), ""))
		for f in (row4.get("functions", []) as Array):
			if not (f is Dictionary):
				continue
			var fb: Dictionary = f
			var cid := str(fb.get("content", ""))
			if cid == "" or seen_cid.has(cid):
				continue
			seen_cid[cid] = true
			var fn_code := str(fb.get("fn", ""))
			var fn_id := FunctionDecls.fn_id_of(m, fn_code) if not m.is_empty() else ""
			if fn_id == "":
				if not m.is_empty():
					conflicts.append({"kind": "content_function", "id": cid,
						"message": "内容 %s 的功能码 %s 未在清单声明" % [cid, fn_code]})
				continue
			var cdata := ContentStore.read(m, fn_id, cid)
			if cdata.is_empty() and staged_contents.has(cid) and (staged_contents[cid] as Variant) is Dictionary:
				cdata = staged_contents[cid] as Dictionary   # R12：暂存内容也在复制范围内
			if cdata.is_empty():
				conflicts.append({"kind": "content_missing", "id": cid,
					"message": "内容文件读不到：%s/%s" % [fn_id, cid]})
				continue
			var new_cid := _new_content_id(m, fn_id, ddata, new_code, cid)
			if new_cid == "":
				conflicts.append({"kind": "content_id", "id": cid,
					"message": "新内容 ID 生成失败：%s" % cid})
				continue
			content_map[cid] = new_cid
			var clone: Dictionary = cdata.duplicate(true)
			clone["id"] = new_cid
			clone["function"] = FunctionDecls.fn_code(m, fn_id)
			pending.append({"fn_id": fn_id, "id": new_cid, "data": clone})
	# —— 行补丁：实例码 / 引用 / 绑定（按声明，不做字符串盲扫） ——
	var cross_code := ""
	if src_map != "" and src_map != dst_map:
		cross_code = _source_key(sdata, src_map)   # 同图粘贴 = ""，组外引用原样保留
	# R10：源图身份键——配对地图字段的现值与它不符的引用指向第三张图，原样保留。
	var source_key := _source_key(sdata, src_map)
	var out_objects: Array = []
	for r5 in selected:
		out_objects.append(remap_row(r5 as Dictionary, instance_map, content_map, m,
			cross_code, src_codes, conflicts, ddata, dst_map, source_key, src_map))
	# —— 内容副本内部引用：组内实例码/内容跳转按声明重映射（C05） ——
	for pc in pending:
		_remap_content((pc as Dictionary).data, m, str((pc as Dictionary).fn_id),
			instance_map, content_map, cross_code, src_codes, conflicts,
			ddata, dst_map, source_key, src_map)
	var patch := {"objects": out_objects}
	if include_world:
		# 整图：图片/瓦片/碰撞/出生点原样带过去（实例行已重映射）
		for key in ["tiles", "spawn", "collision"]:
			var seg = sdata.get(key, null)
			if seg is Dictionary or seg is Array:
				patch[key] = (seg as Variant).duplicate(true)
	return {
		"status": "ok" if conflicts.is_empty() else "conflict",
		"instance_map": instance_map,
		"content_map": content_map,
		"map_patch": patch,
		"pending_contents": pending,
		"conflicts": conflicts,
	}

## 单行重映射（活体贴/区域粘贴/整图共用）：返回深拷贝，原行不动。
##   instance_map 旧码→新码；content_map 旧内容 ID→新内容 ID；
##   cross_code 非空 = 跨图复制时组外引用该写入的源图键（"" = 同图/整图，组外原样保留）；
##   source_codes 源图全部实例码（空 = 未知：凡未在组内的引用都按源图算）。
## 配对地图字段规则见文件头；冲突写进 conflicts（调用方据此取消整个计划）。
static func remap_row(row: Dictionary, instance_map: Dictionary, content_map: Dictionary,
		manifest: Dictionary, cross_code := "", source_codes: Dictionary = {},
		conflicts = null, target_data: Dictionary = {}, target_map := "",
		source_key := "", source_name := "") -> Dictionary:
	var out: Dictionary = row.duplicate(true)
	var old_code := str(out.get("code", ""))
	if old_code != "" and instance_map.has(old_code):
		out["code"] = instance_map[old_code]
	var aid := str(out.get("asset", ""))
	var props: Dictionary = out.get("props", {}) if out.get("props", {}) is Dictionary else {}
	var ad := AssetDecl.by_id(manifest, aid) if not manifest.is_empty() else {}
	var fdecls: Array = ad.get("fields", []) if ad.get("fields", []) is Array else []
	# C1：record 数组行内 entity_ref 递归重映射（行内兄弟 = 子字段声明；配对字段读行内值）
	for fd in fdecls:
		if not (fd is Dictionary):
			continue
		var f: Dictionary = fd
		if str(f.get("type", "")) != "array" or str(f.get("of", "")) != "record":
			continue
		var rows = props.get(str(f.get("id", "")), null)
		if not (rows is Array):
			continue
		var subs: Array = f.get("fields", []) if f.get("fields", []) is Array else []
		var ri := 0
		for r in rows:
			if r is Dictionary:
				_remap_entity_ref_fields(r as Dictionary, subs, "%s.字段%s#%d" % [str(out.get("code", "")), str(f.get("id", "")), ri], instance_map, cross_code, source_codes, conflicts, target_data, target_map, source_key, source_name)
			ri += 1
	# 顶层 entity_ref（值键 = 字段 id；配对字段读 props）
	_remap_entity_ref_fields(props, fdecls, str(out.get("code", "")), instance_map, cross_code, source_codes, conflicts, target_data, target_map, source_key, source_name)
	# C3：port_ref 重映射（props 键 = 字段 id，code 兜底）
	_remap_port_refs(props, fdecls, instance_map, target_data, target_map, cross_code, source_codes, source_key, source_name)
	# 功能绑定：内容跳转换成副本；未知键原样保留
	var fns: Array = out.get("functions", []) if out.get("functions", []) is Array else []
	for i in fns.size():
		if not (fns[i] is Dictionary):
			continue
		var fb: Dictionary = fns[i]
		var cid := str(fb.get("content", ""))
		if cid != "" and content_map.has(cid):
			fb["content"] = content_map[cid]
		fns[i] = fb
	out["functions"] = fns
	out["props"] = props
	return out

## 目标图身份键（配对地图字段写这个值）：图码优先，缺码用图名。
static func _target_key(target_data: Dictionary, target_map: String) -> String:
	var meta = target_data.get("meta", null)
	var code := str((meta as Dictionary).get("code", "")) if meta is Dictionary else ""
	return code if code != "" else target_map

## 内容副本的引用重映射：fields 按键=字段码；steps[].fields 按步骤声明字段码。
## 只碰声明为引用（entity_inst / content）的键；其余值（含同形四位码）不动。
static func _remap_content(data: Dictionary, manifest: Dictionary, fn_id: String,
		instance_map: Dictionary, content_map: Dictionary, cross_code: String,
		source_codes: Dictionary, conflicts: Array, target_data: Dictionary,
		target_map: String, source_key := "", source_name := "") -> void:
	var decls := _content_decls(manifest, fn_id)
	var owner := str(data.get("id", ""))
	_remap_field_map(data.get("fields", null), decls, instance_map, content_map,
		cross_code, source_codes, conflicts, owner, target_data, target_map, source_key, source_name)
	var steps = data.get("steps", null)
	for st in (steps as Array) if steps is Array else []:
		if not (st is Dictionary):
			continue
		var step_code := str((st as Dictionary).get("step", ""))
		var sd: Dictionary = StepDecls.step_by_code(manifest, step_code)
		var sdecls: Array = sd.get("fields", []) if sd.get("fields", []) is Array else []
		_remap_field_map((st as Dictionary).get("fields", null), sdecls, instance_map,
			content_map, cross_code, source_codes, conflicts, owner, target_data, target_map,
			source_key, source_name)

## 一组声明字段 → 值字典的引用重映射（功能字段/条件字段/步骤字段共用）。
static func _remap_field_map(values, decls: Array, instance_map: Dictionary,
		content_map: Dictionary, cross_code: String, source_codes: Dictionary,
		conflicts: Array, owner: String, target_data: Dictionary, target_map: String,
		source_key := "", source_name := "") -> void:
	if not (values is Dictionary):
		return
	var vals: Dictionary = values
	# C1：record 数组行先递归（行内键 = 码或 id；引用与配对字段作用域 = 行内值）
	_remap_record_rows(vals, decls, instance_map, content_map, cross_code, source_codes, conflicts, owner, target_data, target_map, source_key, source_name)
	# C3：port_ref 重映射（内容字段键 = 码优先，id 兜底）
	_remap_port_refs(vals, decls, instance_map, target_data, target_map, cross_code, source_codes, source_key, source_name)
	var pairs_to_fill := {}
	for fd in decls:
		if not (fd is Dictionary):
			continue
		var f: Dictionary = fd
		var desc := RefFields.describe(f)
		if not bool(desc.get("is_ref", false)):
			continue
		var kind := str(desc.get("kind", ""))
		if kind != "entity_inst" and kind != "content":
			continue
		var key := str(f.get("code", ""))
		if key == "":
			key = str(f.get("id", ""))
		if not vals.has(key):
			continue
		var id_map: Dictionary = instance_map if kind == "entity_inst" else content_map
		# R10：先看配对地图字段的现值——目标不是源图的引用原样保留（跨图身份）。
		var pair := str(f.get("mapField", ""))
		if kind == "entity_inst" and pair != "" and (source_key != "" or source_name != ""):
			var pk := _key_of(decls, pair)
			var pv := str(vals.get(pk, "")) if pk != "" and vals.has(pk) else ""
			if pv != "" and pv != source_key and pv != source_name:
				continue
		var v = vals[key]
		var touched := _touches(v, id_map)
		if touched:
			vals[key] = _swap(v, id_map)
		if kind != "entity_inst" or _is_empty_value(v):
			continue
		var pair_key := _key_of(decls, pair)
		if touched:
			# 组内：配对地图字段指向副本所在的图
			if pair_key != "":
				var tk := _target_key(target_data, target_map)
				if pairs_to_fill.has(pair_key) and str(pairs_to_fill[pair_key]) != tk:
					conflicts.append({"kind": "ref_pair_conflict", "id": owner,
						"message": "内容 %s 的配对地图字段被多条引用要求指向不同图：无法一次复制，请取消或拆分" % owner})
				pairs_to_fill[pair_key] = tk
			continue
		if cross_code == "":
			continue
		if not source_codes.is_empty() and not _touches(v, source_codes):
			continue
		if pair_key != "":
			if pairs_to_fill.has(pair_key) and str(pairs_to_fill[pair_key]) != cross_code:
				conflicts.append({"kind": "ref_pair_conflict", "id": owner,
					"message": "内容 %s 的配对地图字段被多条引用要求指向不同图：无法一次复制，请取消或拆分" % owner})
			pairs_to_fill[pair_key] = cross_code
		else:
			conflicts.append({"kind": "ref_unpaired", "id": owner,
				"message": "内容 %s 的字段 %s 指向源图实例，但该字段不支持地图配对：请改选目标或取消" % [
					owner, str(f.get("id", ""))]})
	for k in pairs_to_fill:
		vals[k] = pairs_to_fill[k]

## 新内容 ID：优先按分层身份重组（目标图码 + 类型码 + 新实例码 + 功能 id），
## 缺任一段时沿用源 ID 前缀 + 新随机内容段，最后查重。
static func _new_content_id(manifest: Dictionary, fn_id: String, target_data: Dictionary,
		new_inst_code: String, old_id: String) -> String:
	var map_code := str((target_data.get("meta", {}) as Dictionary).get("code", "")) \
		if (target_data.get("meta", {}) as Dictionary).get("code", null) != null else ""
	var ent_code := ""
	var cand := ""
	if map_code != "" and new_inst_code != "":
		# 类型码从源内容 ID 的第二段取（内容 ID = 图-类型-实例-功能-内容）
		var segs := old_id.split("-", false)
		if segs.size() >= 2:
			ent_code = str(segs[1])
	cand = ContentId.content_id(map_code, ent_code, new_inst_code, fn_id)
	if cand == "":
		# 老式内容 ID 不一定是五段（如 CID1）：沿用原 ID 作前缀，只换末段
		var cut := old_id.rfind("-")
		if cut < 0:
			cand = old_id
		else:
			cand = old_id.substr(0, cut) + "-" + ContentId.new_inst_code()
	return ContentId.unique(manifest, fn_id, cand)

## 计划里的冲突 → 给用户看的一行（预览弹窗/状态栏共用）。
static func conflicts_text(conflicts: Array) -> String:
	var lines: Array = []
	for c in conflicts:
		lines.append(str((c as Dictionary).get("message", str(c))))
	return "\n".join(PackedStringArray(lines))

## —— 整图复制（C2）：在 build 之上组装完整地图文档 ——
## 源文档全部保留（含游戏侧自定义顶层键），只替换 meta 身份与 objects/tiles/spawn/collision。
## 调用方先发行新图名与地图码；内容按 A2 顺序由调用方先写 pending_contents。
## 返回 build 的结果 + 额外键 "document"（可直接 MapStore.write 的文档）。
static func whole_map_document(src: Dictionary, new_name: String, new_code: String) -> Dictionary:
	var sdata := _data(src)
	var m := _manifest(src) if not _manifest(src).is_empty() else {}
	var src_map := _map_name(src)
	var doc: Dictionary = sdata.duplicate(true)
	var meta: Dictionary = doc.get("meta", {}) if doc.get("meta", {}) is Dictionary else {}
	meta["name"] = new_name
	meta["code"] = new_code
	doc["meta"] = meta
	# 目标文档（自身）只用于实例码占位查询：整图复制到新文件，不能撞现有任何码
	var dst_ctx := {"data": {"meta": meta}, "manifest": m, "map": new_name}
	var plan: Dictionary = build({"data": sdata, "manifest": m, "map": src_map}, dst_ctx,
		PackedStringArray(), true)
	var patch: Dictionary = plan.get("map_patch", {}) if plan.get("map_patch", {}) is Dictionary else {}
	for key in ["objects", "tiles", "spawn", "collision"]:
		if patch.has(key):
			doc[key] = patch[key]
	plan["document"] = doc
	return plan
## entity_ref 字段引用重映射（remap_row 顶层与 C1 记录行共用）：vals = 值字典（键=字段 id），
## fdecls = 兄弟声明（配对地图字段按 mapField 在这里找，值读 vals）。冲突 id 用 owner。
## 原逻辑保持不变（R10 配对优先、组内→指向目标图、组外→钉源图/报冲突）。
static func _remap_entity_ref_fields(vals: Dictionary, fdecls: Array, owner: String,
		instance_map: Dictionary, cross_code := "", source_codes: Dictionary = {},
		conflicts = null, target_data: Dictionary = {}, target_map := "",
		source_key := "", source_name := "") -> void:
	var pairs_to_fill := {}
	for fd in fdecls:
		if not (fd is Dictionary):
			continue
		var f: Dictionary = fd
		var fid := str(f.get("id", ""))
		if str(f.get("type", "")) != "entity_ref":
			continue
		var vv = vals.get(fid, null)
		if _is_empty_value(vv):
			continue
		var pair := str(f.get("mapField", ""))
		# R10：先看配对地图字段的现值——目标不是源图的引用原样保留（跨图身份 (图码, 实例码)）。
		if pair != "" and (source_key != "" or source_name != ""):
			var pk := _key_of(fdecls, pair)
			var pv := str(vals.get(pk, "")) if pk != "" and vals.has(pk) else ""
			if pv != "" and pv != source_key and pv != source_name:
				continue
		var vs := str(vv)
		if instance_map.has(vs):
			vals[fid] = instance_map[vs]
			# 组内：配对地图字段指向副本所在的图（同图复制也是本图当前码）
			if pair != "":
				var tk := _target_key(target_data, target_map)
				if pairs_to_fill.has(pair) and str(pairs_to_fill[pair]) != tk:
					if conflicts is Array:
						(conflicts as Array).append({"kind": "ref_pair_conflict", "id": owner,
							"message": "实例 %s 的配对地图字段 %s 被多条引用要求指向不同图：无法一次复制，请取消或拆分选择" % [owner, pair]})
				pairs_to_fill[pair] = tk
			continue
		if cross_code == "":
			continue
		if not source_codes.is_empty() and not source_codes.has(vs):
			continue   # 本来就指向第三张图：引用与地图字段都原样保留
		# 组外且指向源图：跨图时只能靠配对地图字段把目标钉在源图
		if pair != "":
			if pairs_to_fill.has(pair) and str(pairs_to_fill[pair]) != cross_code:
				if conflicts is Array:
					(conflicts as Array).append({"kind": "ref_pair_conflict", "id": owner,
						"message": "实例 %s 的配对地图字段 %s 被多条引用要求指向不同图：无法一次复制，请取消或拆分选择" % [owner, pair]})
			pairs_to_fill[pair] = cross_code
		elif conflicts is Array:
			(conflicts as Array).append({"kind": "ref_unpaired", "id": owner,
				"message": "实例 %s 的字段 %s 指向源图 %s，但该字段不支持地图配对：请改选目标或取消" % [owner, fid, cross_code]})
	for k in pairs_to_fill:
		vals[k] = pairs_to_fill[k]

## C1：内容/步骤 fields 的 record 数组行先逐行递归（行内兄弟 = 子字段声明，键=码或 id）。
## 行内的引用重映射走 _remap_field_map 同一条入口，配对字段作用域 = 行内值。
static func _remap_record_rows(values: Dictionary, decls: Array, instance_map: Dictionary,
		content_map: Dictionary, cross_code: String, source_codes: Dictionary,
		conflicts: Array, owner: String, target_data: Dictionary, target_map: String,
		source_key := "", source_name := "") -> void:
	for fd in decls:
		if not (fd is Dictionary):
			continue
		var f: Dictionary = fd
		if str(f.get("type", "")) != "array" or str(f.get("of", "")) != "record":
			continue
		var key := str(f.get("code", ""))
		if key == "":
			key = str(f.get("id", ""))
		var rows = values.get(key, null)
		if not (rows is Array):
			continue
		var subs: Array = f.get("fields", []) if f.get("fields", []) is Array else []
		for r in rows:
			if r is Dictionary:
				_remap_field_map(r as Dictionary, subs, instance_map, content_map, cross_code,
					source_codes, conflicts, owner, target_data, target_map, source_key, source_name)
## C3：port_ref 字段的重映射：值 = {map, inst, port}，只改所属实例/地图分量（端口 ID 不动）。
## 组内：inst 在 instance_map → 换新码，map 分量在空/指向源图时换目标图键；指向第三图原样保留。
## 组外指向源图 + 跨图复制 → map 钉源图；组外指向第三图 → 原样保留。
static func _remap_port_refs(vals: Dictionary, fdecls: Array, instance_map: Dictionary,
		target_data: Dictionary, target_map: String, cross_code := "", source_codes: Dictionary = {},
		source_key := "", source_name := "") -> void:
	var tk := _target_key(target_data, target_map)
	for fd in fdecls:
		if not (fd is Dictionary):
			continue
		var f: Dictionary = fd
		if str(f.get("type", "")) != "port_ref":
			continue
		var key := str(f.get("id", ""))
		if key == "" or not vals.has(key):
			key = str(f.get("code", ""))
		if key == "" or not vals.has(key):
			continue
		var v = vals[key]
		if not (v is Dictionary):
			continue
		var vd: Dictionary = v
		var inst := str(vd.get("inst", ""))
		if inst == "":
			continue
		if instance_map.has(inst):
			var mcmp := str(vd.get("map", ""))
			if mcmp == "" or mcmp == source_key or mcmp == source_name:
				vd["map"] = tk
				vd["inst"] = str(instance_map[inst])
			continue
		if cross_code == "":
			continue
		if not source_codes.is_empty() and not source_codes.has(inst):
			continue
		vd["map"] = cross_code