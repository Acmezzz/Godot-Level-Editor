# 游戏侧开发规范（编辑器数据契约）

> 面向 `D:\Game\BIRD\bird`。本文约束的是**游戏工程**该怎么声明资产/功能、怎么读编辑器产物；
> 编辑器自身的功能说明见 [EDITOR_FEATURES.md](EDITOR_FEATURES.md)。
> 所有条目以编辑器源码为准。标「未实现 / 缺口」的地方是当前真实情况，不要按想象补齐。

## 0. 一句话

编辑器只产出三样东西：**清单** `editor/editor_manifest.json`、**地图** `maps/*.json`、
**内容** `content/<功能id>/<内容ID>.json`。游戏侧只读不写；功能行为 100% 在游戏侧实现，
编辑器只负责「绑定 + 填字段」。

## 1. 数据落点

```
<游戏工程>/
├── editor/editor_manifest.json      # 清单：图集 / 图层 / 实体类型 / 功能声明
├── editor/previews/*.png            # 实体缩略图（清单 thumb 指向这里）
├── maps/<地图名>.json               # 地图（编辑器唯一的地图写盘产物）
├── maps/<地图名>.autosave.json      # 编辑器自动草稿（游戏扫描时必须忽略）
├── content/<功能id>/<内容ID>.json   # 内容条目
└── assets/tiles/*.png + *.tres      # 图集与烘焙 TileSet
```

地图名规则（`manifest.gd::is_valid_map_name`）：必须是纯文件名，不含 `/ \ : * ? " < > |`、
不以 `.` 开头、不含 `..`、不以点或空格结尾、不是 `CON/PRN/AUX/NUL`。游戏侧拼路径前照此校验。

## 2. 清单 `editor/editor_manifest.json`

### 2.1 顶层键（全部可选，缺失走默认值）

| 键 | 类型 | 编辑器行为 |
|---|---|---|
| `version` | int | 缺省补 `1`；只作迁移锚点，编辑器不按版本号拒绝清单 |
| `projectName` | string | 顶栏品牌名，缺省空 |
| `tileSize` | number | 必须 > 0（否则清单报错）；缺省 16。瓦片边长像素 |
| `screenSize` | [w,h] | 游玩视野框尺寸，缺省 `[640,360]`；纯编辑器视觉 |
| `tiles` | array | 图集列表，见 2.2 |
| `layers` | array | 地图图层，见 2.3 |
| `entities` | array | 实体类型，见 2.4 |
| `functions` | dict \| array | 功能声明，见 2.5 |
| `contentDir` | string | 内容根目录（相对工程根），缺省 `content`；不允许 `..` 或绝对路径 |
| `playCommand` | string | 试玩命令模板；支持 `%mapfile%`、`%projectpath%` |
| `godotExe` | string | 可选，覆盖 `playCommand` 首个可执行文件路径；支持 `%projectpath%` |

清单校验只把 `tiles/layers/entities` 非 Array、`tileSize` 非正数、图层 id 不受支持、
瓦片/实体 id 空或重复、图集路径含 `..`、palette 元素缺 `cell` 判为**错误**（编辑器拒绝加载）；
`terrain/decor/collision` 三个图层缺任何一个只判**警告**。

### 2.2 图集 `tiles[]`

```json
{
  "id": "rock",
  "name": "岩块件套",
  "atlas": "assets/tiles/terrain_atlas.png",
  "palette": [
    {"cell": [0, 0], "name": "单块", "cat": "地面"},
    {"cell": [1, 0], "name": "顶左"}
  ]
}
```

| 键 | 必填 | 语义 |
|---|---|---|
| `id` | 是 | 非空且全清单唯一。**仅编辑器内部标识，不写进地图** |
| `atlas` | 是 | 相对工程根的 PNG 路径，不能含 `..` |
| `name` | 否 | 左栏「图集列表」显示名；也是 palette 条目无 `cat` 时的兜底类别名 |
| `palette` | 否 | 精选瓦片清单；**缺省/空 = 整张图集按网格全量铺开** |
| `palette[].cell` | 是 | `[atlasX, atlasY]`，按 `tileSize` 切分后的格子坐标 |
| `palette[].name` | 否 | 显示名，缺省 `"x,y"` |
| `palette[].cat` | 否 | 类别名；缺省用图集 `name` 作类别；再缺「未分类」 |

**关键契约：`tiles[]` 的顺序就是地图里的 `atlas` 字段值。**
`tiles` 数组索引 = 地图 terrain/decor 条目第三位 = TileSet `source_id`。
游戏侧把 `tiles[0]` 视为烘焙 TileSet 的源 0（`assets/tiles/terrain_tiles.tres` 自带），
`tiles[1..]` 由 `map_loader._add_manifest_sources()` 运行时加载 PNG 挂成 `source_id = 索引`。

**因此：`tiles[0]` 的位置是硬契约，新图集只能追加在末尾，不能插队或重排。**
一旦重排，所有既有地图的 atlas 数字全部错位。

