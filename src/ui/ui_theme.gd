extends RefCounted
class_name UiTheme
## 编辑器统一视觉系统：颜色令牌 + 完整控件主题。
##
## 设计取向（参考现代 AI 编码工具的界面）：近黑中性底、单一蓝色强调色、
## 低饱和边框分层、高对比正文。所有 UI 组件只从这里取色和样式，
## 不允许在别处硬编码色值，保证换肤只改一个文件。
##
## 用法：`theme = UiTheme.build()`（在 app._build_theme 里）。

# —— 颜色令牌 ——
# 背景由深到浅分三层，制造「凹陷画布 / 常规面板 / 浮起控件」的层级
const BG_VOID := Color("#0b0e13")      # 画布底色（最深）
const BG_BASE := Color("#12161d")      # 窗口底
const BG_PANEL := Color("#171c24")     # 面板
const BG_RAISED := Color("#1e242e")    # 输入框 / 按钮 / 卡片
const BG_HOVER := Color("#273040")     # 悬停
const BG_ACTIVE := Color("#2f3a4d")    # 按下

# 边框：低对比，只用来切分区域，不抢视觉
const BORDER := Color("#242c38")
const BORDER_HI := Color("#354052")

# 文字三级层次
const TEXT := Color("#e8edf5")
const TEXT_DIM := Color("#9aa5b5")
# 启用态次级控件用中间亮度：比普通说明文字亮一档，避免「新建/打开/保存」被误读为禁用
const TEXT_SOFT := Color("#b9c3d1")
const TEXT_MUTE := Color("#697487")

# 单一强调色（选中 / 主操作 / 焦点环）
const ACCENT := Color("#4c9aff")
const ACCENT_HI := Color("#74b4ff")
const ACCENT_BG := Color("#182c47")

# 语义色：只用于状态反馈，不参与常规装饰
const OK := Color("#3fb950")
const WARN := Color("#d6a13a")
const ERR := Color("#f0605c")

# 圆角尺度：外层容器更大，内层控件更紧
const R_CONTAINER := 8
const R_CONTROL := 6
const R_INNER := 4

# 字号尺度
const FS_META := 11
const FS_SMALL := 12
const FS_BASE := 13
const FS_MD := 14
const FS_LG := 17

## 构造完整主题。所有控件类型一次性配齐，避免局部漏样式而回落到 Godot 默认灰。
const MAP_TERRAIN := Color(0.35, 0.65, 0.40, 0.95)
const MAP_DECOR := Color(0.20, 0.40, 0.25, 0.80)

static func build() -> Theme:
	var th := Theme.new()
	th.default_font_size = FS_BASE
	_style_button(th)
	_style_inputs(th)
	_style_lists(th)
	_style_tabs(th)
	_style_containers(th)
	_style_popups(th)
	_style_labels(th)
	return th

