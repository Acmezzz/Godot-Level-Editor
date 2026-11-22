extends RefCounted
## 内容表单 + 内容库（复制成新 ID）：从 content_editor.gd 拆出的控制器。宿主 = content_editor 实例（host 引用）。
## 搬迁约定：函数体逐字节原样迁入；跨边界引用经 host 转发——
## 同名 const 重声明 + 同名转发属性 + 同名包装方法，搬动文本零改动。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentId := preload("res://src/content/content_id.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const ProjectAudit := preload("res://src/project/project_audit.gd")   # E3：内容库删除前的引用检查
const BatchOps := preload("res://src/content/batch_ops.gd")   # E2：同功能批量改值
const RelGraph := preload("res://src/content/rel_graph.gd")   # E2：关系图（纯数据 + 写回）
const RelGraphView := preload("res://src/ui/rel_graph_view.gd")
const RIGHT_W := 360

var host   # content_editor 宿主
var app    # 根应用（= host.app）

func _init(h) -> void:
	host = h
	app = h.app

## 同名转发属性（读写穿透到宿主，保住搬动文本零改动）
var manifest: Dictionary:
	get: return host.manifest
var _pending_commits: Array:
	get: return host._pending_commits
var _selected_fn: int:
	get: return host._selected_fn
	set(v): host._selected_fn = v
var _form_id_edit: LineEdit:
	get: return host._form_id_edit
	set(v): host._form_id_edit = v
var _selected_ent: String:
	get: return host._selected_ent
	set(v): host._selected_ent = v
var _preview: Control:
	get: return host._preview
var _r_badge: PanelContainer:
	get: return host._r_badge

## 同名包装方法（真实实现经 host 转发）
## 表单内部调用点都是「换选择前先冲刷控件值」，不落 staged（A2）。
func commit() -> bool:
	host.commit_fields()
	return true
func _current_fns() -> Array:
	return host._current_fns()
func _current_spr() -> EntityNode:
	return host._current_spr()
func _entities() -> Array:
	return host._entities()
func _content_id_for(n: EntityNode, fn_id: String) -> String:
	return host._content_id_for(n, fn_id)
func _map_ready() -> bool:
	return host._map_ready()
func _write_fns(n: EntityNode, fns: Array) -> void:
	host._write_fns(n, fns)
func _refresh_all() -> void:
	host._refresh_all()
func _rebuild_right() -> void:
	host._rebuild_right()
func _rebuild_rows() -> void:
	host._rebuild_rows()
func _open_steps_editor(i: int) -> void:
	host._open_steps_editor(i)
func _resolve_fn(f: Dictionary) -> Dictionary:
	return host._resolve_fn(f)
func _set_parallel(i: int, v: bool) -> void:
	host._set_parallel(i, v)

## 内容表单：字段按功能声明渲染（声明 = 游戏侧契约，编辑器只建控件不解释语义）。
## 内容文件结构 {id, function: 功能码, name, fields:{字段码:值}}。
## 磁盘上的 function/fields 键一律是执行码（ensure_codes 保证），严格按码、无回退。
func _build_form_block() -> Control:
	var box := Kit.vbox(6)
	var fns := _current_fns()
	var i := _selected_fn
	var f: Dictionary = fns[i] if i >= 0 and i < fns.size() and fns[i] is Dictionary else {}
	var ref := _resolve_fn(f)
	var fn_id := str(ref.get("id", ""))
	var content_id := str(f.get("content", ""))
	var fn_label := str(FunctionDecls.function_name(manifest, fn_id)) if bool(ref.get("known", false)) \
		else "(未声明的功能) " + str(f.get("fn", ""))
	var st0 = _staged.get(content_id, null)
	var cres: Dictionary = {"status": "ok", "data": (st0.data as Dictionary).duplicate(true), "error": ""} \
		if st0 is Dictionary and content_id != "" \
		else (ContentStore.read_ex(manifest, fn_id, content_id) if content_id != "" and fn_id != "" \
		else {"status": "missing", "data": {}, "error": ""})
	var data: Dictionary = cres.data if str(cres.status) == "ok" else {}
	var cname := str(data.get("name", "")) if not data.is_empty() else str(f.get("name", ""))

	var head := Kit.hbox(6)
	var title := Kit.text_label("%s 内容" % fn_label, Th.TEXT, Th.FS_SMALL)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	# E2：批量改值入口——同一张图里绑定了同一功能的实例一次改到相同值（先预览再提交）。
	# 只在有多条本功能内容候选时出现，单实例维持「就地填」的最短路径。
	var fn_ent := _batch_candidates(fn_id)
	if fn_ent.size() > 1:
		var bbtn := Kit.button("批量…", func(): _open_batch(fn_id), "ghost")
		bbtn.tooltip_text = "同一功能的多条内容一次改同一字段（先预览命中/跳过/冲突）"
		bbtn.add_theme_font_size_override("font_size", Th.FS_META)
		head.add_child(bbtn)
	# E2：关系图入口——本功能内容条数超过普通搜索可维护的规模时，图比下拉更快。
	# 只在有多条同功能内容时出现（单条没有边可看）。
	var rel_n: int = ContentStore.list_ids(manifest, fn_id).size()
	if rel_n + _staged_count(fn_id) > 1:
		var rbtn := Kit.button("关系…", func(): _open_rel_graph(fn_id), "ghost")
		rbtn.tooltip_text = "按 (功能, 内容) 看引用关系；点边改接/断开，写回同一字段"
		rbtn.add_theme_font_size_override("font_size", Th.FS_META)
		head.add_child(rbtn)
	box.add_child(head)
	# 码漂移：内容文件的 "function" 键与当前功能执行码不一致（清单改码后旧文件仍带旧码）。
	# 只提示不阻断——写盘时会以当前码重写，用户改一次值即自愈。
	var drift := _function_code_drift(data, fn_id)
	if drift != "":
		box.add_child(Kit.text_label("⚠ 内容记录的功能码 %s 与清单当前码 %s 不一致（改动任一字段即按当前码重写）"
			% [drift, FunctionDecls.fn_code(manifest, fn_id)], Th.WARN, Th.FS_META))
	# 损坏内容：拒绝静默覆盖，给显式修复入口（C04）。修复前表单只读。
	if str(cres.status) == "invalid":
		box.add_child(Kit.text_label("⚠ 内容文件损坏，已拒绝写入：%s" % str(cres.error), Th.ERR, Th.FS_META))
		var fix := Kit.button("重建为空白内容（会覆盖坏文件）", func():
			var blank := _blank_content(fn_id, content_id)
			if ContentStore.write(manifest, fn_id, content_id, blank, true):
				app._set_status(" 内容已重建：" + content_id)
				_rebuild_right())
		box.add_child(fix)

	# 只读层级 ID：创建后显示完整 id，未创建时明确写「未创建」而不是伪造一个随机码
	var id_text := content_id
	if id_text == "":
		id_text = "未创建"
	_form_id_edit = LineEdit.new()
	_form_id_edit.text = id_text
	_form_id_edit.editable = false
	_form_id_edit.tooltip_text = "内容 ID：<地图>-<实体类型>-<实例>-<功能>-<随机码>"
	_form_id_edit.add_theme_font_size_override("font_size", Th.FS_META)
	box.add_child(Kit.field_row("ID", _form_id_edit, 40))

	var name_edit := LineEdit.new()
	name_edit.text = cname if cname != "" else fn_id
	name_edit.placeholder_text = "显示名（空则用功能 id）"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_submitted.connect(func(t: String): _commit_name(i, t))
	name_edit.focus_exited.connect(func(): _commit_name(i, name_edit.text))
	box.add_child(Kit.field_row("显示名", name_edit, 56))

	# 演出功能（声明 "steps": true）：只读摘要 + 子面板入口。步骤数组是这类功能
	# 内容的主体；普通字段/条件区照常渲染在下方（演出功能也可以有字段）。
	if FunctionDecls.fn_has_steps(manifest, fn_id):
		var sdata: Array = data.get("steps", []) if data.get("steps", []) is Array else []
		var parts: Array[String] = []
		for st in sdata:
			var sc := str((st as Dictionary).get("step", "")) if st is Dictionary else ""
			parts.append("%d.%s" % [parts.size() + 1, StepDecls.step_name(manifest, sc)])
		var sum := " → ".join(parts) if not parts.is_empty() else "（空演出：还没有步骤）"
		var srow := Kit.hbox(6)
		var slabel := Kit.hint_label("演出步骤：%s" % sum, RIGHT_W - 200)
		slabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		srow.add_child(slabel)
		srow.add_child(Kit.button("编辑演出", func(): _open_steps_editor(i), "primary"))
		box.add_child(srow)
		box.add_child(Kit.divider())

	var fields := FunctionDecls.function_fields(manifest, fn_id)
	if fields.is_empty():
		box.add_child(Kit.hint_label("这个功能没有声明可填字段；填个名字即可。", RIGHT_W - 40))
	var cur: Dictionary = data.get("fields", {}) if data.get("fields", {}) is Dictionary else {}
	for fd in fields:
		if not (fd is Dictionary):
			continue
		box.add_child(_build_field_row(i, fn_id, fd, cur))
	# 条件区：功能声明引用的条件库条目。条件参数是实例上填的——同一条件被不同
	# 实例引用时参数各填各的；值与功能字段共存于同一份内容 fields（键=字段码）。
	var cond_fds: Array = []
	for cid in FunctionDecls.function_decl(manifest, fn_id).get("conditions", []):
		var cond_id := str(cid)
		var cdecl := ConditionDecls.condition_decl(manifest, cond_id)
		if cdecl.is_empty():
			continue
		box.add_child(Kit.divider())
		box.add_child(Kit.section_header("条件：%s" % str(cdecl.get("name", cond_id))))
		var cfields: Array = cdecl.get("fields", [])
		if cfields.is_empty():
			box.add_child(Kit.hint_label("这个条件没有可调参数。", RIGHT_W - 40))
		for fd2 in cfields:
			if not (fd2 is Dictionary):
				continue
			cond_fds.append(fd2)
			box.add_child(_build_field_row(i, fn_id, fd2, cur))
	if content_id == "":
		box.add_child(Kit.hint_label("首次修改任意字段即创建内容条目。", RIGHT_W - 40))
	var undeclared := _undeclared_block(fields, cond_fds, cur)
	if undeclared != null:
		box.add_child(undeclared)
	return box

