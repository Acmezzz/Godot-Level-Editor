extends RefCounted
## 内容编辑器：左列本图实例列表 / 中列只读画布预览 / 右列实例引用 + 功能绑定与内容表单。
##
## 与其它控制器同形：RefCounted + _init(host)，样式统一走 Kit/Th。
## 数据真相：实例绑定在画布 Sprite2D 的 meta（functions），功能内容在
## content/<功能id>/<内容id>.json。离散控件改动即时写盘；SpinBox/多行等
## 连续控件在失焦或 commit() 时统一落盘（见 _pending_commits）。
## 中列是重绘式预览——同一节点不能两处上屏，不挂 app.canvas，按坐标重画。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentId := preload("res://src/content/content_id.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const MapStore := preload("res://src/map_store.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const Preview := preload("res://src/ui/content_preview.gd")
const K := preload("res://src/core/constants.gd")

## 序号圈字符；超出后回落到数字
const ORD := ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]
const LEFT_W := 220
const RIGHT_W := 360

var app
var manifest := {}
## 本控制器是 RefCounted：由 project_shell 把这个根 Control 挂进 _holder
var root: Control = null

var _selected_ent := ""
var _selected_fn := -1

# 左列
var _left_title: Label = null
var _rows_box: VBoxContainer = null
# 中列（只读预览控件，实现见 content_preview.gd）
var _preview: Control = null
var _preview_map := ""   # 预览缩放所属地图：切图时 reset_view
# 右列
var _r_name: Label = null
var _r_id: Label = null
var _r_badge: PanelContainer = null
var _r_body: VBoxContainer = null
# 表单里需要就地更新的那处：首次改动创建内容后只改 ID 文本，不重建表单（重建会丢焦点）
var _form_id_edit: LineEdit = null
## 「+ 添加功能」弹层：控制器级单例，跨 _rebuild_right 复用
var _add_menu: PopupMenu = null

func _init(host) -> void:
	app = host
	manifest = host.manifest

## 由 project_shell 调用：构建三区骨架并返回可挂进 _holder 的根节点。
func build() -> Control:
	root = Control.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", Th.flat(Th.BG_BASE, 0))
	root.add_child(bg)

	var cols := Kit.hbox(0)
	cols.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(cols)
	cols.add_child(_build_left())
	cols.add_child(_build_middle())
	cols.add_child(_build_right())
	return root

# ──────────── 左列：本图实例列表 ────────────

func _build_left() -> Control:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = Vector2(LEFT_W, 0)
	var sb := Th.box(Th.BG_PANEL, Th.BORDER, 0, 10, 10)
	sb.set_border_width_all(0)
	sb.border_width_right = 1
	wrap.add_theme_stylebox_override("panel", sb)
	var col := Kit.vbox(8)
	wrap.add_child(col)

	var head := Kit.hbox(6)
	_left_title = Kit.section_label("实例")
	_left_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_left_title)
	col.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows_box = Kit.vbox(2)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)
	col.add_child(scroll)

	col.add_child(Kit.hint_label("点画布上的实体选中同一行。", LEFT_W - 24))
	return wrap

# ──────────── 中列：只读画布预览（实现在 src/ui/content_preview.gd） ────────────

func _build_middle() -> Control:
	var wrap := Control.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.custom_minimum_size = Vector2(240, 0)

	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", Th.flat(Th.BG_VOID, 0))
	wrap.add_child(bg)

	_preview = Preview.new(self)
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.add_child(_preview)

	var hint := Kit.text_label("只读预览 · 滚轮缩放 · 中键拖动 · 点击实例选中", Th.TEXT_MUTE, Th.FS_META)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.position = Vector2(12, 10)
	wrap.add_child(hint)
	return wrap

# ──────────── 右列：实例与功能 ────────────