# —— 基础构造工具 ——
## 统一风格的底板：可选边框、圆角、内边距、阴影
static func box(
		bg: Color,
		border: Color = Color(0, 0, 0, 0),
		radius: int = R_CONTROL,
		pad_h: int = 10,
		pad_v: int = 6,
		border_w: int = 1,
		shadow: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	if border.a > 0.0:
		sb.set_border_width_all(border_w)
		sb.border_color = border
	else:
		sb.set_border_width_all(0)
	if shadow > 0:
		sb.shadow_size = shadow
 # 阴影带底色倾向，而不是纯黑，避免发灰
		sb.shadow_color = Color(0, 0, 0, 0.35)
		sb.shadow_offset = Vector2(0, 2)
	return sb

## 一段纯色填充（用于分隔线等没有文字的样式盒）
static func flat(bg: Color, radius: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	return sb

# —— Button 及变体 ——
static func _style_button(th: Theme) -> void:
	# 默认按钮：浮起底色 + 细边框，悬停提亮，按下下沉
	th.set_stylebox("normal", "Button", box(BG_RAISED, BORDER, R_CONTROL, 12, 6))
	th.set_stylebox("hover", "Button", box(BG_HOVER, BORDER_HI, R_CONTROL, 12, 6))
	th.set_stylebox("pressed", "Button", box(BG_ACTIVE, ACCENT, R_CONTROL, 12, 6))
	var disabled := box(BG_RAISED, BORDER, R_CONTROL, 12, 6)
	disabled.bg_color = Color(BG_RAISED, 0.45)
	th.set_stylebox("disabled", "Button", disabled)
	# 焦点环：1px 强调色描边（键盘可达性）
	th.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), ACCENT, R_CONTROL, 0, 0))

	th.set_color("font_color", "Button", TEXT_SOFT)
	th.set_color("font_hover_color", "Button", TEXT)
	th.set_color("font_pressed_color", "Button", TEXT)
	th.set_color("font_focus_color", "Button", TEXT)
	th.set_color("font_disabled_color", "Button", Color(TEXT_MUTE, 0.5))
	th.set_constant("h_separation", "Button", 6)
	th.set_font_size("font_size", "Button", FS_BASE)

	# 主操作（试玩 / 保存）：实心强调色
	th.set_type_variation("PrimaryButton", "Button")
	th.set_stylebox("normal", "PrimaryButton", box(ACCENT.darkened(0.35), ACCENT, R_CONTROL, 14, 6))
	th.set_stylebox("hover", "PrimaryButton", box(ACCENT.darkened(0.15), ACCENT_HI, R_CONTROL, 14, 6))
	th.set_stylebox("pressed", "PrimaryButton", box(ACCENT.darkened(0.5), ACCENT, R_CONTROL, 14, 6))
	th.set_stylebox("disabled", "PrimaryButton", box(Color(ACCENT.darkened(0.6), 0.4), BORDER, R_CONTROL, 14, 6))
	th.set_stylebox("focus", "PrimaryButton", box(Color(0, 0, 0, 0), ACCENT_HI, R_CONTROL, 0, 0))
	th.set_color("font_color", "PrimaryButton", Color("#eaf3ff"))
	th.set_color("font_hover_color", "PrimaryButton", Color("#ffffff"))
	th.set_color("font_pressed_color", "PrimaryButton", Color("#dbe9ff"))
	th.set_color("font_disabled_color", "PrimaryButton", Color(TEXT_MUTE, 0.6))

	# 幽灵按钮（次级操作）：无底色，悬停才浮现
	th.set_type_variation("GhostButton", "Button")
	var ghost := flat(Color(0, 0, 0, 0), R_CONTROL)
	ghost.content_margin_left = 10
	ghost.content_margin_right = 10
	ghost.content_margin_top = 6
	ghost.content_margin_bottom = 6
	th.set_stylebox("normal", "GhostButton", ghost)
	th.set_stylebox("hover", "GhostButton", box(BG_RAISED, Color(0, 0, 0, 0), R_CONTROL, 10, 6))
	th.set_stylebox("pressed", "GhostButton", box(BG_ACTIVE, Color(0, 0, 0, 0), R_CONTROL, 10, 6))
	th.set_stylebox("disabled", "GhostButton", ghost)
	th.set_stylebox("focus", "GhostButton", box(Color(0, 0, 0, 0), ACCENT, R_CONTROL, 10, 6))
	th.set_color("font_color", "GhostButton", TEXT_SOFT)
	th.set_color("font_hover_color", "GhostButton", TEXT)
	th.set_color("font_pressed_color", "GhostButton", TEXT)
	th.set_color("font_disabled_color", "GhostButton", Color(TEXT_MUTE, 0.45))

	# 图标按钮：正方形、无左右留白（👁 / 🔒 / ↺ 这类）
	th.set_type_variation("IconButton", "Button")
	th.set_stylebox("normal", "IconButton", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), R_INNER, 4, 4))
	th.set_stylebox("hover", "IconButton", box(BG_HOVER, Color(0, 0, 0, 0), R_INNER, 4, 4))
	th.set_stylebox("pressed", "IconButton", box(ACCENT_BG, ACCENT, R_INNER, 4, 4))
	th.set_stylebox("focus", "IconButton", box(Color(0, 0, 0, 0), ACCENT, R_INNER, 4, 4))
	th.set_color("font_color", "IconButton", TEXT_SOFT)
	th.set_color("font_hover_color", "IconButton", TEXT)
	th.set_color("font_pressed_color", "IconButton", ACCENT_HI)

	# 工具切换按钮：选中态用强调色描边 + 淡底，一眼看出当前工具
	th.set_type_variation("ToolButton", "Button")
	th.set_stylebox("normal", "ToolButton", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), R_INNER, 9, 5))
	th.set_stylebox("hover", "ToolButton", box(BG_RAISED, Color(0, 0, 0, 0), R_INNER, 9, 5))
	th.set_stylebox("pressed", "ToolButton", box(ACCENT_BG, ACCENT, R_INNER, 9, 5))
	th.set_stylebox("focus", "ToolButton", box(Color(0, 0, 0, 0), ACCENT, R_INNER, 9, 5))
	th.set_color("font_color", "ToolButton", TEXT_SOFT)
	th.set_color("font_hover_color", "ToolButton", TEXT)
	th.set_color("font_pressed_color", "ToolButton", ACCENT_HI)
	th.set_color("font_hover_pressed_color", "ToolButton", ACCENT_HI)

	# 开关按钮（网格 / 碰撞）：靠 pressed 的强调底色表达 on/off
	th.set_type_variation("ToggleButton", "Button")
	th.set_stylebox("normal", "ToggleButton", box(Color(0, 0, 0, 0), BORDER, R_INNER, 10, 5))
	th.set_stylebox("hover", "ToggleButton", box(BG_HOVER, BORDER_HI, R_INNER, 10, 5))
	th.set_stylebox("pressed", "ToggleButton", box(ACCENT_BG, ACCENT, R_INNER, 10, 5))
	th.set_stylebox("focus", "ToggleButton", box(Color(0, 0, 0, 0), ACCENT_HI, R_INNER, 10, 5))
	th.set_color("font_color", "ToggleButton", TEXT_MUTE)
	th.set_color("font_hover_color", "ToggleButton", TEXT_DIM)
	th.set_color("font_pressed_color", "ToggleButton", ACCENT_HI)
	th.set_color("font_hover_pressed_color", "ToggleButton", ACCENT_HI)

	# 图标型开关（图层可见/锁定）：紧凑方块，on 态用强调色实底 + 亮描边，
	# off 态只留一圈弱边——两者对比足够强，不会「看不出是否启用」。
	th.set_type_variation("IconToggle", "Button")
	th.set_stylebox("normal", "IconToggle",
		box(Color(0, 0, 0, 0), BORDER, R_INNER, 5, 3))
	th.set_stylebox("hover", "IconToggle",
		box(BG_HOVER, BORDER_HI, R_INNER, 5, 3))
	th.set_stylebox("pressed", "IconToggle",
		box(ACCENT_BG, ACCENT, R_INNER, 5, 3))
	th.set_stylebox("hover_pressed", "IconToggle",
		box(BG_ACTIVE, ACCENT_HI, R_INNER, 5, 3))
	th.set_stylebox("focus", "IconToggle",
		box(Color(0, 0, 0, 0), ACCENT_HI, R_INNER, 5, 3))
	th.set_color("font_color", "IconToggle", TEXT_MUTE)
	th.set_color("font_hover_color", "IconToggle", TEXT)
	th.set_color("font_pressed_color", "IconToggle", ACCENT_HI)
	th.set_color("font_hover_pressed_color", "IconToggle", Color("#ffffff"))

