extends RefCounted
## 内容编辑器：左列本图实例列表 / 中列只读画布预览 / 右列实例引用 + 功能绑定与内容表单。
##
## 与其它控制器同形：RefCounted + _init(host)，样式统一走 Kit/Th。
## 中列是重绘式预览——同一节点不能两处上屏，不挂 app.canvas，按坐标重画。
##
## 三种写入时机（别混成一句「即时写盘」）：
##   1) 已有内容文件的字段 → 控件失焦/回车/commit() 时**当场写那个内容文件**（不每击键）；
##      写前比对磁盘摘要，被外部改过就拒写并提示。
##   2) 还没创建的内容（新绑定第一次改字段）→ 先发行分层 ID，值进 **staged 暂存**
##      （按内容 ID 查，不按功能码），正式提交（Ctrl+S/试玩）时才落盘；
##      绑定被撤销后暂存行作废，不留孤儿文件。
##   3) 实例绑定本身（functions 数组、props 引用值）→ 只改地图内存态，随地图保存；
##      改动走 _write_fns，进画布撤销栈。
## 内容文件不是地图快照的一部分：撤销只回退地图，不回滚已写的内容文件。

const FrameReference := preload("res://src/ui/map_game_preview.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentId := preload("res://src/content/content_id.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const Preview := preload("res://src/ui/content_preview.gd")
const ContentForm := preload("res://src/ui/content_form.gd")
const FnBind := preload("res://src/ui/fn_bind.gd")
const ReferenceViewLibrary := preload("res://src/ui/reference_view_library.gd")
const ViewportLibrary := preload("res://src/ui/viewport_library.gd")
const ProjectContentLibrary := preload("res://src/ui/project_content_library.gd")
const StepsPanel := preload("res://src/ui/steps_panel.gd")
const SessionContext := preload("res://src/ui/session_context.gd")
const K := preload("res://src/core/constants.gd")
const INSTANCE_REF_TYPES := ["entity_ref", "map_ref", "edge_ref", "port_ref"]

## 序号圈字符；超出后回落到数字
const LEFT_W := 220
const RIGHT_W := 360

var app
## 拆分出的子控制器
var _form   # content_form.gd：内容表单/库/写盘
var _fnbind   # fn_bind.gd：功能绑定行
var _library: ProjectContentLibrary
var _steps   # steps_panel.gd：演出子面板
var manifest := {}
## 本控制器是 RefCounted：由 project_shell 把这个根 Control 挂进 _holder
var root: Control = null
## E1：演出面板的停靠位（三列下方，占位不覆盖表单；内容页构建时创建）
var steps_dock_slot: PanelContainer = null

var _selected_ent := ""
var _selected_fn := -1
## E1：上次展开的功能（执行码）+ 所属实例——切到资产/关卡再回来时按身份恢复展开项。
## 只记身份不记节点：实例被删/换绑时自然回落为空。
var _remembered_binding := {}
var _remembered_fn_ent := ""
## 当前定位所属地图（切图即忘掉上一张图的选中与记忆）
var _selected_map := ""
## E1：问题抽屉定位的字段 id（引用区行高亮一次；下次普通重建清空）
var _field_focus := ""

# 左列
var _left_title: Label = null
var _instance_count: Label
var _instance_scroll: ScrollContainer
var _rows_box: VBoxContainer = null
# 中列（只读预览控件，实现见 content_preview.gd）
var _preview: Control = null
# 右列
var _r_name: Label = null
var _r_id: Label = null
var _r_badge: PanelContainer = null
var _r_body: VBoxContainer = null
# 表单里需要就地更新的那处：首次改动创建内容后只改 ID 文本，不重建表单（重建会丢焦点）
var _form_id_edit: LineEdit = null
## 「+ 添加功能」弹层：控制器级单例，跨 _rebuild_right 复用
@warning_ignore("unused_private_class_variable")

func _init(host) -> void:
	app = host
	_form = ContentForm.new(self)
	_fnbind = FnBind.new(self)
	_steps = StepsPanel.new(self)
	_library = ProjectContentLibrary.new(self)
	manifest = host.manifest

## 由 project_shell 调用：构建三区骨架并返回可挂进 _holder 的根节点。
func build() -> Control:
	root = Control.new()
	root.tree_exited.connect(_release_view_callbacks)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", Th.flat(Th.BG_BASE, 0))
	root.add_child(bg)

	# E1 演出停靠位：竖排「三列 + 底部演出面板」。停靠时三列让出高度，
	# 而不是把面板浮在表单上（浮动会盖住正在填的字段）。
	var stack := Kit.vbox(0)
	stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(stack)
	var cols := Kit.hbox(0)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(cols)
	steps_dock_slot = PanelContainer.new()
	steps_dock_slot.custom_minimum_size = Vector2(0, 340)
	steps_dock_slot.visible = false
	# 槽本身不画框也不留内边距：面板自带描边与留白，叠两层会显脏
	steps_dock_slot.add_theme_stylebox_override("panel", Th.flat(Th.BG_BASE, 0))
	stack.add_child(steps_dock_slot)
	cols.add_child(_build_left())
	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(_build_middle())
	split.add_child(_build_right())
	cols.add_child(split)
	return root

func _release_view_callbacks() -> void:
	# The view owns these callbacks; their closures can refer back to this controller.
	_filter_refill = Callable()
	_pending_commits.clear()
	_steps.clear_view_callbacks()

# ──────────── 左列：本图实例列表 ────────────

func _build_left() -> Control:
	var box := Kit.frame(SIDE_RIGHT, 12, 12)
	box.custom_minimum_size.x = LEFT_W
	var col := Kit.vbox(10)
	box.add_child(col)

	col.add_child(Kit.section_label("项目内容"))
	col.add_child(Kit.button("打开项目内容库…", open_project_library, "plain"))
	col.add_child(Kit.button("屏幕界面…", func():
		if commit_fields():
			ReferenceViewLibrary.open(app, "", {"layout": true}), "plain"))
	var references := Kit.hbox(6)
	var sizes := Kit.button("参考画幅…", func():
		if commit_fields():
			ViewportLibrary.open(app), "ghost")
	var views := Kit.button("参考视图…", func():
		if commit_fields():
			ReferenceViewLibrary.open(app, "", {"layout": false}), "ghost")
	for button in [sizes, views]:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		references.add_child(button)
	col.add_child(references)
	col.add_child(Kit.divider())
	var head := Kit.hbox(6)
	_left_title = Kit.clipped_label("地图实例", Th.TEXT, Th.FS_MD)
	_left_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_left_title)
	_instance_count = Kit.text_label("", Th.TEXT_DIM, Th.FS_SMALL)
	head.add_child(_instance_count)
	col.add_child(head)

	# E2 筛选：名称/实例码 + 层 + 资产。列表长时按需收窄，不改数据、不动选中。
	var frow := Kit.vbox(4)
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "筛选：名称或实例码"
	_filter_edit.clear_button_enabled = true
	_filter_edit.text_changed.connect(func(t: String):
		_filter_text = t
		_rebuild_rows())
	frow.add_child(_filter_edit)
	var srow := Kit.hbox(4)
	var layer_opt := OptionButton.new()
	layer_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layer_opt.fit_to_longest_item = false
	layer_opt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	layer_opt.custom_minimum_size.x = 88
	layer_opt.tooltip_text = "按图层收窄实例列表（不影响画布选中）"
	var asset_opt := OptionButton.new()
	asset_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	asset_opt.fit_to_longest_item = false
	asset_opt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	asset_opt.custom_minimum_size.x = 88
	asset_opt.tooltip_text = "按资产类型收窄实例列表"
	# 选项在每次刷新列表时按当前图重建（层/资产随切图变化）
	var refill_opts := func():
		var keep_l := _filter_layer
		var keep_a := _filter_asset
		layer_opt.clear()
		layer_opt.add_item("全部层")
		layer_opt.set_item_metadata(0, "")
		if app.canvas != null:
			for i in app.canvas.layer_count():
				layer_opt.add_item(app._layer_label(i))
				layer_opt.set_item_metadata(layer_opt.item_count - 1, app.canvas.layer_id(i))
		asset_opt.clear()
		asset_opt.add_item("全部资产")
		asset_opt.set_item_metadata(0, "")
		var seen := {}
		for row in _entities():
			var aid := str((row as Dictionary).get("asset", ""))
			if aid == "" or seen.has(aid):
				continue
			seen[aid] = true
			asset_opt.add_item(AssetDecl.label(manifest, aid))
			asset_opt.set_item_metadata(asset_opt.item_count - 1, aid)
		# 回填（静默）：选项里没有原来的值就退回「全部」
		var li := 0
		for k in layer_opt.item_count:
			if str(layer_opt.get_item_metadata(k)) == keep_l:
				li = k
		layer_opt.select(li)
		_filter_layer = str(layer_opt.get_item_metadata(li))
		var ai := 0
		for k2 in asset_opt.item_count:
			if str(asset_opt.get_item_metadata(k2)) == keep_a:
				ai = k2
		asset_opt.select(ai)
		_filter_asset = str(asset_opt.get_item_metadata(ai))
	layer_opt.item_selected.connect(func(k: int):
		_filter_layer = str(layer_opt.get_item_metadata(k))
		_rebuild_rows())
	asset_opt.item_selected.connect(func(k: int):
		_filter_asset = str(asset_opt.get_item_metadata(k))
		_rebuild_rows())
	srow.add_child(layer_opt)
	srow.add_child(asset_opt)
	frow.add_child(srow)
	col.add_child(frow)
	# 切图/换清单后选项要跟着换；_rebuild_rows 每次都会调到这里（幂等）
	_filter_refill = refill_opts

	var scroll := ScrollContainer.new()
	_instance_scroll = scroll
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows_box = Kit.vbox(2)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)
	col.add_child(scroll)

	col.add_child(Kit.hint_label("点击预览或列表选择实例。", LEFT_W - 24))
	return box

