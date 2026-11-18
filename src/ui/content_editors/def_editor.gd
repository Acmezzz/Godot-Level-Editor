extends RefCounted
## 定义编辑器：名称 / 种类 / 外观来源 + 组件引用（每个组件一个资源下拉）。
## 同一实体可挂多个组件；游戏侧互动优先级 互动事件 > 对话 > 商店。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const DefModel := preload("res://src/content/def_model.gd")

var host

func _init(host_ref) -> void:
	host = host_ref

func render() -> void:
	var body: VBoxContainer = host.body
	body.add_child(host.id_row())
	body.add_child(_name_row())
	body.add_child(_kind_row())
	body.add_child(_visual_row("prefab", "预制体"))
	body.add_child(_visual_row("thumb", "缩略图"))
	body.add_child(Kit.divider())
	body.add_child(Kit.section_label("组件"))
	body.add_child(Kit.hint_label(
		"同一实体可挂多个组件；互动优先级：互动事件 > 对话 > 商店。", 520))
	for comp in DefModel.components_list(host.manifest):   # H4：声明优先
		body.add_child(_component_row(str(comp)))

func _name_row() -> Control:
	var edit := LineEdit.new()
	edit.text = str(host.data.get("name", ""))
	edit.placeholder_text = "显示名"
	edit.focus_exited.connect(func():
		host.data["name"] = edit.text.strip_edges()
		host.commit())
	return Kit.field_row("名称", edit, Kit.LABEL_W)

func _kind_row() -> Control:
	var kinds: Array = []
	for entity in host.manifest.get("entities", []):
		if entity is Dictionary:
			kinds.append(str((entity as Dictionary).get("id", "")))
	var opt := OptionButton.new()
	opt.add_item("(未设置)")
	for k in kinds:
		opt.add_item(str(k))
	var cur := str(host.data.get("kind", ""))
	opt.select(kinds.find(cur) + 1 if kinds.has(cur) else 0)
	opt.item_selected.connect(func(idx: int):
		if idx == 0:
			host.data.erase("kind")
		else:
			host.data["kind"] = str(kinds[idx - 1])
		host.commit())
	return Kit.field_row("种类", opt, Kit.LABEL_W)

func _visual_row(key: String, label: String) -> Control:
	var edit := LineEdit.new()
	edit.text = str(host.data.get(key, ""))
	edit.placeholder_text = "相对游戏工程根目录"
	edit.focus_exited.connect(func():
		var t := edit.text.strip_edges()
		if t == "":
			host.data.erase(key)
		else:
			host.data[key] = t
		host.commit())
	return Kit.field_row(label, edit, Kit.LABEL_W)

func _components() -> Dictionary:
	var components = host.data.get("components", {})
	return components if components is Dictionary else {}

## 一个组件一块：多条目按顺序排列，顺序即匹配优先级
func _component_row(comp: String) -> Control:
	var col := Kit.vbox(3)
	var head := Kit.hbox(8)
	head.add_child(Kit.text_label(_component_name(comp), Th.TEXT_DIM, Th.FS_SMALL))
	head.add_child(Kit.spacer())
	var kind := DefModel.component_kind(host.manifest, comp)   # H4：声明优先
	if kind == "":
		# enemy_profile 等尚未建模的组件：只保留键，不提供编辑
		head.add_child(Kit.hint_label("（暂未建模，保留键）", 200))
		col.add_child(head)
		return col
	head.add_child(Kit.button("+  条目", func(): _add_item(comp), "ghost"))
	col.add_child(head)
	var items := DefModel.items_of(host.data, comp)
	if items.is_empty():
		col.add_child(Kit.hint_label("未配置", 300))
		return col
	if items.size() > 1:
		col.add_child(Kit.hint_label("按顺序匹配：命中第一条「条件满足且没播过」的", 300))
	for i in items.size():
		col.add_child(_item_row(comp, kind, i, items[i], items.size()))
	return col

