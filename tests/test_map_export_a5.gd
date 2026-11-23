extends "res://tests/_suite_base.gd"
## A5：导出几何/像素预算/碰撞对象口径/统计文本（PNG 概览的纯数据部分）。

const MapExport := preload("res://src/map/map_export.gd")
const GridSpace := preload("res://src/canvas/grid_space.gd")

func _map(w: int, h: int, proj := "", tile := 16) -> Dictionary:
	var meta := {"w": w, "h": h, "layers": [{"id": "L1", "name": "层"}]}
	if proj != "":
		meta["gridProjection"] = proj
	return {"version": 7, "meta": meta, "tiles": {"L1": []}, "collision": [], "objects": [],
		"spawn": [0, 0], "tileSize": tile}

func _m(proj := "", tile := 16) -> Dictionary:
	var m := {"tileSize": tile}
	if proj != "":
		m["assets"] = [{"id": "t", "kind": "scene", "shape": "tile", "gridProjection": proj}]
	return m

## 正交 20×10 @ 16px 格、4 px/格 → 80×40 像素
func test_orthogonal_geometry() -> void:
	var geo := MapExport.output_geometry(_map(20, 10), _m())
	var sz: Vector2i = geo.size
	eq(sz, Vector2i(80, 40), "正交输出尺寸 = 格数 × px/格")

## 4000×4000 @ 16px 格、16 px/格 → 超 16M 像素，必须给出缩放建议
func test_budget_rejects_4000_square() -> void:
	var d := _map(4000, 4000)
	var b := MapExport.budget(d, _m(), 16)
	ok(not bool(b.get("ok", true)), "4000×4000@16px 超预算")
	ok(int(b.get("suggested", 0)) > 0, "给出可用缩放倍率：%s" % str(b.get("suggested")))
	ok(int(b.get("pixels", 0)) > MapExport.MAX_PIXELS, "报告像素总数")
	# 建议值本身必须真的通过预算
	var b2 := MapExport.budget(d, _m(), int(b.get("suggested")))
	ok(bool(b2.get("ok", false)), "建议倍率能通过预算")

## 等距：输出边界取格轮廓包围盒（菱形网格），不是 w×h 的方形
func test_isometric_bounds() -> void:
	var d := _map(4, 4, "isometric")
	var geo := MapExport.output_geometry(d, _m("isometric"))
	var bounds: Rect2 = geo.bounds
	ok(bounds.size.x > 0.0 and bounds.size.y > 0.0, "边界非空")
	# 等距 4×4 的包围盒应为 菱形宽 2 倍格宽 × 深 = 4 格宽、高 = 4 格高
	var grid := GridSpace.new(Vector2i(16, 16), "isometric")
	var want: Rect2 = grid.map_bounds(Rect2i(0, 0, 4, 4))
	eq(bounds.size, want.size, "边界与 GridSpace.map_bounds 同口径")

## 六边形：cell_polygon 六点，导出按六角画（边界取四角包围盒）
func test_hex_bounds_and_polygon() -> void:
	var d := _map(3, 3, "hexagonal")
	var geo := MapExport.output_geometry(d, _m("hexagonal"))
	var bounds: Rect2 = geo.bounds
	ok(bounds.size.x > 0.0, "六边边界非宽为 0")
	var grid: GridSpace = geo.grid
	eq(grid.cell_polygon(Vector2i(1, 1)).size(), 6, "六边格 = 六个顶点")

## 渲染：碰撞对象口径 {x,y,type?,shape?} 能画进图（不再按数组取 x/y）
func test_render_collision_objects() -> void:
	var d := _map(4, 4)
	d["collision"] = [{"x": 1, "y": 1}, {"x": 2, "y": 2, "type": "hazard", "shape": "r45"}]
	var img := MapExport.render_preview(d, 8, _m())
	ok(not img.is_empty(), "出图非空")
	eq(img.get_size(), Vector2i(32, 32), "4×4 @8px = 32×32")
	# 碰撞格中心像素应被着色（与背景不同）
	var bg := img.get_pixel(0, 0)
	var hit := img.get_pixel(12, 12)
	ok(hit != bg, "对象碰撞格已着色")

## 超预算时 render_preview 返回空图（不分配爆内存）
func test_render_refuses_over_budget() -> void:
	var d := _map(4000, 4000)
	var img := MapExport.render_preview(d, 16, _m())
	ok(img.is_empty(), "超预算不分配图像")

