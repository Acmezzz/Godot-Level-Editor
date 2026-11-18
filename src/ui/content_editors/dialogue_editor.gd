extends RefCounted
## 对话编辑器：节点卡片列表（id / 说话者 / 文本 / next / 选项 / 终止）。
## 宿主接口见 content_panel.gd 顶部注释；编辑改内存后由 host.commit() 落盘。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")

var host

func _init(host_ref) -> void:
	host = host_ref

func render() -> void:
	var body: VBoxContainer = host.body
	body.add_child(host.id_row())
	body.add_child(_start_row())
	body.add_child(Kit.divider())
	body.add_child(_speakers_section())
	body.add_child(Kit.divider())
	var head := Kit.section_header("节点")
	head.add_child(Kit.button("▶ 预演", func(): _dry_run(), "ghost"))
	head.add_child(Kit.button("+  节点", func(): _add_node(), "ghost"))
	body.add_child(head)
	var nodes := _nodes()
	if nodes.is_empty():
		body.add_child(Kit.hint_label("还没有节点。至少需要一个起始节点。", 520))
		return
	for i in nodes.size():
		body.add_child(_node_card(i, nodes[i]))

func _nodes() -> Array:
	var nodes = host.data.get("nodes", [])
	return nodes if nodes is Array else []

func _node_ids() -> Array:
	var out: Array = []
	for node in _nodes():
		if node is Dictionary:
			var nid := str((node as Dictionary).get("id", ""))
			if nid != "":
				out.append(nid)
	return out

## 节点下拉：空串 = 未设置/结束，其余为可选目标
func _target_option(current: String, empty_label: String) -> OptionButton:
	var opt := OptionButton.new()
	var ids: Array = [""]
	opt.add_item(empty_label)
	for nid in _node_ids():
		ids.append(str(nid))
		opt.add_item(str(nid))
	# E4：悬空引用直接显示（不再伪装成结束/未设置）；选中悬空项 = 保住原值
	if current != "" and not ids.has(current):
		opt.add_item(current + "  (不存在)")
		ids.append(current)
		opt.select(opt.item_count - 1)
	else:
		opt.select(ids.find(current) if ids.has(current) else 0)
	opt.set_meta("ids", ids)
	return opt

func _start_row() -> Control:
	var cur := str(host.data.get("start", ""))
	var opt := _target_option(cur, "(未设置)")
	var ids: Array = opt.get_meta("ids")
	opt.item_selected.connect(func(idx: int):
		host.data["start"] = str(ids[idx])
		host.commit())
	return Kit.field_row("起始节点", opt, Kit.LABEL_W)

func _set_node_field(index: int, field: String, value) -> void:
	var nodes := _nodes()
	if index < 0 or index >= nodes.size() or not (nodes[index] is Dictionary):
		return
	var node: Dictionary = nodes[index]
	if field == "end":
		if value:
			node["end"] = true
		else:
			node.erase("end")
	elif str(value) == "":
		node.erase(field)
	else:
		node[field] = value
	host.commit()

## 单个节点卡片
func _node_card(index: int, node) -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", Th.box(Th.BG_PANEL, Th.BORDER, Th.R_CONTAINER, 10, 8))
	var col := Kit.vbox(6)
	wrap.add_child(col)
	if not (node is Dictionary):
		col.add_child(Kit.badge("节点必须是对象", Th.ERR))
		return wrap
	var nd: Dictionary = node

	var head := Kit.hbox(8)
	head.add_child(Kit.text_label("#%d" % index, Th.TEXT_MUTE, Th.FS_META))
	var id_edit := LineEdit.new()
	id_edit.text = str(nd.get("id", ""))
	id_edit.placeholder_text = "节点 id"
	id_edit.custom_minimum_size = Vector2(96, 0)
	id_edit.tooltip_text = "节点 id（被 next/选项引用）"
	id_edit.text_submitted.connect(func(t: String):
		_set_node_field(index, "id", t.strip_edges()))
	id_edit.focus_exited.connect(func():
		_set_node_field(index, "id", id_edit.text.strip_edges()))
	head.add_child(id_edit)
	var end_check := CheckBox.new()
	end_check.text = "终止"
	end_check.button_pressed = bool(nd.get("end", false))
	end_check.toggled.connect(func(on: bool): _set_node_field(index, "end", on))
	head.add_child(end_check)
	head.add_child(Kit.spacer())
	head.add_child(Kit.button("删除", func(): _delete_node(index), "ghost"))
	col.add_child(head)

	col.add_child(_speaker_row(index, nd))
	col.add_child(_text_row(index, nd))
	col.add_child(_next_row(index, nd))
	col.add_child(_choices_section(index, nd))
	return wrap

