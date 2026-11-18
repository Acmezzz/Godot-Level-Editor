extends RefCounted
## 内容编辑器（批次 C）：左本图实例 / 中只读画布预览 / 右实例与功能。
##
## 与其它控制器同形：RefCounted + _init(host)，UI 全部用 Kit/Th 构建。
## 数据真相：实例绑定在画布 Sprite2D 的 meta（props / functions），
## 功能内容在 content/<fn>/<id>.json；本面板不做内存草稿，改动即时写盘。
## 中列是重绘式预览——同一节点不能两处上屏，所以不挂 app.canvas，只按坐标重画。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentId := preload("res://src/content/content_id.gd")
const MapStore := preload("res://src/map_store.gd")

## 序号圈字符；超出后回落到数字
const ORD := ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]
## 顶栏地图菜单里追加的地图项 id 从这里开始，避开 1..6 的文件动作
const MAP_MENU_BASE := 100
const LEFT_W := 220
const RIGHT_W := 360

var app
var manifest := {}
## 本控制器是 RefCounted：由 project_shell 把这个根 Control 挂进 _holder
var root: Control = null

var _selected_ent := ""
var _selected_fn := -1
var _only_todo := false

# 左列
var _left_title: Label = null
var _badge: PanelContainer = null
var _rows_box: VBoxContainer = null
var _filter_btn: Button = null
## 「校验本图」入口按钮（v2 §7.3 出口迁到内容编辑器左列）
var _val_btn: Button = null
# 中列
var _preview: Control = null
# 右列
var _r_name: Label = null
var _r_id: Label = null
var _r_badge: PanelContainer = null
var _r_body: VBoxContainer = null
# 表单里需要就地更新的那处：首次改动创建内容后只改 ID 文本，不重建表单（重建会丢焦点）
var _form_id_edit: LineEdit = null
# 顶栏地图菜单
var _map_menu: PopupMenu = null
var _map_menu_base_count := 0
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
	# 顶栏地图下拉挂未填徽章（批次 C 第 5 条）：不改 editor_layout，只在建好后追加
	_hook_map_menu()
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
	_badge = Kit.badge("0/0 未填", Th.OK)
	head.add_child(_badge)
	col.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows_box = Kit.vbox(2)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)
	col.add_child(scroll)

	_filter_btn = Kit.button("只看未填 (0)", func(): _toggle_filter(), "toggle")
	_filter_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_filter_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_filter_btn)
	# 校验本图（v2 §7.3：MapValidate/ContentValidate 的出口 = 内容编辑器的地图级清单）。
	# 旧右栏的问题页签随检查器一起删了，全图校验入口迁到这里。
	_val_btn = Kit.button("校验本图", func(): open_validate_popup(false), "ghost")
	_val_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_val_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_val_btn.tooltip_text = "校验当前地图 + 内容资源，问题条目可点击定位"
	col.add_child(_val_btn)
	col.add_child(Kit.hint_label("行尾黄点 = 有功能未填；点画布上的实体选中同一行。", LEFT_W - 24))
	return wrap

# ──────────── 中列：只读画布预览 ────────────

## 预览控件：真正画图的是控制器，本类只负责把 _draw / 点击转过去。
## 为什么要新类：同一 Node2D 不能同时挂在两份 UI 里，所以这里重绘而不是复用画布。
class PreviewControl extends Control:
	var ctrl = null

	func _draw() -> void:
		if ctrl != null:
			ctrl._draw_preview(self)

	func _gui_input(event: InputEvent) -> void:
		if ctrl != null:
			ctrl._preview_input(event)


func _build_middle() -> Control:
	var wrap := Control.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.custom_minimum_size = Vector2(240, 0)

	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", Th.flat(Th.BG_VOID, 0))
	wrap.add_child(bg)

	_preview = PreviewControl.new()
	_preview.ctrl = self
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview.tooltip_text = "只读预览 · 点击实例选中"
	wrap.add_child(_preview)

	var hint := Kit.text_label("只读预览 · 点击实例选中", Th.TEXT_MUTE, Th.FS_META)
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
	_sync_map_menu()
	if not _map_ready():
		_clear_all_for_empty()
		return
	var ents := _entities()
	# 选中项失效（切图/删实体）时回到第一行：右栏不该对着已不存在的实例
	if focus != "" and _find_ent(focus) != null:
		_selected_ent = focus
	elif _find_ent(_selected_ent) == null:
		# 没有显式 focus 时落在画布当前选中实体上——关卡编辑器「在工作台编辑 →」
		# 不带参数过来，用户期望看到的就是刚才选中的那个实例。
		var sel = app.canvas.selected_entity if app.canvas != null else null
		if sel != null and is_instance_valid(sel) and sel.has_meta("scene"):
			_selected_ent = str(sel.get_meta("ent_id", ""))
		if _find_ent(_selected_ent) == null:
			_selected_ent = str((ents[0] as Dictionary).get("id", "")) if not ents.is_empty() else ""
	_selected_fn = -1
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.queue_redraw()

