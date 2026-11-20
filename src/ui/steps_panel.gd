extends RefCounted
## 演出子面板：从 content_editor.gd 拆出的控制器。宿主 = content_editor 实例（host 引用）。
## 搬迁约定：函数体逐字节原样迁入；跨边界引用经 host 转发——
## 同名 const 重声明 + 同名转发属性 + 同名包装方法，搬动文本零改动。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const StepTimeline := preload("res://src/content/step_timeline.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")

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

## 同名包装方法（真实实现经 host 转发）
func commit() -> bool:
	return host.commit()
func _current_fns() -> Array:
	return host._current_fns()
func _ensure_content(i: int) -> String:
	return host._ensure_content(i)
func _ensure_failed() -> void:
	host._ensure_failed()
func _refresh_status_only() -> void:
	host._refresh_status_only()
func _resolve_fn(f: Dictionary) -> Dictionary:
	return host._resolve_fn(f)
func _resolve_options(decl: Dictionary) -> Array:
	return host._resolve_options(decl)
func _rebuild_right() -> void:
	host._rebuild_right()

var _steps_pop: PopupPanel = null
var _steps_i := -1            # 正在编辑的绑定行下标
var _steps_fn_id := ""        # 该绑定的功能 id
var _steps_sel := -1          # 当前选中步骤下标；-1 = 无
var _steps_list: VBoxContainer = null
var _steps_form: VBoxContainer = null
# 时间轴视图页签（第 4 批）：同一份 steps，两种呈现。
var _steps_view := "list"     # "list" / "timeline"
var _steps_tabs: HBoxContainer = null
var _steps_tl_box: VBoxContainer = null
var _steps_scroll: ScrollContainer = null
var _steps_tl: TimelineView = null

## 打开演出子面板：先保证内容条目存在（首改即建），再建弹窗填步骤列表。
func _open_steps_editor(i: int) -> void:
	commit()   # 主表单待提交值先落盘：子面板写盘不该挤掉未提交值
	var fns := _current_fns()
	var f: Dictionary = fns[i] if i >= 0 and i < fns.size() and fns[i] is Dictionary else {}
	var fn_id := str(_resolve_fn(f).get("id", ""))
	if fn_id == "":
		return
	if _ensure_content(i) == "":
		_ensure_failed()
		return
	_steps_i = i
	_steps_fn_id = fn_id
	_steps_sel = -1
	_steps_view = "list"
	var shell: Dictionary = app._popup_body("演出编辑：%s" % FunctionDecls.function_name(manifest, fn_id),
		"步骤按 at/duration/track 排布；列表保序、时间轴可拖")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	_steps_pop = pop
	_steps_list = Kit.vbox(4)
	_steps_tl_box = Kit.vbox(4)
	_steps_form = Kit.vbox(6)
	_build_steps_tabs(body)
	body.add_child(_steps_list)
	body.add_child(_steps_tl_box)
	body.add_child(Kit.divider())
	body.add_child(_steps_form)
	# 时间轴视图建一次、反复复用（set_steps 换数据源）；滚动容器兜住超宽/超高的排布
	_steps_tl = TimelineView.new()
	_steps_tl.set_steps([], _step_name_of)
	_steps_tl.picked.connect(func(idx: int): _steps_pick_tl(idx))
	_steps_tl.changed.connect(_on_steps_tl_changed)
	_steps_scroll = ScrollContainer.new()
	_steps_scroll.custom_minimum_size = Vector2(0, 120)
	_steps_scroll.add_child(_steps_tl)
	_steps_tl_box.add_child(_steps_scroll)
	pop.popup_hide.connect(func(): _rebuild_right())
	_rebuild_steps_all()
	app._open_popup(pop)

## 页签：列表 / 时间轴。同一份数据，两种呈现。
func _build_steps_tabs(parent: Control) -> void:
	_steps_tabs = Kit.hbox(6)
	var grp := ButtonGroup.new()
	for pair in [["列表", "list"], ["时间轴", "timeline"]]:
		var b := Kit.button(str(pair[0]), func(): _set_steps_view(str(pair[1])), "ghost")
		b.toggle_mode = true
		b.button_group = grp
		b.set_meta("view", str(pair[1]))
		_steps_tabs.add_child(b)
	parent.add_child(_steps_tabs)

