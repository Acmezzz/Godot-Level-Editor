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
const ContentStore := preload("res://src/content/content_store.gd")
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

var host   # content_editor 宿主
var app    # 根应用（= host.app）

func _init(h) -> void:
	host = h
	app = h.app

## 同名转发属性（读写穿透到宿主，保住搬动文本零改动）
var manifest: Dictionary:
	get: return host.manifest
## 本面板自己的待提交控件（步骤字段）。不能转发到宿主数组：换步骤/重建表单时清空
## 本面板的待提交项，会把主表单还没冲刷的连续控件值一起丢掉（V4 P1）。
var _pending_commits: Array = []

## 冲刷本面板待提交值（换步骤/切时间轴点选前调用；控件闭包绑定的是当时的下标）。
func _flush_pending() -> bool:
	for cb in _pending_commits.duplicate():
		if cb is Callable and cb.is_valid():
			var result = cb.call()
			if result is bool and not result:
				return false
	return true

## 同名包装方法（真实实现经 host 转发）
func commit() -> bool:
	return _flush_pending() and host.commit()
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
		return host._form.project_reference_options(decl, _reference_context)
	return host._form._resolve_options(decl, _project_scope)
func _rebuild_right() -> void:
	host._rebuild_right()

var _steps_pop: PopupPanel = null
## E1：可复用容器形态——"popup" 独立窗口 / "content" 内容页下方 / "canvas" 画布下方。
## 三种形态共用同一控制器状态与工作副本，切换只换宿主容器，不重建数据。
var _steps_dock_where := "popup"
var _steps_dock: PanelContainer = null
var _steps_i := -1            # 正在编辑的绑定行下标
var _steps_fn_id := ""        # 该绑定的功能 id
## E1：所属实例码。停靠面板会长时间占屏，换实例后身份校验必须能发现（空绑定尤甚）
var _steps_ent := ""
var _steps_cid := ""          # 该绑定的内容 ID（身份校验：绑定换内容 = 数据源失效）
## R05：工作副本对应磁盘摘要（写回基线；暂存条目 digest 为空 = 不比对）。
var _steps_base := ""
## R23：面板令牌的地图身份——切图后旧面板对不上就不再写值。
var _project_manifest: Dictionary = {}
var _project_target := false
var _project_scope := false
var _reference_context := ""
var _steps_map := ""
var _steps_rev := 0           # 结构版本：增删/排序后递增，过期控件回调据此丢弃（D1）
var _steps_sel := -1          # 当前选中步骤下标；-1 = 无
## E1：恢复记忆下标时校验「还是同一步」——期间步骤被增删/换序就回落到无选中，
## 不把下标悄悄挪到另一条步骤上（与 D1 的过期回调同一套身份原则）。
var _steps_sel_expect := ""
var _steps_list: VBoxContainer = null
var _steps_form: VBoxContainer = null
var _steps_warn_box: VBoxContainer = null
# 时间轴视图页签（第 4 批）：同一份 steps，两种呈现。
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
## E1：按 (功能码, 内容 ID) 记住上次的步骤下标/视图/播放头——关掉再开回到原处。
## 只在同一份内容上恢复：换内容 = 另一份步骤数组，旧下标没有意义。
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
	_steps_map = _current_map_key()
	_mount_target()

func open_content(fn_id: String, cid: String, context := "", step_index := -1) -> bool:
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
	return true

func _mount_target() -> void:
	var fn_id := _steps_fn_id
	_steps_rev = 0
	# 时间轴视图对象每次开面板都是新建的：版本缓存必须同样归零，
	# 否则「0 == 0」会跳过 set_steps，再开一次时间轴页签就是空白。
	_steps_tl_rev = -1
	_steps_sel = -1
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
			"步骤按 at/duration/track 排布；列表保序、时间轴可拖")
		_steps_pop = shell.pop
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
	body.add_child(_steps_list)
	body.add_child(_steps_tl_box)
	body.add_child(Kit.divider())
	body.add_child(_steps_form)
	# 时间轴视图建一次、反复复用（set_steps 换数据源）；滚动容器兜住超宽/超高的排布
	_steps_tl = TimelineView.new()
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
		app._open_popup(_steps_pop)

