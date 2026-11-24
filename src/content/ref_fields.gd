extends RefCounted
## 引用字段描述：把声明里的引用来源（choice.source / input.type）归一成结构化描述。
## 本模块是**唯一**的「这个字段指向什么」判定入口——内容表单、步骤面板、复制重映射、
## 审计与画布连线都走 describe()，不各自解析 source 字符串。
##
## 返回值 {kind, scope, filter, many, map_field, is_ref, allow_empty}：
##   kind  "entity_inst" / "entity_type" / "map" / "content" / "asset" / "audio" / "view" / "layer" /
##         "port"（C3 端口引用）/ "value"
##   scope "same_map"（枚举本图实例）/ "map_ref"（由配对地图字段决定目标图）/
##         "pool"（全项目池）/ "static"（固定 options）
##   filter {ids: Array, types: Array, kind: String, fn: String, dims: int}
##   many  是否多选（choice.multiple）
##   map_field 配对的地图选择字段（人类 id；"" = 无）
##
## 可验证约束（测试按这些断言，不靠读实现猜）：
##   - 只有 is_ref=true 的字段参与复制重映射与悬空检查；普通字符串永不按「恰好等于某实例码」改写。
##   - mapField 按**人类字段 id** 找兄弟声明；值按配对声明的 **code 优先、id 兜底**读
##     （内容/步骤的键是 code，实例 props 的键是 id）。配对字段缺失 = 作用域退回本图，不报错。
##   - 地图键解析统一走 ReferenceIndex.resolve_map：**一码多图不猜**（status=ambiguous，
##     候选进审计），缺键 = missing，两者在候选列表里都返回空数组——控件保留原值显示，
##     绝不把读不到的目标静默改写成空串。
##   - 同一图同格多实例不是歧义：候选按实例码区分（显示「类型 码 · (x,y)」）。
##
## 声明规则沿用现有 source 字符串，避免第二套词汇：
##   content:<功能id> / entity:<id,id> / entity_inst:<id,id> / map / audio: / view: / layer: /
##   asset:<kind>:<id,id>（kind 可为空——`asset::ID` 必须解析成「不限 kind + 过滤 ID」，
##   旧实现用 split(":", false) 会吃掉空段，把 ID 当成 kind）。

const ASSET_PREFIX := "asset:"
const ENTITY_INST_PREFIX := "entity_inst:"
const ENTITY_PREFIX := "entity:"
const CONTENT_PREFIX := "content:"

const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const EdgeRef := preload("res://src/map/edge_ref.gd")

## 逗号分隔 id 白名单（空 = 不限）
static func _ids(s: String) -> Array:
	var out: Array = []
	for part in s.split(",", false):
		var t := str(part).strip_edges()
		if t != "":
			out.append(t)
	return out

static func _base(decl: Dictionary) -> Dictionary:
	return {
		"kind": "value",
		"scope": "static",
		"filter": {},
		"many": bool(decl.get("multiple", false)),
		"map_field": str(decl.get("mapField", "")),
		"is_ref": false,
		"allow_empty": bool(decl.get("allowEmpty", false)),
	}

## 二维向量声明维数（C06）：默认 2；声明 dims 只接受 2/3。
static func vector_dims(decl: Dictionary) -> int:
	var d := int(decl.get("dims", 2))
	return d if d == 2 or d == 3 else 2

static func is_ordered_choice(decl: Dictionary) -> bool:
	return decl.get("type") == "array" and decl.get("of") == "choice" and not bool(decl.get("multiple", false))