func _build_right() -> Control:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = Vector2(RIGHT_W, 0)
	var sb := Th.box(Th.BG_PANEL, Th.BORDER, 0, 12, 10)
	sb.set_border_width_all(0)
	sb.border_width_left = 1
	wrap.add_theme_stylebox_override("panel", sb)
	var col := Kit.vbox(10)
	wrap.add_child(col)

	var head := Kit.hbox(8)
	_r_name = Kit.text_label("—", Th.TEXT, Th.FS_MD)
	_r_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_r_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(_r_name)
	_r_id = Kit.text_label("", Th.TEXT_MUTE, Th.FS_META)
	head.add_child(_r_id)
	col.add_child(head)
	_r_badge = Kit.badge("", Th.OK)
	_r_badge.visible = false
	col.add_child(_r_badge)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_r_body = Kit.vbox(10)
	_r_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_r_body)
	col.add_child(scroll)
	return wrap

# ──────────── 刷新入口（project_shell 调用） ────────────

## 进入内容视图时调用。focus 是实例 id（右键/定位直达），空则保留上次选中。
func refresh_list(focus := "") -> void:
	if root == null:
		return
	manifest = app.manifest
	if not _map_ready():
		_clear_all_for_empty()
		return
	# 切图后上一张图的缩放/平移对这张图没有意义：zoom 归 1（整图塞进控件）
	if _preview_map != str(app.cur_map_name):
		_preview_map = str(app.cur_map_name)
		_preview.reset_view()
	var ents := _entities()
	# 悬停 id 随切图/删实体失效：留着会指向不存在的实例，清干净
	if _preview.hover_ent != "" and _find_ent(_preview.hover_ent) == null:
		_preview.clear_hover()
	# 选中项失效（切图/删实体）时回到第一行：右栏不该对着已不存在的实例
	if focus != "" and _find_ent(focus) != null:
		_selected_ent = focus
	elif _find_ent(_selected_ent) == null:
 # 没有显式 focus 时落在画布当前选中实体上——关卡编辑器「在工作台编辑 →」
 # 不带参数过来，用户期望看到的就是刚才选中的那个实例。
		var sel = app.canvas.selected_entity if app.canvas != null else null
		if sel != null and is_instance_valid(sel) and sel.has_meta("scene"):
			_selected_ent = str(sel.get_meta("code", ""))
		if _find_ent(_selected_ent) == null:
			_selected_ent = str((ents[0] as Dictionary).get("id", "")) if not ents.is_empty() else ""
	_selected_fn = -1
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.refresh()

## Ctrl+S / 切视图：把还没失焦提交的连续控件改动统一写盘，避免 Esc 或直接切走时丢改动。
func commit() -> bool:
	var pend := _pending_commits.duplicate()
	_pending_commits.clear()
	for cb in pend:
		if cb is Callable and (cb as Callable).is_valid():
			(cb as Callable).call()
	return true

## 待提交的连续控件提交器（SpinBox / 多行文本）：拖值/输入期间只记内存，
## 失焦或 commit() 才写内容文件。由 field_widgets.build() 产出，值未变时下游会幂等跳过。
var _pending_commits: Array = []

# ──────────── 数据读取：只从画布实体读，不另存一份 ────────────

func _map_ready() -> bool:
	return app.map_loaded and app.canvas != null and is_instance_valid(app.canvas)

## 本图实例快照（保持画布放置顺序）：[{spr, code, scene, name, fns}]
## 按 canvas.ents_rev 缓存——预览每次鼠标移动都调 _hit_at，原实现每个事件
## 都重扫子树 + 重新排序（95×56 满图时每秒上万次临时数组分配）。绑定变更走 _mark() 抬 rev。
var _ents_cache: Array = []
var _ents_rev := -1
var _ents_map := ""

func _entities() -> Array:
	if not _map_ready():
		_ents_cache = []
		_ents_rev = -1
		return _ents_cache
	var rev: int = int(app.canvas.ents_rev)
	var map_name := str(app.cur_map_name)
	if _ents_rev == rev and _ents_map == map_name:
		return _ents_cache
	var out: Array = []
	for e in app.canvas.ents_all():
		var spr := e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		var sid := str(spr.get_meta("scene", ""))
		var fns = spr.get_meta("functions", [])
		var list: Array = fns if fns is Array else []
		out.append({
			"spr": spr,
			"code": str(spr.get_meta("code", "")),
			"scene": sid,
			"name": str(app._scene_name(sid)),
			"fns": list,
		})
	# 保持画布放置顺序（撤销恢复也稳定），不做字符串排序
	_ents_cache = out
	_ents_rev = rev
	_ents_map = map_name
	return out