# ──────────── 中列：只读画布预览（实现在 src/ui/content_preview.gd） ────────────

func _build_middle() -> Control:
	var box := Control.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.custom_minimum_size = Vector2(240, 0)

	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", Th.flat(Th.BG_VOID, 0))
	box.add_child(bg)

	_preview = Preview.new(self)
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_child(_preview)

	var hint := Kit.text_label("只读预览 · 滚轮缩放 · 中键拖动 · 点击实例选中", Th.TEXT_MUTE, Th.FS_META)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.position = Vector2(12, 10)
	box.add_child(hint)
	return box

# ──────────── 右列：实例与功能 ────────────

func _build_right() -> Control:
	var box := Kit.frame(SIDE_LEFT, 14, 12)
	box.custom_minimum_size.x = RIGHT_W
	var col := Kit.vbox(10)
	box.add_child(col)
	col.add_child(Kit.section_label("实例详情"))

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
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_r_body = Kit.vbox(10)
	_r_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_r_body)
	col.add_child(scroll)
	return box

# ──────────── 刷新入口（project_shell 调用） ────────────

## 进入内容视图时调用。focus 是实例 id（右键/定位直达），空则保留上次选中。
func refresh_list(focus := "") -> void:
	if root == null:
		return
	manifest = app.manifest
	if not _map_ready():
		_clear_all_for_empty()
		return
	var ents := _entities()
	# 切图：旧图的选中/记忆实例对这张图没有意义，直接忘掉（否则会被误判成「已删除」）
	var map_key: String = app._map_file_ctrl.document_key()
	var map_changed := _selected_map != map_key
	if map_changed:
		_selected_map = map_key
		_preview.reset_view()
		_selected_ent = ""
		_remembered_fn_ent = ""
		_remembered_binding.clear()
	# 悬停 id 随切图/删实体失效：留着会指向不存在的实例，清干净
	if _preview.hover_ent != "" and _find_ent(_preview.hover_ent) == null:
		_preview.set_hover("")
	# 选中项解析顺序：显式 focus → 画布当前选中 → 上次记着的实例 → 第一行。
	# 目标在同图内已删除时显示空态——不落到第一行冒充「恢复成功」（E1 身份校验）。
	var prev_ent := _selected_ent
	if focus != "" and _find_ent(focus) != null:
		_selected_ent = focus
	else:
		var canvas_sel := ""
		var sel = app.canvas.selected_entity if app.canvas != null else null
		if sel is EntityNode and is_instance_valid(sel) and (sel as EntityNode).code != "":
			canvas_sel = (sel as EntityNode).code
		if canvas_sel != "":
			_selected_ent = canvas_sel
		elif _remembered_fn_ent != "" and _find_ent(_remembered_fn_ent) != null:
			_selected_ent = _remembered_fn_ent
		elif prev_ent != "" and _find_ent(prev_ent) == null:
			# 同图内上次选中的实例已不存在：明确空态，保留「请重选」的提示
			_selected_ent = ""
			_remembered_fn_ent = ""
			_remembered_binding.clear()
			_selected_fn = -1
			_rebuild_rows()
			_rebuild_right()
			if _preview != null:
				_preview.refresh()
			app._set_status("上次编辑的实例 %s 已不存在：请重新选一个实例" % prev_ent)
			return
		elif _find_ent(_selected_ent) == null:
			_selected_ent = str((ents[0] as Dictionary).get("code", "")) if not ents.is_empty() else ""
	_selected_fn = _restore_fn_index()
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.refresh()

