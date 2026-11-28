extends RefCounted
## 时间标尺换算（D2）：把步骤的 at/duration 从**原始单位**换算成秒，供预览/试听对齐。
## 纯数据工具，不碰 UI、不写盘；游戏行为仍由试玩验证，这里的秒数只用于编辑器内对齐。
##
## 三种时间基：
##   seconds 秒（缺省）—— 原值即秒
##   frames  帧 —— value / fps
##   beats   拍 —— 变速段累加：从第 0 拍起，每段（起点 BPM）折线换算
##
## 构造参数（全部由功能声明的 timePreview 解析而来，缺项时对应能力不可用）：
##   fps 帧率（> 0）；offset 首拍偏移秒数；tempo 变速段 [{beat, bpm}]（beat 严格递增、从 0 起）；
##   subdivisions 每拍格数（界面吸附用，缺省 4）；missing 缺项的人类可读说明。

const DEFAULT_SUBDIVISIONS := 4

## 时间基：seconds / frames / beats（非法值按 seconds）。
var timebase := "seconds"
var fps := 0.0            # frames 基需要
var tempo: Array = []     # beats 基需要：[{beat: float, bpm: float}]，beat 严格递增
var beat_offset := 0.0    # 首拍偏移（秒）
var subdivisions := DEFAULT_SUBDIVISIONS
## 缺项说明（空 = 配置齐全）。非空时换算退回原单位（按 1:1 秒），供界面提示具体缺什么。
var missing: PackedStringArray = PackedStringArray()

## 配置是否可用于秒换算。
func is_ready() -> bool:
	return missing.is_empty()

func _init(tb := "seconds", cfg := {}) -> void:
	timebase = tb if ["seconds", "frames", "beats"].has(tb) else "seconds"
	fps = float(cfg.get("fps", 0.0))
	beat_offset = float(cfg.get("offset", 0.0))
	var sub := int(cfg.get("subdivisions", DEFAULT_SUBDIVISIONS))
	subdivisions = sub if sub > 0 else DEFAULT_SUBDIVISIONS   # 非正 = 未配好，用缺省
	tempo = cfg.get("tempo", []) if cfg.get("tempo", null) is Array else []
	missing = PackedStringArray()
	if timebase == "frames":
		if not (is_finite(fps) and fps > 0.0):
			missing.append("帧率（fpsField 未填或不是正数）")
	elif timebase == "beats":
		var ok_tempo := not tempo.is_empty()
		var prev := -INF
		for seg in tempo:
			if not (seg is Dictionary):
				ok_tempo = false
				break
			var b := float((seg as Dictionary).get("beat", NAN))
			var v := float((seg as Dictionary).get("bpm", NAN))
			if not (is_finite(b) and is_finite(v) and v > 0.0 and b > prev):
				ok_tempo = false
				break
			prev = b
		if not ok_tempo:
			missing.append("变速段（tempoStep/bpmField 未配好，需有限正 BPM 与严格递增起点）")

## 原始单位 → 秒。配置不全时按 1:1 返回（保留原单位编辑），由界面显示缺项。
func seconds_at(value: float) -> float:
	if timebase == "frames":
		if not (is_finite(fps) and fps > 0.0):
			return value
		return value / fps
	if timebase == "beats":
		if not is_ready():
			return value
		return beat_offset + _beats_to_seconds(maxf(value, 0.0))
	return value

## 秒 → 原始单位（时间轴刻度反查用）。配置不全时按 1:1。
func value_at(seconds: float) -> float:
	if timebase == "frames":
		if not (is_finite(fps) and fps > 0.0):
			return seconds
		return seconds * fps
	if timebase == "beats":
		if not is_ready():
			return seconds
		return _seconds_to_beats(maxf(seconds - beat_offset, 0.0))
	return seconds

## Normalize a preview sample; missing conversion does not invent seconds.
func sample(value: float, unit := "") -> Dictionary:
	var input_unit: String = timebase if unit == "" else unit
	var sec := value if input_unit == "seconds" else (seconds_at(value) if is_ready() else NAN)
	var sample_point := {"value": value_at(sec) if is_ready() and input_unit != timebase else value,
		"unit": timebase if is_ready() else input_unit, "seconds": null}
	if is_finite(sec):
		sample_point.seconds = sec
	return sample_point