func _speaker_row(index: int, nd: Dictionary) -> Control:
	var speakers: Dictionary = host.data.get("speakers", {}) if host.data.get("speakers") is Dictionary else {}
	var opt := OptionButton.new()
	var keys: Array = [""]
	opt.add_item("(旁白)")
	var sorted_keys: Array = speakers.keys()
	sorted_keys.sort()
	for key in sorted_keys:
		keys.append(str(key))
		var info: Dictionary = speakers[key] if speakers[key] is Dictionary else {}
		opt.add_item("%s · %s" % [str(key), str(info.get("name", key))])
	var cur := str(nd.get("speaker", ""))
	opt.select(keys.find(cur) if keys.has(cur) else 0)
	opt.item_selected.connect(func(idx: int): _set_node_field(index, "speaker", str(keys[idx])))
	return Kit.field_row("说话者", opt, Kit.LABEL_W)

func _text_row(index: int, nd: Dictionary) -> Control:
	var edit := TextEdit.new()
	edit.text = str(nd.get("text", ""))
	edit.custom_minimum_size = Vector2(0, 58)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit.focus_exited.connect(func(): _set_node_field(index, "text", edit.text))
	return Kit.field_row("文本", edit, Kit.LABEL_W)

func _next_row(index: int, nd: Dictionary) -> Control:
	var opt := _target_option(str(nd.get("next", "")), "(结束)")
	var ids: Array = opt.get_meta("ids")
	opt.item_selected.connect(func(idx: int): _set_node_field(index, "next", str(ids[idx])))
	return Kit.field_row("下一节点", opt, Kit.LABEL_W)

## 选项区块：每条 = 文本 + 目标节点 + 可选动作
func _choices_section(index: int, nd: Dictionary) -> Control:
	var col := Kit.vbox(4)
	var head := Kit.hbox(8)
	head.add_child(Kit.section_label("选项"))
	head.add_child(Kit.spacer())
	head.add_child(Kit.button("+  选项", func(): _add_choice(index), "ghost"))
	col.add_child(head)
	var choices = nd.get("choices", [])
	if not (choices is Array):
		return col
	for i in (choices as Array).size():
		col.add_child(_choice_row(index, i, (choices as Array)[i]))
	return col

func _choice_row(index: int, choice_index: int, choice) -> Control:
	var row := Kit.hbox(6)
	if not (choice is Dictionary):
		row.add_child(Kit.badge("选项必须是对象", Th.ERR))
		return row
	var ch: Dictionary = choice
	var text := LineEdit.new()
	text.text = str(ch.get("text", ""))
	text.placeholder_text = "选项文本"
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.text_submitted.connect(func(t: String):
		_set_choice_field(index, choice_index, "text", t))
	text.focus_exited.connect(func():
		_set_choice_field(index, choice_index, "text", text.text))
	row.add_child(text)
	var opt := _target_option(str(ch.get("next", "")), "(未设置)")
	var ids: Array = opt.get_meta("ids")
	opt.item_selected.connect(func(idx: int):
		_set_choice_field(index, choice_index, "next", str(ids[idx])))
	row.add_child(opt)
	var action := LineEdit.new()
	action.text = str(ch.get("action", ""))
	action.placeholder_text = "动作（可选）"
	action.custom_minimum_size = Vector2(120, 0)
	action.focus_exited.connect(func():
		_set_choice_field(index, choice_index, "action", action.text.strip_edges()))
	row.add_child(action)
	row.add_child(Kit.del_button(func(): _delete_choice(index, choice_index), "删除这个选项分支"))
	return row

func _set_choice_field(index: int, choice_index: int, field: String, value: String) -> void:
	var nodes := _nodes()
	if index < 0 or index >= nodes.size() or not (nodes[index] is Dictionary):
		return
	var choices = (nodes[index] as Dictionary).get("choices", [])
	if not (choices is Array) or choice_index < 0 or choice_index >= (choices as Array).size():
		return
	var ch = (choices as Array)[choice_index]
	if not (ch is Dictionary):
		return
	if value == "":
		(ch as Dictionary).erase(field)
	else:
		(ch as Dictionary)[field] = value
	host.commit()

