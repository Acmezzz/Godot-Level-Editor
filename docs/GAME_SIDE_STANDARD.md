# 游戏侧开发规范（编辑器数据契约）

> 面向**任何** 2D 游戏工程。本文约束的是游戏工程该怎么声明资产/功能、怎么读编辑器产物；
> 编辑器自身的功能说明见 [EDITOR_FEATURES.md](EDITOR_FEATURES.md)。
> 所有条目以编辑器源码为准。标「未实现 / 缺口」的地方是当前真实情况，不要按想象补齐。
>
> 编辑器不绑定任何具体游戏：一个工程只要按本文摆好清单与目录，打开即用；
> 多个工程可以并行开发，编辑器里按项目列表切换。

## 0. 一句话

编辑器只产出三样东西：**清单** `editor/editor_manifest.json`、**地图** `maps/*.json`、
**内容** `content/<功能id>/<内容ID>.json`。游戏侧只读不写；功能行为 100% 在游戏侧实现，
编辑器只负责「绑定 + 填字段」。

**第一次接工程，按这个顺序读**：§1 三种文件长什么样 → §2 清单（先照抄 §10 检查清单）→
§6 游戏侧读取契约 → 其余按需查。所有身份码相关（码、表、改名）见 §5。

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
`tiles[1..]` 由游戏侧在运行时加载 PNG 挂成 `source_id = 索引`（每张图集一个 TileSetAtlasSource）。

**因此：`tiles[0]` 的位置是硬契约，新图集只能追加在末尾，不能插队或重排。**
一旦重排，所有既有地图的 atlas 数字全部错位。

游戏侧烘焙 TileSet 的源 0 里必须有 `(4,0)` 这个格子作为隐形碰撞占位瓦片
（编辑器侧常量 `constants.gd::INVISIBLE_CELL`，带整格物理多边形）。游戏侧用它做
solid+矩形碰撞：`col.set_cell(cell, 0, Vector2i(4,0))`。

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
  "functions": ["hp"],
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
| `functions` | 否 | **自带功能（挂载）**：声明池 functions 里功能 id 的数组，声明顺序 = 默认执行顺序；见 2.4.1 |
| `fields` | 否 | 实例级「引用型」参数声明，见 2.4.2 |

**`functions`（挂载）与 `fields` 的分工**：
- `functions` = 类型自带、实例不可删的**功能**（如生命值/攻击/寻敌），声明本体在顶层 functions 池，
  类型只挂 id。值走内容文件（与附加功能同一模型）；未编辑过的实例 = 声明 default。
- `fields` 是「引用型」参数声明，编辑器**只用于**复制/粘贴时按 `type: "entity_ref"`
  重映射实例 id 引用（§2.4.2）。它不是功能，也没有值编辑 UI（`portal.target_point` 这类
  值由游戏侧运行时写或手改 JSON）。

> 这是缺口，不是设计。要改「能在编辑器里点选目标落点」，得在编辑器里补控件；
> 游戏侧按当前 JSON 契约实现即可，不必等待。

### 2.4.1 自带功能（挂载）`entities[].functions`

```json
"functions": ["hp", "attack"]
```

实体类型从顶层 `functions` **声明池**里挑功能挂为「类型自带」：实例上不可删（内容编辑器里
显示 🔒），与附加功能同一套绑定/内容模型，没有任何独立的数值层：

| 事项 | 语义 |
|---|---|
| 挂载写法 | 功能 **id 数组**（人类名，清单作者手写可读）；实例绑定写**执行码** |
| 声明本体 | 字段/kind/type/default 全在顶层 `functions` 声明里（§2.5），类型不重复声明 |
| 实例值 | `content/<功能id>/<内容ID>.json`（§4）；未编辑过的实例 = 声明 `default`（游戏侧按「键缺失 = 用 default」兜底） |
| 同一功能挂多个类型 | 完全合法：共享同一声明池条目，各自实例各自的内容条目 |
| 类型差异 | 声明池里另声明一个变体功能（如 `boss_hp`），各挂各的 |
| 画布/分布 | 实例分布视图（资产目录）只读清点；值只在内容编辑器一个入口编辑 |

