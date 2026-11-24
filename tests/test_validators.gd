extends "res://tests/_suite_base.gd"
## 清单校验：合法清单零错误；各类坏清单报出具体错误。

const V := preload("res://src/project/manifest_validation.gd")

func test_object_geometry_rejects_crossing_and_quantized_duplicates() -> void:
	var geometry := preload("res://src/map/object_geometry.gd")
	var poly := {"type": "poly"}
	ok(geometry.problem([[0,0], [10,10], [0,10], [10,0]], poly).contains("自交"), "reject crossed ring")
	ok(geometry.problem([[0,0], [0.001,0], [10,0], [10,10]], poly).contains("重合"), "check stored precision")
	eq(geometry.problem([[0,0], [10,0], [10,10], [5,5], [0,10]], poly), "", "accept concave contour")
	eq(geometry.problem([[0,0], [10,10], [0,10], [10,0]], {"type": "path"}), "", "allow crossings in a path")

func test_geometry_holes_require_strict_containment_and_subtract_fill() -> void:
	var geometry := preload("res://src/map/object_geometry.gd")
	var outer := [Vector2(0,0), Vector2(12,0), Vector2(12,10), Vector2(0,10)]
	var hole := [Vector2(3,2), Vector2(7,2), Vector2(7,7), Vector2(3,7)]
	var touching := [Vector2(0,1), Vector2(2,1), Vector2(2,4), Vector2(0,4)]
	eq(geometry.holes_problem(outer, [hole]), "", "valid enclosed ring")
	ok(geometry.holes_problem(outer, [touching]).contains("接触边界"), "touching exterior is invalid")
	ok(geometry.holes_problem(outer, [hole, hole]).contains("已有孔洞"), "overlapping holes are invalid")
	var rings: Array[PackedVector2Array] = [PackedVector2Array(outer), PackedVector2Array(hole)]
	var strips := geometry.fill_strips(rings)
	var area := 0.0
	for quad in strips:
		for i in quad.size():
			area += quad[i].cross(quad[(i + 1) % quad.size()]) * 0.5
	eq(area, 100.0, "the rendered area subtracts the hole")

func _good() -> Dictionary:
	return {
		"tileSize": 16,
		"assets": [
			{"id": "terrain", "kind": "scene", "shape": "tile", "atlas": "assets/t0.png"},
			{"id": "door", "kind": "entity", "prefab": "res://x/door.tscn"}],
		"functions": {"f1": {"name": "F", "code": "F111", "fields": [
			{"id": "a", "code": "A111", "kind": "input", "type": "string", "default": ""}]}},
	}

func test_good_manifest_zero_errors() -> void:
	var errs := V.validate(_good())
	var lines := []
	for e in errs:
		lines.append(str(e.get("path")) + " " + str(e.get("message")))
	eq(errs.size(), 0, "合法清单零错误：%s" % str(lines))

func _errs_of(data: Dictionary) -> Array:
	var out := []
	for e in V.validate(data):
		if str(e.get("severity")) == "error":
			out.append(str(e.get("path")))
	return out

func test_bad_field_kind() -> void:
	var m := _good()
	var f: Dictionary = m.functions.f1
	var fields: Array = f.get("fields", [])
	(fields[0] as Dictionary).erase("kind")
	ok(_errs_of(m).size() >= 1, "字段缺 kind 报错")

func test_step_code_dup_within_pool() -> void:
	var m := _good()
	m["steps"] = {"s": {"name": "步", "code": "S111"}, "s2": {"name": "步2", "code": "S111"}}
	ok(_errs_of(m).size() >= 1, "步骤码池内重复报错（条目码查重是池内，字段码才是跨池空间）")

func test_step_dict_value_not_object() -> void:
	var m := _good()
	m["steps"] = {"s": "坏值"}
	ok(_errs_of(m).size() >= 1, "步骤 dict 写法值非对象报错（审查 P2-3 修复点）")

func test_undeclared_condition_ref() -> void:
	var m := _good()
	var f: Dictionary = m.functions.f1
	f["conditions"] = ["nope"]
	ok(_errs_of(m).size() >= 1, "功能引用未声明条件报错")