# —— 增删 ——
func _add_node() -> void:
	var nodes := _nodes()
	var used := {}
	for nid in _node_ids():
		used[str(nid)] = true
	var i := 1
	while used.has("n%d" % i):
		i += 1
	var new_id := "n%d" % i
	nodes.append({"id": new_id, "speaker": "", "text": "", "next": ""})
	host.data["nodes"] = nodes
	if str(host.data.get("start", "")) == "":
		host.data["start"] = new_id
	host.commit()
	host.rebuild()

func _delete_node(index: int) -> void:
	var nodes := _nodes()
	if index < 0 or index >= nodes.size():
		return
	var removed := ""
	if nodes[index] is Dictionary:
		removed = str((nodes[index] as Dictionary).get("id", ""))
	nodes.remove_at(index)
	host.data["nodes"] = nodes
	# 起始节点被删：退到剩下的第一个，避免留悬空 start
	if str(host.data.get("start", "")) == removed:
		host.data["start"] = _node_ids()[0] if not _node_ids().is_empty() else ""
	host.commit()
	host.rebuild()

func _add_choice(index: int) -> void:
	var nodes := _nodes()
	if index < 0 or index >= nodes.size() or not (nodes[index] is Dictionary):
		return
	var node: Dictionary = nodes[index]
	var choices = node.get("choices", [])
	if not (choices is Array):
		choices = []
	(choices as Array).append({"text": "", "next": ""})
	node["choices"] = choices
	host.commit()
	host.rebuild()

func _delete_choice(index: int, choice_index: int) -> void:
	var nodes := _nodes()
	if index < 0 or index >= nodes.size() or not (nodes[index] is Dictionary):
		return
	var node: Dictionary = nodes[index]
	var choices = node.get("choices", [])
	if not (choices is Array) or choice_index < 0 or choice_index >= (choices as Array).size():
		return
	(choices as Array).remove_at(choice_index)
	if (choices as Array).is_empty():
		node.erase("choices")
	host.commit()
	host.rebuild()

# —— 说话者表 ——
func _speakers_section() -> Control:
	var col := Kit.vbox(4)
	var head := Kit.hbox(8)
	head.add_child(Kit.section_label("说话者"))
	head.add_child(Kit.spacer())
	head.add_child(Kit.button("+  说话者", func(): _add_speaker(), "ghost"))
	col.add_child(head)
	var speakers: Dictionary = host.data.get("speakers", {}) if host.data.get("speakers") is Dictionary else {}
	if speakers.is_empty():
		col.add_child(Kit.hint_label("留空表示旁白。需要名字/立绘时再加。", 520))
		return col
	var keys: Array = speakers.keys()
	keys.sort()
	for key in keys:
		col.add_child(_speaker_row_edit(str(key), speakers[key]))
	return col

func _speaker_row_edit(key: String, info) -> Control:
	var row := Kit.hbox(6)
	var data: Dictionary = info if info is Dictionary else {}
	row.add_child(Kit.text_label(key, Th.TEXT_MUTE, Th.FS_SMALL))
	var name_edit := LineEdit.new()
	name_edit.text = str(data.get("name", ""))
	name_edit.placeholder_text = "显示名"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.focus_exited.connect(func(): _set_speaker_field(key, "name", name_edit.text))
	row.add_child(name_edit)
	var portrait := LineEdit.new()
	portrait.text = str(data.get("portrait", ""))
	portrait.placeholder_text = "立绘路径（可选）"
	portrait.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	portrait.focus_exited.connect(func(): _set_speaker_field(key, "portrait", portrait.text))
	row.add_child(portrait)
	row.add_child(Kit.del_button(func(): _delete_speaker(key), "删除这个说话者"))
	return row

func _set_speaker_field(key: String, field: String, value: String) -> void:
	var speakers: Dictionary = host.data.get("speakers", {}) if host.data.get("speakers") is Dictionary else {}
	if not speakers.has(key):
		return
	var info: Dictionary = speakers[key] if speakers[key] is Dictionary else {}
	if value.strip_edges() == "":
		info.erase(field)
	else:
		info[field] = value.strip_edges()
	speakers[key] = info
	host.data["speakers"] = speakers
	host.commit()

func _add_speaker() -> void:
	var speakers: Dictionary = host.data.get("speakers", {}) if host.data.get("speakers") is Dictionary else {}
	var i := 1
	while speakers.has("s%d" % i):
		i += 1
	speakers["s%d" % i] = {"name": ""}
	host.data["speakers"] = speakers
	host.commit()
	host.rebuild()