游戏侧烘焙 TileSet 的源 0 里必须有 `(4,0)` 这个格子作为隐形碰撞占位瓦片
（`constants.gd::INVISIBLE_CELL`，带整格物理多边形）。游戏侧 `map_loader` 用它做
solid+矩形碰撞，硬编码 `col.set_cell(cell, 0, Vector2i(4,0))`。

### 2.3 图层 `layers[]`

```json
[
  {"id": "terrain",   "name": "地形", "type": "tiles"},
  {"id": "decor",     "name": "装饰", "type": "tiles"},
  {"id": "collision", "name": "碰撞", "type": "grid"}
]
```

`id` **只允许** `terrain` / `decor` / `collision`（`manifest_validation.gd::SUPPORTED_TILE_LAYERS`），
其他 id 判错、拒绝加载。三个缺任何一个只警告，但地图数据会因缺图层而无处落地。

- 图层**顺序**决定左栏下拉顺序；也决定实体层索引（实体层 = `layers.size()`）。
- `type` 字段编辑器只做展示，**语义不参与绘制判断**——是否按格涂刷看的是 `id`。
- `name` 是左栏显示名。`decor` 层判定还额外兼容 `id` 以 `decor` 开头或 `name == "装饰"`。

编辑器不允许新增图层类型。要加「前景/背景装饰层」之类的需求，当前架构不支持，
只能在同一个 `decor` 层里靠瓦片区分。

游戏侧对应：`terrain` → 有物理的 TileMapLayer；`decor` → `collision_enabled = false`；
`collision` → 隐形瓦片/类型化物理节点。

### 2.4 实体类型 `entities[]`

```json
{
  "id": "portal",
  "name": "传送门(图内/跨图)",
  "prefab": "scenes/objects/portal.tscn",
  "thumb": "editor/previews/portal.png",
  "editorSize": [10, 10],
  "role": "portal",
  "code": "FY9F",
  "stats": [],
  "fields": [
    {"id": "target_map",   "name": "跨图目标地图(留空=图内)", "type": "map_ref"},
    {"id": "target_point", "name": "目标(落点=单向/门=双向)", "type": "entity_ref", "of": "spawn_point,portal"}
  ]
}
```

| 键 | 必填 | 语义 |
|---|---|---|
| `id` | 是 | 全清单唯一；**同时是地图 `entities[].scene` 的值** |
| `name` | 否 | 显示名，缺省用 `id` |
| `prefab` | 是（可运行实体） | 相对工程根的 `.tscn` 路径；**游戏侧按此加载** |
| `thumb` | 否 | 编辑器材质的缩略图 PNG 路径；缺失则画布上是空白占位 |
| `editorSize` | 否 | `[w,h]` **像素**，画布占位尺寸。缺省读 prefab 的第一个碰撞形状；再缺用缩略图原始尺寸 |
| `role` | 否 | 连接语义：`portal` / `exit` / `landing` / `trigger`；见 2.6 |
| `code` | 否 | 4 位实体身份码。缺省由编辑器补发并随清单写回；**不要手工改动** |
| `stats` | 否 | 类型自带的实例级参数声明，见 2.4.1 |
| `fields` | 否 | 实例级「引用型」参数声明，见 2.4.2 |

**`fields` 与 `stats` 的区别（当前实现的真实情况）：**
- `stats` 是**有值**的参数（数值/字符串），编辑器会在内容编辑器「固定功能」块里渲染控件，
  写进实例的 `props[<statId>]`。
- `fields` 编辑器**只用于两件事**：① 复制/粘贴/框选粘贴时按 `type: "entity_ref"`
  重映射实例 id 引用；② `type: "map_ref"` / `"entity_ref"` 的**类型名**给手工改 JSON 的人看。
  **编辑器当前不渲染 `fields` 的输入控件**——`portal.target_point` 这类值只能直接改地图 JSON
  或由内容编辑器之外的路径写入。

> 这是缺口，不是设计。要改「能在编辑器里点选目标落点」，得在编辑器里补控件；
> 游戏侧按当前 JSON 契约实现即可，不必等待。

### 2.4.1 `stats[]` —— 类型自带参数（数值/字符串）

```json
{"id": "hp", "name": "生命值", "type": "int", "default": 1, "min": 1, "max": 99}
```

| 键 | 必填 | 语义 |
|---|---|---|
| `id` | 是 | 实例 `props` 里的键名；同类型内唯一 |
| `name` | 否 | 控件标签，缺省用 `id` |
| `type` | 否 | `int` / `float` / 其他任意字符串。**只有 `int`/`float` 得到 SpinBox**，其余一律 LineEdit |
| `default` | 否 | 缺省值。int/float 缺省 0 / 0.0；其他类型缺省 `""` |
| `min` / `max` | 否 | 仅 int/float 生效；缺省 `-999999` / `999999` |

控件步进：`int` 步进 1.0，`float` 步进 0.1。连续控件只在失焦/回车/松手时提交。

**有效值三层合并（`def_model.gd::effective_stats`）**：

```
清单 stats[].default  ←  def 内容文件 stats  ←  实例 props.stats
```