func _find_ent(code: String) -> Sprite2D:
	if code == "" or not _map_ready():
		return null
	for e in app.canvas.ents_all():
		var spr := e as Sprite2D
		if spr != null and str(spr.get_meta("code", "")) == code:
			return spr
	return null

func _current_spr() -> Sprite2D:
	return _find_ent(_selected_ent)

func _current_fns() -> Array:
	var spr := _current_spr()
	if spr == null:
		return []
	var fns = spr.get_meta("functions", [])
	return fns if fns is Array else []

## 分层内容 ID 的候选：地图码-实体码-实例码-功能id-内容码。
## 三段身份码来自各层载体（地图 meta / 清单 entities / 实体 meta），缺段返回空串。
func _content_id_for(spr: Sprite2D, fn_id: String) -> String:
	var map_code := str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", ""))
	var ent_code := ""
	for e in manifest.get("entities", []):
		if e is Dictionary and str((e as Dictionary).get("id", "")) == str(spr.get_meta("scene", "")):
			ent_code = str((e as Dictionary).get("code", ""))
			break
	var inst_code := str(spr.get_meta("code", ""))
	return ContentId.content_id(map_code, ent_code, inst_code, fn_id)

## 写回附加功能：先撤销快照（改动前），再改 meta 并标脏。
## 内容条目留在库里，删绑定不等于删内容。
func _write_fns(spr: Sprite2D, fns: Array) -> void:
	if spr == null:
		return
	app.canvas._push_undo()
	spr.set_meta("functions", fns.duplicate(true))
	app.canvas._mark()

# ──────────── 左列渲染 ────────────

func _rebuild_rows() -> void:
	if _rows_box == null:
		return
	for c in _rows_box.get_children():
		_rows_box.remove_child(c)
		c.queue_free()
	var ents := _entities()
	# 标题以画布实际加载的地图为准（app.cur_map_name 在切图协程里可能短暂超前/滞后）
	var map_name := str(app.canvas.cur_map_name) if str(app.canvas.cur_map_name) != "" else "未命名"
	_left_title.text = "%s 实例" % map_name

	if ents.is_empty():
		_rows_box.add_child(Kit.empty_state("▦", "这张图没有实例",
			"去关卡编辑器放几个实体再回来挂功能"))
		return
	for row in ents:
		_rows_box.add_child(_build_row(row))

## 实例行：类型名 + 实例码。整行是按钮，点击走 select_inst（与画布双向同步）。
func _build_row(row: Dictionary) -> Control:
	var code := str(row.code)
	var on := code == _selected_ent
	var b := Kit.button("", func(): select_inst(code), "ghost")
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = "%s %s" % [str(row.name), code]
	if on:
		b.add_theme_stylebox_override("normal",
			Th.box(Th.ACCENT_BG, Th.ACCENT, Th.R_INNER, 6, 4))
	b.add_theme_stylebox_override("hover",
		Th.box(Th.BG_HOVER, Th.BORDER_HI, Th.R_INNER, 6, 4))

	var h := Kit.hbox(6)
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 6)
	h.offset_left = 6
	h.offset_right = -6
	b.add_child(h)

	var nm := Kit.text_label(str(row.name), Th.TEXT if on else Th.TEXT_SOFT, Th.FS_SMALL)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(nm)

	var iid := Kit.text_label(code, Th.TEXT_MUTE, Th.FS_META)
	iid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(iid)

	# 按钮内容行撑满高度：ghost 按钮默认按文字定高，空文字会塌成 0
	b.custom_minimum_size = Vector2(0, 26)
	# 悬停行 → 预览里高亮对应实例（与预览内悬停同一状态，青框）
	b.mouse_entered.connect(func():
		_preview.set_hover(code))
	b.mouse_exited.connect(func():
		if _preview.hover_ent == code:
			_preview.set_hover(""))
	return b

