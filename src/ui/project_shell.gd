extends VBoxContainer
## 项目工作台外壳：资产 / 内容两个全屏视图共用一个壳。
##
## 设计基线：资产 / 内容统一进项目工作台（旧的三全屏模式取消）。
## 右上角与画布顶栏同一套「关卡 / 内容 / 资产」模式切换（Esc 回画布），
## 底栏状态消息常驻，Ctrl+S 按当前视图分派保存目标。
## 没有左侧页签栏——切换全靠右上角三个模式按钮。
## 清单设置、背景图组、关卡清单与世界拓扑均已删除。
##
## 各视图只负责自己的内容区（原来是各自带顶栏的全屏界面，顶栏已收进本壳）。

const StartupDialog := preload("res://src/ui/startup_dialog.gd")
const ProjectSlots := preload("res://src/project/project_content_slots.gd")
const ProjectSlotsDialog := preload("res://src/ui/project_content_slots_dialog.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const AssetPanelScript := preload("res://src/ui/asset_panel.gd")
const ContentEditorScript := preload("res://src/ui/content_editor.gd")
const TopBarNavScript := preload("res://src/ui/top_bar_nav.gd")

var app   # 宿主 app
var manifest := {}
var save_manifest: Callable

var asset_panel = null
var content_editor = null

var _view := "asset"
var _holder: Control
var _title: Label
var _status: Label
var _nav_bar   # 地图 ▾ + 三个模式按钮（与关卡视图顶栏共用同一个组件）

func _init(host) -> void:
	app = host
	manifest = host.manifest
	save_manifest = Callable(host, "_save_manifest_file")

func build() -> void:
	add_theme_constant_override("separation", 0)
	add_child(_build_top_bar())
	_holder = Control.new()
	_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_holder)
	add_child(_build_status_bar())
	_build_views()

## 顶栏：模式切换（关卡/内容/资产）+ 当前视图名 + 项目徽章 + 保存
func _build_top_bar() -> PanelContainer:
	var box := PanelContainer.new()
	var sb := Th.box(Th.BG_BASE, Th.BORDER, 0, 12, 8)
	sb.set_border_width_all(0)
	sb.border_width_bottom = 1
	box.add_theme_stylebox_override("panel", sb)
	var bar := Kit.hbox(10)
	box.add_child(bar)
	_title = Kit.text_label("项目", Th.TEXT, Th.FS_LG)
	bar.add_child(_title)
	bar.add_child(Kit.badge(str(manifest.get("projectName", "?")), Th.ACCENT))
	bar.add_child(Kit.spacer())
	# 地图 ▾ + 三个模式按钮：与关卡视图顶栏共用同一个组件
	_nav_bar = TopBarNavScript.new(app)
	_nav_bar.after_switch = func(): show_view(_view)
	_nav_bar.build()
	app._nav_bars.append(_nav_bar)
	bar.add_child(_nav_bar)
	bar.add_child(Kit.vdivider())
	var save := Kit.button("保存", func(): save_current(), "primary")
	save.tooltip_text = "保存当前视图对应的数据（Ctrl+S）"
	bar.add_child(save)
	if manifest.has("startup"):
		bar.add_child(Kit.button("启动入口…", func(): StartupDialog.open(app), "ghost"))
	if not ProjectSlots.declarations(manifest).is_empty():
		bar.add_child(Kit.button("项目规则…", func(): ProjectSlotsDialog.open(app), "ghost"))
	if bool(manifest.get("playtest", {}).get("projectEntry", false)):
		bar.add_child(Kit.button("试玩项目", func():
			app._playtest_ctrl.on_play(Vector2i(-1, -1), true), "ghost"))
	if bool(manifest.get("playtest", {}).get("report", false)):
		bar.add_child(Kit.button("试玩反馈", func(): app._playtest_ctrl.open_play_report(), "ghost"))
	return box

## 底栏：状态消息常驻，与画布状态栏同一套视觉
func _build_status_bar() -> PanelContainer:
	var box := PanelContainer.new()
	var sb := Th.box(Th.BG_BASE, Th.BORDER, 0, 12, 5)
	sb.set_border_width_all(0)
	sb.border_width_top = 1
	box.add_theme_stylebox_override("panel", sb)
	var h := Kit.hbox(10)
	box.add_child(h)
	_status = Kit.text_label("就绪", Th.TEXT_DIM, Th.FS_SMALL)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(_status)
	return box

