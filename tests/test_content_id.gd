extends "res://tests/_suite_base.gd"
## content_id.gd：三池字段码收集器 + 五段身份码拼装 + 码形状。

const ContentId := preload("res://src/content/content_id.gd")

func test_field_codes_three_pools() -> void:
	var m := {
		"functions": {"f": {"fields": [{"id": "a", "code": "F111"}]}},
		"conditions": [{"id": "c", "fields": [{"id": "b", "code": "C111"}]}],
		"steps": {"s": {"fields": [{"id": "d", "code": "S111"}]}},
	}
	var seen := ContentId.field_codes(m)
	eq(seen.size(), 3, "三池字段码全收集")
	for c in ["F111", "C111", "S111"]:
		ok(seen.has(c), "含 %s" % str(c))

func test_field_codes_forms_and_empty() -> void:
	var m := {
		"functions": [{"id": "f", "fields": [{"id": "a", "code": "F222"}, {"id": "b", "code": ""}]}],
	}
	var dict_form := {"functions": {"f": {"fields": [{"id": "a", "code": "F333"}]}}}
	eq(ContentId.field_codes(m).size(), 1, "数组写法收集、空码忽略")
	ok(ContentId.field_codes(dict_form).has("F333"), "dict 写法收集")

func test_content_id_assembly() -> void:
	var cid := str(ContentId.content_id("MAP1", "ENT1", "INS1", "FUNC"))
	ok(cid.begins_with("MAP1-ENT1-INS1-FUNC-"), "前四段正确")
	eq(cid.length(), 26, "五段总长 26（4-4-4-4-6）")
	for miss in [["", "ENT1", "ID", "f"], ["MAP1", "", "ID", "f"],
			["MAP1", "ENT1", "", "f"], ["MAP1", "ENT1", "ID", ""]]:
		eq(str(ContentId.content_id(miss[0], miss[1], miss[2], miss[3])), "", "缺段返回空串")

func test_new_code_shape() -> void:
	for c in [ContentId.new_fn_code(), ContentId.new_inst_code(),
			ContentId.new_map_code(), ContentId.new_entity_code()]:
		eq(str(c).length(), 4, "4 位长度")
		for ch in str(c):
			ok(str(ContentId.CHARS).contains(ch), "字符集内: %s" % str(ch))
