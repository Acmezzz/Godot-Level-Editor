extends RefCounted

## 全工程共享常量（S-01：此前 INVISIBLE_CELL 在画布与导出双定义）

## 碰撞格占位瓦片坐标：碰撞层用它做数据占位，CollisionView 负责画红块
const INVISIBLE_CELL := Vector2i(4, 0)

## P-12：组拖热区（框选集合外接框的膨胀比例）——画布提示框与按下判定共用同一常量，
## 否则 0.5~0.75 环带按下会清空整组选区但提示框还在
const GROUP_HOT := 0.5

## 地图缺省尺寸（新图对话框初值 + meta.w/h 缺失时的兜底）。
## 此前散在 5 个文件 9 处且值漂移过（content_editor 用过时的 95，其余 120）。
const DEFAULT_MAP_W := 120
const DEFAULT_MAP_H := 56
