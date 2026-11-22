extends RefCounted
## E3：地图菜单的身份解析（纯逻辑，无 UI）。
## 菜单项在弹出时绑定 {name, code}；点击时按绑定身份解析，绝不按下标去读一份新的 list_maps——
## 外部增删文件会让排序下标指向另一张图（旧实现就是这样静默切错图的）。

const OK := "ok"            # 绑定有效：可以切
const STALE := "stale"      # 下标越界/无绑定：菜单条目已错位
const MISSING := "missing"  # 绑定的文件已不存在
const RECODE := "recode"    # 文件还在但地图码变了：同名现在指着另一张图
const SAME := "same"        # 就是当前图

## binds: 弹出时的绑定数组，元素 {name, code, path}
## exists: 绑定图名的文件此刻是否存在
## current_code: 该文件此刻 meta.code（读不出给空串 = 不做码校验）
## cur_name: 当前已载入的图名（同名 = 无需切换）
static func resolve(binds: Array, id: int, exists: bool, current_code: String,
		cur_name: String) -> Dictionary:
	var out := {"status": STALE, "name": "", "code": ""}
	if id < 0 or id >= binds.size() or not (binds[id] is Dictionary):
		return out
	var b: Dictionary = binds[id]
	var nm := str(b.get("name", ""))
	if nm == "":
		return out
	var bound_code := str(b.get("code", ""))
	out["name"] = nm
	out["code"] = bound_code
	if not exists:
		out["status"] = MISSING
		return out
	if bound_code != "" and current_code != "" and current_code != bound_code:
		out["status"] = RECODE
		return out
	out["status"] = SAME if nm == cur_name else OK
	return out