后者覆盖前者。游戏侧 `enemy_db.gd::merge` 只实现前两层（清单默认 ← `props.stats`），
`def` 层在游戏侧未实现——**若游戏需要 `def` 层，必须自己补**。

**`props` 写盘规则**：值等于 `null` 或空字符串时**不写入**（`undo_history.extract` 的 `clean` 过滤）。
所以「把参数改回默认值」在磁盘上表现为「键消失」，游戏侧必须按「键缺失 = 用默认值」实现。

### 2.4.2 `fields[]` —— 引用型参数声明

```json
{"id": "target_point", "name": "目标", "type": "entity_ref", "of": "spawn_point,portal"}
```

编辑器实际消费的只有两点：
1. `type == "entity_ref"` 的字段，在复制/粘贴一块实例时，若值命中块内某实例的旧 id，
   自动替换成新实例 id（`selection_ops.gd::_remap_refs_in`）。
2. `fields[].id` 必须非空且同类型内唯一（校验规则）。

`of` 键**编辑器完全不读**（没有解析代码）。写它只是给人看的注释。
`type` 其余取值（`map_ref` / `string` 等）编辑器同样不特殊处理——按字符串对待。

因此 `fields` 的本质是「**声明这个键里存的是别的实例的 id**」，好让块复制时能改指向。

### 2.5 功能声明 `functions`

两种写法都支持，归一化后结构相同（`manifest.gd::functions`）：

```json
"functions": {
  "dialogue": {
    "name": "对话",
    "fields": [{"id": "text", "name": "台词", "type": "string", "default": ""}]
  }
}
```

```json
"functions": [
  {"id": "dialogue", "name": "对话", "fields": [...]}
]
```

**功能 id（`dialogue`）是稳定身份键**：它出现在内容 ID 的第四段，出现在实例 `functions[].fn`。
改名会切断既有内容引用，所以只改 `name`，不改 `id`。

**字段声明结构与 `stats[]` 完全同构**，控件映射也相同：

| `type` | 控件 |
|---|---|
| `bool` | CheckBox，即时写盘 |
| `int` / `float` | SpinBox（步进 1.0 / 0.1，`min`/`max` 可声明），失焦/回车提交 |
| 其他任意字符串 | LineEdit，回车/失焦提交，字符串 `strip_edges()` |

`default` 决定新建内容时的初值：`bool`→false、`int`→0、`float`→0.0、其他→`""`。

**功能声明里编辑器不支持的键**（别指望它们生效）：`trigger`、`scope`、`icon`、`params`、
`category`、`group` 等一律被忽略——`functions()` 归一化时只保留 `id` / `name` / `fields`。
「一个功能在什么时机触发」**不在清单里声明**，由游戏侧实现决定
（现有 `dialogue` 就是 main.gd 按距离 + 交互键触发）。

**实例上挂多个功能**：`functions` 是有序数组，每项：

```json
{"fn": "dialogue", "content": "TEST-D4L3-XXXX-dialogue-ABC123", "name": "自我介绍", "order": 1, "parallel": false}
```

| 键 | 语义 |
|---|---|
| `fn` | 功能 id，必须非空；未在清单声明只**警告**不报错（允许先放数据后补实现） |
| `content` | 内容 ID；空串 = 已绑定功能但还没建内容（合法状态） |
| `name` | 显示名，缺省用 `fn` |
| `order` | 顺序，编辑器在增删时重排为 1..n |
| `parallel` | 布尔，编辑器只存取，**不解释语义** |

游戏侧若要「顺序执行 vs 并行」，读 `order` 与 `parallel` 自行实现；编辑器不校验语义。

### 2.6 `role` —— 连接语义标签

| role | 含义 | 编辑器用在哪 |
|---|---|---|
| `portal` | 图内/跨图传送门 | 画布画「已接好」角标 |
| `exit` | 跨图出口（单向） | 画布画 `↗` + 目标图名角标 |
| `landing` | 传送落点 | 画布画落点描边 |
| `trigger` | 触发区 | 画布画半透明矩形 + 事件名 |

缺省回退表（`manifest.gd::FALLBACK_ROLES`）按实体 id 匹配：
`portal`→portal、`exit`→exit、`spawn_point`→landing、`trigger_zone`→trigger。
清单显式 `role` 优先于回退。

**role 只影响画布呈现，不影响数据。**地图里不写 role，游戏侧也不该读 role 决定行为——
按 `scene`（实体 id）或 `prefab` 分发。role 存在的意义是让编辑器在换实体 id 时仍能识别连接语义。

### 2.7 内置实体种类 `trigger_zone`

由编辑器提供，**不需要游戏工程在清单里声明**；加载清单时自动并入（`builtin=true`），
写盘前再剥掉，所以游戏工程的 `editor_manifest.json` 里看不到它。

```json
{"id": "trigger_zone", "name": "触发区", "builtin": true, "role": "trigger", "code": "TZ99", "fields": []}
```

它**没有 prefab、没有缩略图、没有 stats**。地图里它的 `props` 是编辑器硬编码的：

