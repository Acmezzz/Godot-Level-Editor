extends VBoxContainer
## 内容抽屉：停靠在关卡编辑器右侧，编辑「当前选中实体」的内容组。
## 与全屏内容库的关系：这里是入口（实例为主），内容库是共享池（库为辅）。
## 两者读写同一批 JSON，所以这里改的对话/商店立刻就是库里的资源，可被别处复用。
##
## 编辑器控制器（src/ui/content_editors/*）只认下面这套宿主接口：
##   body / data / id / kind / manifest / id_row() / commit() / rebuild()
##   schema() / open_kind() / create_in_kind()
## 所以同一个对话编辑器既能跑在全屏内容库里，也能跑在这个抽屉里。

signal closed

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentTemplates := preload("res://src/content/content_templates.gd")
const DefModel := preload("res://src/content/def_model.gd")
const DialogueEditor := preload("res://src/ui/content_editors/dialogue_editor.gd")
const EventEditor := preload("res://src/ui/content_editors/event_editor.gd")
const ShopEditor := preload("res://src/ui/content_editors/shop_editor.gd")

## 组件名 → 内容种类 / 中文名
const SLOTS := [
	{"comp": "dialogue", "kind": "dialogues", "label": "对话"},
	{"comp": "interact_event", "kind": "events", "label": "互动事件"},
	{"comp": "shop", "kind": "shops", "label": "商店"},
]
## 槽位里能就地编辑的种类（enemy_profile 等仍未建模）
const EDITORS := {
	"dialogues": "dialogue_editor",
	"events": "event_editor",
	"shops": "shop_editor",
}

var app   # 宿主（app.gd）
var manifest := {}

var body: VBoxContainer
var header: VBoxContainer
var _editors := {}
var _kind := "dialogues"
var _id := ""
var _data: Dictionary = {}
var _def_id := ""
## 校验徽章节点（每次 _validate 前清空，避免连点保存后徽章堆积）
var _issue_nodes: Array = []
## 抽屉「放大/还原」按钮引用（toggle_wide 改文案用）
var _wide_btn: Button

# 编辑器控制器要求的宿主接口
var data: Dictionary:
	get: return _data
	set(value): _data = value
var id: String:
	get: return _id
	set(value): _id = value
var kind: String:
	get: return _kind
	set(value): _kind = value

func _init(host) -> void:
	app = host
	manifest = host.manifest
	# 抽屉默认加宽到 480：360 宽时对话节点卡片里的多行控件全被挤成两行
	custom_minimum_size = Vector2(DOCK_W, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)
	# 抽屉是 VBoxContainer，没有 panel stylebox，自己画底色 + 左侧分隔线
	queue_redraw()
	# 这四个控制器与全屏内容库共用：它们只认宿主接口，不关心外面是全屏还是抽屉
	_editors = {
		"dialogues": DialogueEditor.new(self),
		"events": EventEditor.new(self),
		"shops": ShopEditor.new(self),
	}
	_build_shell()

## 抽屉默认宽度（R4：360 → 480，写作时字段不再被挤成两行）
const DOCK_W := 480.0
## 放大态宽度：写作时展开占画布区。上限受「左栏 252 + 画布最小 320 + 右栏 340」约束——
## 超过约 620 就会把检查器挤出屏幕（实测 900 时右栏宽度归零）。
const DOCK_W_WIDE := 620.0
var _wide := false