func _delete_speaker(key: String) -> void:
	var speakers: Dictionary = host.data.get("speakers", {}) if host.data.get("speakers") is Dictionary else {}
	speakers.erase(key)
	if speakers.is_empty():
		host.data.erase("speakers")
	else:
		host.data["speakers"] = speakers
	host.commit()
	host.rebuild()

## 节点 id → 节点字典（预演/校验共用）
func _node_map() -> Dictionary:
	var out := {}
	for nd in _nodes():
		if nd is Dictionary:
			out[str(nd.get("id", ""))] = nd
	return out

## A3.2 预演：只走数据指针的节点导航（start → next/choices → end）。
## 不执行游戏代码——动作与 flag 条件只显示不运行，不违反契约 §0 红线。
func _dry_run() -> void:
	var nodes := _node_map()
	var pop := PopupPanel.new()
	var vb := Kit.vbox(10)
	pop.add_child(vb)
	vb.add_child(Kit.hint_label("预演只模拟节点导航（next/choices 指针），动作与 flag 条件不执行。", 420))
	var state := {"cur": str(host.data.get("start", ""))}
	var node_lbl = Kit.text_label("", Th.TEXT, Th.FS_MD)
	var body_lbl = Kit.text_label("", Th.TEXT, Th.FS_MD)
	body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_lbl.custom_minimum_size = Vector2(380, 0)
	vb.add_child(node_lbl)
	vb.add_child(body_lbl)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 6)
	vb.add_child(btns)
	# 常驻关闭出口：预演中途任何一步都能退出（分支节点原本只有「下一句/分支」）
	var foot := Kit.hbox(6)
	foot.add_child(Kit.spacer())
	foot.add_child(Kit.button("关闭", func(): pop.hide(), "ghost"))
	vb.add_child(foot)
	var ctx := {"nodes": nodes, "state": state, "btns": btns, "node": node_lbl, "body": body_lbl, "pop": pop}
	_dry_step(ctx)

## 预演单步：渲染当前指针节点与走向按钮（不执行游戏代码）
func _dry_step(ctx: Dictionary) -> void:
	var btns: HBoxContainer = ctx.get("btns")
	for c in btns.get_children():
		btns.remove_child(c)
		c.free()
	var nodes: Dictionary = ctx.get("nodes")
	var state: Dictionary = ctx.get("state")
	var node_lbl: Label = ctx.get("node")
	var body_lbl: Label = ctx.get("body")
	var pop: PopupPanel = ctx.get("pop")
	var cur := str(state.get("cur", ""))
	var nd = nodes.get(cur, null)
	if cur == "" or nd == null:
		node_lbl.text = "(指针为空)"
		body_lbl.text = "导航到这里没有节点可去（悬空/结束）。"
		btns.add_child(Kit.button("关闭", func(): pop.hide(), "ghost"))
		return
	var speakers: Dictionary = host.data.get("speakers", {}) if host.data.get("speakers") is Dictionary else {}
	var spk := str(nd.get("speaker", ""))
	var spk_name := str((speakers.get(spk, {}) as Dictionary).get("name", spk)) if spk != "" else "旁白"
	node_lbl.text = "[%s] %s" % [cur, spk_name]
	body_lbl.text = str(nd.get("text", ""))
	if bool(nd.get("end", false)):
		btns.add_child(Kit.button("（终）关闭", func(): pop.hide(), "ghost"))
		return
	var choices = nd.get("choices", [])
	if choices is Array and not (choices as Array).is_empty():
		for ch in choices:
			if not (ch is Dictionary):
				continue
			var chd: Dictionary = ch
			btns.add_child(Kit.button("→ " + str(chd.get("text", "(无文本)")), func():
				(ctx.get("state") as Dictionary)["cur"] = str(chd.get("next", ""))
				_dry_step(ctx), "plain"))
		return
	var nxt := str(nd.get("next", ""))
	if nxt != "":
		btns.add_child(Kit.button("下一句 →", func():
			(state as Dictionary)["cur"] = nxt
			_dry_step(ctx), "plain"))
	else:
		body_lbl.text += "（无 next 且无选项 = 终止）"
	pop.position = Vector2i(host.get_global_rect().position + Vector2(40, 80))
	host.add_child(pop)
	pop.popup()