## 内容页是否在屏上（root 由 project_shell 切 visible）。隐藏时的选中只记状态不重建 UI。
func _is_view_visible() -> bool:
	return root != null and is_instance_valid(root) and root.visible

## 单一选中入口：左列行、中列画布预览、外部定位都走这里，避免两处状态不同步。
func select_inst(code: String) -> void:
	if code == "" or _find_ent(code) == null:
		return
	# 切实例前先落盘当前 SpinBox 的待提交值（旧下标只对旧实例有效）
	commit()
	_selected_ent = code
	_selected_fn = -1
	# 切实例清指向预览：高亮属于上一个实例的引用编辑，不带走
	app.canvas.ref_highlight = ""
	app.canvas.queue_redraw()
	if _preview != null:
		_preview.set_highlight("")
	# 自带功能（类型挂载）补齐绑定：缺就按声明顺序追加到列表末尾（见 _sync_mounted）。
	var spr0 := _find_ent(code)
	if spr0 != null:
		_sync_mounted(spr0)
	# 内容页隐藏时（关卡编辑器里点实体）不做整套左列/右栏重建，只记住选中，
	# 等切到内容视图时 refresh_list 再重建。
	if not _is_view_visible():
		return
	# 选中同步到关卡画布：切回关卡编辑器时选中框落在同一实例上。
	# 画布上已有框选组（>1）时不能把 selected_multi 覆写成 [spr]——
	# _box_select 会经 entity_selected 走到这里，覆写就等于「框选完立刻塌缩成单选」，
	# 整组拖动随即失效（用户报的「能框选但不能移动」）。只把单选指针挪过去即可。
	var spr := _find_ent(code)
	if spr != null and app.canvas != null:
		app.canvas.selected_entity = spr
 # 只有「本次选中就是这个多选集合的成员」才保留集合；其它入口（新放置实体等）
 # 仍按单选收拢，避免旧框选残留在 selected_multi 里。
		var keep_multi: bool = app.canvas.selected_multi.size() > 1 \
			and app.canvas.selected_multi.has(spr)
		if not keep_multi:
			app.canvas.selected_multi = [spr]
 # 选中状态改了必须让画布重绘，否则选择框要等下一次任意重绘才落位。
 # 不发 entity_selected——那会经 app 再转回本函数，形成回环。
		app.canvas.queue_redraw()
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.refresh()

# ──────────── 中列：重绘式预览（实现见 content_preview.gd） ────────────
## 没开地图：清空三列并给引导。不伪造空行，让「先去开图」是唯一明确动作。
func _clear_all_for_empty() -> void:
	_selected_ent = ""
	_selected_fn = -1
	_preview.clear_hover()
	_left_title.text = "实例"
	if _rows_box != null:
		for c in _rows_box.get_children():
			_rows_box.remove_child(c)
			c.queue_free()
		_rows_box.add_child(Kit.empty_state("▦", "没有正在编辑的地图",
			"先去关卡编辑器新建或打开一张地图"))
	_r_name.text = "—"
	_r_id.text = ""
	_r_badge.visible = false
	if _r_body != null:
		for c in _r_body.get_children():
			_r_body.remove_child(c)
			c.queue_free()
		_r_body.add_child(Kit.empty_state("◇", "先打开一张地图",
			"顶栏地图下拉可切换地图"))
	if _preview != null:
		_preview.refresh()

# ──────────── 右列：渲染 ────────────

func _rebuild_right() -> void:
	if _r_body == null:
		return
	# 右栏控件整片重建：待提交项绑定的是旧控件，重建后失效，直接清（提交发生在选择变更前）。
	_pending_commits.clear()
	for c in _r_body.get_children():
		_r_body.remove_child(c)
		c.queue_free()
	_form_id_edit = null
	var spr := _current_spr()
	if spr == null:
		_r_name.text = ""
		_r_id.text = ""
		_r_badge.visible = false
		_r_body.add_child(Kit.empty_state("◇", "选一个实例", "左侧列表或中间预览点击实例"))
		return
	var sid := str(spr.get_meta("scene", ""))
	var code := str(spr.get_meta("code", ""))
	_r_name.text = str(app._scene_name(sid))
	_r_id.text = "%s.%s" % [str(app.cur_map_name), code]
	_r_badge.visible = false

	var refs := _build_refs_block()
	if refs != null:
		_r_body.add_child(refs)
		_r_body.add_child(Kit.divider())
	_r_body.add_child(_build_fn_block())
	if _selected_fn >= 0 and _selected_fn < _current_fns().size():
		_r_body.add_child(Kit.divider())
		_r_body.add_child(_build_form_block())