## 放大 / 还原：写作时抽屉占画布区，读图时收回
func toggle_wide() -> void:
	_wide = not _wide
	custom_minimum_size = Vector2(DOCK_W_WIDE if _wide else DOCK_W, 0)
	if _wide_btn:
		_wide_btn.text = "还原" if _wide else "放大"
		_wide_btn.tooltip_text = "收回常规宽度" if _wide else "展开占画布区（写作时更宽）"

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Th.BG_PANEL)
	draw_line(Vector2.ZERO, Vector2(0, size.y), Th.BORDER, 1.0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

## 外壳：标题行 / 实体头 / 槽位区 / 就地编辑区
func _build_shell() -> void:
	var top := Kit.hbox(8)
	top.add_child(Kit.text_label("内容", Th.TEXT, Th.FS_LG))
	top.add_child(Kit.spacer())
	_wide_btn = Kit.button("放大", func(): toggle_wide(), "ghost")
	_wide_btn.tooltip_text = "展开占画布区（写作时更宽）"
	top.add_child(_wide_btn)
	var hide_btn := Kit.button("收起", func(): close(), "ghost")
	hide_btn.tooltip_text = "收起抽屉（Enter 在选中实体时可再次打开）"
	top.add_child(hide_btn)
	add_child(top)
	header = Kit.vbox(6)
	add_child(header)
	add_child(Kit.divider())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_right", 10)
	scroll.add_child(margin)
	body = Kit.vbox(10)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(body)
	open_for("")

func close() -> void:
	closed.emit()

# —— 对外入口：按实体打开 ——
## 打开某个实体的内容组。没有组时给「创建」入口，而不是空白。
func open_for(def_id: String) -> void:
	_def_id = def_id
	_clear(header)
	_clear(body)
	if def_id == "":
		header.add_child(Kit.empty_state("◇", "未选中实体",
			"用「属性」工具点画布上的实体，在这里给它写对话/事件/商店"))
		return
	var definition := ContentStore.read(manifest, "defs", def_id)
	if definition.is_empty():
		header.add_child(Kit.badge("内容组缺失: " + def_id, Th.ERR))
		return
	var name := str(definition.get("name", def_id))
	var sid := str(definition.get("kind", ""))
	var head := Kit.hbox(6)
	head.add_child(Kit.text_label(name if name != "" else def_id, Th.TEXT, Th.FS_MD))
	head.add_child(Kit.badge(sid, Th.TEXT_MUTE))
	header.add_child(head)
	header.add_child(Kit.text_label("内容组 " + def_id, Th.TEXT_MUTE, Th.FS_META))
	_render_slots(definition)

## 内容组被创建/切换后由属性面板调用
func refresh() -> void:
	open_for(_def_id)

func current_def() -> String:
	return _def_id

# —— 槽位区：一个组件一块，里面按顺序列多条目 ——
## 顺序即匹配优先级：游戏取第一条「条件满足且没播过」的。
func _render_slots(definition: Dictionary) -> void:
	for slot in SLOTS:
		body.add_child(_slot_block(str(slot.comp), str(slot.kind), str(slot.label), definition))

func _slot_block(comp: String, kind_key: String, label: String, definition: Dictionary) -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", Th.box(Th.BG_BASE, Th.BORDER, Th.R_CONTAINER, 8, 6))
	var col := Kit.vbox(4)
	wrap.add_child(col)
	var top := Kit.hbox(6)
	top.add_child(Kit.text_label(label, Th.TEXT_DIM, Th.FS_SMALL))
	top.add_child(Kit.spacer())
	top.add_child(Kit.button("+  条目", func(): _new_for(comp, kind_key), "ghost"))
	col.add_child(top)

	var items := DefModel.items_of(definition, comp)
	if items.is_empty():
		col.add_child(Kit.hint_label("未配置", 320))
		var add_row := Kit.hbox(6)
		add_row.add_child(Kit.button("选已有…", func(): _pick(comp, kind_key, label), "ghost"))
		col.add_child(add_row)
		return wrap
	if items.size() > 1:
		col.add_child(Kit.hint_label("按顺序匹配：命中第一条「条件满足且没播过」的", 320))
	for i in items.size():
		col.add_child(_item_row(comp, kind_key, label, i, items[i], items.size()))
	# F2（批次 12）：选已有常驻——非空槽位也能追加共享资源（与文档承诺对齐）
	var pick_row := Kit.hbox(6)
	pick_row.add_child(Kit.button("选已有…", func(): _pick(comp, kind_key, label), "ghost"))
	col.add_child(pick_row)
	return wrap

## 单条：id / 播放语义 / 条件 / 顺序调整 / 删除 / 编辑
func _item_row(comp: String, kind_key: String, label: String, index: int,
		entry: Dictionary, total: int) -> Control:
	var col := Kit.vbox(3)
	var res_id := str(entry.get("id", ""))
	var once := bool(entry.get("once", false))
	var when := str(entry.get("when", ""))

	var head := Kit.hbox(6)
	head.add_child(Kit.text_label("%d" % (index + 1), Th.TEXT_MUTE, Th.FS_META))
	head.add_child(Kit.badge(res_id, Th.ACCENT_HI))
	head.add_child(Kit.badge("一次性" if once else "可重复", Th.WARN if once else Th.TEXT_MUTE))
	if when != "":
		head.add_child(Kit.badge("需要 " + when, Th.ACCENT))
	head.add_child(Kit.spacer())
	if index > 0:
		head.add_child(Kit.button("↑", func(): _move_item(comp, index, -1), "ghost"))
	if index < total - 1:
		head.add_child(Kit.button("↓", func(): _move_item(comp, index, 1), "ghost"))
	head.add_child(Kit.del_button(func(): _remove_item(comp, index), "从槽位移除这份资源（资源本身还在库里）"))
	col.add_child(head)

	var opts := Kit.hbox(6)
	opts.add_child(Kit.button("编辑", func(): _edit(comp, kind_key, res_id), "plain"))
	var toggle := CheckBox.new()
	toggle.text = "播完不再出现"
	toggle.button_pressed = once
	toggle.toggled.connect(func(on: bool): _set_item_field(comp, index, "once", on))
	opts.add_child(toggle)
	col.add_child(opts)

	var when_edit := LineEdit.new()
	when_edit.text = when
	when_edit.placeholder_text = "前置 flag（留空 = 无条件）"
	when_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	when_edit.focus_exited.connect(func():
		_set_item_field(comp, index, "when", when_edit.text.strip_edges()))
	col.add_child(when_edit)
	return col

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

# —— 绑定与切换 ——
## 从库里挑一个已有资源追加到这个槽位（共享：别的实体也能指同一份）
func _pick(comp: String, kind_key: String, label: String) -> void:
	var ids := ContentStore.list_ids(manifest, kind_key)
	if ids.is_empty():
		_new_for(comp, kind_key)
		return
	# 已经挂在这个槽位里的不再重复列出（同槽位重复引用会被校验报错）
	var taken := {}
	for entry in DefModel.items_of(_read_def(), comp):
		taken[str((entry as Dictionary).get("id", ""))] = true
	var available: Array = []
	for res_id in ids:
		if not taken.has(str(res_id)):
			available.append(res_id)
	if available.is_empty():
		# E7（批次 12）：提示走状态栏——往 header 加徽章会随点击堆积
		app._set_status("「%s」该种类的资源都已挂在这个槽位了" % label)
		return
	var shell: Dictionary = app._popup_body("添加%s" % label,
		"选中的资源会被多个实体共享；改一次，所有引用它的实体都变。")
	var pop: PopupPanel = shell.pop
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(app.POPUP_BODY_W, 220)
	for res_id in available:
		list.add_item(str(res_id))
	# R4：单击即选中（item_activated 要双击/回车，列表里点一下没反应像坏了）
	var take := func(idx: int):
		if idx < 0 or idx >= available.size():
			return
		pop.hide()
		_append_item(comp, {"id": str(available[idx])})
	list.item_clicked.connect(func(idx: int, _at: Vector2, _mb: int): take.call(idx))
	list.item_activated.connect(func(idx: int): take.call(idx))
	shell.body.add_child(list)
	var cancel_row := Kit.hbox(6)
	cancel_row.add_child(Kit.spacer())
	cancel_row.add_child(Kit.button("取消", func(): pop.hide(), "ghost"))
	shell.body.add_child(cancel_row)
	app._open_popup(pop)

## 往槽位追加一份资源并立刻绑定（id 带实体归属，便于识别来源）
func _new_for(comp: String, kind_key: String) -> void:
	var new_id := _make_id(kind_key, comp)
	if not ContentStore.write(manifest, kind_key, new_id, ContentTemplates.for_kind(kind_key)):
		header.add_child(Kit.badge("新建失败，检查内容目录权限", Th.ERR))
		return
	_append_item(comp, {"id": new_id})
	_edit(comp, kind_key, new_id)

func _make_id(kind_key: String, comp: String) -> String:
	var prefix := ContentTemplates.prefix_for(kind_key)
	# 归属前缀：<内容组 id>.<组件>，例 grp.town.e_42.dialogue
	var base := "%s.%s" % [_def_id, comp] if _def_id != "" else prefix
	var existing := ContentStore.list_ids(manifest, kind_key)
	if not existing.has(base):
		return base
	var i := 2
	while existing.has("%s.%d" % [base, i]):
		i += 1
	return "%s.%d" % [base, i]

# —— 内容组读写：统一走 _write_slot，避免每处各拼一遍 ——
func _read_def() -> Dictionary:
	if _def_id == "":
		return {}
	return ContentStore.read(manifest, "defs", _def_id)

func _write_slot(comp: String, items: Array) -> void:
	var definition := _read_def()
	if definition.is_empty():
		return
	var comps: Dictionary = definition.get("components", {}) if definition.get("components", {}) is Dictionary else {}
	if items.is_empty():
		comps.erase(comp)
	else:
		comps[comp] = items
	definition["components"] = comps
	ContentStore.write(manifest, "defs", _def_id, definition)
	app._mark_def_used(_def_id)
	refresh()

func _append_item(comp: String, entry: Dictionary) -> void:
	var items := DefModel.items_of(_read_def(), comp)
	items.append(entry.duplicate(true))
	_write_slot(comp, items)

## 单条字段编辑：once / when 都走这里；空值删键，保持 JSON 干净
func _set_item_field(comp: String, index: int, key: String, value) -> void:
	var items := DefModel.items_of(_read_def(), comp)
	if index < 0 or index >= items.size():
		return
	var entry: Dictionary = items[index]
	var empty: bool = (not bool(value)) if value is bool else str(value).strip_edges() == ""
	if empty:
		entry.erase(key)
	else:
		entry[key] = value
	items[index] = entry
	_write_slot(comp, items)

func _remove_item(comp: String, index: int) -> void:
	var items := DefModel.items_of(_read_def(), comp)
	if index < 0 or index >= items.size():
		return
	items.remove_at(index)
	_write_slot(comp, items)

## 顺序就是匹配优先级，所以上下移动是一等操作
func _move_item(comp: String, index: int, delta: int) -> void:
	var items := DefModel.items_of(_read_def(), comp)
	var target := index + delta
	if index < 0 or index >= items.size() or target < 0 or target >= items.size():
		return
	var entry = items[index]
	items.remove_at(index)
	items.insert(target, entry)
	_write_slot(comp, items)

func _edit(comp: String, kind_key: String, res_id: String) -> void:
	kind = kind_key
	id = res_id
	data = ContentStore.read(manifest, kind_key, res_id)
	if data.is_empty():
		header.add_child(Kit.badge("资源读取失败: " + res_id, Th.ERR))
		return
	_render_editor()

## 就地渲染编辑器：抽屉里替换内容区，地图和实体仍然可见
func _render_editor() -> void:
	_clear(body)
	var back := Kit.hbox(6)
	back.add_child(Kit.text_label("编辑中：", Th.TEXT_MUTE, Th.FS_META))
	back.add_child(Kit.badge(id + " · " + str(kind), Th.ACCENT))
	back.add_child(Kit.spacer())
	back.add_child(Kit.button("← 返回槽位", func(): refresh(), "ghost"))
	body.add_child(back)
	var editor = _editors.get(kind)
	if editor == null:
		body.add_child(Kit.hint_label("该种类暂不支持就地编辑。", 320))
		body.add_child(Kit.button("在全屏内容库里打开", func(): app._open_content_at(kind, id), "plain"))
		return
	editor.render()
	_validate()

# —— 编辑器控制器要求的宿主接口 ——
func commit() -> void:
	if _data.is_empty():
		return
	if not ContentStore.write(manifest, kind, id, _data):
		body.add_child(Kit.badge("写盘失败，检查内容目录权限", Th.ERR))
		return
	_validate()

func rebuild() -> void:
	if _data.is_empty():
		return
	_render_editor()

func schema() -> Dictionary:
	return ContentStore.read(manifest, "schema", ContentStore.SCHEMA_ID)

func open_kind(next_kind: String, res_id: String) -> void:
	kind = next_kind
	id = res_id
	data = ContentStore.read(manifest, next_kind, res_id)
	_render_editor()

func create_in_kind(next_kind: String) -> void:
	var new_id := _make_id(next_kind, "extra")
	if not ContentStore.write(manifest, next_kind, new_id, ContentTemplates.for_kind(next_kind)):
		return
	open_kind(next_kind, new_id)

## 资源 id 一行：抽屉里只给「打开内容库」与「删除」，重命名仍归内容库
func id_row() -> Control:
	var row := Kit.field_row("资源 id", Kit.text_label(id, Th.TEXT, Th.FS_SMALL), Kit.LABEL_W)
	row.add_child(Kit.button("内容库中打开",
		func(): app._open_content_at(kind, id), "ghost"))
	return row

func _validate() -> void:
	if _data.is_empty():
		return
	# P0-2：每次校验先清掉上一轮的徽章——旧实现只追加不清理，连点保存会堆成一列
	for c in _issue_nodes:
		if is_instance_valid(c):
			body.remove_child(c)
			c.queue_free()
	_issue_nodes.clear()
	var issues: Array = []
	var DialogueModel := preload("res://src/content/dialogue_model.gd")
	var EventModel := preload("res://src/content/event_model.gd")
	var ShopModel := preload("res://src/content/shop_model.gd")
	match kind:
		"dialogues": issues = DialogueModel.validate(_data)
		"events": issues = EventModel.validate(_data, schema())
		"shops": issues = ShopModel.validate(_data, ShopModel.item_index(manifest))
		_: pass
	if issues.is_empty():
		_issue_nodes.append(_push(Kit.badge("校验通过", Th.OK)))
		return
	for issue in issues:
		var is_error := str((issue as Dictionary).get("level", "warn")) == "error"
		var color: Color = Th.ERR if is_error else Th.WARN
		var row := Kit.hbox(8)
		row.add_child(Kit.badge("错误" if is_error else "警告", color))
		row.add_child(Kit.text_label(
			"%s — %s" % [str((issue as Dictionary).get("field", "")),
				str((issue as Dictionary).get("message", ""))], Th.TEXT_DIM, Th.FS_SMALL))
		_issue_nodes.append(_push(row))

## 追加到 body 并登记（校验徽章统一回收）
func _push(c: Control) -> Control:
	body.add_child(c)
	return c