## 弹窗形态的头部行：标题右侧挂「停靠下方」（搬进内容页底部，同一控制器）
func _build_steps_popup_head(body: VBoxContainer) -> void:
	var row := Kit.hbox(8)
	var dock_btn := Kit.button("停靠下方", func(): _dock_and_show("content"), "ghost")
	dock_btn.tooltip_text = "把演出面板停靠到内容页底部：表单和步骤同屏对照（步骤与播放头不变）"
	dock_btn.add_theme_font_size_override("font_size", Th.FS_META)
	row.add_child(Kit.spacer())
	row.add_child(dock_btn)
	body.add_child(row)

## 停靠形态的头部：标题 + 形态切换 + 收起（同一控制器，搬动不改数据）
## 三个去处常驻显示，当前所在项置灰——切换不重建头部，搬动只是换个父容器。
func _build_steps_head(head: HBoxContainer) -> void:
	head.add_child(Kit.section_header("演出编辑：%s" %
		FunctionDecls.function_name(manifest, _steps_fn_id)))
	head.add_child(Kit.spacer())
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
		var b := Kit.button(str(pair[0]), func(): _set_steps_view(str(pair[1])), "ghost")
		b.toggle_mode = true
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
	var current_manifest := manifest
	var session = app._map_file_ctrl.sess
	var generation: int = session.generation
	var valid := func() -> bool:
		return is_instance_valid(timeline) and is_same(_steps_tl, timeline) \
			and is_same(manifest, current_manifest) and _steps_identity_ok() and not session.stale(generation)
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
		var moment := {"value": raw, "unit": clock.timebase, "seconds": null}
		var seconds := clock.seconds_at(raw)
		if clock.is_ready() and is_finite(seconds):
			moment["seconds"] = seconds
		var subject := {"function": _steps_fn_id, "content": _steps_cid, "data": data, "time": moment,
			"manifest": app._manifest_write_payload(manifest), "viewportId": preset}
		var context := {}
		if not _project_target:
			context = MapGamePreview.map_context(app) if app.map_loaded else {}
			if context.is_empty():
				return {"error": "地图正在重建，请稍后重试。"}
			subject.merge(context)
			subject["instance"] = _steps_ent
			subject["bindingId"] = str(_steps_binding.get("bindingId", ""))
			subject["bindingIndex"] = _steps_i
		var revision: int = session.revision
		var matches := func() -> bool:
			return session.revision == revision \
				and (context.is_empty() or MapGamePreview.context_matches(app, context)) \
				and (_steps_cid == "" or host.read_content_staged(_steps_fn_id, _steps_cid) == data)
		return {"subject": subject, "default_size": Vector2(1280, 720), "current": matches,
			"summary": " · %s %s" % [value, clock.timebase]}
	FrameDialog.open(app, TIMELINE_FRAME, {"title": "游戏演出画面预览", "button": "渲染取样",
		"hint": "用已应用的演出内容和本图暂存数据，由游戏渲染选定时刻。",
		"prefix": "TimelineGamePreview", "default_label": "默认 1280 × 720",
		"sample": {"unit": _steps_timebase(), "value": timeline.playhead},
		"initial": "起始位置来自播放头；在此修改取样位置不会移动播放头。"}, capture, valid)

func _set_steps_view(mode: String) -> void:
	if mode != "list" and mode != "timeline":
		return
	# 切页签前先提交当前控件（D1）：待提交值属于旧下标，切完再落到新表单上会串步
	if not host.commit_fields():
		return
	_steps_view = mode
	_rebuild_steps_all()

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
	return str((d as Dictionary).get("timebase", "seconds"))

## 时间轴点选：只换选中与表单，不重建视图（拖拽进行中 picked 会被发多次）。
func _steps_pick_tl(idx: int) -> void:
	# 换选中前提交旧步骤的待提交控件值（同 _steps_pick）
	if not host.commit_fields() or not _flush_pending():
		if is_instance_valid(_steps_tl):
			_steps_tl.reject_pick(_steps_sel)
		return
	_steps_sel = idx
	if _steps_tl != null and is_instance_valid(_steps_tl):
		_steps_tl.sel = idx
		_steps_tl.queue_redraw()
	_rebuild_steps_form_from_data()