## E1：恢复展开的绑定；重复功能使用行 ID，旧行用已有的内容身份。
## 同一实例被换绑/删功能时退回「未展开」，不猜一个邻近下标。
func _restore_fn_index() -> int:
	if _remembered_fn_ent == "" or _remembered_fn_ent != _selected_ent:
		return -1
	return SessionContext.fn_index_of(_current_fns(), str(_remembered_binding.get("fn", "")),
		str(_remembered_binding.get("bindingId", "")), str(_remembered_binding.get("content", "")))

## E1：记下当前内容页展开的实例及绑定，供切走再回来恢复。
func remember_context() -> void:
	if _selected_ent == "":
		return
	_remembered_fn_ent = _selected_ent
	var fns := _current_fns()
	if _selected_fn >= 0 and _selected_fn < fns.size() and fns[_selected_fn] is Dictionary:
		var row: Dictionary = fns[_selected_fn]
		_remembered_binding = {"fn": row.get("fn", ""), "bindingId": row.get("bindingId", ""),
			"content": row.get("content", "")}
	else:
		_remembered_binding.clear()

## 提交控件值；暂存内容仍等地图保存或试玩才写盘。
func commit_fields() -> bool:
	var pend := _pending_commits.duplicate()
	for cb in pend:
		if cb is Callable and cb.is_valid():
			var result = cb.call()
			if result is bool and not result:
				return false
	return _steps._flush_pending()

## 数值和文本控件可在失焦或显式提交时写入。
var _pending_commits: Array = []

# ──────────── 数据读取：只从画布实体读，不另存一份 ────────────

func _map_ready() -> bool:
	return app.map_loaded and app.canvas != null and is_instance_valid(app.canvas)

## 仅缓存本图实体，场景摆放物不参与内容绑定。
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
			"layer": n.layer_id,
			"name": str(app._scene_name(n.asset)),
			"position": n.position,
			"fns": n.functions,
		})
	# 保持画布放置顺序（撤销恢复也稳定），不做字符串排序
	_ents_cache = out
	_ents_rev = rev
	_ents_map = map_name
	return out

func _find_ent(code: String) -> EntityNode:
	return app.canvas.entity_by_code(code) if not code.is_empty() and _map_ready() else null

func _current_spr() -> EntityNode:
	return _find_ent(_selected_ent)

