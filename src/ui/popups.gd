extends RefCounted
## Popups：主题构建/徽章/统一弹窗外壳/快捷键速查（从 editor_layout.gd 拆出，宿主 = editor_layout）


var host   # editor_layout 宿主
var app    # 根应用（= host.app）

func _init(h) -> void:
	host = h
	app = h.app

func _build_theme() -> void:
	app.theme = app.UiThemeScript.build()

## 原地切换徽章状态（继承 → 覆盖）

func _set_badge(p: PanelContainer, text: String, color: Color) -> void:
	app.UiKitScript.set_badge(p, text, color)

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
	# 先按内容算出最小尺寸（此刻子控件还没排版，直接量会偏小），
	# 再用 popup_centered() 让引擎按最小尺寸开窗——不带参数的 popup_centered()
	# 会沿用上次窗口大小，必须显式给尺寸。
	# 单次居中量取不准会裁切内容——两段式（先 1×1 弹出再按实际最小尺寸居中）。
	# 两段式首帧会在左上角闪一下 1×1 的小窗。把第一段挪到屏幕外再量——
	# 同一帧内接第二段居中，中间那次布局从未被绘制，闪烁消失。
	pop.popup_centered(Vector2i(1, 1))
	pop.position = Vector2i(-32000, -32000)
	var want := pop.get_contents_minimum_size().ceil()
	var vp = app.get_viewport_rect().size
	want.x = minf(want.x, vp.x - 40)
	want.y = minf(want.y, vp.y - 40)
	if size != Vector2i.ZERO:
		want = Vector2(size)
	pop.popup_centered(Vector2i(want))

## 弹窗标准外壳：标题 + 副标题 + 内容区，保证所有面板视觉一致
## 内容列宽度固定（body_w），所有内部换行标签都以此为准，避免弹窗高度失控。

func _popup_body(title: String, subtitle := "") -> Dictionary:
	var pop := PopupPanel.new()
	var col = app.UiKitScript.vbox(10)
	col.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	pop.add_child(col)
	col.add_child(app.UiKitScript.text_label(title, app.UiThemeScript.TEXT, app.UiThemeScript.FS_MD))
	if subtitle != "":
		col.add_child(app.UiKitScript.hint_label(subtitle, app.POPUP_BODY_W))
	var body = app.UiKitScript.vbox(8)
	body.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	col.add_child(body)
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
		["返回", "Esc 回到关卡编辑器 / 取消区域粘贴预览"],
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
