extends "res://tests/_suite_base.gd"
## D2：TimelineClock 帧/拍换算、timePreview 声明解析（id→码）、小数帧标记与量化。

const TimelineClock := preload("res://src/content/timeline_clock.gd")
const V := preload("res://src/project/manifest_validation.gd")
const StepTimeline := preload("res://src/content/step_timeline.gd")

## 验收：60 fps 的第 12 帧预览 = 0.2 秒
func test_frames_to_seconds() -> void:
	var c := TimelineClock.new("frames", {"fps": 60.0})
	ok(c.is_ready(), "60fps 配置可用")
	eq(snappedf(c.seconds_at(12.0), 0.001), 0.2, "第 12 帧 = 0.2 秒")
	eq(snappedf(c.value_at(0.2), 0.001), 12.0, "0.2 秒 = 第 12 帧（逆换算）")
	eq(c.snap_step(), 1.0, "帧基吸附 1 帧")
	# 缺 fps：保留原单位，不假装能换算
	var bad := TimelineClock.new("frames", {})
	ok(not bad.is_ready(), "缺 fps 不可用")
	ok(bad.missing.size() > 0, "给出缺项说明")
	eq(bad.seconds_at(12.0), 12.0, "缺项时按原单位返回")

## 验收：0 拍 120 BPM、4 拍 60 BPM、首拍偏移 0.25 秒 → 第 6 拍 = 4.25 秒
func test_beats_constant_then_slow() -> void:
	var c := TimelineClock.new("beats", {
		"tempo": [{"beat": 0.0, "bpm": 120.0}, {"beat": 4.0, "bpm": 60.0}],
		"offset": 0.25,
	})
	ok(c.is_ready(), "变速段合法")
	# 0..4 拍 @120 = 2 秒；4..6 拍 @60 = 2 秒；+0.25 offset
	eq(snappedf(c.seconds_at(6.0), 0.001), 4.25, "第 6 拍 = 4.25 秒")
	eq(snappedf(c.seconds_at(0.0), 0.001), 0.25, "第 0 拍 = 首拍偏移")
	eq(snappedf(c.value_at(4.25), 0.001), 6.0, "逆换算回第 6 拍")

## 验收：跨变速的第 3 至第 5 拍 = 1.75 到 3.25 秒
func test_beats_cross_tempo_span() -> void:
	var c := TimelineClock.new("beats", {
		"tempo": [{"beat": 0.0, "bpm": 120.0}, {"beat": 4.0, "bpm": 60.0}],
		"offset": 0.25,
	})
	eq(snappedf(c.seconds_at(3.0), 0.001), 1.75, "第 3 拍 = 1.75 秒（3×0.5+0.25）")
	eq(snappedf(c.seconds_at(5.0), 0.001), 3.25, "第 5 拍 = 3.25 秒（2+1+0.25）")

## 变速段非法（BPM 非正 / 起点不递增）→ 不可用，按原单位
func test_invalid_tempo_rejected() -> void:
	var neg := TimelineClock.new("beats", {"tempo": [{"beat": 0.0, "bpm": -10.0}]})
	ok(not neg.is_ready(), "负 BPM 判非法")
	var zero := TimelineClock.new("beats", {"tempo": [{"beat": 0.0, "bpm": 0.0}]})
	ok(not zero.is_ready(), "0 BPM 判非法")
	var unordered := TimelineClock.new("beats", {
		"tempo": [{"beat": 0.0, "bpm": 120.0}, {"beat": 4.0, "bpm": 60.0}, {"beat": 2.0, "bpm": 90.0}]})
	ok(not unordered.is_ready(), "起点不严格递增判非法")
	eq(neg.seconds_at(4.0), 4.0, "非法时按原单位")

## 拍吸附：缺省每拍 4 格；声明 8 格
func test_beats_subdivision_snap() -> void:
	var c := TimelineClock.new("beats", {"tempo": [{"beat": 0.0, "bpm": 120.0}]})
	eq(c.subdivisions, 4, "缺省每拍 4 格")
	eq(snappedf(c.snap_step(), 0.001), 0.25, "吸附 1/4 拍")
	var c2 := TimelineClock.new("beats", {"tempo": [{"beat": 0.0, "bpm": 120.0}], "subdivisions": 8})
	eq(snappedf(c2.snap_step(), 0.001), 0.125, "8 格/拍吸附 1/8 拍")
	# 非法值退回缺省
	var c3 := TimelineClock.new("beats", {"tempo": [{"beat": 0.0, "bpm": 120.0}], "subdivisions": 0})
	eq(c3.subdivisions, 4, "0 格/拍退回缺省 4")