**props 只剩几何/引用**：触发区 `w/h`、`target_map`/`target_point` 这类引用值留在 `props`；
数值类参数一律不进 props。

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
    "code": "X7K2",
    "fields": [
      {"id": "text", "code": "M3PQ", "name": "台词",
       "kind": "input", "type": "string", "default": ""}
    ]
  }
}
```

```json
"functions": [
  {"id": "dialogue", "code": "X7K2", "name": "对话", "fields": [...]}
]
```

**功能码 / 字段码**：`code` 是 4 位执行码（与地图/实例码同字符集），编辑器加载清单时给缺码
声明自动补发并随清单写回（`ensure_codes`）。**不要手工编 code**；两声明同码 = 静默别名，
校验报**错误**。人类 id 只负责显示与内容目录名——执行引用一律写码：

| 磁盘引用 | 写什么 |
|---|---|
| 地图 `entities[].functions[].fn` | 功能执行码 |
| 内容文件 `"function"` 键 | 功能执行码 |
| 内容文件 `fields` 的键 | 字段执行码 |

人类名 ↔ 码对照表在每次保存清单时自动写到 `editor/CODES.md`；游戏侧启动时读清单重建同样的
映射（约 30 行代码），改名（id 或 name）不破任何磁盘引用。

**字段声明 = kind（input/choice）+ type**。控件映射（`field_widgets.gd`）：

| kind | type | 控件 |
|---|---|---|
| input | `string` | LineEdit，回车/失焦提交并 strip_edges；`multiline: true` 则 TextEdit（失焦提交） |
| input | `int` / `float` | SpinBox（步进 1.0 / 0.1，`min`/`max` 可声明），失焦/回车提交 |
| input | `bool` | CheckBox，即时写盘 |
| choice | — | OptionButton：`options: ["a","b"]` 直给，或 `source` 动态取 |
| input | 其他任意字符串 | 只读展示 + 黄字提示（编辑器不会把数组/对象塞进可写控件） |

choice 的 `source` 取值：`content:<kind>`（列该目录内容条目）、`entity:<id,id>`（清单实体，
空 = 不过滤）、`map`（地图列表）。值的 JSON 形态与声明不符时只读展示，**绝不自动改写**。

`default` 决定新建内容时的初值：`bool`→false、`int`→0、`float`→0.0、其他→`""`。

**功能声明里编辑器不支持的键**（别指望它们生效）：`trigger`、`scope`、`icon`、`params`、
`category`、`group` 等一律被忽略——`functions()` 归一化时只保留 `id` / `code` / `name` / `fields`。
「一个功能在什么时机触发」**不在清单里声明**，由游戏侧实现决定
（现有 `dialogue` 就是 game 侧按距离 + 交互键触发）。

**实例上挂多个功能**：`functions` 是有序数组，每项：

```json
{"fn": "X7K2", "content": "TEST-D4L3-XXXX-dialogue-ABC123", "name": "自我介绍", "order": 1, "parallel": false}
```

| 键 | 语义 |
|---|---|
| `fn` | 功能**执行码**；码未在清单声明只**警告**（允许先放数据后补声明） |
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

实体条目必须**显式声明** `role` 才有画布连接标记；不声明就是普通实体，编辑器不按实体 id 猜语义。
`trigger_zone` 由编辑器内置声明（`role: trigger`）。

**role 只影响画布呈现，不影响数据。**地图里不写 role，游戏侧也不该读 role 决定行为——
按 `scene`（实体 id）或 `prefab` 分发。role 存在的意义是让编辑器在换实体 id 时仍能识别连接语义。

### 2.7 内置实体种类 `trigger_zone`

由编辑器提供，**不需要游戏工程在清单里声明**；加载清单时自动并入（`builtin=true`），
写盘前再剥掉，所以游戏工程的 `editor_manifest.json` 里看不到它。

```json
{"id": "trigger_zone", "name": "触发区", "builtin": true, "role": "trigger", "code": "TZ99", "fields": []}
```

它**没有 prefab、没有缩略图、没有自带功能**。地图里它的 `props` 是编辑器硬编码的：

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

`trigger_zone` **没有 prefab**，游戏侧必须自己按 `props.w/h/mode/event/once` 建 Area2D
（不要指望按 scene 查 prefab 的通用实例化逻辑能处理它，那一步会取不到 prefab 而跳过）。
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

游戏侧读取时**不必检查 `version`**：下面的兼容分支已经覆盖旧格式，旧图不会崩。

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
`tileSize` 取自清单，不是地图。**游戏侧的瓦片像素常量必须与清单 `tileSize` 一致，否则整体错位**
（建议游戏侧也从清单读 `tileSize`，而不是写死 16）。

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

**类型**（编辑器 UI 的 4 个选项，游戏侧按此语义实现）：

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
    {"fn": "X7K2", "content": "TEST-FY9F-QK3T-dialogue-7M2XK9",
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
  "function": "X7K2",
  "name": "打招呼",
  "fields": {"M3PQ": "你终于回来了。"}
}
```

