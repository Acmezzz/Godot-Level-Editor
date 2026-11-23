extends RefCounted
## 功能绑定块（附加功能行 + 添加菜单 + 行操作）：从 content_editor.gd 拆出的控制器。宿主 = content_editor 实例（host 引用）。
## 「添加」菜单只滤掉已绑定的功能（方便选择），数据层不强制唯一——手改 JSON 仍可造成重复绑定。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
const ORD := ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]
const RIGHT_W := 360

var host   # content_editor 宿主
var app    # 根应用（= host.app）

func _init(h) -> void:
	host = h
	app = h.app

## 同名转发属性（读写穿透到宿主，保住搬动文本零改动）
var manifest: Dictionary:
	get: return host.manifest
var _selected_fn: int:
	get: return host._selected_fn
	set(v): host._selected_fn = v
var _add_menu: PopupMenu:
	get: return host._add_menu
	set(v): host._add_menu = v

## 同名包装方法（真实实现经 host 转发）
## 这里所有调用点都是「改绑定前先冲刷控件值」，不能走完整 commit——
## 那会把 staged 新内容提前写盘（只有正式保存/试玩才该落盘，A2）。
func commit() -> bool:
	return host.commit_fields()
func _current_fns() -> Array:
	return host._current_fns()
func _current_spr() -> EntityNode:
	return host._current_spr()
func _write_fns(n: EntityNode, fns: Array) -> void:
	host._write_fns(n, fns)
func _refresh_all() -> void:
	host._refresh_all()
func _rebuild_rows() -> void:
	host._rebuild_rows()
func _rebuild_right() -> void:
	host._rebuild_right()
func _mount_codes() -> Dictionary:
	return host._mount_codes()
func _open_lib(i: int) -> void:
	host._open_lib(i)

## 附加功能列表：每行 ① 名称 [内容名] ⟳并行 [库] ✕；点行展开内容表单。
## 挂载功能与附加功能同一列表同一模型；挂载行只锁「删除」，其余（并行/库/表单）照常。
func _build_fn_block() -> Control:
	var box := Kit.vbox(6)
	box.add_child(Kit.section_header("功能", null))
	var fns := _current_fns()
	if fns.is_empty():
		box.add_child(Kit.hint_label("这个实例还没有功能。", RIGHT_W - 40))
	for i in fns.size():
		box.add_child(_build_fn_row(i, fns[i], fns.size(), _fn_token(fns, i)))
	box.add_child(_build_add_row())
	return box

