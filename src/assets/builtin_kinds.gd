extends RefCounted
## 内置实体种类：不需要游戏工程清单声明，也不需要 prefab / 缩略图。
## 加载时补入缺失的种类，记录实际注入的 ID，避免清单保存时丢掉游戏自定义资产。
##
## 呈现由 `visual` 声明决定：`mode:"rect"` 让画布在无贴图时画半透明矩形，
## `type` 缺省 `rect`（几何种类与校验读它），color/alpha 定色；编辑器据此画占位，
## 不再靠"id == trigger_zone"这类硬编码分支。

## 内置种类定义（assets[] 条目同形）。
## fields 是引用型参数声明（复制/粘贴时重映射实例引用用，见 GAME_SIDE_STANDARD §2.4.2），
## 数值类参数不在这里——数值一律功能化（挂载），见 function_decl.gd。
## code = 分层身份码的实体段（内置种类固定码，merge 不覆盖游戏工程自己的声明）。
const TRIGGER_ID := "trigger_zone"
const TRIGGER_CODE := "TZ99"
const KINDS := [
	{
		"id": TRIGGER_ID,
		"kind": "entity",
		"name": "事件",
		"role": "trigger",
		"code": TRIGGER_CODE,
		# 旧数据的 x/y 是矩形左上格——用 top_left 锚点原样还原，不需要迁移
		"anchor": "top_left",
		"visual": {"mode": "rect", "color": "#4fc3f7", "alpha": 0.35},
		"sizeFields": ["w", "h"],
		"fields": [],
	},
]

## 把缺失的内置种类补进清单 assets[]；已存在（游戏工程自己声明过）则不覆盖。
static func merge_into(manifest: Dictionary) -> void:
	var assets: Array = manifest.get_or_add("assets", [])
	var injected := {}
	for kind in KINDS:
		if assets.any(func(asset): return asset.id == kind.id):
			continue
		assets.append(kind.duplicate(true))
		injected[kind.id] = true
	manifest["_injected_asset_ids"] = injected

static func is_injected(manifest: Dictionary, id: String) -> bool:
	return manifest.get("_injected_asset_ids", {}).has(id)