## Ctrl+S：本面板改动即时写盘，这里只做一次可见反馈。
func commit() -> bool:
	return true

# ──────────── 数据读取：只从画布实体读，不另存一份 ────────────

func _map_ready() -> bool:
	return app.map_loaded and app.canvas != null and is_instance_valid(app.canvas) \
		and app.canvas.entities != null and is_instance_valid(app.canvas.entities)

## 本图实例快照（按 ent_id 排序，保持稳定顺序）：[{spr, id, scene, name, fns, todo}]
func _entities() -> Array:
	var out: Array = []
	if not _map_ready():
		return out
	for e in app.canvas.entities.get_children():
		var spr := e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		var sid := str(spr.get_meta("scene", ""))
		var fns = spr.get_meta("functions", [])
		var list: Array = fns if fns is Array else []
		out.append({
			"spr": spr,
			"id": str(spr.get_meta("ent_id", "")),
			"scene": sid,
			"name": str(app._scene_name(sid)),
			"fns": list,
			"todo": _fn_todo_count(list),
		})
	out.sort_custom(func(a, b): return _ent_less(str(a.id), str(b.id)))
	return out

## e_N 按数字排序（字符串排序会把 e_10 排到 e_3 前，行序看着像乱的）
func _ent_less(a: String, b: String) -> bool:
	var na := a.trim_prefix("e_").to_int()
	var nb := b.trim_prefix("e_").to_int()
	if a.begins_with("e_") and b.begins_with("e_") and na != nb:
		return na < nb
	return a < b

## 未填 = 附加功能里有 content == "" 的项（固定功能参数缺失本批次不判）
func _fn_todo_count(fns: Array) -> int:
	var n := 0
	for f in fns:
		if f is Dictionary and str((f as Dictionary).get("content", "")) == "":
			n += 1
	return n

func _find_ent(ent_id: String) -> Sprite2D:
	if ent_id == "" or not _map_ready():
		return null
	for e in app.canvas.entities.get_children():
		var spr := e as Sprite2D
		if spr != null and str(spr.get_meta("ent_id", "")) == ent_id:
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

## 写回附加功能：先撤销快照（改动前），再改 meta 并标脏。
## 内容条目留在库里，删绑定不等于删内容（与演示稿状态栏口径一致）。
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
	var todo_n := 0
	for row in ents:
		if int(row.todo) > 0:
			todo_n += 1
	var map_name := str(app.cur_map_name) if str(app.cur_map_name) != "" else "未命名"
	_left_title.text = "%s 实例" % map_name
	Kit.set_badge(_badge, "%d/%d 未填" % [todo_n, ents.size()], Th.WARN if todo_n > 0 else Th.OK)
	_filter_btn.text = ("显示全部 (%d)" if _only_todo else "只看未填 (%d)") % (ents.size() if _only_todo else todo_n)
	_filter_btn.button_pressed = _only_todo

	if ents.is_empty():
		_rows_box.add_child(Kit.empty_state("▦", "这张图没有实例",
			"去关卡编辑器放几个实体再回来挂功能"))
		return
	var shown := 0
	for row in ents:
		if _only_todo and int(row.todo) == 0:
			continue
		shown += 1
		_rows_box.add_child(_build_row(row))
	if shown == 0:
		_rows_box.add_child(Kit.hint_label("没有未填的实例了。", LEFT_W - 24))