## 主入口：声明 → 结构化描述。认不出的类型/来源原样按 value 返回（控件只读兜底）。
static func describe(decl: Dictionary) -> Dictionary:
	var out := _base(decl)
	var typ := str(decl.get("type", ""))
	if typ == "flow_target" or decl.get("source") == "editor:flow-target":
		out.merge({"kind": "flow_target", "scope": "pool", "is_ref": true, "allow_empty": true}, true)
		return out
	if is_ordered_choice(decl):
		var item := describe(array_element_decl(decl))
		item["many"] = true
		return item
	if typ == "array" and decl.get("of") in ["port_ref", "edge_ref", "flow_target"]:
		var item := describe(array_element_decl(decl))
		item["many"] = true
		return item
	# asset_ref 是 input 类型，不是 choice 来源：先归一成 asset 引用
	if typ == "entity_ref":
		out.kind = "entity_inst"
		out.scope = "map_ref" if out.map_field != "" else "same_map"
		out.filter = {"ids": _ids(str(decl.get("of", "")))}
		out.is_ref = true
		out.allow_empty = true
		return out
	if typ == "port_ref":
		out.kind = "port"
		out.scope = "map_ref" if out.map_field != "" else "same_map"
		out.filter = {"types": _ids(str(decl.get("of", "")))}
		out.is_ref = true
		out.allow_empty = true
		return out
	if typ == "map_ref":
		out.kind = "map"
		out.scope = "pool"
		out.is_ref = true
		out.allow_empty = true
		return out
	if typ == "edge_ref":
		# §7.4 格边引用：值 = {map, cell, edge}；边身份由格拓扑推导（EdgeRef 规范代表边）。
		out.kind = "edge"
		out.scope = "map_ref" if out.map_field != "" else "same_map"
		out.is_ref = true
		out.allow_empty = true
		return out
	if typ == "asset_ref":
		out.kind = "asset"
		out.scope = "pool"
		out.filter = {"kind": str(decl.get("assetKind", "")), "ids": _ids(str(decl.get("of", "")))}
		out.is_ref = true
		return out
	var src := str(decl.get("source", ""))
	if src.begins_with(CONTENT_PREFIX):
		out.kind = "content"
		out.scope = "pool"
		out.filter = {"fn": src.substr(CONTENT_PREFIX.length())}
		out.is_ref = true
	elif src.begins_with(ENTITY_INST_PREFIX):
		out.kind = "entity_inst"
		out.scope = "map_ref" if out.map_field != "" else "same_map"
		out.filter = {"ids": _ids(src.substr(ENTITY_INST_PREFIX.length()))}
		out.is_ref = true
	elif src.begins_with(ENTITY_PREFIX):
		out.kind = "entity_type"
		out.scope = "pool"
		out.filter = {"ids": _ids(src.substr(ENTITY_PREFIX.length()))}
	elif src.begins_with(ASSET_PREFIX):
		out.kind = "asset"
		out.scope = "pool"
		# 保留空段：`asset::AB23` = kind 空 + ID 过滤
		var rest := src.substr(ASSET_PREFIX.length())
		var cut := rest.find(":")
		var ak := rest if cut < 0 else rest.substr(0, cut)
		var ids_s := "" if cut < 0 else rest.substr(cut + 1)
		out.filter = {"kind": ak, "ids": _ids(ids_s)}
		out.is_ref = true
	elif src == "map":
		out.kind = "map"
		out.scope = "pool"
		out.is_ref = true
	elif src == "view:":
		out.kind = "view"
		out.scope = "pool"
		out.is_ref = true
		out.allow_empty = true
	elif src == "audio:":
		out.kind = "audio"
		out.scope = "pool"
		out.is_ref = true
	elif src == "layer:":
		out.kind = "layer"
		out.scope = "same_map"
		out.is_ref = true
	elif src.begins_with("cell:"):
		# C4/§4.2-2：有限格图 cell_id 引用。合法性以格图声明（cell_id + 显式邻接）为准，
		# 不由整数格坐标推导——审计据此查「引用的 cell_id 是否还在格图里」。
		out.kind = "cell"
		out.scope = "map_ref" if out.map_field != "" else "same_map"
		out.is_ref = true
		out.allow_empty = true
	return out