func test_asset_id_dup() -> void:
	var m := _good()
	m["assets"] = [
		{"id": "door", "kind": "entity", "prefab": "p"},
		{"id": "door", "kind": "entity", "prefab": "p"}]
	ok(_errs_of(m).size() >= 1, "资产 id 重复报错")

func test_legacy_keys_retired() -> void:
	var m := _good()
	m["tiles"] = [{"id": "t0", "atlas": "a.png"}]
	ok(_errs_of(m).size() >= 1, "旧 tiles[] 键报错（零兼容，走迁移脚本）")

func test_entity_needs_prefab_or_visual() -> void:
	var m := _good()
	m["assets"] = [{"id": "ghost", "kind": "entity"}]
	ok(_errs_of(m).size() >= 1, "实体既无 prefab 也无 visual 报错")

func test_scene_needs_one_of_atlas_texture() -> void:
	var m := _good()
	m["assets"] = [{"id": "bg", "kind": "scene", "shape": "image"}]
	ok(_errs_of(m).size() >= 1, "image 场景缺 texture 报错")

func test_audio_code_dup() -> void:
	var m := _good()
	m["audio"] = [
		{"id": "a", "name": "A", "path": "x.ogg", "code": "Z111"},
		{"id": "b", "name": "B", "path": "y.ogg", "code": "Z111"}]
	ok(_errs_of(m).size() >= 1, "音频码重复报错")

func test_cross_pool_field_code_dup() -> void:
	var m := _good()
	m["conditions"] = [{"id": "c", "fields": [
		{"id": "x", "code": "A111", "kind": "input", "type": "string", "default": ""}]}]
	ok(_errs_of(m).size() >= 1, "功能与条件字段码同码报错（三池一个码空间）")

func test_fn_id_charset() -> void:
	var m := _good()
	m["functions"] = {"中文功能": {"name": "N", "code": "F111"}}
	ok(_errs_of(m).size() >= 1, "功能 id 含非 ASCII 字符报错（内容目录/ID 段不可用）")

func test_trigger_pool_and_refs() -> void:
	var m := _good()
	m["triggers"] = [{"id": "on_enter", "code": "T111"}, {"id": "on_enter", "code": "T222"}]
	ok(_errs_of(m).size() >= 1, "时机 id 重复报错")
	var m2 := _good()
	m2["triggers"] = [{"id": "on_enter", "code": "T111"}, {"id": "on_enter", "code": "T111"}]
	ok(_errs_of(m2).size() >= 1, "时机码重复报错")
	var m3 := _good()
	m3["triggers"] = [{"id": "on_enter", "code": "T111"}]
	(m3.functions.f1 as Dictionary)["triggers"] = ["nope"]
	ok(_errs_of(m3).size() >= 1, "功能引用未声明时机报错")

func test_new_input_types_accepted() -> void:
	var m := _good()
	var fields: Array = (m.functions.f1 as Dictionary).get("fields", [])
	fields.append({"id": "tint", "code": "A222", "kind": "input", "type": "color", "default": "#ffffff"})
	fields.append({"id": "off", "code": "A333", "kind": "input", "type": "vector2", "default": [0, 0]})
	fields.append({"id": "curve", "code": "A444", "kind": "input", "type": "range", "default": 0.5, "min": 0.0, "max": 1.0})
	fields.append({"id": "asset", "code": "A555", "kind": "input", "type": "asset_ref", "default": ""})
	fields.append({"id": "arr", "code": "A666", "kind": "input", "type": "array", "of": "int", "default": []})
	fields.append({"id": "multi", "code": "A777", "kind": "choice", "options": ["a", "b"], "multiple": true, "default": []})
	eq(_errs_of(m).size(), 0, "新字段类型全部合法：%s" % str(_errs_of(m)))

