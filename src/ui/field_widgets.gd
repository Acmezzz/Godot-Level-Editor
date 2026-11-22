extends RefCounted
## 声明式字段控件工厂：清单字段声明 → 控件。
##
## 只有两个可写 kind：
## input —— type: string / int / float / bool / color / vector2 / range / asset_ref / array
## choice —— options[] 直给，或 source 从内容库 / 清单实体 / 地图列表动态取；multiple: true 切勾选组
##
## string 可加 multiline: true 切 TextEdit；range 读 min/max/step（无 min/max 时退到 HSlider 默认）；
## asset_ref 读 `assetKind`（按资产 kind 过滤）与可选 `of`（逗号分隔 id 白名单）。
## array 读 of（基础类型或 choice，不嵌套 array）与可选 min/max（数字元素界限，透传给行控件）。
## 认不出的声明一律只读展示 + 黄色提示，绝不提供可写控件。
## 旧实现把未知类型落进 LineEdit：数组 [1,2,3] 被 str() 成 "[1, 2, 3]"，用户一碰
## 就把数组写成它的打印形式，是静默数据损坏。这里改成结构可见、不可写。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")

const KIND_INPUT := "input"
const KIND_CHOICE := "choice"
const KIND_RECORD := "record"   # C1：array of record 的行控件种类（仅作数组元素，不作顶层字段类型）

## 值是否「未填」：null 或空串（数组/字典不算未填——比较时要避开 Variant 类型错误）
static func _is_unset(v) -> bool:
	return v == null or (v is String and str(v) == "")

## 声明的种类：一律读 kind 键，不做推断。
## 缺 kind / 认不出的 kind 一律走只读展示（校验层把缺 kind 报成错误）。
static func kind_of(decl: Dictionary) -> String:
	return str(decl.get("kind", ""))

## E1：该字段是否适合提供「画布选…」——同图实例引用（entity_ref / entity_inst 来源）。
## 配对地图字段（scope=map_ref）不给：目标图不一定是当前图，下拉列的是目标图实例，
## 在画布上点的是本图实例，两者不是同一个域。
static func wants_canvas_pick(decl: Dictionary) -> bool:
	var d := RefFields.describe(decl)
	if str(d.get("kind", "")) == "entity_inst" and str(d.get("scope", "")) == "same_map":
		return true
	# C4：有限格图 cell_id 字段——格是多边形，画布按多边形命中（accept="cell"）
	return wants_cell_pick(decl)

## C4：choice 来源是 `cell:` 的字段可在画布上按格图多边形点选。
static func wants_cell_pick(decl: Dictionary) -> bool:
	return type_of(decl) == "choice" and str(decl.get("source", "")).begins_with("cell:")

## 画布选点的候选类型白名单（声明的 of 过滤；空 = 不限实体类型）。
static func canvas_pick_types(decl: Dictionary) -> Array:
	var d := RefFields.describe(decl)
	return Array((d.get("filter", {}) as Dictionary).get("ids", []))


static func type_of(decl: Dictionary) -> String:
	return str(decl.get("type", ""))

## 声明没给 default 时的初值（按 type 推）。
static func default_for(decl: Dictionary) -> Variant:
	match type_of(decl):
		"bool": return false
		"int": return int(decl.get("min", 0))
		"float", "range": return float(decl.get("min", 0.0))
		"vector2":
			var dims := RefFields.vector_dims(decl)
			var lo := float(decl.get("min", 0.0))
			return [lo, lo, lo] if dims == 3 else [lo, lo]
		"color": return "#ffffff"
		"choice": return [] if bool(decl.get("multiple", false)) else ""
		"array": return []
		"record": return {}
		_: return ""

