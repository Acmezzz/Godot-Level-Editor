extends VBoxContainer
## 资产与内容工作区及其状态栏；顶栏与关卡工作区共享。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const AssetPanelScript := preload("res://src/ui/asset_panel.gd")
const ContentEditorScript := preload("res://src/ui/content_editor.gd")

var app   # 宿主 app
var manifest := {}

var asset_panel = null
var content_editor = null

var _view := "asset"
var _holder: Control
var _status: Label

func _init(host) -> void:
	app = host
	manifest = host.manifest

func build() -> void:
	add_theme_constant_override("separation", 0)
	_holder = Control.new()
	_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_holder)
	add_child(_build_status_bar())
	_build_views()

## 底栏：状态消息常驻，与画布状态栏同一套视觉
func _build_status_bar() -> PanelContainer:
	var box := Kit.frame(SIDE_TOP, 12, 5)
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
	app._sync_panel_buttons(view)
	# E1：停靠的演出面板跟着视图搬到对应停靠位（资产视图保持原位）
	app._sync_steps_dock(view)
	asset_panel.visible = view == "asset"
	content_editor.root.visible = view == "content"
	match view:
		"asset":
			# 图鉴是唯一页面：焦点定位或落到第一项
			asset_panel.show_detail(focus)
			_set_status("资产名称和功能挂载应用后写入清单")
		"content":
			# focus 语义在此视图 = 实例 id（右栏定位），空则保留上次选中
			content_editor.refresh_list(focus)
			_set_status("编辑实例绑定，或打开项目内容库编辑独立内容")

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

## 内容页走统一保存入口；资产页只写清单。
func save_current() -> void:
	match _view:
		"content":
			var res: Dictionary = await app._map_file_ctrl.commit_document("内容页保存")
			_set_status("地图和暂存内容已保存" if res.status == "ok" else "保存未完成：" + str(res.error))
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
		_status.tooltip_text = _status.text
