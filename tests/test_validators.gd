extends "res://tests/_suite_base.gd"
## 清单校验：合法清单零错误；各类坏清单报出具体错误。

const V := preload("res://src/manifest_validation.gd")

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
