extends "res://tests/_suite_base.gd"
## 功能/条件声明域：归一化、跨功能字段码查重、steps 标记、条件补码避让。

const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")

func _mk_fn(code: String, fa: String, fb: String) -> Dictionary:
	return {"name": "N", "code": code, "fields": [
		{"id": "a", "code": fa, "kind": "input", "type": "string", "default": ""},
		{"id": "b", "code": fb, "kind": "input", "type": "string", "default": ""}]}

func test_normalization_dict_form() -> void:
	var m := {"functions": {"door": _mk_fn("F111", "A111", "A222")}}
	var f: Dictionary = FunctionDecls.functions(m)["door"]
	eq(str(f.get("name")), "N", "显示名")
	eq(str(f.get("code")), "F111", "执行码")
	eq((f.get("fields") as Array).size(), 2, "字段数")

func test_steps_flag_survives() -> void:
	var m := {"functions": {"d": {"name": "x", "code": "F333", "steps": true}}}
	eq(bool(FunctionDecls.functions(m)["d"].get("steps", false)), true, "steps 标记保留（审查 P0 核实点）")

func test_array_form_name_default() -> void:
	var m := {"functions": [{"id": "f", "code": "F222"}]}
	var f: Dictionary = FunctionDecls.functions(m)["f"]
	eq(str(f.get("name")), "f", "缺名回退 id")

func test_duplicate_fn_code() -> void:
	var m := {"functions": {"x": _mk_fn("F111", "A111", "A222"), "y": _mk_fn("F111", "A333", "A444")}}
	ok(FunctionDecls.duplicate_codes(m).size() >= 1, "功能码重复被查出")

func test_duplicate_field_code_cross_function() -> void:
	var m := {"functions": {"x": _mk_fn("F111", "A111", "A222"), "y": _mk_fn("F222", "A111", "A444")}}
	ok(FunctionDecls.duplicate_codes(m).size() >= 1, "字段码跨功能重复被查出（审查 P2-1 修复点）")

func test_no_duplicate_clean() -> void:
	var m := {"functions": {"x": _mk_fn("F111", "A111", "A222"), "y": _mk_fn("F222", "A333", "A444")}}
	eq(FunctionDecls.duplicate_codes(m).size(), 0, "干净清单零报告")

func test_conditions_normalization() -> void:
	var m := {"conditions": [{"id": "has_item", "name": "持有物品",
		"fields": [{"id": "item", "code": "C111", "kind": "input", "type": "string", "default": ""}]}]}
	var conds := ConditionDecls.conditions(m)
	eq(conds.size(), 1, "条件池归一化")
	eq(str(conds["has_item"].get("name")), "持有物品", "条件名")

func test_condition_ensure_codes_avoids_functions() -> void:
	var m := {
		"functions": {"f": {"name": "n", "code": "F111",
			"fields": [{"id": "a", "code": "AAAA", "kind": "input", "type": "string", "default": ""}]}},
		"conditions": [{"id": "c", "fields": [{"id": "x", "kind": "input", "type": "string", "default": ""}]}],
	}
	ConditionDecls.ensure_codes(m)
	var fc := str((m.conditions[0].fields[0] as Dictionary).get("code", ""))
	eq(fc.length(), 4, "条件字段码补发 4 位")
	ok(fc != "AAAA", "避开功能已占码")