func _set_steps_view(mode: String) -> void:
	if mode != "list" and mode != "timeline":
		return
	_steps_view = mode
	_rebuild_steps_all()

func _sync_steps_tabs() -> void:
	if _steps_tabs == null:
		return
	for c in _steps_tabs.get_children():
		var b := c as Button
		if b != null:
			b.button_pressed = str(b.get_meta("view", "")) == _steps_view

## 时间轴名称回调：未知码原样返回（视图据此画 ⚠）。
func _step_name_of(sc: String) -> String:
	var d: Dictionary = StepDecls.step_by_code(manifest, sc)
	return str(d.get("name", sc)) if not d.is_empty() else sc

## 时间轴点选：只换选中与表单，不重建视图（拖拽进行中 picked 会被发多次）。
func _steps_pick_tl(idx: int) -> void:
	_steps_sel = idx
	if _steps_tl != null and is_instance_valid(_steps_tl):
		_steps_tl.sel = idx
		_steps_tl.queue_redraw()
	_rebuild_steps_form_from_data()

## 当前正在编辑的演出内容（绑定 _steps_i 的内容文件）；读不到返回 {}。
func _steps_data() -> Dictionary:
	var fns := _current_fns()
	if _steps_i < 0 or _steps_i >= fns.size() or not (fns[_steps_i] is Dictionary):
		return {}
 # 身份校验：绑定行的功能已不是开面板时的那个 → 数据源失效（防串内容）
	if str(_resolve_fn(fns[_steps_i]).get("id", "")) != _steps_fn_id:
		return {}
	var cid := str((fns[_steps_i] as Dictionary).get("content", ""))
	return ContentStore.read(manifest, _steps_fn_id, cid) if cid != "" else {}

## 写回演出内容；失败给可见反馈，不静默吞掉。
func _steps_write(data: Dictionary) -> void:
	var fns := _current_fns()
	if _steps_i < 0 or _steps_i >= fns.size() or not (fns[_steps_i] is Dictionary):
		return
 # 身份校验同 _steps_data：绑定行功能对不上就不写（防串内容）
	if str(_resolve_fn(fns[_steps_i]).get("id", "")) != _steps_fn_id:
		return
	var cid := str((fns[_steps_i] as Dictionary).get("content", ""))
	if cid == "":
		return
	if not ContentStore.write(manifest, _steps_fn_id, cid, data):
		_ensure_failed()

## 重建子面板：页签同步 + 列表/时间轴互斥重建 + 当前步骤表单。
func _rebuild_steps_all() -> void:
	if _steps_list == null or _steps_form == null:
		return
	_sync_steps_tabs()
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if _steps_view == "timeline":
		_steps_list.visible = false
		_steps_tl_box.visible = true
		_rebuild_steps_tl(arr)
	else:
		_steps_tl_box.visible = false
		_steps_list.visible = true
		_rebuild_steps_list(arr)
	_rebuild_steps_form(arr)

## 步骤列表（列表视图）：空态 + 逐行渲染。
func _rebuild_steps_list(arr: Array) -> void:
	if _steps_list == null:
		return
	for c in _steps_list.get_children():
		_steps_list.remove_child(c)
		c.queue_free()
	if arr.is_empty():
		_steps_list.add_child(Kit.hint_label("（空演出：添加步骤开始排）", 320))
	var pool := StepDecls.steps(manifest)
	for si in arr.size():
		var st = arr[si]
		if not (st is Dictionary):
			continue
		_steps_list.add_child(_steps_row(si, st, pool))

## 时间轴视图：换数据源 + 选中态 + 滚动容器高度。
func _rebuild_steps_tl(arr: Array) -> void:
	if _steps_tl == null or not is_instance_valid(_steps_tl):
		return
	_steps_tl.set_steps(arr, _step_name_of)
	_steps_tl.sel = _steps_sel
	_steps_tl.sync_min_size()
	if _steps_scroll != null:
		_steps_scroll.custom_minimum_size = Vector2(0, minf(_steps_tl.fit_height() + 8.0, 220.0))