## 小数帧标记 + 量化（新录帧取整数）
func test_fractional_frames_mark_and_quantize() -> void:
	var steps := [
		{"step": "A", "at": 3.5, "duration": 2},
		{"step": "B", "at": 7, "duration": 1.25},
	]
	var bad := TimelineClock.fractional_frames(steps)
	eq(bad.size(), 2, "两处小数帧被标出：%s" % str(bad))
	eq(str((bad[0] as Dictionary).get("key", "")), "at", "标记 at")
	eq(str((bad[1] as Dictionary).get("key", "")), "duration", "标记 duration")
	var q: Array = TimelineClock.quantize_frames(steps)
	eq(int((q[0] as Dictionary).get("at", 0)), 4, "3.5 → 4")
	eq(int((q[1] as Dictionary).get("duration", 0)), 1, "1.25 → 1")
	eq(TimelineClock.fractional_frames(q).size(), 0, "量化后无小数帧")
	eq(float((steps[0] as Dictionary).get("at", 0.0)), 3.5, "原数组不被改动")

## timePreview 声明解析：字段 ID → 字段码，再从内容字段取值
func test_from_decl_resolves_ids_to_codes() -> void:
	var m := {
		"tileSize": 16,
		"functions": {"anim": {
			"name": "动画", "code": "A111", "timebase": "frames",
			"fields": [
				{"id": "fps", "code": "F111", "kind": "input", "type": "int"},
				{"id": "shape", "code": "S111", "kind": "input", "type": "string"},
			],
			"timePreview": {"fpsField": "fps", "audioField": "shape"},
		}},
	}
	var content := {"fields": {"F111": 60, "S111": "swing"}}
	var r := TimelineClock.from_decl(m, "anim", content)
	eq(str(r.get("timebase", "")), "frames", "时间基透传")
	var cfg: Dictionary = r.get("cfg", {})
	eq(float(cfg.get("fps", 0.0)), 60.0, "fps 按码取到值")
	eq((r.get("missing", []) as Array).size(), 0, "配置齐全无缺项")
	var clock := TimelineClock.new(str(r.get("timebase")), cfg)
	eq(snappedf(clock.seconds_at(12.0), 0.001), 0.2, "解析结果可直接换算")

## 缺参考参数：保留原单位 + 具体缺项（不静默退化成 0/1）
func test_from_decl_reports_missing() -> void:
	var m := {
		"tileSize": 16,
		"functions": {"anim": {
			"name": "动画", "code": "A111", "timebase": "frames",
			"fields": [{"id": "fps", "code": "F111", "kind": "input", "type": "int"}],
			"timePreview": {"fpsField": "fps"},
		}},
	}
	# 内容里 fps 未填
	var r := TimelineClock.from_decl(m, "anim", {"fields": {}})
	var missing: Array = r.get("missing", [])
	ok(missing.size() > 0, "缺项被报出：%s" % str(missing))
	var clock := TimelineClock.new(str(r.get("timebase")), r.get("cfg", {}))
	ok(not clock.is_ready(), "时钟不可用")
	eq(clock.seconds_at(12.0), 12.0, "原单位编辑保留")