## 声明里能读到的说明性信息（E1）：字段 id / 执行码 / 类型与范围 / 缺省值。
## 契约里没有独立的「说明」「单位」键（GAME_SIDE_STANDARD §2.4/§2.5），
## 因此这里只拼**已声明**的键，不发明新键；需要文字说明时游戏侧补契约再接。
static func decl_tooltip(decl: Dictionary) -> String:
	var parts: Array[String] = []
	var fid := str(decl.get("id", ""))
	if fid != "":
		parts.append("字段 " + fid)
	var code := str(decl.get("code", ""))
	if code != "":
		parts.append("码 " + code)
	var kind := kind_of(decl)
	if kind == KIND_CHOICE:
		var opts = decl.get("options", null)
		if opts is Array and not (opts as Array).is_empty():
			parts.append("可选：" + ",".join(PackedStringArray((opts as Array).map(func(o): return str(o)))))
		elif str(decl.get("source", "")) != "":
			parts.append("来源 " + str(decl.get("source", "")))
		if bool(decl.get("multiple", false)):
			parts.append("可多选")
	else:
		var typ := type_of(decl)
		if typ != "":
			var rng := ""
			if decl.get("min", null) != null:
				rng += "min %s" % str(decl.get("min"))
			if decl.get("max", null) != null:
				rng += (" " if rng != "" else "") + "max %s" % str(decl.get("max"))
			parts.append(typ + ("（%s）" % rng if rng != "" else ""))
	var dflt = decl.get("default", null)
	if dflt != null:
		parts.append("缺省 " + (str(dflt) if (dflt is String or dflt is int or dflt is float
			or dflt is bool) else JSON.stringify(dflt)))
	return " · ".join(parts)

## 构建控件。返回 {ctl: Control, commit: Callable}。
## commit 用于重建/切实例前统一提交连续控件（SpinBox/多行文本）的待写值；
## 幂等（值未变不写盘）由下游 _set_field 保证。离散控件（CheckBox/LineEdit/OptionButton）commit 为空操作。
## option_resolver（可选）：Callable(decl) -> Array，元素为 {v, t} 或纯字符串，
## 供 choice 的 source（content:item / entity:portal,exit / map）动态取选项。
static func build(decl: Dictionary, value, on_set: Callable,
		option_resolver: Callable = Callable(), key_mode := "id") -> Dictionary:
	var kind := kind_of(decl)
	if kind == KIND_CHOICE:
		return _build_choice(decl, value, on_set, option_resolver, key_mode)
	if kind == KIND_INPUT:
		return _build_input(decl, value, on_set, option_resolver, key_mode)
	if kind == KIND_RECORD:
		return _build_record(decl, value, on_set, option_resolver, key_mode)
	var why := "声明缺 kind（应写 \"input\" 或 \"choice\"）" if kind == "" \
		else "未声明的字段种类「%s」" % kind
	return _readonly(decl, value, why, "补全声明后重新加载清单即可恢复编辑")

