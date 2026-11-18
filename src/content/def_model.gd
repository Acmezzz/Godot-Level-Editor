extends RefCounted
## 实体定义校验与解析：定义种类必须对应清单实体、组件必须在白名单内、组件引用可解析。
## 同时提供运行时/编辑器共用的属性合并规则（实例 > 定义 > 清单默认）。
##
## 组件数据结构（一个槽位可挂多份，按顺序匹配）：
##   "components": {
##     "dialogue": [
##       {"id": "dlg.first",  "once": true},        # 初遇，播完作废
##       {"id": "dlg.idle",   "when": "met_smith"}, # 认识之后才有
##       {"id": "dlg.default"}                      # 兜底循环
##     ]
##   }
## 旧的单对象写法 {"dialogue": {"id": "x", "once": true}} 自动归一化为单元素数组。

const MODEL := "def"

## 受支持的组件种类。新增组件需同时更新游戏侧执行器与 content_validate。
const COMPONENTS := ["dialogue", "shop", "interact_event", "enemy_profile"]
## 每个组件引用的内容种类（用于跨资源校验）。
const COMPONENT_KIND := {
	"dialogue": "dialogues",
	"shop": "shops",
	"interact_event": "events",
}
## 支持挂多份的组件（enemy_profile 仍未建模）
const MULTI_SLOTS := ["dialogue", "shop", "interact_event"]

## H4（批次 11）：组件声明化——content/schema/components.json 声明优先，
## 无声明回退内置常量（向前兼容）。声明形如 {"components": {"dialogue": {"kind": "dialogues", "multi": true, "label": "对话"}}}。
static var _decl_cache := {}   # 项目目录 → 声明（{} = 无声明，回退内置）

static func components_decl(manifest: Dictionary) -> Dictionary:
	var dir := str(manifest.get("_dir", ""))
	if dir == "":
		return {}
	var hit = _decl_cache.get(dir, null)
	if hit != null:
		return hit
	var out := {}
	var path := dir.path_join("content/schema/components.json")
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var d = JSON.parse_string(f.get_as_text())
			if d is Dictionary and ((d as Dictionary).get("components", {}) is Dictionary):
				out = (d as Dictionary).get("components", {})
	_decl_cache[dir] = out
	return out

## 生效组件列表：声明优先，缺省回退内置 COMPONENTS
static func components_list(manifest: Dictionary) -> Array:
	var decl := components_decl(manifest)
	if not (decl as Dictionary).is_empty():
		return (decl as Dictionary).keys()
	return COMPONENTS

## 组件 → 内容种类（跨资源校验用）：声明优先，缺省回退内置映射
static func component_kind(manifest: Dictionary, comp_name: String) -> String:
	var decl := components_decl(manifest)
	if not (decl as Dictionary).is_empty():
		return str((decl.get(comp_name, {}) as Dictionary).get("kind", ""))
	return str(COMPONENT_KIND.get(comp_name, ""))

## 组件是否可挂多份：声明优先，缺省回退内置 MULTI_SLOTS
static func component_multi(manifest: Dictionary, comp_name: String) -> bool:
	var decl := components_decl(manifest)
	if not (decl as Dictionary).is_empty():
		return bool((decl.get(comp_name, {}) as Dictionary).get("multi", false))
	return MULTI_SLOTS.has(comp_name)

static func validate(definition: Dictionary, manifest: Dictionary) -> Array:
	var issues: Array = []
	var kind := str(definition.get("kind", ""))
	if kind == "":
		issues.append(_issue("error", "kind", "定义缺少种类（kind）"))
	elif not _kind_known(kind, manifest):
		issues.append(_issue("error", "kind", "种类不在清单实体中: " + kind + "（应先写进编辑器清单）"))
	# H4：组件白名单按声明（components.json 优先，缺省内置）
	var comps: Array = components_list(manifest)
	var components = definition.get("components", {})
	if components is Dictionary:
		for name in (components as Dictionary):
			_validate_component(str(name), (components as Dictionary)[name], issues, comps, manifest)
	elif definition.has("components"):
		issues.append(_issue("error", "components", "components 必须是对象"))
	return issues