func _build_fn_row(i: int, item, total: int, tok: Dictionary = {}) -> Control:
	var f: Dictionary = item if item is Dictionary else {}
	var ref := _resolve_fn(f)
	var fn_id := str(ref.get("id", ""))
	var fname := str(f.get("name", ""))
	var content_id := str(f.get("content", ""))
	var on := i == _selected_fn
	# 令牌由调用方按「功能码 + 同码序号」算好传入（§4.1：迟到回调按令牌定位）

	var line := Kit.hbox(6)
	line.add_theme_constant_override("separation", 6)

	var ord_lbl := Kit.text_label(ORD[i] if i < ORD.size() else str(i + 1), Th.TEXT_MUTE, Th.FS_SMALL)
	line.add_child(ord_lbl)

	# 「库」按钮与「并行」勾选都要吞掉点击，否则会连带展开/收起表单
	# 未知码：清单里查不到 → 红字显形，数据原样保留（不删、不改写）
	var known := bool(ref.get("known", false))
	var name_lbl := Kit.text_label(
		FunctionDecls.function_name(manifest, fn_id) if known else ("(未声明的功能) " + str(f.get("fn", ""))),
		(Th.TEXT if on else Th.TEXT_SOFT) if known else Th.WARN, Th.FS_SMALL)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(name_lbl)

	var cname := Kit.text_label(fname if fname != "" else "未填",
		Th.TEXT_DIM if fname != "" else Th.TEXT_MUTE, Th.FS_META)
	cname.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cname.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	cname.tooltip_text = content_id if content_id != "" else "尚未创建内容"
	cname.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(cname)

	var par := CheckBox.new()
	par.text = "并行"
	par.button_pressed = bool(f.get("parallel", false))
	par.add_theme_font_size_override("font_size", Th.FS_META)
	par.tooltip_text = "与前一项同时触发"
	par.toggled.connect(func(v: bool): _set_parallel(tok, v))
	line.add_child(par)

	# 时机：声明 triggers 是白名单，这里只能挑（空 = 用声明默认）；磁盘写时机码。
	var trg := OptionButton.new()
	trg.custom_minimum_size = Vector2(72, 0)
	trg.add_theme_font_size_override("font_size", Th.FS_META)
	trg.tooltip_text = "本条绑定的时机；空 = 使用功能声明的默认时机"
	trg.add_item("默认时机")
	trg.set_item_metadata(0, "")
	var cur_trigger := str(f.get("trigger", ""))
	var tidx := 0
	for to in _trigger_options(fn_id):
		trg.add_item(str((to as Dictionary).get("t", "")))
		var at := trg.get_item_count() - 1
		var tv := str((to as Dictionary).get("v", ""))
		trg.set_item_metadata(at, tv)
		if tv != "" and tv == cur_trigger:
			tidx = at
	if cur_trigger != "" and tidx == 0:
		trg.add_item("(当前值) " + cur_trigger)
		trg.set_item_metadata(trg.get_item_count() - 1, cur_trigger)
		tidx = trg.get_item_count() - 1
	trg.select(tidx)
	trg.item_selected.connect(func(k: int): _set_trigger(tok, str(trg.get_item_metadata(k))))
	line.add_child(trg)

	var en := CheckBox.new()
	en.text = "启用"
	en.button_pressed = bool(f.get("enabled", true))
	en.add_theme_font_size_override("font_size", Th.FS_META)
	en.tooltip_text = "缺省为启用；关掉时写 enabled: false"
	en.toggled.connect(func(v: bool): _set_enabled(tok, v))
	line.add_child(en)

	# 执行顺序 = 数组序：↑↓ 交换相邻绑定，order 随交换统一重排
	if i > 0:
		line.add_child(Kit.button("↑", func(): _move_fn(i, -1), "ghost"))
	if total > 1 and i < total - 1:
		line.add_child(Kit.button("↓", func(): _move_fn(i, 1), "ghost"))
	# 「库」始终在行内：复用是追加一条新绑定，与原行是否已填无关
	var lib := Kit.button("库", func(): _open_lib(i), "ghost")
	lib.tooltip_text = "从已有内容复制一条进来（生成新 ID，追加到列表末尾）"
	line.add_child(lib)
	# 挂载功能不可删（类型自带，锁只锁删除）；附加功能照常给删除钮
	if _mount_codes().has(str(ref.get("code", ""))):
		var lock := Kit.text_label("🔒", Th.TEXT_MUTE, Th.FS_META)
		lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lock.tooltip_text = "类型自带功能：不可删除。改挂载清单去资产目录。"
		line.add_child(lock)
	else:
		line.add_child(Kit.del_button(func(): _delete_fn(i), "移除这一项（内容条目留在库里）"))


	# 行本身是按钮：用一层覆盖按钮承载点击，内部控件仍可单独响应。
	# 不能用 flat=true——flat 会禁用全部背景绘制，选中态就看不出来了，
	# 所以改成 flat=false + 三态自定义样式盒（未选中 = 全透明）。
	var row := Button.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.custom_minimum_size = Vector2(0, 28)
	row.tooltip_text = "点击展开这一项的内容表单"
	row.pressed.connect(func(): _pick_fn(i))
	var clear := Th.flat(Color(0, 0, 0, 0), Th.R_INNER)
	row.add_theme_stylebox_override("normal",
		Th.box(Th.ACCENT_BG, Th.ACCENT, Th.R_INNER, 4, 3) if on else clear)
	row.add_theme_stylebox_override("hover",
		Th.box(Th.BG_HOVER, Color(0, 0, 0, 0), Th.R_INNER, 4, 3))
	row.add_theme_stylebox_override("pressed",
		Th.box(Th.BG_ACTIVE, Color(0, 0, 0, 0), Th.R_INNER, 4, 3))
	row.add_theme_stylebox_override("focus",
		Th.box(Color(0, 0, 0, 0), Th.ACCENT, Th.R_INNER, 0, 0))
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.mouse_filter = Control.MOUSE_FILTER_PASS
	line.offset_left = 4
	line.offset_right = -4
	row.add_child(line)
	return row