## 内容里有清单没声明的键——保留原值、只读呈现，不删不改。
## 键一律是字段码；对不上声明码 = 声明被删/换码（数据漂移）。
## fields 与 cond_fields 都算「已知」：条件字段与功能字段共存于同一份 fields。
func _undeclared_block(fields: Array, cond_fields: Array, cur: Dictionary) -> Control:
	var known := {}
	for fd in fields:
		if fd is Dictionary:
			known[str((fd as Dictionary).get("code", ""))] = true
	for fd2 in cond_fields:
		if fd2 is Dictionary:
			known[str((fd2 as Dictionary).get("code", ""))] = true
	var extra := []
	for k in cur:
		if str(k) == "" or known.has(str(k)):
			continue
		extra.append(k)
	if extra.is_empty():
		return null
	extra.sort()
	var box := Kit.vbox(4)
	box.add_child(Kit.hint_label(
		"⚠ %d 个字段未在清单中声明（只读保留，不参与编辑）：" % extra.size(), RIGHT_W - 40))
	for k in extra:
		var v = cur[k]
		var txt := str(v) if (v is String or v is StringName) else JSON.stringify(v)
		var row := LineEdit.new()
		row.text = "%s = %s" % [str(k), txt]
		row.editable = false
		row.add_theme_font_size_override("font_size", Th.FS_META)
		row.tooltip_text = "字段码不在清单声明里（声明被删/换码）。补回声明（code 须一致）即可恢复编辑。"
		box.add_child(row)
	return box

## 单个声明字段：交给 field_widgets 按 kind（input / choice）建控件。
## 内容文件里的键一律是字段码（ensure_codes 保证声明都有码，无回退）。
## E1：同图实例引用额外给「画布选…」——临时切回画布点目标，确认才写值
## （取消时原值/焦点都不动，控件也不重建）。
func _build_field_row(i: int, fn_id: String, fd: Dictionary, cur: Dictionary) -> Control:
	var fid := str(fd.get("id", ""))
	var key := str(fd.get("code", ""))
	var val = cur.get(key, fd.get("default", FieldWidgets.default_for(fd)))
	var label := str(fd.get("name", fid))
	var built := FieldWidgets.build(fd, val, func(v):
		_set_field(i, fn_id, key, v), _resolve_options)
	if built.get("commit") is Callable and (built.commit as Callable).is_valid():
		_pending_commits.append(built.commit)
	var row := Kit.field_row(label, built.ctl, 96)
	if FieldWidgets.wants_canvas_pick(fd):
		var pick := Kit.button("画布选…", func():
			_pick_entity_for(fd, key, func(code): _set_field(i, fn_id, key, code)), "ghost")
		pick.tooltip_text = "临时切到画布点一个实例；确认才写入，取消不改当前值"
		pick.add_theme_font_size_override("font_size", Th.FS_META)
		row.add_child(pick)
	return row

## E1：为一个实例引用字段开画布选点（宿主 = app，会话管理与确认条都在那边）。
## 确认回调只写字段值；字段写盘走与手选下拉同一条 _set_field。
func _pick_entity_for(fd: Dictionary, key: String, commit: Callable) -> void:
	var fname := str(fd.get("name", str(fd.get("id", ""))))
	var label := "为「%s」选目标实例" % fname
	var of := FieldWidgets.canvas_pick_types(fd)
	var hint := label + ("（限定类型：%s）" % ",".join(PackedStringArray(of)) if not of.is_empty() else "")
	# 单独建回调再传：多行 lambda 直接塞进实参列表容易读错缩进边界
	var on_ok := func(code: String):
		if code == "":
			return
		commit.call(code)
		# 下拉控件还停在旧值：提交后重建右栏让新值上屏（用户主动确认的写盘）
		_rebuild_right()
	app._begin_canvas_pick("content", "entity", hint, on_ok, Callable(), of)