| `props` 键 | 编辑器含义 | 编辑器是否会写 |
|---|---|---|
| `w` / `h` | 矩形尺寸（**格**，不是像素），缺省 1 | 放置时写 2/2 |
| `mode` | 触发方式，缺省 `"enter"` | 放置时写 `"enter"` |
| `event` | 绑定事件 id，缺省空 | 放置时写 `""` |
| `once` | 是否只触发一次 | 放置时写 `true` |
| `require_flag` | 前置标记 | **编辑器从不写，也不会显示** |

`undo_history.gd::TRIGGER_PROP_KEYS` 声明了这 6 个键，但**没有任何编辑控件**——
`props` 由 `undo_history.extract` 原样保留（只要非空），要改只能直接改地图 JSON 或
靠游戏工程在 `entities` 里自己声明同名实体类型覆盖内置定义。

**位置语义（重要）**：`trigger_zone` 的 `x/y` 是矩形**左上角格坐标**，
编辑器中它按矩形中心摆放，保存时再换算回左上角；其他实体 `x/y` 是**格中心**的格子。
游戏侧若把 `trigger_zone` 当作普通实体按格中心放置，会偏半个矩形。

游戏侧当前**还没有**消费 `trigger_zone` 的实现（`map_loader` 只跳过无 prefab 的实体，
不生成节点）。要在游戏里用触发区，需要自己按 `props.w/h/mode/event/once` 建 Area2D。
## 3. 地图 JSON `maps/<名>.json`

### 3.1 顶层结构（格式版本 `version: 3`）

```json
{
  "version": 3,
  "meta": {"name": "TEST", "w": 95, "h": 56, "code": "K7QM"},
  "spawn": [28, 28],
  "terrain": [[21, 24, 0, 1, 2]],
  "decor": [[5, 9, 0, 3, 0]],
  "collision": [[21, 24], [30, 12, "one_way"], [33, 4, "solid", "r45"]],
  "entities": [{"scene": "portal", "id": "e_7", "code": "QK3T", "x": 31, "y": 28,
                "flip_h": false, "props": {"target_point": "e_10"}, "functions": []}]
}
```

| 键 | 必填 | 语义 |
|---|---|---|
| `version` | 否 | 缺省按 1；< 3 时编辑器会把实体/spawn 坐标取整后写回 3 |
| `meta` | 否 | 对象。编辑器只读 `name`/`w`/`h`/`code`；**其他键原样保留**（游戏侧自定义键安全） |
| `meta.w` / `meta.h` | 否 | 地图格尺寸，缺省 120×56 |
| `meta.code` | 否 | 4 位地图身份码，编辑器缺省补发。改名不改变它 |
| `spawn` | 否 | `[x, y]` 格坐标，缺省 `[2, 2]`；**给了就必须是两个数字**（否则校验报错） |
| `terrain[]` | 否 | 数组，见 3.2 |
| `decor[]` | 否 | 数组，见 3.2 |
| `collision[]` | 否 | 数组，见 3.3；**整个键缺失**时编辑器/游戏都退回「地形即碰撞」 |
| `entities[]` | 否 | 数组，见 3.4 |

游戏侧当前 `map_loader` **只读 `version` 之外的所有键，不检查 version**。
它同时接受旧格式（见 3.2 兼容分支），所以旧图不会崩。

### 3.2 瓦片条目 `terrain[]` / `decor[]`

新格式（v3，**5 元**）：

```
[x, y, atlas, atlasX, atlasY]
```

| 位 | 语义 |
|---|---|
| 0 | 格坐标 x |
| 1 | 格坐标 y |
| 2 | **图集索引** = 清单 `tiles[]` 的下标 = TileSet `source_id` |
| 3 | 图集内格坐标 x |
| 4 | 图集内格坐标 y |

旧格式（**4 元**）仍被两侧接受，等价于 `atlas = 0`：`[x, y, atlasX, atlasY]`。
编辑器读取时按 `arr.size() >= 5` 分支；写出**永远写 5 元**。

地图数据校验对 terrain/decor 的要求：元素必须是 Array、至少 4 个数字，
否则报 `must contain x, y, atlas_x, atlas_y`。**第 5 位不强制**（兼容旧图）。

瓦片原点：格 `(x,y)` 的像素矩形 = `Rect2(x*tileSize, y*tileSize, tileSize, tileSize)`，
`tileSize` 取自清单，不是地图。游戏侧 `map_loader.TILE` 当前硬编码 16——
**必须与清单 `tileSize` 保持一致，否则整体错位**。

### 3.3 碰撞条目 `collision[]`

四种写法，**由长到短**（缺省值零冗余写出）：

```
[x, y]                        # = solid + 矩形
[x, y, type]                  # 类型化的矩形
[x, y, type, shape]           # 类型化 + 斜坡
```

| 位 | 语义 |
|---|---|
| 0, 1 | 格坐标 |
| 2 | 类型，缺省 `"solid"` |
| 3 | 形状，缺省 `""`（矩形） |

**类型**（编辑器 UI 与游戏 `map_loader` 一一对应）：

