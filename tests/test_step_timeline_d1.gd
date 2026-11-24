extends "res://tests/_suite_base.gd"
## D1：步骤时间轴的单一数据源——补丁合并、净化、生效区间、结构版本与警告。

const StepTimeline := preload("res://src/content/step_timeline.gd")

func test_copy_range_keeps_inherited_and_parallel_timing() -> void:
	var steps := [
		{"step": "A", "duration": 7},
		{"step": "B", "duration": 3, "fields": {"routes": [{"to": "exit"}]}},
		{"step": "C", "track": 1, "at": 5, "duration": 8, "blocking": false, "custom": "keep"},
		{"step": "D"},
	]
	var segment := StepTimeline.copy_range(steps, 1, 3)
	var placed := StepTimeline.offset_segment(segment, StepTimeline.end_time(steps))
	eq(placed.map(func(step): return step.at), [15.0, 13.0, 18.0],
		"最早生效步骤落在全轨结束处，继承起点仍保留相对时间")
	eq(placed[1], {"step": "C", "track": 1, "at": 13.0, "duration": 8,
		"blocking": false, "custom": "keep"}, "仅改起点")
	placed[0].fields.routes[0].to = "other"
	eq(segment[0].fields.routes[0].to, "exit", "再次粘贴使用原段落数据")
	eq(steps[1].fields.routes[0].to, "exit", "原步骤字段独立")
	ok(not steps[1].has("at"), "原步骤仍随前序")

## 计划验收数据：[{duration:2},{duration:1}] → 第二步生效起点 2；
## 右边拖到 4 只改时长（变 2），再归零并换新轨。
func test_acceptance_two_steps_second_effective_at() -> void:
	var steps := [{"step": "A", "duration": 2}, {"step": "B", "duration": 1}]
	var tl := StepTimeline.to_timeline(steps)
	eq(float((tl[1] as Dictionary).get("at", -1.0)), 2.0, "第二步生效起点 = 2（顺序累加）")
	# 右缘拖到 4：起手 at=2，终点 4 → 时长 2
	var r := StepTimeline.apply_patch(steps, 1, {"duration": 2.0})
	ok(bool(r.get("ok")), "补丁合并成功")
	var next: Array = r.get("steps", [])
	eq(float((next[1] as Dictionary).get("duration", 0.0)), 2.0, "只改时长")
	ok(not (next[1] as Dictionary).has("at"), "未编辑 at 不被写入（仍随前序）")
	# 时长归零：等于缺省 → 键被剥掉
	var r0 := StepTimeline.apply_patch(next, 1, {"duration": 0.0})
	var n0: Array = r0.get("steps", [])
	ok(not (n0[1] as Dictionary).has("duration"), "duration=0 剥键（缺省省略）")
	# 换新轨
	var r2 := StepTimeline.apply_patch(n0, 1, {"track": 1})
	var n2: Array = r2.get("steps", [])
	eq(int((n2[1] as Dictionary).get("track", 0)), 1, "换轨写入")
	ok(not (n0[0] as Dictionary).has("track"), "未编辑的相邻步骤不受影响")

## 只净化被编辑的键：duration 显式为 0 且没被编辑时保持原样（不做全量重写）
func test_patch_only_normalizes_edited_keys() -> void:
	var steps := [{"step": "A", "duration": 0, "customKey": "keep"}, {"step": "B"}]
	var r := StepTimeline.apply_patch(steps, 1, {"at": 3.0})
	var next: Array = r.get("steps", [])
	ok((next[0] as Dictionary).has("duration"), "未编辑步骤的显式 0 不被净化")
	eq(str((next[0] as Dictionary).get("customKey", "")), "keep", "未知键原样保留")
	eq(float((next[1] as Dictionary).get("at", 0.0)), 3.0, "编辑键写入")
	eq((steps[1] as Dictionary).size(), 1, "原数组不被就地修改")

## 清 at = 独立命令（erase_keys），恢复「随前序」
func test_erase_at_restores_sequential() -> void:
	var steps := [{"step": "A", "duration": 1}, {"step": "B", "at": 9.0}]
	var r := StepTimeline.apply_patch(steps, 1, {}, ["at"])
	var next: Array = r.get("steps", [])
	ok(not (next[1] as Dictionary).has("at"), "at 被擦除")
	var tl := StepTimeline.to_timeline(next)
	eq(float((tl[1] as Dictionary).get("at", -1.0)), 1.0, "生效起点回到顺序累加值")

## 补丁键白名单：身份键（step/fields）不能被时间轴补丁改写
func test_patch_rejects_non_time_keys() -> void:
	var steps := [{"step": "A", "fields": {"X": 1}}]
	var r := StepTimeline.apply_patch(steps, 0, {"step": "B"})
	ok(not bool(r.get("ok")), "step 不是时间键 → 拒绝")
	ok(bool(str(r.get("error", "")).length() > 0), "给出错误原因")
	var r2 := StepTimeline.apply_patch(steps, 5, {"at": 1.0})
	ok(not bool(r2.get("ok")), "越界下标 → 拒绝")
	eq(str(((r2.get("steps", []) as Array)[0] as Dictionary).get("step", "")), "A", "拒绝时数据不变")