## 拍 → 秒：以第 0 拍开段，逐段累加 (拍差 × 60 / BPM)。
## 首段起点非零（声明里第一段 beat > 0）：0 拍..首段起点这段没有变速记录，
## 按首段 BPM 外推——否则这段恒算 0 秒，正向/反向换算在起点前不可逆（V4 P1）。
func _beats_to_seconds(beat: float) -> float:
	var sec := 0.0
	var cur_beat := 0.0
	var cur_bpm := 0.0
	if not tempo.is_empty():
		var b0 := float((tempo[0] as Dictionary).get("beat", 0.0))
		var v0 := float((tempo[0] as Dictionary).get("bpm", 0.0))
		if b0 > 0.0 and v0 > 0.0:
			cur_bpm = v0   # 首段之前的基底 BPM（外推）
	for seg in tempo:
		var b := float((seg as Dictionary).get("beat", 0.0))
		var v := float((seg as Dictionary).get("bpm", 0.0))
		if b > beat:
			break
		# 先结算上一段到本段起点
		if cur_bpm > 0.0:
			sec += (b - cur_beat) * 60.0 / cur_bpm
		cur_beat = b
		cur_bpm = v
	if cur_bpm > 0.0:
		sec += (beat - cur_beat) * 60.0 / cur_bpm
	return sec

## 秒 → 拍（逆换算；超出末段就按末段 BPM 外推）。
func _seconds_to_beats(sec: float) -> float:
	var acc := 0.0
	var cur_beat := 0.0
	var cur_bpm := 0.0
	if not tempo.is_empty():
		var b0 := float((tempo[0] as Dictionary).get("beat", 0.0))
		var v0 := float((tempo[0] as Dictionary).get("bpm", 0.0))
		if b0 > 0.0 and v0 > 0.0:
			cur_bpm = v0
	for seg in tempo:
		var b := float((seg as Dictionary).get("beat", 0.0))
		var v := float((seg as Dictionary).get("bpm", 0.0))
		var span := (b - cur_beat) * 60.0 / cur_bpm if cur_bpm > 0.0 else 0.0
		if cur_bpm > 0.0 and acc + span > sec:
			return cur_beat + (sec - acc) * cur_bpm / 60.0
		acc += span
		cur_beat = b
		cur_bpm = v
	if cur_bpm > 0.0:
		return cur_beat + (sec - acc) * cur_bpm / 60.0
	return sec

## 界面吸附粒度（原始单位）：frames 1 帧、beats 1/subdivisions 拍、seconds 0.1 秒。
func snap_step() -> float:
	if timebase == "frames":
		return 1.0
	if timebase == "beats":
		return 1.0 / float(maxi(1, subdivisions))
	return 0.1

## 已存小数帧的待修条目（D2）：frames 基下 at/duration 不是整数的步骤下标。
static func fractional_frames(steps: Array) -> Array:
	var out: Array = []
	for i in steps.size():
		if not (steps[i] is Dictionary):
			continue
		var st: Dictionary = steps[i]
		for key in ["at", "duration"]:
			if not st.has(key):
				continue
			var v := float(st.get(key, 0.0))
			if not is_equal_approx(v, roundf(v)):
				out.append({"index": i, "key": key, "value": v})
	return out

## 新录帧取整数：把帧基下的 at/duration 量化到整帧（只动这两个键）。
static func quantize_frames(steps: Array) -> Array:
	var out: Array = steps.duplicate(true)
	for st in out:
		if not (st is Dictionary):
			continue
		for key in ["at", "duration"]:
			if (st as Dictionary).has(key):
				(st as Dictionary)[key] = roundf(float((st as Dictionary).get(key, 0.0)))
	return out