| type | 语义 | 游戏侧实现 |
|---|---|---|
| `solid` | 整格阻挡 | `solid` + 矩形 → 隐形瓦片；其余 → StaticBody2D |
| `one_way` | 只碰顶面，可下跳穿 | StaticBody2D + `one_way_collision = true` |
| `ladder` | 可攀爬 | Area2D，加入组 `ladder`，`meta.ctype = "ladder"` |
| `hazard` | 伤害格 | Area2D，加入组 `hazard`，`meta.ctype = "hazard"` |

**形状**（只对 solid / one_way 有意义，其他类型按整格）：

| shape | 多边形（相对格左上，16×16） |
|---|---|
| `""` | 整格矩形 `(0,0)-(T,0)-(T,T)-(0,T)` |
| `r45` | 右高：`(0,T)-(T,0)-(T,T)` |
| `l45` | 左高：`(0,0)-(T,T)-(0,T)` |

写盘规则（`undo_history.extract`）：`type == "solid" && shape == ""` → 只写 `[x,y]`；
`shape == ""` → 写 `[x,y,type]`；否则写 4 元。编辑器读回来时按同样规则还原，
所以**游戏侧也必须按缺省值解释**，不能要求显式 `"solid"`。

**`collision` 键整体缺失** = 旧图，两侧都用地形瓦片兜底生成 solid 碰撞。
**`collision: []`（空数组）≠ 缺失**——空数组表示「明确无碰撞」。

### 3.4 实体条目 `entities[]`

```json
{
  "scene": "portal",
  "id": "e_7",
  "code": "QK3T",
  "x": 31,
  "y": 28,
  "flip_h": false,
  "props": {"target_point": "e_10"},
  "functions": [
    {"fn": "dialogue", "content": "TEST-FY9F-QK3T-dialogue-7M2XK9",
     "name": "打招呼", "order": 1, "parallel": false}
  ]
}
```

| 键 | 必填 | 语义 |
|---|---|---|
| `scene` | 是 | 实体类型 id = 清单 `entities[].id`。**编辑器校验：空 → 错误；不在清单 → 仅警告** |
| `id` | 否 | 图内唯一实例 id，形如 `e_N`。缺省由编辑器补号（`e_<max+1>`）。跨图引用与 `props` 里的 `entity_ref` 全靠它 |
| `code` | 否 | 4 位实例身份码，内容 ID 的第三段。缺省补发。**不要手工改** |
| `x` / `y` | 否 | **格坐标，格中心语义**：像素 = `(x + 0.5) * tileSize`。`trigger_zone` 例外，见 2.7 |
| `flip_h` | 否 | 布尔，水平翻转 |
| `props` | 否 | 对象。类型参数 + 自定义键。**编辑器原样保留非空值，不剥离未知键** |
| `functions` | 否 | 数组，见 2.5；缺省视为空数组，编辑器写出时**总是写这个键**（含 `[]`） |
| `def` | 否 | 旧格式的定义层引用（内容文件 id）。新数据不再写入，编辑器只在既有值上原样带出 |

**`props` 的保留策略是「只丢空值」**：`value == null` 或 `str(value) == ""` 的键在保存时消失，
其余（包括编辑器完全不认识的键、嵌套字典、数组）原样保留。
所以游戏侧可以往 `props` 里塞自己的数据，但要接受「空值会被清掉」。

**实体 id 分配规则**（`_assign_id`，`editor_canvas.gd:437`）：新实体优先复用本图最小空闲 `e_N`，
但**发号前会全工程扫一遍引用**（所有地图 `props` 里的 `e_N` 形字符串 + `content/events/` 下
旧事件内容的步骤值，`_referenced_ent_ids`）。被引用过的号**绝不复用**，此时取高水位 +1。
所以跨图 `target_point` 指向 `e_10` 是安全的——只要那条引用还在 JSON 里，`e_10` 不会被回收。

> 注意：引用扫描**只覆盖 `props` 与 `content/events/`**，不覆盖 `content/<其他功能>/*.json` 的
> `fields`。若你的功能字段里存 `e_N` 引用，请放进实体 `props`（并在 `fields` 里声明
> `type: "entity_ref"`），否则号可能被回收。

## 4. 内容 `content/<功能id>/<内容ID>.json`

```json
{
  "id": "TEST-FY9F-QK3T-dialogue-7M2XK9",
  "function": "dialogue",
  "name": "打招呼",
  "fields": {"text": "你终于回来了。"}
}
```

| 键 | 语义 |
|---|---|
| `id` | 与文件名同名；编辑器写盘时强制覆盖为文件名 |
| `function` | 功能 id，与所在目录名一致 |
| `name` | 显示名 |
| `fields` | `{字段id: 值}`，字段 id 来自清单 `functions[eid].fields[].id` |

**路径**：`<工程根>/<contentDir>/<function>/<id>.json`，`contentDir` 缺省 `content`。
目录名与文件名都**不能含 `.`**（目录）**或路径分隔符 / `..` / `:`**（文件名）。
文件 id 允许字母/数字/下划线/连字符/点，但不以点开头结尾。

**读不到一律当空**：编辑器与游戏侧（`content_db.gd`）对缺失/损坏/非法路径都返回 `{}`，
调用方自行兜底。运行时不该因为缺一个内容文件而崩。

