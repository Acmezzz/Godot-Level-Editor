extends RefCounted
## 商店编辑器：条目行（物品 / 价格 / 库存）+ 货币。
## 清单有 items 时用下拉选物品，没有时退回手填 id。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ShopModel := preload("res://src/content/shop_model.gd")

var host

func _init(host_ref) -> void:
	host = host_ref

func render() -> void:
	var body: VBoxContainer = host.body
	body.add_child(host.id_row())
	var currency := LineEdit.new()
	currency.text = str(host.data.get("currency", ""))
	currency.placeholder_text = "gold（缺省）"
	currency.focus_exited.connect(func():
		var t := currency.text.strip_edges()
		if t == "":
			host.data.erase("currency")
		else:
			host.data["currency"] = t
		host.commit())
	body.add_child(Kit.field_row("货币", currency, Kit.LABEL_W))
	body.add_child(Kit.divider())
	var head := Kit.section_header("商品")
	head.add_child(Kit.button("+  条目", func(): _add_entry(), "ghost"))
	body.add_child(head)
	var entries := _entries()
	if entries.is_empty():
		body.add_child(Kit.hint_label("还没有商品条目。", 520))
		return
	for i in entries.size():
		body.add_child(_entry_row(i, entries[i]))

func _entries() -> Array:
	var entries = host.data.get("entries", [])
	return entries if entries is Array else []

func _entry_row(index: int, entry) -> Control:
	var row := Kit.hbox(6)
	if not (entry is Dictionary):
		row.add_child(Kit.badge("条目必须是对象", Th.ERR))
		return row
	var en: Dictionary = entry
	var known := ShopModel.item_index(host.manifest)
	if known.is_empty():
		var item_edit := LineEdit.new()
		item_edit.text = str(en.get("item", ""))
		item_edit.placeholder_text = "物品 id"
		item_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item_edit.focus_exited.connect(func():
			_set_entry_field(index, "item", item_edit.text.strip_edges()))
		row.add_child(item_edit)
	else:
		var opt := OptionButton.new()
		var ids: Array = [""]
		opt.add_item("(未设置)")
		var keys: Array = known.keys()
		keys.sort()
		for key in keys:
			ids.append(str(key))
			var info: Dictionary = known[key] if known[key] is Dictionary else {}
			opt.add_item("%s · %s" % [str(key), str(info.get("name", key))])
		var cur := str(en.get("item", ""))
		opt.select(ids.find(cur) if ids.has(cur) else 0)
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt.item_selected.connect(func(idx: int): _set_entry_field(index, "item", str(ids[idx])))
		row.add_child(opt)
	row.add_child(_number_edit("价格", float(en.get("price", 0)), func(v):
		_set_entry_field(index, "price", v)))
	row.add_child(_number_edit("库存", float(en.get("stock", -1)), func(v):
		# B5：库存按契约整数化提交（-1 无限 / >=0 有限）
		_set_entry_field(index, "stock", roundi(v))))
	row.add_child(Kit.del_button(func(): _delete_entry(index), "删除这条商店条目"))
	return row

## 数字输入：失焦/回车才提交，避免每击键都写盘
func _number_edit(placeholder: String, value: float, on_commit: Callable) -> LineEdit:
	var edit := LineEdit.new()
	edit.text = str(int(value)) if value == floor(value) else str(value)
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(72, 0)
	edit.focus_exited.connect(func():
		if _guard_number(edit.text):
			on_commit.call(_parse_number(edit.text, value)))
	edit.text_submitted.connect(func(t: String):
		if _guard_number(t):
			on_commit.call(_parse_number(t, value)))
	return edit

## E3：非法数字不再静默还原——状态栏提示（host.app 可用时）；空串 = 未改动放行
func _guard_number(t: String) -> bool:
	var x := t.strip_edges()
	if x == "" or x.is_valid_float() or x.is_valid_int():
		return true
	if host.app != null:
		host.app._set_status(" 价格/库存需为数字，已还原")
	return false

func _parse_number(text: String, fallback: float) -> float:
	var t := text.strip_edges()
	if not t.is_valid_float() and not t.is_valid_int():
		return fallback
	return float(t)

func _set_entry_field(index: int, key: String, value) -> void:
	var entries := _entries()
	if index < 0 or index >= entries.size() or not (entries[index] is Dictionary):
		return
	(entries[index] as Dictionary)[key] = value
	host.commit()

func _add_entry() -> void:
	var entries := _entries()
	var known := ShopModel.item_index(host.manifest)
	var first := ""
	if not known.is_empty():
		var keys: Array = known.keys()
		keys.sort()
		first = str(keys[0])
	entries.append({"item": first, "price": 0, "stock": -1})
	host.data["entries"] = entries
	host.commit()
	host.rebuild()

func _delete_entry(index: int) -> void:
	var entries := _entries()
	if index < 0 or index >= entries.size():
		return
	entries.remove_at(index)
	host.data["entries"] = entries
	host.commit()
	host.rebuild()
