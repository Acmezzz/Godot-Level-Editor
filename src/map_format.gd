extends RefCounted
## 地图数据格式版本常量。单独成文件是为了让「读写的 map_store」与「校验的 map_data_validation」
## 都能引用它而不互相 preload（两者本来就有依赖方向，再反向引用就成环）。

## 当前地图数据格式版本。老图（无 version 键）视为 1。
## v4：用户层栈 meta.layers=[{id,name,visible}]（栈序底→顶，id=4 位层码）；瓦片改
## tiles={层id:[[x,y,atlas,ax,ay]...]}；实体 entities[] 加 layer=层码；collision 不变；
## terrain/decor 顶层键删除——零兼容，旧图不迁移，由校验拒绝。
## v5：瓦片条目第 3 位由「清单 tiles[] 数组序」改为**资产 id 字符串**
## （tiles={层id:[[x,y,<资产id>,ax,ay]...]}）；清单侧 tiles[]/entities[] 合并为
## assets[]（kind=scene/entity）。v5 在第 1~2 批之间是开发中间态：objects[] 尚未落地时
## 地图里仍是 entities 段——中间态期间不要接游戏工程。
const VERSION := 5