## 底部「+ 添加功能 …」：列出清单 functions 声明的全部功能（声明 = 开发契约，编辑器只读）。
## 弹层实例只建一次（Rebuild 时只重建按钮）：每次刷新都 new 一个 PopupMenu 会留下孤儿节点。
func _build_add_row() -> Control:
	var btn := Kit.button("+ 添加功能 …", Callable(), "ghost")
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _function_index().is_empty():
		btn.disabled = true
		btn.tooltip_text = "清单里还没有 functions 声明（功能声明属开发标准）"
		return btn
	if _add_menu == null:
		_add_menu = PopupMenu.new()
		_add_menu.id_pressed.connect(_on_add_menu_id)
		# PopupMenu 必须进树才能弹出：本控制器是 RefCounted，挂到应用根上
		app.add_child(_add_menu)
	btn.pressed.connect(func():
		_populate_add_menu()
		var at := Vector2i(btn.get_screen_position()) + Vector2i(0, int(btn.size.y))
		_add_menu.popup(Rect2i(at, Vector2i.ZERO)))
	return btn

## 添加功能弹层的内容每次弹出前重建：清单可能在会话中被编辑（清单视图）。
## 已绑定（含挂载自动生成的）的功能不再出现在菜单里——界面层的便利过滤；
## 数据层不强制唯一（手改 JSON 仍可造出重复绑定，自检不报这条）。
func _populate_add_menu() -> void:
	_add_menu.clear()
	var all := _function_index()
	var bound := {}
	for f in _current_fns():
		if f is Dictionary:
			bound[str((f as Dictionary).get("fn", ""))] = true
	for k in all.keys():
		var d: Dictionary = all[k]
		var code := str(d.get("code", ""))
		if bound.has(code):
			continue
		_add_menu.add_item(str(d.get("name", k)))
		_add_menu.set_item_metadata(_add_menu.get_item_count() - 1, str(k))

func _on_add_menu_id(idx: int) -> void:
	var fn_id := str(_add_menu.get_item_metadata(idx))
	_add_fn(fn_id)

func _function_index() -> Dictionary:
	return FunctionDecls.functions(manifest)

## 解析一条绑定里的功能引用：磁盘上的 fn 一律是执行码，按码查 id；查不到 = 数据漂移。
## 返回 {id, code, known}——UI 全部按 id（人类名）组织，写盘只写 code。
func _resolve_fn(f: Dictionary) -> Dictionary:
	var code := str(f.get("fn", ""))
	var id := FunctionDecls.fn_id_of(manifest, code)
	return {"id": id, "code": code, "known": id != ""}

## §4.1：绑定行的稳定令牌 = 功能码 + 同码序号（同 steps_panel._step_token 口径）。
## 行内回调原先捕获裸下标：期间增删/上下移绑定后，迟到的 toggled/库/删除会落到另一条上。
func _fn_token(fns: Array, i: int) -> Dictionary:
	if i < 0 or i >= fns.size():
		return {"code": "", "nth": -1}
	var code := str((fns[i] if fns[i] is Dictionary else {}).get("fn", ""))
	var nth := 0
	for k in i:
		if str((fns[k] if fns[k] is Dictionary else {}).get("fn", "")) == code:
			nth += 1
	return {"code": code, "nth": nth}

## 令牌 → 当前下标；找不到（那条绑定已被删）返回 -1。调用方据此放弃写入。
func _fn_index_of(fns: Array, tok: Dictionary) -> int:
	var code := str(tok.get("code", ""))
	var want := int(tok.get("nth", -1))
	if code == "" or want < 0:
		return -1
	var nth := 0
	for i in fns.size():
		if str((fns[i] if fns[i] is Dictionary else {}).get("fn", "")) != code:
			continue
		if nth == want:
			return i
		nth += 1
	return -1

func _pick_fn(i: int) -> void:
	if not commit():
		return
	_selected_fn = -1 if _selected_fn == i else i
	_rebuild_right()

