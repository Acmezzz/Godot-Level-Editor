extends RefCounted
## 碰撞类型池（REFACTOR_PLAN 3.6）：清单顶层 `collisionTypes` 声明画布画什么形状/颜色，
## `gameplay` 是游戏侧自己的解释标签（编辑器只存取不解释）。
##
## 缺省池：清单没声明时用内置四类（solid/one_way/ladder/hazard），行为与旧版一致；
## 声明即整体覆盖——不支持「声明一个、保留其余内置」的混搭（口径保持单一）。

## 内置缺省池（color 是编辑器呈现键，游戏侧不读）。
const FALLBACK := [
	{"id": "solid", "name": "实心", "shape": "rect", "gameplay": "block", "color": "#f0605c"},
	{"id": "one_way", "name": "单向", "shape": "rect", "gameplay": "one_way", "color": "#f2b822"},
	{"id": "ladder", "name": "攀爬", "shape": "rect", "gameplay": "area", "color": "#4c9aff"},
	{"id": "hazard", "name": "危险格", "shape": "rect", "gameplay": "area", "color": "#da66ff"},
]

## dict/array 两种写法统一成 [{id, body}]（校验用）。
static func _decl_items(decl) -> Array:
	var out: Array = []
	if decl is Dictionary:
		for k in (decl as Dictionary):
			var b = (decl as Dictionary)[k]
			if b is Dictionary:
				out.append({"id": str(k), "body": b})
	elif decl is Array:
		for item in (decl as Array):
			if item is Dictionary:
				out.append({"id": str((item as Dictionary).get("id", "")), "body": item})
	return out

## 声明的类型池（清单没声明 = 内置缺省池）。统一成 [{id, name, shape, gameplay, color}]。
## 支持 dict（{类型id: {name, shape, gameplay, color}}）与数组（[{id, ...}]）两种写法。
static func pool(m: Dictionary) -> Array:
	var decl = m.get("collisionTypes", null)
	if not (decl is Dictionary or decl is Array):
		return FALLBACK
	var out: Array = []
	if decl is Dictionary:
		for k in (decl as Dictionary):
			var b = (decl as Dictionary)[k]
			if not (b is Dictionary):
				continue
			var row: Dictionary = b.duplicate(true)
			row["id"] = str(k)
			out.append(row)
	else:
		for item in (decl as Array):
			if item is Dictionary and str(item.get("id", "")) != "":
				out.append((item as Dictionary).duplicate(true))
	return out if not out.is_empty() else FALLBACK

## 类型 id → 声明行（含缺省池）；未声明返回 {}。
static func decl_of(m: Dictionary, tid: String) -> Dictionary:
	for row in pool(m):
		if str(row.get("id", "")) == tid:
			return row
	return {}