## 变速段从内容步骤里抽：步骤 ID → 步骤码，字段 ID → 字段码
func test_from_decl_tempo_segments() -> void:
	var m := {
		"tileSize": 16,
		"functions": {"show": {
			"name": "演出", "code": "S111", "timebase": "beats", "steps": true,
			"fields": [{"id": "off", "code": "O111", "kind": "input", "type": "float"}],
			"timePreview": {"tempoStep": "tempo", "bpmField": "bpm", "offsetField": "off",
				"subdivisionsPerBeat": 4},
		}},
		"steps": [{"id": "tempo", "code": "T111", "name": "变速", "fields": [
			{"id": "bpm", "code": "B111", "kind": "input", "type": "int"}]}],
	}
	var content := {
		"fields": {"O111": 0.25},
		"steps": [
			{"step": "T111", "fields": {"B111": 120}},
			{"step": "T111", "at": 4, "fields": {"B111": 60}},
		],
	}
	var r := TimelineClock.from_decl(m, "show", content)
	eq((r.get("missing", []) as Array).size(), 0, "变速段解析成功：%s" % str(r.get("missing")))
	var cfg: Dictionary = r.get("cfg", {})
	var tempo: Array = cfg.get("tempo", [])
	eq(tempo.size(), 2, "两段变速")
	eq(float((tempo[0] as Dictionary).get("beat", -1.0)), 0.0, "首段起点 0")
	eq(float((tempo[0] as Dictionary).get("bpm", 0.0)), 120.0, "首段 BPM")
	eq(float((tempo[1] as Dictionary).get("beat", -1.0)), 4.0, "第二段起点 = 步骤 at")
	eq(float((tempo[1] as Dictionary).get("bpm", 0.0)), 60.0, "第二段 BPM")
	var clock := TimelineClock.new("beats", cfg)
	eq(snappedf(clock.seconds_at(6.0), 0.001), 4.25, "端到端：第 6 拍 = 4.25 秒")

## 声明校验：timePreview 引用未声明字段/步骤 = 错误；非正整数细分 = 错误
func test_time_preview_validation() -> void:
	var base := {
		"tileSize": 16,
		"assets": [{"id": "door", "kind": "entity", "prefab": "res://d.tscn"}],
		"functions": {"f1": {
			"name": "F", "code": "F111",
			"fields": [{"id": "fps", "code": "A111", "kind": "input", "type": "int"}],
			"timePreview": {"fpsField": "fps"},
		}},
	}
	eq(_errs(base).size(), 0, "合法 timePreview 零错误")
	var bad_field := base.duplicate(true)
	(bad_field.functions.f1 as Dictionary)["timePreview"] = {"fpsField": "nope"}
	ok(_errs(bad_field).size() >= 1, "引用未声明字段报错")
	var bad_sub := base.duplicate(true)
	(bad_sub.functions.f1 as Dictionary)["timePreview"] = {"subdivisionsPerBeat": 0}
	ok(_errs(bad_sub).size() >= 1, "0 细分报错")
	var bad_step := base.duplicate(true)
	(bad_step.functions.f1 as Dictionary)["timePreview"] = {"tempoStep": "ghost"}
	ok(_errs(bad_step).size() >= 1, "引用未声明步骤报错")
	var not_obj := base.duplicate(true)
	(not_obj.functions.f1 as Dictionary)["timePreview"] = "frames"
	ok(_errs(not_obj).size() >= 1, "timePreview 非对象报错")

func _errs(m: Dictionary) -> Array:
	var out := []
	for e in V.validate(m):
		if str(e.get("severity")) == "error":
			out.append(str(e.get("path")) + " " + str(e.get("message")))
	return out

## 秒基 + 无 timePreview：零配置也能用，原值即秒
func test_seconds_passthrough() -> void:
	var c := TimelineClock.new("seconds", {})
	ok(c.is_ready(), "秒基无需配置")
	eq(c.seconds_at(2.5), 2.5, "原值即秒")
	eq(c.snap_step(), 0.1, "秒基吸附 0.1")
	eq(StepTimeline.to_timeline([{"step": "A", "duration": 2}]).size(), 1, "与 D1 数据口径共存")

## 参考素材引用（D2）：audioField / frameAssetField 的 ID 也解析成执行码，交给界面取素材。
func test_refs_resolve_audio_and_frame_asset() -> void:
	var m := {
		"tileSize": 16,
		"functions": {"anim": {
			"name": "动画", "code": "A111", "timebase": "frames",
			"fields": [
				{"id": "fps", "code": "F111", "kind": "input", "type": "int"},
				{"id": "snd", "code": "S222", "kind": "input", "type": "asset_ref"},
				{"id": "sheet", "code": "S333", "kind": "input", "type": "asset_ref"},
			],
			"timePreview": {"fpsField": "fps", "audioField": "snd", "frameAssetField": "sheet"},
		}},
	}
	var r := TimelineClock.from_decl(m, "anim", {"fields": {"F111": 30}})
	var refs: Dictionary = r.get("refs", {})
	eq(str(refs.get("audioField", "")), "S222", "audioField → 字段码")
	eq(str(refs.get("frameAssetField", "")), "S333", "frameAssetField → 字段码")
	eq((r.get("missing", []) as Array).size(), 0, "只写引用不给值不算缺项")