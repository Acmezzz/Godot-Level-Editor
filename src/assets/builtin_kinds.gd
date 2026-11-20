extends RefCounted
## 内置实体种类：不需要游戏工程清单声明，也不需要 prefab / 缩略图。
## 加载清单时自动并入 assets[]（标记 builtin=true），保存清单时再剥掉，
## 这样编辑器开箱可用，又不会污染游戏工程的 editor_manifest.json。
##
## 呈现由 `visual` 声明决定（mode/color/alpha），编辑器据此画占位，
## 不再靠"id == trigger_zone"这类硬编码分支。

## 内置种类定义（assets[] 条目同形）。
## fields 是引用型参数声明（复制/粘贴时重映射实例引用用，见 GAME_SIDE_STANDARD §2.4.2），
## 数值类参数不在这里——数值一律功能化（挂载），见 function_decl.gd。
## code = 分层身份码的实体段（内置种类固定码，merge 不覆盖游戏工程自己的声明）。
const KINDS := [
	{
		"id": "trigger_zone",
		"kind": "entity",
		"name": "事件区",
		"builtin": true,
		"role": "trigger",
		"code": "TZ99",
		# 旧数据的 x/y 是矩形左上格——用 top_left 锚点原样还原，不需要迁移
		"anchor": "top_left",
		"visual": {"mode": "rect", "color": "#4fc3f7", "alpha": 0.35},
		"fields": [],
	},
]

## 内置种类 id 列表
static func ids() -> Array:
	var out: Array = []
	for kind in KINDS:
		out.append(str((kind as Dictionary).get("id", "")))
	return out

## 内置种类声明；非内置返回空字典。
static func decl_of(id: String) -> Dictionary:
	for kind in KINDS:
		if str((kind as Dictionary).get("id", "")) == id:
			return (kind as Dictionary).duplicate(true)
	return {}

## 把缺失的内置种类补进清单 assets[]；已存在（游戏工程自己声明过）则不覆盖。
## 局部变量不能标 Array——清单里 assets 坏了（非 Array）时，类型化赋值会直接报错
## 中断清单加载，而这里本该走兜底（当空表重建）。
static func merge_into(manifest: Dictionary) -> void:
	var raw = manifest.get("assets", [])
	var assets: Array = raw if raw is Array else []
	if not (raw is Array):
		manifest["assets"] = assets
	var existing := {}
	for a in assets:
		if a is Dictionary:
			existing[str((a as Dictionary).get("id", ""))] = true
	for kind in KINDS:
		if existing.has(str((kind as Dictionary).get("id", ""))):
			continue
		assets.append((kind as Dictionary).duplicate(true))

## 写盘前剥掉内置种类：它们由编辑器提供，不需要落到游戏工程清单里。
static func strip_from(manifest: Dictionary) -> Dictionary:
	var out := manifest.duplicate(true)
	var kept: Array = []
	for a in out.get("assets", []):
		if a is Dictionary and bool((a as Dictionary).get("builtin", false)):
			continue
		kept.append(a)
	out["assets"] = kept
	return out

static func is_builtin(asset_id: String) -> bool:
	return ids().has(asset_id)