## input：string（可 multiline）/ int / float / bool / color / vector2 / range / asset_ref。
## 连续控件（SpinBox、HScale、多行 TextEdit）拖动/输入期间只记内存，失焦或 commit() 才写盘。
static func _build_input(decl: Dictionary, value, on_set: Callable,
		option_resolver: Callable, key_mode := "id") -> Dictionary:
	var typ := type_of(decl)
	match typ:
		"bool":
			# 布尔必须是布尔（C06）："false" 这类字符串不能被 bool() 静默当真——
			# 旧值非法时只读展示，用户显式修正（勾选控件以外的路径都不可写）
			if not _is_unset(value) and not (value is bool):
				return _readonly(decl, value, "值类型不符：声明 bool，实际是 %s" % type_name(value),
					"编辑器不会改写它，请游戏侧或手工修正")
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
				if typ == "int":
					pending.v = int(v)
				else:
					pending.v = v)
			# 未改动就提交时什么都不做（A2）：否则「空表单按 Ctrl+S」会先建出内容 ID
			var initial := sp.value
			var commit := func():
				if float(pending.v) != initial:
					on_set.call(pending.v)
			sp.get_line_edit().text_submitted.connect(func(_t: String):
				if float(pending.v) != initial:
					on_set.call(pending.v))
			sp.get_line_edit().focus_exited.connect(func():
				if float(pending.v) != initial:
					on_set.call(pending.v))
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
				var te0 := te.text
				return {"ctl": te, "commit": func():
					if te.text != te0:
						on_set.call(te.text)}
			var le := LineEdit.new()
			le.text = str(value)
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_submitted.connect(func(t: String): on_set.call(t.strip_edges()))
			le.focus_exited.connect(func(): on_set.call(le.text.strip_edges()))
			# 单行文本也登记提交器：Ctrl+S 时即使焦点还在框里，也按当前文本落盘（A2）
			var le0 := le.text
			return {"ctl": le, "commit": func():
				if le.text.strip_edges() != le0.strip_edges():
					on_set.call(le.text.strip_edges())}
		"color":
			var cp := ColorPickerButton.new()
			cp.color = Color(str(value) if str(value).begins_with("#") else "#ffffff")
			cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cp.color_changed.connect(func(c: Color): on_set.call("#%s" % c.to_html(false)))
			return {"ctl": cp, "commit": Callable()}
		"vector2":
			# 维数按声明（C06）：缺省二维；声明 dims: 3 时只接受三元。多一元/少一元都只读，
			# 否则一提交就会静默丢维度或把第三位吞掉。
			var dims := RefFields.vector_dims(decl)
			if not _is_unset(value) and (not (value is Array) or (value as Array).size() != dims):
				return _readonly(decl, value, "值类型不符：声明 vector2/%d 维，实际是 %s" % [dims, type_name(value)],
					"编辑器不会改写它，请游戏侧或手工修正")
			if not (value is Array):
				value = default_for(decl)   # 未填：按声明 default（[min, min]）起步，与 int/float 的空串口径一致
			var vv: Array = value
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", 4)
			var pending := {"v": []}
			for axis in dims:
				(pending.v as Array).append(float(vv[axis]))
			for axis in dims:
				var sp := SpinBox.new()
				sp.step = 0.1
				sp.min_value = float(decl.get("min", -999999))
				sp.max_value = float(decl.get("max", 999999))
				sp.value = pending.v[axis]
				sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				sp.prefix = ("xyz"[axis] if axis < 3 else str(axis)) + ": "
				var ai := axis
				sp.value_changed.connect(func(n: float):
					pending.v[ai] = n)
				sp.get_line_edit().focus_exited.connect(func(): on_set.call(pending.v.duplicate()))
				h.add_child(sp)
			var init_vv: Array = pending.v.duplicate()
			# 没动过就提交 = 无操作（避免空表单保存时凭空创建内容，A2）
			var commit_v := func():
				if pending.v != init_vv:
					on_set.call(pending.v.duplicate())
			return {"ctl": h, "commit": commit_v}
		"range":
			# 数字之外的值（空串占位除外）只读展示——commit() 不能把它悄悄写成 min
			if not (value is int or value is float):
				if not _is_unset(value):
					return _readonly(decl, value, "值类型不符：声明 range，实际是 %s" % type_name(value),
						"编辑器不会改写它，请游戏侧或手工修正")
				value = float(decl.get("min", 0.0))   # 未填：从 min 起步，落盘走声明 default 同一形态
			var lo := float(decl.get("min", 0.0))
			var hi := float(decl.get("max", 1.0))
			if hi <= lo:
				hi = lo + 1.0
			var step := float(decl.get("step", 0.01))
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 6)
			var sl := HSlider.new()
			sl.min_value = lo
			sl.max_value = hi
			sl.step = step
			sl.value = float(value) if (value is int or value is float) else lo
			sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var num := SpinBox.new()
			num.min_value = lo
			num.max_value = hi
			num.step = step
			num.value = sl.value
			var pending2 := {"v": sl.value}
			sl.value_changed.connect(func(n: float):
				pending2.v = n
				num.value = n)
			num.value_changed.connect(func(n: float):
				pending2.v = n
				sl.value = n)
			# 拖完滑杆/输入框失焦即提交，与 int/float 同一口径；未改动不提交（A2）
			var init2 := sl.value
			var commit2 := func():
				if pending2.v != init2:
					on_set.call(pending2.v)
			sl.drag_ended.connect(func(_c: bool): commit2.call())
			num.get_line_edit().focus_exited.connect(func(): commit2.call())
			num.get_line_edit().text_submitted.connect(func(_t: String): commit2.call())
			box.add_child(sl)
			box.add_child(num)
			return {"ctl": box, "commit": commit2}
		"array":
			# array.of ∈ 基础类型/choice（不嵌套 array）；非数组值只读展示——commit() 不能把坏值悄悄写成 []
			var of := str(decl.get("of", ""))
			var ok_of: Array = ["string", "int", "float", "bool", "color", "vector2", "range", "asset_ref", "choice", "record"]
			if not ok_of.has(of):
				return _readonly(decl, value, "array.of 未声明（应写基础类型或 choice）",
					"补全声明后重新加载清单即可恢复编辑")
			if not _is_unset(value) and not (value is Array):
				return _readonly(decl, value, "值类型不符：声明 array，实际是 %s" % type_name(value),
					"编辑器不会改写它，请游戏侧或手工修正")
			var items: Array = value if value is Array else []
			return _build_array(decl, items, on_set, option_resolver, key_mode)
		"viewport_ref":
			return _build_viewport_ref(decl, value, on_set, option_resolver)
		"port_ref":
			# C3：端口引用 = 对象值 {map, inst, port}；选项 = port: 解析器（配对图优先），写入值解码回对象。
			# 值编码成 JSON 串走 choice 控件；值不在选项里时显示「(当前值)」，不静默改写。
			var pd2: Dictionary = decl.duplicate(true)
			pd2["kind"] = KIND_CHOICE
			pd2["source"] = "port:" + str(decl.get("of", ""))
			var enc := JSON.stringify(value) if value is Dictionary else ""
			return _build_choice(pd2, enc, func(v2):
				var pd = JSON.parse_string(str(v2))
				on_set.call(pd if pd is Dictionary else {}), option_resolver)
		"asset_ref":
			# 资产引用走 choice 的同一套控件，只是选项来源由 asset: 解析器提供。
			# 白名单两种写法：`of`（字段直写）或 `ids`（数组元素的同型声明——`of` 已被元素类型占用）。
			var d2: Dictionary = decl.duplicate(true)
			d2["kind"] = KIND_CHOICE
			var ak := str(decl.get("assetKind", ""))
			var only := str(decl.get("of", ""))
			if only == "" and decl.get("ids", null) is Array:
				only = ",".join(PackedStringArray(decl.get("ids", [])))
			d2["source"] = "asset:" + ak + (":" + only if only != "" else "")
			return _build_choice(d2, value, on_set, option_resolver, key_mode)
		_:
			var why := "声明缺 type（应写 string / int / float / bool / color / vector2 / range / asset_ref / array）" if typ == "" \
				else "未声明的输入类型「%s」" % typ
			return _readonly(decl, value, why, "补全声明后重新加载清单即可恢复编辑")