## 身份校验：还是同一个实例、绑定行还在、功能 id 与内容 ID 都还是开面板时的那个
## （换实例/换内容 = 数据源失效）。空绑定也必须过实例这一关：下标 i 在另一个实例上
## 可能照样合法，只比下标会把值写进别人的内容。
func _steps_identity_ok() -> bool:
	if _project_target:
		return is_same(_project_manifest, app.manifest) and _steps_cid != ""
	if _steps_map != "" and _steps_map != _current_map_key():
		return false   # R23：切图后旧面板令牌失效（同码实例/同类空绑定也判失效）
	if _steps_ent != "" and str(host._selected_ent) != _steps_ent:
		return false
	var fns := _current_fns()
	if _steps_i < 0 or _steps_i >= fns.size() or not (fns[_steps_i] is Dictionary):
		return false
	var f: Dictionary = fns[_steps_i]
	if str(_resolve_fn(f).get("id", "")) != _steps_fn_id:
		return false
	# 空绑定：会话内还没预留内容 ID，仍可写（首次实际改动才预留）
	return is_same(f, _steps_binding) and str(f.get("content", "")) == _steps_cid

## R23：当前文档身份键（地图码优先，无码退回图名）——与 content_form._doc_key 同口径。
func _current_map_key() -> String:
	var root := str(app.manifest.get("_dir", ""))
	var code := ""
	if host._map_ready() and host.app.canvas.map_data.get("meta", null) is Dictionary:
		code = str((host.app.canvas.map_data["meta"] as Dictionary).get("code", ""))
	if code == "":
		code = str(app.cur_map_name)
	return root.path_join(code)

## 工作副本读取：已绑定内容读磁盘/暂存；空绑定返回内存空壳（不落盘、不建 ID）。
func _steps_data() -> Dictionary:
	if not _steps_identity_ok():
		return {}
	if _steps_cid == "":
		return {"id": "", "function": FunctionDecls.fn_code(manifest, _steps_fn_id),
			"name": _steps_fn_id, "fields": {}, "steps": []}
	# R05：读工作副本时记下磁盘摘要（写回基线）；staged 条目 digest 为空（不比对）。
	var rd: Dictionary = host.read_content_staged_ex(_steps_fn_id, _steps_cid)
	_steps_base = str(rd.get("digest", ""))
	var data: Dictionary = rd.get("data", {})
	_project_scope = _project_target or data.get("scope") == "project"
	return data

## 工作副本写回：**首次实际改动时才预留内容 ID**（D1）；内容写盘失败给可见反馈。
func _steps_write(data: Dictionary) -> bool:
	if not _steps_identity_ok():
		return false
	if _steps_cid == "":
		var cid := _ensure_content(_steps_i)
		if cid == "":
			_ensure_failed()
			return false
		_steps_cid = cid
		_steps_binding = _current_fns()[_steps_i]
		if str(data.get("id", "")) == "":
			data["id"] = cid
	if str(host.write_content_staged(_steps_fn_id, _steps_cid, data, _steps_base)) != "ok":
		_ensure_failed()
		return false
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
		_steps_list.visible = false
		_steps_tl_box.visible = true
		_rebuild_steps_tl(arr)
	else:
		_steps_tl_box.visible = false
		_steps_list.visible = true
		_rebuild_steps_list(arr)
	_rebuild_steps_form(arr)

## 步骤列表（列表视图）：空态 + 逐行渲染。
var _steps_list_snapshot: Array = []
var _steps_binding: Dictionary = {}

func _rebuild_steps_list(arr: Array) -> void:
	_steps_list_snapshot = arr.duplicate(true)
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
	_steps_audio = AudioDecls.from_value(manifest, audio_value)
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
	var data := _steps_data()
	if data.is_empty():
		return
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if _steps_tl == null or arr != _steps_tl.steps:
		_bump_steps_rev()
		_rebuild_steps_all()
		return
	var res: Dictionary = StepTimeline.apply_patch(arr, idx, patch)
	if not bool(res.get("ok", false)):
		return
	data["steps"] = res.get("steps", arr)
	if not _steps_write(data):
		return
	_steps_sel = idx
	_bump_steps_rev()
	_rebuild_steps_all()

## 表单重建（数据自取）：时间轴点选后只换表单、不动视图。
func _rebuild_steps_form_from_data() -> void:
	if _steps_form == null:
		return
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	_sync_steps_clock(data)   # fps/偏移等参考值可能刚在别处改过，读数跟着更新
	_rebuild_steps_form(arr)

