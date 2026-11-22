extends RefCounted
## 引用字段描述（C10）：把声明里的引用来源（choice.source / input.type）归一成结构化描述。
##
## 返回值 {kind, scope, filter, many, map_field, is_ref, allow_empty}：
##   kind  "entity_inst" / "entity_type" / "map" / "content" / "asset" / "audio" / "layer" / "value"
##   scope "same_map"（枚举所属图的实例）/ "map_ref"（由配对地图字段决定目标图）/
##         "pool"（全项目池）/ "static"（固定 options）
##   filter {ids: Array, kind: String, fn: String, dims: int}
##   many  是否多选（choice.multiple）
##   map_field 配对的地图选择字段（人类 id；"" = 无）
##
## 声明规则沿用现有 source 字符串，避免第二套词汇：
##   content:<功能id> / entity:<id,id> / entity_inst:<id,id> / map / audio: / layer: /
##   asset:<kind>:<id,id>（kind 可为空——`asset::ID` 必须解析成「不限 kind + 过滤 ID」，
##   旧实现用 split(":", false) 会吃掉空段，把 ID 当成 kind）。

const ASSET_PREFIX := "asset:"
const ENTITY_INST_PREFIX := "entity_inst:"
const ENTITY_PREFIX := "entity:"
const CONTENT_PREFIX := "content:"

const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")

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

## 主入口：声明 → 结构化描述。认不出的类型/来源原样按 value 返回（控件只读兜底）。
static func describe(decl: Dictionary) -> Dictionary:
	var out := _base(decl)
	var typ := str(decl.get("type", ""))
	# asset_ref 是 input 类型，不是 choice 来源：先归一成 asset 引用
	if typ == "entity_ref":
		out.kind = "entity_inst"
		out.scope = "map_ref" if out.map_field != "" else "same_map"
		out.filter = {"ids": _ids(str(decl.get("of", "")))}
		out.is_ref = true
		out.allow_empty = true
		return out
	if typ == "map_ref":
		out.kind = "map"
		out.scope = "pool"
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
	elif src == "audio:":
		out.kind = "audio"
		out.scope = "pool"
		out.is_ref = true
	elif src == "layer:":
		out.kind = "layer"
		out.scope = "same_map"
		out.is_ref = true
	return out

## 选项来源是否是引用（用于「未设置」空项与数组元素声明复制）。
static func is_ref(decl: Dictionary) -> bool:
	return bool(describe(decl).get("is_ref", false))

## E2：资产声明里的全部实例引用字段（type=entity_ref）。返回声明原件，供画布连线/把手用。
static func ref_fields(ad: Dictionary) -> Array:
	var out := []
	for fd in (ad.get("fields", []) as Array):
		if fd is Dictionary and str((fd as Dictionary).get("type", "")) == "entity_ref":
			out.append(fd)
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
	var want := str(decl.get("mapField", ""))
	if want == "":
		return {}
	for fd in siblings:
		if fd is Dictionary and str((fd as Dictionary).get("id", "")) == want:
			return fd
	return {}

## 读配对地图字段的当前值：值键优先用配对声明的 code，缺省退回它的 id
## （实例 props 的键是 id；内容/步骤的键是 code）。
static func paired_map_value(decl: Dictionary, siblings: Array, values: Dictionary) -> String:
	var pm := paired_map_decl(decl, siblings)
	if pm.is_empty():
		return ""
	var key := str(pm.get("code", ""))
	if key == "" or not values.has(key):
		key = str(pm.get("id", ""))
	return str(values.get(key, "") if values.get(key, null) != null else "")

## 地图键（地图码或图名）→ 该图里的实体实例 [{v: 实例码, t: 显示名, asset: 资产 id}]。
## want_types 非空时只列这些实体类型（entity_ref 的 of 过滤）。
## 读不到图/未知键返回空数组（引用控件保留原值显示，不静默改成空）。
static func map_instances(manifest: Dictionary, map_key: String, want_types: Array = []) -> Array:
	var out: Array = []
	if map_key == "":
		return out
	var name := map_key
	var list: Array = MapStore.list_maps(manifest)
	if not list.has(map_key):
		# map_key 是地图码：换成图名（一码多图时拒绝猜测）
		var cm: Dictionary = MapStore.code_map(manifest)
		name = str(cm.get(map_key, ""))
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
