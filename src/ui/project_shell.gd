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
			_set_status("点实例挂功能、填内容；改动即时写盘（Esc 回关卡编辑器）")

func _label_of(view: String) -> String:
	if view == "content":
		return "内容"
	if view == "asset":
		return "资产"
	return "项目"

## Ctrl+S / 顶栏保存：按当前视图分派保存目标
func save_current() -> void:
	match _view:
		"content":
			# 新内容编辑器改动即时写盘，commit 只回报成功与否
			content_editor.commit()
			# 加载清单时补发过执行码（D6）：内容文件此刻已带新码，清单也必须落盘，
			# 否则磁盘上「内容里的码」在清单里查无对应，游戏侧重建映射直接断链。
			if bool(manifest.get("_codes_issued", false)):
				save_manifest.call()
				_set_status("内容已保存；清单补发的新码已一并写回")
			else:
				_set_status("内容已保存（改动即时写盘）")
		_:
			save_manifest.call()
			_set_status("资产清单已保存")

func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg.strip_edges()