## 实例行：类型名 + e_N + 状态点。整行是按钮，点击走 select_inst（与画布双向同步）。
func _build_row(row: Dictionary) -> Control:
	var ent_id := str(row.id)
	var on := ent_id == _selected_ent
	var b := Kit.button("", func(): select_inst(ent_id), "ghost")
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = "%s %s" % [str(row.name), ent_id]
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

	var iid := Kit.text_label(ent_id, Th.TEXT_MUTE, Th.FS_META)
	iid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(iid)

	var dot := Control.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var warn := int(row.todo) > 0
	dot.draw.connect(func():
		dot.draw_circle(Vector2(4, 4), 4.0, Th.WARN if warn else Th.OK))
	h.add_child(dot)

	# 按钮内容行撑满高度：ghost 按钮默认按文字定高，空文字会塌成 0
	b.custom_minimum_size = Vector2(0, 26)
	return b

func _toggle_filter() -> void:
	_only_todo = not _only_todo
	_rebuild_rows()

## 单一选中入口：左列行、中列画布预览、外部定位都走这里，避免两处状态不同步。
func select_inst(ent_id: String) -> void:
	if ent_id == "" or _find_ent(ent_id) == null:
		return
	_selected_ent = ent_id
	_selected_fn = -1
	# 选中同步到关卡画布：切回关卡编辑器时选中框落在同一实例上
	var spr := _find_ent(ent_id)
	if spr != null and app.canvas != null:
		app.canvas.selected_entity = spr
		app.canvas.selected_multi = [spr]
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.queue_redraw()

# ──────────── 中列：重绘式预览 ────────────

## 预览缩放：把整张地图塞进控件（留 24px 边距），不跟随关卡画布的 zoom/相机。
## 内容编辑只看「有哪些实例、在哪」，不需要精确对位。
func _preview_scale(c: Control) -> float:
	if not _map_ready() or c.size.x <= 1 or c.size.y <= 1:
		return 0.0
	var meta: Dictionary = app.canvas.map_data.get("meta", {})
	# app.canvas 在宿主上是无类型 var，链式取值是 Variant：必须显式标注，否则推断失败
	var tile_px: float = float(app.canvas.tile_px)
	var w: float = float(int(meta.get("w", 95))) * tile_px
	var h: float = float(int(meta.get("h", 56))) * tile_px
	if w <= 0 or h <= 0:
		return 0.0
	return minf((c.size.x - 48) / w, (c.size.y - 48) / h)

## 预览绘制：只画网格 + 实例缩略图/色块 + 选中框，不画地形瓦片
## （内容编辑关心「哪个实例」，地形只会让缩略图更难看清）。
func _draw_preview(c: Control) -> void:
	c.draw_rect(Rect2(Vector2.ZERO, c.size), Th.BG_VOID)
	if not _map_ready():
		c.draw_string(ThemeDB.fallback_font, Vector2(24, c.size.y * 0.5),
			"没有正在编辑的地图", HORIZONTAL_ALIGNMENT_LEFT, -1, Th.FS_SMALL, Th.TEXT_MUTE)
		return
	var s := _preview_scale(c)
	if s <= 0.0:
		return
	var meta: Dictionary = app.canvas.map_data.get("meta", {})
	var mw := int(meta.get("w", 95))
	var mh := int(meta.get("h", 56))
	var tile := float(app.canvas.tile_px)
	var map_px := Vector2(float(mw) * tile, float(mh) * tile) * s
	var origin := (c.size - map_px) * 0.5

	# 地图底 + 网格：缩略后逐格线过密就不画（避免一整片灰）
	c.draw_rect(Rect2(origin, map_px), Th.BG_BASE)
	var step := tile * s
	if step >= 6.0:
		var grid_col := Color(1, 1, 1, 0.05)
		for x in mw + 1:
			var px := origin.x + x * step
			c.draw_line(Vector2(px, origin.y), Vector2(px, origin.y + map_px.y), grid_col, 1.0)
		for y in mh + 1:
			var py := origin.y + y * step
			c.draw_line(Vector2(origin.x, py), Vector2(origin.x + map_px.x, py), grid_col, 1.0)
	c.draw_rect(Rect2(origin, map_px), Color(1, 1, 1, 0.25), false, 1.0)

	for row in _entities():
		var spr: Sprite2D = row.spr
		if spr == null or not is_instance_valid(spr):
			continue
		var dsz: Vector2 = app.canvas.entity_display_size_of(spr) * s
		var center := origin + spr.position * s
		var rect := Rect2(center - dsz * 0.5, dsz)
		var tex: Texture2D = app.canvas.thumbs.get(str(row.scene))
		if tex != null:
			c.draw_texture_rect(tex, rect, false)
		else:
			# 内置种类（触发区等）没有缩略图：画半透明块，尺寸就是它在游戏里的占位
			c.draw_rect(rect, Color(Th.ACCENT, 0.35), true)
			c.draw_rect(rect, Color(Th.ACCENT_HI, 0.8), false, 1.0)
		if str(row.id) == _selected_ent:
			var pad := 3.0
			c.draw_rect(rect.grow(pad), Th.WARN, false, 2.0)