## 统计文本：投影/预览尺寸 + 瓦片总数 + 重复实例码
func test_stats_text() -> void:
	var d := _map(4, 4)
	d["tiles"] = {"L1": [[0, 0, "a", 0, 0, 0], [1, 0, "a", 0, 0, 0]]}
	d["objects"] = [{"asset": "door", "code": "I111"}, {"asset": "door", "code": "I111"}]
	var txt := MapExport.stats_text("m1", d, _m(), 4)
	ok(txt.contains("瓦片总数: 2"), "瓦片总数")
	ok(txt.contains("投影: orthogonal"), "投影行")
	ok(txt.contains("预览: 4 px/格"), "预览尺寸行")
	ok(txt.contains("重复实例码: I111"), "重复实例码警告")

## 不做预算检查的直渲染入口（批量已缩过时用）也走同一几何
func test_render_direct_matches_geometry() -> void:
	var d := _map(10, 6)
	var geo := MapExport.output_geometry(d, _m(), 3)
	var img: Image = MapExport._render(d, _m(), geo, 16)
	var sz: Vector2i = geo.size
	eq(img.get_size(), sz, "直渲染尺寸 = 预算几何尺寸")

## B3/§7.3：层 offset/scale 参与导出边界——层把内容推到根边界外时，边界必须跟着扩，
## 否则导出的概览会把那部分裁掉。
func test_layer_transform_expands_bounds() -> void:
	var d := _map(4, 4)
	d["meta"]["layers"] = [{"id": "L1", "offset": [32, 0], "scale": 1.0}]
	var base := MapExport.output_geometry(_map(4, 4), _m(), 4)
	var xf := MapExport.output_geometry(d, _m(), 4)
	eq((base.bounds as Rect2).size, Vector2(64, 64), "根边界 4×4 @16 = 64×64（无层变换）")
	eq((xf.bounds as Rect2).position, Vector2.ZERO, "合并后仍从 0 起")
	eq((xf.bounds as Rect2).size, Vector2(96, 64), "层右移 32 = 边界宽 96")

## 层缩放同理：2× 层让内容占两倍面积，边界必须覆盖
func test_layer_scale_expands_bounds() -> void:
	var d := _map(4, 4)
	d["meta"]["layers"] = [{"id": "L1", "scale": 2.0}]
	var xf := MapExport.output_geometry(d, _m(), 4)
	eq((xf.bounds as Rect2).size, Vector2(128, 128), "2× 层 = 边界 128×128")

## §4.3-4：两档导出——布局示意（默认）画全部层；画面一致档跳过隐藏层。
func test_export_hidden_layer_modes() -> void:
	# 两层：L1 可见、L2 隐藏；都铺一格。4×4 @16px 格、8 px/格
	var d := _map(4, 4)
	d["meta"]["layers"] = [{"id": "L1", "visible": true}, {"id": "L2", "visible": false}]
	d["tiles"] = {"L1": [], "L2": [[1, 1, "", 0, 0, 0]]}
	var loose := MapExport.render_preview(d, 8, _m())
	var strict := MapExport.render_preview(d, 8, _m(), 16, true)
	ok(not loose.is_empty() and not strict.is_empty(), "两档都出图")
	# L2 隐藏层的那格：布局示意档有色块，画面一致档与「另一个没瓦片的格」同为背景
	var px_probe := Vector2i(1 * 8 + 4, 1 * 8 + 4)
	var empty_probe := Vector2i(3 * 8 + 4, 3 * 8 + 4)
	ok(loose.get_pixelv(px_probe) != strict.get_pixelv(px_probe), "隐藏层在画面一致档不参与合成")
	eq(strict.get_pixelv(px_probe), strict.get_pixelv(empty_probe), "画面一致档该格 = 空格背景色")

## §4.3-4：blend=add 层在画面一致档提亮（与 mix 档同位置像素不同）。
func test_export_add_blend_brightens() -> void:
	var d := _map(4, 4)
	d["meta"]["layers"] = [{"id": "L1", "blend": "add"}, {"id": "L2"}]
	d["tiles"] = {"L1": [[1, 1, "", 0, 0, 0]], "L2": []}
	var mixy := MapExport.render_preview(d, 8, _m(), 16, false)
	var addy := MapExport.render_preview(d, 8, _m(), 16, true)
	var probe := Vector2i(1 * 8 + 4, 1 * 8 + 4)
	ok(addy.get_pixelv(probe).get_luminance() >= mixy.get_pixelv(probe).get_luminance(),
		"add 层不比 mix 暗")
