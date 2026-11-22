extends RefCounted
## RefOps：实例 props 引用字段的统一写入口（E2 空间连线 / E1 画布选点 / 内容表单下拉）。
##
## 三条路径写同一份数据就不能各写一遍规则：改配对地图字段时旧落点属于原图（C1），
## 必须先确认再把配对引用一起清空；改动进画布撤销栈（props 是地图数据）。
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
	if props.get(fid, null) == value:
		return {"status": "ok", "cleared": []}
	# 该字段是否被其它 entity_ref 的 mapField 配对（改目标图 → 旧落点跨图失效）
	var edef: Dictionary = AssetDecl.by_id(app.manifest, n.asset)
	var paired_refs: Array = []
	for other in (edef.get("fields", []) as Array):
		if other is Dictionary and str((other as Dictionary).get("mapField", "")) == fid:
			if str(props.get(str((other as Dictionary).get("id", "")), "")) != "":
				paired_refs.append(other)
	if not paired_refs.is_empty():
		var msg := "改目标地图会清空 %d 个已填引用（旧落点属于原图）。继续？" % paired_refs.size()
		if not await app._confirm_action("改目标地图", msg, "改并清空"):
			return {"status": "cancelled", "cleared": []}
	# §7.5 阶段二：引用值改的是这一条实例的 props → InstanceKey 差量。
	var pre: Dictionary = cvs._undo_history_ctrl.inst_rows([n])
	var via_delta := bool(pre.get("ok", false))
	if not via_delta:
		cvs.push_undo()
	if value == "":
		props.erase(fid)
	elif value is Dictionary and (value as Dictionary).is_empty():
		props.erase(fid)   # §7.4：「未设置」的 edge_ref 也是空对象，落盘按缺键
	else:
		props[fid] = value
	var cleared: Array = []
	for other2 in paired_refs:
		var oid := str((other2 as Dictionary).get("id", ""))
		props.erase(oid)
		cleared.append(oid)
	n.props = props
	if via_delta:
		cvs._undo_history_ctrl.inst_commit(pre.get("rows", {}))
	cvs._mark_ents()   # 阶段三：只改实例 props，瓦片/碰撞镜像不动
	# 指向预览：仅本图 entity_ref 高亮（跨图/地图引用在本图没有可亮对象）
	var target := str(value) if value is String and app.canvas.is_entity_code_local(value) else ""
	cvs.ref_highlight = target
	cvs.queue_redraw()
	if value == "" or (value is Dictionary and (value as Dictionary).is_empty()):
		app._set_status("已清空引用「%s」" % str(fd.get("name", fid)))
	elif value is Dictionary:
		app._set_status("引用「%s」→ %s（Ctrl+Z 撤销）" % [
			str(fd.get("name", fid)), str((value as Dictionary).get("edge", ""))])
	else:
		app._set_status("引用「%s」→ %s（Ctrl+Z 撤销）" % [str(fd.get("name", fid)), str(value)])
	return {"status": "ok", "cleared": cleared}

## 目标实例是否满足字段的 of 白名单（空 = 不限）。拖连线/画布选点共用。
func accepts(fd: Dictionary, n: EntityNode) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	return RefFields.field_accepts(fd, n.asset)

## 本图可连的 entity_ref 字段（配对地图为空或指向本图）。
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
		out.append({"fd": rd.get("fd", {}), "value": val, "target": tgt})
	return out
