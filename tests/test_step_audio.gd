extends "res://tests/_suite_base.gd"
## 步骤池/音频池：归一化、码查询、补码避让三池占用。

const StepDecls := preload("res://src/content/step_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const ContentId := preload("res://src/content/content_id.gd")

func test_steps_normalization() -> void:
	var m := {"steps": {"move_to": {"name": "走到目标", "code": "S111",
		"fields": [{"id": "dur", "code": "D111", "kind": "input", "type": "float", "default": 0.0}]}}}
	var all := StepDecls.steps(m)
	eq(all.size(), 1, "步骤池归一化")
	eq(str(all["move_to"].get("name")), "走到目标", "步骤名")
	eq(str(all["move_to"].get("code")), "S111", "条目码")

func test_step_by_code() -> void:
	var m := {"steps": {"wait": {"name": "等待", "code": "S222"}}}
	ok(StepDecls.step_by_code(m, "S222") != Dictionary(), "按码查到步骤")
	eq(StepDecls.step_by_code(m, "NOPE"), Dictionary(), "未知码返回空字典")
	eq(StepDecls.step_by_code(m, ""), Dictionary(), "空码返回空字典")

func test_step_ensure_codes_avoids_occupied() -> void:
	var m := {
		"functions": {"f": {"name": "n", "code": "F111",
			"fields": [{"id": "a", "code": "AAAA", "kind": "input", "type": "string", "default": ""}]}},
		"steps": {"s": {"name": "步",
			"fields": [{"id": "d", "kind": "input", "type": "float", "default": 0.0}]}},
	}
	StepDecls.ensure_codes(m)
	var s: Dictionary = m.steps.s
	eq(str(s.get("code", "")).length(), 4, "条目码补发 4 位")
	var fc := str((s.get("fields", [])[0] as Dictionary).get("code", ""))
	eq(fc.length(), 4, "字段码补发 4 位")
	ok(fc != "AAAA", "避开功能字段已占码")
	ok(ContentId.field_codes(m).has(fc), "新码已入占用表")

func test_audio_pool_and_codes() -> void:
	var m := {"audio": [
		{"id": "bgm_a", "name": "背景音乐A", "path": "assets/audio/bgm_a.ogg"},
		{"id": "bgm_b", "name": "背景音乐B", "path": "assets/audio/bgm_b.ogg"},
	]}
	AudioDecls.ensure_codes(m)
	var all := AudioDecls.audio(m)
	eq(all.size(), 2, "音频池归一化")
	var codes := []
	for aid in all:
		codes.append(str((all[aid] as Dictionary).get("code", "")))
	eq(codes.size(), 2, "两条码")
	ok(codes[0] != codes[1], "两条码不同")
	eq(str(all["bgm_a"].get("path")), "assets/audio/bgm_a.ogg", "path 保留")

