extends "res://tests/_suite_base.gd"
## C1：引用字段描述、类型严格性、配对地图字段与地图目录校验（C06/C07/C10）。

const RefFields := preload("res://src/content/ref_fields.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const V := preload("res://src/project/manifest_validation.gd")

## —— C10：asset::id 保留空段（旧 split(":", false) 会把 ID 当 kind） ——
func test_describe_asset_keeps_empty_kind() -> void:
	var d := RefFields.describe({"kind": "choice", "source": "asset::AB23"})
	eq(str(d.kind), "asset", "空 kind 仍是资产引用")
	eq(str((d.filter as Dictionary).get("kind", "")), "", "kind 段为空（不被 ID 顶替）")
	eq(d.filter.get("ids", []), ["AB23"], "ID 过滤独立传入")
	var d2 := RefFields.describe({"kind": "choice", "source": "asset:scene:A1,B2"})
	eq(str((d2.filter as Dictionary).get("kind", "")), "scene", "kind 解析")
	eq(d2.filter.get("ids", []), ["A1", "B2"], "多 ID 过滤")
	var d3 := RefFields.describe({"kind": "choice", "source": "asset:scene"})
	eq(d3.filter.get("ids", []), [], "无过滤 = 空列表")

## —— C10：引用来源种类与实例配对 ——
func test_describe_ref_kinds() -> void:
	var same := RefFields.describe({"kind": "choice", "source": "entity_inst:door,exit"})
	eq(str(same.kind), "entity_inst", "实例引用")
	eq(str(same.scope), "same_map", "无 mapField = 本图")
	eq(same.filter.get("ids", []), ["door", "exit"], "of 白名单")
	ok(bool(same.is_ref), "标记为引用")
	var paired := RefFields.describe({"kind": "choice", "source": "entity_inst:door", "mapField": "target_map"})
	eq(str(paired.scope), "map_ref", "有 mapField = 目标图域")
	eq(str(paired.map_field), "target_map", "mapField 透传")
	var er := RefFields.describe({"type": "entity_ref", "mapField": "target_map", "of": "door"})
	eq(str(er.kind), "entity_inst", "entity_ref 归一成实例引用")
	eq(str(er.scope), "map_ref", "entity_ref + mapField = 目标图")
	var mr := RefFields.describe({"type": "map_ref"})
	eq(str(mr.kind), "map", "map_ref → 地图")
	ok(bool(mr.allow_empty), "地图引用带空态")

## —— C10：空项策略 ——
func test_empty_option_policy() -> void:
	ok(RefFields.wants_empty_option({"type": "entity_ref"}), "实例引用默认带「未设置」")
	ok(RefFields.wants_empty_option({"type": "map_ref"}), "地图引用默认带「未设置」")
	ok(not RefFields.wants_empty_option({"type": "asset_ref"}), "资产引用默认不带空项")
	ok(RefFields.wants_empty_option({"type": "asset_ref", "allowEmpty": true}), "allowEmpty 显式开启")
	ok(not RefFields.wants_empty_option({"kind": "choice", "options": ["a"]}), "固定选项不带空项")

## —— C07：功能 id 与内容目录同一条规则（dlg.one 必须被拒） ——
func test_function_id_folder_rule() -> void:
	ok(not ContentStore.is_valid_kind("dlg.one"), "带点功能 id 不是合法目录名")
	ok(ContentStore.is_valid_kind("dialogue"), "普通 id 合法")
	ok(not ContentStore.is_valid_kind("a/b"), "分隔符非法")
	ok(not ContentStore.is_valid_kind(""), "空 id 非法")
	eq(ContentStore.path_for({"_dir": "C:/x"}, "dlg.one", "C-1"), "", "带点 kind 产不出路径")
	var m := {"functions": {"dlg.one": {"code": "F111"}}}
	var errs := []
	for e in V.validate(m):
		if str(e.get("severity")) == "error":
			errs.append(str(e.get("path")))
	ok(errs.size() >= 1, "清单校验拒绝 dlg.one：%s" % str(errs))

## —— C07：conditions 非数组不被归一成空数组 ——
func test_non_array_conditions_not_normalized() -> void:
	var m := {"functions": {"f": {"code": "F111", "conditions": "nope"}}}
	var norm := FunctionDecls.functions(m)
	eq(str(norm.f.get("conditions", null)), "nope", "非数组原样保留（不被洗成 []）")
	var errs2 := []
	for e in V.validate(m):
		if str(e.get("severity")) == "error":
			errs2.append(str(e.get("path")))
	ok(errs2.has("functions.f.conditions"), "校验报出具体键：%s" % str(errs2))
	# 缺键才补 []
	var m2 := {"functions": {"f": {"code": "F111"}}}
	eq(FunctionDecls.functions(m2).f.get("conditions", null), [], "缺键补空数组")

## —— C06：类型严格性（控件层） ——
func test_widget_type_strictness() -> void:
	# 三元素写给二维向量：只读兜底（ctl 是 VBox 里放只读 LineEdit），commit 不写
	var b := FieldWidgets.build({"kind": "input", "type": "vector2"}, [1, 2, 3], func(_v): pass)
	ok(b.ctl is VBoxContainer, "三元素向量 → 只读容器")
	ok(not (b.commit as Callable).is_valid(), "只读控件无提交器（空操作）")
	# 声明 dims:3 时三元合法
	var b3 := FieldWidgets.build({"kind": "input", "type": "vector2", "dims": 3}, [1, 2, 3], func(_v): pass)
	ok(b3.ctl is HBoxContainer, "dims:3 接受三元")
	eq(RefFields.vector_dims({"dims": 3}), 3, "维数解析")
	eq(RefFields.vector_dims({"dims": 5}), 2, "非法维数回退 2")
	eq(FieldWidgets.default_for({"kind": "input", "type": "vector2", "dims": 3}), [0.0, 0.0, 0.0], "三维缺省值")
	# 布尔字符串：不能被 bool() 当真
	var bb := FieldWidgets.build({"kind": "input", "type": "bool"}, "false", func(_v): pass)
	ok(bb.ctl is VBoxContainer, "字符串 \"false\" → 只读容器")
	var bb2 := FieldWidgets.build({"kind": "input", "type": "bool"}, true, func(_v): pass)
	ok(bb2.ctl is CheckBox, "真布尔 → 勾选框")
	# 多选标量：只读，不包成单元素数组
	var mm := FieldWidgets.build({"kind": "choice", "multiple": true, "options": ["a", "b"]}, "a", func(_v): pass)
	ok(mm.ctl is VBoxContainer, "多选标量旧值 → 只读容器")
	var mm2 := FieldWidgets.build({"kind": "choice", "multiple": true, "options": ["a", "b"]}, ["a"], func(_v): pass)
	ok(mm2.ctl is VBoxContainer, "多选数组 → 勾选组")

## —— C10：数组元素继承范围/选项 ——
func test_array_elem_inherits_decl() -> void:
	var elem := FieldWidgets._elem_decl({"kind": "input", "type": "array", "of": "int", "min": 3, "max": 9})
	eq(int(elem.get("min", 0)), 3, "元素继承 min")
	eq(int(elem.get("max", 0)), 9, "元素继承 max")
	var elem2 := FieldWidgets._elem_decl({"kind": "input", "type": "array", "of": "choice",
		"options": ["x", "y"], "multiple": true})
	ok(bool(elem2.get("multiple", false)), "choice 元素继承 multiple")
	eq(elem2.get("options", []), ["x", "y"], "choice 元素继承 options")
	var elem3 := FieldWidgets._elem_decl({"kind": "input", "type": "array", "of": "asset_ref",
		"assetKind": "entity", "ids": ["A1", "B2"]})
	eq(str(elem3.get("assetKind", "")), "entity", "asset_ref 元素继承 assetKind")
	eq(str(elem3.get("of", "")), "A1,B2", "ids 白名单转成元素 of")

## —— E2：画布连线的本图引用筛选与目标类型白名单 ——
## 连线只列「落点能在本图解出来」的引用：跨图配对（target_map 指向别的图）不列；
## 配对地图留空或写本图码/本图名 = 本图。目标实例必须落在声明的 of 白名单内。
func test_local_entity_refs_and_accepts() -> void:
	var ad := {"fields": [
		{"id": "target_point", "type": "entity_ref", "of": "portal,spawn", "mapField": "target_map"},
		{"id": "target_map", "type": "map_ref"},
		{"id": "route", "type": "entity_ref"},
		{"id": "note", "type": "input", "input": "string"},
	]}
	# 配对地图留空 = 本图：两条引用都列；非引用字段不列
	var props := {"target_point": "AAAA", "route": "BBBB"}
	var rows := RefFields.local_entity_refs(ad, props, "m1", "M1CD")
	eq(rows.size(), 2, "本图引用两条（跨图字段不填 = 本图）")
	eq(str((rows[0].fd as Dictionary).get("id", "")), "target_point", "保持声明顺序")
	eq(str((rows[0] as Dictionary).get("value", "")), "AAAA", "带出当前值")
	# 配对地图写本图码 = 仍算本图；写别的图码/图名 = 不列
	eq(RefFields.local_entity_refs(ad, {"target_map": "M1CD", "target_point": "AAAA"}, "m1", "M1CD").size(), 2,
		"配对地图写本图码仍是本图")
	eq(RefFields.local_entity_refs(ad, {"target_map": "m1", "target_point": "AAAA"}, "m1", "M1CD").size(), 2,
		"配对地图写本图名仍是本图（老数据）")
	eq(RefFields.local_entity_refs(ad, {"target_map": "ZZZZ", "target_point": "AAAA"}, "m1", "M1CD").size(), 1,
		"配对地图指向别的图：该引用不参与本图连线")
	# map_key_local 的单点判定
	ok(RefFields.map_key_local("", "m1", "M1CD"), "空键 = 本图")
	ok(not RefFields.map_key_local("ZZZZ", "m1", "M1CD"), "别的图码 = 跨图")
	# of 白名单：空 = 不限；非空只收列出的资产
	ok(RefFields.field_accepts({"type": "entity_ref"}, "anything"), "of 为空不限制目标类型")
	ok(RefFields.field_accepts({"type": "entity_ref", "of": "portal,spawn"}, "spawn"), "白名单内可连")
	ok(not RefFields.field_accepts({"type": "entity_ref", "of": "portal"}, "chest"), "白名单外不可连")
	# ref_fields 只挑 entity_ref（map_ref / 普通字段不算）
	eq(RefFields.ref_fields(ad).size(), 2, "只列 entity_ref 字段")