## 选项来源是否是引用（用于「未设置」空项与数组元素声明复制）。
static func is_ref(decl: Dictionary) -> bool:
	return bool(describe(decl).get("is_ref", false))

## 表单与引用遍历共用数组元素声明。数组的 of 表示元素类型，资产 ID 白名单写 ids。
static func array_element_decl(decl: Dictionary) -> Dictionary:
	var of := str(decl.get("of", "string"))
	if of == "choice":
		var d: Dictionary = {"kind": "choice"}
		for k in ["options", "source", "multiple", "allowEmpty", "mapField", "_mapKey"]:
			if decl.get(k, null) != null:
				d[k] = (decl.get(k) as Variant).duplicate(true) if (decl.get(k) is Array or decl.get(k) is Dictionary) \
					else decl.get(k)
		return d
	if of == "condition":
		return {"kind": "condition_row", "type": "condition", "source": "editor:condition-schema",
			"allowedConditions": decl.get("allowedConditions", [])}
	# C1：of: record —— 元素控件是记录表单（子字段声明在 fields 里，逐元素独立副本）
	if of == "record":
		return {"kind": "record", "type": "record",
			"fields": (decl.get("fields", []) as Array).duplicate(true)}
	var out := {"kind": "input", "type": of}
	for k in ["min", "max", "step", "dims", "assetKind", "mapField", "_mapKey", "maps", "screens", "contentTypes", "arrivalPorts"]:
		if decl.get(k, null) != null:
			# 逐元素独立声明副本（C1）：数组/字典值不能与父声明共享引用
			out[k] = decl.get(k).duplicate(true) if (decl.get(k) is Array or decl.get(k) is Dictionary) \
				else decl.get(k)
	if of == "asset_ref":
		var ids = decl.get("ids", null)
		if ids is Array:
			out["of"] = ",".join(PackedStringArray(ids))
	elif of == "port_ref" and decl.get("portTypes") is String:
		out["of"] = decl.portTypes
	return out

## 一个数组字段中可继续按声明进入的作用域。value/fields 是原字典引用，
## path 相对数组字段用于定位；标签含条件类型，供图和审计显示。
static func nested_scopes(manifest: Dictionary, field: Dictionary, value: Variant) -> Array:
	var scopes: Array = []
	if field.get("type") != "array" or not value is Array:
		return scopes
	var kind := str(field.get("of", ""))
	if kind != "record" and kind != "condition":
		return scopes
	for i in value.size():
		var row = value[i]
		if not row is Dictionary:
			continue
		var decls = field.get("fields")
		var vals: Dictionary = row
		var label := str(i + 1)
		var relative := [i]
		if kind == "condition":
			var decl := ConditionDecls.row_schema(manifest, field, row)
			if decl.is_empty() or not row.get("fields") is Dictionary:
				continue
			decls = decl.fields
			vals = row.fields
			relative.append("fields")
			label += " · " + str(decl.name)
		if decls is Array:
			scopes.append({"decls": decls, "values": vals, "path": relative, "label": label})
	return scopes

## C1（§7.4）：递归收集引用字段（含 record 数组子字段）。返回 [{fd, path}]：
## 顶层引用 path = [字段 id]；record 行内 = [记录字段 id, "#", 子字段 id]（# = 逐行维度）。
## 兄弟配对字段作用域 = 该层声明本身（顶层配对字段在顶层找，记录行的在子字段声明里找）。
static func ref_fields_deep(ad: Dictionary) -> Array:
	var out := []
	_collect_refs(ad.get("fields", []) if ad.get("fields", null) is Array else [], [], out, 0)
	return out

## 深度收集器：decls 为当前层声明；path 累积路径；depth 限深防声明自嵌套。
static func _collect_refs(decls: Array, path: Array, out: Array, depth: int) -> void:
	if depth > 4:
		return
	for fd in decls:
		if not (fd is Dictionary):
			continue
		var f: Dictionary = fd
		if str(f.get("type", "")) == "array" and str(f.get("of", "")) == "record":
			_collect_refs(f.get("fields", []) if f.get("fields", []) is Array else [], path + [str(f.get("id", "")), "#"], out, depth + 1)
			continue
		if bool(describe(f).get("is_ref", false)):
			out.append({"fd": f, "path": path.duplicate() + [str(f.get("id", ""))]})