## 预览点击：命中半径取实体显示尺寸的一半（与它看起来的大小一致）。
## 禁用拖拽/涂刷——本面板只做选中，位置属关卡编辑器（§9）。
func _preview_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if _preview == null or not _map_ready():
		return
	var s := _preview_scale(_preview)
	if s <= 0.0:
		return
	var meta: Dictionary = app.canvas.map_data.get("meta", {})
	var map_px := Vector2(float(int(meta.get("w", 95))) * app.canvas.tile_px,
		float(int(meta.get("h", 56))) * app.canvas.tile_px) * s
	var origin := (_preview.size - map_px) * 0.5
	var world := (mb.position - origin) / s
	# 后画的在上层，命中测试要反向遍历（同一格叠多个时选最上面那个）
	var ents := _entities()
	var hit := ""
	for i in range(ents.size() - 1, -1, -1):
		var row: Dictionary = ents[i]
		var spr: Sprite2D = row.spr
		if spr == null or not is_instance_valid(spr):
			continue
		var half: Vector2 = app.canvas.entity_display_size_of(spr) * 0.5
		if absf(world.x - spr.position.x) <= maxf(half.x, 4.0) \
				and absf(world.y - spr.position.y) <= maxf(half.y, 4.0):
			hit = str(row.id)
			break
	if hit != "":
		select_inst(hit)

## 没开地图：清空三列并给引导。不伪造空行，让「先去开图」是唯一明确动作。
func _clear_all_for_empty() -> void:
	_selected_ent = ""
	_selected_fn = -1
	_left_title.text = "实例"
	Kit.set_badge(_badge, "0/0 未填", Th.OK)
	_filter_btn.text = "只看未填 (0)"
	_filter_btn.button_pressed = false
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
		_preview.queue_redraw()

# ──────────── 右列：渲染 ────────────

func _rebuild_right() -> void:
	if _r_body == null:
		return
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
	var ent_id := str(spr.get_meta("ent_id", ""))
	_r_name.text = str(app._scene_name(sid))
	_r_id.text = "%s.%s" % [str(app.cur_map_name), ent_id]
	var todo := _fn_todo_count(_current_fns())
	_r_badge.visible = true
	Kit.set_badge(_r_badge, ("本实例 %d 项未填" % todo) if todo > 0 else "已填齐",
		Th.WARN if todo > 0 else Th.OK)

	_r_body.add_child(_build_fixed_block(sid))
	_r_body.add_child(Kit.divider())
	_r_body.add_child(_build_fn_block())
	if _selected_fn >= 0 and _selected_fn < _current_fns().size():
		_r_body.add_child(Kit.divider())
		_r_body.add_child(_build_form_block())

## 固定的「类型自带参数」：清单 entities[].stats 声明 → SpinBox / LineEdit。
## 值写在实体 meta props 上（实例级覆盖），不碰清单默认值——改模板去资产目录。
func _build_fixed_block(sid: String) -> Control:
	var box := Kit.vbox(6)
	box.add_child(Kit.section_header("固定功能", null))
	var stats := _stats_of(sid)
	if stats.is_empty():
		box.add_child(Kit.hint_label("这个类型没有可调参数。", RIGHT_W - 40))
		return box
	var spr := _current_spr()
	var props: Dictionary = spr.get_meta("props", {}) if spr != null else {}
	for st in stats:
		if not (st is Dictionary):
			continue
		var decl: Dictionary = st
		var key := str(decl.get("id", ""))
		if key == "":
			continue
		var typ := str(decl.get("type", "int"))
		var cur = props.get(key, decl.get("default", 0))
		var ctl: Control = null
		if typ == "int" or typ == "float":
			var sp := SpinBox.new()
			sp.step = 1.0 if typ == "int" else 0.1
			sp.min_value = float(decl.get("min", -999999))
			sp.max_value = float(decl.get("max", 999999))
			sp.value = float(cur) if str(cur) != "" else 0.0
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp.value_changed.connect(func(v: float):
				_set_prop(key, int(v) if typ == "int" else v))
			ctl = sp
		else:
			var le := LineEdit.new()
			le.text = str(cur)
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_submitted.connect(func(t: String): _set_prop(key, t.strip_edges()))
			le.focus_exited.connect(func(): _set_prop(key, le.text.strip_edges()))
			ctl = le
		box.add_child(Kit.field_row(str(decl.get("name", key)), ctl, 96))
	box.add_child(Kit.hint_label("固定功能由代码实现，只能改值。", RIGHT_W - 40))
	return box