## 解析 functions[].timePreview 声明 → 时钟配置。
## 声明里的 fpsField/audioField/offsetField 是**字段 ID**（人类名），内容里存的是**字段码**——
## 这里按功能字段声明把 ID 转成码，再从内容字段值里取值。
## tempoStep/bpmField 同理：步骤 ID → 步骤码，字段 ID → 字段码。
## 返回 {timebase, cfg:{fps, offset, tempo, subdivisions}, missing:[...], refs:{...}}。
## missing 里的条目是「声明了但解析不到」的具体缺项，界面据此提示，不阻断原单位编辑。
static func from_decl(manifest: Dictionary, fn_id: String, content: Dictionary) -> Dictionary:
	var FunctionDecls := preload("res://src/content/function_decl.gd")
	var decl: Dictionary = FunctionDecls.function_decl(manifest, fn_id)
	var base_unit := str(decl.get("timebase", "seconds"))
	if base_unit not in ["frames", "beats"]:
		base_unit = "seconds"
	var tp = decl.get("timePreview", null)
	var cfg := {"subdivisions": DEFAULT_SUBDIVISIONS}
	var missing_steps: Array = []
	var refs := {}
	if tp is Dictionary:
		var tpd: Dictionary = tp
		var subdivisions_value = tpd.get("subdivisionsPerBeat")
		if subdivisions_value is int or subdivisions_value is float:
			if subdivisions_value > 0 and subdivisions_value == floorf(float(subdivisions_value)):
				cfg["subdivisions"] = subdivisions_value
		var fields: Dictionary = content.get("fields", {}) if content.get("fields", null) is Dictionary else {}
		var fmap := _field_code_map(decl.get("fields", []))
		# 帧率
		var fps_key := str(tpd.get("fpsField", ""))
		if fps_key != "":
			var code := str(fmap.get(fps_key, ""))
			refs["fpsField"] = code
			var v = fields.get(code, null)
			if v == null or not (v is int or v is float) or float(v) <= 0.0:
				missing_steps.append("fpsField「%s」在内容里没有有限正数" % fps_key)
			else:
				cfg["fps"] = float(v)
		# 参考素材（D2）：只把 ID 解析成码，取用归界面（帧序列预览 / 音频定位）
		var audio_key := str(tpd.get("audioField", ""))
		if audio_key != "":
			refs["audioField"] = str(fmap.get(audio_key, ""))
		var fa_key := str(tpd.get("frameAssetField", ""))
		if fa_key != "":
			refs["frameAssetField"] = str(fmap.get(fa_key, ""))
		# 首拍偏移
		var off_key := str(tpd.get("offsetField", ""))
		if off_key != "":
			var ocode := str(fmap.get(off_key, ""))
			refs["offsetField"] = ocode
			var ov = fields.get(ocode, null)
			if ov is int or ov is float:
				cfg["offset"] = float(ov)
		# 变速段：tempoStep（步骤 ID）+ bpmField（该步骤字段 ID）
		var tempo_step := str(tpd.get("tempoStep", ""))
		if tempo_step != "":
			var step_code := _step_code_of(manifest, tempo_step)
			refs["tempoStep"] = step_code
			var bpm_key := str(tpd.get("bpmField", ""))
			var bpm_code := ""
			if step_code != "":
				var sd: Dictionary = preload("res://src/content/step_decl.gd").step_by_code(manifest, step_code)
				bpm_code = str(_field_code_map(sd.get("fields", [])).get(bpm_key, ""))
			refs["bpmField"] = bpm_code
			var segs := _tempo_segments(content.get("steps", []), step_code, bpm_code)
			if segs.is_empty():
				missing_steps.append("变速段「%s」在内容步骤里没有有效 BPM 段" % tempo_step)
			else:
				cfg["tempo"] = segs
	# 缺 fps/offset 不算致命以外的项：时钟自检会再统一给出可用性
	var clock := new(base_unit, cfg)
	for m in clock.missing:
		if not missing_steps.has(m):
			missing_steps.append(m)
	return {"timebase": base_unit, "cfg": cfg, "missing": missing_steps, "refs": refs}

## 字段 ID → 字段码。
static func _field_code_map(fields: Array) -> Dictionary:
	var out := {}
	for fd in fields:
		if fd is Dictionary and str((fd as Dictionary).get("id", "")) != "":
			out[str((fd as Dictionary).get("id", ""))] = str((fd as Dictionary).get("code", ""))
	return out

## 步骤 ID → 步骤码（声明态 id 转执行码）。
static func _step_code_of(manifest: Dictionary, step_id: String) -> String:
	var StepDecls := preload("res://src/content/step_decl.gd")
	var d: Dictionary = StepDecls.step_decl(manifest, step_id)
	if not d.is_empty():
		return str(d.get("code", ""))
	# 声明里查不到 id 时，容忍内容里直接写了码
	return step_id

## 从内容 steps 里抽变速段：该步骤的 BPM 字段值 + 该步的生效起点（拍）。
## 起点取内容步骤自身（第 0 步 at 缺省 = 0），按出现顺序；值不是有限正数的步骤忽略。
static func _tempo_segments(steps, step_code: String, bpm_code: String) -> Array:
	var StepTimeline := preload("res://src/content/step_timeline.gd")
	if not (steps is Array) or step_code == "" or bpm_code == "":
		return []
	var tl: Array = StepTimeline.to_timeline(steps)
	var out: Array = []
	for i in (steps as Array).size():
		var st = (steps as Array)[i]
		if not (st is Dictionary) or str((st as Dictionary).get("step", "")) != step_code:
			continue
		var sfd = (st as Dictionary).get("fields", null)
		if not (sfd is Dictionary):
			continue
		var v = (sfd as Dictionary).get(bpm_code, null)
		if not (v is int or v is float):
			continue
		var bpm := float(v)
		if not (is_finite(bpm) and bpm > 0.0):
			continue
		var beat := float((tl[i] as Dictionary).get("at", 0.0)) if i < tl.size() else 0.0
		out.append({"beat": beat, "bpm": bpm})
	return out