## E2：资产声明里的全部实例引用字段（type=entity_ref）。返回声明原件，供画布连线/把手用。
static func ref_fields(ad: Dictionary) -> Array:
	var out := []
	for fd in (ad.get("fields", []) as Array):
		if fd is Dictionary and str((fd as Dictionary).get("type", "")) == "entity_ref":
			out.append(fd)
	return out

## C3：资产声明的端口表（assets[].ports：{id, x, y, type?}）。无声明返回空数组。
static func ports_of(ad: Dictionary) -> Array:
	var ps = ad.get("ports", null)
	return ps if ps is Array else []

## C3：端口候选（port: 选项来源）：目标图上每个实例的声明端口，按类型过滤。
## 返回 [{v: JSON 串（{map, inst, port}）, t: 标签}]；地图解析失败返回空（控件保留原值）。
static func port_candidates(manifest: Dictionary, map_key: String, want_types: Array) -> Array:
	var out: Array = []
	var rm := ReferenceIndex.resolve_map(manifest, map_key)
	if str(rm.get("status", "")) != "ok":
		return out
	var name := str(rm.get("key", ""))
	if name == "":
		return out
	var data: Dictionary = MapStore.read(manifest, name)
	var map_code := str((data.get("meta", {}) as Dictionary).get("code", ""))
	return port_options(manifest, map_code if map_code != "" else name, data.get("objects", []), want_types)

static func port_options(manifest: Dictionary, map_key: String, objects: Array, want_types: Array) -> Array:
	var out: Array = []
	for o in objects:
		if not (o is Dictionary):
			continue
		var code := str((o as Dictionary).get("code", ""))
		if code == "":
			continue
		var ad := AssetDecl.by_id(manifest, str((o as Dictionary).get("asset", "")))
		if ad.is_empty():
			continue
		for p in ports_of(ad):
			if not (p is Dictionary):
				continue
			var pid := str((p as Dictionary).get("id", ""))
			if pid == "":
				continue
			var pt := str((p as Dictionary).get("type", ""))
			if not want_types.is_empty() and not want_types.has(pt):
				continue
			var val := {"map": map_key, "inst": code, "port": pid}
			out.append({"v": JSON.stringify(val), "t": "%s · %s" % [code, pid]})
	return out

## §7.4：格边候选（`edge:` 选项来源）：地图 tiles 里「两侧都有瓦片」的相邻格对，
## 按规范代表边（EdgeRef.canonical_edge）去重排序。返回 [{v: JSON({map, cell, edge}), t: "(x,y)-(x,y)"}]。
## 地图解析失败 / 读不到返回空（控件保留原值，不静默改写）。
static func edge_candidates(manifest: Dictionary, map_key: String) -> Array:
	var rm: Dictionary = ReferenceIndex.resolve_map(manifest, map_key)
	if str(rm.get("status", "")) != "ok":
		return []
	var name := str(rm.get("key", ""))
	if name == "":
		return []
	return edge_candidates_of(MapStore.read(manifest, name), manifest)

## 已读地图文档 → 边候选（画布对内存文档直接调，避免再读盘）。瓦片格号按生效拓扑解析。
static func edge_candidates_of(data: Dictionary, manifest: Dictionary) -> Array:
	if data.is_empty():
		return []
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	var grid: GridSpace = GridSpace.resolve(meta, manifest).get("grid") as GridSpace
	var occ := {}
	var tiles_data = data.get("tiles", null)
	if tiles_data is Dictionary:
		for lid in (tiles_data as Dictionary):
			var cells = (tiles_data as Dictionary)[lid]
			if not (cells is Array):
				continue
			for c0 in (cells as Array):
				if c0 is Array and (c0 as Array).size() >= 2:
					occ[Vector2i(int(c0[0]), int(c0[1]))] = true
	return occupied_edge_options(grid, meta, occ)