| 键 | 语义 |
|---|---|
| `id` | 与文件名同名；编辑器写盘时强制覆盖为文件名 |
| `function` | 功能**执行码**，与所在目录名（功能人类 id）不同——目录名给人读，文件内写码 |
| `name` | 显示名 |
| `fields` | `{字段执行码: 值}`，码来自清单 `functions[].fields[].code`（CODES.md 可查） |

**路径**：`<工程根>/<contentDir>/<function>/<id>.json`，`contentDir` 缺省 `content`。
目录名与文件名都**不能含 `.`**（目录）**或路径分隔符 / `..` / `:`**（文件名）。
文件 id 允许字母/数字/下划线/连字符/点，但不以点开头结尾。

**读不到一律当空**：编辑器与游戏侧（`content_db.gd`）对缺失/损坏/非法路径都返回 `{}`，
调用方自行兜底。运行时不该因为缺一个内容文件而崩。

**未知字段不剥离**：`fields` 里编辑器不认识的键（不在声明的码集里）原样保留；
编辑器以**只读行**展示（「未在清单中声明」+ 黄字说明），不提供可写控件，也**不会被删除**。
补回声明（code 须与磁盘键一致）即可恢复编辑。

**改名/复制语义**：改名只是改 `name`（ID 不变）；「复制成新 ID」会生成新的内容码段，
名字沿用弹窗输入。删除实例的绑定**不删除内容文件**——内容条目是库资产，可能被别的实例复用。

## 5. 分层身份码

字符集 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`（32 字符，去掉易混的 I/O/0/1）。

| 层 | 长度 | 载体 | 何时发放 |
|---|---|---|---|
| 地图码 | 4 | 地图 `meta.code` | 首次打开该图 |
| 实体码 | 4 | 清单 `entities[].code` | 首次加载清单；随清单写回 |
| 实例码 | 4 | 地图 `entities[].code` | 放置实例时 |
| 功能码 | 4 | 清单 `functions[].code` | 加载清单时缺则补发（`ensure_codes`） |
| 字段码 | 4 | 清单 `functions[].fields[].code` | 同上 |
| 功能段 | — | 内容 ID 第四段 = 功能人类 id（显示壳；执行引用不用它） | 内容创建时取当次声明 |
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

**显示壳与执行引用**：内容 ID 第四段保留功能人类 id（显示壳，人眼可读）；
磁盘上的**执行引用**写码——地图 `functions[].fn`、内容文件 `"function"`、内容 `fields` 的键。
两端映射表：编辑器保存清单时生成 `editor/CODES.md`；游戏侧启动读清单重建同款映射
（`functions[].code` ↔ `id`，`fields[].code` ↔ `id`）。

## 6. 游戏侧读取契约

### 6.1 加载顺序

```
main.gd
 ├── 决定地图路径（跨图过渡 > --map= > 默认图）
 ├── MapLoader.load_json(path)            # 纯 JSON 读，不校验
 ├── build(root, data)                     # 建地形/装饰/碰撞/实体/出生点
 ├── load_content(fn, id)                  # 功能内容按需读（可自行封装）
 └── 按绑定读 content/<功能id>/<内容ID>.json（§7.2 模式；缺键用声明 default 兜底）
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
# 游戏侧推荐模型（按 `scene` 查清单拿 prefab，不要扫目录）
var edef := manifest_entity_def(scene_id)      # 从清单按 id 查
var inst := (load(edef.prefab) as PackedScene).instantiate()
inst.position = Vector2((x + 0.5) * tile_size, (y + 0.5) * tile_size)
inst.set_meta("ent_id", id)
inst.set_meta("props", props)
inst.set_meta("functions", functions)          # 游戏侧需要时自己注入
```

**注入给 prefab 的 metadata 是唯一约定通道**。推荐注入三件：
`ent_id`（实例 id，跨图引用靠它）、`props`（几何/引用参数，见 §2.4.1）、
`scene_id`（= `scene`，类型 id，查清单用）。
prefab 脚本在 `_ready()` 里读这些 meta，**不要依赖编辑器把值写进场景属性**。

`flip_h`：编辑器存布尔。推荐处理是「根节点有 `flip_h` 属性就 set，否则遍历子 `Sprite2D` 全部 set」。
新 prefab 建议根节点直接是 `Sprite2D` 或暴露 `flip_h`，省掉遍历。

**未知 `scene` 的处理**：清单里查不到该 id 就跳过并 `push_warning`。
编辑器校验已经会警告「entity type is not in the current manifest」，所以运行期跳过是可接受的降级。

### 6.4 参考实现

编辑器不再附带任何示例游戏工程（原 `D:\Game\BIRD\bird` 已于 2026-11-19 删除）。
新工程从零接入时，按 §10 的检查清单逐条自己实现；下面是最小可用的读取骨架：

```gdscript
const TILE := 16   # 必须与清单 tileSize 一致

