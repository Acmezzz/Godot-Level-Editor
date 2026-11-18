extends RefCounted
## 事件编辑器：步骤列表，动作类型与参数控件全部由 actions.json 驱动。
## schema 缺失时只给结构提示，不猜测游戏能力。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const EventModel := preload("res://src/content/event_model.gd")
const ContentStore := preload("res://src/content/content_store.gd")

## schema 引用类型 → 内容库种类。entity_ref 指向地图内实体，内容库无从得知，仍手填。
const REF_KINDS := {
	"dialogue_ref": "dialogues",
	"event_ref": "events",
	"shop_ref": "shops",
	"def_ref": "defs",
}

var host

func _init(host_ref) -> void:
	host = host_ref

func render() -> void:
	var body: VBoxContainer = host.body
	body.add_child(host.id_row())
	var once := CheckBox.new()
	once.text = "只播放一次（运行时写 evt.<id>.done）"
	once.button_pressed = bool(host.data.get("once", false))
	once.toggled.connect(func(on: bool):
		if on:
			host.data["once"] = true
		else:
			host.data.erase("once")
		host.commit())
	body.add_child(once)
	body.add_child(Kit.divider())
	var schema: Dictionary = host.schema()
	var actions := EventModel.actions_of(schema)
	if actions.is_empty():
		body.add_child(Kit.badge("未找到 actions.json", Th.WARN))
		body.add_child(Kit.hint_label(
			"游戏工程需提供 content/schema/actions.json 声明可用动作；缺失时只做结构检查。", 520))
	var head := Kit.section_header("步骤")
	head.add_child(Kit.button("+  步骤", func(): _add_step(), "ghost"))
	body.add_child(head)
	var steps := _steps()
	if steps.is_empty():
		body.add_child(Kit.hint_label("点右上「+ 步骤」添加第一个动作。", 520))
		return
	for i in steps.size():
		body.add_child(_step_card(i, steps[i], schema))

func _steps() -> Array:
	var steps = host.data.get("steps", [])
	return steps if steps is Array else []

## 单个步骤卡片：动作下拉 + 按 schema 生成的参数行
func _step_card(index: int, step, schema: Dictionary) -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", Th.box(Th.BG_PANEL, Th.BORDER, Th.R_CONTAINER, 10, 8))
	var col := Kit.vbox(6)
	wrap.add_child(col)
	if not (step is Dictionary):
		col.add_child(Kit.badge("步骤必须是对象", Th.ERR))
		return wrap
	var st: Dictionary = step
	var actions := EventModel.actions_of(schema)
	var cur := str(st.get("type", ""))

	var head := Kit.hbox(8)
	head.add_child(Kit.text_label("#%d" % index, Th.TEXT_MUTE, Th.FS_META))
	var type_opt := OptionButton.new()
	var names: Array = actions.keys()
	names.sort()
	if cur != "" and not names.has(cur):
		names.insert(0, cur)
	for name in names:
		type_opt.add_item(str(name))
	type_opt.select(names.find(cur) if names.has(cur) else 0)
	type_opt.item_selected.connect(func(idx: int): _set_step_type(index, str(names[idx])))
	head.add_child(type_opt)
	head.add_child(Kit.spacer())
	# A3.1：步骤排序（契约：steps 有序执行）——↑/↓ 相邻交换
	head.add_child(Kit.button("↑", func(): _move_step(index, -1), "ghost"))
	head.add_child(Kit.button("↓", func(): _move_step(index, 1), "ghost"))
	head.add_child(Kit.button("删除", func(): _delete_step(index), "ghost"))
	col.add_child(head)

	if not actions.has(cur):
		if cur != "":
			col.add_child(Kit.badge("游戏工程未声明该动作", Th.ERR))
		return wrap
	var params := EventModel.params_of(schema, cur)
	for pid in params:
		col.add_child(_param_row(index, str(pid), params[pid], st))
	return wrap

## 参数控件按 schema 类型选择：bool 用开关，数值用 SpinBox，其余用单行文本
func _param_row(index: int, pid: String, spec, st: Dictionary) -> Control:
	var pdef: Dictionary = spec if spec is Dictionary else {}
	var type_name := str(pdef.get("type", "string"))
	var label := pid + ("*" if bool(pdef.get("required", false)) else "")
	var value = st.get(pid, pdef.get("default", null))
	if type_name == "bool":
		var cb := CheckBox.new()
		cb.button_pressed = bool(value) if value != null else false
		cb.toggled.connect(func(on: bool): _set_step_field(index, pid, on))
		return Kit.field_row(label, cb, Kit.LABEL_W_LONG)
	if type_name == "int" or type_name == "float":
		var spin := SpinBox.new()
		# H1（批次 11）：参数可声明 min/max/step（编辑器控件用，游戏侧忽略）
		spin.min_value = float(pdef.get("min", -99999))
		spin.max_value = maxf(float(pdef.get("max", 99999)), float(pdef.get("min", -99999)))
		spin.step = float(pdef.get("step", 1.0 if type_name == "int" else 0.1))
		spin.value = clampf(float(value) if value != null else 0.0, spin.min_value, spin.max_value)
		spin.value_changed.connect(func(v: float):
			_set_step_field(index, pid, int(v) if type_name == "int" else v))
		return Kit.field_row(label, spin, Kit.LABEL_W_LONG)
	if REF_KINDS.has(type_name):
		return _ref_row(index, pid, str(REF_KINDS[type_name]), value, label)
	var edit := LineEdit.new()
	edit.text = str(value) if value != null else ""
	edit.placeholder_text = type_name
	edit.text_submitted.connect(func(t: String): _set_step_field(index, pid, t))
	edit.focus_exited.connect(func(): _set_step_field(index, pid, edit.text))
	# A3.3：flag 参数（名字含 flag 的 string 参数）接已声明 flag 选择器（扫全工程事件）
	if pid.to_lower().contains("flag"):
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var flag_wrap := HBoxContainer.new()
		flag_wrap.add_theme_constant_override("separation", 4)
		flag_wrap.add_child(edit)
		flag_wrap.add_child(Kit.button("⚑", func(): _pick_flag(index, pid, edit), "ghost"))
		return Kit.field_row(label, flag_wrap, Kit.LABEL_W_LONG)
	return Kit.field_row(label, edit, Kit.LABEL_W_LONG)