# —— 输入类控件 ——
static func _style_inputs(th: Theme) -> void:
	th.set_stylebox("normal", "LineEdit", box(BG_VOID, BORDER, R_INNER, 9, 5))
	th.set_stylebox("focus", "LineEdit", box(BG_VOID, ACCENT, R_INNER, 9, 5))
	th.set_stylebox("read_only", "LineEdit", box(BG_BASE, BORDER, R_INNER, 9, 5))
	th.set_color("font_color", "LineEdit", TEXT)
	th.set_color("font_placeholder_color", "LineEdit", Color(TEXT_MUTE, 0.8))
	th.set_color("caret_color", "LineEdit", ACCENT)
	th.set_color("selection_color", "LineEdit", Color(ACCENT, 0.3))
	th.set_constant("minimum_character_width", "LineEdit", 4)

	# OptionButton 继承 Button 的样式盒，只需补箭头留白与字体
	th.set_constant("arrow_margin", "OptionButton", 8)
	th.set_constant("modulate_arrow", "OptionButton", 1)
	th.set_color("font_color", "OptionButton", TEXT_SOFT)
	th.set_color("font_hover_color", "OptionButton", TEXT)
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		th.set_stylebox(state, "OptionButton", th.get_stylebox(state, "Button"))

	# SpinBox：内部是 LineEdit，补上下按钮留白
	th.set_constant("updown_icon_max_width", "SpinBox", 14)
	th.set_stylebox("up_background", "SpinBox", flat(BG_RAISED, R_INNER))
	th.set_stylebox("down_background", "SpinBox", flat(BG_RAISED, R_INNER))

	th.set_color("font_color", "CheckBox", TEXT_SOFT)
	th.set_color("font_hover_color", "CheckBox", TEXT)
	th.set_color("font_pressed_color", "CheckBox", TEXT)
	th.set_color("font_hover_pressed_color", "CheckBox", TEXT)
	th.set_constant("h_separation", "CheckBox", 8)
	# 勾选图形默认取图标的深色描边，深底上几乎看不见；显式指定一个浅色图标
	# 给勾选框：用自绘圆角方块代替引擎图标，未选=空框，选中=强调色实心+对勾
	var cb_off := _checkbox_icon(false)
	var cb_on := _checkbox_icon(true)
	for state in ["unchecked", "checked"]:
		th.set_icon(state, "CheckBox", cb_on if state == "checked" else cb_off)
	th.set_icon("unchecked_disabled", "CheckBox", cb_off)
	# 禁用且勾选 = 灰化对勾（旧实现复用未选中图标，看起来像没勾）
	th.set_icon("checked_disabled", "CheckBox", _checkbox_icon(true, true))
	th.set_constant("check_v_offset", "CheckBox", 0)
	# CheckBox 继承 Button 的样式盒，不覆盖就会画出一个假的按钮底框。
	# 勾选框本身已有独立图形，这里把底框全部清空。
	var no_box := box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0, 0, 0)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		th.set_stylebox(state, "CheckBox", no_box)
	# 滚动条与进度条主题化——深底上不再回落引擎默认浅灰
	for sbt in ["HScrollBar", "VScrollBar"]:
		th.set_stylebox("scroll", sbt, flat(BG_PANEL, 4))
		th.set_stylebox("grabber", sbt, box(BG_RAISED, BORDER, 4, 3, 3))
		th.set_stylebox("grabber_highlight", sbt, box(BG_RAISED, ACCENT, 4, 3, 3))
		th.set_stylebox("grabber_pressed", sbt, box(BG_RAISED, ACCENT_HI, 4, 3, 3))
	th.set_stylebox("background", "ProgressBar", box(BG_PANEL, BORDER, 4, 3, 3))
	th.set_stylebox("fill", "ProgressBar", flat(ACCENT, 4))
	th.set_color("font_color", "ProgressBar", TEXT_DIM)
	th.set_stylebox("normal", "CheckButton", no_box)
	th.set_stylebox("hover", "CheckButton", no_box)
	th.set_stylebox("pressed", "CheckButton", no_box)
	th.set_stylebox("hover_pressed", "CheckButton", no_box)

