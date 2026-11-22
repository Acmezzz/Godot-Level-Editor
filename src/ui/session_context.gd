extends RefCounted
## E1：视图切换的上下文快照（纯逻辑）。采集与应用归各控制器，这里只做身份校验与边界收敛。
##
## 快照不存节点引用，只存可再校验的身份：地图码、实例码、功能执行码、内容 ID、步骤下标。
## 归来时目标已删除/绑定已换 → 调用方显示空态，绝不落到「第一个实例」上冒充恢复成功。

## 绑定数组里按功能执行码找下标；-1 = 没这条绑定。
static func fn_index_of(fns: Array, fn_code: String) -> int:
	if fn_code == "":
		return -1
	for i in fns.size():
		var f = fns[i]
		if f is Dictionary and str((f as Dictionary).get("fn", "")) == fn_code:
			return i
	return -1

## 步骤下标收敛到 [0, count-1]；-1（未选中）保持不变；空数组一律 -1。
static func step_index(sel: int, count: int) -> int:
	if count <= 0 or sel < 0:
		return -1
	return mini(sel, count - 1)

## 实例列表（[{code, ...}]）里是否有该码；空码不算命中。
static func has_code(ents: Array, code: String) -> bool:
	if code == "":
		return false
	for e in ents:
		if e is Dictionary and str((e as Dictionary).get("code", "")) == code:
			return true
	return false

## 地图身份是否仍一致（快照里的地图码 vs 当前图；空码 = 老图无码，按图名比）。
static func same_map(snap: Dictionary, map_code: String, map_name: String) -> bool:
	var want_code := str(snap.get("map_code", ""))
	var want_name := str(snap.get("map_name", ""))
	if want_code != "" or map_code != "":
		return want_code == map_code
	return want_name == map_name
