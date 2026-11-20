extends "res://tests/_suite_base.gd"
## EntityNode：锚点 ↔ 格坐标换算、显示尺寸、transform 缺省判定。
## 这些是 objects[] 落盘口径的核心——x/y 存的是「锚点相对格」的浮点坐标，
## 换算错了表现为「加载后整体偏移半格」，很难从 JSON 里看出来。

const TILE := 16

func _mk(decl: Dictionary, size := Vector2(16, 16)) -> EntityNode:
	var n := EntityNode.new()
	n.decl = decl
	n.tile_px = TILE
	n.base_size = size
	return n

func test_anchor_center() -> void:
	var n := _mk({})
	eq(n.anchor(), "center", "缺省锚点 center")
	eq(n.world_of_grid(1, 2), Vector2(24, 40), "格中心 = (x+0.5, y+0.5)*tile")
	eq(n.grid_of_world(Vector2(24, 40)), Vector2(1, 2), "反算回原值")
	n.free()

func test_anchor_top_left() -> void:
	var n := _mk({"anchor": "top_left"}, Vector2(32, 48))
	eq(n.world_of_grid(3, 4), Vector2(48, 64), "左上角 = (x, y)*tile")
	eq(n.grid_of_world(Vector2(48, 64)), Vector2(3, 4), "反算回原值")
	n.apply_grid(3, 4)
	eq(n.rect(), Rect2(48, 64, 32, 48), "视觉矩形以左上角为原点")
	n.free()

func test_anchor_bottom_center() -> void:
	var n := _mk({"anchor": "bottom_center"}, Vector2(32, 48))
	eq(n.world_of_grid(3, 4), Vector2(56, 80), "底边中点 = (x+0.5, y+1)*tile")
	eq(n.grid_of_world(Vector2(56, 80)), Vector2(3, 4), "反算回原值")
	eq(n.anchor_off(), Vector2(16, 48), "视觉偏移 = 半个宽 + 整个高")
	n.free()

func test_float_coords_and_cell() -> void:
	var n := _mk({})
	n.apply_grid(2.5, 3.75)
	eq(n.position, Vector2(48, 68), "浮点格坐标直接换世界坐标（含锚点格内偏移）")
	eq(n.cell(), Vector2i(2, 3), "所在格 = 视觉矩形左上格")
	eq(n.grid_of_world(n.position), Vector2(2.5, 3.75), "往返保真")
	n.free()

func test_size_fields_override() -> void:
	var n := _mk({"sizeFields": ["w", "h"]}, Vector2(16, 16))
	n.props = {"w": 4, "h": 2}
	eq(n.display_size(), Vector2(64, 32), "事件区尺寸读 props（格 → 像素）")
	eq(n.anchor_off(), Vector2(32, 16), "锚点偏移跟着尺寸走")
	n.props = {"w": 0, "h": -5}
	eq(n.display_size(), Vector2(16, 16), "非法尺寸夹到 1 格")
	n.free()

func test_transform_default() -> void:
	var n := _mk({})
	ok(n.transform_is_default(), "空 transform = 缺省")
	n.data_transform = {"scale": [1, 1], "rotation": 0.0, "flip_h": false}
	ok(n.transform_is_default(), "显式写 1/0/false 仍算缺省（写盘会整键省略）")
	n.data_transform = {"scale": [2, 1]}
	ok(not n.transform_is_default(), "非 1 缩放不算缺省")
	n.data_transform = {"rotation": 0.5}
	ok(not n.transform_is_default(), "旋转不算缺省")
	n.data_transform = {}
	n.toggle_flip_h()
	ok(n.flipped_h(), "toggle 打开水平翻转")
	ok(not n.transform_is_default(), "翻转不算缺省")
	n.toggle_flip_h()
	ok(n.transform_is_default(), "toggle 回去 = 缺省（键被删掉，不留 false）")
	n.free()

func test_is_entity() -> void:
	var e := _mk({"kind": "entity"})
	ok(e.is_entity(), "kind=entity")
	e.free()
	var s := _mk({"kind": "scene", "shape": "image"})
	ok(not s.is_entity(), "场景实例不算实体")
	s.free()