**未知字段不剥离**：`fields` 里编辑器不认识的键原样保留，游戏侧可自行扩展。
但编辑器只会渲染清单声明过的字段——**没声明的键不会出现在 UI 上，也不会被编辑器删除**。

**改名/复制语义**：改名只是改 `name`（ID 不变）；「复制成新 ID」会生成新的内容码段，
名字沿用弹窗输入。删除实例的绑定**不删除内容文件**——内容条目是库资产，可能被别的实例复用。

## 5. 分层身份码

字符集 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`（32 字符，去掉易混的 I/O/0/1）。

| 层 | 长度 | 载体 | 何时发放 |
|---|---|---|---|
| 地图码 | 4 | 地图 `meta.code` | 首次打开该图 |
| 实体码 | 4 | 清单 `entities[].code` | 首次加载清单；随清单写回 |
| 实例码 | 4 | 地图 `entities[].code` | 放置实例时 |
| 功能段 | — | 清单 `functions` 的 key（功能 id 本身） | 手工声明 |
| 内容码 | 6 | 内容文件名 | 首次创建内容 |

拼装（`content_id.gd::content_id`）：

```
<地图码>-<实体码>-<实例码>-<功能id>-<内容码>
```

例：`TEST` 图上的 `portal`（实体码 `FY9F`）第 7 号实例（实例码 `QK3T`）挂对话：

```
TEST-FY9F-QK3T-dialogue-7M2XK9
```

**任一段缺失 → 不生成内容 ID**（返回空串），内容编辑器会提示「还没有身份码」，此时不写盘。

**游戏侧的用途**：不需要解析这段 ID，只要把它当不透明字符串用
（`ContentDB.load_content(fn, id)` 拼路径）。但可以做一件便宜的事——**按前缀反查归属**：
前 4 段（到功能段为止）唯一确定「哪张图的哪类哪个实例的哪个功能」，
用于「这个内容属于谁」的调试输出或分图校验。

**名字（地图名 / 实体 `name` / 实例号 `e_N`）一律不进 ID**，改名不破坏内容引用。

## 6. 游戏侧读取契约

### 6.1 加载顺序

```
main.gd
 ├── 决定地图路径（跨图过渡 > --map= > 默认图）
 ├── MapLoader.load_json(path)            # 纯 JSON 读，不校验
 ├── MapLoader.build(root, data, frozen)  # 建节点，返回 {terrain, decor, entities, dialogues, spawn, spawn_pos, rect}
 ├── ContentDB.load_content(fn, id)       # 功能内容按需读
 └── EnemyDB.merge(type_id, props)        # 数值合并