func _current_fns() -> Array:
	var n := _current_spr()
	return n.functions if n != null else []

## 分层内容 ID 的候选：地图码-实体码-实例码-功能执行码-内容码。
## 身份来自地图、实例和清单声明，缺段不发号。
func _content_id_for(n: EntityNode, fn_id: String) -> String:
	var map_code: String = app.canvas.cur_map_code()
	var ent_code := str(AssetDecl.by_id(manifest, n.asset).get("code", ""))
	return ContentId.content_id(map_code, ent_code, n.code, FunctionDecls.fn_code(manifest, fn_id))

## 写回附加功能：改的是该实例的 functions 数组 → InstanceKey 差量（§7.5 阶段二）。
## 内容条目留在库里，删绑定不等于删内容。
func _write_fns(n: EntityNode, fns: Array) -> void:
	if n == null:
		return
	var pre: Dictionary = app.canvas._undo_history_ctrl.inst_rows([n])
	var via_delta := bool(pre.get("ok", false))
	if not via_delta:
		app.canvas.push_undo()
	var updated := fns.duplicate(true)
	for i in mini(n.functions.size(), updated.size()):
		# Untouched rows keep their in-memory identity for open step and field controls.
		if n.functions[i] is Dictionary and updated[i] is Dictionary and n.functions[i] == updated[i]:
			updated[i] = n.functions[i]
	n.functions = updated
	if via_delta:
		app.canvas._undo_history_ctrl.inst_commit(pre.get("rows", {}))
	app.canvas._mark_ents()

# ──────────── 左列渲染 ────────────

## E2：实例列表筛选（名称/实例码 + 图层 + 资产）。放在左列标题下、列表上，
## 三件套一起决定「现在看哪些实例」；筛选只影响列表显示，不动数据与选中。
var _filter_text := ""
var _filter_layer := ""   # 空 = 全部层
var _filter_asset := ""   # 空 = 全部资产
var _filter_edit: LineEdit = null
var _filter_refill: Callable = Callable()   # 层/资产下拉的选项重建（列表刷新时调用）

## E2：筛选后的实例快照（保持画布放置顺序）。
func _filtered_ents() -> Array:
	var q := _filter_text.strip_edges().to_lower()
	var out: Array = []
	for row in _entities():
		var r: Dictionary = row
		if _filter_layer != "" and str(r.get("layer", "")) != _filter_layer:
			continue
		if _filter_asset != "" and str(r.get("asset", "")) != _filter_asset:
			continue
		if q != "":
			var hay := ("%s %s" % [str(r.get("name", "")), str(r.get("code", ""))]).to_lower()
			if not hay.contains(q):
				continue
		out.append(r)
	return out

func _rebuild_rows() -> void:
	if _rows_box == null:
		return
	# 层/资产下拉的选项跟随当前图的层栈与实例集（幂等：保留已选值，失效则退回「全部」）
	if _filter_refill is Callable and (_filter_refill as Callable).is_valid():
		(_filter_refill as Callable).call()
	for c in _rows_box.get_children():
		_rows_box.remove_child(c)
		c.queue_free()
	var ents := _filtered_ents()
	var all_n: int = _entities().size()
	# 标题以画布实际加载的地图为准（app.cur_map_name 在切图协程里可能短暂超前/滞后）
	var map_name := str(app.canvas.cur_map_name) if str(app.canvas.cur_map_name) != "" else "未命名"
	_left_title.text = "地图实例"
	_left_title.tooltip_text = map_name
	_instance_count.text = str(all_n) if ents.size() == all_n else "%d/%d" % [ents.size(), all_n]

	if ents.is_empty():
		if all_n == 0:
			_rows_box.add_child(Kit.empty_state("▦", "这张图没有实例",
				"先在「关卡」视图摆放实体，再回来配置功能"))
		else:
			_rows_box.add_child(Kit.empty_state("⌕", "筛选没有命中",
				"清空上方筛选条件，或换一个关键词"))
		return
	for row in ents:
		var button := _build_row(row)
		_rows_box.add_child(button)
		if str(row.code) == _selected_ent and _is_view_visible() and not _filter_edit.has_focus():
			var reveal := func():
				if is_instance_valid(button) and _instance_scroll.is_ancestor_of(button):
					_instance_scroll.ensure_control_visible(button)
			reveal.call_deferred()