## 换序后送达的旧回调：下标语义已变，版本校验必须能识别（纯数据侧的证据）
func test_stale_index_after_reorder_is_detectable() -> void:
	var steps := [{"step": "A", "fields": {"T": "a"}}, {"step": "B", "fields": {"T": "b"}}]
	# 换序
	var swapped := [steps[1], steps[0]]
	# 旧回调带下标 1（原本是 B），换序后下标 1 = A，文本 "b" 不能落到 A 上
	eq(str((swapped[1] as Dictionary).get("step", "")), "A", "换序后下标 1 已指向 A")
	eq(str(((swapped[1] as Dictionary).get("fields", {}) as Dictionary).get("T", "")), "a",
		"按版本丢弃旧回调的必要性：直接按下标写会污染 A")

## 显式 0 与随前序：to_timeline 两者都可区分
func test_explicit_zero_vs_sequential() -> void:
	var steps := [{"step": "A", "duration": 5}, {"step": "B", "at": 0.0}, {"step": "C"}]
	var tl := StepTimeline.to_timeline(steps)
	eq(float((tl[1] as Dictionary).get("at", -1.0)), 0.0, "显式 0 = 从零开始")
	eq(float((tl[2] as Dictionary).get("at", -1.0)), 5.0, "C 仍随前序（A 的结束）")

## 每轨独立游标 + 非阻塞步骤不推游标
func test_track_cursors_and_blocking() -> void:
	var steps := [
		{"step": "A", "duration": 2},
		{"step": "B", "duration": 1, "track": 1},
		{"step": "C", "duration": 3, "blocking": false},
		{"step": "D", "track": 1},
	]
	var tl := StepTimeline.to_timeline(steps)
	eq(float((tl[0] as Dictionary).get("at", -1.0)), 0.0, "A 在 0")
	eq(float((tl[1] as Dictionary).get("at", -1.0)), 0.0, "B 在另一轨，也从 0")
	eq(float((tl[2] as Dictionary).get("at", -1.0)), 2.0, "C 接 A 结束")
	eq(float((tl[3] as Dictionary).get("at", -1.0)), 1.0, "D 接 B 结束（轨 1 游标独立）")

## 重叠检测：每轨按起点排序；瞬发（duration 0）不算重叠
func test_conflicts_sorted_per_track() -> void:
	var steps := [
		{"step": "A", "duration": 2},          # 0..2
		{"step": "B", "duration": 2, "at": 1},  # 1..3 与 A 重叠
		{"step": "C", "duration": 0, "at": 0},  # 瞬发不占时
	]
	var cf := StepTimeline.conflicts(steps)
	eq(cf.size(), 1, "仅 A/B 一条重叠：%s" % str(cf))
	ok(str(cf).contains("0") and str(cf).contains("1"), "重叠对是 0/1")
	# 起点相同但不同轨 = 不重叠
	var ok2 := [{"step": "A", "duration": 2}, {"step": "B", "duration": 2, "track": 1}]
	eq(StepTimeline.conflicts(ok2).size(), 0, "不同轨同区间不算冲突")

## P02：全重叠是平方级警告——面板只收前 N 条 + 一行「另有 M 条」，不刷爆列表。
func test_warnings_cap_quadratic_overlap() -> void:
	var steps := []
	for i in 40:
		steps.append({"step": "A", "duration": 5, "at": 0, "track": 0})
	var w := StepTimeline.warnings(steps)
	eq(w.size(), StepTimeline.MAX_WARNINGS + 1, "截断到上限 + 1 条汇总行")
	ok(str(w[w.size() - 1]).contains("另有"), "末行说明剩余数量：%s" % str(w[w.size() - 1]))
	var all := StepTimeline.warnings(steps, 0)
	eq(all.size(), 40 * 39 / 2, "limit=0 时不截断（40 步全重叠 = 780 对）")
	eq(StepTimeline.warnings([{"step": "A", "duration": 1}]).size(), 0, "单步无警告")

## 净化：from_timeline 剥缺省键，未知键与 fields 不动
func test_from_timeline_strips_defaults() -> void:
	var steps := [{"step": "A", "duration": 0.0, "track": 0, "blocking": true,
		"fields": {"K": "v"}, "unknown": [1, 2]}]
	var out: Array = StepTimeline.from_timeline(steps)
	var d: Dictionary = out[0]
	ok(not d.has("duration") and not d.has("track") and not d.has("blocking"), "缺省键剥掉")
	eq(str((d.get("fields", {}) as Dictionary).get("K", "")), "v", "fields 保留")
	ok(d.has("unknown"), "未知键保留")

## 生效条目查询（拖拽起手快照口径）
func test_effective_snapshot() -> void:
	var steps := [{"step": "A", "duration": 2}, {"step": "B", "duration": 1}]
	var e0: Dictionary = StepTimeline.effective(steps, 0)
	eq(float(e0.get("at", -1.0)), 0.0, "第 0 步生效起点")
	var e1: Dictionary = StepTimeline.effective(steps, 1)
	eq(float(e1.get("at", -1.0)), 2.0, "第 1 步生效起点")
	eq(StepTimeline.effective(steps, 9).size(), 0, "越界返回空")