## 子面板里的一个步骤行：序号+名称（选中高亮）+ 上移/下移/复制/删除。
func _steps_row(si: int, st: Dictionary, _pool: Dictionary) -> Control:
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
	_rebuild_steps_all()

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
	var reload_btn := Kit.button("重读步骤", _reload_steps, "ghost")
	reload_btn.tooltip_text = "放弃尚未写入的步骤输入，重读当前内容"
	add_row.add_child(reload_btn)
	box.add_child(add_row)
	# 时间轴警告（负 at/duration、同轨重叠）：只提示不阻断
	for wtext in StepTimeline.warnings(arr):
		box.add_child(Kit.hint_label("⚠ " + str(wtext), 320))
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
	box.add_child(_steps_time_row(arr, shown))
	var sfields: Array = decl.get("fields", [])
	var sfd: Dictionary = st.get("fields", {}) if st.get("fields", {}) is Dictionary else {}
	for fd in sfields:
		if not (fd is Dictionary):
			continue
		box.add_child(_step_field_row(fd, sfd, sfields, shown))
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
## 回调捕获**步骤稳定令牌 + 结构版本 + 绑定身份**（D1/V4 P1）：换序/切页签后迟到的
## 回调按版本丢弃；版本没变但步序真的变了（外部合并暂存）时按令牌重新定位。
## E1：同图实例引用给「画布选…」——选点会话写回走同一版本校验入口。
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
	var frame_pick := func(row: Control, nested: Dictionary, pair: Callable, save: Callable):
		FrameReference.add_reference_button(app, row, nested, pair, save, _resolve_options, _project_scope,
			_rebuild_steps_form_from_data, _reference_context)
	var built := FieldWidgets.build(d, val, apply, _resolve_options, "code", frame_pick)
	if built.get("commit") is Callable and (built.commit as Callable).is_valid():
		_pending_commits.append(built.commit)
	var row := Kit.field_row(label, built.ctl, 96)
	var tip := FieldWidgets.decl_tooltip(fd)
	if tip != "":
		row.tooltip_text = tip
	var pickable := FieldWidgets.wants_canvas_pick(fd) and (not _project_scope or tk != "")
	if pickable and host._form.can_pick_on_canvas(tk):
		var pick := Kit.button("画布选…", func(): _pick_step_ref(fd, apply), "ghost")
		pick.tooltip_text = "临时切到画布点一个实例；确认才写入这一步，取消不改当前值" \
			if not FieldWidgets.wants_edge_pick(fd) else "临时切到画布点一条格边；确认才写入这一步，取消不改当前值"
		if FieldWidgets.wants_cell_pick(fd):
			pick.tooltip_text = "临时切到画布点格图里的一格（按多边形命中）；确认才写入这一步，取消不改当前值"
		pick.add_theme_font_size_override("font_size", Th.FS_META)
		row.add_child(pick)
	if FieldWidgets.wants_frame_pick(fd):
		var pair := func() -> String:
			var index: int = shown.index
			var steps: Array = shown.steps
			return RefFields.paired_map_value(fd, siblings, steps[index].get("fields", {}))
		var save := func(value) -> bool:
			var expected: String = pair.call()
			return _set_step_field(shown, key, value, rev,
				func(fields: Dictionary): return RefFields.paired_map_value(fd, siblings, fields) == expected)
		FrameReference.add_reference_button(app, row, fd, pair, save, _resolve_options, _project_scope,
			_rebuild_steps_form_from_data, _reference_context)
	return row

## E1：步骤字段的画布选点。确认后按起手时的步骤令牌 + 版本写回：
## 期间步骤被增删/换序则丢弃（与拖拽同一套过期校验）。
## accept 按字段种类走：entity_ref = 实例；§7.4 edge_ref = 格边（值解码回 {map, cell, edge}）；
## C4 cell: 的 choice = 格图一格（值就是 cell_id 字符串）——与内容表单同一路径。
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
func _steps_time_row(arr: Array, tok: Dictionary) -> Control:
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
	trk.value_changed.connect(func(v: float):
		if rev_trk == _steps_rev:
			_apply_time_patch(tok, {"track": int(v)}, []))
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
	return box

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
		var tr := TextureRect.new()
		tr.texture = tex
		tr.custom_minimum_size = Vector2(48, 48)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_steps_frame_holder.add_child(tr)
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
		if not value.is_valid_float() or not is_finite(value.to_float()):
			edit.text = initial
			app._set_status("请输入有效的时间数值")
			return
		_apply_time_patch(tok, {key: maxf(value.to_float(), 0.0)}, [])
	edit.text_submitted.connect(commit)
	edit.focus_exited.connect(func(): commit.call(edit.text))

