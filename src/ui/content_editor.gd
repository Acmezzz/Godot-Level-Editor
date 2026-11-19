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
const LEFT_W := 220
const RIGHT_W := 360
## 预览悬停高亮色：青色，和选中框的黄（Th.WARN）区分开
const HOVER_COL := Color(0.35, 0.95, 0.95, 0.95)

var app
var manifest := {}
## 本控制器是 RefCounted：由 project_shell 把这个根 Control 挂进 _holder
var root: Control = null

var _selected_ent := ""
var _selected_fn := -1
## 预览区鼠标悬停的实例 id（青色高亮，与点击选中的黄框区分）
var _hover_ent := ""

# 左列
var _left_title: Label = null
var _rows_box: VBoxContainer = null
# 中列
var _preview: Control = null
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

	## 鼠标离开预览区：清掉悬停高亮，避免光标移出后框还停在原处
	func _notification(what: int) -> void:
		if ctrl == null:
			return
		if what == NOTIFICATION_MOUSE_EXIT:
			ctrl._set_preview_hover(self, Vector2.INF)
			ctrl._preview_panning = false   # 拖出预览区松不了中键：出界即复位
		elif what == NOTIFICATION_MOUSE_ENTER:
			ctrl._set_preview_hover(self, get_local_mouse_position())


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
	# 缩放/平移后地图不能画出控件边界（曾盖到左列）——同关卡画布的 SubViewport 裁剪语义
	_preview.clip_contents = true
	_preview.tooltip_text = "只读预览 · 滚轮缩放 · 中键拖动 · 点击实例选中"
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
		_preview_zoom = 1.0
		_preview_pan = Vector2.ZERO
	var ents := _entities()
	# 悬停 id 随切图/删实体失效：留着会指向不存在的实例，清干净
	if _hover_ent != "" and _find_ent(_hover_ent) == null:
		_hover_ent = ""
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

## Ctrl+S / 切视图：把还没失焦提交的连续控件改动统一写盘，避免 Esc 或直接切走时丢改动。
func commit() -> bool:
	if not _pending_fields.is_empty():
		var pend := _pending_fields.duplicate()
		_pending_fields.clear()
		for p in pend:
			var v = p.get("v")
			_set_field(int(p.get("i", -1)), str(p.get("fn_id", "")), str(p.get("key", "")),
				int(v) if str(p.get("type", "")) == "int" else v)
	return true

## 待提交的连续控件（SpinBox）：拖值期间只记内存，失焦/回车/commit() 才写内容文件。
var _pending_fields: Array = []

func _commit_pending(p: Dictionary) -> void:
	_pending_fields.erase(p)
	var v = p.get("v")
	_set_field(int(p.get("i", -1)), str(p.get("fn_id", "")), str(p.get("key", "")),
		int(v) if str(p.get("type", "")) == "int" else v)

# ──────────── 数据读取：只从画布实体读，不另存一份 ────────────

func _map_ready() -> bool:
	return app.map_loaded and app.canvas != null and is_instance_valid(app.canvas) \
		and app.canvas.entities != null and is_instance_valid(app.canvas.entities)

## 本图实例快照（按 ent_id 排序，保持稳定顺序）：[{spr, id, scene, name, fns}]
## P2-4：按 canvas.ents_rev 缓存——预览每次鼠标移动都调 _hit_ent_at，原实现每个事件
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
		})
	out.sort_custom(func(a, b): return _ent_less(str(a.id), str(b.id)))
	_ents_cache = out
	_ents_rev = rev
	_ents_map = map_name
	return out

## e_N 按数字排序（字符串排序会把 e_10 排到 e_3 前，行序看着像乱的）
func _ent_less(a: String, b: String) -> bool:
	var na := a.trim_prefix("e_").to_int()
	var nb := b.trim_prefix("e_").to_int()
	if a.begins_with("e_") and b.begins_with("e_") and na != nb:
		return na < nb
	return a < b

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
	# 标题以画布实际加载的地图为准（app.cur_map_name 在切图协程里可能短暂超前/滞后）
	var map_name := str(app.canvas.cur_map_name) if str(app.canvas.cur_map_name) != "" else "未命名"
	_left_title.text = "%s 实例" % map_name

	if ents.is_empty():
		_rows_box.add_child(Kit.empty_state("▦", "这张图没有实例",
			"去关卡编辑器放几个实体再回来挂功能"))
		return
	for row in ents:
		_rows_box.add_child(_build_row(row))

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

	# 按钮内容行撑满高度：ghost 按钮默认按文字定高，空文字会塌成 0
	b.custom_minimum_size = Vector2(0, 26)
	# 悬停行 → 预览里高亮对应实例（与预览内悬停同一状态 _hover_ent，青框）
	b.mouse_entered.connect(func():
		_hover_ent = ent_id
		if _preview != null:
			_preview.queue_redraw())
	b.mouse_exited.connect(func():
		if _hover_ent == ent_id:
			_hover_ent = ""
			if _preview != null:
				_preview.queue_redraw())
	return b