## 实例行：类型名 + 实例码。整行是按钮，点击走 select_inst（与画布双向同步）。
func _build_row(row: Dictionary) -> Control:
	var code := str(row.code)
	var on := code == _selected_ent
	var b := Kit.button("", Callable(), "ghost")
	b.pressed.connect(func():
		if code == _selected_ent:
			return
		var had_focus := b.has_focus()
		select_inst(code)
		if had_focus:
			for child in _rows_box.get_children():
				if child.get_meta("instance", "") == code:
					child.grab_focus()
					break)
	b.set_meta("instance", code)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var layer_index: int = app.canvas._layer_index_of(row.layer)
	var location := "%s · %s" % [app._layer_label(layer_index), str(Vector2i(row.position))]
	b.tooltip_text = "%s · %s\n%s" % [str(row.name), code, location]
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

	var nm := Kit.text_label("%s\n%s" % [str(row.name), location], Th.TEXT if on else Th.TEXT_SOFT, Th.FS_SMALL)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(nm)

	var iid := Kit.text_label(code, Th.TEXT_MUTE, Th.FS_META)
	iid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(iid)

	# 按钮内容行撑满高度：ghost 按钮默认按文字定高，空文字会塌成 0
	b.custom_minimum_size = Vector2(0, 42)
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
	# 换实例前先提交旧表单值。
	if not commit_fields():
		return
	_selected_ent = code
	_selected_fn = -1
	# E1：画布停靠态下点选了别的实例——演出面板编辑的已不是当前对象，先收起
	_steps.revalidate_dock()
	# 切实例清指向预览：高亮属于上一个实例的引用编辑，不带走
	app.canvas.ref_highlight = ""
	app.canvas.queue_redraw()
	if _preview != null:
		_preview.set_highlight("")
	# 内容页隐藏时只记住选中，由进入视图时刷新。
	if not _is_view_visible():
		return
	# 与画布同步选中时保留已经形成的多选。
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
	_pending_commits.clear()
	_form_sig = ""
	_form_block = null
	_preview.set_hover("")
	_left_title.text = "地图实例"
	_instance_count.text = "0"
	if _rows_box != null:
		for c in _rows_box.get_children():
			_rows_box.remove_child(c)
			c.queue_free()
		_rows_box.add_child(Kit.empty_state("▦", "没有正在编辑的地图",
			"可直接开项目内容库，或先新建地图再编辑实例"))
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

## 阶段三：表单控件复用。右栏重建会销毁并重造全部字段控件（一行一个下拉/输入框，
## 大功能几十行），而「重选同一实例」「问题抽屉定位后回填」这类重建其实没改表单内容。
## 这里按身份+值算一个签名，签名没变就直接留用现有控件：输入焦点、滚动位置、待提交值都不动。
var _form_block: Control = null
var _form_sig := ""

func _form_sig_of(spr: EntityNode) -> String:
	if spr == null or not is_instance_valid(spr):
		return ""
	var fns := _current_fns()
	var f: Dictionary = fns[_selected_fn] \
		if _selected_fn >= 0 and _selected_fn < fns.size() and fns[_selected_fn] is Dictionary else {}
	var fn_id := str(_form._resolve_fn(f).get("id", ""))
	var cid := str(f.get("content", ""))
	var data := {}
	if cid != "":
		var st = _form._staged_get(fn_id, cid)
		data = (st as Dictionary).get("data", {}) if st is Dictionary \
			else (_form._content_read(fn_id, cid) if fn_id != "" else {})
	# 只列影响表单呈现的量：实例身份/类型/字段值、绑定表、展开的功能、内容数据、定位高亮
	return JSON.stringify([spr.get_instance_id(), spr.code, spr.asset, spr.props, fns, _selected_fn, fn_id, cid, data, _field_focus])

func reload_content_form() -> void:
	_form_sig = ""
	_rebuild_right()

func _rebuild_right() -> void:
	if _r_body == null:
		return
	# E1：右栏重建 = 可能换了实例/绑定。停靠的演出面板按身份复核，对不上就收起
	_steps.revalidate_dock()
	var spr0 := _current_spr()
	var sig0 := _form_sig_of(spr0)
	if sig0 != "" and sig0 == _form_sig \
			and _form_block != null and _form_block.get_parent() == _r_body:
		# 阶段三：表单内容一个键都没变——不重建，保住焦点/滚动/未提交的连续控件值
		return
	# 右栏控件整片重建：待提交项绑定的是旧控件，重建后失效，直接清（提交发生在选择变更前）。
	_pending_commits.clear()
	for c in _r_body.get_children():
		_r_body.remove_child(c)
		c.queue_free()
	_form_block = null
	_form_sig = ""
	_form_id_edit = null
	var spr := spr0
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

	_r_body.add_child(_build_fn_block())
	if _selected_fn >= 0 and _selected_fn < _current_fns().size():
		_r_body.add_child(Kit.divider())
		_form_block = _build_form_block()
		_r_body.add_child(_form_block)
	var params := _build_instance_values(spr)
	if params != null:
		_r_body.add_child(params)
		_r_body.add_child(Kit.divider())
	var refs := _build_refs_block()
	if refs != null:
		_r_body.add_child(refs)
		_r_body.add_child(Kit.divider())
	_form_sig = sig0

