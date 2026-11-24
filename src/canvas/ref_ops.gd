extends RefCounted
## RefOps：实例 props 引用字段的统一写入口（E2 空间连线 / E1 画布选点 / 内容表单下拉）。
##
## 三条路径写同一份数据就不能各写一遍规则：改配对地图字段时旧落点属于原图（C1），
## 改图层同样可能使局部坐标失效。确认后一起清空旧值，并记为一步地图撤销。
## `host` = app（要状态栏/确认框），`cvs` = app.canvas（撤销与标记）。

var app
var cvs

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")

func _init(a) -> void:
	app = a
	cvs = a.canvas

## 写引用字段（entity_ref 的实例码字符串；§7.4 edge_ref 的 {map, cell, edge} 对象）。
## 返回 {status: "ok"/"cancelled"/"failed", cleared: 清空的配对字段 id[]}。
## 幂等：值未变直接 ok（不压撤销）。配对清空需要确认时会等待用户选择；
## 取消返回 cancelled 且数据一点没动（调用方把控件回填旧值）。
func set_entity_ref(n: EntityNode, fd: Dictionary, value) -> Dictionary:
	if n == null or not is_instance_valid(n) or not app.map_loaded:
		return {"status": "failed", "cleared": []}
	var fid := str(fd.get("id", ""))
	if fid == "":
		return {"status": "failed", "cleared": []}
	var props: Dictionary = n.props.duplicate(true)
	if is_same(props.get(fid, null), value) or (typeof(props.get(fid)) == typeof(value) and props.get(fid) == value):
		return {"status": "ok", "cleared": []}
	var edef: Dictionary = AssetDecl.by_id(app.manifest, n.asset)
	var cleared: Array[String] = []
	for other in (edef.get("fields", []) as Array):
		if not other is Dictionary:
			continue
		var depends: bool = other.get("mapField", "") == fid \
			or (other.get("pickSpace") == "layer" and other.get("layerField", "") == fid)
		var dependent_id := str(other.get("id", ""))
		if depends and _has_scope_value(props.get(dependent_id)):
			cleared.append(dependent_id)
	if not cleared.is_empty():
		var source: Dictionary = app.manifest
		var live_map: Dictionary = cvs.map_data
		var asset_id := n.asset
		var asset_decl := edef.duplicate(true)
		var title := "改目标图层" if RefFields.describe(fd).kind == "layer" else "改目标地图"
		var msg := "将清空属于原坐标空间的字段：%s。继续？" % "、".join(cleared)
		if not await app._confirm_action(title, msg, "改并清空"):
			return {"status": "cancelled", "cleared": []}
		if not app.map_loaded or app.canvas != cvs or not is_same(cvs.map_data, live_map) \
				or not is_same(app.manifest, source) or not is_instance_valid(n) \
				or n.is_queued_for_deletion() or n.asset != asset_id or n.props != props \
				or AssetDecl.by_id(source, asset_id) != asset_decl:
			app._set_status("确认期间实例或引用已变更，请重试")
			return {"status": "failed", "cleared": []}
	var empty: bool = (value is String and value.is_empty()) or (value is Dictionary and value.is_empty())
	if empty:
		props.erase(fid)
	else:
		props[fid] = value
	for id in cleared:
		props.erase(id)
	_commit_props(n, props)
	# 指向预览：仅本图 entity_ref 高亮（跨图/地图引用在本图没有可亮对象）
	var target := str(value) if fd.get("type") == "entity_ref" and value is String \
		and app.canvas.is_entity_code_local(value) else ""
	cvs.ref_highlight = target
	cvs.queue_redraw()
	if empty:
		app._set_status("已清空引用「%s」" % str(fd.get("name", fid)))
	elif value is Dictionary:
		app._set_status("引用「%s」→ %s（Ctrl+Z 撤销）" % [
			str(fd.get("name", fid)), str(value.get("edge", value.get("port", "")))])
	else:
		app._set_status("引用「%s」→ %s（Ctrl+Z 撤销）" % [str(fd.get("name", fid)), str(value)])
	return {"status": "ok", "cleared": cleared}

static func _has_scope_value(value: Variant) -> bool:
	if value is String or value is Array or value is Dictionary:
		return not value.is_empty()
	return value != null

func set_instance_value(n: EntityNode, id: String, value: Variant) -> void:
	var props := n.props.duplicate(true)
	props[id] = value
	_commit_props(n, props)

func _commit_props(n: EntityNode, props: Dictionary) -> void:
	var pre: Dictionary = cvs._undo_history_ctrl.inst_rows([n])
	if not pre.ok:
		cvs.push_undo()
	n.props = props
	n.refresh_visual()
	if pre.ok:
		cvs._undo_history_ctrl.inst_commit(pre.rows)
	cvs._mark_ents()
	cvs.queue_redraw()

## 目标实例是否满足字段的 of 白名单（空 = 不限）。拖连线/画布选点共用。
func accepts(fd: Dictionary, n: EntityNode) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	return RefFields.field_accepts(fd, n.asset)

## 本图可连的实例和端口字段。跨图引用保留在表单中编辑。
## 返回 [{fd, value, target: EntityNode 或 null}]——target 是 C1 解析后的落点。
func local_refs(n: EntityNode) -> Array:
	var out: Array = []
	if n == null or not is_instance_valid(n):
		return out
	var edef: Dictionary = AssetDecl.by_id(app.manifest, n.asset)
	var cur_name := str(cvs.cur_map_name)
	var cur_code := str((cvs.map_data.get("meta", {}) as Dictionary).get("code", "")) \
		if cvs.map_data.get("meta", {}) is Dictionary else ""
	var by_code: Dictionary = cvs._ent_by_code_index()
	for r in RefFields.local_entity_refs(edef, n.props, cur_name, cur_code):
		var rd: Dictionary = r
		var val := str(rd.get("value", ""))
		var tgt = by_code.get(val, null) if val != "" else null
		if tgt != null and not is_instance_valid(tgt):
			tgt = null
		out.append({"fd": rd.get("fd", {}), "target": tgt})
	var fields: Array = edef.get("fields", [])
	for fd in fields:
		if not fd is Dictionary or fd.get("type") != "port_ref":
			continue
		var pair := RefFields.paired_map_value(fd, fields, n.props, "id")
		var value = n.props.get(fd.id)
		if not cvs.is_local_port_map(pair) or (value is Dictionary and not cvs.is_local_port_map(str(value.get("map", "")))):
			continue
		var target := by_code.get(value.get("inst", "")) as EntityNode if value is Dictionary else null
		var port := _port_of(target, str(value.get("port", ""))) if value is Dictionary else {}
		var source := _port_of(n, str(fd.get("sourcePort", "")))
		out.append({"fd": fd, "target": target if not port.is_empty() else null,
			"source_port": source, "target_port": port, "bound": value is Dictionary and not value.is_empty()})
	return out

func _port_of(node: EntityNode, id: String) -> Dictionary:
	if not is_instance_valid(node) or id.is_empty():
		return {}
	for port in RefFields.ports_of(node.decl):
		if port is Dictionary and port.get("id") == id:
			return port
	return {}