func _stats_of(sid: String) -> Array:
	for e in manifest.get("entities", []):
		if e is Dictionary and str((e as Dictionary).get("id", "")) == sid:
			var st = (e as Dictionary).get("stats", [])
			return st if st is Array else []
	return []

## 写实例参数：改动前先存撤销快照；值等于声明默认值时删键，保持地图 JSON 精简。
func _set_prop(key: String, value) -> void:
	var spr := _current_spr()
	if spr == null:
		return
	var props: Dictionary = spr.get_meta("props", {})
	if props.get(key, null) == value:
		return
	app.canvas._push_undo()
	props = props.duplicate(true)
	props[key] = value
	spr.set_meta("props", props)
	app.canvas._mark()

## 附加功能列表：每行 ① 名称 [内容名] ⟳并行 [库] ✕；点行展开内容表单。
func _build_fn_block() -> Control:
	var box := Kit.vbox(6)
	box.add_child(Kit.section_header("附加功能", null))
	var fns := _current_fns()
	if fns.is_empty():
		box.add_child(Kit.hint_label("这个实例还没有附加功能。", RIGHT_W - 40))
	for i in fns.size():
		box.add_child(_build_fn_row(i, fns[i]))
	box.add_child(_build_add_row())
	return box

func _build_fn_row(i: int, item) -> Control:
	var f: Dictionary = item if item is Dictionary else {}
	var fn_id := str(f.get("fn", ""))
	var fname := str(f.get("name", ""))
	var content_id := str(f.get("content", ""))
	var on := i == _selected_fn

	var line := Kit.hbox(6)
	line.add_theme_constant_override("separation", 6)

	var ord := Kit.text_label(ORD[i] if i < ORD.size() else str(i + 1), Th.TEXT_MUTE, Th.FS_SMALL)
	line.add_child(ord)

	# 「库」按钮与「并行」勾选都要吞掉点击，否则会连带展开/收起表单
	var name_lbl := Kit.text_label(str(EditorManifest.function_name(manifest, fn_id)),
		Th.TEXT if on else Th.TEXT_SOFT, Th.FS_SMALL)
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
func _populate_add_menu() -> void:
	_add_menu.clear()
	var all := _function_index()
	var keys: Array = all.keys()
	keys.sort()
	for k in keys:
		var d: Dictionary = all[k]
		_add_menu.add_item(str(d.get("name", k)))
		_add_menu.set_item_metadata(_add_menu.get_item_count() - 1, str(k))

func _on_add_menu_id(idx: int) -> void:
	var fn_id := str(_add_menu.get_item_metadata(idx))
	_add_fn(fn_id)

func _function_index() -> Dictionary:
	return EditorManifest.functions(manifest)

func _pick_fn(i: int) -> void:
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
	fns = fns.duplicate(true)
	fns.remove_at(i)
	# order 之后重排：序号是执行顺序的唯一真相，删除后不能留空洞
	for k in fns.size():
		if fns[k] is Dictionary:
			(fns[k] as Dictionary)["order"] = k + 1
	_selected_fn = -1
	_write_fns(spr, fns)
	_refresh_all()

## 追加功能：内容留空，等用户在表单里第一次改动时再生成 ID（§3.4 的「未填」状态）。
func _add_fn(fn_id: String) -> void:
	var spr := _current_spr()
	if spr == null or fn_id == "":
		return
	var fns := _current_fns().duplicate(true)
	fns.append({"fn": fn_id, "content": "", "name": "", "order": fns.size() + 1, "parallel": false})
	_selected_fn = fns.size() - 1
	_write_fns(spr, fns)
	_refresh_all()

## 左右列一起刷新（列表状态点、徽章、右栏表单都随绑定变化）
func _refresh_all() -> void:
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.queue_redraw()

# ──────────── 右列：内容表单 ────────────

