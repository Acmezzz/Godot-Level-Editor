extends "res://tests/_suite_base.gd"
## C1（§7.4）：record 数组字段——声明校验、元素声明与默认值、引用遍历、复制重映射。

const ManifestValidation := preload("res://src/project/manifest_validation.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const ClonePlan := preload("res://src/content/clone_plan.gd")
const MapStore := preload("res://src/map/map_store.gd")
const ScreenLayout := preload("res://src/project/screen_layout.gd")

func test_screen_layout_image_fit():
	var bounds := Rect2(0, 0, 100, 100)
	var clip := Rect2(25, 0, 75, 100)
	var size := Vector2(200, 100)
	var cover := ScreenLayout.image_placement(bounds, clip, size, "cover")
	eq(cover.dest, clip, "cover is clipped at the viewport boundary")
	eq(cover.source, Rect2(75, 0, 75, 100), "cover crops the corresponding source pixels")
	var contain := ScreenLayout.image_placement(bounds, bounds, size, "contain")
	eq(contain.dest, Rect2(0, 25, 100, 50), "contain centers the original aspect ratio")
	var stretch := ScreenLayout.image_placement(bounds, clip, size, "stretch")
	eq(stretch.source, Rect2(50, 0, 150, 100), "stretch uses the entire source before clipping")

func test_layout_localized_variant_and_schema() -> void:
	var button := {"id": "continue", "kind": "button", "anchors": [0.1, 0.2, 0.8, 0.4],
		"text": "Continue", "textLocales": {"pt": "Continuar", "pt-br": "Avançar"}}
	var manifest := {"views": [{"view_id": "menu", "layout": {"locales": ["pt", "pt-br"], "elements": [button]}}]}
	ok(ManifestValidation.validate(manifest).is_empty(), "localized layout is valid")
	eq(ScreenLayout.display_text(button, "PT_BR"), "Avançar", "normalized exact locale comes first")
	eq(ScreenLayout.display_text(button, "pt-PT"), "Continuar", "regional tags fall back to their parent")
	eq(ScreenLayout.display_text(button, "es"), "Continue", "missing translations retain source text")
	button.textLocales["en"] = "Next"
	ok(ManifestValidation.validate(manifest).any(func(issue): return str(issue.path).ends_with("textLocales.en")),
		"an undeclared translated locale is diagnosed at its value")

func test_focus_skips_clipped_target_and_cleans_removed_links() -> void:
	var layout := {"focusStart": "start", "elements": [
		{"id": "start", "kind": "button", "anchors": [0, 0, 0.2, 0.2], "focus": {"right": "hidden"}},
		{"id": "hidden", "kind": "button", "anchors": [0, 0, 0, 0], "offsets": [1000, 0, 1030, 30]},
		{"id": "fallback", "kind": "button", "anchors": [0.3, 0, 0.5, 0.2]},
	]}
	eq(ScreenLayout.focus_step(layout, layout.elements, "start", "right", Vector2(1280, 720)),
		"hidden", "an explicit visible target wins")
	eq(ScreenLayout.focus_step(layout, layout.elements, "start", "right", Vector2(720, 720)),
		"fallback", "a clipped explicit target falls back to visible spatial navigation")
	var data := {"views": [{"view_id": "menu", "layout": layout}]}
	layout.elements.remove_at(1)
	var issues := ManifestValidation.validate(data)
	ok(issues.any(func(issue): return str(issue.path).ends_with(".focus.right")), "stale input route is rejected")
	ScreenLayout.clear_focus_links(layout, layout.elements, "hidden")
	ok(ManifestValidation.validate(data).is_empty(), "deletion cleanup leaves a valid layout")

## 验收声明样例：配方 = 材料与数量；牌组 = 内容与张数；叙事选项 = 条件与目标
func _record_decl(subs: Array) -> Dictionary:
	return {"id": "ITEMS", "kind": "input", "type": "array", "of": "record", "code": "F001", "fields": subs}

func _manifest_with(fn_fields: Array) -> Dictionary:
	return {"functions": [{"id": "recipe", "name": "配方", "code": "FN01", "fields": fn_fields}]}

func _errors_of(issues: Array[Dictionary]) -> Array:
	var out: Array = []
	for it in issues:
		var d: Dictionary = it
		if str(d.get("severity", "")) == "error":
			out.append(str(d.get("message", "")))
	return out
## 有效 record 声明（配方材料+数量）不产错误
func test_validation_accepts_record_decl() -> void:
	var fd := _record_decl([
		{"id": "MAT", "kind": "input", "type": "asset_ref", "code": "F0011"},
		{"id": "QTY", "kind": "input", "type": "int", "code": "F0012", "min": 1},
	])
	var errs := _errors_of(ManifestValidation.validate(_manifest_with([fd])))
	eq(errs.size(), 0, "valid record decl has no errors: " + str(errs))

## of: record 缺 fields 数组 = 错误
func test_validation_rejects_record_without_fields() -> void:
	var fd := {"id": "ITEMS", "kind": "input", "type": "array", "of": "record"}
	var errs := _errors_of(ManifestValidation.validate(_manifest_with([fd])))
	ok(errs.size() >= 1, "missing fields array is an error")
	ok(str(errs).contains("record"), "error mentions record: " + str(errs))
## 子字段 kind 非法 = 错误；嵌套 record 合法
func test_validation_rejects_bad_subfield_and_accepts_nested() -> void:
	var bad := _record_decl([{"id": "X", "kind": "widget", "type": "string"}])
	var errs := _errors_of(ManifestValidation.validate(_manifest_with([bad])))
	ok(str(errs).contains("record sub-field kind"), "bad sub-kind reported: " + str(errs))
	var nested := _record_decl([{"id": "SUBS", "kind": "input", "type": "array", "of": "record",
		"fields": [{"id": "N", "kind": "input", "type": "string"}]}])
	var errs2 := _errors_of(ManifestValidation.validate(_manifest_with([nested])))
	eq(errs2.size(), 0, "nested record ok: " + str(errs2))

## 元素声明与默认值（field_widgets）
func test_elem_decl_and_default() -> void:
	var fd := _record_decl([{"id": "MAT", "kind": "input", "type": "string"}, {"id": "QTY", "kind": "input", "type": "int"}])
	var e := FieldWidgets._elem_decl(fd)
	eq(str(e.get("kind")), "record", "elem kind is record")
	eq(str(e.get("type")), "record", "elem type is record")
	eq((e.get("fields") as Array).size(), 2, "elem fields copied")
	var d = FieldWidgets.default_for(e)
	ok(d is Dictionary and (d as Dictionary).is_empty(), "record default is empty dict")
## RefFields 递归收集：顶层引用 + 记录行内引用（路径带 # 行维度）
func test_ref_fields_deep_paths() -> void:
	var ad := {"id": "box", "kind": "entity", "visual": {"type": "rect"}, "fields": [
		{"id": "TGT", "type": "entity_ref"},
		{"id": "ROWS", "type": "array", "of": "record", "fields": [
			{"id": "SUB", "type": "entity_ref", "mapField": "PMAP"},
			{"id": "PMAP", "type": "map_ref"},
		]}]}
	var got := RefFields.ref_fields_deep(ad)
	eq(got.size(), 3, "top ref + record sub refs (entity_ref + map_ref) collected")
	var p0 := (got[0] as Dictionary).get("path", []) as Array
	var p1 := (got[1] as Dictionary).get("path", []) as Array
	eq(str(p0[0]), "TGT", "top path")
	eq(str(p1[0]), "ROWS", "record field first")
	eq(str(p1[1]), "#", "row marker")
	eq(str(p1[2]), "SUB", "sub field id")
	var p2 := (got[2] as Dictionary).get("path", []) as Array
	eq(str(p2[2]), "PMAP", "map_ref inside record also collected")
## ClonePlan：记录行内 entity_ref 逐行重映射；配对地图字段写回行内
func test_clone_remaps_record_rows() -> void:
	var m := {"assets": [{"id": "box", "kind": "entity", "visual": {"type": "rect"}, "fields": [
		{"id": "ROWS", "type": "array", "of": "record", "fields": [
			{"id": "SUB", "type": "entity_ref", "mapField": "PMAP"},
			{"id": "PMAP", "type": "map_ref"}]}]}]}
	var row := {"code": "AAAA", "asset": "box", "x": 0, "y": 0,
		"props": {"ROWS": [{"SUB": "BBBB", "PMAP": ""}, {"SUB": "CCCC"}]}}
	var out := ClonePlan.remap_row(row, {"AAAA": "N1", "BBBB": "N2", "CCCC": "N3"}, {}, m,
		"", {}, null, {"meta": {"code": "M9"}}, "m1")
	var rows: Array = (out["props"] as Dictionary)["ROWS"]
	eq(str(((rows[0] as Dictionary)["SUB"])), "N2", "record ref remapped in group")
	eq(str(((rows[0] as Dictionary)["PMAP"])), "M9", "pair scope is the row")
	eq(str(((rows[1] as Dictionary)["SUB"])), "N3", "second row remapped")
	eq(str(((rows[1] as Dictionary).get("PMAP", ""))), "M9", "pair written to row")
## C3：assets[].ports 校验（id 非空唯一、x/y 数字、type 可选字符串）
func test_ports_validation() -> void:
	var m := {"assets": [{"id": "gate", "kind": "entity", "visual": {"type": "rect"}, "fields": [{"id": "WIRE", "type": "port_ref"}], "ports": [
		{"id": "A", "x": 0, "y": 0, "type": "in"},
		{"id": "B", "x": 16, "y": 0},
	]}]}
	var errs := _errors_of(ManifestValidation.validate(m))
	eq(errs.size(), 0, "valid ports decl ok: " + str(errs))
	var bad := {"assets": [{"id": "gate", "kind": "entity", "visual": {"type": "rect"}, "ports": [
		{"id": "A"}, {"id": "A"}, {"id": "B", "x": "no"}]}]}
	var errs2 := _errors_of(ManifestValidation.validate(bad))
	ok(errs2.size() >= 2, "dup id and non-number x both reported: " + str(errs2))

## C3：port_ref 描述、候选与复制重映射（双端口机关样例）
func test_port_ref_describe_candidates_remap() -> void:
	var m := {"assets": [{"id": "gate", "kind": "entity", "visual": {"type": "rect"}, "fields": [{"id": "WIRE", "type": "port_ref"}], "ports": [
		{"id": "A", "x": 0, "y": 0, "type": "in"}, {"id": "B", "x": 16, "y": 0, "type": "out"}]}]}
	var d := RefFields.describe({"id": "W", "type": "port_ref", "of": "in", "mapField": "PM"})
	eq(str(d.get("kind", "")), "port", "describe kind = port")
	ok(bool(d.get("is_ref", false)), "port_ref is a ref")
	m["_dir"] = "user://test_c1_records_tmp"
	m["_maps_dir"] = "user://test_c1_records_tmp/maps"
	var md := MapStore.new_map("m1", 40, 30)
	(md.get("meta", {}) as Dictionary)["code"] = "M1"
	md["objects"] = [{"code": "AAAA", "asset": "gate", "x": 0, "y": 0}]
	var werr := MapStore.write_error(m, md)
	eq(werr, "", "map with gate instance: " + werr)
	ok(MapStore.write(m, "m1", md), "map writes")
	var cands := RefFields.port_candidates(m, "m1", ["in"])
	eq(cands.size(), 1, "type filter keeps only port A")
	var got = JSON.parse_string(str((cands[0] as Dictionary).get("v", "")))
	ok(got is Dictionary and str((got as Dictionary).get("inst", "")) == "AAAA" and str((got as Dictionary).get("port", "")) == "A", "candidate is {map, inst, port}: " + str(got))
	# 复制重映射：组内 → map/inst 分量都换，port 不动
	var row := {"code": "AAAA", "asset": "gate", "x": 0, "y": 0, "props": {"WIRE": {"map": "", "inst": "AAAA", "port": "A"}}}
	var out := ClonePlan.remap_row(row, {"AAAA": "N1"}, {}, m, "", {}, null, {"meta": {"code": "M9"}}, "m1")
	var wire: Dictionary = (out["props"] as Dictionary)["WIRE"]
	eq(str(wire.get("map", "")), "M9", "map component -> target map")
	eq(str(wire.get("inst", "")), "N1", "inst component -> new code")
	eq(str(wire.get("port", "")), "A", "port component kept")
## C5：具名参考画幅 viewports 与只读参考 views 的声明校验
func test_viewports_views_validation() -> void:
	var m := {"viewports": [{"id": "wide", "w": 1920, "h": 1080}, {"id": "tall", "w": 720, "h": 1280}],
		"views": [{"view_id": "mapView", "image": "a.png", "pixel_size": 2,
			"hotspots": [{"rect": [0.1, 0.2, 0.3, 0.3], "target": {"inst": "AAAA"}}]}]}
	var errs := _errors_of(ManifestValidation.validate(m))
	eq(errs.size(), 0, "valid viewports/views ok: " + str(errs))
	var bad := {"viewports": [{"id": "wide", "w": 100, "h": 50}, {"id": "wide", "w": -3, "h": 50}],
		"views": [{"view_id": "v", "pixel_size": 0, "hotspots": [{"rect": [0.1, 0.2, 1.4, 0.3]}]}]}
	var errs2 := _errors_of(ManifestValidation.validate(bad))
	ok(errs2.size() >= 3, "dup id + bad pixel_size + out-of-range rect reported: " + str(errs2))
