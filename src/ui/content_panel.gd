extends VBoxContainer
## 内容库界面：定义 / 对话 / 事件 / 商店的浏览与编辑入口。
## 与实体资产界面平级，由 app._set_mode("content") 切换。
##
## 本文件只是外壳：顶栏 / 种类页签 / 左侧列表 / 右侧内容区 + 保存与新建。
## 各类型的表单渲染在 src/ui/content_editors/ 下的控制器里，它们共用宿主接口：
##   host.data / host.manifest / host.id / host.kind
##   host.commit()   → 落盘 + 校验（编辑只改内存，提交才写盘）
##   host.rebuild()  → 重渲染 + 校验（增删条目后调用）
##   host.open_kind(kind, id) → 跳到其它资源

signal closed

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentTemplates := preload("res://src/content/content_templates.gd")
const DialogueModel := preload("res://src/content/dialogue_model.gd")
const EventModel := preload("res://src/content/event_model.gd")
const ShopModel := preload("res://src/content/shop_model.gd")
const DefModel := preload("res://src/content/def_model.gd")
const DialogueEditor := preload("res://src/ui/content_editors/dialogue_editor.gd")
const EventEditor := preload("res://src/ui/content_editors/event_editor.gd")
const ShopEditor := preload("res://src/ui/content_editors/shop_editor.gd")
const DefEditor := preload("res://src/ui/content_editors/def_editor.gd")

## 资源种类 → 显示名（顺序即页签顺序）
const KIND_LABELS := {
	"dialogues": "对话",
	"events": "事件",
	"shops": "商店",
	"defs": "定义",
}

## 内容表单最大宽度：超过这个宽度就居中留白，避免字段在宽屏里被拉散
const CONTENT_MAX_W := 720.0

var manifest := {}
var app = null  # 宿主 app（编辑器状态栏提示用，E3）
var _filter := ""  # A3.6 列表过滤词

var _kind := "dialogues"
var _id := ""
var _data: Dictionary = {}

var kind_bar: HBoxContainer
var id_list: ItemList
var body: VBoxContainer
var issue_box: VBoxContainer
var title_label: Label
var empty_hint: Label
var _editors := {}
## 以下是控制器要用的宿主接口（editor 脚本里直接 host.xxx 调用）
var data: Dictionary:
	get: return _data
	set(value): _data = value
var id: String:
	get: return _id
	set(value): _id = value
var kind: String:
	get: return _kind
	set(value): _kind = value

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Th.BG_BASE)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

func build() -> void:
	add_theme_constant_override("separation", 0)
	_editors = {
		"dialogues": DialogueEditor.new(self),
		"events": EventEditor.new(self),
		"shops": ShopEditor.new(self),
		"defs": DefEditor.new(self),
	}
	_build_kind_bar()
	var split := Kit.hbox(0)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	split.add_child(_build_list_column())
	split.add_child(_build_body_column())
	show_kind(_kind)

## 种类页签（对话/事件/商店/定义）：视图内的二级导航，外壳与返回钮在上层项目页
func _build_kind_bar() -> void:
	var wrap := PanelContainer.new()
	var sb := Th.box(Th.BG_PANEL, Th.BORDER, 0, 12, 6)
	sb.set_border_width_all(0)
	sb.border_width_bottom = 1
	wrap.add_theme_stylebox_override("panel", sb)
	add_child(wrap)
	kind_bar = Kit.hbox(4)
	wrap.add_child(kind_bar)
	for kind_key in KIND_LABELS:
		var btn := Kit.button(str(KIND_LABELS[kind_key]), func(): show_kind(kind_key), "toggle")
		btn.set_meta("kind", kind_key)
		kind_bar.add_child(btn)

func _build_list_column() -> Control:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = Vector2(240, 0)
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sb := Th.box(Th.BG_PANEL, Th.BORDER, 0, 10, 10)
	sb.set_border_width_all(0)
	sb.border_width_right = 1
	wrap.add_theme_stylebox_override("panel", sb)
	var col := Kit.vbox(8)
	wrap.add_child(col)
	# 视图名 + 「+ 新建」下沉到列表列头：新建是列表级动作，放在它作用的对象旁边
	var head := Kit.hbox(6)
	title_label = Kit.section_label("")
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title_label)
	var new_btn := Kit.button("+ 新建", func(): _create_resource(), "ghost")
	new_btn.tooltip_text = "在当前种类下新建一条资源"
	head.add_child(new_btn)
	col.add_child(head)
	# A3.6：过滤框（id/显示名 contains，输入即刷）
	var fbox = LineEdit.new()
	fbox.placeholder_text = "搜索：id 或显示名"
	fbox.text_changed.connect(func(t: String):
		_filter = t
		refresh_list())
	col.add_child(fbox)
	id_list = ItemList.new()
	id_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	id_list.item_selected.connect(func(idx: int): _on_id_picked(idx))
	col.add_child(id_list)
	empty_hint = Kit.hint_label("", 210)
	col.add_child(empty_hint)
	return wrap