## 引用类型参数：列出现有内容资源供选，避免手打 id 打错变成悬空引用。
## 保留「(空)」与「手填…」，因为资源可能还没建，或指向本页之外的资源。
func _ref_row(index: int, pid: String, kind_key: String, value, label: String) -> Control:
	var ids := ContentStore.list_ids(host.manifest, kind_key)
	var opt := OptionButton.new()
	opt.add_item("(空)")
	var current := str(value) if value != null else ""
	var sel := 0
	var listed := false
	for res_id in ids:
		opt.add_item(str(res_id))
		if str(res_id) == current:
			sel = opt.item_count - 1
			listed = true
	if current != "" and not listed:
		# 引用了不存在的资源：保住这个值，同时让用户看到它是悬空的
		opt.add_item(current + "  (不存在)")
		sel = opt.item_count - 1
	opt.select(sel)
	opt.item_selected.connect(func(idx: int):
		_set_step_field(index, pid, "" if idx == 0 else opt.get_item_text(idx).replace("  (不存在)", "")))
	var row := Kit.field_row(label, opt, Kit.LABEL_W_LONG)
	if ids.is_empty():
		row.add_child(Kit.button("去新建…", func(): host.create_in_kind(kind_key), "ghost"))
	return row

func _set_step_type(index: int, type_name: String) -> void:
	var steps := _steps()
	if index < 0 or index >= steps.size() or not (steps[index] is Dictionary):
		return
	if str((steps[index] as Dictionary).get("type", "")) == type_name:
		return
	# 换动作：重置为该动作的默认参数，避免残留上一个动作的键
	var fresh := {"type": type_name}
	var params := EventModel.params_of(host.schema(), type_name)
	for pid in params:
		var spec: Dictionary = params[pid] if params[pid] is Dictionary else {}
		if spec.has("default"):
			fresh[str(pid)] = spec["default"]
	steps[index] = fresh
	host.commit()
	host.rebuild()

func _set_step_field(index: int, key: String, value) -> void:
	var steps := _steps()
	if index < 0 or index >= steps.size() or not (steps[index] is Dictionary):
		return
	var st: Dictionary = steps[index]
	if value is String and str(value).strip_edges() == "":
		st.erase(key)
	else:
		st[key] = value
	host.commit()

func _add_step() -> void:
	var steps := _steps()
	var actions := EventModel.actions_of(host.schema())
	var step := {"type": ""}
	if not actions.is_empty():
		var names: Array = actions.keys()
		names.sort()
		var first := str(names[0])
		step["type"] = first
		var params := EventModel.params_of(host.schema(), first)
		for pid in params:
			var spec: Dictionary = params[pid] if params[pid] is Dictionary else {}
			if spec.has("default"):
				step[str(pid)] = spec["default"]
	steps.append(step)
	host.data["steps"] = steps
	host.commit()
	host.rebuild()

func _delete_step(index: int) -> void:
	var steps := _steps()
	if index < 0 or index >= steps.size():
		return
	steps.remove_at(index)
	host.data["steps"] = steps
	host.commit()
	host.rebuild()

## A3.1：步骤上移/下移（相邻交换；越界不动）
func _move_step(index: int, dir: int) -> void:
	var steps := _steps()
	var j := index + dir
	if j < 0 or j >= steps.size():
		return
	var tmp = steps[index]
	steps[index] = steps[j]
	steps[j] = tmp
	host.data["steps"] = steps
	host.commit()
	host.rebuild()

## A3.3：flag 选择弹窗（清单来自 EventModel.declared_flags 全工程扫描）
func _pick_flag(index: int, pid: String, edit: LineEdit) -> void:
	var flags: Array = EventModel.declared_flags(host.manifest)
	var pop := PopupPanel.new()
	var vb := Kit.vbox(6)
	pop.add_child(vb)
	vb.add_child(Kit.text_label("已声明的 flag（扫自全工程事件的 set_flag 步骤）", Th.TEXT_MUTE, Th.FS_SMALL))
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(240, 220)
	if flags.is_empty():
		list.add_item("(还没有任何事件写过 set_flag)")
	else:
		for f in flags:
			list.add_item(str(f))
	list.item_clicked.connect(func(idx: int, _at: Vector2, _mb: int):
		var f := str(flags[idx]) if not flags.is_empty() and idx < flags.size() else ""
		if f == "":
			pop.queue_free()
			return
		edit.text = f
		_set_step_field(index, pid, f)
		pop.queue_free())
	# 选择器也要有取消出口：没有候选时别让用户只靠点空白关窗
	var foot := Kit.hbox(6)
	foot.add_child(Kit.spacer())
	foot.add_child(Kit.button("取消", func(): pop.queue_free(), "ghost"))
	vb.add_child(foot)
	pop.position = Vector2i(edit.get_global_rect().position + Vector2(0, edit.size.y + 4))
	host.add_child(pop)
	pop.popup()