## 内容表单：字段按功能声明渲染（与实体 stats/fields 同一套声明式思路）。
## 内容文件结构 {id, function, name, fields:{字段id:值}}，fields 子字典留给以后扩展。
func _build_form_block() -> Control:
	var box := Kit.vbox(6)
	var fns := _current_fns()
	var i := _selected_fn
	var f: Dictionary = fns[i] if i >= 0 and i < fns.size() and fns[i] is Dictionary else {}
	var fn_id := str(f.get("fn", ""))
	var content_id := str(f.get("content", ""))
	var fn_label := str(EditorManifest.function_name(manifest, fn_id))
	var data: Dictionary = ContentStore.read(manifest, fn_id, content_id) if content_id != "" else {}
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

	var fields := EditorManifest.function_fields(manifest, fn_id)
	if fields.is_empty():
		box.add_child(Kit.hint_label("这个功能没有声明可填字段；填个名字即可。", RIGHT_W - 40))
	var cur: Dictionary = data.get("fields", {}) if data.get("fields", {}) is Dictionary else {}
	for fd in fields:
		if not (fd is Dictionary):
			continue
		box.add_child(_build_field_row(i, fn_id, fd, cur))
	if content_id == "":
		box.add_child(Kit.hint_label("首次修改任意字段即创建内容条目。", RIGHT_W - 40))
	return box

## 单个声明字段：int/float → SpinBox，bool → CheckBox，其余 → LineEdit。
func _build_field_row(i: int, fn_id: String, fd: Dictionary, cur: Dictionary) -> Control:
	var key := str(fd.get("id", ""))
	var typ := str(fd.get("type", "string"))
	var val = cur.get(key, fd.get("default", _default_for(typ)))
	var label := str(fd.get("name", key))
	var ctl: Control = null
	match typ:
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = bool(val)
			cb.toggled.connect(func(v: bool): _set_field(i, fn_id, key, v))
			ctl = cb
		"int", "float":
			var sp := SpinBox.new()
			sp.step = 1.0 if typ == "int" else 0.1
			sp.min_value = float(fd.get("min", -999999))
			sp.max_value = float(fd.get("max", 999999))
			sp.value = float(val) if str(val) != "" else 0.0
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp.value_changed.connect(func(v: float):
				_set_field(i, fn_id, key, int(v) if typ == "int" else v))
			ctl = sp
		_:
			var le := LineEdit.new()
			le.text = str(val)
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_submitted.connect(func(t: String): _set_field(i, fn_id, key, t))
			le.focus_exited.connect(func(): _set_field(i, fn_id, key, le.text))
			ctl = le
	return Kit.field_row(label, ctl, 96)

func _default_for(typ: String):
	match typ:
		"bool": return false
		"int": return 0
		"float": return 0.0
		_: return ""

## 字段改动：写内容文件。content 为空时首次改动即创建条目（ID 生成 + 绑定回写）。
func _set_field(i: int, fn_id: String, key: String, value) -> void:
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
	var fn_id := str(f.get("fn", ""))
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

func _blank_content(fn_id: String, cid: String) -> Dictionary:
	return {"id": cid, "function": fn_id, "name": fn_id, "fields": {}}

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
	var fn_id := str(f.get("fn", ""))
	var spr := _current_spr()
	if spr == null or fn_id == "":
		return ""
	var sid := str(spr.get_meta("scene", ""))
	var ent_id := str(spr.get_meta("ent_id", ""))
	var map_name := str(app.cur_map_name)
	var cand := ContentId.make(map_name, sid, ent_id, fn_id)
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
func _ensure_failed() -> void:
	app._set_status(" 内容写盘失败，检查 content 目录权限")
	if _r_badge != null:
		_r_badge.visible = true
		Kit.set_badge(_r_badge, "写盘失败", Th.ERR)

## 只刷左列/徽章，不重建右栏——表单重建会丢输入焦点，改一个字段就跳走无法连续输入。
func _refresh_status_only() -> void:
	_rebuild_rows()
	if _r_body != null:
		var spr := _current_spr()
		if spr != null:
			var todo := _fn_todo_count(_current_fns())
			Kit.set_badge(_r_badge, ("本实例 %d 项未填" % todo) if todo > 0 else "已填齐",
				Th.WARN if todo > 0 else Th.OK)
	if _preview != null:
		_preview.queue_redraw()

# ──────────── 库复用弹窗 ────────────

