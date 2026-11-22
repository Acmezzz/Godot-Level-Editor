extends RefCounted
## TileReplace：按选区 + 源资产/图集格批量替换瓦片（E2）。纯数据：只算计划，不改画布。
##
## 计划 = {cells: [{c: Vector2i, src_layer: int, src: int, atlas: Vector2i, alt: int}],
##         conflicts: [{c, why}], total: n}
## 冲突判据（「目标图集不能表示原变换时先列冲突」）：
##   ① 目标资产在清单里不存在 / 不是瓦片；
##   ② 源切片坐标超出目标图集边界（目标图集比源小）；
##   ③ 原格子带变换 alt，但目标切片没有对应 alternative（Godot 需显式建 alternative；
##      TilesetCache.set_cell_alt 会自动补建，所以这里只在「目标图集没有该切片」时判冲突）。
## 通过后由调用方一次撤销 + 逐格写（写盘走既有 extract/撤销栈）。

## 扫描选区：只收匹配 src_asset（且给定 src_cell 时匹配该切片）的瓦片格。
## 返回 [{c, layer: 层id, src: TileSet source_id, atlas, alt}]——供计划与预览共用。
static func collect(cvs, sel: Rect2i, src_asset: String, src_cell := Vector2i(-1, -1)) -> Array:
	var out: Array = []
	if src_asset == "" or sel.size.x <= 0 or sel.size.y <= 0:
		return out
	for li in cvs.layer_tiles.size():
		var lid: String = cvs.layer_id(li)
		if lid == "":
			continue
		var layer: TileMapLayer = cvs.layer_tiles[li]
		for y in range(sel.position.y, sel.end.y):
			for x in range(sel.position.x, sel.end.x):
				var c := Vector2i(x, y)
				var sid := layer.get_cell_source_id(c)
				if sid < 0:
					continue
				if str(cvs.asset_of_source(sid)) != src_asset:
					continue
				var ac := layer.get_cell_atlas_coords(c)
				if src_cell.x >= 0 and ac != src_cell:
					continue
				out.append({"c": c, "layer": lid, "src": sid, "atlas": ac,
					"alt": MapFormat.alt_of_godot(layer.get_cell_alternative_tile(c))})
	return out

## 计划：把 cells 换成 dst_asset 的 dst_cell（同一格位，保留 alt）。
## dst_asset 的图集尺寸取自清单声明（palette 切片或整图平铺的 cols/rows）。
static func plan(manifest: Dictionary, cells: Array, dst_asset: String,
		dst_cell := Vector2i(-1, -1)) -> Dictionary:
	var out := {"cells": [], "conflicts": [], "total": cells.size()}
	if cells.is_empty():
		return out
	var ad: Dictionary = AssetDecl.by_id(manifest, dst_asset)
	if ad.is_empty():
		out.conflicts.append({"c": Vector2i.ZERO, "why": "目标资产 %s 不在清单里" % dst_asset})
		return out
	if str(ad.get("kind", "")) != "tile" and str(ad.get("kind", "")) != "scene":
		out.conflicts.append({"c": Vector2i.ZERO, "why": "资产 %s 不是瓦片类" % dst_asset})
		return out
	if str(ad.get("shape", "")) != "tile":
		out.conflicts.append({"c": Vector2i.ZERO, "why": "资产 %s 不是图集瓦片（shape=%s）" % [dst_asset, str(ad.get("shape", ""))]})
		return out
	var bounds := atlas_bounds(manifest, dst_asset)
	for it in cells:
		var e: Dictionary = it
		var c: Vector2i = e.get("c", Vector2i.ZERO)
		var ac: Vector2i = dst_cell if dst_cell.x >= 0 else (e.get("atlas", Vector2i.ZERO) as Vector2i)
		if bounds.x > 0 and bounds.y > 0 and not Rect2i(Vector2i.ZERO, bounds).has_point(ac):
			out.conflicts.append({"c": c, "why": "切片 %s 超出目标图集 %dx%d" % [
				str(ac), bounds.x, bounds.y]})
			continue
		out.cells.append({"c": c, "layer": str(e.get("layer", "")), "atlas": ac,
			"alt": int(e.get("alt", 0))})
	return out

## 目标资产的图集切片边界（列 x 行）。palette 非空按切片声明；否则按整图 / cell 尺寸算。
## 读不到图集尺寸时返回 ZERO（调用方跳过边界检查——不拿未知尺寸去否掉用户操作）。
static func atlas_bounds(manifest: Dictionary, aid: String) -> Vector2i:
	var ad: Dictionary = AssetDecl.by_id(manifest, aid)
	if ad.is_empty():
		return Vector2i.ZERO
	var pal: Array = ad.get("palette", []) if ad.get("palette", []) is Array else []
	var mx := -1
	var my := -1
	for p in pal:
		if p is Dictionary:
			var c = (p as Dictionary).get("cell", [])
			if not (c is Array) or (c as Array).size() < 2:
				continue
			mx = maxi(mx, int((c as Array)[0]))
			my = maxi(my, int((c as Array)[1]))
	if mx >= 0:
		return Vector2i(mx + 1, my + 1)
	var cell: Vector2i = AssetDecl.cell_size(manifest, aid)
	var img := atlas_image_size(manifest, aid)
	if cell.x > 0 and cell.y > 0 and img.x > 0 and img.y > 0:
		return Vector2i(int(img.x / float(cell.x)), int(img.y / float(cell.y)))
	return Vector2i.ZERO

## 图集像素尺寸：读不到返回 ZERO（文件缺失/损坏时不做边界判定）。
static func atlas_image_size(manifest: Dictionary, aid: String) -> Vector2i:
	var ad: Dictionary = AssetDecl.by_id(manifest, aid)
	var abs_path := str(ad.get("atlas_abs", ""))
	if abs_path == "" or not FileAccess.file_exists(abs_path):
		return Vector2i.ZERO
	var img := Image.new()
	if img.load(abs_path) != OK:
		return Vector2i.ZERO
	return img.get_size()

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const MapFormat := preload("res://src/map/map_format.gd")