func _item_row(comp: String, kind: String, index: int, entry: Dictionary, total: int) -> Control:
	var row := Kit.hbox(6)
	row.add_child(Kit.text_label("%d" % (index + 1), Th.TEXT_MUTE, Th.FS_META))
	var ids: Array = []
	for res_id in ContentStore.list_ids(host.manifest, kind):
		ids.append(str(res_id))
	var opt := OptionButton.new()
	opt.add_item("(无)")
	var cur := str(entry.get("id", ""))
	var sel := 0
	var listed := false
	for res_id in ids:
		opt.add_item(str(res_id))
		if str(res_id) == cur:
			sel = opt.item_count - 1
			listed = true
	if cur != "" and not listed:
		opt.add_item(cur + "  (不存在)")
		sel = opt.item_count - 1
	opt.select(sel)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.item_selected.connect(func(idx: int):
		_set_item_id(comp, index, "" if idx == 0 else opt.get_item_text(idx).replace("  (不存在)", "")))
	row.add_child(opt)

	var once := CheckBox.new()
	once.text = "一次性"
	once.button_pressed = bool(entry.get("once", false))
	once.toggled.connect(func(on: bool): _set_item_field(comp, index, "once", on))
	row.add_child(once)

	var when := LineEdit.new()
	when.text = str(entry.get("when", ""))
	when.placeholder_text = "前置 flag"
	when.custom_minimum_size = Vector2(110, 0)
	when.focus_exited.connect(func():
		_set_item_field(comp, index, "when", when.text.strip_edges()))
	row.add_child(when)

	var edit_btn := Kit.button("编辑",
		func(): host.open_kind(kind, str(entry.get("id", ""))), "ghost")
	edit_btn.disabled = cur == ""
	row.add_child(edit_btn)
	if index > 0:
		row.add_child(Kit.button("↑", func(): _move_item(comp, index, -1), "ghost"))
	if index < total - 1:
		row.add_child(Kit.button("↓", func(): _move_item(comp, index, 1), "ghost"))
	row.add_child(Kit.del_button(func(): _remove_item(comp, index), "从槽位移除这份资源（资源本身还在库里）"))
	return row

# —— 条目增删改：统一走 _write_slot ——
func _write_slot(comp: String, items: Array) -> void:
	var components := _components()
	if items.is_empty():
		components.erase(comp)
	else:
		components[comp] = items
	if components.is_empty():
		host.data.erase("components")
	else:
		host.data["components"] = components
	host.commit()
	host.rebuild()

func _add_item(comp: String) -> void:
	var items := DefModel.items_of(host.data, comp)
	items.append({"id": ""})
	_write_slot(comp, items)

func _set_item_id(comp: String, index: int, res_id: String) -> void:
	var items := DefModel.items_of(host.data, comp)
	if index < 0 or index >= items.size():
		return
	if res_id == "":
		# 选了 "(无)"：这条没意义了，直接移除；但保留首条空位以便继续填
		if items.size() > 1:
			items.remove_at(index)
		else:
			(items[index] as Dictionary).erase("id")
	else:
		(items[index] as Dictionary)["id"] = res_id
	_write_slot(comp, items)

func _set_item_field(comp: String, index: int, key: String, value) -> void:
	var items := DefModel.items_of(host.data, comp)
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
	var items := DefModel.items_of(host.data, comp)
	if index < 0 or index >= items.size():
		return
	items.remove_at(index)
	_write_slot(comp, items)

func _move_item(comp: String, index: int, delta: int) -> void:
	var items := DefModel.items_of(host.data, comp)
	var target := index + delta
	if index < 0 or index >= items.size() or target < 0 or target >= items.size():
		return
	var entry = items[index]
	items.remove_at(index)
	items.insert(target, entry)
	_write_slot(comp, items)

static func _component_name(comp: String) -> String:
	match comp:
		"dialogue": return "对话"
		"shop": return "商店"
		"interact_event": return "互动事件"
		"enemy_profile": return "敌人配置"
		_: return comp