## 时间轴拖拽落定：净化回写（剥缺省键），整体重建（视图重新指向净化后的数组）。
func _on_steps_tl_changed() -> void:
	var data := _steps_data()
	var arr: Array = data.get("steps", [])
	if not (arr is Array):
		arr = []
	data["steps"] = StepTimeline.from_timeline(arr)
	_steps_write(data)
	if _steps_sel >= (data["steps"] as Array).size():
		_steps_sel = (data["steps"] as Array).size() - 1
	_rebuild_steps_all()

## 表单重建（数据自取）：时间轴点选后只换表单、不动视图。
func _rebuild_steps_form_from_data() -> void:
	if _steps_form == null:
		return
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	_rebuild_steps_form(arr)

## 子面板里的一个步骤行：序号+名称（选中高亮）+ 上移/下移/复制/删除。
func _steps_row(si: int, st: Dictionary, pool: Dictionary) -> Control:
	var sc := str(st.get("step", ""))
	var decl: Dictionary = StepDecls.step_by_code(manifest, sc)
	var known := not decl.is_empty()
	var nm := str(decl.get("name", sc)) if known else "（未声明的步骤 %s）" % sc
	var sel := _steps_sel == si
	var row := Kit.hbox(4)
	var mark := Kit.text_label("%d. %s" % [si + 1, nm],
		Th.TEXT if sel else Th.TEXT_DIM, Th.FS_SMALL)
	mark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
 # 行可点：点步骤名选中该步，右侧表单跟着换（不必先按 ↑↓ 才能选）
	mark.mouse_filter = Control.MOUSE_FILTER_STOP
	mark.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_steps_pick(si))
	row.add_child(mark)
	if not known:
		row.add_child(Kit.hint_label("⚠", 20))
	row.add_child(Kit.button("↑", func(): _steps_move(si, -1), "ghost"))
	row.add_child(Kit.button("↓", func(): _steps_move(si, 1), "ghost"))
	row.add_child(Kit.button("复制", func(): _steps_dup(si), "ghost"))
	row.add_child(Kit.del_button(func(): _steps_del(si)))
	return row

## 点步骤名选中该步：右侧表单换到这一步（重建保持 _steps_sel 选中态）。
func _steps_pick(si: int) -> void:
	_steps_sel = si
	_rebuild_steps_all()

## 当前步骤表单：步骤类型选择 + 该步骤声明的字段 + 未声明键只读保留。
## 字段改动即时写盘，不重建表单（保持输入焦点，与主表单同一纪律）。
func _rebuild_steps_form(arr: Array) -> void:
	var box := _steps_form
	if box == null:
		return
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	# 添加步骤：下拉选步骤池条目 → 追加到末尾
	var add_row := Kit.hbox(6)
	var pick := OptionButton.new()
	for sid in StepDecls.steps(manifest):
		var d: Dictionary = StepDecls.steps(manifest)[sid]
		pick.add_item(str(d.get("name", sid)))
		pick.set_item_metadata(pick.item_count - 1, str(d.get("code", "")))
	add_row.add_child(pick)
	var add_btn := Kit.button("添加步骤", func():
		if pick.selected < 0:
			return
		_steps_add(str(pick.get_item_metadata(pick.selected))))
	add_row.add_child(add_btn)
	box.add_child(add_row)
	# 时间轴警告（负 at/duration、同轨重叠）：只提示不阻断
	for wtext in StepTimeline.warnings(arr):
		box.add_child(Kit.hint_label("⚠ " + str(wtext), 320))
	if _steps_sel < 0 or _steps_sel >= arr.size() or not (arr[_steps_sel] is Dictionary):
		if not arr.is_empty():
			box.add_child(Kit.hint_label("点上方一个步骤进行编辑", 320))
		return
	var st: Dictionary = arr[_steps_sel]
	var sc := str(st.get("step", ""))
	var decl: Dictionary = StepDecls.step_by_code(manifest, sc)
	if decl.is_empty():
		box.add_child(Kit.hint_label(
			"⚠ 步骤码 %s 不在清单声明里（声明被删/换码）。只读保留。" % sc, 320))
		return
	box.add_child(Kit.divider())
	box.add_child(Kit.section_header("第 %d 步：%s" % [_steps_sel + 1, str(decl.get("name", sc))]))
	var sfields: Array = decl.get("fields", [])
	var sfd: Dictionary = st.get("fields", {}) if st.get("fields", {}) is Dictionary else {}
	for fd in sfields:
		if not (fd is Dictionary):
			continue
		box.add_child(_step_field_row(fd, sfd))
	# 该步骤里有声明已删的键：只读保留
	var known := {}
	for fd2 in sfields:
		if fd2 is Dictionary:
			known[str((fd2 as Dictionary).get("code", ""))] = true
	var extra := []
	for k in sfd:
		if str(k) == "" or known.has(str(k)):
			continue
		extra.append(k)
	if not extra.is_empty():
		extra.sort()
		box.add_child(Kit.hint_label("⚠ %d 个参数未在声明里（只读保留）" % extra.size(), 320))
		for k2 in extra:
			var v = sfd[k2]
			var row := LineEdit.new()
			row.text = "%s = %s" % [str(k2), str(v) if (v is String or v is StringName) else JSON.stringify(v)]
			row.editable = false
			box.add_child(row)