## 表单的时间编辑：与时间轴同一个补丁入口（StepTimeline.apply_patch + 同一写回）。
## tok 持有展示快照，顺序和正文仍匹配时才使用其中的下标。
func _apply_time_patch(tok: Dictionary, patch: Dictionary, erase_keys: Array) -> void:
	if tok.is_empty():
		return
	var data := _steps_data()
	if data.is_empty():
		return
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	var si := _step_index_of(arr, tok)
	if si < 0:
		app._set_status("步骤已变更，本次未写入")
		return
	# D2：新输入的 at/duration 按声明粒度吸附（帧取整、拍按 subdivisionsPerBeat）；
	# 秒基不吸附——手输的秒精度就是用户意图，不该被改
	if _steps_clock != null and str(_steps_clock.timebase) != "seconds":
		var snapv := float(_steps_clock.snap_step())
		patch = patch.duplicate()
		for k in ["at", "duration"]:
			if patch.has(k):
				patch[k] = snappedf(maxf(float(patch[k]), 0.0), snapv)
	var res: Dictionary = StepTimeline.apply_patch(arr, si, patch, erase_keys)
	if not bool(res.get("ok", false)):
		return
	data["steps"] = res.get("steps", arr)
	if not _steps_write(data):
		return
	_steps_sel = si
	_bump_steps_rev()
	_rebuild_steps_all()

## 使用展示时的顺序快照；同码步骤重排后拒绝旧回调。
static func _step_index_of(arr: Array, tok: Dictionary) -> int:
	return int(tok.get("index", -1)) if arr == tok.get("steps") else -1

## 写步骤字段：即时写盘，不重建表单（保焦点）。版本过期/令牌失效直接丢弃。
func _set_step_field(shown: Dictionary, key: String, value, rev := -1, check_pair := Callable()) -> bool:
	if key == "" or (rev >= 0 and rev != _steps_rev):
		return false
	var data := _steps_data()
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
	if not _steps_write(data):
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

func _steps_add(code: String) -> void:
	if code == "":
		return
	var data := _steps_data()
	if data.is_empty():
		return
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	arr.append({"step": code, "fields": {}})
	data["steps"] = arr
	if not _steps_write(data):
		return
	_steps_sel = arr.size() - 1
	_bump_steps_rev()
	_rebuild_steps_all()

## 删除步骤；删的是选中的步骤时清除选中。
func _steps_del(si: int) -> void:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size():
		return
	arr.remove_at(si)
	data["steps"] = arr
	if not _steps_write(data):
		return
	var next_sel := _steps_sel - 1 if _steps_sel > si else _steps_sel
	_steps_sel = mini(next_sel, arr.size() - 1)
	_bump_steps_rev()
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
	if not _steps_write(data):
		return
	_steps_sel = nj
	_bump_steps_rev()
	_rebuild_steps_all()

## 复制步骤：整条深拷贝（duplicate(true)，fields 再单独拷一层防共享嵌套），插到下一步；
## 步骤码引用清单声明、跨内容共享，无需重映射。
func _steps_dup(si: int) -> void:
	var data := _steps_data()
	var arr: Array = data.get("steps", []) if data.get("steps", []) is Array else []
	if si < 0 or si >= arr.size() or not (arr[si] is Dictionary):
		return
	var cp: Dictionary = (arr[si] as Dictionary).duplicate(true)
	cp["fields"] = (cp.get("fields", {}) as Dictionary).duplicate(true) if cp.get("fields", {}) is Dictionary else {}
	arr.insert(si + 1, cp)
	data["steps"] = arr
	if not _steps_write(data):
		return
	_steps_sel = si + 1
	_bump_steps_rev()
	_rebuild_steps_all()