## 勾选框图标：深底可见的空心框 / 强调色描边带对勾，16×16 自绘
static func _checkbox_icon(checked: bool, muted := false) -> ImageTexture:
	const S := 16
	var img := Image.create(S, S, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var fill := Color(BG_VOID)
	var edge := (BORDER if muted else ACCENT) if checked else BORDER_HI
	# 实心底：1px 内缩，四角各让 1px 做出轻微圆角
	for y in range(1, S - 1):
		for x in range(1, S - 1):
			if (x == 1 or x == S - 2) and (y == 1 or y == S - 2):
				continue
			img.set_pixel(x, y, fill)
	# 描边
	for i in range(1, S - 1):
		img.set_pixel(i, 1, edge)
		img.set_pixel(i, S - 2, edge)
		img.set_pixel(1, i, edge)
		img.set_pixel(S - 2, i, edge)
	if checked:
 # 对勾：短笔 + 长笔，两像素粗以保证小尺寸下可辨；禁用态灰化
		var tick := Color(1, 1, 1, 0.45) if muted else Color.WHITE
		for i in 4:
			img.set_pixel(4 + i, 8, tick)
			img.set_pixel(4 + i, 9, tick)
		for i in 5:
			img.set_pixel(7 + i, 8 - i, Color.WHITE)
			img.set_pixel(7 + i, 9 - i, Color.WHITE)
	return ImageTexture.create_from_image(img)

# —— 列表 / 树 ——
static func _style_lists(th: Theme) -> void:
	var panel := box(BG_VOID, BORDER, R_INNER, 4, 4)
	th.set_stylebox("panel", "ItemList", panel)
	th.set_stylebox("focus", "ItemList", box(Color(0, 0, 0, 0), ACCENT, R_INNER, 0, 0))
	th.set_stylebox("selected", "ItemList", box(ACCENT_BG, Color(0, 0, 0, 0), R_INNER, 4, 3))
	th.set_stylebox("selected_focus", "ItemList", box(ACCENT_BG, ACCENT, R_INNER, 4, 3))
	th.set_stylebox("hovered", "ItemList", box(BG_RAISED, Color(0, 0, 0, 0), R_INNER, 4, 3))
	th.set_stylebox("cursor", "ItemList", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), R_INNER, 0, 0))
	th.set_stylebox("cursor_unselected", "ItemList", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), R_INNER, 0, 0))
	th.set_color("font_color", "ItemList", TEXT_DIM)
	th.set_color("font_selected_color", "ItemList", TEXT)
	th.set_color("font_hovered_color", "ItemList", TEXT)
	th.set_color("guide_color", "ItemList", Color(BORDER, 0.6))
	th.set_constant("v_separation", "ItemList", 4)
	th.set_constant("h_separation", "ItemList", 6)
	th.set_constant("icon_margin", "ItemList", 6)
	th.set_constant("line_separation", "ItemList", 2)