func test_top_level_shapes_and_projection() -> void:
	var m0 := _good()
	eq(_errs_of(m0).size(), 0, "无顶层可选键 = 通过")
	var m1 := _good()
	m1["contentDir"] = 3
	ok(_errs_of(m1).size() >= 1, "contentDir 非字符串报错")
	var m2 := _good()
	m2["contentDir"] = "../evil"
	ok(_errs_of(m2).size() >= 1, "contentDir 含 .. 报错")
	var m3 := _good()
	m3["screenSize"] = [640]
	ok(_errs_of(m3).size() >= 1, "screenSize 不是 [w,h] 报错")
	var m4 := _good()
	m4["screenSize"] = [640, 360]
	eq(_errs_of(m4).size(), 0, "screenSize [640,360] 合法")
	var m5 := _good()
	(m5.assets as Array).append({"id": "t2", "kind": "scene", "shape": "tile", "atlas": "assets/t1.png", "gridProjection": "isometric"})
	eq(V.validate(m5).size(), 0, "assets can declare different grid projections")

## B1：tileSize 必须是正整数像素（拒绝零/负/小数），[w,h] 两正整数
func test_tile_size_integer_gate() -> void:
	var m := _good()
	m["tileSize"] = [32, 16]
	eq(_errs_of(m).size(), 0, "[32,16] 合法")
	var m2 := _good()
	m2["tileSize"] = 16
	eq(_errs_of(m2).size(), 0, "标量 16 合法")
	var m3 := _good()
	m3["tileSize"] = 16.0
	eq(_errs_of(m3).size(), 0, "JSON float 整数合法")
	for bad in [0, -16, 16.5, 0.0, [0, 16], [32, -1], [32, 16.5], "16", [32]]:
		var mb := _good()
		mb["tileSize"] = bad
		ok(_errs_of(mb).size() >= 1, "非法 tileSize 报错: %s" % str(bad))

func test_collision_types_decl() -> void:
	var m := _good()
	m["collisionTypes"] = {"ice": {"name": "冰面", "shape": "rect", "gameplay": "slide"}}
	eq(_errs_of(m).size(), 0, "合法碰撞类型池零错误")
	var m2 := _good()
	m2["collisionTypes"] = {"bad": {"name": "斜", "shape": "wedge"}}
	ok(_errs_of(m2).size() >= 1, "shape 非法报错")
	var m3 := _good()
	m3["collisionTypes"] = [{"id": "a"}, {"id": "a"}]
	ok(_errs_of(m3).size() >= 1, "数组写法 id 重复报错")

func test_playtest_structured_launch() -> void:
	var m := _good()
	m["playtest"] = {"executable": "game.exe", "args": ["--path", "%projectpath%", "--", "--map=%mapfile%"]}
	eq(_errs_of(m).size(), 0, "结构化启动声明零错误")
	var m2 := _good()
	m2["playtest"] = {"executable": 3}
	ok(_errs_of(m2).size() >= 1, "executable 非字符串报错")
	var m3 := _good()
	m3["playtest"] = {"args": ["ok", 5]}
	ok(_errs_of(m3).size() >= 1, "args 含非字符串报错")
	var m4 := _good()
	m4["playtest"] = {"args": "--map=%mapfile%"}
	ok(_errs_of(m4).size() >= 1, "args 非数组报错")
	# 缺 playtest 键 = 空字典语义，零错误也不崩
	eq(_errs_of(_good()).size(), 0, "缺 playtest 不报错")

## A6：%mapfile% / %projectpath% 在参数数组里逐项替换，路径含空格不破坏分段
func test_playtest_arg_substitution() -> void:
	var m := _good()
	m["_dir"] = "D:/proj with space"
	var mapp := "D:/proj with space/maps/a.json"
	var args: Array = ["--path", "%projectpath%", "--", "--map=%mapfile%"]
	var out: Array = []
	for a in args:
		out.append(preload("res://src/project/manifest.gd").substitute_vars_raw(str(a), mapp, str(m.get("_dir", ""))))
	eq(str(out[1]), "D:/proj with space", "projectpath 替换")
	eq(str(out[3]), "--map=D:/proj with space/maps/a.json", "mapfile 替换（含空格原样）")
	eq(str(out[0]), "--path", "无变量参数不变")