## choice.source 的选项来源解析（由游戏侧声明，编辑器只查不解释）。
## 支持：content:<功能id>（内容库）、entity:<id,id>（清单实体类型）、
## entity_inst:<id,id>（当前图实例，值=实例码）、map（值=地图码，显示图名）、audio:（音频池）、
## layer:（当前图用户层栈，值=层码，显示「序号.层名」）、
## asset:<kind>:<id,id>（资产引用，kind 空 = 全部；asset_ref 类型的 input 字段也走这里）。
func _resolve_options(decl: Dictionary) -> Array:
	var src := str(decl.get("source", ""))
	if src.begins_with("content:"):
		var kind := src.substr(8)
		var out: Array = []
		for cid in ContentStore.list_ids(manifest, kind):
			var d := ContentStore.read(manifest, kind, str(cid))
			var nm := str(d.get("name", ""))
			out.append({"v": str(cid), "t": ("%s  %s" % [str(cid), nm]) if nm != "" else str(cid)})
		return out
	if src.begins_with("entity:"):
		var want := src.substr(7).split(",", false)
		var out2: Array = []
		for e in AssetDecl.of_kind_placed(manifest, "entity"):
			var sid := str((e as Dictionary).get("id", ""))
			if not want.is_empty() and not want.has(sid):
				continue
			out2.append({"v": sid, "t": str((e as Dictionary).get("name", sid))})
		return out2
	if src.begins_with("entity_inst:"):
	# 实例级来源：列实例（值=实例码）。目标域 = 声明的 _mapKey（配对地图字段，C1）：
	# 有目标图就枚举目标图实例（跨图引用按 (地图码, 实例码) 语义），否则列当前图。
		var want := src.substr(12).split(",", false)
		var map_key := str(decl.get("_mapKey", ""))
		if map_key != "":
			return RefFields.map_instances(manifest, map_key, Array(want))
		var out4: Array = []
		if _map_ready():
			for e0 in app.canvas.ents_all():
				var spr := e0 as EntityNode
				if spr == null or not spr.is_entity():
					continue
				var sid0 := spr.asset
				if not want.is_empty() and not want.has(sid0):
					continue
				var c0 := spr.code
				if c0 == "":
					continue
				var cell: Vector2i = spr.cell()
				# 标签带实例码：同类型同格的多个实例（多楼层/叠放）靠码区分，否则下拉项完全同名
				out4.append({"v": c0, "t": "%s %s · (%d,%d)" % [
					str(app._scene_name(sid0)), c0, cell.x, cell.y]})
		return out4
	if src == "layer:":
		var outl: Array = []
		var li := 0
		for L in app.canvas.layers_decl():
			outl.append({"v": str(L.get("id", "")), "t": "%d.%s" % [li + 1, str(L.get("name", ""))]})
			li += 1
		return outl
	if src == "audio:":
		# 音频池来源：列音频声明（值=音频码，显示名），路径解释权在游戏侧。
		var out5: Array = []
		for aid in AudioDecls.audio(manifest):
			var ad: Dictionary = (AudioDecls.audio(manifest) as Dictionary)[aid]
			out5.append({"v": str(ad.get("code", "")), "t": str(ad.get("name", aid))})
		return out5
	if src.begins_with("asset:"):
		# asset:<kind>[:<id,id>] —— 资产引用（asset_ref）的选项来源；值 = 资产 id。
		var parts := src.substr(6).split(":", false)
		var want_kind := str(parts[0]) if parts.size() > 0 else ""
		var want_ids: Array = Array(str(parts[1]).split(",", false)) if parts.size() > 1 and str(parts[1]) != "" else []
		var assets := AssetDecl.all(manifest)
		var out6: Array = []
		for a in assets:
			var ad: Dictionary = assets[a]
			var aid := str(ad.get("id", ""))
			if want_kind != "" and str(ad.get("kind", "")) != want_kind:
				continue
			if not want_ids.is_empty() and not want_ids.has(aid):
				continue
			out6.append({"v": aid, "t": str(ad.get("name", aid))})
		return out6
	if src == "map":
		var out3: Array = []
		# 值 = 地图码（v7）：改名不破坏引用；老图缺码时退回图名（保存一次即补码）。
		# 走 code_map 的 mtime+size 签名缓存（C-17）：表单每次刷新不再全量解析地图文件。
		var n2c: Dictionary = MapStore.name_to_code(manifest)
		for mn in MapStore.list_maps(manifest):
			var mc := str(n2c.get(str(mn), ""))
			out3.append({"v": mc if mc != "" else str(mn), "t": str(mn)})
		return out3
	return []


## 读内容：暂存中的条目优先（还没落盘），否则读盘。
func _content_read(fn_id: String, cid: String) -> Dictionary:
	var st = _staged.get(cid, null)
	if st is Dictionary:
		return (st.data as Dictionary).duplicate(true)
	return ContentStore.read(manifest, fn_id, cid)

## 读内容并带出磁盘文本摘要（F1/P04 写前基线）：{data, digest}。
## 暂存条目没有磁盘基线（digest 为空 = 不比对，写盘时只落在 flushed 之后）。
func _content_read_ex(fn_id: String, cid: String) -> Dictionary:
	var st = _staged.get(cid, null)
	if st is Dictionary:
		return {"data": (st.data as Dictionary).duplicate(true), "digest": ""}
	var res := ContentStore.read_ex(manifest, fn_id, cid)
	return {"data": res.data if str(res.status) == "ok" else {},
		"digest": str(res.get("digest", "")) if str(res.status) == "ok" else ""}

## 写内容：暂存中的条目只更新内存（staged），已落盘的条目照旧即时写盘（field_edit 允许）。
## base_digest = 读到内容时的磁盘摘要；非空时写前比对，磁盘被外部改过就不覆盖（P04）。
## 返回 "ok" / "conflict" / "fail"。
func _content_write(fn_id: String, cid: String, data: Dictionary, base_digest := "") -> String:
	var st = _staged.get(cid, null)
	if st is Dictionary:
		(st as Dictionary)["data"] = data.duplicate(true)
		return "ok"
	var res := ContentStore.write_ex(manifest, fn_id, cid, data, base_digest)
	if bool(res.get("conflict", false)):
		return "conflict"
	return "ok" if bool(res.get("ok", false)) else "fail"

## 写前发现磁盘内容被外部改过（F1/P04）：不覆盖、不改画布，只提示去重开。
## 内容文件每次保存都有 .history 备份，但外部改动是别人的工作，静默吞掉比报错更糟。
func _content_conflict(cid: String) -> void:
	app._set_status(" 内容 %s 已被外部修改，本次未写入：重开该实例内容后再改" % cid)

