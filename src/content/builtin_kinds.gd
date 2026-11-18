extends RefCounted
## 内置实体种类：不需要游戏工程清单声明，也不需要 prefab / 缩略图。
## 加载清单时自动并入 entities（标记 builtin=true），保存清单时再剥掉，
## 这样编辑器开箱可用，又不会污染游戏工程的 editor_manifest.json。

## 内置种类定义。fields 只声明编辑器要渲染的控件类型，游戏侧按自己的规则解释。
const KINDS := [
	{
		"id": "trigger_zone",
		"name": "触发区",
		"builtin": true,
		"role": "trigger",
		"fields": [],
	},
]

## 内置种类 id 列表
static func ids() -> Array:
	var out: Array = []
	for kind in KINDS:
		out.append(str((kind as Dictionary).get("id", "")))
	return out

## 把缺失的内置种类补进清单；已存在（游戏工程自己声明过）则不覆盖。
static func merge_into(manifest: Dictionary) -> void:
	var entities: Array = manifest.get("entities", [])
	if not (entities is Array):
		entities = []
		manifest["entities"] = entities
	var existing := {}
	for entity in entities:
		if entity is Dictionary:
			existing[str((entity as Dictionary).get("id", ""))] = true
	for kind in KINDS:
		if existing.has(str((kind as Dictionary).get("id", ""))):
			continue
		entities.append((kind as Dictionary).duplicate(true))

## 写盘前剥掉内置种类：它们由编辑器提供，不需要落到游戏工程清单里。
static func strip_from(manifest: Dictionary) -> Dictionary:
	var out := manifest.duplicate(true)
	var kept: Array = []
	for entity in out.get("entities", []):
		if entity is Dictionary and bool((entity as Dictionary).get("builtin", false)):
			continue
		kept.append(entity)
	out["entities"] = kept
	return out

static func is_builtin(scene_id: String) -> bool:
	return ids().has(scene_id)