## array 元素声明：of 指基础类型或 choice；choice 元素继承 options/source，
## 其它同型声明继承范围/固定选项/过滤参数（C10）——每个元素拿到的是独立同型声明副本。
## 注意 `of` 在数组上表示**元素类型**，所以 asset_ref 元素的 id 白名单用 `ids`（不用 of）。
static func _elem_decl(decl: Dictionary) -> Dictionary:
	var of := str(decl.get("of", "string"))
	if of == "choice":
		var d: Dictionary = {"kind": KIND_CHOICE}
		for k in ["options", "source", "multiple", "mapField"]:
			if decl.get(k, null) != null:
				d[k] = (decl.get(k) as Variant).duplicate(true) if (decl.get(k) is Array or decl.get(k) is Dictionary) \
					else decl.get(k)
		return d
	# C1：of: record —— 元素控件是记录表单（子字段声明在 fields 里，逐元素独立副本）
	if of == "record":
		return {"kind": KIND_RECORD, "type": "record",
			"fields": (decl.get("fields", []) as Array).duplicate(true)}
	var out := {"kind": KIND_INPUT, "type": of}
	for k in ["min", "max", "step", "dims", "assetKind"]:
		if decl.get(k, null) != null:
			# 逐元素独立声明副本（C1）：数组/字典值不能与父声明共享引用
			out[k] = decl.get(k).duplicate(true) if (decl.get(k) is Array or decl.get(k) is Dictionary) \
				else decl.get(k)
	if of == "asset_ref":
		var ids = decl.get("ids", null)
		if ids is Array:
			out["of"] = ",".join(PackedStringArray(ids))
	return out