## 列同功能的全部内容条目；选中一条 → 复制成新 ID 追加到当前实例末尾。
## 跨功能不列：字段声明不同，复用没有意义（演示稿 filterLib 同口径）。
func _open_lib(i: int) -> void:
	var fns := _current_fns()
	if i < 0 or i >= fns.size():
		return
	var f: Dictionary = fns[i] if fns[i] is Dictionary else {}
	var fn_id := str(f.get("fn", ""))
	if fn_id == "":
		return
	var fn_label := str(EditorManifest.function_name(manifest, fn_id))
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
	var sid := str(spr.get_meta("scene", ""))
	var ent_id := str(spr.get_meta("ent_id", ""))
	var cand := ContentId.make(str(app.cur_map_name), sid, ent_id, fn_id)
	var new_id := ContentId.unique(manifest, fn_id, cand)
	if new_id == "":
		app._set_status(" 新内容 ID 生成失败（同前缀撞码）")
		return
	var nm := new_name.strip_edges()
	if nm == "":
		nm = str(src.get("name", "")) if str(src.get("name", "")) != "" else fn_id
	var src_fields = src.get("fields", {})
	var data := {
		"id": new_id,
		"function": fn_id,
		"name": nm,
		"fields": (src_fields as Dictionary).duplicate(true) if src_fields is Dictionary else {},
	}
	if not ContentStore.write(manifest, fn_id, new_id, data):
		app._set_status(" 写盘失败，检查 content 目录权限")
		return
	var fns := _current_fns().duplicate(true)
	fns.append({"fn": fn_id, "content": new_id, "name": nm, "order": fns.size() + 1, "parallel": false})
	_selected_fn = fns.size() - 1
	_write_fns(spr, fns)
	_refresh_all()
	app._set_status(" 已复制「%s」为新内容 %s" % [nm, new_id])

# ──────────── 顶栏地图下拉：切图 + 未填徽章 ────────────

## 地图菜单条目：[{name, todo, total}]，供外部（project_shell / app 钩子）读取。
## 按清单 + 磁盘地图文件枚举，todo = 该图还有未填功能的实例数。
func map_menu_entries() -> Array:
	var out: Array = []
	if str(manifest.get("_dir", "")) == "":
		return out
	for name in MapStore.list_maps(manifest):
		var map_name := str(name)
		var total := 0
		var todo := 0
		if map_name == str(app.cur_map_name) and _map_ready():
			# 当前图读内存态：磁盘还没有本次改动，按盘算徽章会滞后
			for row in _entities():
				total += 1
				if int(row.todo) > 0:
					todo += 1
		else:
			var data: Dictionary = MapStore.read(manifest, map_name)
			for e in data.get("entities", []):
				if not (e is Dictionary):
					continue
				total += 1
				if _fn_todo_count((e as Dictionary).get("functions", []) if (e as Dictionary).get("functions", []) is Array else []) > 0:
					todo += 1
		out.append({"name": map_name, "todo": todo, "total": total})
	return out

## 往顶栏地图菜单追加「切图」段：editor_layout 建的菜单 id 1..6 是文件动作，
## 地图项从 MAP_MENU_BASE 起编号，避免撞号。菜单是 app 的直接子节点（PopupMenu）。
## 用 about_to_popup 在弹出前重建——地图/未填数随时可能变，静态追加必然过期。
func _hook_map_menu() -> void:
	_map_menu = null
	# 菜单是顶栏里的嵌套子节点（不是 app 的直接子节点），必须递归找；
	# 以「第一项 id == 1（新建地图）」认出 editor_layout 建的那个 PopupMenu。
	for c in app.find_children("*", "PopupMenu", true, false):
		var pm := c as PopupMenu
		if pm != null and pm.item_count >= 6 and pm.get_item_id(0) == 1:
			_map_menu = pm
			break
	if _map_menu == null:
		return
	# 记下原有条目数（6 个动作 + 1 条分隔线），之后只截断这一段以后的追加项
	_map_menu_base_count = _map_menu.item_count
	if not _map_menu.id_pressed.is_connected(_on_map_entry):
		_map_menu.id_pressed.connect(_on_map_entry)
	# 弹出前重建地图段：不改 editor_layout 的菜单定义，也不需要在 app.gd 加钩子
	if not _map_menu.about_to_popup.is_connected(_sync_map_menu):
		_map_menu.about_to_popup.connect(_sync_map_menu)
	_sync_map_menu()