func _build_instance_values(spr: EntityNode) -> Control:
	var box := Kit.vbox(6)
	box.add_child(Kit.section_header("实例参数"))
	var fields: Array = AssetDecl.by_id(manifest, spr.asset).get("fields", [])
	for fd in fields:
		if not fd is Dictionary or fd.get("kind", "") not in ["input", "choice"] \
				or fd.get("type", "") in INSTANCE_REF_TYPES:
			continue
		var fid: String = fd.id
		var value = spr.props.get(fid, fd.get("default", FieldWidgets.default_for(fd)))
		var written := {"value": spr.props.get(fid)}
		var pair := func() -> Array[String]: return RefFields.frame_scope(fd, fields, spr.props, "id")
		var scope: Array[String] = pair.call()
		var current := func() -> bool:
			return box.get_parent() == _r_body and is_instance_valid(spr) and spr == _current_spr() \
				and spr.props.get(fid) == written.value
		var apply := func(v) -> bool:
			# 实例差量先恢复节点，再通知选中。旧控件失焦时不能盖掉刚恢复的值。
			if not current.call():
				return false
			app.canvas._ref_ops_ctrl.set_instance_value(spr, fid, v)
			written.value = v
			_form_sig = ""
			_preview.refresh()
			return true
		var decl: Dictionary = fd.duplicate()
		var paired: String = scope[0]
		if paired != "":
			decl["_mapKey"] = paired
		var frame_pick := func(nested_row: Control, nested: Dictionary, nested_pair: Callable, save: Callable, read: Callable):
			FrameReference.add_reference_button(app, nested_row, nested, nested_pair, save, reference_options, false,
				_rebuild_right, "", read)
		# 普通控件在撤销通知时可能还有待提交值；过期值应丢弃。
		# 实景确认则必须让弹窗知道是否真的写入。
		var scope_selector: bool = RefFields.describe(fd).kind in ["map", "layer"]
		var built := FieldWidgets.build(decl, value, func(v):
			if not current.call() or pair.call() != scope:
				return
			if scope_selector:
				_set_prop_ref(fd, v)
			else:
				apply.call(v), reference_options, "id", frame_pick)
		var control: Control = built.ctl
		control.name = "InstanceValue_" + fid
		var field_row := Kit.field_row(str(fd.get("name", fid)), control, 96)
		field_row.tooltip_text = FieldWidgets.decl_tooltip(fd)
		if FieldWidgets.wants_frame_pick(fd) and FieldWidgets.frame_value_available(fd, built):
			frame_pick.call(field_row, fd, pair, apply, built.get("pick_values", Callable()))
		if fid == _field_focus:
			Kit.highlight_field_row(field_row)
		box.add_child(field_row)
		_pending_commits.append(built.commit)
	if box.get_child_count() > 1:
		return box
	box.free()
	return null

## 自带功能（挂载）——类型自带、实例不可删，与附加功能同一套绑定/内容模型：
## 值在 content/<功能id>/<内容ID>.json，未编辑过的实例 = 声明 default（游戏侧兜底）。
## 绑定补齐在放置/载图时完成（C09，FunctionDecl.fill_bindings，写 mounted 继承行）；
## 选中事件只刷新界面。列表里的锁 = 挂载码集。

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

# ──────────── 实例引用编辑（实体类型 fields 声明的 entity_ref/map_ref） ────────────

## 按实体类型的引用型字段声明渲染下拉；值存实例 props。编辑器只管存取与呈现，
## 语义归游戏侧。类型没有引用声明就不出这个区块。
## 字段顺序按声明：配对地图字段（mapField 指向）先渲染，引用行据此取目标域（C1）。
func _build_refs_block() -> Control:
	var spr := _current_spr()
	if spr == null or not is_instance_valid(spr):
		return null
	var sid := spr.asset
	var edef: Dictionary = AssetDecl.by_id(manifest, sid)
	var fdecls: Array = edef.get("fields", []) if edef.get("fields", []) is Array else []
	var rows: Array = []
	var map_rows: Array = []
	for fd in fdecls:
		if fd is Dictionary:
			var t := str(fd.get("type", ""))
			if t in INSTANCE_REF_TYPES:
				rows.append(fd)
				if t == "map_ref":
					map_rows.append(fd)
	if rows.is_empty():
		return null
	var box := Kit.vbox(6)
	box.add_child(Kit.section_header("引用"))
	var props: Dictionary = spr.props
	# 先出配对地图字段：引用行的「目标图」来自它们（缺省 = 本图）
	for fd in map_rows:
		box.add_child(_build_ref_row(fd, props, fdecls))
	for fd in rows:
		if not map_rows.has(fd):
			box.add_child(_build_ref_row(fd, props, fdecls))
	return box

