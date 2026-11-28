extends RefCounted
## 演出子面板（列表视图 + 时间轴视图 + 步骤参数表单）：从 content_editor.gd 拆出的控制器，
## 宿主 = content_editor（host 引用）。
##
## 一条数据、两个视图：列表与时间轴渲染**同一份** `steps` 数组，任何改动都写回同一个工作副本，
## 不存在「时间轴另存一份」。面板令牌（会话 + 内容键 + 绑定身份 + 结构版本）保证异步回调
## （拖块结束、步进器失焦）落在发起它的那一次编辑上——令牌不匹配就丢弃，不写错内容。
## 时间单位（秒/帧/拍）由功能声明的 timebase 与 TimelineClock 解释，数据形态不变；
## 写盘时机与其他内容字段一致（工作副本 → 正式提交），不做逐键写盘。

const FrameReference := preload("res://src/ui/map_game_preview.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const StepTimeline := preload("res://src/content/step_timeline.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const TimelineClock := preload("res://src/content/timeline_clock.gd")
const AudioPreview := preload("res://src/ui/timeline_audio_preview.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const EntityNodeRef := preload("res://src/canvas/entity_node.gd")
const SessionContext := preload("res://src/ui/session_context.gd")
const GamePreview := preload("res://src/project/game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")
const MapGamePreview := preload("res://src/ui/map_game_preview.gd")
const TIMELINE_FRAME := "timelineFrame"

# content_editor 持有该子控制器；反向只保留弱引用，切换项目时可释放。
var _host_ref: WeakRef
var host:
	get: return _host_ref.get_ref()
var app    # 根应用（= host.app）

func _init(h) -> void:
	_host_ref = weakref(h)
	app = h.app

var manifest: Dictionary:
	get: return host.manifest
## 步骤表单独立收集待提交值，重建时不影响主表单。
var _pending_commits: Array = []

func clear_view_callbacks() -> void:
	_pending_commits.clear()

## 冲刷本面板待提交值（换步骤/切时间轴点选前调用；控件闭包绑定的是当时的下标）。
func _flush_pending() -> bool:
	for cb in _pending_commits.duplicate():
		if cb is Callable and cb.is_valid():
			var result = cb.call()
			if result is bool and not result:
				return false
	return true

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
	if _project_target:
		return host.project_reference_options(decl, _reference_context)
	return host.reference_options(decl, _project_scope)
func _rebuild_right() -> void:
	host._rebuild_right()

var _steps_pop: PopupPanel = null
## 浮窗、内容页和画布停靠共用一份编辑状态。
var _steps_dock_where := "popup"
var _steps_dock: PanelContainer = null
var _steps_i := -1            # 正在编辑的绑定行下标
var _steps_fn_id := ""        # 该绑定的功能 id
var _steps_ent := ""
var _steps_cid := ""          # 该绑定的内容 ID（身份校验：绑定换内容 = 数据源失效）
var _project_manifest: Dictionary = {}
var _project_target := false
var _project_scope := false
var _reference_context := ""
var _steps_map := ""
var _steps_rev := 0           # 结构版本：增删/排序后递增，过期控件回调据此丢弃（D1）
var _steps_sel := -1          # 当前选中步骤下标；-1 = 无
var _steps_page := 0
const STEPS_PAGE_SIZE := 40
## 重开时检查原步骤身份；不匹配则清空选中。
var _steps_sel_expect := ""
var _steps_list: VBoxContainer = null
var _steps_form: VBoxContainer = null
var _steps_view := "list"     # "list" / "timeline"
var _steps_tabs: HBoxContainer = null
var _steps_tl_box: VBoxContainer = null
var _steps_scroll: ScrollContainer = null
var _steps_tl: TimelineView = null
var _steps_tl_rev := -1       # 时间轴视图绑定的结构版本
var _steps_clock = null       # TimelineClock（D2）：秒换算/吸附粒度
var _steps_clock_missing: Array = []   # 声明了但解析不到的参考项（表单显示，不阻断编辑）
var _steps_preview_asset := ""         # frameAssetField 解析出的资产码（帧基预览用）
var _steps_preview_frames: Array = []   # 该资产的帧序列（相对路径）
var _steps_preview_idx := -1            # 当前预览帧（播放头所在帧）
var _steps_audio: Dictionary = {}
var _audio_preview: Node
var _audio_button: Button
var _steps_frame_holder: Control = null  # 参考帧预览行（播放头移动时只刷这一行）
var _steps_playhead_label: Label = null  # 播放头读数（原始单位 → 秒；负秒 = 音频起点前）
## 同一份内容重开时恢复步骤、视图和播放头。
var _steps_mem := {}

static func _mem_key(fn_code: String, cid: String) -> String:
	return fn_code + "\u0001" + cid

## 打开演出子面板：绑定已有内容就地编辑；空绑定**首次实际改动才预留内容 ID**（D1/A2）。
## E1：默认弹出独立窗口；可停靠到内容页底部或画布下方，也可随时独立展开。
## 三种形态共用同一控制器/工作副本/结构版本，切换只换宿主容器，不重建数据。
func _open_steps_editor(i: int) -> void:
	if not host.commit_fields():
		return
	var fns := _current_fns()
	var f: Dictionary = fns[i] if i >= 0 and i < fns.size() and fns[i] is Dictionary else {}
	var fn_id := str(_resolve_fn(f).get("id", ""))
	if fn_id == "":
		return
	# 缺 steps 声明就不该有演出入口（从旧版本/脚本调用来的也挡掉）
	if not FunctionDecls.fn_has_steps(manifest, fn_id):
		return
	_project_target = false
	_project_scope = false
	_project_manifest = {}
	_steps_i = i
	_steps_fn_id = fn_id
	_steps_ent = str(host._selected_ent)
	_steps_cid = str(f.get("content", ""))
	_steps_binding = f
	_steps_map = app._map_file_ctrl.document_key()
	_mount_target()

func open_content(fn_id: String, cid: String, context := "", step_index := -1, field := "") -> bool:
	if not host.commit_fields() or not FunctionDecls.fn_has_steps(manifest, fn_id) or cid == "":
		return false
	_project_target = true
	_project_scope = true
	_reference_context = context
	_project_manifest = manifest
	_steps_i = 0
	_steps_fn_id = fn_id
	_steps_ent = ""
	_steps_cid = cid
	_steps_binding = {}
	_steps_map = ""
	_mount_target()
	if step_index >= 0:
		_steps_pick(step_index)
		if field != "" and _steps_form != null:
			for row in _steps_form.get_children():
				if row.get_meta("field_id", "") == field:
					Kit.highlight_field_row(row)
					var ancestor := row.get_parent()
					while ancestor != null and not ancestor is ScrollContainer:
						ancestor = ancestor.get_parent()
					if ancestor is ScrollContainer:
						ancestor.ensure_control_visible.call_deferred(row)
					break
	return true

## 供跨面板定位和截图：打开内容，再把时间轴滚动到指定播放头。
func open_timeline(fn_id: String, cid: String, context: String, time: Variant = null) -> bool:
	if not open_content(fn_id, cid, context) or not _set_steps_view("timeline"):
		return false
	if time != null:
		_set_preview_position(maxf(0.0, time))
		_steps_tl.follow_playhead.call_deferred()
	return true

func _mount_target() -> void:
	var fn_id := _steps_fn_id
	_steps_rev = 0
	# 时间轴视图对象每次开面板都是新建的：版本缓存必须同样归零，
	# 否则「0 == 0」会跳过 set_steps，再开一次时间轴页签就是空白。
	_steps_tl_rev = -1
	_steps_sel = -1
	_steps_page = 0
	_steps_view = "list"
	_steps_clock = null
	_steps_clock_missing = []
	_steps_preview_asset = ""
	_steps_preview_frames = []
	_steps_preview_idx = -1
	_steps_audio = {}
	# E1：同一份内容再开 → 恢复步骤/视图/播放头（下标在 _rebuild 里按当前步数收敛）
	var mem: Dictionary = _steps_mem.get(_mem_key(FunctionDecls.fn_code(manifest, fn_id), _steps_cid), {})
	_steps_sel_expect = ""
	if not mem.is_empty():
		_steps_sel = int(mem.get("sel", -1))
		_reveal_step_page()
		_steps_view = str(mem.get("view", "list"))
		# 记下记忆里那一步的步骤码：复盘时若下标已指向别的步骤，宁可无选中
		_steps_sel_expect = str(mem.get("step", ""))
	# 停靠形态按当前视图落位：在内容页开就得落在内容页（画布停靠位此刻是隐藏的）
	if _steps_dock_where != "popup":
		_steps_dock_where = "content" if host._is_view_visible() else "canvas"
	# 旧宿主先拆干净：停靠形态下重复打开会往同一容器里再叠一份控件
	_teardown_steps_host()
	_steps_mount(mem)

## 按当前宿主形态（弹窗 / 内容下方 / 画布下方）建造面板内容。mem 非空时回填播放头。
func _steps_mount(mem: Dictionary) -> void:
	var body: VBoxContainer = null
	var head: HBoxContainer = null
	if _steps_dock_where != "popup":
		# 防御：旧弹窗若还开着（上次没走 teardown 的路径），先收掉——同一时刻只留一个宿主
		if _steps_pop != null and is_instance_valid(_steps_pop):
			var stale: PopupPanel = _steps_pop
			_steps_pop = null
			stale.hide()
		var d := _ensure_dock(_steps_dock_where)
		body = d.get("body", null)
		head = d.get("head", null)
		if body == null or head == null:
			# 停靠位没建好（宿主骨架缺失）：退回弹窗，别让入口点了没反应
			_steps_dock_where = "popup"
			body = null
			head = null
	if _steps_dock_where == "popup":
		var shell: Dictionary = app._popup_body(
			"演出编辑：%s" % FunctionDecls.function_name(manifest, _steps_fn_id),
			"在列表中排序。切到时间轴可以试听、拖动步骤和调整时长。", true)
		_steps_pop = shell.pop
		var popup := _steps_pop
		popup.window_input.connect(func(event: InputEvent):
			if popup == _steps_pop and undo_shortcut(event, popup.gui_get_focus_owner()):
				popup.set_input_as_handled())
		if GamePreview.supports(manifest, TIMELINE_FRAME):
			FrameDialog.keep_on_focus_loss(_steps_pop)
		body = shell.body
	# 搬家会换 TimelineView 实例：版本缓存必须归零，否则新视图跳过 set_steps 显示空白
	_steps_tl_rev = -1
	_steps_list = Kit.vbox(4)
	_steps_tl_box = Kit.vbox(4)
	_steps_form = Kit.vbox(6)
	if head != null:
		_build_steps_head(head)
	else:
		_build_steps_popup_head(body)
	if _project_target:
		var select: OptionButton = host._form.reference_context_selector(_reference_context, func(key: String) -> bool:
			if not _steps_identity_ok() or not _flush_pending():
				return false
			_reference_context = key
			_rebuild_steps_all()
			return true)
		if select.item_count > 1:
			body.add_child(Kit.field_row("本图候选", select, 96))
		else:
			select.free()
	_build_steps_tabs(body)
	body.add_child(_steps_tl_box)
	var step_list_scroll := ScrollContainer.new()
	step_list_scroll.custom_minimum_size.y = 186
	step_list_scroll.follow_focus = true
	step_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_steps_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	step_list_scroll.add_child(_steps_list)
	body.add_child(step_list_scroll)
	body.add_child(Kit.divider())
	body.add_child(_steps_form)
	# 时间轴视图建一次、反复复用（set_steps 换数据源）；滚动容器兜住超宽/超高的排布
	_steps_tl = TimelineView.new()
	_steps_tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_steps_tl.set_steps([], _step_name_of)
	_steps_tl.picked.connect(func(idx: int): _steps_pick_tl(idx))
	# 视图按起手时的结构版本发请求：宿主据此丢弃过期拖拽（D1）
	_steps_tl.step_change_requested.connect(func(idx: int, revision: int, patch: Dictionary):
		_on_step_change_requested(idx, revision, patch))
	_audio_preview = AudioPreview.new()
	_steps_tl.add_child(_audio_preview)
	_audio_preview.position_changed.connect(_set_preview_position)
	_audio_preview.transport_changed.connect(_sync_transport_button)
	_steps_tl.playhead_changed.connect(func(v: float):
		_audio_preview.seek(v)
		_on_playhead_changed(v))
	var timeline := _steps_tl
	var transport := _audio_preview
	timeline.visibility_changed.connect(func():
		if is_instance_valid(transport) and not timeline.is_visible_in_tree():
			transport.stop())
	_steps_scroll = ScrollContainer.new()
	_steps_scroll.custom_minimum_size = Vector2(0, 120)
	_steps_scroll.add_child(_steps_tl)
	_steps_tl_box.add_child(_steps_scroll)
	if _steps_dock_where != "popup":
		var slot := _steps_dock.get_parent() as Control
		if slot != null:
			slot.visible = true
	else:
		var mounted := _steps_pop
		mounted.popup_hide.connect(func():
			# 主动拆卸或切画布选点时，调用方已处理提交与定位。
			if _steps_pop == mounted:
				if _steps_identity_ok() and not _flush_pending():
					app._set_status("关闭演出时未能保存当前步骤，请重开检查。")
				_steps_remember()
				_steps_pop = null
			_stop_audio_preview()
			_pending_commits.clear()
			if host._is_view_visible():
				_rebuild_right())
	_rebuild_steps_all()
	if not mem.is_empty():
		# 播放头随视图恢复：set_steps 会清拖拽但不动 playhead，这里显式回填后重画
		var ph := float(mem.get("playhead", 0.0))
		if _steps_tl != null and is_instance_valid(_steps_tl):
			_steps_tl.playhead = ph
			_steps_tl.queue_redraw()
		_on_playhead_changed(ph)
	if _steps_dock_where == "popup":
		app._open_popup(_steps_pop, Vector2i(642, 0))

## 弹窗形态的头部行：标题右侧挂「停靠下方」（搬进内容页底部，同一控制器）
func _build_steps_popup_head(body: VBoxContainer) -> void:
	var row := Kit.hbox(8)
	var dock_btn := Kit.button("停靠下方", func(): _dock_and_show("content"), "ghost")
	dock_btn.tooltip_text = "把演出面板停靠到内容页底部：表单和步骤同屏对照（步骤与播放头不变）"
	row.add_child(Kit.spacer())
	_add_history_buttons(row)
	row.add_child(dock_btn)
	row.add_child(Kit.button("关闭", func(): _steps_pop.hide(), "ghost"))
	body.add_child(row)

## 停靠形态的头部：标题 + 形态切换 + 收起（同一控制器，搬动不改数据）
## 三个去处常驻显示，当前所在项置灰——切换不重建头部，搬动只是换个父容器。
func _build_steps_head(head: HBoxContainer) -> void:
	head.add_child(Kit.section_header("演出编辑：%s" %
		FunctionDecls.function_name(manifest, _steps_fn_id)))
	head.add_child(Kit.spacer())
	_add_history_buttons(head)
	var cv_btn := Kit.button("停靠画布", func(): _dock_and_show("canvas"), "ghost")
	cv_btn.tooltip_text = "搬动画布下方并切到关卡视图：边看实例边对步骤（内容表单让位，数据不变）"
	cv_btn.add_theme_font_size_override("font_size", Th.FS_META)
	cv_btn.set_meta("where", "canvas")
	head.add_child(cv_btn)
	var ct_btn := Kit.button("停靠内容", func(): _dock_and_show("content"), "ghost")
	ct_btn.tooltip_text = "搬回内容页底部并切到内容视图（步骤与播放头不变）"
	ct_btn.add_theme_font_size_override("font_size", Th.FS_META)
	ct_btn.set_meta("where", "content")
	head.add_child(ct_btn)
	var pop_btn := Kit.button("独立展开", func(): _steps_set_dock_where("popup"), "ghost")
	pop_btn.tooltip_text = "把演出面板搬回独立窗口（步骤与播放头不变）"
	pop_btn.add_theme_font_size_override("font_size", Th.FS_META)
	head.add_child(pop_btn)
	head.add_child(Kit.button("收起", func(): _steps_close_dock(), "ghost"))
	_sync_steps_head()

func _add_history_buttons(row: HBoxContainer) -> void:
	row.add_child(Kit.button("撤销", func(): _restore_edit(false), "ghost"))
	row.add_child(Kit.button("重做", func(): _restore_edit(true), "ghost"))

## 当前所在项置灰（停靠形态下头部不重建，只同步可用态）
func _sync_steps_head() -> void:
	if _steps_dock == null or not is_instance_valid(_steps_dock):
		return
	var h: Variant = _steps_dock.get_meta("_head", null)
	if not (h is HBoxContainer) or not is_instance_valid(h):
		return
	for c in (h as HBoxContainer).get_children():
		var b := c as Button
		if b != null and b.has_meta("where"):
			b.disabled = str(b.get_meta("where", "")) == _steps_dock_where

## 停靠位：内容页底部 / 画布下方（两处都由宿主骨架预建）
func _dock_slot_for(where: String) -> PanelContainer:
	if where == "content":
		return host.steps_dock_slot
	if where == "canvas":
		return app._canvas_dock_slot
	return null

## 停靠 ↔ 停靠：只把容器搬到另一个槽（控件、滚动位置、焦点、播放头原样保留）。
## 目标槽不可用（宿主没建）时留在原处，形态标记也跟着回退——不留「说是画布、其实在内容」。
func _attach_dock_to_slot() -> void:
	var slot := _dock_slot_for(_steps_dock_where)
	if _steps_dock == null or not is_instance_valid(_steps_dock):
		return
	if slot == null:
		# 目标槽不可用（宿主没建）：形态标记回退到容器当前所在的槽
		var cur := _steps_dock.get_parent() as Control
		_steps_dock_where = "canvas" if cur == app._canvas_dock_slot else "content"
		return
	var old := _steps_dock.get_parent() as Control
	if old != null and old != slot:
		old.visible = false
		old.remove_child(_steps_dock)
		slot.add_child(_steps_dock)
	slot.visible = true
	_sync_steps_head()

## 形态切换：记下当前输入与播放头 → 换宿主 → 复原（索引/版本保持一致）
func _steps_set_dock_where(where: String) -> void:
	if where != "popup" and where != "content" and where != "canvas":
		return
	if _steps_dock_where == where:
		return
	if not host.commit_fields():
		return
	_steps_remember()
	if where != "popup" and _steps_dock_where != "popup" \
			and _steps_dock != null and is_instance_valid(_steps_dock):
		# 停靠之间互搬：不拆控件，直接换槽（保住滚动位置与正在编辑的焦点）
		_steps_dock_where = where
		_attach_dock_to_slot()
		return
	var mem := {
		"sel": _steps_sel, "view": _steps_view,
		"playhead": float(_steps_tl.playhead) if _steps_tl != null and is_instance_valid(_steps_tl) else 0.0,
	}
	_teardown_steps_host()
	_steps_dock_where = where
	_steps_mount(mem)

## 停靠形态跟着当前视图走：切到关卡就停在画布下方，切回内容就停在三列下方。
## 搬动同样先记输入与播放头，新宿主复原后步骤索引与版本保持一致；弹窗形态不动。
## 收起后（_steps_list 为空）也不动，否则会把空面板重新亮出来。
func sync_dock_to_view(view: String) -> void:
	if _steps_dock_where == "popup":
		return
	# 只跟关卡/内容两个视图走；资产视图没有停靠位，保持现状（内容页隐藏时自然不可见）
	if view != "map" and view != "content":
		return
	if _steps_dock == null or not is_instance_valid(_steps_dock):
		return
	if _steps_list == null or not is_instance_valid(_steps_list):
		return
	var where := "canvas" if view == "map" else "content"
	if where == _steps_dock_where:
		return
	_steps_set_dock_where(where)

## 头部入口：切到目标停靠位并让对应视图上屏（否则控件搬进了看不见的容器）。
## 已经在目标视图上就不重复切——_set_mode 会重建内容表单，白丢展开项与输入焦点。
func _dock_and_show(where: String) -> void:
	_steps_set_dock_where(where)
	if where == "canvas":
		if app._map_view == null or not app._map_view.visible:
			app._set_mode("map")
	elif where == "content":
		var sh = app.project_shell
		if sh == null or not sh.visible or str(sh._view) != "content":
			app._set_mode("content")

## 拆掉当前宿主里的内容（控件归宿主所有；控制器状态不动）
func _teardown_steps_host() -> void:
	_stop_audio_preview()
	_audio_preview = null
	_audio_button = null
	_pending_commits.clear()
	if _steps_pop != null and is_instance_valid(_steps_pop):
		var old_pop: PopupPanel = _steps_pop
		_steps_pop = null
		old_pop.hide()   # popup_hide → queue_free（_open_popup 挂的）
	if _steps_dock != null and is_instance_valid(_steps_dock):
		var slot := _steps_dock.get_parent() as Control
		if slot != null:
			slot.visible = false
		var b: Variant = _steps_dock.get_meta("_body", null)
		if b is VBoxContainer and is_instance_valid(b):
			for c in (b as VBoxContainer).get_children():
				(b as VBoxContainer).remove_child(c)
				c.queue_free()
			var h: Variant = _steps_dock.get_meta("_head", null)
			if h is HBoxContainer and is_instance_valid(h):
				for c2 in (h as HBoxContainer).get_children():
					(h as HBoxContainer).remove_child(c2)
					c2.queue_free()
	_steps_list = null
	_steps_tl_box = null
	_steps_form = null
	_steps_tabs = null
	_steps_tl = null
	_steps_scroll = null

## 收起停靠面板（相当于关弹窗：先记定位）。形态记忆保留——下次「编辑演出」仍停靠。
## 只有内容页在屏上才重建右栏（刷新「演出步骤」摘要）；在画布上收起不该动表单。
func _steps_close_dock() -> void:
	if not host.commit_fields():
		return
	_steps_remember()
	_teardown_steps_host()
	if host._is_view_visible():
		_rebuild_right()

## 宿主重建右栏后调用：停靠面板挂在内容页底部，身份失效就得一起收掉——
## 换实例/换绑定后脚下还摊着上一份演出，会让人把值填进另一条内容。
## 形态记忆（_steps_dock_where）不动：下次打开同一份内容仍回到原停靠位。
func revalidate_dock() -> void:
	if _steps_dock_where == "popup" or _steps_list == null:
		return
	if _steps_identity_ok():
		return
	_steps_remember()
	_teardown_steps_host()
	app._set_status("演出面板已收起：当前选中/绑定已不是它编辑的那份内容")

## 惰性建停靠容器：挂进内容页 / 画布底部预留的停靠位（让出高度，不覆盖表单）。
func _ensure_dock(where: String) -> Dictionary:
	var slot: PanelContainer = host.steps_dock_slot if where == "content" else app._canvas_dock_slot
	if slot == null:
		return {}
	# 停靠位有主：若已有容器却是给另一处建的，先拆掉（同一时刻只存在一个停靠容器）
	if _steps_dock != null and is_instance_valid(_steps_dock) and _steps_dock.get_parent() != slot:
		var old_slot := _steps_dock.get_parent() as Control
		if old_slot != null:
			old_slot.visible = false   # 别留一条空的面板横在旧位置
		_steps_dock.queue_free()
		_steps_dock = null
	if _steps_dock != null and is_instance_valid(_steps_dock):
		return {"body": _steps_dock.get_meta("_body", null), "head": _steps_dock.get_meta("_head", null)}
	var outer := PanelContainer.new()
	var sb := Th.box(Th.BG_PANEL, Th.BORDER, 0, 10, 8)
	sb.set_border_width_all(0)
	sb.border_width_top = 1
	outer.add_theme_stylebox_override("panel", sb)
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.mouse_filter = Control.MOUSE_FILTER_STOP
	outer.focus_mode = Control.FOCUS_CLICK
	var col := Kit.vbox(6)
	outer.add_child(col)
	var head := Kit.hbox(8)
	col.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var body := Kit.vbox(6)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	col.add_child(scroll)
	slot.add_child(outer)
	outer.set_meta("_body", body)
	outer.set_meta("_head", head)
	_steps_dock = outer
	return {"body": body, "head": head}

## E1：把子面板的定位写进会话记忆（按功能码 + 内容 ID 分桶）。
## 空绑定（还没内容 ID）也记：首次改动预留 ID 后同一会话内再开还是同一处。
func _steps_remember() -> void:
	if _steps_i < 0:
		return
	var cid := _steps_cid
	if cid == "":
		# 空绑定：本次会话里可能已被 _steps_write 预留 ID
		var fns := _current_fns()
		if _steps_i >= 0 and _steps_i < fns.size() and fns[_steps_i] is Dictionary:
			cid = str((fns[_steps_i] as Dictionary).get("content", ""))
	var ph: float = _steps_tl.playhead if _steps_tl != null and is_instance_valid(_steps_tl) else 0.0
	_steps_mem[_mem_key(FunctionDecls.fn_code(manifest, _steps_fn_id), cid)] = {
		"sel": _steps_sel, "view": _steps_view, "playhead": ph,
		"step": _steps_step_code_at(_steps_sel),
	}

## 某下标的步骤码（恢复时用来认「还是同一步」；越界/无选中返回空串）
func _steps_step_code_at(si: int) -> String:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size() or not (arr[si] is Dictionary):
		return ""
	return str((arr[si] as Dictionary).get("step", ""))

## 页签：列表 / 时间轴。同一份数据，两种呈现。
func _build_steps_tabs(parent: Control) -> void:
	_steps_tabs = Kit.hbox(6)
	var grp := ButtonGroup.new()
	for pair in [["列表", "list"], ["时间轴", "timeline"]]:
		var b := Kit.button(str(pair[0]), func(): _set_steps_view(str(pair[1])), "toggle")
		b.button_group = grp
		b.set_meta("view", str(pair[1]))
		_steps_tabs.add_child(b)
	if GamePreview.supports(manifest, TIMELINE_FRAME):
		var render := Kit.button("游戏演出画面…", _open_game_frame, "ghost")
		render.name = "TimelineGamePreview"
		render.tooltip_text = "从播放头开始取样，可以直接输入其他时刻；使用已应用的步骤和当前暂存内容。"
		_steps_tabs.add_child(render)
	parent.add_child(_steps_tabs)

func _open_game_frame() -> void:
	if not _steps_identity_ok() or not is_instance_valid(_steps_tl):
		return
	_stop_audio_preview()
	var timeline := _steps_tl
	var same_doc: Callable = app._map_file_ctrl.document_guard(false)
	var valid := func() -> bool:
		return is_instance_valid(timeline) and is_same(_steps_tl, timeline) \
			and _steps_identity_ok() and same_doc.call()
	var capture := func(preset: String, input: String) -> Dictionary:
		var value := input.strip_edges()
		if not value.is_valid_float():
			return {"error": "请输入有效的非负取样位置。"}
		var raw := value.to_float()
		if not is_finite(raw) or raw < 0.0:
			return {"error": "请输入有效的非负取样位置。"}
		# Read without updating the form's optimistic write baseline.
		var data: Dictionary = host.read_content_staged(_steps_fn_id, _steps_cid) if _steps_cid != "" else _steps_data()
		if data.is_empty():
			return {"error": "演出内容无法读取。"}
		var r := TimelineClock.from_decl(manifest, _steps_fn_id, data)
		var clock := TimelineClock.new(r.get("timebase", "seconds"), r.get("cfg", {}))
		var subject := {"function": _steps_fn_id, "content": _steps_cid, "data": data, "time": clock.sample(raw),
			"manifest": EditorManifest.public_data(manifest), "viewportId": preset}
		var context := {}
		if not _project_target:
			context = MapGamePreview.map_context(app) if app.map_loaded else {}
			if context.is_empty():
				return {"error": "地图正在重建，请稍后重试。"}
			subject.merge(context)
			subject["instance"] = _steps_ent
			subject["bindingId"] = str(_steps_binding.get("bindingId", ""))
			subject["bindingIndex"] = _steps_i
		var unchanged: Callable = app._map_file_ctrl.document_guard()
		var matches := func() -> bool:
			return unchanged.call() \
				and (context.is_empty() or MapGamePreview.context_matches(app, context)) \
				and (_steps_cid == "" or host.read_content_staged(_steps_fn_id, _steps_cid) == data)
		return {"subject": subject, "default_size": Vector2(1280, 720), "current": matches,
			"summary": " · %s %s" % [value, clock.timebase]}
	FrameDialog.open(app, TIMELINE_FRAME, {"title": "游戏演出画面预览", "button": "渲染取样",
		"hint": "用已应用的演出内容和本图暂存数据，由游戏渲染选定时刻。",
		"prefix": "TimelineGamePreview", "default_label": "默认 1280 × 720",
		"sample": {"unit": _steps_timebase(), "value": timeline.playhead},
		"initial": "起始位置来自播放头；在此修改取样位置不会移动播放头。"}, capture, valid)

func _set_steps_view(mode: String) -> bool:
	if mode != "list" and mode != "timeline":
		return false
	# 切页签前先提交当前控件（D1）：待提交值属于旧下标，切完再落到新表单上会串步
	if not host.commit_fields():
		return false
	_steps_view = mode
	_rebuild_steps_all()
	if mode == "timeline" and _steps_sel >= 0:
		_steps_tl.reveal_step.call_deferred(_steps_sel)
	return true

func _sync_steps_tabs() -> void:
	if _steps_tabs == null:
		return
	for c in _steps_tabs.get_children():
		var b := c as Button
		if b != null and b.has_meta("view"):
			b.button_pressed = str(b.get_meta("view", "")) == _steps_view

## 时间轴名称回调：未知码原样返回（视图据此画 ⚠）。
func _step_name_of(sc: String) -> String:
	var d: Dictionary = StepDecls.step_by_code(manifest, sc)
	return str(d.get("name", sc)) if not d.is_empty() else sc

## 功能声明 timebase（R-10 帧级时间轴）：seconds（缺省）/ frames / beats
func _steps_timebase() -> String:
	var fns: Dictionary = FunctionDecls.functions(manifest)
	var d = fns.get(_steps_fn_id, null)
	if not (d is Dictionary):
		return "seconds"
	var unit := str(d.get("timebase", "seconds"))
	return unit if unit in ["frames", "beats"] else "seconds"

## 时间轴点选：只换选中与表单，不重建视图（拖拽进行中 picked 会被发多次）。
func _steps_pick_tl(idx: int) -> void:
	# 换选中前提交旧步骤的待提交控件值（同 _steps_pick）
	if not host.commit_fields() or not _flush_pending():
		if is_instance_valid(_steps_tl):
			_steps_tl.reject_pick(_steps_sel)
		return
	_steps_sel = idx
	_reveal_step_page()
	if _steps_tl != null and is_instance_valid(_steps_tl):
		_steps_tl.sel = idx
		_steps_tl.queue_redraw()
	_rebuild_steps_list(_steps_data().get("steps", []))
	_rebuild_steps_form_from_data()

## 绑定身份须同时匹配地图、实例和行；同一下标可能属于别的实例。
func _steps_identity_ok() -> bool:
	if _project_target:
		return is_same(_project_manifest, app.manifest) and _steps_cid != ""
	if _steps_map != "" and _steps_map != app._map_file_ctrl.document_key():
		return false   # R23：切图后旧面板令牌失效（同码实例/同类空绑定也判失效）
	if _steps_ent != "" and str(host._selected_ent) != _steps_ent:
		return false
	var fns := _current_fns()
	if _steps_i < 0 or _steps_i >= fns.size() or not (fns[_steps_i] is Dictionary):
		return false
	var f: Dictionary = fns[_steps_i]
	if str(_resolve_fn(f).get("id", "")) != _steps_fn_id:
		return false
	return is_same(f, _steps_binding) and str(f.get("content", "")) == _steps_cid

## 工作副本读取：已绑定内容读磁盘/暂存；空绑定返回内存空壳（不落盘、不建 ID）。
func _steps_data() -> Dictionary:
	return _steps_read().data

func _steps_read() -> Dictionary:
	if not _steps_identity_ok():
		return {"data": {}, "digest": ""}
	if _steps_cid == "":
		return {"digest": "", "data": {"id": "", "function": FunctionDecls.fn_code(manifest, _steps_fn_id),
			"name": _steps_fn_id, "fields": {}, "steps": []}}
	var result: Dictionary = host.read_content_staged_ex(_steps_fn_id, _steps_cid)
	_project_scope = _project_target or result.data.get("scope") == "project"
	return result

func _steps_edit() -> Dictionary:
	var source := _steps_read()
	source["before"] = source.data
	source["data"] = source.data.duplicate(true)
	return source


func has_dock_focus(focus: Control) -> bool:
	return is_instance_valid(_steps_dock) and _steps_dock.is_visible_in_tree() and focus != null \
		and (focus == _steps_dock or _steps_dock.is_ancestor_of(focus))

func undo_shortcut(event: InputEvent, focus: Control) -> bool:
	if not event is InputEventKey or not event.pressed or event.echo or not event.ctrl_pressed \
			or event.keycode not in [KEY_Z, KEY_Y] or focus is LineEdit or focus is TextEdit:
		return false
	_restore_edit(event.keycode == KEY_Y or event.shift_pressed)
	return true

func _restore_edit(forward: bool) -> void:
	if _steps_cid == "" or not _steps_identity_ok() or not _flush_pending():
		return
	match app.canvas._undo_history_ctrl.undo_content_only(forward, _steps_fn_id, _steps_cid):
		"done":
			app._set_status(" 已重做演出改动" if forward else " 已撤销演出改动")
		"refused":
			app._set_status(" 内容文件已被外部修改：未恢复")
		_:
			app._set_status(" 没有可重做的演出改动" if forward else " 没有可撤销的演出改动")

func refresh_after_restore(fn_id: String, cid: String) -> void:
	if fn_id == _steps_fn_id and cid == _steps_cid and _steps_identity_ok() \
			and (is_instance_valid(_steps_pop) or is_instance_valid(_steps_dock)):
		_pending_commits.clear()
		_reload_steps()

## 首次实际改动才预留内容 ID；已落盘的改动进入内容撤销栈。
func _steps_write(edit: Dictionary) -> bool:
	if not _steps_identity_ok():
		return false
	var data: Dictionary = edit.data
	var before: Dictionary = edit.before if _steps_cid != "" else {}
	if _steps_cid == "":
		var cid := _ensure_content(_steps_i)
		if cid == "":
			_ensure_failed()
			return false
		_steps_cid = cid
		_steps_binding = _current_fns()[_steps_i]
		if str(data.get("id", "")) == "":
			data["id"] = cid
	var digest: String = edit.digest
	var result: String = host.write_content_staged(_steps_fn_id, _steps_cid, data, digest, before)
	if result != "ok":
		if result == "conflict":
			host._form._content_conflict(_steps_cid)
		elif result != "invalid":
			_ensure_failed()
		return false
	host._form._record_content_delta(_steps_fn_id, _steps_cid, before, data, digest)
	return true

## 结构版本递增：增删/排序/复制后旧控件与旧拖拽请求一律失效（D1）。
func _bump_steps_rev() -> void:
	_steps_rev += 1
	_steps_tl_rev = -1

## 重建子面板：页签同步 + 列表/时间轴互斥重建 + 当前步骤表单。
func _rebuild_steps_all() -> void:
	if _steps_list == null or _steps_form == null:
		return
	_sync_steps_tabs()
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	# E1：恢复的记忆下标可能超出当前步数（步骤被删过）——按当前数据收敛，不留悬空选中。
	# 下标还在但已指向另一条步骤（期间增删/换序）时也清掉选中：记的是「那一步」，不是「那个号」。
	_steps_sel = SessionContext.step_index(_steps_sel, arr.size())
	if _steps_sel_expect != "":
		var now_code := ""
		if _steps_sel >= 0 and _steps_sel < arr.size() and arr[_steps_sel] is Dictionary:
			now_code = str((arr[_steps_sel] as Dictionary).get("step", ""))
		if now_code != _steps_sel_expect:
			_steps_sel = -1
		_steps_sel_expect = ""
	_sync_steps_clock(data)
	if _steps_view == "timeline":
		_steps_list.visible = true
		_steps_tl_box.visible = true
		_rebuild_steps_tl(arr)
		_rebuild_steps_list(arr)
	else:
		_steps_tl_box.visible = false
		_steps_list.visible = true
		_rebuild_steps_list(arr)
	_rebuild_steps_form(arr)

## 列表分页仅限制创建的控件，步骤序号、复制范围和写入均对应完整数组。
var _steps_list_snapshot: Array = []
var _step_times: Array = []
var _steps_binding: Dictionary = {}
var _copied_segment: Array = []
var _segment_scope: Array = []

func _rebuild_steps_list(arr: Array) -> void:
	if _steps_list == null:
		return
	_steps_list_snapshot = arr.duplicate(true)
	_step_times = StepTimeline.to_timeline(arr)
	for c in _steps_list.get_children():
		_steps_list.remove_child(c)
		c.queue_free()
	var actions := Kit.hbox(6)
	_steps_list.add_child(actions)
	var copy := Kit.button("复制段落…", _copy_segment, "ghost")
	copy.disabled = arr.is_empty()
	actions.add_child(copy)
	var paste := Kit.button("粘贴段落…", _paste_segment, "ghost")
	paste.disabled = _copied_segment.is_empty() or _segment_scope != _current_segment_scope()
	paste.tooltip_text = "追加已复制的步骤；可在同项目、同功能及同地图作用域内复用"
	actions.add_child(paste)
	var shift := Kit.button("调整一段的时间…", _retime_segment, "ghost")
	shift.disabled = arr.is_empty()
	actions.add_child(shift)
	if arr.is_empty():
		_steps_list.add_child(Kit.hint_label("（空演出：添加步骤开始排）", 320))
	var last_page := maxi(0, ceili(float(arr.size()) / STEPS_PAGE_SIZE) - 1)
	_steps_page = mini(_steps_page, last_page)
	var first := _steps_page * STEPS_PAGE_SIZE
	var end := mini(first + STEPS_PAGE_SIZE, arr.size())
	if last_page > 0:
		var nav := Kit.hbox(6)
		_steps_list.add_child(nav)
		var prev := Kit.button("上一页", _go_to_step_page.bind(_steps_page - 1), "ghost")
		prev.disabled = _steps_page == 0
		nav.add_child(prev)
		var next := Kit.button("下一页", _go_to_step_page.bind(_steps_page + 1), "ghost")
		next.disabled = _steps_page == last_page
		nav.add_child(next)
		nav.add_child(Kit.text_label("%d–%d / %d" % [first + 1, end, arr.size()], Th.TEXT_DIM, Th.FS_SMALL))
		var jump := _segment_range_input(arr.size(), first + 1)
		jump.tooltip_text = "输入完整列表中的步骤序号"
		nav.add_child(jump)
		nav.add_child(Kit.button("定位步骤", func():
			jump.apply()
			_steps_pick(int(jump.value) - 1), "ghost"))
	for si in range(first, end):
		var st = arr[si]
		if not (st is Dictionary):
			continue
		_steps_list.add_child(_steps_row(si, st))

func _go_to_step_page(page: int) -> void:
	if _flush_pending():
		_steps_page = page
		_rebuild_steps_list(_steps_data().get("steps", []))

func _reveal_step_page() -> void:
	_steps_page = floori(float(maxi(0, _steps_sel)) / STEPS_PAGE_SIZE)

func _current_segment_scope() -> Array:
	return [str(manifest.get("_dir", "")), _steps_fn_id, "" if _project_scope else _steps_map]

func _segment_dialog(title: String, label: String, body: Control, accept: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.ok_button_text = label
	dialog.cancel_button_text = "取消"
	dialog.min_size = Vector2i(380, 0)
	dialog.add_child(body)
	_steps_list.add_child(dialog)
	dialog.confirmed.connect(accept)
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free())
	dialog.popup_centered()

func _segment_range_input(count: int, initial: int) -> SpinBox:
	var input := SpinBox.new()
	input.min_value = 1
	input.max_value = count
	input.step = 1
	input.value = initial
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return input

func _copy_segment() -> void:
	if not _flush_pending():
		return
	var arr: Array = _steps_data().get("steps", [])
	if arr.is_empty():
		return
	var start := _segment_range_input(arr.size(), maxi(1, _steps_sel + 1))
	var end := _segment_range_input(arr.size(), arr.size())
	var body := Kit.vbox(6)
	body.add_child(Kit.field_row("首步序号", start, 96))
	body.add_child(Kit.field_row("末步序号", end, 96))
	_segment_dialog("复制演出段落", "复制段落", body, func():
		start.apply()
		end.apply()
		var first := int(minf(start.value, end.value)) - 1
		var last := int(maxf(start.value, end.value)) - 1
		_copied_segment = StepTimeline.copy_range(arr, first, last)
		_segment_scope = _current_segment_scope()
		app._set_status("已复制 %d 个步骤" % _copied_segment.size())
		_rebuild_steps_list(arr))

func _retime_segment() -> void:
	if not _flush_pending():
		return
	var steps: Array = _steps_data().get("steps", [])
	if steps.is_empty():
		return
	var rev := _steps_rev
	var first := _segment_range_input(steps.size(), maxi(1, _steps_sel + 1))
	var last := _segment_range_input(steps.size(), steps.size())
	var shift := LineEdit.new()
	shift.text = "0"
	var spacing := LineEdit.new()
	spacing.placeholder_text = "留空保留现有间隔"
	var body := Kit.vbox(8)
	body.add_child(Kit.field_row("首步序号", first, 92))
	body.add_child(Kit.field_row("末步序号", last, 92))
	body.add_child(Kit.field_row("偏移量", shift, 92))
	body.add_child(Kit.field_row("固定间隔", spacing, 92))
	body.add_child(Kit.hint_label("单位：%s。范围外步骤保留原生效时间。" % _steps_timebase(), 340))
	_segment_dialog("调整演出段落", "应用时间", body, func():
		var edit := _steps_edit()
		if rev != _steps_rev or edit.data.get("steps", []) != steps:
			return
		first.apply()
		last.apply()
		var delta := _read_time(shift.text)
		var span := _read_time(spacing.text) if spacing.text.strip_edges() != "" else -1.0
		if not is_finite(delta) or not is_finite(span) or (spacing.text.strip_edges() != "" and span < 0):
			app._set_status("输入有效偏移和非负间隔。")
			return
		var begin := int(minf(first.value, last.value)) - 1
		var end := int(maxf(first.value, last.value)) - 1
		var timeline := StepTimeline.to_timeline(steps)
		var origin: float = timeline[begin].get("at", 0.0)
		var result := steps.duplicate(true)
		for i in result.size():
			if timeline[i].is_empty():
				continue
			var time: float = timeline[i].at
			if i in range(begin, end + 1):
				time = (time if span < 0 else origin + (i - begin) * span) + delta
			if time < 0 or not is_finite(time):
				app._set_status("调整后有步骤早于零点或超出范围。")
				return
			result[i]["at"] = time
		edit.data["steps"] = result
		if _steps_write(edit):
			_steps_sel = begin
			_bump_steps_rev()
			_rebuild_steps_all()
			app._set_status("已调整第 %d–%d 步" % [begin + 1, end + 1]))

func _paste_segment() -> void:
	if not _flush_pending():
		return
	var data := _steps_data()
	if data.is_empty() or _segment_scope != _current_segment_scope():
		return
	var arr: Array = data.get("steps", [])
	var revision := _steps_rev
	var default_time := StepTimeline.end_time(arr)
	var start := LineEdit.new()
	start.text = str(default_time)
	start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var body := Kit.vbox(6)
	body.add_child(Kit.hint_label("将 %d 个步骤追加到列表，保留段落内的相对时间。" % _copied_segment.size(), 340))
	body.add_child(Kit.field_row("起点 / " + _steps_timebase(), start, 126))
	_segment_dialog("粘贴演出段落", "粘贴段落", body, func():
		var value := _read_time(start.text.strip_edges())
		if not is_finite(value) or value < 0.0:
			app._set_status("段落起点必须是非负时间数值")
			return
		_run_row_command(revision, arr, _append_segment.bind(value)))

func _append_segment(origin: float) -> void:
	var edit := _steps_edit()
	var data: Dictionary = edit.data
	var arr: Array = data.get("steps", [])
	var first := arr.size()
	arr.append_array(StepTimeline.offset_segment(_copied_segment, origin))
	data["steps"] = arr
	if _steps_write(edit):
		_steps_sel = first
		_reveal_step_page()
		_bump_steps_rev()
		_rebuild_steps_all()

## D2：按 timePreview 声明建换算时钟，并把参考素材（帧序列 / 音频）解析成界面可用的值。
## 缺项只记录在 _steps_clock_missing 里（表单显示），不阻断原单位编辑。
func _sync_steps_clock(data: Dictionary) -> void:
	if data.is_empty():
		# 数据源已失效（绑定换了）：不拿空内容解析缺项，免得报假警告
		_steps_clock = null
		_steps_clock_missing = []
		_steps_preview_asset = ""
		_steps_preview_frames = []
		_steps_audio = {}
		_stop_audio_preview()
		if is_instance_valid(_steps_tl):
			_steps_tl.set_reference_audio(0.0, PackedVector2Array())
		return
	var r: Dictionary = TimelineClock.from_decl(manifest, _steps_fn_id, data)
	_steps_clock = TimelineClock.new(str(r.get("timebase", "seconds")), r.get("cfg", {}))
	_steps_clock_missing = r.get("missing", [])
	var refs: Dictionary = r.get("refs", {})
	var fields: Dictionary = data.get("fields", {}) if data.get("fields", null) is Dictionary else {}
	# 参考帧序列：资产码 → 声明 frames[]（相对路径）；只在帧基下用得到
	_steps_preview_asset = str(fields.get(str(refs.get("frameAssetField", "")), ""))
	_steps_preview_frames = []
	if _steps_preview_asset != "":
		var ad: Dictionary = AssetDecl.by_id(manifest, _steps_preview_asset)
		var fr = ad.get("frames", null)
		if fr is Array:
			_steps_preview_frames = fr
	var audio_value := str(fields.get(str(refs.get("audioField", "")), ""))
	_steps_audio = AudioDecls.by_code(manifest, audio_value)
	if audio_value != "" and _steps_audio.is_empty():
		_steps_clock_missing.append("音频码无法解析：%s" % audio_value)
	if is_instance_valid(_steps_tl):
		_steps_tl.set_clock(_steps_clock)
		if not _steps_audio.is_empty():
			_audio_preview.configure(str(manifest.get("_dir", "")), _steps_audio, _steps_clock)
			if _audio_preview.is_available():
				_steps_tl.set_reference_audio(_audio_preview.length, _audio_preview.waveform)
			else:
				_steps_tl.set_reference_audio(0.0, PackedVector2Array())
		else:
			_stop_audio_preview()
			_steps_tl.set_reference_audio(0.0, PackedVector2Array())

func _stop_audio_preview() -> void:
	if is_instance_valid(_audio_preview):
		_audio_preview.stop()

func _sync_transport_button() -> void:
	if is_instance_valid(_audio_button):
		_audio_button.text = "暂停试听" if is_instance_valid(_audio_preview) and _audio_preview.active else "试听"

func _set_preview_position(value: float) -> void:
	if not is_instance_valid(_steps_tl) or not _steps_identity_ok():
		_stop_audio_preview()
		return
	_steps_tl.playhead = value
	_steps_tl.queue_redraw()
	_steps_tl.follow_playhead()
	_on_playhead_changed(value)

func _toggle_audio_preview() -> void:
	if not _steps_identity_ok() or not is_instance_valid(_audio_preview):
		return
	if _audio_preview.active:
		_audio_preview.stop()
	elif not _audio_preview.play_from(_steps_tl.playhead):
		app._set_status("播放头已到音频末尾；请先回到起点或选一处拍点。")

func _rewind_audio_preview() -> void:
	_set_preview_position(0.0)
	_audio_preview.seek(0.0)

## 播放头移动：帧基下换算成整数帧号给表单预览；秒/拍基只显示时间换算。
## 只刷参考帧行与读数——整表重建会清掉用户正在输入的控件。
func _on_playhead_changed(v: float) -> void:
	_steps_preview_idx = int(floorf(v)) if _steps_clock != null and _steps_clock.timebase == "frames" else -1
	_fill_frame_preview()
	_fill_playhead_label(v)

## 播放头读数：原始单位 + 换算秒数。负秒（拍基首拍偏移前）标「音频起点前」。
func _fill_playhead_label(v: float) -> void:
	if _steps_playhead_label == null:
		return
	var tb: String = str(_steps_clock.timebase) if _steps_clock != null else "seconds"
	var unit: String = {"seconds": "s", "frames": "帧", "beats": "拍"}.get(tb, "s")
	var sec: float = float(_steps_clock.seconds_at(v)) if _steps_clock != null else v
	var tail := "（音频起点前，静音）" if sec < 0.0 else ""
	_steps_playhead_label.text = "播放头 %s %s → %.3f s%s" % [
		_num_text(v), unit, sec, tail]

## 时间轴视图：换数据源 + 选中态 + 滚动容器高度。
## 结构版本变了才 set_steps（换数据源并清拖拽）；版本没变只同步选中，不打断进行中的拖拽。
func _rebuild_steps_tl(arr: Array) -> void:
	if _steps_tl == null or not is_instance_valid(_steps_tl):
		return
	_steps_tl.set_timebase(_steps_timebase())
	if _steps_tl_rev != _steps_rev:
		_steps_tl.set_steps(arr, _step_name_of, _steps_rev)
		_steps_tl_rev = _steps_rev
	_steps_tl.sel = _steps_sel
	_steps_tl.sync_min_size()
	if _steps_scroll != null:
		_steps_scroll.custom_minimum_size = Vector2(0, minf(_steps_tl.fit_height() + 8.0, 220.0))

## 时间轴拖拽落定：**一次拖动 = 一次编辑**（D1）。补丁按步骤身份 + 结构版本校验后合并，
## 过期请求（期间增删/换序/换页签/换绑定）直接丢弃；合并只净化被编辑的键。
func _on_step_change_requested(idx: int, revision: int, patch: Dictionary) -> void:
	if revision != _steps_rev or not _steps_identity_ok():
		return   # 过期拖拽：结构已变，按下标写回会落到别的步骤上
	var edit := _steps_edit()
	var data: Dictionary = edit.data
	if data.is_empty():
		return
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if _steps_tl == null or arr != _steps_tl.steps:
		_bump_steps_rev()
		_rebuild_steps_all()
		return
	_write_time_patch(edit, arr, idx, patch, [])

## 表单重建（数据自取）：时间轴点选后只换表单、不动视图。
func _rebuild_steps_form_from_data() -> void:
	if _steps_form == null:
		return
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	_sync_steps_clock(data)   # fps/偏移等参考值可能刚在别处改过，读数跟着更新
	_rebuild_steps_form(arr)

## 子面板里的一个步骤行：序号+名称（选中高亮）+ 上移/下移/复制/删除。
func _steps_row(si: int, st: Dictionary) -> Control:
	var sc := str(st.get("step", ""))
	var decl: Dictionary = StepDecls.step_by_code(manifest, sc)
	var known := not decl.is_empty()
	var nm := str(decl.get("name", sc)) if known else "（未声明的步骤 %s）" % sc
	var sel := _steps_sel == si
	var row := Kit.hbox(4)
	var clock: Dictionary = _step_times[si] if si in range(_step_times.size()) else {}
	var summary := ""
	var values = st.get("fields", {})
	if values is Dictionary:
		for value in values.values():
			if value is String and value != "":
				summary = " · " + value.get_slice("\n", 0)
				break
	var mark := Kit.button("%s%d. %s · %s · 轨 %d%s" % [
		"▸ " if sel else "", si + 1, nm, _num_text(float(clock.get("at", 0.0))), int(clock.get("track", 0)) + 1, summary],
		func(): _steps_pick(si), "ghost")
	mark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mark.clip_text = true
	mark.alignment = HORIZONTAL_ALIGNMENT_LEFT
	mark.tooltip_text = mark.text
	row.add_child(mark)
	if not known:
		row.add_child(Kit.hint_label("⚠", 20))
	var revision := _steps_rev
	var displayed: Array = _steps_list_snapshot
	row.add_child(Kit.button("↑", func(): _run_row_command(revision, displayed, _steps_move.bind(si, -1)), "ghost"))
	row.add_child(Kit.button("↓", func(): _run_row_command(revision, displayed, _steps_move.bind(si, 1)), "ghost"))
	row.add_child(Kit.button("复制", func(): _run_row_command(revision, displayed, _steps_dup.bind(si)), "ghost"))
	row.add_child(Kit.del_button(func(): _run_row_command(revision, displayed, _steps_del.bind(si))))
	return row

func _run_row_command(revision: int, displayed: Array, command: Callable) -> void:
	if revision != _steps_rev or not _steps_identity_ok():
		return
	if not _flush_pending():
		return
	var data := _steps_data()
	if data.is_empty() or data.get("steps", []) != displayed:
		_bump_steps_rev()
		_rebuild_steps_all()
		return
	command.call()

## 点步骤名选中该步：右侧表单换到这一步（重建保持 _steps_sel 选中态）。
func _steps_pick(si: int) -> void:
	# 换选中前先提交当前表单控件：SpinBox 之类的待提交值属于旧步骤下标
	if not host.commit_fields() or not _flush_pending():
		if is_instance_valid(_steps_tl):
			_steps_tl.sel = _steps_sel
			_steps_tl.queue_redraw()
		return
	_steps_sel = si
	_reveal_step_page()
	_rebuild_steps_all()
	if _steps_view == "timeline":
		_steps_tl.reveal_step.call_deferred(si)

## 当前步骤表单：步骤类型选择 + 该步骤声明的字段 + 未声明键只读保留。
## 字段改动即时写盘，不重建表单（保持输入焦点，与主表单同一纪律）。
func _rebuild_steps_form(arr: Array) -> void:
	var box := _steps_form
	if box == null:
		return
	# 表单整片重建：待提交项绑定的是旧控件（旧步骤下标），重建后一律失效
	_pending_commits.clear()
	_steps_frame_holder = null   # 参考帧行随旧表单一起释放
	_steps_playhead_label = null
	_audio_button = null
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
		if _flush_pending():
			_steps_add(str(pick.get_item_metadata(pick.selected))))
	add_row.add_child(add_btn)
	var at_head := Kit.button("在播放头添加", func():
		if pick.selected >= 0 and _flush_pending():
			_steps_add(str(pick.get_item_metadata(pick.selected)), true))
	at_head.tooltip_text = "在当前播放头时间放置新步骤，保留原有步骤时间"
	add_row.add_child(at_head)
	var reload_btn := Kit.button("重读步骤", _reload_steps, "ghost")
	reload_btn.tooltip_text = "放弃尚未写入的步骤输入，重读当前内容"
	add_row.add_child(reload_btn)
	box.add_child(add_row)
	# 时间轴警告（负 at/duration、同轨重叠）：只提示不阻断
	var warnings := StepTimeline.warnings(arr)
	if not warnings.is_empty():
		var details := Kit.vbox(3)
		details.hide()
		box.add_child(Kit.button("时间提示（%d）…" % warnings.size(), func(): details.visible = not details.visible, "ghost"))
		for wtext in warnings:
			details.add_child(Kit.hint_label("⚠ " + str(wtext), 320))
		box.add_child(details)
	var shown := {"steps": arr.duplicate(true), "index": _steps_sel}
	# D2：参考时钟（缺项 / 小数帧待修 / 参考帧与音频）
	box.add_child(_steps_clock_box(arr, shown))
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
	# 时间与轨道（D1）：与时间轴同一份数据、同一补丁入口；缺 at 显示「随前序」
	var time_row := _steps_time_row(arr, shown)
	box.add_child(time_row.control)
	var sfields: Array = decl.get("fields", [])
	var sfd: Dictionary = st.get("fields", {}) if st.get("fields", {}) is Dictionary else {}
	for fd in sfields:
		if not (fd is Dictionary):
			continue
		box.add_child(_step_field_row(fd, sfd, sfields, shown))
	_pending_commits.append(time_row.track_commit)
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

## 字段写回使用展示时的步骤快照，拒绝过期回调。
func _step_field_row(fd: Dictionary, sfd: Dictionary, siblings: Array, shown: Dictionary) -> Control:
	var key := str(fd.get("code", ""))
	var val = sfd.get(key, fd.get("default", FieldWidgets.default_for(fd)))
	var label := str(fd.get("name", str(fd.get("id", ""))))
	var rev := _steps_rev
	# R13：配对地图字段的现值注入 _mapKey——步骤字段的实例引用与摆放物同一语义。
	var d := fd
	var paired := str(fd.get("mapField", "")) != "" and not siblings.is_empty()
	var tk := RefFields.paired_map_value(fd, siblings, sfd) if paired else ""
	if paired:
		if tk != "":
			d = fd.duplicate(true)
			d["_mapKey"] = tk
	var check_pair := func(values: Dictionary) -> bool:
		if paired and RefFields.paired_map_value(fd, siblings, values) != tk:
			app._set_status("配对地图已改，请重新打开步骤表单后选择引用")
			return false
		return true
	var apply := func(v) -> bool: return _set_step_field(shown, key, v, rev, check_pair)
	var frame_pick := func(nested_row: Control, nested: Dictionary, pair: Callable, save: Callable, read: Callable):
		FrameReference.add_reference_button(app, nested_row, nested, pair, save, _resolve_options, _project_scope,
			_rebuild_steps_form_from_data, _reference_context, read)
	var built := FieldWidgets.build(d, val, apply, _resolve_options, "code", frame_pick)
	if built.get("commit") is Callable and (built.commit as Callable).is_valid():
		_pending_commits.append(built.commit)
	var field_row := Kit.field_row(label, built.ctl, 96)
	field_row.set_meta("field_id", str(fd.get("id", "")))
	var tip := FieldWidgets.decl_tooltip(fd)
	if tip != "":
		field_row.tooltip_text = tip
	var pickable := FieldWidgets.wants_canvas_pick(fd) and (not _project_scope or tk != "")
	if pickable and not FieldWidgets.ordered_frame_pick(fd) and not bool(fd.get("multiple", false)) and host._form.can_pick_on_canvas(tk):
		var pick := Kit.button("画布选…", func(): _pick_step_ref(fd, apply), "ghost")
		pick.tooltip_text = "临时切到画布点一个实例；确认才写入这一步，取消不改当前值" \
			if not FieldWidgets.wants_edge_pick(fd) else "临时切到画布点一条格边；确认才写入这一步，取消不改当前值"
		if FieldWidgets.wants_cell_pick(fd):
			pick.tooltip_text = "临时切到画布点格图里的一格（按多边形命中）；确认才写入这一步，取消不改当前值"
		pick.add_theme_font_size_override("font_size", Th.FS_META)
		field_row.add_child(pick)
	if FieldWidgets.wants_frame_pick(fd) and FieldWidgets.frame_value_available(fd, built):
		var pair := func() -> Array[String]:
			var index: int = shown.index
			var steps: Array = shown.steps
			return RefFields.frame_scope(fd, siblings, steps[index].get("fields", {}))
		var save := func(value) -> bool:
			var expected: Array = pair.call()
			return _set_step_field(shown, key, value, rev,
				func(fields: Dictionary): return RefFields.frame_scope(fd, siblings, fields) == expected)
		FrameReference.add_reference_button(app, field_row, fd, pair, save, _resolve_options, _project_scope,
			_rebuild_steps_form_from_data, _reference_context, built.get("pick_values", Callable()))
	return field_row

## 画布选点和表单共用写回校验。
func _pick_step_ref(fd: Dictionary, apply: Callable) -> void:
	var fname := str(fd.get("name", str(fd.get("id", ""))))
	var mode := FieldWidgets.pick_mode(fd)
	var is_cell := mode == "cell"
	var is_edge := mode == "edge"
	var of := FieldWidgets.canvas_pick_types(fd)
	var hint := ("第 %d 步「%s」选一格（格图）" % [_steps_sel + 1, fname]) if is_cell \
		else (("第 %d 步「%s」选一条格边（靠近格边点）" % [_steps_sel + 1, fname]) if is_edge \
		else ("第 %d 步「%s」选目标实例" % [_steps_sel + 1, fname] + \
			("（限定类型：%s）" % ",".join(PackedStringArray(of)) if not of.is_empty() else "")))
	if mode == "port":
		hint = "第 %d 步「%s」选目标端口" % [_steps_sel + 1, fname]
	var on_ok := func(code: String):
		if code == "":
			return
		var value = FieldWidgets.decode_pick(mode, code)
		if value != null:
			apply.call(value)
		_reopen_after_pick()
	var on_cancel := func(_code: String):
		_reopen_after_pick()
	# 收起子面板前先冲刷连续控件（写回的是本步当前值；面板重建后旧控件失效）
	if not host.commit_fields():
		return
	# 弹窗形态：切到画布前先收起（否则弹窗悬在画布上），返回时按记忆重建。
	# hide() 会走 _open_popup 挂的 popup_hide → queue_free，不留隐形弹窗。
	# 停靠形态不需要收：选点开始时宿主会把面板整体搬到画布下方，回来再搬回原处。
	_steps_remember()
	var old := _steps_pop
	_steps_pop = null
	if old != null and is_instance_valid(old):
		old.hide()
	app._begin_canvas_pick("steps", mode, hint, on_ok, on_cancel, of)

## 选点归来：重开同一个绑定行的演出面板（步骤/视图/播放头由 _steps_mem 恢复）。
## 期间实例/绑定换了（身份校验失败）就不重开——对着另一条绑定弹出旧面板更糟。
## 停靠形态面板一直在屏上：只刷新数据，不拆宿主（保住滚动位置与焦点）。
func _reopen_after_pick() -> void:
	if _steps_i < 0 or not _steps_identity_ok():
		return
	if _steps_dock_where != "popup" and _steps_list != null and is_instance_valid(_steps_list):
		_rebuild_steps_all()
		return
	if _project_target:
		open_content(_steps_fn_id, _steps_cid)
	else:
		_open_steps_editor(_steps_i)

## 时间换算读数（D2）：非秒基下显示「= 起 .. 止 s」，秒基返回空串。
## 只做对齐参考；缺项（时钟不可用）时不显示，避免给出假秒数。
func _step_seconds_hint(eff: Dictionary) -> String:
	if _steps_clock == null or str(_steps_clock.timebase) == "seconds":
		return ""
	if not _steps_clock.is_ready():
		return ""
	var at := float(_steps_clock.seconds_at(float(eff.get("at", 0.0))))
	var end := float(_steps_clock.seconds_at(float(eff.get("at", 0.0)) + float(eff.get("duration", 0.0))))
	return "  = %ss → %ss" % [String.num(at, 3), String.num(end, 3)]

## 时间与轨道行（D1）：默认收起，展开后可输入起点 / 时长 / 轨号 / 阻塞。
## 起点留空 = 「随前序」（缺 at）；显式 0 = 从零开始。时长接受 0。
func _steps_time_row(arr: Array, tok: Dictionary) -> Dictionary:
	var si := int(tok.index)
	var box := Kit.vbox(2)
	var eff: Dictionary = StepTimeline.effective(arr, si)
	var st: Dictionary = arr[si] if si < len(arr) and arr[si] is Dictionary else {}
	var has_at := st.has("at")
	var body := Kit.vbox(2)
	body.visible = false
	var head := Kit.button("▸ 时间与轨道（%s 起，时长 %s，轨 %d）%s" % [
		_num_text(eff.get("at", 0.0)), _num_text(eff.get("duration", 0.0)),
		int(eff.get("track", 0)), _step_seconds_hint(eff)], Callable(), "ghost")
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.pressed.connect(func():
		body.visible = not body.visible
		head.text = ("▾" if body.visible else "▸") + head.text.substr(1))
	box.add_child(head)
	box.add_child(body)
	var row := Kit.hbox(6)
	# 起点
	var at_edit := LineEdit.new()
	at_edit.custom_minimum_size = Vector2(74, 0)
	at_edit.placeholder_text = "随前序"
	at_edit.text = _num_text(st.get("at", null)) if has_at else ""
	at_edit.tooltip_text = "留空 = 随前序（接着上一阻塞步骤结束）；填 0 = 从零开始"
	_bind_time_input(at_edit, tok, "at")
	row.add_child(Kit.text_label("起点", Th.TEXT_DIM, Th.FS_META))
	row.add_child(at_edit)
	# 时长
	var dur_edit := LineEdit.new()
	dur_edit.custom_minimum_size = Vector2(64, 0)
	dur_edit.text = _num_text(eff.get("duration", 0.0))
	dur_edit.tooltip_text = "持续时长；0 = 瞬发（不占时）"
	_bind_time_input(dur_edit, tok, "duration")
	row.add_child(Kit.text_label("时长", Th.TEXT_DIM, Th.FS_META))
	row.add_child(dur_edit)
	# 轨号
	var trk := SpinBox.new()
	trk.min_value = 0
	trk.max_value = 99
	trk.step = 1
	trk.value = int(eff.get("track", 0))
	trk.custom_minimum_size = Vector2(60, 0)
	trk.tooltip_text = "轨道号；同轨按起点排序，重叠只警告"
	var rev_trk := _steps_rev
	var initial_track := int(trk.value)
	var flush_track := FieldWidgets.spin_text_flush(trk)
	var track_commit := func() -> bool:
		if rev_trk != _steps_rev:
			return true
		flush_track.call()
		var track := int(trk.value)
		if track == initial_track:
			return true
		return _apply_time_patch(tok, {"track": track}, [])
	FieldWidgets.bind_spin_commit(trk, track_commit)
	row.add_child(Kit.text_label("轨", Th.TEXT_DIM, Th.FS_META))
	row.add_child(trk)
	# 阻塞
	var blk := CheckBox.new()
	blk.text = "阻塞"
	blk.button_pressed = bool(eff.get("blocking", true))
	blk.tooltip_text = "阻塞 = 后续步骤等这一步结束；关掉则同刻继续"
	var rev_blk := _steps_rev
	blk.toggled.connect(func(v: bool):
		if rev_blk == _steps_rev:
			_apply_time_patch(tok, {"blocking": v}, []))
	row.add_child(blk)
	var rev_new := _steps_rev
	var new_trk := Kit.button("移至新轨", func():
		if rev_new == _steps_rev:
			_apply_time_patch(tok, {"track": _next_track()}, []), "ghost")
	new_trk.tooltip_text = "轨号取当前最大值 + 1（新轨在时间轴底部）"
	row.add_child(new_trk)
	# 拍基：显式对齐到声明细分格（既有拍数精度不自动改，D2）
	if _steps_clock != null and str(_steps_clock.timebase) == "beats" and _steps_clock.is_ready():
		var grid := float(_steps_clock.snap_step())
		var rev_align := _steps_rev
		var align := Kit.button("对齐 1/%d 拍" % int(roundf(1.0 / grid)), func():
			if rev_align == _steps_rev:
				_quantize_step(tok, grid), "ghost")
		align.tooltip_text = "把这一步的 at/duration 对齐到声明的每拍格数"
		row.add_child(align)
	body.add_child(row)
	return {"control": box, "track_commit": track_commit}

## D2 参考时钟块：声明缺项提示、小数帧待修（含一键量化）、参考帧缩略与音频名。
## 只服务于「按秒对齐」，不做游戏判定；缺项时时间仍按原单位编辑。
func _steps_clock_box(arr: Array, shown: Dictionary) -> Control:
	var box := Kit.vbox(2)
	if _steps_clock == null:
		return box
	var tb := str(_steps_clock.timebase)
	var unit: String = {"seconds": "秒", "frames": "帧", "beats": "拍"}.get(tb, "秒")
	# 播放头读数：原始单位 → 秒（负秒 = 音频起点前，保持静音；这里只标注）
	_steps_playhead_label = Kit.text_label("", Th.TEXT_MUTE, Th.FS_META)
	var ph: float = _steps_tl.playhead if _steps_tl != null and is_instance_valid(_steps_tl) else 0.0
	_fill_playhead_label(ph)
	box.add_child(_steps_playhead_label)
	for m in _steps_clock_missing:
		box.add_child(Kit.hint_label("⚠ 参考参数缺项：%s（时间仍按%s编辑）" % [str(m), unit], 320))
	# 小数帧待修：已存值不求整，只标记；逐条提供显式量化（新输入由吸附取整）
	if tb == "frames":
		var frac: Array = TimelineClock.fractional_frames(arr)
		if not frac.is_empty():
			box.add_child(Kit.hint_label("⚠ %d 处小数帧待修（at/duration 应为整数帧）" % frac.size(), 320))
			for f in frac:
				var fi := int(f.index)
				var nm := _step_name_of(str((arr[fi] as Dictionary).get("step", ""))) \
					if fi >= 0 and fi < arr.size() and arr[fi] is Dictionary else ""
				var frow := Kit.hbox(6)
				var flabel := Kit.hint_label("  · 第 %d 步%s %s = %s 帧" % [
					fi + 1, ("（%s）" % nm) if nm != "" else "",
					str(f.key), _num_text(f.value)], 320)
				flabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				frow.add_child(flabel)
				var fix := Kit.button("取整", func(): _quantize_step({"steps": shown.steps, "index": fi}, 1.0), "ghost")
				fix.tooltip_text = "只把这一步的 at/duration 四舍五入到整帧"
				frow.add_child(fix)
				box.add_child(frow)
	# 拍基：既有拍数精度不动（底层保留），只有显式「对齐格」才量化选中步骤——
	# 见时间与轨道行里的对齐按钮，这里不逐条列「不在格上」免得老内容满屏提示
	# 参考帧预览（帧基专有）：播放头帧号取整，越界显式提示（从第 0 帧计数）
	if tb == "frames" and not _steps_preview_frames.is_empty():
		box.add_child(_steps_frame_preview())
	if not _steps_audio.is_empty() and is_instance_valid(_audio_preview):
		box.add_child(Kit.hint_label("♪ %s · 0 %s 对应 %.3f s" % [
			str(_steps_audio.get("name", "")), unit, _steps_clock.seconds_at(0.0)], 320))
		if _audio_preview.is_available() and _steps_view == "timeline":
			var transport := Kit.hbox(6)
			_audio_button = Kit.button("试听", _toggle_audio_preview)
			transport.add_child(_audio_button)
			_sync_transport_button()
			transport.add_child(Kit.button("回到起点", _rewind_audio_preview, "ghost"))
			if _steps_sel >= 0:
				var place := Kit.button("步骤移到播放头", func():
					var at := snappedf(_steps_tl.playhead, _steps_clock.snap_step())
					_apply_time_patch(shown, {"at": at}, []), "ghost")
				transport.add_child(place)
			box.add_child(transport)
		elif _audio_preview.error != "":
			box.add_child(Kit.hint_label(_audio_preview.error, 320))
	return box

## 参考帧预览：帧基下按播放头帧索引显示该资产声明的一帧；无播放头时显示第 0 帧。
## 播放头拖动期间只重建这一行（不动整张表单，免得清掉正在输入的焦点）。
func _steps_frame_preview() -> Control:
	_steps_frame_holder = Kit.hbox(6)
	_fill_frame_preview()
	return _steps_frame_holder

func _fill_frame_preview() -> void:
	if _steps_frame_holder == null:
		return
	for c in _steps_frame_holder.get_children():
		_steps_frame_holder.remove_child(c)
		c.queue_free()
	var n := _steps_preview_frames.size()
	if n <= 0:
		return
	var idx := _steps_preview_idx
	var label := "参考帧："
	if idx < 0:
		idx = 0
		label = "参考帧（第 0 帧）："
	elif idx >= n:
		_steps_frame_holder.add_child(Kit.hint_label("⚠ 播放头帧 %d 超出帧序列（0..%d）" % [idx, n - 1], 320))
		idx = n - 1
	_steps_frame_holder.add_child(Kit.text_label(label, Th.TEXT_DIM, Th.FS_META))
	var rel := str(_steps_preview_frames[idx])
	var tex: Texture2D = EntityNodeRef.texture_of(manifest, rel)
	if tex != null:
		var preview_texture := TextureRect.new()
		preview_texture.texture = tex
		preview_texture.custom_minimum_size = Vector2(48, 48)
		preview_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_steps_frame_holder.add_child(preview_texture)
	_steps_frame_holder.add_child(Kit.text_label("%d / %d  %s" % [idx, n - 1, rel], Th.TEXT_MUTE, Th.FS_META))

## 显式量化单步（D2：吸附只作用于新输入或显式量化选中项）：
## 只把该步 at/duration 按粒度四舍五入（帧 = 1 帧；拍 = 1/subdivisions），
## 经同一补丁入口写回，已有精度不被自动改写。tok = 步骤稳定令牌。
func _quantize_step(tok: Dictionary, grid: float) -> void:
	if grid <= 0.0 or tok.is_empty():
		return
	var data := _steps_data()
	if data.is_empty():
		return
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var si := _step_index_of(arr, tok)
	if si < 0 or not (arr[si] is Dictionary):
		return
	var step: Dictionary = arr[si]
	var patch := {}
	for key in ["at", "duration"]:
		if step.has(key):
			patch[key] = snappedf(maxf(float(step.get(key, 0.0)), 0.0), grid)
	if patch.is_empty():
		return
	_apply_time_patch(tok, patch, [])

## 新轨号 = 当前所有步骤的最大轨号 + 1。
func _next_track() -> int:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var mx := 0
	var tl := StepTimeline.to_timeline(arr)
	for e in tl:
		mx = maxi(mx, int((e as Dictionary).get("track", 0)))
	return mx + 1

static func _num_text(v) -> String:
	if v == null:
		return ""
	if v is int:
		return str(v)
	var f := float(v)
	if f == roundf(f):
		return str(int(f))
	# 四位小数去尾零，不用两位：两位会把 1.234 显示成 1.23，失焦回写就把真实值截断了（V4 P1）
	return ("%.4f" % f).rstrip("0").rstrip(".")

static func _read_time(text: String) -> float:
	if not text.is_valid_float():
		return NAN
	# Time inputs accept scientific notation, but oversized exponents warn inside Godot's float parser.
	var exponent := text.findn("e")
	if exponent >= 0 and absi(int(text.substr(exponent + 1))) > 308:
		return NAN
	return text.to_float()

func _bind_time_input(edit: LineEdit, tok: Dictionary, key: String) -> void:
	var rev := _steps_rev
	var initial := edit.text
	var commit := func(text: String):
		if rev != _steps_rev or text.strip_edges() == initial:
			return
		var value := text.strip_edges()
		if key == "at" and value.is_empty():
			_apply_time_patch(tok, {}, [key])
			return
		var time := _read_time(value)
		if not is_finite(time):
			edit.text = initial
			app._set_status("请输入有效的时间数值")
			return
		_apply_time_patch(tok, {key: maxf(time, 0.0)}, [])
	edit.text_submitted.connect(commit)
	edit.focus_exited.connect(func(): commit.call(edit.text))

## 表单的时间编辑：与时间轴同一个补丁入口（StepTimeline.apply_patch + 同一写回）。
## tok 持有展示快照，顺序和正文仍匹配时才使用其中的下标。
func _apply_time_patch(tok: Dictionary, patch: Dictionary, erase_keys: Array) -> bool:
	if tok.is_empty():
		return false
	var edit := _steps_edit()
	var data: Dictionary = edit.data
	if data.is_empty():
		return false
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var si := _step_index_of(arr, tok)
	if si < 0:
		app._set_status("步骤已变更，本次未写入")
		return false
	# D2：新输入的 at/duration 按声明粒度吸附（帧取整、拍按 subdivisionsPerBeat）；
	# 秒基不吸附——手输的秒精度就是用户意图，不该被改
	if _steps_clock != null and str(_steps_clock.timebase) != "seconds":
		var snapv := float(_steps_clock.snap_step())
		patch = patch.duplicate()
		for k in ["at", "duration"]:
			if patch.has(k):
				patch[k] = snappedf(maxf(float(patch[k]), 0.0), snapv)
	return _write_time_patch(edit, arr, si, patch, erase_keys)

func _write_time_patch(edit: Dictionary, arr: Array, si: int, patch: Dictionary, erase_keys: Array) -> bool:
	var res := StepTimeline.apply_patch(arr, si, patch, erase_keys)
	if not bool(res.get("ok", false)):
		return false
	edit.data["steps"] = res.get("steps", arr)
	if not _steps_write(edit):
		return false
	_steps_sel = si
	_bump_steps_rev()
	_rebuild_steps_all()
	return true

## 使用展示时的顺序快照；同码步骤重排后拒绝旧回调。
static func _step_index_of(arr: Array, tok: Dictionary) -> int:
	return int(tok.get("index", -1)) if arr == tok.get("steps") else -1

## 写步骤字段：即时写盘，不重建表单（保焦点）。版本过期/令牌失效直接丢弃。
func _set_step_field(shown: Dictionary, key: String, value, rev := -1, check_pair := Callable()) -> bool:
	if key == "" or (rev >= 0 and rev != _steps_rev):
		return false
	var edit := _steps_edit()
	var data: Dictionary = edit.data
	if data.is_empty():
		return false
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if arr != shown.steps:
		app._set_status("步骤已变更，本次未写入")
		return false
	var si := int(shown.index)
	if si < 0 or si >= arr.size() or not (arr[si] is Dictionary):
		return false
	var st: Dictionary = arr[si]
	var sfd: Dictionary = st.get("fields", {}) if st.get("fields", {}) is Dictionary else {}
	if check_pair.is_valid() and not check_pair.call(sfd):
		return false
	if sfd.get(key, null) == value:
		return true
	sfd[key] = value
	st["fields"] = sfd
	data["steps"] = arr
	if not _steps_write(edit):
		return false
	# Compare later edits with the representation the workspace actually reads.
	# JSON numbers read back as floats, including integers within records.
	var stored: Array = _steps_data().get("steps", arr)
	var previous: Array = shown.steps
	shown.steps = stored.duplicate(true)
	if _steps_list_snapshot == previous:
		_steps_list_snapshot[si] = stored[si].duplicate(true)
	if is_instance_valid(_steps_tl) and _steps_tl.steps == previous:
		_steps_tl.steps[si] = stored[si].duplicate(true)
	var preview = FunctionDecls.function_decl(manifest, _steps_fn_id).get("timePreview")
	if preview is Dictionary and preview.has("tempoStep") and preview.has("bpmField"):
		var tempo := StepDecls.step_decl(manifest, str(preview.tempoStep))
		if str(tempo.get("code", "")) == str(st.get("step", "")):
			for fd in tempo.get("fields", []):
				if fd is Dictionary and fd.get("id") == preview.bpmField and fd.get("code") == key:
					_refresh_tempo_controls.call_deferred(_steps_form, _steps_rev, si)
					break
	return true

func _refresh_tempo_controls(form: Control, revision: int, index: int) -> void:
	if is_instance_valid(form) and form.is_visible_in_tree() and is_instance_valid(_steps_tl) \
			and form == _steps_form and revision == _steps_rev and index == _steps_sel:
		_rebuild_steps_form_from_data()

## 添加步骤：追加到末尾并选中。
func _reload_steps() -> void:
	_bump_steps_rev()
	_rebuild_steps_all()

func _steps_add(code: String, at_playhead := false) -> void:
	if code == "":
		return
	var edit := _steps_edit()
	var data: Dictionary = edit.data
	if data.is_empty():
		return
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var step := {"step": code, "fields": {}}
	if at_playhead:
		var time := maxf(0.0, _steps_tl.playhead)
		if _steps_clock != null and _steps_clock.timebase != "seconds":
			time = snappedf(time, _steps_clock.snap_step())
		step["at"] = time
	arr.append(step)
	data["steps"] = arr
	if not _steps_write(edit):
		return
	_steps_sel = arr.size() - 1
	_reveal_step_page()
	_bump_steps_rev()
	_rebuild_steps_all()

## 删除后尽量保留原选中步骤；删掉选中项时选相邻项。
func _steps_del(si: int) -> void:
	var edit := _steps_edit()
	var data: Dictionary = edit.data
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size():
		return
	arr.remove_at(si)
	data["steps"] = arr
	if not _steps_write(edit):
		return
	var next_sel := _steps_sel - 1 if _steps_sel > si else _steps_sel
	_steps_sel = mini(next_sel, arr.size() - 1)
	_reveal_step_page()
	_bump_steps_rev()
	_rebuild_steps_all()

## 上移/下移一格。
func _steps_move(si: int, dir: int) -> void:
	var edit := _steps_edit()
	var data: Dictionary = edit.data
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var nj := si + dir
	if si < 0 or si >= arr.size() or nj < 0 or nj >= arr.size():
		return
	var tmp = arr[si]
	arr[si] = arr[nj]
	arr[nj] = tmp
	data["steps"] = arr
	if not _steps_write(edit):
		return
	_steps_sel = nj
	_reveal_step_page()
	_bump_steps_rev()
	_rebuild_steps_all()

## 复制步骤：整条深拷贝，插到下一步；
## 步骤码引用清单声明、跨内容共享，无需重映射。
func _steps_dup(si: int) -> void:
	var edit := _steps_edit()
	var data: Dictionary = edit.data
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size() or not (arr[si] is Dictionary):
		return
	var cp: Dictionary = (arr[si] as Dictionary).duplicate(true)
	arr.insert(si + 1, cp)
	data["steps"] = arr
	if not _steps_write(edit):
		return
	_steps_sel = si + 1
	_reveal_step_page()
	_bump_steps_rev()
	_rebuild_steps_all()