## 自带功能（挂载）——类型自带、实例不可删，与附加功能同一套绑定/内容模型：
## 值在 content/<功能id>/<内容ID>.json，未编辑过的实例 = 声明 default（游戏侧兜底）。
## 选中实例时补齐缺失的挂载绑定（见 _sync_mounted）；列表里的锁 = 挂载码集。

## 实体类型的挂载码集（{code: true}）；码由 ensure_codes 保证非空。
func _mount_codes() -> Dictionary:
	var sid := ""
	var spr := _current_spr()
	if spr != null and is_instance_valid(spr):
		sid = str(spr.get_meta("scene", ""))
	var out := {}
	for m in FunctionDecls.entity_mounts(manifest, sid):
		out[str((m as Dictionary).get("code", ""))] = true
	return out

## 给当前实例补齐缺失的挂载绑定：缺的按声明顺序追加到末尾并重排 order。
## 只在真的补了东西时写盘/标脏——常规路径（绑定齐全）零副作用。
func _sync_mounted(spr: Sprite2D) -> void:
	var sid := str(spr.get_meta("scene", ""))
	var mounts: Array = FunctionDecls.entity_mounts(manifest, sid)
	if mounts.is_empty():
		return
	var fns: Array = spr.get_meta("functions", [])
	if not (fns is Array):
		fns = []
	var have := {}
	for f in fns:
		if f is Dictionary:
			have[str((f as Dictionary).get("fn", ""))] = true
	var missing: Array = []
	for m in mounts:
		var code := str((m as Dictionary).get("code", ""))
		if code != "" and not have.has(code):
			missing.append({"fn": code, "content": "", "name": "",
				"order": 0, "parallel": false})
	if missing.is_empty():
		return
	app.canvas._push_undo()   # 自动补绑定也是地图修改：进撤销栈，Ctrl+Z 整步退回
	fns = fns.duplicate(true)
	fns.append_array(missing)
	for k in fns.size():
		if fns[k] is Dictionary:
			(fns[k] as Dictionary)["order"] = k + 1
	spr.set_meta("functions", fns)
	app.canvas._mark()

# ──────────── 实例引用编辑（实体类型 fields 声明的 entity_ref/map_ref） ────────────

## 按实体类型的引用型字段声明渲染下拉；值存实例 props。编辑器只管存取与呈现，
## 语义归游戏侧。类型没有引用声明就不出这个区块。
func _build_refs_block() -> Control:
	var spr := _current_spr()
	if spr == null or not is_instance_valid(spr):
		return null
	var sid := str(spr.get_meta("scene", ""))
	var edef: Dictionary = {}
	for e0 in manifest.get("entities", []):
		if e0 is Dictionary and str(e0.get("id", "")) == sid:
			edef = e0
			break
	var fdecls: Array = edef.get("fields", []) if edef.get("fields", []) is Array else []
	var rows: Array = []
	for fd in fdecls:
		if fd is Dictionary:
			var t := str(fd.get("type", ""))
			if t == "entity_ref" or t == "map_ref":
				rows.append(fd)
	if rows.is_empty():
		return null
	var box := Kit.vbox(6)
	box.add_child(Kit.section_header("引用"))
	var props: Dictionary = spr.get_meta("props", {}) if spr.get_meta("props", {}) is Dictionary else {}
	for fd in rows:
		box.add_child(_build_ref_row(fd, props))
	return box

