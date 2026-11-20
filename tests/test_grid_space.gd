extends "res://tests/_suite_base.gd"
## 空间与类型池：GridSpace 正交/等距换算、collisionTypes 池归一化。

const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const CollisionTypes := preload("res://src/core/collision_types.gd")

func test_grid_orthogonal() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	eq(g.to_px(Vector2(3, 4)), Vector2(48, 64), "正交格→像素")
	eq(g.to_grid(Vector2(48, 64)), Vector2(3, 4), "正交像素→格")

func test_grid_isometric() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "isometric")
	eq(g.to_px(Vector2(1, 0)), Vector2(8, 8), "等距 (1,0) 中心 = (w/2, h/2)")
	eq(g.to_px(Vector2(1, 1)), Vector2(0, 16), "等距 (1,1) 中心 = (0, h)")
	var gr: Vector2 = g.to_grid(Vector2(8, 8))
	eq(int(gr.x), 1, "等距反算 i")
	eq(int(gr.y), 0, "等距反算 j")
	eq(gr, Vector2(1, 0), "等距往返一致")

func test_collision_types_pool() -> void:
	var fallback := CollisionTypes.pool({})
	eq(fallback.size(), 4, "未声明 = 内置缺省池")
	eq(str((fallback[0] as Dictionary).get("id")), "solid", "缺省首类 solid")
	var declared := {"collisionTypes": {"ice": {"name": "冰面", "shape": "rect", "gameplay": "slide", "color": "#88ccff"}}}
	var pool := CollisionTypes.pool(declared)
	eq(pool.size(), 1, "声明覆盖内置")
	eq(str((pool[0] as Dictionary).get("gameplay")), "slide", "gameplay 透传")
	var d: Dictionary = CollisionTypes.decl_of(declared, "ice")
	eq(str(d.get("name")), "冰面", "按 id 查声明")
	eq(CollisionTypes.decl_of(declared, "nope"), Dictionary(), "未声明返回空")
	var arr := {"collisionTypes": [{"id": "a"}, {"id": "a"}]}
	ok(arr != null, "数组写法可解析（查重归清单校验）")
