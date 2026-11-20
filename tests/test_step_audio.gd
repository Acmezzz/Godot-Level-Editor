extends "res://tests/_suite_base.gd"
## 步骤池/音频池/时机池：归一化、码查询、补码避让三池占用。

const StepDecls := preload("res://src/content/step_decl.gd")
const StepTimeline := preload("res://src/content/step_timeline.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
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

func test_trigger_pool_and_codes() -> void:
	var m := {"triggers": [
		{"id": "on_enter", "name": "进入地图"},
		{"id": "on_touch", "name": "触碰", "code": "T222"},
	]}
	ok(TriggerDecls.ensure_codes(m), "缺码补发")
	var all := TriggerDecls.triggers(m)
	eq(all.size(), 2, "时机池归一化")
	eq(str(all["on_enter"].get("name")), "进入地图", "名称")
	eq(str(all["on_touch"].get("code")), "T222", "已有码不变")
	ok(str(all["on_enter"].get("code")).length() == 4, "补发 4 位码")
	eq(TriggerDecls.trigger_id_of(m, "T222"), "on_touch", "按码反查 id")
	eq(TriggerDecls.trigger_id_of(m, "NOPE"), "", "未知码返回空")
	ok(not ContentId.field_codes(m).has(str(all["on_touch"].get("code"))), "时机码不进字段码空间")

func test_timeline_defaults_linear() -> void:
	var steps := [
		{"step": "S111", "fields": {}, "duration": 1.5},
		{"step": "S111", "fields": {}},
		{"step": "at 2 秒起", "at": 2.0},
	]
	var tl := StepTimeline.to_timeline(steps)
	eq(tl.size(), 3, "时间轴视图 1:1")
	eq(float(tl[0].get("at")), 0.0, "首步从 0 起")
	eq(float(tl[1].get("at")), 1.5, "顺序累加")
	eq(float(tl[2].get("at")), 2.0, "显式 at 生效")
	eq(int(tl[0].get("track")), 0, "缺省轨道 0")
	ok(bool(tl[0].get("blocking")), "缺省阻塞")

func test_timeline_nonblocking_and_track() -> void:
	var steps := [
		{"step": "S111", "fields": {}, "duration": 2.0, "blocking": false},
		{"step": "S111", "fields": {}, "duration": 0.5},
		{"step": "S111", "fields": {}, "duration": 1.0, "track": 1},
	]
	var tl := StepTimeline.to_timeline(steps)
	eq(float(tl[1].get("at")), 0.0, "非阻塞不推游标：下一步与本步同刻开始")
	eq(int(tl[2].get("track")), 1, "轨道号透传")
	eq(float(tl[2].get("at")), 0.0, "不同轨游标独立")

func test_timeline_from_timeline_strips_defaults() -> void:
	var steps := [
		{"step": "S111", "fields": {}, "at": 2.5, "duration": 0.0, "track": 0, "blocking": true},
		{"step": "S111", "fields": {}, "duration": 1.0, "blocking": false},
	]
	var out := StepTimeline.from_timeline(steps)
	eq(out.size(), 2, "净化条数不变")
	ok(not (out[0] as Dictionary).has("duration"), "duration 0 剥键")
	ok(not (out[0] as Dictionary).has("track"), "track 0 剥键")
	ok(not (out[0] as Dictionary).has("blocking"), "blocking true 剥键")
	ok((out[0] as Dictionary).has("at"), "显式 at 保留")
	eq(float((out[1] as Dictionary).get("duration", 0.0)), 1.0, "非缺省 duration 保留")
	ok((out[1] as Dictionary).has("blocking"), "blocking false 保留")

func test_timeline_conflicts() -> void:
	var steps := [
		{"step": "S111", "fields": {}, "duration": 2.0},
		{"step": "S111", "fields": {}, "duration": 1.0, "at": 1.0},
		{"step": "S111", "fields": {}, "duration": 1.0, "track": 1},
		{"step": "S111", "fields": {}},
	]
	var cf := StepTimeline.conflicts(steps)
	eq(cf.size(), 1, "同轨重叠 1 对：%s" % str(cf))
	eq(int((cf[0] as Dictionary).get("a")), 0, "重叠起点")
	eq(int((cf[0] as Dictionary).get("b")), 1, "重叠终点")
	ok(not StepTimeline.conflicts([]).size(), "空数组无冲突")