# —— Tab 页面 ——
static func _style_tabs(th: Theme) -> void:
	var bar_bg := flat(BG_BASE, 0)
	th.set_stylebox("tabbar_background", "TabContainer", bar_bg)
	th.set_stylebox("panel", "TabContainer", box(BG_PANEL, BORDER, R_CONTAINER, 8, 8))

	var unsel := box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), R_INNER, 10, 6)
	th.set_stylebox("tab_unselected", "TabContainer", unsel)
	th.set_stylebox("tab_hovered", "TabContainer", box(BG_RAISED, Color(0, 0, 0, 0), R_INNER, 10, 6))
	th.set_stylebox("tab_disabled", "TabContainer", unsel)
	# 选中页签：强调色上沿 + 浮起底，当前页一眼可辨
	var sel := box(BG_RAISED, Color(0, 0, 0, 0), R_INNER, 10, 6)
	sel.border_width_top = 2
	sel.border_color = ACCENT
	th.set_stylebox("tab_selected", "TabContainer", sel)

	th.set_color("font_unselected_color", "TabContainer", TEXT_MUTE)
	th.set_color("font_hovered_color", "TabContainer", TEXT_DIM)
	th.set_color("font_selected_color", "TabContainer", TEXT)
	th.set_color("font_disabled_color", "TabContainer", Color(TEXT_MUTE, 0.4))
	th.set_constant("side_margin", "TabContainer", 4)
	th.set_constant("tab_separation", "TabContainer", 2)

