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
	# 每轨按起点排序后线性扫描：O(n log n)，大段演出拖动时每帧都要算
	var by_track := {}
	for i in tl.size():
		var e: Dictionary = tl[i]
		if float(e.get("duration", 0.0)) <= 0.0:
			continue
		var tr := int(e.get("track", 0))
		if not by_track.has(tr):
			by_track[tr] = []
		(by_track[tr] as Array).append(i)
	for tr2 in by_track:
		var idxs: Array = by_track[tr2]
		idxs.sort_custom(func(a, b):
			return float((tl[a] as Dictionary).get("at", 0.0)) < float((tl[b] as Dictionary).get("at", 0.0)))
		for k in range(0, idxs.size() - 1):
			var a: Dictionary = tl[idxs[k]]
			var s0 := float(a.get("at", 0.0))
			var e0 := s0 + float(a.get("duration", 0.0))
			for m in range(k + 1, idxs.size()):
				var b: Dictionary = tl[idxs[m]]
				var s1 := float(b.get("at", 0.0))
				if s1 >= e0:
					break   # 已按起点排序：后面的更靠右，不会与 a 重叠
				out.append({"a": idxs[k], "b": idxs[m]})
	return out

## 允许进补丁的时间键（D1）；fields/step 等身份键不在此列，永不经时间轴改写。
const PATCH_KEYS := ["at", "duration", "track", "blocking"]

## 补丁合并（D1）：把时间键补丁合并到 steps[index] 的工作副本上，
## 只净化**被编辑的键**（等于缺省就删键），其余未知键与未改条目原样保留。
## erase_keys 是独立命令（清 at = 恢复「随前序」），与补丁分开表达。
## 返回 {ok, steps, error}；steps 为新的深拷贝数组，原数组不动。
static func apply_patch(steps: Array, index: int, patch: Dictionary, erase_keys: Array = []) -> Dictionary:
	if index < 0 or index >= steps.size():
		return {"ok": false, "steps": steps, "error": "步骤下标越界"}
	if not (steps[index] is Dictionary):
		return {"ok": false, "steps": steps, "error": "该步骤不是对象"}
	for k in patch:
		if not PATCH_KEYS.has(str(k)):
			return {"ok": false, "steps": steps, "error": "不允许的时间键: %s" % str(k)}
	var next: Array = steps.duplicate(true)
	var step: Dictionary = next[index]
	step.merge(patch, true)
	# 只净化被编辑的键：from_timeline 对单步做缺省剥离，再按编辑集裁回
	var normalized: Dictionary = from_timeline([step])[0]
	for key in patch:
		if not normalized.has(key):
			step.erase(key)
	for key in erase_keys:
		if PATCH_KEYS.has(str(key)):
			step.erase(str(key))
	next[index] = step
	return {"ok": true, "steps": next, "error": ""}

## 某步的生效时间轴条目（含缺省展开）；越界返回 {}。
static func effective(steps: Array, index: int) -> Dictionary:
	var tl := to_timeline(steps)
	if index < 0 or index >= tl.size():
		return {}
	return tl[index]

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