func test_playtest_entry_functions() -> void:
	var m := _good()
	m["playtest"] = {"executable": "game.exe", "projectEntry": true, "entryFunctions": ["f1"]}
	eq(_errs_of(m).size(), 0, "accept a declared project entry function")
	m.playtest.entryFunctions = ["f1", "f1", "unknown"]
	eq(_errs_of(m).size(), 2, "reject duplicate and unknown entry functions")
	m.playtest.entryFunctions = ["f1"]
	m.playtest.projectEntry = false
	eq(_errs_of(m).size(), 1, "entry functions require project entry support")

func test_screen_playtest_and_map_pairs() -> void:
	var m := _good()
	m["playtest"] = {"viewEntry": true}
	eq(_errs_of(m).size(), 1, "a direct screen entry needs the structured launch")
	m.playtest["executable"] = "game.exe"
	m.playtest["viewDraft"] = true
	eq(_errs_of(m).size(), 1, "draft launch requires a load receipt")
	m.playtest["report"] = true
	var record := {"id": "targets", "kind": "input", "type": "array", "of": "record", "fields": [
		{"id": "map", "kind": "choice", "source": "map"},
		{"id": "floor", "kind": "choice", "source": "layer:", "mapField": "map"},
		{"id": "start", "kind": "input", "type": "vector2", "pickSpace": "layer", "layerField": "floor", "mapField": "map"},
	]}
	m["screenModules"] = {"relay": {"fields": [record]}}
	eq(_errs_of(m).size(), 0, "screen launch does not require a project-content entry or an open map")
	record.fields[1]["mapField"] = "missing"
	eq(_errs_of(m).size(), 2, "reject a missing sibling map and a mismatched coordinate layer")


func test_curve_field_authoring() -> void:
	var widgets := preload("res://src/ui/field_widgets.gd")
	var curve := preload("res://src/content/keyframe_curve.gd")
	var store := preload("res://src/content/content_store.gd")
	var manifest := _good()
	var field := {"id": "zoom", "kind": "input", "type": "curve", "code": "A111"}
	manifest.functions.f1.fields = [field]
	eq(_errs_of(manifest), [], "a game can expose a continuous parameter")
	var project := OS.get_user_data_dir().path_join("curve-test-%s" % Time.get_ticks_usec())
	manifest["_dir"] = project
	var cid := "project-camera"
	var built := widgets.build(field, null, func(value):
		return store.write(manifest, "f1", cid, {"scope": "project", "function": "F111", "fields": {"A111": value}}))
	var editor: Control = built.ctl
	var graph: Control = editor.get_node("KeyframeGraph")
	graph.size = Vector2(200, 120)
	for uv in [Vector2(0.25, 0.2), Vector2(0.75, 0.8)]:
		var mouse := InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.position = Vector2(9, 9) + (graph.size - Vector2(18, 18)) * Vector2(uv.x, 1.0 - uv.y)
		mouse.pressed = true
		graph.gui_input.emit(mouse)
		mouse.pressed = false
		graph.gui_input.emit(mouse)
	var first := InputEventMouseButton.new()
	first.button_index = MOUSE_BUTTON_LEFT
	first.position = Vector2(9, 9) + (graph.size - Vector2(18, 18)) * Vector2(0.25, 0.8)
	first.pressed = true
	graph.gui_input.emit(first)
	first.pressed = false
	graph.gui_input.emit(first)
	var mode: OptionButton = editor.find_child("KeyframeMode", true, false)
	mode.item_selected.emit(2)
	var payload := store.read(manifest, "f1", cid)
	var saved: Array = payload.get("fields", {}).get("A111", [])
	ok(curve.valid(saved) and saved.size() == 2, "authored points survive the content store")
	if saved.size() == 2:
		eq(saved[0].mode, "smooth", "the selected segment keeps its interpolation")
		ok(is_equal_approx(curve.interpolate(saved[0], saved[1], 0.25), 0.29375), "the stored segment gives the authored easing")
	editor.free()
	var file := store.path_for(manifest, "f1", cid)
	var dir := file.get_base_dir()
	var history := dir.path_join(".history")
	DirAccess.remove_absolute(file)
	for snapshot in DirAccess.get_files_at(history):
		DirAccess.remove_absolute(history.path_join(snapshot))
	DirAccess.remove_absolute(history)
	DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute(store.root_dir(manifest))
	DirAccess.remove_absolute(project)