## array：可增删行容器，每行一个元素控件；值 = 各行 state.v 按顺序收集。
## 行删除前先冲刷该行连续控件的待写值（commit），行序变动靠行字典引用而非闭包下标。
## C1：of: record 行给 复制/上移/下移（rows 换位 + 容器子序同步）；key_mode 透传元素控件。
static func _build_array(decl: Dictionary, items: Array, on_set: Callable,
		option_resolver: Callable, key_mode := "id") -> Dictionary:
	var elem := _elem_decl(decl)
	var rec := str(elem.get("type", "")) == "record"
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)
	var rows_box := VBoxContainer.new()
	rows_box.add_theme_constant_override("separation", 4)
	wrap.add_child(rows_box)
	var rows: Array = []
	var ctx := {}
	var collect := func() -> Array:
		var out: Array = []
		for r in rows:
			var c: Callable = r.get("commit", Callable())
			if c.is_valid():
				c.call()
			out.append((r.state as Dictionary).get("v"))
		return out
	var done := func(): on_set.call(collect.call())
	var add_row := func(v, at := -1) -> void:
		var r := {"state": {"v": v}, "commit": Callable(), "line": null}
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 4)
		var built := build(elem, v, func(v2): (r.state as Dictionary)["v"] = v2, option_resolver, key_mode)
		r["commit"] = built.commit
		line.add_child(built.ctl)
		if rec:
			line.add_child(_row_tools(ctx, r))
		var del := Button.new()
		del.text = "×"
		del.focus_mode = Control.FOCUS_NONE
		del.pressed.connect(func():
			var c: Callable = r.commit
			if c.is_valid():
				c.call()
			rows.erase(r)
			line.queue_free()
			on_set.call(collect.call()))
		line.add_child(del)
		# 行容器子序与 rows 数组一致：插行 = add_child + move_child 到目标行号
		if at < 0 or at >= rows.size():
			rows.append(r)
			rows_box.add_child(line)
		else:
			rows.insert(at, r)
			rows_box.add_child(line)
			rows_box.move_child(line, at)
		r["line"] = line
	for v in items:
		add_row.call(v)
	var add := Button.new()
	add.text = "+ 添加"
	add.focus_mode = Control.FOCUS_NONE
	add.pressed.connect(func():
		add_row.call(default_for(elem))
		on_set.call(collect.call()))
	wrap.add_child(add)
	return {"ctl": wrap, "commit": func():
		on_set.call(collect.call())}

## C1：记录行工具组（复制/上移/下移）。ctx = {"rows", "box", "add", "done"}。
## GDScript lambda 按值捕获局部变量，行操作需要共享可变状态，统一走 ctx 字典（字典按引用捕获）。
static func _row_tools(ctx: Dictionary, r: Dictionary) -> Control:
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 2)
	var rows: Array = ctx.get("rows", [])
	var box: Control = ctx.get("box", null)
	var done: Callable = ctx.get("done", Callable())
	var up := Kit.button("↑", func(): _row_move(rows, box, r, -1, done))
	var down := Kit.button("↓", func(): _row_move(rows, box, r, 1, done))
	var cp := Kit.button("复制", func(): _row_dup(ctx, r, done))
	tools.add_child(up)
	tools.add_child(down)
	tools.add_child(cp)
	for b in [up, down, cp]:
		(b as Button).focus_mode = Control.FOCUS_NONE
	return tools

## 行换位：rows 数组交换 + rows_box 子序同步（move_child 到目标行号）；完成后 done 写盘。
static func _row_move(rows: Array, box: Control, r: Dictionary, dir: int, done: Callable) -> void:
	var i: int = rows.find(r)
	var j: int = i + dir
	if i < 0 or j < 0 or j >= rows.size() or box == null:
		return
	rows[i] = rows[j]
	rows[j] = r
	box.move_child((r as Dictionary)["line"] as Control, j)
	done.call()

