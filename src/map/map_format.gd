extends RefCounted
## 地图数据格式版本常量。单独成文件是为了让「读写的 map_store」与「校验的 map_data_validation」
## 都能引用它而不互相 preload（两者本来就有依赖方向，再反向引用就成环）。

## 当前地图数据格式版本。老图（无 version 键）视为 1。
## v4：用户层栈 meta.layers=[{id,name,visible}]（栈序底→顶，id=4 位层码）；瓦片改
## tiles={层id:[[x,y,atlas,ax,ay]...]}；实体 entities[] 加 layer=层码；collision 不变；
## terrain/decor 顶层键删除——零兼容，旧图不迁移，由校验拒绝。
## v5：瓦片条目第 3 位由「清单 tiles[] 数组序」改为**资产 id 字符串**
## （tiles={层id:[[x,y,<资产id>,ax,ay]...]}）；清单侧 tiles[]/entities[] 合并为
## assets[]（kind=scene/entity）；地图侧 entities[] 并入 objects[]（场景图片与实体实例
## 同形，`asset` 指资产、`code` 只属于实体、x/y 为浮点格坐标、transform 缺省省略）。
## v6：collision[] 条目由定长数组 [x,y,(type,(shape))] 改为**对象** {x, y, type?, shape?}
## （缺省省略：type 缺省 solid、shape 缺省矩形）；清单顶层新增 collisionTypes 声明池、
## meta.layers 层参数（parallax/ySort/offset/scale）、瓦片 palette 条目 ySortOrigin。
## v7：瓦片条目 5 元 → 6 元 [x,y,资产id,ax,ay,alt]（第 6 位 = 变换位 0-7：bit0 水平翻转、
## bit1 垂直翻转、bit2 转置(90°)，0 缺省不可省）；meta.layers[] 增可选 blend（mix 省略/add/mul）。
const VERSION := 7

## —— 瓦片变换位（编辑器口径 0-7） ——
## Godot 的 alternative_tile 把变换编在第 12/13/14 位（FLIP_H=4096 / FLIP_V=8192 / TRANSPOSE=16384）；
## 磁盘数据收敛到 0-7，读写时经这两个函数与 Godot 位互转。
const TILE_FLIP_H := 1
const TILE_FLIP_V := 2
const TILE_ROT90 := 4

## —— 八种 alt 作为 D4 组合表（E08）——
## 旧实现把「旋转档位位集」与水平翻转直接 OR——rot90(T|H) 加翻转又变回 T，
## 部分档位翻转无效。改为群作用表：旋转 90° = 左乘 Rcw = H∘T，水平翻转 = 左乘 H。
## 两张表满足 R^4 = X^2 = 恒等，八个元素全可达；按键、吸管、存档共用同一编号。
const ALT_ROT90 := [5, 7, 4, 6, 1, 3, 0, 2]
const ALT_FLIP_H := [1, 0, 3, 2, 5, 4, 7, 6]

static func alt_rotate90(f: int) -> int:
	return int(ALT_ROT90[f & 7])

static func alt_flip_h(f: int) -> int:
	return int(ALT_FLIP_H[f & 7])

## alt → 旋转档位（0/90/180/270），供状态栏描述
static func alt_rot_deg(f: int) -> int:
	match f & 7:
		5, 4:
			return 90
		3, 2:
			return 180
		6, 7:
			return 270
		_:
			return 0

## alt 是否含水平翻转（相对未翻转基准：1/4/2/7 是 0/5/3/6 的翻转对）
static func alt_flipped(f: int) -> bool:
	return (f & 7) in [1, 4, 2, 7]

static func alt_label(f: int) -> String:
	return "%d°%s" % [alt_rot_deg(f), "·翻转" if alt_flipped(f) else ""]

static func alt_to_godot(f: int) -> int:
	var g := 0
	if f & TILE_FLIP_H:
		g |= 4096
	if f & TILE_FLIP_V:
		g |= 8192
	if f & TILE_ROT90:
		g |= 16384
	return g

static func alt_of_godot(g: int) -> int:
	var f := 0
	if g & 4096:
		f |= TILE_FLIP_H
	if g & 8192:
		f |= TILE_FLIP_V
	if g & 16384:
		f |= TILE_ROT90
	return f

## 地图正文与冻结计划的摘要使用同一序列化格式。整图撤销使用紧凑正文。
static func encode(data: Dictionary, compact := false) -> String:
	return JSON.stringify(data, "" if compact else "	")