## 单个引用字段行：entity_ref → 实例下拉（of 限定类型，未声明 of 列全部）；
## map_ref → 地图下拉。声明了 mapField 的 entity_ref 枚举**配对地图**的实例；
## 配对地图未填时取所属图（本图）。值不在选项里时由 FieldWidgets 保留原值。
func _build_ref_row(fd: Dictionary, props: Dictionary, fdecls: Array = []) -> Control:
	var fid := str(fd.get("id", ""))
	var object_ref := str(fd.get("type", "")) in ["edge_ref", "port_ref"]
	var cur = props.get(fid, null) if object_ref else str(props.get(fid, ""))
	var built: Dictionary
	var d := fd.duplicate(true)
	if str(fd.get("type", "")) == "map_ref":
		d["kind"] = "choice"
		d["source"] = "map"
	elif object_ref:
		d["kind"] = "input"
		# §7.4：格边引用 = 对象值 {map, cell, edge}，FieldWidgets 的 edge_ref 分支统一编码成 JSON 走下拉
		var emap := RefFields.paired_map_value(fd, fdecls, props, "id")
		if emap != "":
			d["_mapKey"] = emap
	else:
		d["kind"] = "choice"
		d["source"] = "entity_inst:" + str(fd.get("of", ""))
		var target_map := RefFields.paired_map_value(fd, fdecls, props, "id")
		if target_map != "":
			d["_mapKey"] = target_map   # 引用解析据此枚举目标图实例
	var expected_map := str(d.get("_mapKey", ""))
	var origin := _current_spr()
	var apply := func(v) -> void:
		if origin == null or not is_instance_valid(origin) or origin != _current_spr() \
				or RefFields.paired_map_value(fd, fdecls, origin.props, "id") != expected_map:
			return
		_set_prop_ref(fd, v)
	built = FieldWidgets.build(d, cur, apply, reference_options)
	built.ctl.name = "InstanceReference_" + fid
	var row := Kit.field_row(str(fd.get("name", fid)), built.ctl, 96)
	var tip := FieldWidgets.decl_tooltip(fd)
	if tip != "":
		row.tooltip_text = tip
	var pickable := FieldWidgets.wants_canvas_pick(fd)
	if pickable and _form.can_pick_on_canvas(expected_map):
		var pick := Kit.button("画布选…", func(): _pick_prop_ref(fd, apply), "ghost")
		pick.tooltip_text = "临时切到画布点一个实例；确认才写入，取消不改当前值"
		pick.add_theme_font_size_override("font_size", Th.FS_META)
		row.add_child(pick)
	if FieldWidgets.wants_frame_pick(fd) and FieldWidgets.frame_value_available(fd, built):
		var pair := func() -> Array[String]: return RefFields.frame_scope(fd, fdecls, origin.props, "id")
		var save := func(value) -> bool:
			if not is_instance_valid(origin) or origin != _current_spr():
				return false
			await _set_prop_ref(fd, value)
			return origin.props.get(fid) == value
		var frame_pick := FrameReference.add_reference_button(app, row, d, pair, save,
			reference_options, false, _rebuild_right, "", built.get("pick_values", Callable()))
		if frame_pick != null:
			frame_pick.name = "FrameReference_" + fid
	# E1：问题抽屉跳「某字段悬空」——对应行加一次醒目标记（重建后即消失）
	if fid == _field_focus:
		Kit.highlight_field_row(row)
		row.tooltip_text = "问题定位：这个引用字段需要处理"
	return row

## E1：问题抽屉定位到某字段。选中实例后调用；字段行在重建时按 _field_focus 高亮一次
## （重建完立刻清空：后续普通刷新不再带这块高亮）。
func highlight_field(fid: String) -> void:
	_field_focus = fid
	_rebuild_right()
	_field_focus = ""
	if fid != "":
		app._set_status("已定位到实例 %s 的字段 %s（问题抽屉）" % [_selected_ent, fid])

## E1：实例 props 引用字段的画布选点。确认后与手选下拉同一写入口（撤销/配对清空规则一致）。
## accept 按字段种类走：entity_ref = 实例；§7.4 edge_ref = 格边（值解码回 {map, cell, edge}）。
func _pick_prop_ref(fd: Dictionary, apply: Callable) -> void:
	var fname := str(fd.get("name", str(fd.get("id", ""))))
	var mode := FieldWidgets.pick_mode(fd)
	var is_edge := mode == "edge"
	var of := FieldWidgets.canvas_pick_types(fd)
	var hint := ("为「%s」选一条格边（靠近格边点）" % fname) if is_edge else ("为「%s」选目标实例" % fname)
	if mode == "port":
		hint = "为「%s」选目标端口" % fname
	if not is_edge and not of.is_empty():
		hint += "（限定类型：%s）" % ",".join(PackedStringArray(of))
	var on_ok := func(code: String):
		if code == "":
			return
		var value = FieldWidgets.decode_pick(mode, code)
		if value != null:
			apply.call(value)
			_rebuild_right()
	app._begin_canvas_pick("content", mode, hint, on_ok, Callable(), of)

## 写实例 props 的引用字段：props 是地图数据，改动进撤销栈；并做指向预览高亮。
## E2：与画布连线把手走同一写入口（ref_ops.set_entity_ref）——改配对地图字段时
## 旧落点会指向别的图的实例码（C1），确认与「一起清空」的规则只写在一处。
func _set_prop_ref(fd: Dictionary, value) -> void:
	var spr := _current_spr()
	if spr == null or not is_instance_valid(spr) or not app.map_loaded:
		return
	var res: Dictionary = await app.canvas._ref_ops_ctrl.set_entity_ref(spr, fd, value)
	if RefFields.describe(fd).kind in ["map", "layer"]:
		# 下拉回调结束后再重建，保住其他控件尚未提交的值。
		_refresh_instance_scope.call_deferred(spr)
	if str(res.get("status", "")) != "ok":
		return
	# 指向预览：高亮被指实例（仅当前图 entity_ref；跨图/地图/格边引用不高亮）——
	# RefOps 已在画布上写好 ref_highlight，这里同步只读预览列
	var target := ""
	if str(fd.get("type", "")) == "entity_ref" and value is String \
			and app.canvas.is_entity_code_local(value):
		target = value
	if _preview != null:
		_preview.set_highlight(target)

func _refresh_instance_scope(spr: EntityNode) -> void:
	if is_instance_valid(spr) and spr == _current_spr() and commit_fields():
		reload_content_form()

## 左右列一起刷新（列表高亮、徽章、右栏表单都随绑定变化）
func _refresh_all() -> void:
	_rebuild_rows()
	_rebuild_right()
	if _preview != null:
		_preview.refresh()

