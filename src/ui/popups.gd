extends RefCounted
## Popups：统一弹窗外壳与快捷键速查（从 editor_layout.gd 拆出，宿主 = editor_layout）


# editor_layout 持有该子控制器；反向只保留弱引用，切换项目时可释放。
var _host_ref: WeakRef
var host:
	get: return _host_ref.get_ref()
var app    # 根应用（= host.app）

func _init(h) -> void:
	_host_ref = weakref(h)
	app = h.app

## 统一的弹窗挂载：挂到窗口根（不再挂进资产栏，避免被布局裁切与节点泄漏），
## 居中显示，关闭后自动释放。所有弹窗面板都必须走这里。

func _open_popup(pop: PopupPanel, size := Vector2i.ZERO, parent: Window = null) -> void:
	if parent == null:
		app.add_child(pop)
	else:
		pop.transient = true
		pop.exclusive = true
		parent.add_child(pop)
	pop.popup_hide.connect(func(): pop.queue_free())
	if not pop.has_meta("dialog_body"):
		pop.popup_centered(size)
		return
	var body: VBoxContainer = pop.get_meta("dialog_body")
	var scroll := body.get_parent() as ScrollContainer
	var col := scroll.get_parent() as VBoxContainer
	if body.get_child_count() > 0:
		var actions := body.get_child(-1)
		if actions.has_meta("dialog_actions"):
			actions.reparent(col)
	var measure := func() -> Vector2i:
		var available: Vector2 = app.get_viewport_rect().size - Vector2(48, 48)
		var padding := pop.get_theme_stylebox("panel", "PopupPanel").get_minimum_size()
		scroll.custom_minimum_size = Vector2.ZERO
		var chrome := col.get_combined_minimum_size() + padding
		var natural := body.get_combined_minimum_size()
		scroll.custom_minimum_size = Vector2(
			maxf(0.0, minf(available.x - padding.x, natural.x + 8.0)),
			maxf(0.0, minf(available.y - chrome.y - 12.0, natural.y + 4.0)))
		var want := Vector2i((col.get_combined_minimum_size() + padding).ceil())
		return want.max(size).min(Vector2i(available))
	pop.popup_centered(measure.call())
	body.minimum_size_changed.connect(func():
		if pop.visible and not pop.is_queued_for_deletion():
			var wanted: Vector2i = measure.call()
			if wanted.x > pop.size.x or wanted.y > pop.size.y:
				var centered := pop.position + Vector2i(Vector2(pop.size - wanted) * 0.5)
				pop.size = wanted
				var limit := Vector2i(app.get_viewport_rect().size) - wanted - Vector2i(8, 8)
				pop.position = centered.clamp(Vector2i(8, 8), limit.max(Vector2i(8, 8)))
	, CONNECT_DEFERRED)

## 弹窗标准外壳：标题 + 副标题 + 内容区，保证所有面板视觉一致
## 内容列宽度固定（body_w），所有内部换行标签都以此为准，避免弹窗高度失控。

func _popup_body(title: String, subtitle := "") -> Dictionary:
	var pop := PopupPanel.new()
	var col = app.UiKitScript.vbox(12)
	col.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	pop.add_child(col)
	col.add_child(app.UiKitScript.text_label(title, app.UiThemeScript.TEXT, app.UiThemeScript.FS_LG))
	if subtitle != "":
		col.add_child(app.UiKitScript.hint_label(subtitle, app.POPUP_BODY_W))
	var scroll := ScrollContainer.new()
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var body = app.UiKitScript.vbox(8)
	body.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	pop.set_meta("dialog_body", body)
	return {"pop": pop, "root": col, "body": body}

## 快捷键速查共 8 行（撤销 / 剪贴板 / 编辑 / 框选 / 文件 / 返回 / 视图 / 速查）。
## 数字键与工具键已全部删除——它们从未是用户设计的一部分，是历史实现遗留。
func _open_shortcut_help() -> void:
	var shell: Dictionary = app._popup_body("快捷键速查", "只剩必要的键盘入口；其余全部交给鼠标与层下拉")
	var pop: PopupPanel = shell.pop
	var rows := [
		["撤销", "Ctrl+Z 撤销 · Ctrl+Y / Ctrl+Shift+Z 重做"],
		["剪贴板", "Ctrl+C 复制 · Ctrl+V 粘贴 · Ctrl+X 剪切 · Ctrl+D 原位复制"],
		["编辑", "Del 删除选中 · F 水平翻转 · R 旋转90° · [ ] 缩放步进 · 方向键 微调 1 格（Shift = 4 格）"],
		["框选", "点状态栏「框选」开关后左键拖动框选；选中后可直接整组拖动"],
		["文件", "Ctrl+S 保存 · Ctrl+N 新建 · Ctrl+O 打开"],
		["返回", "Esc 回到关卡视图 / 取消区域粘贴预览"],
		["视图", "滚轮 缩放 · 中键/空格拖拽 平移 · Home 适应窗口 · = / - 缩放"],
		["速查", "? 本速查"],
	]
	for r in rows:
		var line: HBoxContainer = app.UiKitScript.hbox(8)
		var k: Label = app.UiKitScript.text_label(str(r[0]), app.UiThemeScript.ACCENT_HI, app.UiThemeScript.FS_SMALL)
		k.custom_minimum_size = Vector2(56, 0)
		line.add_child(k)
		line.add_child(app.UiKitScript.wrap_label(str(r[1]), app.POPUP_BODY_W - 64))
		shell.body.add_child(line)
	shell.body.add_child(app.UiKitScript.hint_label(
		"左键放置/涂刷、右键擦除；层下拉决定当前画笔，没有工具要选。" +
		"新建/打开地图时填名字，不再在顶栏就地改名。",
		app.POPUP_BODY_W))
	var close_btn: Button = app.UiKitScript.button("关闭", func(): pop.hide(), "primary")
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	shell.body.add_child(close_btn)
	app._open_popup(pop)