## 复制行：先 commit 该行连续控件，深拷贝当前值插到下一行（记录行字典深拷贝，脱离引用）。
static func _row_dup(ctx: Dictionary, r: Dictionary, done: Callable) -> void:
	var rows: Array = ctx.get("rows", [])
	var i: int = rows.find(r)
	if i < 0:
		return
	var c: Callable = (r as Dictionary).get("commit", Callable())
	if c.is_valid():
		c.call()
	var v = (r as Dictionary).get("state", {}).get("v")
	var copy = v.duplicate(true) if (v is Dictionary or v is Array) else v
	(ctx.get("add", Callable()) as Callable).call(copy, i + 1)
	done.call()

## record（C1）：记录表单 = 子字段递归构建。值是字典；子字段存储键按宿主池规则
## （key_mode："code" = 字段码，缺码退回 id）。兄弟配对字段作用域 = 当前记录行
## （mapField 的 _mapKey 注入读行内值）。未知子键不碰（未知版本往返）；非字典值只读展示。
static func _build_record(decl: Dictionary, value, on_set: Callable,
		option_resolver: Callable, key_mode := "id") -> Dictionary:
	if not (value is Dictionary):
		return _readonly(decl, value, "记录值不是字典（实际 %s）" % type_name(value),
			"已有值原样保留，不提供可写控件")
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Th.box(Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.16), Th.R_INNER, 6, 4))
	var box := Kit.vbox(4)
	panel.add_child(box)
	var commits: Array = []
	var fields_arr: Array = decl.get("fields", []) if decl.get("fields", null) is Array else []
	for sub in fields_arr:
		if not (sub is Dictionary):
			continue
		var sd: Dictionary = sub
		var sub_key := str(sd.get("id", ""))
		if key_mode == "code":
			var c2 := str(sd.get("code", ""))
			if c2 != "":
				sub_key = c2
		var sub_val = value.get(sub_key, sd.get("default", default_for(sd)))
		var d2: Dictionary = sd
		# 兄弟配对字段作用域 = 当前记录行：配对地图字段值从行内读
		if str(sd.get("mapField", "")) != "":
			var tk := RefFields.paired_map_value(sd, fields_arr, value)
			if tk != "":
				d2 = sd.duplicate(true)
				d2["_mapKey"] = tk
		var built := build(d2, sub_val, func(v2):
			value[sub_key] = v2
			on_set.call(value), option_resolver, key_mode)
		box.add_child(Kit.field_row(str(sd.get("name", sub_key)), built.ctl, 96))
		commits.append(built.commit)
	return {"ctl": panel, "commit": func():
		for c in commits:
			if c is Callable and (c as Callable).is_valid():
				(c as Callable).call()
		on_set.call(value)}

## choice：options[] 声明（或 source 动态解析）→ 单选 OptionButton / multiple 勾选组。
## 值不在选项里时保留原值并额外插一条「(当前值)」——绝不静默改成第一项。
static func _build_choice(decl: Dictionary, value, on_set: Callable,
		option_resolver: Callable, key_mode := "id") -> Dictionary:
	if bool(decl.get("multiple", false)):
		return _build_choice_multi(decl, value, on_set, option_resolver)
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
	# 引用型字段给显式空态（C10）：选中「未设置」= 删键，而不是被逼在旧值里打转
	var empty_ok := RefFields.wants_empty_option(decl)
	if empty_ok:
		opt.add_item("（未设置）")
		opt.set_item_metadata(0, "")
		if cur == "":
			idx = 0
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