## 内容页是否在屏上（root 由 project_shell 切 visible）。隐藏时的选中只记状态不重建 UI。
func _is_view_visible() -> bool:
	return root != null and is_instance_valid(root) and root.visible

## 单一选中入口：左列行、中列画布预览、外部定位都走这里，避免两处状态不同步。
func select_inst(ent_id: String) -> void:
	if ent_id == "" or _find_ent(ent_id) == null:
		return
	# 切实例前先落盘当前 SpinBox 的待提交值（旧下标只对旧实例有效）
	commit()
	_selected_ent = ent_id
	_selected_fn = -1
	# P2-9：内容页隐藏时（关卡编辑器里点实体）不做整套左列/右栏重建，只记住选中，
	# 等切到内容视图时 refresh_list 再重建。
	if not _is_view_visible():
		return
	# 选中同步到关卡画布：切回关卡编辑器时选中框落在同一实例上。
	# 画布上已有框选组（>1）时不能把 selected_multi 覆写成 [spr]——
	# _box_select 会经 entity_selected 走到这里，覆写就等于「框选完立刻塌缩成单选」，
	# 整组拖动随即失效（用户报的「能框选但不能移动」）。只把单选指针挪过去即可。
	var spr := _find_ent(ent_id)
	if spr != null and app.canvas != null:
		app.canvas.selected_entity = spr
		# 只有「本次选中就是这个多选集合的成员」才保留集合；其它入口（新放置实体等）
		# 仍按单选收拢，避免旧框选残留在 selected_multi 里。
		var keep_multi: bool = app.canvas.selected_multi.size() > 1 \
			and app.canvas.selected_multi.has(spr)
		if not keep_multi:
			app.canvas.selected_multi = [spr]
		# P2-12：选中状态改了必须让画布重绘，否则选择框要等下一次任意重绘才落位。
		# 不发 entity_selected——那会经 app 再转回本函数，形成回环。
		app.canvas.queue_redraw()
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.queue_redraw()

# ──────────── 中列：重绘式预览 ────────────

## 预览缩放：fit 缩放 × 用户滚轮缩放（zoom 0.2~8），pan 为视图原点的屏幕偏移。
## 滚轮缩放以鼠标为锚点（指着的地图点缩放前后不动）；坐标换算全部走 _preview_origin。
var _preview_zoom := 1.0
var _preview_pan := Vector2.ZERO
var _preview_map := ""   # 预览缩放所属地图：切图时重置 zoom/pan
var _preview_panning := false   # 中键按住拖动平移（手势同关卡画布）

## fit 缩放：把整张地图塞进控件（留 24px 边距），不跟随关卡画布的 zoom/相机。
func _preview_fit(c: Control) -> float:
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

func _preview_scale(c: Control) -> float:
	return _preview_fit(c) * _preview_zoom

## 预览视图原点：居中原点 + 用户 pan 偏移（绘制与命中测试共用同一变换）
func _preview_origin(c: Control, s: float) -> Vector2:
	var meta: Dictionary = app.canvas.map_data.get("meta", {})
	var tile_px: float = float(app.canvas.tile_px)
	var map_px := Vector2(float(int(meta.get("w", 95))) * tile_px,
		float(int(meta.get("h", 56))) * tile_px) * s
	return (c.size - map_px) * 0.5 + _preview_pan