## 功能声明的 trigger id 白名单 → [{v: 时机码, t: 显示名}]。
## 声明按 id 引用时机池；绑定存码，UI 显示名。
func _trigger_options(fn_id: String) -> Array:
	var out: Array = []
	for tid in FunctionDecls.fn_triggers(manifest, fn_id):
		var tdef := TriggerDecls.trigger_decl(manifest, str(tid))
		var code := str(tdef.get("code", ""))
		if code == "":
			continue
		out.append({"v": code, "t": str(tdef.get("name", str(tid)))})
	return out

## 以下 setter 都收**稳定令牌**而不是下标（§4.1）：迟到回调按令牌重新定位，
## 那条绑定已被删（-1）就放弃写入，绝不落到同列表的别人身上。
func _set_parallel(tok: Dictionary, v: bool) -> void:
	var spr := _current_spr()
	var fns := _current_fns()
	var i := _fn_index_of(fns, tok)
	if spr == null or i < 0:
		return
	var f: Dictionary = (fns[i] if fns[i] is Dictionary else {}).duplicate(true)
	f["parallel"] = v
	fns = fns.duplicate(true)
	fns[i] = f
	_write_fns(spr, fns)

func _set_trigger(tok: Dictionary, code: String) -> void:
	var spr := _current_spr()
	var fns := _current_fns()
	var i := _fn_index_of(fns, tok)
	if spr == null or i < 0:
		return
	var f: Dictionary = (fns[i] if fns[i] is Dictionary else {}).duplicate(true)
	if code == "":
		f.erase("trigger")
	else:
		f["trigger"] = code
	fns = fns.duplicate(true)
	fns[i] = f
	_write_fns(spr, fns)

func _set_enabled(tok: Dictionary, v: bool) -> void:
	var spr := _current_spr()
	var fns := _current_fns()
	var i := _fn_index_of(fns, tok)
	if spr == null or i < 0:
		return
	var f: Dictionary = (fns[i] if fns[i] is Dictionary else {}).duplicate(true)
	# 缺省 true 省略，不写冗余键
	if v:
		f.erase("enabled")
	else:
		f["enabled"] = false
	fns = fns.duplicate(true)
	fns[i] = f
	_write_fns(spr, fns)

func _delete_fn(i: int) -> void:
	var spr := _current_spr()
	var fns := _current_fns()
	if spr == null or i < 0 or i >= fns.size():
		return
	if not commit():
		return
	fns = _current_fns().duplicate(true)
	fns.remove_at(i)
	# order 之后重排：序号是执行顺序的唯一真相，删除后不能留空洞
	for k in fns.size():
		if fns[k] is Dictionary:
			(fns[k] as Dictionary)["order"] = k + 1
	_selected_fn = -1
	_write_fns(spr, fns)
	_refresh_all()

## 绑定行 ↑/↓：交换相邻两条并重排 order（执行顺序 = 数组序）。
func _move_fn(i: int, dir: int) -> void:
	var spr := _current_spr()
	var fns := _current_fns()
	var j := i + dir
	if spr == null or j < 0 or j >= fns.size():
		return
	if not commit():
		return
	fns = _current_fns().duplicate(true)
	var t = fns[i]
	fns[i] = fns[j]
	fns[j] = t
	for k in fns.size():
		if fns[k] is Dictionary:
			(fns[k] as Dictionary)["order"] = k + 1
	if _selected_fn == i:
		_selected_fn = j
	elif _selected_fn == j:
		_selected_fn = i
	_write_fns(spr, fns)
	_refresh_all()

## 追加功能：内容留空，等用户在表单里第一次改动时再生成 ID。
## 绑定里写执行码；码由 ensure_codes 在加载清单时补发，这里不可能缺。
func _add_fn(fn_id: String) -> void:
	var spr := _current_spr()
	if spr == null or fn_id == "":
		return
	if not commit():
		return
	var fns := _current_fns().duplicate(true)
	fns.append({"fn": FunctionDecls.fn_code(manifest, fn_id), "content": "", "name": "",
		"order": fns.size() + 1, "parallel": false})
	_selected_fn = fns.size() - 1
	_write_fns(spr, fns)
	_refresh_all()