## choice multiple：每选项一个勾选框；值 = 按选项顺序收集的已勾 v 列表（存字符串数组）。
## 值不在选项集里的残留项照单选口径保留——显示为「(当前值)」行，取消勾选 = 明确移除。
static func _build_choice_multi(decl: Dictionary, value, on_set: Callable,
		option_resolver: Callable) -> Dictionary:
	var opts: Array = []
	if decl.get("options", null) is Array:
		for o in decl.get("options", []):
			opts.append(_norm_option(o))
	elif option_resolver.is_valid():
		for o in option_resolver.call(decl):
			opts.append(_norm_option(o))
	var chosen: Array = []
	# 多选必须是数组（C06）：标量旧值不能被包成单元素数组——那是形状改写，
	# 一勾一取消就把原来的字符串写成了列表。非法旧值只读 + 显式替换。
	if not _is_unset(value) and not (value is Array):
		return _readonly(decl, value, "值类型不符：声明多选（数组），实际是 %s" % type_name(value),
			"勾选组不会自动改写它：确认要清空后再写一次")
	if value is Array:
		for x in value:
			chosen.append(str(x))
	var known := {}
	for o in opts:
		known[str((o as Dictionary).get("v", ""))] = true
	var pend := {"v": chosen.duplicate()}
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	for o in opts:
		var ov := str((o as Dictionary).get("v", ""))
		var cb := CheckBox.new()
		cb.text = str((o as Dictionary).get("t", ""))
		cb.button_pressed = chosen.has(ov)
		cb.toggled.connect(func(on: bool):
			if on and not pend.v.has(ov):
				pend.v.append(ov)
			elif not on:
				pend.v.erase(ov)
			on_set.call(pend.v.duplicate()))
		box.add_child(cb)
	for extra in chosen:
		var ev := str(extra)
		if known.has(ev):
			continue
		var cb2 := CheckBox.new()
		cb2.text = "(当前值) " + ev
		cb2.button_pressed = true
		cb2.toggled.connect(func(on: bool):
			if not on:
				pend.v.erase(ev)
			on_set.call(pend.v.duplicate()))
		box.add_child(cb2)
	return {"ctl": box, "commit": Callable()}

static func _norm_option(o) -> Dictionary:
	if o is Dictionary:
		var v := str((o as Dictionary).get("v", ""))
		var t := str((o as Dictionary).get("t", v))
		return {"v": v, "t": t if t != "" else v}
	return {"v": str(o), "t": str(o)}

## 只读展示：结构可见（JSON 一行），不可写；下面一行黄字说明为什么。
static func _readonly(_decl: Dictionary, value, why: String, hint: String) -> Dictionary:
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

## viewport_ref（C5）：视口归一化坐标域工作值 {viewport: id, point: [nx, ny] | rect: [nx, ny, nw, nh]}。
## 视口 id 候选 = viewport: 解析器（清单 viewports 具名画幅）；rect: true 声明切矩形模式。
## 非字典坏值只读展示；未知键不碰（未知版本往返）。
static func _build_viewport_ref(decl: Dictionary, value, on_set: Callable, option_resolver: Callable) -> Dictionary:
	var is_rect := bool(decl.get("rect", false))
	if not (value is Dictionary) and not _is_unset(value):
		return _readonly(decl, value, "值类型不符：声明 viewport_ref，实际是 %s" % type_name(value), "编辑器不会改写它")
	if not (value is Dictionary):
		value = {}
	var cur: Dictionary = (value as Dictionary).duplicate(true)
	var emit := func(): on_set.call(cur.duplicate(true))
	var wrap := Kit.vbox(4)
	var d2: Dictionary = decl.duplicate(true)
	d2["kind"] = KIND_CHOICE
	d2["source"] = "viewport:"
	var vp_id := str(cur.get("viewport", ""))
	var vpb := _build_choice(d2, vp_id, func(v2):
		cur["viewport"] = str(v2)
		emit.call(), option_resolver)
	wrap.add_child(vpb.ctl)
	# 归一化坐标 0..1：point 两轴 / rect 四轴（SpinBox 即改即写，幂等由下游保证）
	var dims := 4 if is_rect else 2
	var key := "rect" if is_rect else "point"
	var arr: Array = (cur.get(key, [0.0, 0.0, 1.0, 1.0] if is_rect else [0.0, 0.0]) as Array)
	var row := Kit.hbox(4)
	for d in dims:
		var sp := SpinBox.new()
		sp.min_value = 0.0
		sp.max_value = 1.0
		sp.step = 0.01
		sp.value = float(arr[d]) if d < arr.size() else 0.0
		sp.value_changed.connect(func(v3):
			var a2: Array = (cur.get(key, [0.0, 0.0, 1.0, 1.0] if is_rect else [0.0, 0.0]) as Array).duplicate()
			while a2.size() <= d:
				a2.append(0.0)
			a2[d] = v3
			cur[key] = a2
			emit.call())
		row.add_child(sp)
	wrap.add_child(row)
	return {"ctl": wrap, "commit": emit}