func _build_body_column() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 18)
	scroll.add_child(margin)
	# 内容最大宽度 720 居中：表单在 1680 宽窗口里拉满会散成两半，视线要横跳
	var row := Kit.hbox(0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(row)
	row.add_child(Kit.spacer())
	var col := Kit.vbox(12)
	col.custom_minimum_size = Vector2(CONTENT_MAX_W, 0)
	row.add_child(col)
	row.add_child(Kit.spacer())
	body = Kit.vbox(10)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(body)
	issue_box = Kit.vbox(4)
	col.add_child(issue_box)
	return scroll
# —— 列表与加载 ——
func show_kind(next_kind: String) -> void:
	_kind = next_kind
	_id = ""
	_data = {}
	if title_label != null:
		title_label.text = str(KIND_LABELS.get(next_kind, next_kind))
	for btn in kind_bar.get_children():
		if btn is Button:
			(btn as Button).button_pressed = str(btn.get_meta("kind", "")) == next_kind
	refresh_list()

func refresh_list(focus_id := "") -> void:
	if id_list == null:
		return
	id_list.clear()
	var ids := ContentStore.list_ids(manifest, _kind)
	# A3.6：过滤（id/显示名 contains）+ name 显示（契约 §1.2：名称优先、id 作副文本）
	var q := _filter.strip_edges().to_lower()
	var shown: Array = []
	for res_id in ids:
		var data := ContentStore.read(manifest, _kind, str(res_id))
		var nm := str(data.get("name", ""))
		if q != "" and not (str(res_id).to_lower().contains(q) or nm.to_lower().contains(q)):
			continue
		var label = (nm + "（" + str(res_id) + "）") if nm != "" else str(res_id)
		var it := id_list.add_item(label)
		id_list.set_item_metadata(it, str(res_id))
		shown.append(str(res_id))
	empty_hint.visible = ids.is_empty()
	empty_hint.text = "还没有内容。点右上「新建」创建第一个。" if ids.is_empty() else ("过滤后 0 项" if shown.is_empty() else "")
	if shown.is_empty():
		if ids.is_empty():
			_id = ""
			_data = {}
			_render()
		return
	var pick := ""
	if focus_id != "" and shown.has(focus_id):
		pick = str(focus_id)
	elif shown.has(str(_id)):
		pick = str(_id)
	else:
		pick = str(shown[0])
	_id = pick
	id_list.select(shown.find(pick))
	_load_current()

func _on_id_picked(idx: int) -> void:
	if idx < 0 or idx >= id_list.item_count:
		return
	_id = str(id_list.get_item_metadata(idx))
	_load_current()

func _load_current() -> void:
	_data = ContentStore.read(manifest, _kind, _id)
	_render()

# —— 渲染（委托给对应编辑器） ——
func _render() -> void:
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()
	_clear_issues()
	if _data.is_empty():
		body.add_child(Kit.empty_state("◌", "未选择资源", "左侧选一项，或右上新建"))
		return
	var editor = _editors.get(_kind)
	if editor != null:
		editor.render()
	_validate()

## 重渲染 + 校验（增删条目后调用；纯文本编辑不需要）
func rebuild() -> void:
	_render()

func _clear_issues() -> void:
	if issue_box == null:
		return
	for child in issue_box.get_children():
		issue_box.remove_child(child)
		child.queue_free()

## 就地校验当前资源，结果落在 body 下方，不额外跳页
func _validate() -> void:
	_clear_issues()
	if _data.is_empty() or issue_box == null:
		return
	var issues: Array = []
	match _kind:
		"dialogues": issues = DialogueModel.validate(_data)
		"events": issues = EventModel.validate(_data, schema())
		"shops": issues = ShopModel.validate(_data, ShopModel.item_index(manifest))
		"defs": issues = DefModel.validate(_data, manifest)
		_: pass
	if issues.is_empty():
		issue_box.add_child(Kit.badge("校验通过", Th.OK))
		return
	for issue in issues:
		issue_box.add_child(_issue_row(issue))

func _issue_row(issue: Dictionary) -> Control:
	var is_error := str(issue.get("level", "warn")) == "error"
	var color: Color = Th.ERR if is_error else Th.WARN
	var row := Kit.hbox(8)
	row.add_child(Kit.badge("错误" if is_error else "警告", color))
	row.add_child(Kit.text_label(
		"%s — %s" % [str(issue.get("field", "")), str(issue.get("message", ""))],
		Th.TEXT_DIM, Th.FS_SMALL))
	return row

func schema() -> Dictionary:
	return ContentStore.read(manifest, "schema", ContentStore.SCHEMA_ID)

## 编辑提交：只改内存 → 写盘 → 校验。不重建控件（重建会打断输入）。
func commit() -> void:
	if _data.is_empty():
		return
	if not ContentStore.write(manifest, _kind, _id, _data):
		issue_box.add_child(Kit.badge("写盘失败，检查内容目录权限", Th.ERR))
		return
	_validate()

## 跳到另一个资源（定义页的组件「编辑」按钮用）
func open_kind(next_kind: String, res_id: String) -> void:
	show_kind(next_kind)
	refresh_list(res_id)

## 跳到另一类并直接新建一个（事件参数里"该类还没有资源"时的入口）
func create_in_kind(next_kind: String) -> void:
	show_kind(next_kind)
	_create_resource()

## 各编辑器共用的「资源 id + 重命名」一行
func id_row() -> Control:
	var row := Kit.field_row("资源 id", Kit.text_label(_id, Th.TEXT, Th.FS_SMALL), Kit.LABEL_W)
	var rn := Kit.button("改名并迁移引用", func(): rename_current(), "ghost")
	rn.tooltip_text = "改资源 id（= 文件名）并同步改写所有引用；只改显示名用资产页"
	row.add_child(rn)
	row.add_child(Kit.button("删除", func(): delete_current(), "ghost"))
	return row

## 删除资源：先扫引用，有引用就列出来并要求确认，避免删掉被别人引用的对话/事件
func delete_current() -> void:
	if _data.is_empty():
		return
	var refs := ContentStore.find_references(manifest, _kind, _id)
	var dialog := AcceptDialog.new()
	dialog.title = "删除 " + _id
	var col := Kit.vbox(8)
	col.custom_minimum_size = Vector2(340, 0)
	col.add_child(Kit.wrap_label(
		"将删除 %s/%s.json，不可撤销。" % [_kind, _id], 340, Th.TEXT_DIM))
	if refs.is_empty():
		col.add_child(Kit.text_label("没有其它资源引用它。", Th.OK, Th.FS_SMALL))
	else:
		col.add_child(Kit.text_label("%d 处引用仍指向它：" % refs.size(), Th.WARN, Th.FS_SMALL))
		for ref in refs:
			col.add_child(Kit.text_label(
				"  %s/%s" % [str((ref as Dictionary).get("kind", "")), str((ref as Dictionary).get("id", ""))],
				Th.TEXT_MUTE, Th.FS_META))
		col.add_child(Kit.hint_label("删除后这些引用会变成悬空引用，校验页会报错。", 340))
	dialog.add_child(col)
	dialog.add_cancel_button("取消")
	dialog.confirmed.connect(func():
		dialog.queue_free()
		ContentStore.remove(manifest, _kind, _id)
		_id = ""
		_data = {}
		refresh_list())
	dialog.canceled.connect(func(): dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()
# —— 新建 / 重命名 ——
func _create_resource() -> void:
	var new_id := _unique_new_id()
	if not ContentStore.write(manifest, _kind, new_id, ContentTemplates.for_kind(_kind)):
		return
	refresh_list(new_id)

func _unique_new_id() -> String:
	var prefix := ContentTemplates.prefix_for(_kind)
	var existing := ContentStore.list_ids(manifest, _kind)
	var i := 1
	while existing.has("%s.%d" % [prefix, i]):
		i += 1
	return "%s.%d" % [prefix, i]

## 重命名：id 变了文件名要跟着变，先看有没有引用再决定
func rename_current() -> void:
	if _data.is_empty():
		return
	var shell: Dictionary = Kit.popup_shell("改名并迁移引用",
		"id 同时是文件名；改完会迁移所有引用。不动内容只改名用侧栏「重命名（不改引用）」。", app)
	var pop: PopupPanel = shell.pop
	var edit := LineEdit.new()
	edit.text = _id
	edit.custom_minimum_size = Vector2(320, 0)
	shell.body.add_child(edit)
	shell.body.add_child(Kit.popup_buttons(
		func():
			var next_id := edit.text.strip_edges()
			pop.hide()
			_apply_rename(next_id),
		func(): pop.hide()))
	edit.text_submitted.connect(func(_t: String):
		var next_id := edit.text.strip_edges()
		pop.hide()
		_apply_rename(next_id))
	app._open_popup(pop)

## 重命名落地：校验 id 合法性 → 迁移引用 → 刷新列表
func _apply_rename(next_id: String) -> void:
	if next_id == "" or next_id == _id or not ContentStore.is_valid_id(next_id):
		return
	if ContentStore.rename(manifest, _kind, _id, next_id):
		_id = next_id
		refresh_list(next_id)
	else:
		_clear_issues()
		issue_box.add_child(Kit.badge("重命名失败：目标 id 已存在或写入被拒", Th.ERR))