## 字段改动：写内容文件。content 为空时生成 ID 并暂存（A2 staged）。
## 约定：字段值落在 content/<kind>/<id>.json，属「内容资产」而非地图快照——
## 不进画布撤销栈（撤销恢复的是地图，内容文件不回滚）；改绑定的路径（_set_parallel 等）
## 走 _write_fns 各自进撤销。连续控件只在失焦/回车提交。
func _set_field(i: int, fn_id: String, key: String, value) -> void:
	# 字符串字段统一 strip_edges——所有字符串值同一口径，避免同一字段
	# 在两条编辑路径里一个被裁、一个带着首尾空格落盘。
	if value is String:
		value = (value as String).strip_edges()
	var cid := _ensure_content(i)
	if cid == "":
		_ensure_failed()
		return
	var rd := _content_read_ex(fn_id, cid)
	var data: Dictionary = rd.data
	if data.is_empty():
		data = _blank_content(fn_id, cid)
	var fields: Dictionary = data.get("fields", {}) if data.get("fields", {}) is Dictionary else {}
	if fields.get(key, null) == value:
		return
	fields[key] = value
	data["fields"] = fields
	var wr := _content_write(fn_id, cid, data, str(rd.digest))
	if wr == "conflict":
		_content_conflict(cid)
		return
	if wr != "ok":
		_ensure_failed()
		return
	# P04：改字段值不动左列行的「类型名 + 实例码」，只刷预览
	_refresh_value_only()

## 显示名：内容条目的 name；改动写内容文件并同步实例绑定的 name（列表读的是绑定）。
func _commit_name(i: int, text: String) -> void:
	var fns := _current_fns()
	if i < 0 or i >= fns.size():
		return
	var f: Dictionary = fns[i] if fns[i] is Dictionary else {}
	var fn_id := str(_resolve_fn(f).get("id", ""))
	var nm := text.strip_edges()
	if nm == "":
		nm = fn_id
	var cid := str(f.get("content", ""))
	if cid == "":
		# 只改名字不创建内容：绑定里的 name 先记下，保持列表可读
		if str(f.get("name", "")) == nm:
			return
		var spr0 := _current_spr()
		fns = fns.duplicate(true)
		(fns[i] as Dictionary)["name"] = nm
		_write_fns(spr0, fns)
		_refresh_status_only()
		return
	var rd := _content_read_ex(fn_id, cid)
	var data: Dictionary = rd.data
	if data.is_empty():
		return
	if str(data.get("name", "")) == nm:
		return
	data["name"] = nm
	var wr := _content_write(fn_id, cid, data, str(rd.digest))
	if wr == "conflict":
		_content_conflict(cid)
		return
	if wr != "ok":
		_ensure_failed()
		return
	var spr := _current_spr()
	fns = fns.duplicate(true)
	(fns[i] as Dictionary)["name"] = nm
	_write_fns(spr, fns)
	_refresh_status_only()

## 新内容条目骨架：function 写功能码（执行引用），目录名仍是人类名（可读）。
func _blank_content(fn_id: String, cid: String) -> Dictionary:
	return {"id": cid, "function": FunctionDecls.fn_code(manifest, fn_id),
		"name": fn_id, "fields": {}}

## 内容文件的 "function" 键与清单当前执行码不一致时返回文件里的旧码（一致或未记录返回空串）。
## 只用于提示：清单改码后旧内容不会自动重写，等用户下次改动该内容时才以当前码落盘。
func _function_code_drift(data: Dictionary, fn_id: String) -> String:
	if data.is_empty() or fn_id == "":
		return ""
	var stored := str(data.get("function", ""))
	var current := FunctionDecls.fn_code(manifest, fn_id)
	if stored == "" or current == "" or stored == current:
		return ""
	return stored

## 保证该附加功能有 content id：已有绑定直接返回；没有就生成新 ID 但**不写盘**（A2 staged）——
## 新内容要等正式保存/试玩走 commit_document 才落地，避免「打开表单看一眼」就凭空生成文件。
## 暂存信息记在 _staged[fn_code] 里，由 flush_staged() 在正式提交时写入。
## 返回空串 = 生成失败（调用方给出可见反馈，不静默吞掉）。
func _ensure_content(i: int) -> String:
	var fns := _current_fns()
	if i < 0 or i >= fns.size():
		return ""
	var f: Dictionary = fns[i] if fns[i] is Dictionary else {}
	var cid := str(f.get("content", ""))
	if cid != "":
		return cid
	var fn_id := str(_resolve_fn(f).get("id", ""))
	var spr := _current_spr()
	if spr == null or fn_id == "":
		return ""
	var cand := _content_id_for(spr, fn_id)
	var new_id := ContentId.unique(manifest, fn_id, cand)
	if new_id == "":
		return ""
	var nm := str(f.get("name", "")) if str(f.get("name", "")) != "" else fn_id
	var data := _blank_content(fn_id, new_id)
	data["name"] = nm
	# 暂存：只在内存登记，等正式提交再写（staged）
	_staged[new_id] = {"fn_id": fn_id, "data": data, "ent": spr.code, "bind_index": i}
	app._set_status(" 新内容 %s 已暂存：Ctrl+S 或试玩时落盘" % new_id)
	fns = fns.duplicate(true)
	(fns[i] as Dictionary)["content"] = new_id
	(fns[i] as Dictionary)["name"] = nm
	# 新绑定也先写进画布（内存），它同样属于 staged 范围；正式提交时随地图一起落盘
	host._write_fns(spr, fns)
	if _form_id_edit != null:
		_form_id_edit.text = new_id
	return new_id

## 暂存内容：{content_id: {fn_id, data, ent, bind_index}}。正式提交时 flush_staged 写入。
var _staged := {}

## 把暂存内容写盘（A2 正式提交调用）。全部成功返回 true；任一失败停下并保留剩余暂存。
func flush_staged() -> bool:
	if _staged.is_empty():
		return true
	var ids: Array = _staged.keys()
	for cid in ids:
		var st: Dictionary = _staged[cid]
		if not ContentStore.write(manifest, str(st.fn_id), str(cid), st.data):
			_ensure_failed()
			return false
		_staged.erase(cid)
	return true

func has_staged() -> bool:
	return not _staged.is_empty()

## 暂存内容快照（草稿记录用）：{cid: {fn_id, data}}，深拷贝避免外部改动。
func staged_snapshot() -> Dictionary:
	return _staged.duplicate(true)

## 写盘失败：状态栏 + 徽章双重提示（红色徽章在右栏顶部，不依赖状态栏可见性）
## 不再一律甩「目录权限」——真实失败原因多半是身份码没生成或 kind 不合法。
func _ensure_failed() -> void:
	var cur := _current_spr()
	if cur == null:
		app._set_status(" 内容写入失败：当前没有选中实例")
	elif cur.code == "":
		app._set_status("  内容写入失败：这个实例还没有身份码（重新放置一次再试）")
	else:
		app._set_status("  内容写入失败：检查 content 目录是否存在且可写")
	if _r_badge != null:
		_r_badge.visible = true
		Kit.set_badge(_r_badge, "写盘失败", Th.ERR)