static func occupied_edge_options(grid: GridSpace, meta: Dictionary, occ: Dictionary) -> Array:
	var w := int(meta.get("w", 120))
	var h := int(meta.get("h", 56))
	var code := str(meta.get("code", ""))
	var options := {}
	for a: Vector2i in occ:
		for b: Vector2i in grid.neighbors_any(a):
			if not occ.has(b):
				continue
			var edge := EdgeRef.canonical_edge(a, b)
			if options.has(edge) or EdgeRef.segment(grid, a, b, w, h).is_empty():
				continue
			var value := EdgeRef.value_of(code, a, b)
			options[edge] = {"v": JSON.stringify(value), "t": edge.replace("|", " — ")}
	var keys := options.keys()
	keys.sort()
	var out: Array = []
	for key in keys:
		out.append(options[key])
	return out

## E2：配对地图值是否指向当前图（C1：未填配对地图 = 本图；v7 写地图码，老数据存图名）。
## 只有指向本图的实例引用才有画布落点可连——跨图引用的目标实例不在本图。
static func map_key_local(key: String, cur_name: String, cur_code: String) -> bool:
	if key == "":
		return true
	if cur_code != "" and key == cur_code:
		return true
	return key == cur_name

## E2：资产声明里「可画布连线」的 entity_ref 字段及其当前值。
## 返回 [{fd, value}]；跨图配对（配对地图字段指向别的图）的引用不在本图，不列。
## 纯函数：画布不传节点，只按声明 + props 判断——同一份判据测试可独立验证。
static func local_entity_refs(ad: Dictionary, props: Dictionary,
		cur_name: String, cur_code: String) -> Array:
	var out := []
	var fdecls: Array = ad.get("fields", []) if ad.get("fields", []) is Array else []
	for fd in ref_fields(ad):
		var f: Dictionary = fd
		var pair := paired_map_value(f, fdecls, props)
		if not map_key_local(pair, cur_name, cur_code):
			continue
		out.append({"fd": f, "value": str(props.get(str(f.get("id", "")), ""))})
	return out

## E2：目标资产是否满足字段的 of 白名单（空 = 不限）。
static func field_accepts(decl: Dictionary, asset_id: String) -> bool:
	var of := Array((describe(decl).get("filter", {}) as Dictionary).get("ids", []))
	return of.is_empty() or of.has(asset_id)

## 声明是否是「需要清空项」的单选/多选引用：source 型引用一律给空项；
## entity_ref/map_ref 也是；asset_ref 不强制（资产选择通常必填，声明可开 allowEmpty）。
static func wants_empty_option(decl: Dictionary) -> bool:
	var d := describe(decl)
	if not bool(d.get("is_ref", false)):
		return false
	if bool(d.get("allow_empty", false)):
		return true
	# 资产引用由声明显式开启空项；其余引用（实例/地图/内容/音频/层）默认带空项
	return str(d.get("kind", "")) != "asset"

## —— 引用作用域：配对地图字段（C1） ——
## 声明按**人类字段 id** 找配对：entity_ref 用 mapField: "target_map"，
## 内容/功能/条件/步骤字段用同一写法；配对字段本身通常是 map_ref 或 source:"map" 的 choice。
## 配对字段的值按它自己的**声明码**读（内容/功能/条件/步骤的值键是 code；实例 props 键是 id）。

## 在兄弟声明里找配对地图字段的声明（无则空字典）。
static func paired_map_decl(decl: Dictionary, siblings: Array) -> Dictionary:
	return _sibling_decl(str(decl.get("mapField", "")), siblings)

static func _sibling_decl(want: String, siblings: Array) -> Dictionary:
	if want == "":
		return {}
	for fd in siblings:
		if fd is Dictionary and str((fd as Dictionary).get("id", "")) == want:
			return fd
	return {}

