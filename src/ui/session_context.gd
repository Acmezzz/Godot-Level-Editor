extends RefCounted
## E1：视图切换的上下文快照（纯逻辑）。采集与应用归各控制器，这里只做身份校验与边界收敛。
##
## 快照不存节点引用，只存可再校验的身份：地图码、实例码、功能执行码、内容 ID、步骤下标。
## 归来时目标已删除/绑定已换 → 调用方显示空态，绝不落到「第一个实例」上冒充恢复成功。

## 用持久绑定 ID 定位。旧行按功能码与内容 ID 唯一匹配；歧义时保持未展开。
static func fn_index_of(fns: Array, fn_code: String, binding_id := "", content_id := "") -> int:
	if fn_code == "":
		return -1
	var found := -1
	for i in fns.size():
		var row = fns[i]
		if not row is Dictionary or str(row.get("fn", "")) != fn_code:
			continue
		if binding_id != "":
			if str(row.get("bindingId", "")) != binding_id:
				continue
		elif content_id != "" and str(row.get("content", "")) != content_id:
			continue
		if found >= 0:
			return -1
		found = i
	return found

## 步骤下标收敛到 [0, count-1]；-1（未选中）保持不变；空数组一律 -1。
static func step_index(sel: int, count: int) -> int:
	if count <= 0 or sel < 0:
		return -1
	return mini(sel, count - 1)