## 重建菜单里的地图段。当前地图打勾，未填数挂在条目名后（与左列徽章同口径）。
func _sync_map_menu() -> void:
	if _map_menu == null:
		return
	# 按索引截断：分隔线的 id 是 -1，按 id 判断会把 editor_layout 原有的分隔线也删掉
	while _map_menu.item_count > _map_menu_base_count:
		_map_menu.remove_item(_map_menu.item_count - 1)
	_map_menu.add_separator()
	var entries := map_menu_entries()
	if entries.is_empty():
		_map_menu.add_item("（还没有地图）")
		_map_menu.set_item_disabled(_map_menu.item_count - 1, true)
		return
	var cur := str(app.cur_map_name)
	var n := 0
	for row in entries:
		var name := str(row.name)
		var todo := int(row.todo)
		var label := name + (("  ·  %d 未填" % todo) if todo > 0 else "")
		_map_menu.add_item(label, MAP_MENU_BASE + n)
		if name == cur:
			_map_menu.set_item_as_checkable(_map_menu.item_count - 1, true)
			_map_menu.set_item_checked(_map_menu.item_count - 1, true)
		n += 1

## 菜单点击：地图段走切图（确认丢弃未保存改动由 _open_map_by_name 内部处理）。
func _on_map_entry(id: int) -> void:
	if id < MAP_MENU_BASE:
		return
	var entries := map_menu_entries()
	var idx := id - MAP_MENU_BASE
	if idx < 0 or idx >= entries.size():
		return
	app._open_map_by_name(str(entries[idx].name))

# ──────────── 校验（v2 §7.3：MapValidate / ContentValidate 的出口 = 地图级清单） ────────────

var _val_pop: PopupPanel = null

## 打开校验问题清单弹窗。all_maps=false 校验当前图（画布内存快照，未保存改动也覆盖），
## true 校验全部地图 + 关卡清单 + 内容资源。条目可点：带实例定位信息的跳关卡编辑器聚焦实体。
func open_validate_popup(all_maps: bool) -> void:
	if _val_pop != null and is_instance_valid(_val_pop):
		_val_pop.queue_free()
	var issues: Array = app._collect_issues(all_maps)
	var n_err := 0
	for it in issues:
		if str(it.get("level", "")) == "error":
			n_err += 1
	if issues.is_empty():
		app._set_status(" 校验通过：没有发现任何问题")
		return
	var pop := PopupPanel.new()
	var col: VBoxContainer = app.UiKitScript.vbox(10)
	col.custom_minimum_size = Vector2(560, 0)
	pop.add_child(col)
	var head: HBoxContainer = app.UiKitScript.hbox(8)
	head.add_child(app.UiKitScript.text_label("校验问题 %s：%d 项（%d 个错误）" % [
		"全部地图" if all_maps else "本图", issues.size(), n_err],
		app.UiThemeScript.TEXT, app.UiThemeScript.FS_MD))
	head.add_child(app.UiKitScript.spacer())
	head.add_child(app.UiKitScript.button("关闭", func(): pop.hide(), "ghost"))
	col.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, minf(app.get_viewport_rect().size.y - 220, 420))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var rows: VBoxContainer = app.UiKitScript.vbox(3)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	for it in issues:
		var level := str(it.get("level", "warn"))
		var map_n := str(it.get("map", ""))
		var eid := str(it.get("ent_id", ""))
		var msg := str(it.get("message", ""))
		var field := str(it.get("field", ""))
		var mark := "●" if level == "error" else "○"
		var row: Button = app.UiKitScript.button("%s %s%s  %s" % [mark,
			(map_n + " · ") if map_n != "" else "", field, msg], Callable(), "ghost")
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_theme_color_override("font_color",
			app.UiThemeScript.ERR if level == "error" else app.UiThemeScript.TEXT_DIM)
		if map_n != "" and eid != "":
			row.tooltip_text = "点击定位到该实例"
			row.pressed.connect(func():
				pop.hide()
				app._focus_issue(map_n, eid))
		else:
			row.tooltip_text = field + "\n" + msg
		rows.add_child(row)
	_val_pop = pop
	app.add_child(pop)
	pop.popup_centered(Vector2i(1, 1))
	var want := pop.get_contents_minimum_size().ceil()
	var vp: Vector2 = app.get_viewport_rect().size
	want.x = minf(want.x, vp.x - 40)
	want.y = minf(want.y, vp.y - 40)
	pop.popup_centered(Vector2i(want))