## 内容文件被编辑器自己改写（撤销/重做回滚内容字段）后同步界面。
## 只在这份内容正开着时重建右栏——重建会丢输入焦点，别的条目不碰。
func refresh_after_external_write(fn_id: String, cid: String) -> void:
	_steps.refresh_after_restore(fn_id, cid)
	var fns := _current_fns()
	var i := _selected_fn
	if i >= 0 and i < fns.size() and fns[i] is Dictionary:
		var f: Dictionary = fns[i]
		if str(f.get("content", "")) == cid and str(_resolve_fn(f).get("id", "")) == fn_id:
			# 撤销已经把盘面写回旧值：控件里还没提交的值作废丢弃（重建后按盘面显示），
			# 不能在这里 commit——那会把刚撤销的值又写回去。
			_pending_commits.clear()
			_rebuild_right()
			if _preview != null:
				_preview.refresh()
			return
	if _preview != null:
		_preview.refresh()
# ──────────── 右列：内容表单 ────────────


# ──────────── 演出子面板（steps:true 的功能绑定） ────────────


## 跨面板入口：内容库、声明驱动的引用选择和演出定位。
func open_project_library() -> void:
	_library.open()

func open_project_content(fn_id: String, cid: String, context := "") -> void:
	_library.open_item(fn_id, cid, context)

func reference_options(decl: Dictionary, project_scope := false) -> Array:
	return _form.reference_options(decl, project_scope)

func project_reference_options(decl: Dictionary, context: String, snapshot := {}) -> Array:
	return _form.project_reference_options(decl, context, snapshot)

func saved_reference_options(decl: Dictionary) -> Array:
	return _form.saved_reference_options(decl)

func open_content_timeline(fn_id: String, cid: String, context: String, time: Variant = null) -> bool:
	return _steps.open_timeline(fn_id, cid, context, time)

## —— 拆到 src/ui/fn_bind.gd / content_form.gd / steps_panel.gd（调用点保持不变） ——

func _build_fn_block() -> Control:
	return _fnbind._build_fn_block()
func _build_form_block() -> Control:
	return _form._build_form_block()
func _resolve_fn(f: Dictionary) -> Dictionary:
	return _fnbind._resolve_fn(f)
func _set_parallel(tok: Dictionary, v: bool) -> void:
	_fnbind._set_parallel(tok, v)
func _set_trigger(tok: Dictionary, code: String) -> void:
	_fnbind._set_trigger(tok, code)
func _set_enabled(tok: Dictionary, v: bool) -> void:
	_fnbind._set_enabled(tok, v)
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

## 暂存内容是否还有未落盘的（全部文档合计；正式提交/试玩据此判定）
func has_staged_content() -> bool:
	return _form.has_staged()

## 当前文档（地图）的暂存状态与目标（R02/R04：提交日志与草稿按文档冻结）。
func staged_rows_current_doc() -> Array:
	return _form.staged_rows_for_current_doc()
## 当前文档的暂存内容 {ContentKey: data}。
func staged_data_by_key() -> Dictionary:
	return _form.staged_data_by_key()
func has_staged_for_current_doc() -> bool:
	return _form.has_staged_for_current_doc()
func consume_written_staged(receipts: Array) -> void:
	_form.consume_written_staged(receipts)

func drop_staged_for_doc(doc: String) -> int:
	return _form.drop_staged_for_doc(doc)
## 草稿恢复：把待提交内容载荷重新暂存（R03）；返回收下的条数。
func restage_rows(rows: Array) -> int:
	return _form.restage_rows(rows)
## 复制粘贴产生的暂存（R12）：粘贴不落盘，随正式提交写入；撤销随绑定复核丢弃。
func stage_clone(fn_id: String, cid: String, data: Dictionary, ent: String) -> void:
	_form.stage_clone(fn_id, cid, data, ent)

func bound_staged_rows(map_data: Dictionary) -> Array:
	return _form.bound_staged_rows(map_data)


## 暂存感知的内容读写（steps_panel 用）：刚 staged 的新内容还没落盘，
## 直接 ContentStore.read 会读到空，编辑步骤就会丢掉。
func read_content_staged(fn_id: String, cid: String) -> Dictionary:
	return _form._content_read(fn_id, cid)

## 暂存感知读取 + 磁盘摘要（R05 演出写回基线）：{data, digest}。
func read_content_staged_ex(fn_id: String, cid: String) -> Dictionary:
	return _form._content_read_ex(fn_id, cid)

## 暂存感知写回（R05）：base_digest 非空时写前比对，磁盘被外部改过不覆盖。
## 返回 ContentStore 口径的 "ok" / "conflict" / "fail"（不是布尔：冲突与失败要分开报）。
func write_content_staged(fn_id: String, cid: String, data: Dictionary, base_digest: String, before: Dictionary) -> String:
	return _form._content_write(fn_id, cid, data, base_digest, before)

func _ensure_failed() -> void:
	_form._ensure_failed()
func _refresh_status_only() -> void:
	_form._refresh_status_only()
func _open_steps_editor(i: int) -> void:
	_steps._open_steps_editor(i)
## E1：停靠的演出面板跟随视图搬家（内容=三列下方 / 关卡=画布下方）
func sync_steps_dock(view: String) -> void:
	_steps.sync_dock_to_view(view)