## 预览绘制：网格 + 真实地形/装饰瓦片 + 实例缩略图/色块 + 选中框。
## 地形必须画出来：只画实体点时，用户看不出实例压在什么地形上。
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
	var origin := _preview_origin(c, s)

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

	# 地形 / 装饰真实瓦片：预览必须看得出实例压在哪块地上，只画网格等于丢了一半信息。
	# 数据优先取画布实时 TileMapLayer（刚涂的立刻可见），退回 map_data 的序列化数组；
	# 两种来源都归一成 [x, y, atlas, ax, ay]，兼容旧 4 元 [x, y, ax, ay]。
	var texs: Array = app.canvas.atlas_texs
	for kind in ["terrain", "decor"]:
		var fallback: Color = Th.MAP_TERRAIN if str(kind) == "terrain" else Th.MAP_DECOR
		for t in _preview_tiles(str(kind)):
			# 只画地图边界内的格：画布允许在边界外涂，预览出框会显得脏
			var cx := int(t[0])
			var cy := int(t[1])
			if cx < 0 or cy < 0 or cx >= mw or cy >= mh:
				continue
			var ai := int(t[2])
			var src := Rect2(Vector2(float(t[3]), float(t[4])) * tile, Vector2(tile, tile))
			var dst := Rect2(origin + Vector2(float(t[0]), float(t[1])) * step, Vector2(step, step))
			var atex: Texture2D = null
			if ai >= 0 and ai < texs.size():
				atex = texs[ai] as Texture2D
			if atex != null:
				c.draw_texture_rect_region(atex, dst, src)
			else:
				c.draw_rect(dst, fallback, true)

	var hover_rect := Rect2()
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
		# 悬停框记下来，循环结束后再画：否则被后画的实体盖住，悬停看起来像没生效
		if str(row.id) == _hover_ent and str(row.id) != _selected_ent:
			hover_rect = rect
		if str(row.id) == _selected_ent:
			var pad := 3.0
			c.draw_rect(rect.grow(pad), Th.WARN, false, 2.0)
	# 悬停高亮：青色淡框 + 细十字（与选中的黄色实框区分），最后画保证在最上层
	if hover_rect.size.x > 0.0:
		var hr := hover_rect.grow(2.0)
		var hc := hr.get_center()
		c.draw_rect(hr, HOVER_COL, false, 1.5)
		c.draw_line(Vector2(hr.position.x, hc.y), Vector2(hr.end.x, hc.y), Color(HOVER_COL, 0.35), 1.0)
		c.draw_line(Vector2(hc.x, hr.position.y), Vector2(hc.x, hr.end.y), Color(HOVER_COL, 0.35), 1.0)

## 预览用的瓦片列表，统一为 [x, y, atlas, ax, ay]。
## 首选画布实时 TileMapLayer（编辑中的改动立刻反映），图层不可用时退回 map_data 数组。
## P2-4：整图满涂时每次重绘重建上万条临时数组——按 canvas.map_rev 缓存（任何写入都会抬它）。
var _tiles_cache := {}
var _tiles_rev := {}   # kind -> 缓存对应的 map_rev

func _preview_tiles(kind: String) -> Array:
	if not _map_ready():
		return []
	var rev: int = int(app.canvas.map_rev)
	if _tiles_rev.get(kind, -1) == rev:
		return _tiles_cache.get(kind, [])
	var out: Array = []
	var layer: TileMapLayer = app.canvas.terrain if kind == "terrain" else app.canvas.decor
	if layer != null and is_instance_valid(layer):
		for c in layer.get_used_cells():
			var ac: Vector2i = layer.get_cell_atlas_coords(c)
			if ac == Vector2i(-1, -1):
				continue
			out.append([c.x, c.y, layer.get_cell_source_id(c), ac.x, ac.y])
	else:
		for raw in app.canvas.map_data.get(kind, []):
			if not (raw is Array):
				continue
			var a: Array = raw
			if a.size() < 4:
				continue
			if a.size() >= 5:
				out.append([int(a[0]), int(a[1]), int(a[2]), int(a[3]), int(a[4])])
			else:
				out.append([int(a[0]), int(a[1]), 0, int(a[2]), int(a[3])])
	_tiles_cache[kind] = out
	_tiles_rev[kind] = rev
	return out

## 预览点击/悬停：命中半径取实体显示尺寸的一半（与它看起来的大小一致）。
## 手势对齐关卡画布：滚轮缩放（鼠标锚点）、中键按住拖动平移、左键点击选中。
func _preview_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# 中键拖动平移：pan 是屏幕偏移，手势语义与画布 cam_pos 相同（跟手走）
		if _preview_panning:
			_preview_pan += mm.relative
			_preview.queue_redraw()
			return
		_set_preview_hover(_preview, mm.position)
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP
			or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		_zoom_preview_at(mb.position, 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15)
		return
	if mb.button_index == MOUSE_BUTTON_MIDDLE:
		_preview_panning = mb.pressed
		return
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if _preview == null or not _map_ready():
		return
	var hit := _hit_ent_at(mb.position)
	if hit != "":
		select_inst(hit)

## 滚轮缩放预览：缩放前后鼠标指着的地图点不动。pan 屏幕偏移 = 新原点 − 新居中原点。
func _zoom_preview_at(pos: Vector2, factor: float) -> void:
	if _preview == null or not _map_ready():
		return
	var s_old := _preview_scale(_preview)
	if s_old <= 0.0:
		return
	var origin_old := _preview_origin(_preview, s_old)
	_preview_zoom = clampf(_preview_zoom * factor, 0.2, 8.0)
	var s_new := _preview_scale(_preview)
	if is_equal_approx(s_new, s_old):
		return
	_preview_pan = Vector2.ZERO
	var center_new := _preview_origin(_preview, s_new)
	_preview_pan = pos - (pos - origin_old) * (s_new / s_old) - center_new
	_preview.queue_redraw()