## 步骤字段行：复用 field_widgets，值取自步骤自己的 fields（键=字段码）。
func _step_field_row(fd: Dictionary, sfd: Dictionary) -> Control:
	var key := str(fd.get("code", ""))
	var val = sfd.get(key, fd.get("default", FieldWidgets.default_for(fd)))
	var label := str(fd.get("name", str(fd.get("id", ""))))
	var built := FieldWidgets.build(fd, val, func(v):
		_set_step_field(_steps_sel, key, v), _resolve_options)
	if built.get("commit") is Callable and (built.commit as Callable).is_valid():
		_pending_commits.append(built.commit)
	return Kit.field_row(label, built.ctl, 96)

## 写步骤字段：即时写盘，不重建表单（保焦点）。
func _set_step_field(si: int, key: String, value) -> void:
	if si < 0 or key == "":
		return
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si >= arr.size() or not (arr[si] is Dictionary):
		return
	var st: Dictionary = arr[si]
	var sfd: Dictionary = st.get("fields", {}) if st.get("fields", {}) is Dictionary else {}
	if sfd.get(key, null) == value:
		return   # 值没变不写盘（重建触发的同值回调幂等跳过）
	sfd[key] = value
	st["fields"] = sfd
	data["steps"] = arr
	_steps_write(data)

## 添加步骤：追加到末尾并选中。
func _steps_add(code: String) -> void:
	if code == "":
		return
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	arr.append({"step": code, "fields": {}})
	data["steps"] = arr
	_steps_sel = arr.size() - 1
	_steps_write(data)
	_rebuild_steps_all()

## 删除步骤；删的是选中的步骤时清除选中。
func _steps_del(si: int) -> void:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size():
		return
	arr.remove_at(si)
	data["steps"] = arr
	if _steps_sel >= arr.size():
		_steps_sel = arr.size() - 1
	_steps_write(data)
	_rebuild_steps_all()

## 上移/下移一格。
func _steps_move(si: int, dir: int) -> void:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var nj := si + dir
	if si < 0 or si >= arr.size() or nj < 0 or nj >= arr.size():
		return
	var tmp = arr[si]
	arr[si] = arr[nj]
	arr[nj] = tmp
	data["steps"] = arr
	_steps_sel = nj
	_steps_write(data)
	_rebuild_steps_all()

## 复制步骤：浅拷贝 fields 并插到下一步；步骤码引用清单声明、跨内容共享，无需重映射。
func _steps_dup(si: int) -> void:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size() or not (arr[si] is Dictionary):
		return
	var cp: Dictionary = (arr[si] as Dictionary).duplicate(true)
	cp["fields"] = (cp.get("fields", {}) as Dictionary).duplicate(true) if cp.get("fields", {}) is Dictionary else {}
	arr.insert(si + 1, cp)
	data["steps"] = arr
	_steps_sel = si + 1
	_steps_write(data)
	_rebuild_steps_all()
