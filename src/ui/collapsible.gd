extends VBoxContainer
## 折叠区（重构 R2）：一个标题行（点击展开/收起）+ 内容体。
##
## 右栏底部三个项目级区块（实体大纲 / 校验 / 地图列表）都用它——
## 平时收起只占一行，需要时展开。
##
## 注意：结构在 _init 里就建好，不能用 _ready——宿主拿到实例后
## 立刻就要往 body 里填控件（还没入树，_ready 尚未触发）。

signal toggled(expanded: bool)

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")

var title := ""
var body: VBoxContainer
var expanded := true

var _head: Button
var _caret: Label

func _init(title_text: String, start_expanded := false) -> void:
	title = title_text
	expanded = start_expanded
	add_theme_constant_override("separation", 2)
	var row := Kit.hbox(4)
	_caret = Kit.text_label("▾" if expanded else "▸", Th.TEXT_MUTE, Th.FS_META)
	_caret.custom_minimum_size = Vector2(12, 0)
	row.add_child(_caret)
	_head = Kit.button(title, func(): set_expanded(not expanded), "ghost")
	_head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_head.add_theme_font_size_override("font_size", Th.FS_SMALL)
	row.add_child(_head)
	add_child(row)
	body = Kit.vbox(6)
	body.visible = expanded
	add_child(body)

func set_expanded(on: bool) -> void:
	if expanded == on:
		return
	expanded = on
	_caret.text = "▾" if expanded else "▸"
	body.visible = expanded
	toggled.emit(expanded)

## 一个折叠区改标题（例如带上条目数量）
func set_title(t: String) -> void:
	title = t
	if _head:
		_head.text = t