static func _validate_component(comp_name: String, raw, issues: Array, comps: Array, manifest: Dictionary) -> void:
	if not comps.has(comp_name):
		issues.append(_issue("error", "components." + comp_name, "未支持的组件: " + comp_name))
		return
	if not (raw is Dictionary or raw is Array):
		issues.append(_issue("error", "components." + comp_name, "组件必须是对象或数组"))
		return
	var items := _items_of_raw(raw)
	if items.is_empty():
		issues.append(_issue("error", "components." + comp_name, "组件没有任何条目"))
		return
	if not component_multi(manifest, comp_name) and items.size() > 1:
		issues.append(_issue("warn", "components." + comp_name,
			"%s 只取第一条；要挂多份请改用支持的槽位" % comp_name))
	var seen := {}
	for i in items.size():
		var entry: Dictionary = items[i]
		var field := "components.%s[%d]" % [comp_name, i]
		var ref_id := str(entry.get("id", ""))
		if ref_id == "":
			issues.append(_issue("error", field + ".id", "缺少资源 id"))
			continue
		if seen.has(ref_id):
			issues.append(_issue("error", field + ".id", "同一槽位重复引用: " + ref_id))
		seen[ref_id] = true
		# when 是可选的 flag 名；给出空串等于"总是命中"，与省略等价，但显式空串容易误写
		if entry.has("when") and str(entry.get("when", "")).strip_edges() == "":
			issues.append(_issue("warn", field + ".when", "when 为空串，等同不设条件；建议删掉该键"))

## 归一化：单对象 / 数组 → 字典数组（只保留字典项）
static func _items_of_raw(raw) -> Array:
	var out: Array = []
	if raw is Dictionary:
		out.append(raw)
	elif raw is Array:
		for entry in raw:
			if entry is Dictionary:
				out.append(entry)
	return out

## 某槽位的全部条目（归一化后的字典数组）；未配置返回空数组
static func items_of(definition: Dictionary, comp: String) -> Array:
	var components = definition.get("components", {})
	if not (components is Dictionary):
		return []
	return _items_of_raw((components as Dictionary).get(comp))

## 全部组件引用的资源：{组件名: [{kind, id, once, when}, ...]}
## 旧调用方拿到的是"每组件一项"，现在每组件是一组；校验与 UI 都按组处理。
static func references(definition: Dictionary, manifest: Dictionary = {}) -> Dictionary:
	var out := {}
	var components = definition.get("components", {})
	if not (components is Dictionary):
		return out
	for name in (components as Dictionary):
		var comp_name := str(name)
		var kind := component_kind(manifest, comp_name)   # H4：声明优先
		if kind == "":
			continue
		var refs: Array = []
		for entry in items_of(definition, comp_name):
			var ref_id := str((entry as Dictionary).get("id", ""))
			if ref_id == "":
				continue
			refs.append({
				"kind": kind,
				"id": ref_id,
				"once": bool((entry as Dictionary).get("once", false)),
				"when": str((entry as Dictionary).get("when", "")),
			})
		if not refs.is_empty():
			out[comp_name] = refs
	return out

## 合并三层数值：实例 props.stats > 定义 stats > 清单 stats 默认值。
static func effective_stats(definition: Dictionary, manifest_def: Dictionary, instance_props: Dictionary) -> Dictionary:
	var out := {}
	for stat in manifest_def.get("stats", []):
		if not (stat is Dictionary):
			continue
		var sid := str((stat as Dictionary).get("id", ""))
		if sid != "":
			out[sid] = (stat as Dictionary).get("default", 0)
	var def_stats = definition.get("stats", {})
	if def_stats is Dictionary:
		for sid in (def_stats as Dictionary):
			out[str(sid)] = (def_stats as Dictionary)[sid]
	var inst_stats = instance_props.get("stats", {})
	if inst_stats is Dictionary:
		for sid in (inst_stats as Dictionary):
			out[str(sid)] = (inst_stats as Dictionary)[sid]
	return out

static func _kind_known(kind: String, manifest: Dictionary) -> bool:
	for entity in manifest.get("entities", []):
		if entity is Dictionary and str((entity as Dictionary).get("id", "")) == kind:
			return true
	return false

static func _issue(level: String, field: String, message: String) -> Dictionary:
	return {"level": level, "model": MODEL, "field": field, "message": message}
