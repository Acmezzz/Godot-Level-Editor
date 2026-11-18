extends RefCounted
## 实体数值合并规则（实例 > 定义 > 清单默认）。资产面板实例分布与游戏运行时同一算法。
## 旧的四类资源模型（对话/事件/商店/定义校验）已随校验功能一起删除。

## 合并三层数值：实例 props.stats > 定义 stats > 清单 stats 默认值。
static func effective_stats(definition: Dictionary, manifest_def: Dictionary, instance_props: Dictionary) -> Dictionary:
	var out := {}
	for stat in manifest_def.get("stats", []):
		if not (stat is Dictionary):
			continue
		var sid := str((stat as Dictionary).get("id", ""))
		if sid != "":
			out[sid] = (stat as Dictionary).get("default", 0)
	var def_stats = definition.get("stats", {})
	if def_stats is Dictionary:
		for sid in (def_stats as Dictionary):
			out[str(sid)] = (def_stats as Dictionary)[sid]
	var inst_stats = instance_props.get("stats", {})
	if inst_stats is Dictionary:
		for sid in (inst_stats as Dictionary):
			out[str(sid)] = (inst_stats as Dictionary)[sid]
	return out