## 单个引用字段行：entity_ref → 实例下拉（of 限定类型，未声明 of 列全部）；
## map_ref → 地图下拉。值不在选项里时由 FieldWidgets 保留原值（绝不静默改写）。
func _build_ref_row(fd: Dictionary, props: Dictionary) -> Control:
	var fid := str(fd.get("id", ""))
	var typ := str(fd.get("type", ""))
	var cur := str(props.get(fid, ""))
	var built: Dictionary
	if typ == "map_ref":
		built = FieldWidgets.build({"kind": "choice", "source": "map"}, cur,
			func(v): _set_prop_ref(fd, v), _resolve_options)
	else:
		var of := str(fd.get("of", ""))
		var src := "entity_inst:" + of if of != "" else "entity_inst:"
		built = FieldWidgets.build({"kind": "choice", "source": src}, cur,
			func(v): _set_prop_ref(fd, v), _resolve_options)
	return Kit.field_row(str(fd.get("name", fid)), built.ctl, 96)

## 写实例 props 的引用字段：props 是地图数据，改动进撤销栈；并做指向预览高亮。
func _set_prop_ref(fd: Dictionary, value: String) -> void:
	var spr := _current_spr()
	if spr == null or not is_instance_valid(spr) or not app.map_loaded:
		return
	var props: Dictionary = (spr.get_meta("props", {}) as Dictionary).duplicate(true)
	if props.get(fd.id, null) == value:
		return
	app.canvas._push_undo()
	if value == "":
		props.erase(fd.id)
	else:
		props[fd.id] = value
	spr.set_meta("props", props)
	app.canvas._mark()
	# 指向预览：高亮被指实例（仅 entity_ref；map_ref 指向别的图，不高亮）
	var target := value if str(fd.type) == "entity_ref" else ""
	app.canvas.ref_highlight = target
	app.canvas.queue_redraw()
	if _preview != null:
		_preview.set_highlight(target)

## 附加功能列表：每行 ① 名称 [内容名] ⟳并行 [库] ✕；点行展开内容表单。
## 挂载功能与附加功能同一列表同一模型；挂载行只锁「删除」，其余（并行/库/表单）照常。
func _build_fn_block() -> Control:
	var box := Kit.vbox(6)
	box.add_child(Kit.section_header("功能", null))
	var fns := _current_fns()
	if fns.is_empty():
		box.add_child(Kit.hint_label("这个实例还没有功能。", RIGHT_W - 40))
	for i in fns.size():
		box.add_child(_build_fn_row(i, fns[i]))
	box.add_child(_build_add_row())
	return box

func _build_fn_row(i: int, item) -> Control:
	var f: Dictionary = item if item is Dictionary else {}
	var ref := _resolve_fn(f)
	var fn_id := str(ref.get("id", ""))
	var fname := str(f.get("name", ""))
	var content_id := str(f.get("content", ""))
	var on := i == _selected_fn

	var line := Kit.hbox(6)
	line.add_theme_constant_override("separation", 6)

	var ord := Kit.text_label(ORD[i] if i < ORD.size() else str(i + 1), Th.TEXT_MUTE, Th.FS_SMALL)
	line.add_child(ord)

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
	par.toggled.connect(func(v: bool): _set_parallel(i, v))
	line.add_child(par)

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
## 已绑定（含挂载自动生成的）与已挂载的功能不再出现在菜单里——同一个功能一个实例只挂一条。
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

func _pick_fn(i: int) -> void:
	commit()
	_selected_fn = -1 if _selected_fn == i else i
	_rebuild_right()

func _set_parallel(i: int, v: bool) -> void:
	var spr := _current_spr()
	var fns := _current_fns()
	if spr == null or i < 0 or i >= fns.size():
		return
	var f: Dictionary = (fns[i] if fns[i] is Dictionary else {}).duplicate(true)
	f["parallel"] = v
	fns = fns.duplicate(true)
	fns[i] = f
	_write_fns(spr, fns)

func _delete_fn(i: int) -> void:
	var spr := _current_spr()
	var fns := _current_fns()
	if spr == null or i < 0 or i >= fns.size():
		return
	commit()   # 待提交值先落到旧绑定上，随后才增删绑定
	fns = _current_fns().duplicate(true)
	fns.remove_at(i)
	# order 之后重排：序号是执行顺序的唯一真相，删除后不能留空洞
	for k in fns.size():
		if fns[k] is Dictionary:
			(fns[k] as Dictionary)["order"] = k + 1
	_selected_fn = -1
	_write_fns(spr, fns)
	_refresh_all()

