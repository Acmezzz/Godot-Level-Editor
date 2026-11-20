extends RefCounted
## 内容编辑器：左列本图实例列表 / 中列只读画布预览 / 右列实例引用 + 功能绑定与内容表单。
##
## 与其它控制器同形：RefCounted + _init(host)，样式统一走 Kit/Th。
## 数据真相：实例绑定在画布 EntityNode 上（functions），功能内容在
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
const StepTimeline := preload("res://src/content/step_timeline.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const Preview := preload("res://src/ui/content_preview.gd")
const ContentForm := preload("res://src/ui/content_form.gd")
const FnBind := preload("res://src/ui/fn_bind.gd")
const StepsPanel := preload("res://src/ui/steps_panel.gd")
const K := preload("res://src/core/constants.gd")

## 序号圈字符；超出后回落到数字
const ORD := ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]
const LEFT_W := 220
const RIGHT_W := 360

var app
## 拆分出的子控制器
var _form   # content_form.gd：内容表单/库/写盘
var _fnbind   # fn_bind.gd：功能绑定行
var _steps   # steps_panel.gd：演出子面板
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
	_form = ContentForm.new(self)
	_fnbind = FnBind.new(self)
	_steps = StepsPanel.new(self)
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
		if sel is EntityNode and is_instance_valid(sel) and (sel as EntityNode).code != "":
			_selected_ent = (sel as EntityNode).code
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

## 本图实例快照（保持画布放置顺序）：[{node, code, asset, name, fns}]
## 只收实体（kind=entity）——场景实例不参与内容绑定，也不该出现在实例列表里。
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
		var n := e as EntityNode
		if n == null or not n.is_entity():
			continue
		out.append({
			"node": n,
			"code": n.code,
			"asset": n.asset,
			"name": str(app._scene_name(n.asset)),
			"fns": n.functions,
		})
	# 保持画布放置顺序（撤销恢复也稳定），不做字符串排序
	_ents_cache = out
	_ents_rev = rev
	_ents_map = map_name
	return out

func _find_ent(code: String) -> EntityNode:
	if code == "" or not _map_ready():
		return null
	for e in app.canvas.ents_all():
		var n := e as EntityNode
		if n != null and n.code == code:
			return n
	return null

func _current_spr() -> EntityNode:
	return _find_ent(_selected_ent)

func _current_fns() -> Array:
	var n := _current_spr()
	return n.functions if n != null else []

## 分层内容 ID 的候选：地图码-实体码-实例码-功能id-内容码。
## 三段身份码来自各层载体（地图 meta / 清单 assets / 实体 meta），缺段返回空串。
func _content_id_for(n: EntityNode, fn_id: String) -> String:
	var map_code := str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", ""))
	var ent_code := str(AssetDecl.by_id(manifest, n.asset).get("code", ""))
	return ContentId.content_id(map_code, ent_code, n.code, fn_id)

## 写回附加功能：先撤销快照（改动前），再改 meta 并标脏。
## 内容条目留在库里，删绑定不等于删内容。
func _write_fns(n: EntityNode, fns: Array) -> void:
	if n == null:
		return
	app.canvas._push_undo()
	n.functions = fns.duplicate(true)
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
	var sid := spr.asset
	var code := spr.code
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
		sid = spr.asset
	var out := {}
	for m in FunctionDecls.entity_mounts(manifest, sid):
		out[str((m as Dictionary).get("code", ""))] = true
	return out

## 给当前实例补齐缺失的挂载绑定：缺的按声明顺序追加到末尾并重排 order。
## 只在真的补了东西时写盘/标脏——常规路径（绑定齐全）零副作用。
func _sync_mounted(spr: EntityNode) -> void:
	var sid := spr.asset
	var mounts: Array = FunctionDecls.entity_mounts(manifest, sid)
	if mounts.is_empty():
		return
	var fns: Array = spr.functions
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
	spr.functions = fns
	app.canvas._mark()

# ──────────── 实例引用编辑（实体类型 fields 声明的 entity_ref/map_ref） ────────────

## 按实体类型的引用型字段声明渲染下拉；值存实例 props。编辑器只管存取与呈现，
## 语义归游戏侧。类型没有引用声明就不出这个区块。
func _build_refs_block() -> Control:
	var spr := _current_spr()
	if spr == null or not is_instance_valid(spr):
		return null
	var sid := spr.asset
	var edef: Dictionary = AssetDecl.by_id(manifest, sid)
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
	var props: Dictionary = spr.props
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
	var props: Dictionary = spr.props.duplicate(true)
	if props.get(fd.id, null) == value:
		return
	app.canvas._push_undo()
	if value == "":
		props.erase(fd.id)
	else:
		props[fd.id] = value
	spr.props = props
	app.canvas._mark()
	# 指向预览：高亮被指实例（仅 entity_ref；map_ref 指向别的图，不高亮）
	var target := value if str(fd.type) == "entity_ref" else ""
	app.canvas.ref_highlight = target
	app.canvas.queue_redraw()
	if _preview != null:
		_preview.set_highlight(target)

## 左右列一起刷新（列表高亮、徽章、右栏表单都随绑定变化）
func _refresh_all() -> void:
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.refresh()
# ──────────── 右列：内容表单 ────────────


# ──────────── 演出子面板（steps:true 的功能绑定） ────────────


## —— 拆到 src/ui/fn_bind.gd / content_form.gd / steps_panel.gd（调用点保持不变） ——

func _build_fn_block() -> Control:
	return _fnbind._build_fn_block()
func _build_form_block() -> Control:
	return _form._build_form_block()
func _resolve_options(decl: Dictionary) -> Array:
	return _form._resolve_options(decl)
func _resolve_fn(f: Dictionary) -> Dictionary:
	return _fnbind._resolve_fn(f)
func _set_parallel(i: int, v: bool) -> void:
	_fnbind._set_parallel(i, v)
func _set_trigger(i: int, code: String) -> void:
	_fnbind._set_trigger(i, code)
func _set_enabled(i: int, v: bool) -> void:
	_fnbind._set_enabled(i, v)
func _delete_fn(i: int) -> void:
	_fnbind._delete_fn(i)
func _move_fn(i: int, dir: int) -> void:
	_fnbind._move_fn(i, dir)
func _add_fn(fn_id: String) -> void:
	_fnbind._add_fn(fn_id)
func _open_lib(i: int) -> void:
	_form._open_lib(i)
func _ensure_content(i: int) -> String:
	return _form._ensure_content(i)
func _ensure_failed() -> void:
	_form._ensure_failed()
func _refresh_status_only() -> void:
	_form._refresh_status_only()
func _open_steps_editor(i: int) -> void:
	_steps._open_steps_editor(i)