# —— 容器 / 分隔线 ——
static func _style_containers(th: Theme) -> void:
	th.set_stylebox("panel", "PanelContainer", box(BG_PANEL, BORDER, R_CONTAINER, 8, 8))
	th.set_stylebox("panel", "Panel", box(BG_PANEL, BORDER, R_CONTAINER, 8, 8))

	# 分隔线用极低对比的一根线，只做呼吸感，不做视觉噪音
	th.set_stylebox("separator", "HSeparator", flat(BORDER, 0))
	th.set_constant("separation", "HSeparator", 8)
	th.set_stylebox("separator", "VSeparator", flat(BORDER, 0))
	th.set_constant("separation", "VSeparator", 10)

	th.set_stylebox("panel", "ScrollContainer", flat(Color(0, 0, 0, 0), 0))

# —— 弹窗 / 提示 ——
static func _style_popups(th: Theme) -> void:
	# 浮起层：比面板浅一档 + 明显边框 + 投影，明确「浮在上面」
	var pop_bg := box(BG_PANEL, BORDER_HI, R_CONTAINER, 14, 12, 1, 12)
	th.set_stylebox("panel", "PopupPanel", pop_bg)
	th.set_stylebox("panel", "PopupMenu", box(BG_PANEL, BORDER_HI, R_CONTAINER, 6, 6, 1, 10))
	th.set_stylebox("hover", "PopupMenu", box(ACCENT_BG, Color(0, 0, 0, 0), R_INNER, 6, 4))
	th.set_stylebox("separator", "PopupMenu", flat(BORDER, 0))
	th.set_color("font_color", "PopupMenu", TEXT_DIM)
	th.set_color("font_hover_color", "PopupMenu", TEXT)
	th.set_color("font_separator_color", "PopupMenu", TEXT_MUTE)
	th.set_constant("v_separation", "PopupMenu", 4)
	th.set_constant("item_start_padding", "PopupMenu", 8)
	th.set_constant("item_end_padding", "PopupMenu", 8)

	# 对话框与文件选择框共用同一套面板底
	for t in ["AcceptDialog", "ConfirmationDialog", "FileDialog"]:
		th.set_stylebox("panel", t, box(BG_PANEL, BORDER_HI, R_CONTAINER, 14, 12, 1, 16))
		th.set_color("font_color", t, TEXT)
		th.set_constant("buttons_separation", t, 8)
		th.set_constant("margin", t, 12)

	# 工具提示：深底细边，小字号
	th.set_stylebox("panel", "TooltipPanel", box(BG_VOID, BORDER_HI, R_INNER, 8, 5, 1, 6))
	th.set_color("font_color", "TooltipLabel", TEXT_DIM)
	th.set_font_size("font_size", "TooltipLabel", FS_SMALL)

# —— 文本 ——
static func _style_labels(th: Theme) -> void:
	th.set_color("font_color", "Label", TEXT_DIM)
	th.set_font_size("font_size", "Label", FS_BASE)
	th.set_color("font_color", "RichTextLabel", TEXT_DIM)
	th.set_font_size("normal_font_size", "RichTextLabel", FS_BASE)
