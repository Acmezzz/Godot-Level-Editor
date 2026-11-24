extends RefCounted
class_name UiKit
## 可复用 UI 构件：把「分段标题 / 空状态 / 字段行 / 徽章 / 弹窗按钮行」这类重复拼装收敛到一处。
##
## 全部返回已配好样式的 Control，调用方 add_child 即可。样式只在 UiTheme 里定义，
## 这里只做结构与语义组合，不写死色值（个别强调用 UiTheme 的公开常量）。

# —— 文本 ——
## 小节标题：小字号 + 字间距放开 + 弱色，用来分组而不是抢戏
static func section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UiTheme.FS_META)
	l.add_theme_color_override("font_color", UiTheme.TEXT_MUTE)
	return l

## 正文标签（可调色，用于「继承 / 覆盖」这类语义标记）
static func text_label(text: String, color: Color = UiTheme.TEXT_DIM, size: int = UiTheme.FS_BASE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

## 单行弱化说明（空状态下方的一行提示）
## wrap_w > 0 时会强制一个最小宽度：自动换行的 Label 在宽度未定时会被测成
## 近乎 0 宽、高度爆成几十行，进而把弹窗撑到一整屏。给死宽度即可避免。
static func hint_label(text: String, wrap_w := 0) -> Label:
	var l := text_label(text, UiTheme.TEXT_MUTE, UiTheme.FS_SMALL)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if wrap_w > 0:
		l.custom_minimum_size = Vector2(wrap_w, 0)
	return l

## 会换行的正文标签（比 hint_label 亮一档，用于弹窗里的结果/预告）
static func wrap_label(text: String, wrap_w: int, color: Color = UiTheme.TEXT_DIM,
		size: int = UiTheme.FS_SMALL) -> Label:
	var l := text_label(text, color, size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(wrap_w, 0)
	return l

# —— 空状态 ——
## 一个居中的空状态块：图标字符 + 主文案 + 可选辅助说明。
## 空列表只显示空白是体验缺口，这里给用户「下一步该做什么」。
static func empty_state(icon: String, title: String, hint := "") -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if icon != "":
		var il := text_label(icon, UiTheme.TEXT_MUTE, 30)
		il.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(il)
	var tl := text_label(title, UiTheme.TEXT_DIM, UiTheme.FS_SMALL)
	tl.name = "Title"
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(tl)
	if hint != "":
		var hl := text_label(hint, Color(UiTheme.TEXT_MUTE, 0.9), UiTheme.FS_META)
		hl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(hl)
	return box

# —— 按钮 ——
## 按语义创建按钮：primary / ghost / icon / tool / toggle / icon_toggle / plain
static func button(text: String, cb: Callable = Callable(), kind := "plain") -> Button:
	var b := Button.new()
	b.text = text
	match kind:
		"primary": b.theme_type_variation = "PrimaryButton"
		"ghost": b.theme_type_variation = "GhostButton"
		"icon": b.theme_type_variation = "IconButton"
		"tool":
			b.theme_type_variation = "ToolButton"
			b.toggle_mode = true
		"toggle":
			b.theme_type_variation = "ToggleButton"
			b.toggle_mode = true
		"icon_toggle":
			b.theme_type_variation = "IconToggle"
			b.toggle_mode = true
		_: pass
	if cb.is_valid():
		b.pressed.connect(cb)
	return b

# —— 布局 ——
## 水平行：需要让某个子控件撑满时用
static func hbox(separation := 6) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", separation)
	return h

## 垂直列
static func vbox(separation := 6) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", separation)
	return v

## 弹性撑开用的空白控件（把后续元素推到右边）
static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return c

## 一根 1px 水平分隔线（低对比，做视觉呼吸）
static func divider() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_constant_override("separation", 8)
	return s

## 一根垂直分隔线（顶栏分组用）
static func vdivider() -> VSeparator:
	var s := VSeparator.new()
	s.add_theme_constant_override("separation", 10)
	return s
## 「标签 + 控件」一行：标签固定宽度左对齐，控件撑满，保证多个字段视觉整齐
static func field_row(label: String, control: Control, label_w := 72) -> HBoxContainer:
	var h := hbox(8)
	var l := text_label(label, UiTheme.TEXT_MUTE, UiTheme.FS_SMALL)
	l.custom_minimum_size = Vector2(label_w, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(control)
	return h

static func highlight_field_row(row: Control) -> void:
	var style := UiTheme.box(Color(UiTheme.WARN, 0.14), UiTheme.WARN, UiTheme.R_INNER, 6, 3)
	row.set_meta("issue_highlight", true)
	row.draw.connect(func(): row.draw_style_box(style, Rect2(Vector2.ZERO, row.size)))
	row.queue_redraw()

## 分段头部：标题 + 右侧可选操作按钮
static func section_header(title: String, action: Button = null) -> HBoxContainer:
	var h := hbox(8)
	var l := section_label(title)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(l)
	if action != null:
		h.add_child(action)
	return h

## 状态徽章：小圆角底色块（用于「已配对」「文件缺失」这类标记）
## 两个方向都要 SHRINK：VBoxContainer 默认把子节点拉满宽度，
## 不写这一行的话一个小徽章会渲染成一整条横贯面板的色带（实证 N2）。
static func badge(text: String, color: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var sb := UiTheme.box(Color(color, 0.15), Color(color, 0.5), UiTheme.R_INNER, 6, 1)
	p.add_theme_stylebox_override("panel", sb)
	var l := text_label(text, color, UiTheme.FS_META)

	p.add_child(l)
	return p

## 原地更新徽章文字与颜色（用于「继承 → 覆盖」这类状态切换，避免重建整个面板）
static func set_badge(p: PanelContainer, text: String, color: Color) -> void:
	if p == null or not is_instance_valid(p):
		return
	var sb := UiTheme.box(Color(color, 0.15), Color(color, 0.5), UiTheme.R_INNER, 6, 1)
	p.add_theme_stylebox_override("panel", sb)
	for c in p.get_children():
		if c is Label:
			(c as Label).text = text
			(c as Label).add_theme_color_override("font_color", color)
			break

# —— 符号常量 ——
## 行级删除符号统一 ✕。其余符号（↑/↓/+、👁/🔒）直接写在调用处，未设常量。
const SYM_DEL := "✕"

## 行级删除钮：统一 ✕ + ghost + tooltip（删除必须有 tooltip 说明删的是什么）
static func del_button(cb: Callable, tip := "删除这一项") -> Button:
	var b := button(SYM_DEL, cb, "ghost")
	b.tooltip_text = tip
	return b

# —— 弹窗标准件 ——
## 弹窗底部按钮行：确定（primary）+ 取消（ghost），右对齐。
## 所有自建 PopupPanel 都该有取消出口——只有确定按钮的弹窗等于把用户逼上唯一路径。
static func popup_buttons(on_ok: Callable, on_cancel: Callable,
		ok_text := "确定", cancel_text := "取消") -> HBoxContainer:
	var row := hbox(8)
	row.add_child(spacer())
	row.add_child(button(cancel_text, on_cancel, "ghost"))
	row.add_child(button(ok_text, on_ok, "primary"))
	return row

# —— 字段标签宽度常量 ——
## 表单左标签固定两档：常用字段 72，长字段名 96。全库统一，视觉节奏才整齐。
const LABEL_W := 72
const LABEL_W_LONG := 96