## 光标下的实体 id（"" = 空白处）。后画的在上层，命中测试要反向遍历
## （同一格叠多个时取最上面那个）。坐标均为预览控件本地坐标。
func _hit_ent_at(pos: Vector2) -> String:
	if _preview == null or not _map_ready():
		return ""
	var s := _preview_scale(_preview)
	if s <= 0.0:
		return ""
	var meta: Dictionary = app.canvas.map_data.get("meta", {})
	var map_px := Vector2(float(int(meta.get("w", 95))) * app.canvas.tile_px,
		float(int(meta.get("h", 56))) * app.canvas.tile_px) * s
	var origin := _preview_origin(_preview, s)
	var world := (pos - origin) / s
	var ents := _entities()
	for i in range(ents.size() - 1, -1, -1):
		var row: Dictionary = ents[i]
		var spr: Sprite2D = row.spr
		if spr == null or not is_instance_valid(spr):
			continue
		var half: Vector2 = app.canvas.entity_display_size_of(spr) * 0.5
		if absf(world.x - spr.position.x) <= maxf(half.x, 4.0) \
				and absf(world.y - spr.position.y) <= maxf(half.y, 4.0):
			return str(row.id)
	return ""

## 更新预览悬停实体并重绘（只在 id 变化时重绘，鼠标在空白处滑动不刷帧）。
## pos 传 Vector2.INF 表示「离开预览区」，直接清理。
func _set_preview_hover(c, pos: Vector2) -> void:
	var hit := "" if pos == Vector2.INF else _hit_ent_at(pos)
	if hit == _hover_ent:
		return
	_hover_ent = hit
	if c != null and is_instance_valid(c):
		c.queue_redraw()
	elif _preview != null:
		_preview.queue_redraw()

## 没开地图：清空三列并给引导。不伪造空行，让「先去开图」是唯一明确动作。
func _clear_all_for_empty() -> void:
	_selected_ent = ""
	_selected_fn = -1
	_hover_ent = ""
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
		_preview.queue_redraw()

# ──────────── 右列：渲染 ────────────

func _rebuild_right() -> void:
	if _r_body == null:
		return
	# 右栏控件整片重建：待提交项按旧下标记录，重建后失效，直接清（提交发生在选择变更前）。
	_pending_fields.clear()
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
	_r_badge.visible = false

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

## 追加功能：内容留空，等用户在表单里第一次改动时再生成 ID（§3.4 的「未填」状态）。
func _add_fn(fn_id: String) -> void:
	var spr := _current_spr()
	if spr == null or fn_id == "":
		return
	commit()   # 追加前先落盘当前表单待提交值（下标保持有效）
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
			# 连续控件不在每 tick 写盘（P1-6）：拖动期间只记内存，失焦/回车/commit 统一提交。
			# 与 asset_panel 的「编辑态只改内存、失焦提交」同一口径（O3）。
			var pend := {"i": i, "fn_id": fn_id, "key": key, "type": typ, "v": sp.value}
			_pending_fields.append(pend)
			sp.value_changed.connect(func(v: float): pend.v = v)
			sp.get_line_edit().text_submitted.connect(func(_t: String): _commit_pending(pend))
			sp.get_line_edit().focus_exited.connect(func(): _commit_pending(pend))
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
## P2-12 约定：字段值落在 content/<kind>/<id>.json，属「内容资产」而非地图快照——
## 不进画布撤销栈（撤销恢复的是地图，内容文件不回滚）；改地图 meta 的路径（_set_prop/_write_fns）
## 已各自 _push_undo()。连续控件按 O3 只在失焦/回车提交（见 _build_fn_form）。
func _set_field(i: int, fn_id: String, key: String, value) -> void:
	# P3-7：字符串字段统一 strip_edges——与实例固定块的 _set_prop 同口径，
	# 否则同一个名字在固定块里被裁、在内容表单里带着首尾空格落盘。
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
## P3-5：不再一律甩「目录权限」——真实失败原因多半是身份码没生成或 kind 不合法。
func _ensure_failed() -> void:
	var cur := _current_spr()
	if cur == null:
		app._set_status(" 内容写入失败：当前没有选中实例")
	elif str(cur.get_meta("code", "")) == "" and str(cur.get_meta("ent_id", "")) == "":
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
	var cand := _content_id_for(spr, fn_id)
	var new_id := ContentId.unique(manifest, fn_id, cand)
	if new_id == "":
		app._set_status(" 新内容 ID 生成失败（缺分层身份码或撞码重试耗尽）")
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
	commit()   # 复制库内容前先落盘当前表单待提交值（下标保持有效）
	var fns := _current_fns().duplicate(true)
	fns.append({"fn": fn_id, "content": new_id, "name": nm, "order": fns.size() + 1, "parallel": false})
	_selected_fn = fns.size() - 1
	_write_fns(spr, fns)
	_refresh_all()
	app._set_status(" 已复制「%s」为新内容 %s" % [nm, new_id])