## 只刷左列/预览，不重建右栏——表单重建会丢输入焦点，改一个字段就跳走无法连续输入。
## 名字进左列标签，改名后必须重建行；只改字段值时行内容没变，走 _refresh_value_only。
func _refresh_status_only() -> void:
	_rebuild_rows()
	if _preview != null:
		_preview.refresh()

## F1/P04：改字段值只影响内容文件，左列行显示的是「类型名 + 实例码」，一个都不变。
## 原实现每次改值都重建整列控件（满图时几百行 × 每行五个控件），输入大字段时明显卡。
func _refresh_value_only() -> void:
	if _preview != null:
		_preview.refresh()

# ──────────── 库复用弹窗 ────────────

## 列同功能的全部内容条目；选中一条 → 复制成新 ID 追加到当前实例末尾。
## 跨功能不列：字段声明不同，复用没有意义。
## E3：名称筛选 + 改显示名（保 ID）+ 删除（先跑 C3 引用检查，仍被引用时停住）。
func _open_lib(i: int) -> void:
	var fns := _current_fns()
	if i < 0 or i >= fns.size():
		return
	var f: Dictionary = fns[i] if fns[i] is Dictionary else {}
	var fn_id := str(_resolve_fn(f).get("id", ""))
	if fn_id == "":
		return
	var fn_label := str(FunctionDecls.function_name(manifest, fn_id))
	var shell: Dictionary = app._popup_body("选择已有%s内容" % fn_label,
		"选中即复制进当前实例，生成新 ID。改显示名不改 ID；删除前先查引用。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var ids := ContentStore.list_ids(manifest, fn_id)
	# 暂存中的新内容也列进来（还没落盘，但用户可以复用）
	for sid in _staged:
		if str((_staged[sid] as Dictionary).get("fn_id", "")) == fn_id and not ids.has(sid):
			ids.append(sid)
	if ids.is_empty():
		body.add_child(Kit.empty_state("◌", "这个功能还没有已有内容",
			"先在别的实例里填一条，或直接在新实例里新建"))
		body.add_child(Kit.popup_buttons(func(): pop.hide(), func(): pop.hide(), "关闭", "取消"))
		app._open_popup(pop)
		return

	# —— 名称筛选（E3）：按显示名或 id 过滤，不重建弹窗 ——
	var filter := LineEdit.new()
	filter.placeholder_text = "筛选：名称或 id"
	filter.clear_button_enabled = true
	body.add_child(filter)

	var list := ItemList.new()
	list.custom_minimum_size = Vector2(0, 200)
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.max_columns = 1
	var picked := [""]
	# 每行的 {cid, name}：筛选重填时名字从这份快照取（不逐项重读盘）
	var rows: Array = []
	for cid in ids:
		var d := ContentStore.read(manifest, fn_id, str(cid))
		rows.append({"cid": str(cid), "name": str(d.get("name", ""))})
	body.add_child(list)

	var refill := func():
		var q := str(filter.text).strip_edges().to_lower()
		list.clear()
		for r in rows:
			var cid := str((r as Dictionary).get("cid", ""))
			var nm := str((r as Dictionary).get("name", ""))
			if q != "" and not cid.to_lower().contains(q) and not nm.to_lower().contains(q):
				continue
			var it := list.add_item((nm + "  ·  " + cid) if nm != "" else cid)
			list.set_item_metadata(it, cid)
			if nm == "":
				list.set_item_custom_fg_color(it, Th.TEXT_MUTE)

	# —— 改显示名（E3）：只改内容文件的 name，ID 与所有引用不动 ——
	var rename_row := Kit.hbox(6)
	var rename_edit := LineEdit.new()
	rename_edit.placeholder_text = "新显示名（选中条目后可改）"
	rename_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rename_row.add_child(rename_edit)
	var on_rename := func():
		if picked[0] == "":
			app._set_status(" 先选一条内容")
			return
		var nm := rename_edit.text.strip_edges()
		if _rename_library_item(fn_id, picked[0], nm):
			for r in rows:
				if str((r as Dictionary).get("cid", "")) == picked[0]:
					(r as Dictionary)["name"] = nm
			refill.call()
	var rename_btn := Kit.button("改显示名", on_rename, "ghost")
	rename_btn.tooltip_text = "只改显示名；内容 ID 不变，已有引用照常解析"
	rename_row.add_child(rename_btn)
	# —— 删除（E3）：先跑 C3 引用检查；仍被引用或有未扫描文件时停在报告 ——
	var on_del := func():
		if picked[0] == "":
			app._set_status(" 先选一条内容")
			return
		var gone: String = picked[0]
		if not await _delete_library_item(fn_id, gone):
			return
		var keep: Array = []
		for r in rows:
			if str((r as Dictionary).get("cid", "")) != gone:
				keep.append(r)
		rows.clear()
		rows.append_array(keep)
		picked[0] = ""
		refill.call()
	var del_btn := Kit.button("删除…", on_del, "ghost")
	del_btn.add_theme_color_override("font_color", Th.ERR)
	del_btn.tooltip_text = "删除这条内容前先查实例与内容间引用；被引用时不会删"
	rename_row.add_child(del_btn)
	body.add_child(rename_row)

	filter.text_changed.connect(func(_t: String): refill.call())
	refill.call()

	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "新内容显示名"
	body.add_child(Kit.field_row("新名字", name_edit, 56))
	list.item_selected.connect(func(idx: int):
		var cid := str(list.get_item_metadata(idx))
		picked[0] = cid
		var nm := ""
		for r in rows:
			if str((r as Dictionary).get("cid", "")) == cid:
				nm = str((r as Dictionary).get("name", ""))
				break
		if nm == "":
			nm = str(ContentStore.read(manifest, fn_id, cid).get("name", ""))
		name_edit.text = (nm if nm != "" else cid) + " 副本"
		rename_edit.text = nm)

	var on_ok := func():
		if picked[0] == "":
			app._set_status(" 先选一条内容")
			return
		pop.hide()
		_duplicate_from_lib(fn_id, picked[0], name_edit.text, i)
	body.add_child(Kit.popup_buttons(on_ok, func(): pop.hide(), "复用", "取消"))
	app._open_popup(pop)

## E2：同功能批量改值的候选——本图绑定了该功能、且已有内容 ID 的实例。
## 只收实体（场景实例不参与内容绑定）；同一内容 ID 出现多次由 BatchOps 去重。
func _batch_candidates(fn_id: String) -> Array:
	var out: Array = []
	if not _map_ready() or fn_id == "":
		return out
	var fcode := FunctionDecls.fn_code(manifest, fn_id)
	if fcode == "":
		return out
	for e in app.canvas.ents_all():
		var n := e as EntityNode
		if n == null or not n.is_entity():
			continue
		for f in n.functions:
			if not (f is Dictionary):
				continue
			if str((f as Dictionary).get("fn", "")) != fcode:
				continue
			out.append({"node": n, "code": n.code, "cid": str((f as Dictionary).get("content", ""))})
	return out

## E2 批量改值弹窗：选字段（只列同功能可写字段）→ 填目标值（复用原字段控件）
## → 预览命中/跳过/冲突 → 「应用」逐条写。冲突不阻断其余命中，但会逐条列名。
## 批量只改已有内容文件：不新建内容、不碰绑定（绑定编辑走正常表单）。
func _open_batch(fn_id: String) -> void:
	var bfields: Array = BatchOps.batchable_fields(manifest, fn_id)
	if bfields.is_empty():
		app._set_status(" 这个功能没有可批量写入的字段")
		return
	var cand := _batch_candidates(fn_id)
	if cand.is_empty():
		app._set_status(" 本图没有绑定这个功能的实例")
		return
	var shell: Dictionary = app._popup_body("批量改值 · %s" % FunctionDecls.function_name(manifest, fn_id),
		"同一功能的实例改成同一个值。只改已有内容文件；先预览命中、跳过与冲突，确认后逐条写入。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	# 字段选择
	var field_opt := OptionButton.new()
	for r in bfields:
		field_opt.add_item("%s（%s）" % [str((r as Dictionary).get("name", "")), str((r as Dictionary).get("type", ""))])
		field_opt.set_item_metadata(field_opt.item_count - 1, str((r as Dictionary).get("code", "")))
	body.add_child(Kit.field_row("字段", field_opt, 40))
	# 目标值控件位（换字段时重建）
	var value_slot := Kit.vbox(4)
	body.add_child(value_slot)
	var plan_lbl := Kit.hint_label("选字段并填写目标值后点「预览」。", RIGHT_W - 40)
	body.add_child(plan_lbl)
	var apply_btn: Button = Kit.button("应用", func(): pass, "primary")
	apply_btn.disabled = true
	var cur_plan := {}
	# 读控件值 → {v} 或 {err}
	var value_of := func(fd: Dictionary, ctl: Control, commit: Callable) -> Dictionary:
		commit.call()
		# 控件族与 _set_field 一致：CheckBox / OptionButton / LineEdit / SpinBox / 行内多控件
		if ctl is CheckBox:
			return {"v": (ctl as CheckBox).button_pressed}
		if ctl is OptionButton:
			var ob := ctl as OptionButton
			if ob.selected < 0:
				return {"err": "先选一个选项"}
			return {"v": str(ob.get_item_metadata(ob.selected))}
		if ctl is SpinBox:
			return {"v": (ctl as SpinBox).value if str(fd.get("type", "")) != "int" else int((ctl as SpinBox).value)}
		if ctl is LineEdit:
			return {"v": (ctl as LineEdit).text}
		if ctl is TextEdit:
			return {"v": (ctl as TextEdit).text}
		return {"err": "这个字段的控件不支持批量（请在表单里逐个改）"}
	var rebuild := func():
		for c in value_slot.get_children():
			value_slot.remove_child(c)
			c.queue_free()
		var code := str(field_opt.get_item_metadata(field_opt.selected)) if field_opt.selected >= 0 else ""
		apply_btn.disabled = true
		cur_plan = {}
		if code == "":
			return
		var fd: Dictionary = {}
		for r in bfields:
			if str((r as Dictionary).get("code", "")) == code:
				fd = (r as Dictionary).get("fd", {})
				break
		var init = FieldWidgets.default_for(fd)
		var built: Dictionary = FieldWidgets.build(fd, init, func(_v): pass)
		var ctl: Control = built.ctl
		ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		value_slot.add_child(Kit.field_row("目标值", ctl, 48))
		plan_lbl.text = "选字段并填写目标值后点「预览」。"
	var preview := func():
		var code := str(field_opt.get_item_metadata(field_opt.selected)) if field_opt.selected >= 0 else ""
		if code == "":
			app._set_status(" 先选字段")
			return
		var fd: Dictionary = {}
		for r2 in bfields:
			if str((r2 as Dictionary).get("code", "")) == code:
				fd = (r2 as Dictionary).get("fd", {})
				break
		# 控件在 value_slot 的唯一行里：直接取行的子控件
		var got := {"err": "没有目标值控件"}
		if value_slot.get_child_count() > 0:
			var row: Control = value_slot.get_child(0)
			for ch in row.get_children():
				if ch is Control and not (ch is Label):
					got = value_of.call(fd, ch, Callable())
					break
		if str(got.get("err", "")) != "":
			plan_lbl.text = "⚠ " + str(got.get("err", ""))
			apply_btn.disabled = true
			return
		cur_plan = BatchOps.plan_field(manifest, fn_id, cand, code, got.get("v"))
		var txt := BatchOps.plan_text(cur_plan)
		plan_lbl.text = txt
		apply_btn.disabled = str(cur_plan.get("status", "")) != "ok" \
			or (cur_plan.get("targets", []) as Array).is_empty()
	field_opt.item_selected.connect(func(_i: int): rebuild.call())
	var btn_row := Kit.hbox(8)
	btn_row.add_child(Kit.spacer())
	btn_row.add_child(Kit.button("预览", func(): preview.call(), "ghost"))
	btn_row.add_child(apply_btn)
	body.add_child(btn_row)
	# 应用：逐条写（内容编辑器提供 staged 感知读写，不让内存里的新内容被覆盖）
	apply_btn.pressed.connect(func():
		if str(cur_plan.get("status", "")) != "ok":
			return
		var plan := cur_plan.duplicate(true)
		pop.hide()
		var res := BatchOps.apply_field(manifest, fn_id, plan,
			func(fid: String, cid: String) -> Dictionary: return _content_read(fid, cid),
			func(fid: String, cid: String, data: Dictionary) -> bool:
				return _content_write(fid, cid, data) == "ok")
		var failed := (res.get("failed", []) as Array)
		var msg := "批量改值：写入 %d 条" % int(res.get("written", 0))
		if not failed.is_empty():
			var parts: Array[String] = []
			for f in failed:
				parts.append("%s（%s）" % [str((f as Dictionary).get("cid", "")), str((f as Dictionary).get("why", ""))])
			msg += "，失败 %d 条：%s" % [failed.size(), "；".join(parts)]
		app._set_status(msg)
		_refresh_status_only()
		if host != null and host.has_method("_rebuild_right"):
			host._rebuild_right())
	rebuild.call()
	app._open_popup(pop)

## E2：本功能里尚未落盘的内容条数（关系图入口的出现条件用）。
func _staged_count(fn_id: String) -> int:
	var n := 0
	for cid in _staged:
		if str((_staged[cid] as Dictionary).get("fn_id", "")) == fn_id:
			n += 1
	return n

## E2 关系图：节点 = (功能, 内容)，边 = 声明的内容引用字段/步骤字段。
## 点节点 = 在列表里定位那条内容；点边 = 改接（选目标）或断开（复用 C1 清空语义）。
## 写回走 _content_read/_content_write，与表单同一条路径（staged 感知）——两边改完一致。
func _open_rel_graph(fn_id: String) -> void:
	commit()
	# 状态放字典里（lambda 按值捕获局部变量，重新赋值传不出去）
	var cur := {"g": RelGraph.build(manifest, fn_id, _staged_for(fn_id))}
	if (cur.g.get("nodes", []) as Array).is_empty():
		app._set_status(" 这个功能还没有内容条目，关系图无从画起")
		return
	var shell: Dictionary = app._popup_body("关系图 · %s" % FunctionDecls.function_name(manifest, fn_id),
		"点节点跳到该内容；点连线改接或断开。节点按 (功能, 内容 ID) 区分，循环引用合法。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var view = RelGraphView.new()   # 动态类型：on_pick/on_edge 是本控件脚本上的属性
	view.custom_minimum_size = Vector2(720, 420)
	var locate := func(key: String) -> void:
		var parts := key.split("\u0001")
		var tf := str(parts[0]) if parts.size() > 0 else ""
		var tc := str(parts[1]) if parts.size() > 1 else ""
		if tf != fn_id:
			app._set_status(" 这条内容属于功能 %s（%s），请到那个功能下编辑" % [
				FunctionDecls.function_name(manifest, tf), tc])
			return
		pop.hide()
		_locate_content(fn_id, tc)
	var info: Label = Kit.hint_label("", 700)
	var refresh := func() -> void:
		cur.g = RelGraph.build(manifest, fn_id, _staged_for(fn_id))
		view.set_data(cur.g)
		info.text = _rel_graph_hint(cur.g)
	var on_edge := func(e: Dictionary) -> void:
		_open_rel_edge(fn_id, e, func(): refresh.call())
	view.on_pick = locate
	view.on_edge = on_edge
	view.set_data(cur.g)
	body.add_child(view)
	info.text = _rel_graph_hint(cur.g)
	body.add_child(info)
	body.add_child(Kit.hint_label("● 节点 = 内容（下方小字是内容 ID 尾段）　→ 边 = 声明字段；点边改接/断开", 700))
	var close := func(): pop.hide()
	body.add_child(Kit.popup_buttons(close, close, "关闭", "关闭"))
	app._open_popup(pop, Vector2i(760, 580))

## 本功能尚未落盘的内容 {cid: data}（关系图建图时覆盖同名盘上条目）。
func _staged_for(fn_id: String) -> Dictionary:
	var out := {}
	for cid in _staged:
		var st: Dictionary = _staged[cid] if _staged[cid] is Dictionary else {}
		if str(st.get("fn_id", "")) == fn_id and st.get("data", null) is Dictionary:
			out[str(cid)] = st.get("data", {})
	return out

func _rel_graph_hint(g: Dictionary) -> String:
	var parts: Array[String] = []
	parts.append("内容 %d 条 · 关系 %d 条" % [(g.get("nodes", []) as Array).size(), (g.get("edges", []) as Array).size()])
	var ext: Array = g.get("external", [])
	if not ext.is_empty():
		parts.append("⚠ %d 条引用指向不存在的内容（在表单里修正）" % ext.size())
	var bad: Array = g.get("bad", [])
	if not bad.is_empty():
		parts.append("⚠ %d 个内容文件读不出" % bad.size())
	return "　".join(parts)

## 点边 → 小弹窗：改接到某条内容 / 断开（清空字段）。
func _open_rel_edge(fn_id: String, ed: Dictionary, after: Callable) -> void:
	var label := str(ed.get("label", ed.get("field", "")))
	var multi := bool(ed.get("multi", false))
	var shell: Dictionary = app._popup_body("改关系 · %s" % label,
		"字段 %s（%s）。改接写回同一字段；断开 = 清空（与表单「未设置」一致）。" % [
			str(ed.get("field", "")), "多选：只改这一条目标" if multi else "单选"])
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var decl: Dictionary = ed.get("decl", {}) if ed.get("decl", null) is Dictionary else {}
	var opts: Array = _resolve_options(decl)
	var opt := OptionButton.new()
	opt.add_item("（未设置 / 断开）")
	opt.set_item_metadata(0, "")
	var cur_to := str(ed.get("to", "")).substr(str(ed.get("to", "")).find("\u0001") + 1)
	var sel_i := 0
	for o in opts:
		var ov := str((o as Dictionary).get("v", ""))
		opt.add_item(str((o as Dictionary).get("t", ov)))
		opt.set_item_metadata(opt.item_count - 1, ov)
		if ov == cur_to:
			sel_i = opt.item_count - 1
	opt.select(sel_i)
	body.add_child(Kit.field_row("目标", opt, 48))
	var do_it := func() -> void:
		var want := str(opt.get_item_metadata(opt.selected)) if opt.selected >= 0 else ""
		pop.hide()
		var res := RelGraph.set_edge(_content_read, _content_write, fn_id, str(ed.get("cid", "")),
			int(ed.get("step", -1)), str(ed.get("field", "")), want, multi, cur_to)
		var st := str(res.get("status", ""))
		if st == "ok":
			app._set_status("关系已%s：%s" % ["断开" if want == "" else "改接", label])
		elif st == "noop":
			app._set_status("关系未变（%s）" % label)
		elif st == "missing":
			app._set_status(" 改关系失败：目标内容或字段已不存在，先刷新")
		else:
			app._set_status(" 改关系失败：内容文件写入被拒绝（损坏或被占用？）")
		after.call()
	body.add_child(Kit.popup_buttons(do_it, func(): pop.hide(), "应用", "取消"))
	app._open_popup(pop)

## 关系图点节点 → 在左列选中那条内容（同一实例已绑定时直接展开）。
## 内容 ID 可能属于别的实例：从实例快照里反查绑定，选中后展开对应功能。
func _locate_content(fn_id: String, cid: String) -> void:
	if cid == "":
		return
	var fcode := FunctionDecls.fn_code(manifest, fn_id)
	for row in _entities():
		var r: Dictionary = row
		var fns: Array = r.get("fns", [])
		for i in fns.size():
			var f: Dictionary = fns[i] if fns[i] is Dictionary else {}
			if str(f.get("content", "")) != cid:
				continue
			if fcode != "" and str(f.get("fn", "")) != fcode:
				continue
			var code := str(r.get("code", ""))
			if code != _selected_ent:
				host.select_inst(code)
			_selected_fn = i
			_rebuild_right()
			app._set_status("已定位内容 %s（实例 %s）" % [cid, code])
			return
	app._set_status(" 内容 %s 还没有绑定到本图任何实例；绑上后才能编辑" % cid)
## 返回是否真的改了（调用方据此刷新列表快照）。
func _rename_library_item(fn_id: String, cid: String, new_name: String) -> bool:
	var nm := new_name.strip_edges()
	if nm == "":
		app._set_status(" 先填新显示名")
		return false
	var rd := _content_read_ex(fn_id, cid)
	var data: Dictionary = rd.data
	if data.is_empty():
		app._set_status(" 读不到内容 %s（文件缺失或损坏）" % cid)
		return false
	if str(data.get("name", "")) == nm:
		return false
	data["name"] = nm
	var wr := _content_write(fn_id, cid, data, str(rd.digest))
	if wr == "conflict":
		app._set_status(" 内容 %s 已被外部修改，改显示名未写入" % cid)
		return false
	if wr != "ok":
		app._set_status(" 改显示名失败：内容文件不可写")
		return false
	# 绑定里冗余的 name 只影响列表显示：引用字段是 content ID，改名不动它
	app._set_status(" 已改显示名：%s → %s（ID 与引用不变）" % [cid, nm])
	_refresh_status_only()
	return true

## E3：库内删除——先跑 C3 引用检查。三条拦截线：
##   ① 有地图/实例仍引用该内容（含当前画布的未保存绑定）→ 列出后停住；
##   ② 其它内容的引用字段指向它（内容间入边）→ 删除会让那些引用悬空；
##   ③ 有未扫描/读不出的文件（地图或内容）→ 范围不完整，只提示不动手。
## 全部通过才走确认框并删文件（内容文件有 .history 备份可找回）。
## 返回是否真的删了（调用方据此从列表快照里去掉该行）。
func _delete_library_item(fn_id: String, cid: String) -> bool:
	# 当前画布的未保存绑定也算引用（磁盘是旧的）
	var live_codes: Array = []
	var spr := _current_spr()
	if spr != null and is_instance_valid(spr):
		for f in spr.functions:
			if not (f is Dictionary):
				continue
			if str((f as Dictionary).get("content", "")) != cid:
				continue
			if str((f as Dictionary).get("fn", "")) == FunctionDecls.fn_code(manifest, fn_id):
				live_codes.append(spr.code)
				break
	var cur_map := str(app.cur_map_name) if app.map_loaded else ""
	var usage: Dictionary = ProjectAudit.content_usage(manifest, fn_id, cid, cur_map, live_codes)
	if bool(usage.get("incomplete", false)):
		var why: Array[String] = []
		var ur: Array = usage.get("unreadable", [])
		if not ur.is_empty():
			why.append("有地图读不出来（%s）" % ", ".join(PackedStringArray(ur)))
		var bc: Array = usage.get("bad_contents", [])
		if not bc.is_empty():
			why.append("有内容文件读不出来（%s）" % ", ".join(PackedStringArray(bc)))
		app._set_status(" 删除中止：检查范围不完整——" + "；".join(why) + "。先修好这些文件再试")
		return false
	var by_map: Dictionary = usage.get("by_map", {})
	if not by_map.is_empty():
		var lines: Array[String] = []
		var total := 0
		for mn in by_map:
			var codes: Array = by_map[mn]
			total += codes.size()
			lines.append("%s × %d（%s）" % [str(mn), codes.size(),
				", ".join(PackedStringArray(codes.slice(0, 4)))])
		app._set_status(" 删除中止：%s 仍被 %d 个实例引用——%s。先改绑到别的内容或删掉那些绑定" % [
			cid, total, "；".join(lines)])
		return false
	# ② 其它内容文件的引用型字段指向它（内容 → 内容的入边）：删了那些引用就悬空
	var inbound: Array = ProjectAudit.content_inbound_refs(manifest, fn_id, cid)
	if not inbound.is_empty():
		var refs: Array[String] = []
		for r in inbound:
			refs.append("%s/%s.%s" % [str((r as Dictionary).get("kind", "")),
				str((r as Dictionary).get("id", "")), str((r as Dictionary).get("field", ""))])
		app._set_status(" 删除中止：另有 %d 份内容的引用字段指向它（%s）。先清掉那些字段" % [
			inbound.size(), ", ".join(PackedStringArray(refs.slice(0, 5)))])
		return false
	var nm := str(_content_read(fn_id, cid).get("name", ""))
	var text := "将删除内容「%s」(%s)。\n\n当前没有任何实例或内容引用它；文件会从 content/%s/ 移除（.history 有备份）。" % [
		nm if nm != "" else cid, cid, fn_id]
	if not await app._confirm_action("删除内容", text, "删除"):
		return false
	if not ContentStore.remove(manifest, fn_id, cid):
		app._set_status(" 删除失败：内容文件不可删（可能被占用）")
		return false
	app._set_status(" 已删除内容：%s/%s" % [fn_id, cid])
	return true

## 复制成新 ID：深拷贝整份源内容（保留原文件不动），name 用弹窗里填的。
## 继承行（类型挂载行）复用 = 把副本填进**这一行**，不追加同码第二条
## ——追加会让「唯一继承行」无从辨认，也把挂载行变成了两条同码（C09）。
## 附加功能复用 = 追加一条新绑定到末尾并选中。
func _duplicate_from_lib(fn_id: String, old_id: String, new_name: String, bind_index := -1) -> void:
	var src := _content_read(fn_id, old_id)
	if src.is_empty():
		app._set_status(" 读不到内容 %s（文件缺失或损坏）" % old_id)
		return
	var spr := _current_spr()
	if spr == null:
		return
	var cand := _content_id_for(spr, fn_id)
	var new_id := ContentId.unique(manifest, fn_id, cand)
	if new_id == "":
		app._set_status(" 新内容 ID 生成失败（缺分层身份码或撞码重试耗尽）")
		return
	var nm := new_name.strip_edges()
	if nm == "":
		nm = str(src.get("name", "")) if str(src.get("name", "")) != "" else fn_id
	# 以整份源内容为底（顶层未知键原样带走），只覆盖身份三键
	var data: Dictionary = src.duplicate(true)
	data["id"] = new_id
	data["function"] = FunctionDecls.fn_code(manifest, fn_id)
	data["name"] = nm
	if not (data.get("fields", null) is Dictionary):
		data["fields"] = {}
	if not (data.get("steps", null) is Array):
		data["steps"] = []
	# 新内容 + 新绑定都属于 staged 范围（A2）：先暂存，等正式保存/试玩再落盘
	commit()   # 复制库内容前先落盘当前表单待提交值（下标保持有效）
	var fns := _current_fns().duplicate(true)
	if bind_index >= 0 and bind_index < fns.size() and fns[bind_index] is Dictionary:
		# 继承行复用：内容填进原行，行身份（mounted 标记/时机/并行）原样保留
		_staged[new_id] = {"fn_id": fn_id, "data": data, "ent": spr.code, "bind_index": bind_index}
		(fns[bind_index] as Dictionary)["content"] = new_id
		(fns[bind_index] as Dictionary)["name"] = nm
		_selected_fn = bind_index
	else:
		_staged[new_id] = {"fn_id": fn_id, "data": data, "ent": spr.code, "bind_index": -1}
		# 绑定里写执行码；码由 ensure_codes 保证非空
		fns.append({"fn": FunctionDecls.fn_code(manifest, fn_id), "content": new_id, "name": nm,
			"order": fns.size() + 1, "parallel": false})
		_selected_fn = fns.size() - 1
	_write_fns(spr, fns)
	_refresh_all()
	app._set_status(" 已复制「%s」为新内容 %s" % [nm, new_id])
