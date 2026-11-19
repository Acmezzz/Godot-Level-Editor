extends RefCounted
## 声明式字段控件工厂：清单字段声明 → 控件。
##
## 只有两个可写 kind：
## input —— type: string / int / float / bool（multiline 则多行；int/float 读 min/max）
## choice —— options[] 直给，或 source 从内容库 / 清单实体 / 地图列表动态取
##
## 认不出的声明一律只读展示 + 黄色提示，绝不提供可写控件。
## 旧实现把未知类型落进 LineEdit：数组 [1,2,3] 被 str() 成 "[1, 2, 3]"，用户一碰
## 就把数组写成它的打印形式，是静默数据损坏。这里改成结构可见、不可写。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const MapStore := preload("res://src/map_store.gd")

const KIND_INPUT := "input"
const KIND_CHOICE := "choice"

## 声明的种类：一律读 kind 键，不做推断。
## 缺 kind / 认不出的 kind 一律走只读展示（校验层把缺 kind 报成错误）。
static func kind_of(decl: Dictionary) -> String:
	return str(decl.get("kind", ""))

static func type_of(decl: Dictionary) -> String:
	return str(decl.get("type", ""))

## 声明没给 default 时的初值（按 type 推）。
static func default_for(decl: Dictionary) -> Variant:
	match type_of(decl):
		"bool": return false
		"int": return 0
		"float": return 0.0
		_: return ""

## 构建控件。返回 {ctl: Control, commit: Callable}。
## commit 用于重建/切实例前统一提交连续控件（SpinBox/多行文本）的待写值；
## 幂等（值未变不写盘）由下游 _set_field 保证。离散控件（CheckBox/LineEdit/OptionButton）commit 为空操作。
## option_resolver（可选）：Callable(decl) -> Array，元素为 {v, t} 或纯字符串，
## 供 choice 的 source（content:item / entity:portal,exit / map）动态取选项。
static func build(decl: Dictionary, value, on_set: Callable,
		option_resolver: Callable = Callable()) -> Dictionary:
	var kind := kind_of(decl)
	if kind == KIND_CHOICE:
		return _build_choice(decl, value, on_set, option_resolver)
	if kind == KIND_INPUT:
		return _build_input(decl, value, on_set)
	var why := "声明缺 kind（应写 \"input\" 或 \"choice\"）" if kind == "" \
		else "未声明的字段种类「%s」" % kind
	return _readonly(decl, value, why, "补全声明后重新加载清单即可恢复编辑")

## input：string（可 multiline）/ int / float / bool。
## 连续控件（SpinBox、多行 TextEdit）拖动/输入期间只记内存，失焦或 commit() 才写盘。
static func _build_input(decl: Dictionary, value, on_set: Callable) -> Dictionary:
	var typ := type_of(decl)
	match typ:
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = bool(value)
			cb.toggled.connect(func(v: bool): on_set.call(v))
			return {"ctl": cb, "commit": Callable()}
		"int", "float":
			if not (value is int or value is float) and str(value) != "":
				return _readonly(decl, value, "值类型不符：声明 %s，实际是 %s" % [typ, type_name(value)],
					"编辑器不会改写它，请游戏侧或手工修正")
			var sp := SpinBox.new()
			sp.step = 1.0 if typ == "int" else 0.1
			sp.min_value = float(decl.get("min", -999999))
			sp.max_value = float(decl.get("max", 999999))
			sp.value = float(value) if (value is int or value is float) else 0.0
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var pending := {"v": sp.value}
			sp.value_changed.connect(func(v: float):
				pending.v = (int(v) if typ == "int" else v))
			var commit := func():
				on_set.call(pending.v)
			sp.get_line_edit().text_submitted.connect(func(_t: String): on_set.call(pending.v))
			sp.get_line_edit().focus_exited.connect(func(): on_set.call(pending.v))
			return {"ctl": sp, "commit": commit}
		"string":
			if not (value is String) and value != null:
				return _readonly(decl, value, "值类型不符：声明 string，实际是 %s" % type_name(value),
					"编辑器不会改写它，请游戏侧或手工修正")
			if bool(decl.get("multiline", false)):
				var te := TextEdit.new()
				te.text = str(value)
				te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
				te.custom_minimum_size = Vector2(0, 72)
				te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				te.focus_exited.connect(func(): on_set.call(te.text))
				return {"ctl": te, "commit": func(): on_set.call(te.text)}
			var le := LineEdit.new()
			le.text = str(value)
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_submitted.connect(func(t: String): on_set.call(t.strip_edges()))
			le.focus_exited.connect(func(): on_set.call(le.text.strip_edges()))
			return {"ctl": le, "commit": Callable()}
		_:
			var why := "声明缺 type（应写 string / int / float / bool）" if typ == "" \
				else "未声明的输入类型「%s」" % typ
			return _readonly(decl, value, why, "补全声明后重新加载清单即可恢复编辑")

## choice：options[] 直给，或按 source 动态取。
## 值不在选项里时保留原值并额外插一条「(当前值)」——绝不静默改成第一项。
static func _build_choice(decl: Dictionary, value, on_set: Callable,
		option_resolver: Callable) -> Dictionary:
	var opts: Array = []
	if decl.get("options", null) is Array:
		for o in decl.get("options", []):
			opts.append(_norm_option(o))
	elif option_resolver.is_valid():
		for o in option_resolver.call(decl):
			opts.append(_norm_option(o))
	var cur := str(value)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var idx := -1
	for o in opts:
		opt.add_item(str((o as Dictionary).get("t", "")))
		var at := opt.get_item_count() - 1
		opt.set_item_metadata(at, str((o as Dictionary).get("v", "")))
		if str((o as Dictionary).get("v", "")) == cur:
			idx = at
	if cur != "" and idx < 0:
 # 值已不属于当前选项集（选项库改了/来源目录删了）：保留它，别让用户一碰就丢数据
		opt.add_item("(当前值) " + cur)
		opt.set_item_metadata(opt.get_item_count() - 1, cur)
		idx = opt.get_item_count() - 1
	if idx >= 0:
		opt.select(idx)
	opt.item_selected.connect(func(i: int):
		on_set.call(str(opt.get_item_metadata(i))))
	return {"ctl": opt, "commit": Callable()}

static func _norm_option(o) -> Dictionary:
	if o is Dictionary:
		var v := str((o as Dictionary).get("v", ""))
		var t := str((o as Dictionary).get("t", v))
		return {"v": v, "t": t if t != "" else v}
	return {"v": str(o), "t": str(o)}

## 只读展示：结构可见（JSON 一行），不可写；下面一行黄字说明为什么。
static func _readonly(decl: Dictionary, value, why: String, hint: String) -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var le := LineEdit.new()
	le.text = JSON.stringify(value) if not (value is String) else value
	le.editable = false
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.tooltip_text = why
	box.add_child(le)
	var warn := Kit.hint_label(why + "。" + hint, 240)
	warn.add_theme_color_override("font_color", Th.WARN)
	box.add_child(warn)
	return {"ctl": box, "commit": Callable()}

static func type_name(v) -> String:
	if v == null:
		return "null"
	if v is bool:
		return "bool"
	if v is int:
		return "int"
	if v is float:
		return "float"
	if v is String:
		return "string"
	if v is Array:
		return "array"
	if v is Dictionary:
		return "object"
	return "unknown"