func _build_views() -> void:
	asset_panel = AssetPanelScript.new()
	asset_panel.manifest = manifest
	asset_panel.save_manifest = save_manifest
	asset_panel.host = app
	_holder.add_child(asset_panel)
	asset_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	asset_panel.build()

	content_editor = ContentEditorScript.new(app)
	var editor_root: Control = content_editor.build()
	_holder.add_child(editor_root)
	editor_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

## 切视图（可横跳）。focus 用于资产/内容定位到某条资源
func show_view(view: String, focus := "") -> void:
	_view = view
	# 按下态由 app 统一同步到两个顶栏导航条（_set_mode 是唯一真相，
	# 这里补一次是为了 show_view 被直接调用时按钮也不脱节）
	app._sync_panel_buttons(view)
	# E1：停靠的演出面板跟着视图搬到对应停靠位（资产视图保持原位）
	app._sync_steps_dock(view)
	asset_panel.visible = view == "asset"
	content_editor.root.visible = view == "content"
	_title.text = "项目 · %s" % _label_of(view)
	match view:
		"asset":
			# 图鉴是唯一页面：焦点定位或落到第一项
			asset_panel.show_detail(focus)
			_set_status("资产模板改动后点「保存」写回清单，下次试玩生效")
		"content":
			# focus 语义在此视图 = 实例 id（右栏定位），空则保留上次选中
			content_editor.refresh_list(focus)
			_set_status("编辑实例绑定，或从「项目内容库」创建和保存独立内容（Esc 回关卡编辑器）")

## 静默切视图（E1 选点归来）：不重建内容表单/不动焦点——表单值在离开时已保留，
## 参考值的提交由宿主自己就地更新。只切可见性与按下态。
func show_view_quiet(view: String) -> void:
	_view = view
	app._sync_panel_buttons(view)
	# E1：停靠的演出面板跟着视图搬家（画布停靠位 ↔ 内容页停靠位）
	app._sync_steps_dock(view)
	# 从画布切回项目页：画布层必须一起让位，否则两套视图同时上屏
	if app._map_view != null:
		app._map_view.visible = view == "map"
	visible = view != "map"
	asset_panel.visible = view == "asset"
	content_editor.root.visible = view == "content"
	_title.text = "项目 · %s" % _label_of(view)

func _label_of(view: String) -> String:
	if view == "content":
		return "内容"
	if view == "asset":
		return "资产"
	return "项目"

## Ctrl+S / 顶栏保存：按当前视图分派，两条路径的保证不同：
##   内容视图 → commit_document（清单补码 → 暂存内容 → 脏地图，按依赖序 + 提交日志）。
##   其余（资产视图） → 只写清单文件；不碰内容与地图。
## 提示文案一律取自返回结果（written/error），失败时明说「未完成、待写项仍在」，
## 不按「点了保存」猜成功。
func save_current() -> void:
	match _view:
		"content":
			# 统一提交（清单补码 → 暂存内容 → 脏地图），不再绕过提交日志与地图保存。
			var res: Dictionary = await app._map_file_ctrl.commit_document("内容页保存")
			var st := str(res.get("status", ""))
			if st == "ok":
				var wr: Array = res.get("written", []) as Array
				_set_status("内容页提交完成%s" % ("：" + ", ".join(PackedStringArray(wr)) if not wr.is_empty() else "：无待写改动"))
			else:
				_set_status(" 内容页提交未完成：%s；待写项仍在，修好后重试" % str(res.get("error", "未知原因")))
		_:
			var ok: bool = await app._save_manifest_file_async()
			_set_status("资产清单已保存" if ok else " 清单保存失败/取消：改动未落盘")

## E1：离开内容视图时记下定位（实例 + 展开的功能），回来按身份恢复。
## 调用点：_set_mode 切走前、选点会话开始时。
func remember_content_context() -> void:
	if content_editor != null:
		content_editor.remember_context()

func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg.strip_edges()