static func build(root: Node2D, data: Dictionary) -> Dictionary:
	var meta: Dictionary = data.get("meta", {})
	var mw := int(meta.get("w", 120))
	var mh := int(meta.get("h", 56))
	var ts := _build_tileset()          # 源 0 = 烘焙 .tres；源 1..n = 清单 tiles[1..]
	var terrain := TileMapLayer.new(); terrain.tile_set = ts; root.add_child(terrain)
	var decor := TileMapLayer.new(); decor.tile_set = ts; decor.collision_enabled = false; root.add_child(decor)
	for c in data.get("terrain", []):
		var a := c as Array
		if a.size() >= 5:
			terrain.set_cell(Vector2i(int(a[0]), int(a[1])), int(a[2]), Vector2i(int(a[3]), int(a[4])))
	for c in data.get("decor", []):
		var a2 := c as Array
		if a2.size() >= 5:
			decor.set_cell(Vector2i(int(a2[0]), int(a2[1])), int(a2[2]), Vector2i(int(a2[3]), int(a2[4])))
	# collision / entities / spawn 见 §3.3 / §3.4 / 6.3
	return {"terrain": terrain, "decor": decor, "rect": Rect2(Vector2.ZERO, Vector2(mw * TILE, mh * TILE))}
```

**不要照抄别人的工程**。上面这段只覆盖 terrain/decor；碰撞类型、实体实例化、功能消费
各自取决于目标游戏，§3.3 和 §6.3 给了字段语义，实现自由。
## 7. 新增一个「功能」的标准流程

以「开关门」为例，游戏侧需要动三处、编辑器侧一处。

### 7.1 声明（编辑器侧，改清单）

```json
"functions": {
  "door_toggle": {
    "name": "开关门",
    "code": "D9R4",
    "fields": [
      {"id": "require_flag", "code": "F1A2", "name": "前置标记", "type": "string", "default": ""},
      {"id": "once",         "code": "B3C4", "name": "只开一次", "type": "bool",   "default": false},
      {"id": "speed",        "code": "E5D6", "name": "开门速度", "type": "float",  "default": 2.0, "min": 0.1, "max": 20.0}
    ]
  }
}
```

声明后编辑器立刻能在实例上选「开关门」、填三个字段，内容写到
`content/<功能id>/<内容ID>.json` 的 `fields` 下（键是**字段码**）。

### 7.2 实现（游戏侧，读内容）

```gdscript
# 启动时从清单构建 码↔名 映射（这就是 CODES.md 的运行时等价物）：
var fn_by_code := {}      # 功能码 -> 功能 id
var field_by_code := {}   # 字段码 -> 字段 id
func _build_code_tables(manifest: Dictionary) -> void:
	for fid in (manifest.get("functions", {}) as Dictionary):
		var d := (manifest["functions"] as Dictionary)[fid] as Dictionary
		fn_by_code[str(d.get("code", ""))] = str(fid)
		for fd in (d.get("fields", []) as Array):
			field_by_code[str((fd as Dictionary).get("code", ""))] = str((fd as Dictionary).get("id", ""))

