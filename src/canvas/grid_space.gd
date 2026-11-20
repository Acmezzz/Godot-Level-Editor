extends RefCounted
class_name GridSpace
## 格 ↔ 像素坐标转换层（第 5 批 5.1）：正交 / 等距（Godot 原生菱形）两套。
## 全部画布落点换算走这里；等距图要求全部瓦片资产同投影（混投影校验给警告）。
##
## 口径：正交 cell (i,j) 的左上角像素 = (i,j) * tile；等距 cell (i,j) 的**中心**像素 =
## ((i-j) * w/2, (i+j) * h/2)。to_grid 返回**浮点格坐标**（tile 在格内的分数位置），
## 取整（floori）才得到格号。六边形不做（能力天花板）。

var tile: Vector2i = Vector2i(16, 16)
var projection := "orthogonal"   # "orthogonal" / "isometric"

func _init(t: Vector2i = Vector2i(16, 16), proj: String = "orthogonal") -> void:
	tile = t
	projection = "isometric" if proj == "isometric" else "orthogonal"

func is_iso() -> bool:
	return projection == "isometric"

## 格坐标（浮点，含格内分数）→ 像素。等距返回的是格中心。
func to_px(g: Vector2) -> Vector2:
	if is_iso():
		var hw := float(tile.x) * 0.5
		var hh := float(tile.y) * 0.5
		return Vector2((g.x - g.y) * hw, (g.x + g.y) * hh)
	return g * Vector2(tile)

## 像素 → 浮点格坐标；格号 = floori(to_grid(p).x/.y)（仅正交语义）。
func to_grid(p: Vector2) -> Vector2:
	if is_iso():
		var hw := float(tile.x) * 0.5
		var hh := float(tile.y) * 0.5
		if hw == 0.0 or hh == 0.0:
			return Vector2.ZERO
		return Vector2(
			(p.x / hw + p.y / hh) * 0.5,
			(p.y / hh - p.x / hw) * 0.5)
	if tile.x <= 0 or tile.y <= 0:
		return Vector2.ZERO
	return p / Vector2(tile)
