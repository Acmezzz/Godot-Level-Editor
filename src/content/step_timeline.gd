extends RefCounted
## 步骤时间轴：at/duration/track/blocking 的缺省计算、回写净化与冲突检测（纯数据工具）。
## 读写同一份内容 steps 数组，不新增文件、不引入新键之外的形状。
##
## 缺省语义（缺省省略）：
##   at       缺省 = 顺序累加：同轨游标从 0 起，blocking 步骤推游标到 at+duration
##   duration 缺省 0 = 瞬发
##   track    缺省 0
##   blocking 缺省 true —— 非阻塞 = 本步放完不等待，下一步同刻开始
##
## to_timeline(steps)：给每步算出生效的 {at, duration, track, blocking}（视图/校验口径）。
## from_timeline(steps)：回写净化——剥掉等于缺省的键，数组保持可读；只删键不动 fields。

## 缺省轨道号 / 缺省阻塞位（from_timeline 按这两个值剥键）。
const DEFAULT_TRACK := 0
const DEFAULT_BLOCKING := true

## 顺序累加口径：每轨一个游标；显式 at 只推游标不缩游标。
static func to_timeline(steps: Array) -> Array:
	var out: Array = []
	var cursors := {}   # track -> 游标（秒）
	for st in steps:
		if not (st is Dictionary):
			out.append({})
			continue
		var track := int(st.get("track", DEFAULT_TRACK))
		var dur := maxf(0.0, float(st.get("duration", 0.0)))
		var blocking := bool(st.get("blocking", DEFAULT_BLOCKING))
		var at := 0.0
		if st.has("at"):
			at = maxf(float(st.get("at", 0.0)), 0.0)
		else:
			at = float(cursors.get(track, 0.0))
		# 显式 at 只推游标不缩游标：先排远的步骤不会把后面缺省步骤拉回来
		if blocking:
			cursors[track] = maxf(cursors.get(track, 0.0), at + dur)
		out.append({
			"at": at,
			"duration": dur,
			"track": track,
			"blocking": blocking,
		})
	return out

## 回写净化：删掉等于缺省的 duration/track/blocking 键；at 一旦显式就保留
## （时间轴语义里"排在几秒"本身就是信息）。返回净化副本，原数组不动。
static func from_timeline(steps: Array) -> Array:
	var out: Array = []
	for st in steps:
		if not (st is Dictionary):
			out.append(st)
			continue
		var d: Dictionary = st.duplicate(true)
		if float(d.get("duration", 0.0)) == 0.0:
			d.erase("duration")
		if int(d.get("track", DEFAULT_TRACK)) == DEFAULT_TRACK:
			d.erase("track")
		if bool(d.get("blocking", DEFAULT_BLOCKING)) == DEFAULT_BLOCKING:
			d.erase("blocking")
		out.append(d)
	return out

## 同轨时间区间重叠的步骤对（只警告，不阻断）。返回 [{a, b}]（下标对）。
## 口径与 to_timeline 一致：at 缺省顺序累加，duration 0 不算重叠（瞬发不占时）。
static func conflicts(steps: Array) -> Array:
	var tl := to_timeline(steps)
	var out: Array = []
	for i in tl.size():
		var a: Dictionary = tl[i]
		var dur_a := float(a.get("duration", 0.0))
		if dur_a <= 0.0 or not (steps[i] is Dictionary):
			continue
		for j in range(i + 1, tl.size()):
			var b: Dictionary = tl[j]
			if not (steps[j] is Dictionary):
				continue
			var dur_b := float(b.get("duration", 0.0))
			if dur_b <= 0.0:
				continue
			if int(a.get("track", 0)) != int(b.get("track", 0)):
				continue
			var s0 := float(a.get("at", 0.0))
			var e0 := s0 + dur_a
			var s1 := float(b.get("at", 0.0))
			var e1 := s1 + dur_b
			if s0 < e1 and s1 < e0:
				out.append({"a": i, "b": j})
	return out

## 汇总警告（只警告不阻断）：负 at/duration（手改 JSON 才会出现）+ 同轨重叠。
static func warnings(steps: Array) -> Array:
	var out: Array = []
	var tl := to_timeline(steps)
	for i in tl.size():
		if not (steps[i] is Dictionary):
			continue
		var st: Dictionary = steps[i]
		if st.has("at") and float(st.get("at", 0.0)) < 0.0:
			out.append("第 %d 步 at 为负（时间轴里拖回 0 起）" % (i + 1))
		if st.has("duration") and float(st.get("duration", 0.0)) < 0.0:
			out.append("第 %d 步 duration 为负（拖右缘改回非负）" % (i + 1))
	for pair in conflicts(steps):
		out.append("第 %d / %d 步同轨重叠（改 at 或换轨）" % [
			int((pair as Dictionary).get("a", 0)) + 1,
			int((pair as Dictionary).get("b", 0)) + 1,
		])
	return out