func _apply_door(inst: Node, fn: Dictionary) -> void:
	var cid := str(fn.get("content", ""))
	if cid == "":
		return                      # 已绑定功能但没内容：合法，不做任何事
	var data := ContentDB.load_content("door_toggle", cid)
	if data.is_empty():
		push_warning("door_toggle 内容缺失: " + cid)
		return
	var f: Dictionary = data.get("fields", {})
	# 内容 fields 的键是字段码 → 用映射表转回人类名再读
	var flag := str(f.get(field_by_code.get("F1A2", ""), ""))
	var once := bool(f.get(field_by_code.get("B3C4", ""), false))
	var spd := float(f.get(field_by_code.get("E5D6", ""), 2.0))
	# 这里实现行为
```

### 7.3 三条硬约定

1. **`content` 为空不是错误**。用户可能先挂功能后填内容，也可能清空内容绑定。
   静默跳过，不要报错。
2. **字段值以内容文件为准，不要读 `props`**。数值类参数一律在内容文件（§2.4.1）；
   `props` 只剩几何/引用（触发区 w/h、target_map/target_point）。
3. **`order` / `parallel` 由你解释**。编辑器只保证它们是数字/布尔并保持顺序，
   不保证游戏该怎么并发。一个可行的做法是「按 order 排序，同一实体只取最近的一条」。

## 8. 新增一个「实体类型」的标准流程

### 8.1 清单条目

```json
{
  "id": "moving_platform",
  "name": "移动平台",
  "prefab": "scenes/objects/moving_platform.tscn",
  "thumb": "editor/previews/moving_platform.png",
  "editorSize": [32, 16],
  "functions": ["platform_motion"],
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
| `functions` | 只挂已在顶层 `functions` 声明过的功能 id；资产目录「自带功能」UI 可点选挂载，也可手写清单 |
| 缩略图烘焙 | 自己写一个截图脚本把 prefab 渲染成 PNG（需窗口，不能 headless）；编辑器只读 `thumb` 路径 |

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
游戏侧要把 `tiles[1..]` 全部在运行时加载成 TileSetAtlasSource。

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

### 一次性验证命令

```
godot --path "<你的游戏工程>" -- --map=maps/<地图名>.json
```

能进游戏、地形与编辑画布一致、实体按 `props` 正确行为，就说明第 8、9 条通过。

## 11. 已知边界（照抄编辑器实现，不是待办）

- **`fields[]` 没有输入控件**。见 2.4.2。`portal.target_point` 只能手改 JSON。
- **`trigger_zone` 的 props 没有编辑 UI**。见 2.7。
- **不能新增图层类型**。只用 `terrain` / `decor` / `collision` + 实体层。
- **一个实体实例一个功能只挂一条绑定**。同一功能重复绑定会被校验/UI 过滤去重。
- **数值参数不走 props**。props 只剩几何/引用（§2.4.1）；值一律内容文件。
- **内容 ID 不可改**。改名只改 `name`；要换 ID 只能「复制成新 ID」，旧文件留在库里。
- **地图改名不迁移引用**。`target_map` 指名字符串，改名后需手工改。
- **地图 JSON 只有一个写入方**：编辑器 `extract()`。游戏侧回写会造成格式分叉。
- **撤销是整图快照**，只覆盖地图内存态；内容文件改动不进撤销栈。

## 12. 相关文档

| 文档 | 内容 |
|---|---|
| [EDITOR_FEATURES.md](EDITOR_FEATURES.md) | 编辑器功能全貌、快捷键、已知边界索引 |
| [../README.md](../README.md) | 快速上手与目录结构 |