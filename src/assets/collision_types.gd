extends RefCounted
## 清单声明碰撞类型的颜色和游戏标签；绘制形状由各碰撞格的 shape 决定。
##
## 缺省或空池返回内置四类；非空声明整体替换。

## 内置缺省池（color 是编辑器呈现键，游戏侧不读）。
const FALLBACK := [
	{"id": "solid", "name": "实心", "shape": "rect", "gameplay": "block", "color": "#f0605c"},
	{"id": "one_way", "name": "单向", "shape": "rect", "gameplay": "one_way", "color": "#f2b822"},
	{"id": "ladder", "name": "攀爬", "shape": "rect", "gameplay": "area", "color": "#4c9aff"},
	{"id": "hazard", "name": "危险格", "shape": "rect", "gameplay": "area", "color": "#da66ff"},
]

## dict/array 两种写法统一成 [{id, body}]。
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
	var out: Array = []
	for pair in _decl_items(m.get("collisionTypes")):
		if pair.id != "":
			var row: Dictionary = pair.body.duplicate(true)
			row["id"] = pair.id
			out.append(row)
	return out if not out.is_empty() else FALLBACK

## 类型 id → 声明行（含缺省池）；未声明返回 {}。
static func decl_of(m: Dictionary, tid: String) -> Dictionary:
	for row in pool(m):
		if str(row.get("id", "")) == tid:
			return row
	return {}