## 追加功能：内容留空，等用户在表单里第一次改动时再生成 ID。
## 绑定里写执行码；码由 ensure_codes 在加载清单时补发，这里不可能缺。
func _add_fn(fn_id: String) -> void:
	var spr := _current_spr()
	if spr == null or fn_id == "":
		return
	commit()   # 追加前先落盘当前表单待提交值（下标保持有效）
	var fns := _current_fns().duplicate(true)
	fns.append({"fn": FunctionDecls.fn_code(manifest, fn_id), "content": "", "name": "",
		"order": fns.size() + 1, "parallel": false})
	_selected_fn = fns.size() - 1
	_write_fns(spr, fns)
	_refresh_all()

## 左右列一起刷新（列表高亮、徽章、右栏表单都随绑定变化）
func _refresh_all() -> void:
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.refresh()

# ──────────── 右列：内容表单 ────────────

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
## entity_inst:<id,id>（当前图实例，值=实例码）、map（地图文件）、audio:（音频池）、
## layer:（当前图用户层栈，值=层码，显示「序号.层名」）。
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
		for e in manifest.get("entities", []):
			if not (e is Dictionary):
				continue
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
				var spr := e0 as Sprite2D
				if spr == null or not spr.has_meta("scene"):
					continue
				var sid0 := str(spr.get_meta("scene", ""))
				if not want.is_empty() and not want.has(sid0):
					continue
				var c0 := str(spr.get_meta("code", ""))
				if c0 == "":
					continue
				var cell: Vector2i = app.canvas._cell_of(spr.position)
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
	if src == "map":
		var out3: Array = []
		for mn in MapStore.list_maps(manifest):
			out3.append({"v": str(mn), "t": str(mn)})
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
	elif str(cur.get_meta("code", "")) == "":
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
	var src_fields = src.get("fields", {})
	var src_steps = src.get("steps", [])
	var data := {
		"id": new_id,
		"function": FunctionDecls.fn_code(manifest, fn_id),
		"name": nm,
		"fields": (src_fields as Dictionary).duplicate(true) if src_fields is Dictionary else {},
		"steps": (src_steps as Array).duplicate(true) if src_steps is Array else [],
	}
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

# ──────────── 演出子面板（steps:true 的功能绑定） ────────────

var _steps_pop: PopupPanel = null
var _steps_i := -1            # 正在编辑的绑定行下标
var _steps_fn_id := ""        # 该绑定的功能 id
var _steps_sel := -1          # 当前选中步骤下标；-1 = 无
var _steps_list: VBoxContainer = null
var _steps_form: VBoxContainer = null

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
	var shell: Dictionary = app._popup_body("演出编辑：%s" % FunctionDecls.function_name(manifest, fn_id),
		"步骤自上而下依次执行；每步引用步骤池声明并填参")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	_steps_pop = pop
	_steps_list = Kit.vbox(4)
	_steps_form = Kit.vbox(6)
	body.add_child(_steps_list)
	body.add_child(Kit.divider())
	body.add_child(_steps_form)
	pop.popup_hide.connect(func(): _rebuild_right())
	_rebuild_steps_all()
	app._open_popup(pop)

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

## 重建子面板全部内容：步骤列表 + 当前步骤表单。
func _rebuild_steps_all() -> void:
	if _steps_list == null or _steps_form == null:
		return
	for c in _steps_list.get_children():
		_steps_list.remove_child(c)
		c.queue_free()
	for c in _steps_form.get_children():
		_steps_form.remove_child(c)
		c.queue_free()
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if arr.is_empty():
		_steps_list.add_child(Kit.hint_label("（空演出：添加步骤开始排）", 320))
	var pool := StepDecls.steps(manifest)
	for si in arr.size():
		var st = arr[si]
		if not (st is Dictionary):
			continue
		_steps_list.add_child(_steps_row(si, st, pool))
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