```

**绝不反向写地图**。编辑器是唯一写盘方（`editor_canvas.extract()`）。游戏侧若生成运行时状态
（存档、解锁标记），写到别处，不要回写 `maps/*.json`——否则编辑器下次打开会把它当编辑数据。

### 6.2 `--map=` 参数

试玩时编辑器传 `--map=maps/xxx.json`（绝对或相对工程根）。
`main.gd:28-31` 的解析顺序：`FileAccess.file_exists(原始串)` → 否则 `"res://" + 去掉前导 /`。
游戏侧新增启动参数时保持这个前缀约定，别改 `--map=` 的语义。

其他编辑器会传的参数：`--abilities=dash,glide`、`--hp=N`、`--spawnx/--spawny`（格坐标）。

### 6.3 实体实例化：`scene` → prefab

```gdscript
# 游戏侧推荐模型（当前 bird 用扫目录 + prefab_map()，见 6.4）
var edef := manifest_entity_def(scene_id)      # 从清单按 id 查
var inst := (load(edef.prefab) as PackedScene).instantiate()
inst.position = Vector2((x + 0.5) * tile_size, (y + 0.5) * tile_size)
inst.set_meta("ent_id", id)
inst.set_meta("props", props)
inst.set_meta("functions", functions)          # 游戏侧需要时自己注入
```

**注入给 prefab 的 metadata 是唯一约定通道**。当前 bird 已注入：
`ent_id`、`props`、`scene_id`（= `scene`，供 `EnemyDB` 查表）。
prefab 脚本在 `_ready()` 里读这些 meta，**不要依赖编辑器把值写进场景属性**。

`flip_h`：编辑器存布尔。游戏侧的处理约定（`map_loader.gd:146-151`）是
「根节点有 `flip_h` 属性就 set，否则遍历子 `Sprite2D` 全部 set」。新 prefab 建议根节点直接是
`Sprite2D` 或暴露 `flip_h`，省掉遍历。

**未知 `scene` 的处理**：当前 `map_loader` 用 `pmap.get(scene, "")`，取不到就
`continue` 静默跳过。要更严格就 `push_warning` 并记下——编辑器校验已经会警告
「entity type is not in the current manifest」，所以运行期跳过是可接受的降级。

### 6.4 当前 bird 与契约的差距（真实清单）

`bird/scripts/world/map_loader.gd` 已实现的部分（可以直接用）：
terrain/decor 5 元与 4 元解析、碰撞四类型 + 三角斜坡、`entities` 的
`ent_id`/`props`/`scene_id`/`flip_h` 注入、`spawn`、`dialogues` 收集。

**尚未对齐的（按今日代码实测）**：

| 缺口 | 现状 | 影响 |
|---|---|---|
| 不读清单 `entities[].prefab` | 用 `prefab_map()` 扫 `scenes/enemies` + `scenes/objects` 目录按文件名匹配 | 清单里 `prefab` 字段形同虚设；要换 prefab 必须改名或移目录 |
| `TILE` 硬编码 16 | 不读清单 `tileSize` | 改清单 `tileSize` 后地图整体错位 |
| 不消费 `trigger_zone` | 无 prefab → 跳过 | 触发区在游戏里不存在 |
| 不消费 `ladder` / `hazard` 组 | 建了 Area2D 并分组，但没有攀爬/伤害逻辑 | 两个碰撞类型只建了触发体 |
| `functions` 只认 `dialogue` | 其余 fn 静默忽略 | 新增功能需要改 `map_loader` |
| 无 `def` 层数值合并 | `EnemyDB.merge` 只有「清单默认 ← props.stats」 | 与编辑器 `effective_stats` 三层语义不一致 |
| 无地图清单/关卡序列 | `editor/levels.json` 在游戏侧无任何读取代码 | 关卡顺序只能靠默认图或外部脚本 |
| `maps/*.autosave.json` 未排除 | `MapLoader.maps_dir()` 只按名字拼路径 | 只有当有人在游戏里枚举 maps 目录时才会踩到 |

上表不是「要做的事」，是「两边当前不一致的地方」。哪一条要修由游戏侧决定。
## 7. 新增一个「功能」的标准流程

以「开关门」为例，游戏侧需要动三处、编辑器侧一处。

### 7.1 声明（编辑器侧，改清单）

```json
"functions": {
  "door_toggle": {
    "name": "开关门",
    "fields": [
      {"id": "require_flag", "name": "前置标记", "type": "string", "default": ""},
      {"id": "once",         "name": "只开一次", "type": "bool",   "default": false},
      {"id": "speed",        "name": "开门速度", "type": "float",  "default": 2.0, "min": 0.1, "max": 20.0}
    ]
  }
}
```

声明后编辑器立刻能在实例上选「开关门」、填三个字段，内容写到
`content/door_toggle/<内容ID>.json` 的 `fields` 下。

### 7.2 实现（游戏侧，读内容）

```gdscript
func _apply_door(inst: Node, fn: Dictionary) -> void:
	var cid := str(fn.get("content", ""))
	if cid == "":
		return                      # 已绑定功能但没内容：合法，不做任何事
	var data := ContentDB.load_content("door_toggle", cid)
	if data.is_empty():
		push_warning("door_toggle 内容缺失: " + cid)
		return
	var f: Dictionary = data.get("fields", {})
	var flag := str(f.get("require_flag", ""))
	var once := bool(f.get("once", false))
	var spd := float(f.get("speed", 2.0))
	# 这里实现行为
```

### 7.3 三条硬约定

1. **`content` 为空不是错误**。用户可能先挂功能后填内容，也可能清空内容绑定。
   静默跳过，不要报错。
2. **字段值以内容文件为准，不要读 `props`**。`props` 是 `stats` 的地盘（类型参数），
   内容字段在 `content/*.json`。
3. **`order` / `parallel` 由你解释**。编辑器只保证它们是数字/布尔并保持顺序，
   不保证游戏该怎么并发。当前 bird 对 dialogue 的做法是「按 order 排序，同一实体只取最近的一条」。

## 8. 新增一个「实体类型」的标准流程

### 8.1 清单条目

```json
{
  "id": "moving_platform",
  "name": "移动平台",
  "prefab": "scenes/objects/moving_platform.tscn",
  "thumb": "editor/previews/moving_platform.png",
  "editorSize": [32, 16],
  "stats": [
    {"id": "travel", "name": "行程(格)", "type": "float", "default": 3.0, "min": 0.5, "max": 32.0},
    {"id": "speed",  "name": "速度",     "type": "float", "default": 40.0, "min": 1.0, "max": 400.0}
  ],
  "fields": []
}
```

### 8.2 必做项

| 步骤 | 要求 |
|---|---|
| `id` | 全局唯一，且**用英文小写下划线**——它就是地图 `scene` 值，也是游戏侧查表的键 |
| `prefab` | 相对工程根的 `.tscn`。**根节点必须是 `Node2D` 系**，否则 `position` 注入无效 |
| `thumb` | 96×96 左右的 PNG 到 `editor/previews/`。没有它画布上是空白方块，但仍可放置 |
| `editorSize` | 像素。省略则编辑器读 prefab 第一个碰撞形状；再省略用缩略图原尺寸 |
| `stats` | 每个 stat 的 `default` 必填——它是游戏侧数值的默认值来源 |
| 缩略图烘焙 | 跑 `godot --path bird --script editor/bake_previews.gd`（需窗口，不能 headless） |

### 8.3 不要做的事

- **不要手工编 `code`**。4 位实体身份码由编辑器补发并写回清单，手改会让既有内容 ID 前缀失配。
- **不要重排 `tiles[]`**（见 2.2）——那是地图 atlas 数字的索引。
- **不要删除已被引用的实体类型**。清单校验不拦，但地图里会留 `scene` 指向不存在类型的实体，
  游戏侧静默跳过、编辑器只警告。删类型前先扫全项目地图。

## 9. 新增图集

### 9.1 追加到 `tiles[]` 末尾

```json
{"id": "cave", "name": "洞穴件套", "atlas": "assets/tiles/cave_atlas.png", "palette": [...]}
```

加载后它的索引（比如 1）= 地图 terrain 条目的 atlas 数字 = TileSet `source_id` 1。
游戏侧 `map_loader._add_manifest_sources()` 会把 `tiles[1..]` 全部运行时加载。

### 9.2 游戏侧要保证的

1. **源 0 已烘焙**：`assets/tiles/terrain_tiles.tres` 必须存在且源 0 有 `(4,0)` 隐形碰撞格。
   `tiles[0]` 的 PNG 只是编辑器显示用，游戏侧**不再**加载它（`_add_manifest_sources` 从索引 1 起）。
2. **`TILE` 一致性**：运行时 `TileSetAtlasSource.texture_region_size` 写死 `Vector2i(TILE, TILE)`，
   `TILE` 是常量 16。清单 `tileSize` 改成别的值，这里也得同步。
3. **PNG 必须在 `res://` 下且已导入**。`_add_manifest_sources` 用 `load("res://" + rel)`，
   路径含 `..` 直接跳过（安全，但静默——查不到图集时只 `push_warning`）。

### 9.3 palette 可省

`palette` 省略或空数组时，编辑器把整张图集按 `tileSize` 切格全量平铺给用户选。
小图集建议不写 palette；大图集（>8 列）建议写 palette + `cat` 分组，否则左栏要翻很久。

## 10. 游戏工程接入检查清单

要让一个**现有** Godot 工程能被编辑器接管，缺一不可：

| # | 项 | 验收方式 |
|---|---|---|
| 1 | `editor/editor_manifest.json` 存在且能通过清单校验 | 编辑器打开项目不落错误页 |
| 2 | `tiles[]` 至少一项，`tiles[0]` 的 PNG 路径存在 | 左栏出现图集列表 |
| 3 | `layers[]` 含 `terrain` / `decor` / `collision` | 无警告 |
| 4 | `entities[]` 每项有唯一 `id` + `prefab` 指向真实 `.tscn` | 左栏资产列表出图 |
| 5 | `editor/previews/*.png` 与 `thumb` 对应 | 画布上实体有缩略图 |
| 6 | `maps/` 目录存在（可为空） | 新建地图能保存 |
| 7 | `playCommand` 能拉起游戏并接收 `--map=` | 试玩按钮工作 |
| 8 | 游戏侧 `MapLoader` 读 `meta.w/h`、`spawn`、`terrain`、`decor`、`collision`、`entities` | 试玩画面与编辑画布一致 |
| 9 | 游戏侧按 `scene` 实例化并注入 `ent_id`/`props` | 传送门等按 props 行为正确 |
| 10 | 若用功能系统：`functions` 已声明 + 游戏侧有对应消费代码 | 挂上功能后行为生效 |

**当前 bird 的状态**：1–8 基本满足（8 有 6.4 表里的偏差），9 满足，
10 只有 `dialogue` 一个功能被消费。

### 一次性验证命令

```
godot --path "D:\Game\BIRD\bird" -- --map=maps/TEST.json
```

能进游戏、地形与编辑画布一致、传送门能通，就说明第 8 条通过。

## 11. 已知边界（照抄编辑器实现，不是待办）

- **`fields[]` 没有输入控件**。见 2.4.2。`portal.target_point` 只能手改 JSON。
- **`trigger_zone` 的 props 没有编辑 UI**。见 2.7。
- **不能新增图层类型**。只用 `terrain` / `decor` / `collision` + 实体层。
- **一个实体实例只能有一份 `props.stats`**，多份就互相覆盖——`stats` 是扁平键值表。
- **内容 ID 不可改**。改名只改 `name`；要换 ID 只能「复制成新 ID」，旧文件留在库里。
- **地图改名不迁移引用**。`target_map` 指名字符串，改名后需手工改。
- **地图 JSON 只有一个写入方**：编辑器 `extract()`。游戏侧回写会造成格式分叉。
- **撤销是整图快照**，只覆盖地图内存态；内容文件改动不进撤销栈。
- **`def` 层是遗留概念**。新数据不写 `def`；只有老地图残留时编辑器原样带出。

## 12. 相关文档

| 文档 | 内容 |
|---|---|
| [EDITOR_FEATURES.md](EDITOR_FEATURES.md) | 编辑器功能全貌、快捷键、已知边界索引 |
| [code-review-2026-11-19.md](code-review-2026-11-19.md) | 历史审查记录（全部已修） |