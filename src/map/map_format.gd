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