## 读配对地图字段的当前值：值键优先用配对声明的 code，缺省退回它的 id
## （实例 props 的键是 id；内容/步骤的键是 code）。
static func paired_map_value(decl: Dictionary, siblings: Array, values: Dictionary, key_mode := "code") -> String:
	return _sibling_value(paired_map_decl(decl, siblings), values, key_mode)

## Layout props apply declared defaults when an override is absent, including sibling maps.
static func effective_map_value(decl: Dictionary, siblings: Array, values: Dictionary, key_mode: String) -> String:
	return _sibling_value(paired_map_decl(decl, siblings), values, key_mode, true)

static func with_map_scope(decl: Dictionary, siblings: Array, values: Dictionary, key_mode: String,
		use_defaults := false) -> Dictionary:
	if decl.get("mapField", "") == "":
		return decl
	var key := effective_map_value(decl, siblings, values, key_mode) if use_defaults \
		else paired_map_value(decl, siblings, values, key_mode)
	return decl.merged({"_mapKey": key}, true)

## Captured as one scope so either sibling changing invalidates a pending frame pick.
static func frame_scope(decl: Dictionary, siblings: Array, values: Dictionary, key_mode := "code",
		use_defaults := false) -> Array[String]:
	var layer := _sibling_decl(str(decl.get("layerField", "")), siblings) if decl.get("pickSpace") == "layer" else {}
	return [_sibling_value(paired_map_decl(decl, siblings), values, key_mode, use_defaults),
		_sibling_value(layer, values, key_mode, use_defaults)]

static func _sibling_value(pm: Dictionary, values: Dictionary, key_mode: String, use_defaults := false) -> String:
	if pm.is_empty():
		return ""
	var key := str(pm.get("code", "")) if key_mode == "code" else ""
	if use_defaults:
		var value = values.get(key if key != "" else str(pm.id), pm.get("default"))
		return value if value is String else ""
	if key == "" or not values.has(key):
		key = str(pm.get("id", ""))
	return str(values.get(key, "") if values.get(key, null) != null else "")

## 对象引用自己的地图优先，其次用同一行的配对值；两者为空由调用方取所属图。
static func object_map_key(value: Dictionary, paired: String) -> String:
	var key := str(value.get("map", ""))
	return paired if key == "" else key

## 地图键（地图码或图名）→ 该图里的实体实例 [{v: 实例码, t: 显示名, asset: 资产 id}]。
## want_types 非空时只列这些实体类型（entity_ref 的 of 过滤）。
## 读不到图/未知键返回空数组（引用控件保留原值显示，不静默改成空）。
static func map_instances(manifest: Dictionary, map_key: String, want_types: Array = []) -> Array:
	var out: Array = []
	if map_key == "":
		return out
	# B2（§7.2）：地图键解析统一走 ReferenceIndex.resolve_map（R09 撞码不猜、缺失即空）。
	var rm: Dictionary = ReferenceIndex.resolve_map(manifest, map_key)
	if str(rm.get("status", "")) != "ok":
		return out
	var name := str(rm.get("key", ""))
	if name == "":
		return out
	var data: Dictionary = MapStore.read(manifest, name)
	for o in (data.get("objects", []) as Array):
		if not (o is Dictionary):
			continue
		var row: Dictionary = o
		var code := str(row.get("code", ""))
		var aid := str(row.get("asset", ""))
		if code == "" or aid == "":
			continue
		if not want_types.is_empty() and not want_types.has(aid):
			continue
		var ad: Dictionary = AssetDecl.by_id(manifest, aid)
		if str(ad.get("kind", "")) != "entity":
			continue
		out.append({"v": code, "t": "%s · %s (%s,%s)" % [
			str(ad.get("name", aid)), code, str(row.get("x", "?")), str(row.get("y", "?"))],
			"asset": aid})
	return out
