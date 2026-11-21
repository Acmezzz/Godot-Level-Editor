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
var _preview: Control:
	get: return host._preview
var _r_badge: PanelContainer:
	get: return host._r_badge

## 同名包装方法（真实实现经 host 转发）
func commit() -> bool:
	return host.commit()
func _current_fns() -> Array:
	return host._current_fns()
func _current_spr() -> EntityNode:
	return host._current_spr()
func _content_id_for(n: EntityNode, fn_id: String) -> String:
	return host._content_id_for(n, fn_id)
func _map_ready() -> bool:
	return host._map_ready()
func _write_fns(n: EntityNode, fns: Array) -> void:
	host._write_fns(n, fns)
func _refresh_all() -> void:
	host._refresh_all()
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
	var data: Dictionary = ContentStore.read(manifest, fn_id, content_id) if content_id != "" and fn_id != "" else {}
	var cname := str(data.get("name", "")) if not data.is_empty() else str(f.get("name", ""))

	var head := Kit.hbox(6)
	var title := Kit.text_label("%s 内容" % fn_label, Th.TEXT, Th.FS_SMALL)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	box.add_child(head)
	# 码漂移：内容文件的 "function" 键与当前功能执行码不一致（清单改码后旧文件仍带旧码）。
	# 只提示不阻断——写盘时会以当前码重写，用户改一次值即自愈。
	var drift := _function_code_drift(data, fn_id)
	if drift != "":
		box.add_child(Kit.text_label("⚠ 内容记录的功能码 %s 与清单当前码 %s 不一致（改动任一字段即按当前码重写）"
			% [drift, FunctionDecls.fn_code(manifest, fn_id)], Th.WARN, Th.FS_META))

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
func _build_field_row(i: int, fn_id: String, fd: Dictionary, cur: Dictionary) -> Control:
	var fid := str(fd.get("id", ""))
	var key := str(fd.get("code", ""))
	var val = cur.get(key, fd.get("default", FieldWidgets.default_for(fd)))
	var label := str(fd.get("name", fid))
	var built := FieldWidgets.build(fd, val, func(v):
		_set_field(i, fn_id, key, v), _resolve_options)
	if built.get("commit") is Callable and (built.commit as Callable).is_valid():
		_pending_commits.append(built.commit)
	return Kit.field_row(label, built.ctl, 96)

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
		for e in AssetDecl.of_kind(manifest, "entity"):
			var sid := str((e as Dictionary).get("id", ""))
			if not want.is_empty() and not want.has(sid):
				continue
			out2.append({"v": sid, "t": str((e as Dictionary).get("name", sid))})
		return out2
	if src.begins_with("entity_inst:"):
	# 实例级来源：列当前图里这些类型的实例（值=实例码）。类型列表空 = 全部实例。
		var want := src.substr(12).split(",", false)
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
				out4.append({"v": c0, "t": "%s · (%d,%d)" % [str(app._scene_name(sid0)), cell.x, cell.y]})
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


## 字段改动：写内容文件。content 为空时首次改动即创建条目（ID 生成 + 绑定回写）。
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
	var data: Dictionary = ContentStore.read(manifest, fn_id, cid)
	if data.is_empty():
		data = _blank_content(fn_id, cid)
	var fields: Dictionary = data.get("fields", {}) if data.get("fields", {}) is Dictionary else {}
	if fields.get(key, null) == value:
		return
	fields[key] = value
	data["fields"] = fields
	if not ContentStore.write(manifest, fn_id, cid, data):
		_ensure_failed()
		return
	_refresh_status_only()

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
	var data: Dictionary = ContentStore.read(manifest, fn_id, cid)
	if data.is_empty():
		return
	if str(data.get("name", "")) == nm:
		return
	data["name"] = nm
	if not ContentStore.write(manifest, fn_id, cid, data):
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

## 保证该附加功能有 content id：没有就生成并写一条空内容 + 回写绑定。
## 返回空串 = 生成/写盘失败（调用方给出可见反馈，不静默吞掉）。
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
	if not ContentStore.write(manifest, fn_id, new_id, data):
		return ""
	fns = fns.duplicate(true)
	(fns[i] as Dictionary)["content"] = new_id
	(fns[i] as Dictionary)["name"] = nm
	_write_fns(spr, fns)
	if _form_id_edit != null:
		_form_id_edit.text = new_id
	return new_id

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
func _refresh_status_only() -> void:
	_rebuild_rows()
	if _preview != null:
		_preview.refresh()

# ──────────── 库复用弹窗 ────────────

## 列同功能的全部内容条目；选中一条 → 复制成新 ID 追加到当前实例末尾。
## 跨功能不列：字段声明不同，复用没有意义。
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
		"选中即复制进当前实例，生成新 ID")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var ids := ContentStore.list_ids(manifest, fn_id)
	if ids.is_empty():
		body.add_child(Kit.empty_state("◌", "这个功能还没有已有内容",
			"先在别的实例里填一条，或直接在新实例里新建"))
		body.add_child(Kit.popup_buttons(func(): pop.hide(), func(): pop.hide(), "关闭", "取消"))
		app._open_popup(pop)
		return

	var list := ItemList.new()
	list.custom_minimum_size = Vector2(0, 200)
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.max_columns = 1
	var picked := [""]
	for cid in ids:
		var d := ContentStore.read(manifest, fn_id, str(cid))
		var nm := str(d.get("name", ""))
		var it := list.add_item((nm + "  ·  " + str(cid)) if nm != "" else str(cid))
		list.set_item_metadata(it, str(cid))
		if nm == "":
			list.set_item_custom_fg_color(it, Th.TEXT_MUTE)
	body.add_child(list)

	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "新内容显示名"
	body.add_child(Kit.field_row("新名字", name_edit, 56))
	list.item_selected.connect(func(idx: int):
		var cid := str(list.get_item_metadata(idx))
		picked[0] = cid
		var nm := str(ContentStore.read(manifest, fn_id, cid).get("name", ""))
		name_edit.text = (nm if nm != "" else cid) + " 副本")

	var on_ok := func():
		if picked[0] == "":
			app._set_status(" 先选一条内容")
			return
		pop.hide()
		_duplicate_from_lib(fn_id, picked[0], name_edit.text)
	body.add_child(Kit.popup_buttons(on_ok, func(): pop.hide(), "复用", "取消"))
	app._open_popup(pop)

## 复制成新 ID：深拷贝 fields，name 用弹窗里填的；追加到实例附加功能末尾并选中。
func _duplicate_from_lib(fn_id: String, old_id: String, new_name: String) -> void:
	var src := ContentStore.read(manifest, fn_id, old_id)
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
	if not ContentStore.write(manifest, fn_id, new_id, data):
		app._set_status(" 写盘失败: content/%s/%s.json" % [fn_id, new_id])
		return
	commit()   # 复制库内容前先落盘当前表单待提交值（下标保持有效）
	var fns := _current_fns().duplicate(true)
	# 绑定里写执行码；码由 ensure_codes 保证非空
	fns.append({"fn": FunctionDecls.fn_code(manifest, fn_id), "content": new_id, "name": nm,
		"order": fns.size() + 1, "parallel": false})
	_selected_fn = fns.size() - 1
	_write_fns(spr, fns)
	_refresh_all()
	app._set_status(" 已复制「%s」为新内容 %s" % [nm, new_id])
