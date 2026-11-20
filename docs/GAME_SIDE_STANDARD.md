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
| `assets` | array | **统一资产表**，`kind` 区分场景/实体，见 2.2 / 2.4 |
| `tiles` | — | **已退役**：并入 `assets[]`（`kind: "scene"`, `shape: "tile"`）。清单里出现即报错 |
| `entities` | — | **已退役**：并入 `assets[]`（`kind: "entity"`）。清单里出现即报错 |
| `functions` | dict \| array | 功能声明，见 2.5 |
| `triggers` | dict \| array | 时机池，见 2.5.4。只有 `{id, name}`，是功能/绑定引用的标签 |
| `contentDir` | string | 内容根目录（相对工程根），缺省 `content`；不允许 `..` 或绝对路径 |
| `playCommand` | string | 试玩命令模板；支持 `%mapfile%`、`%projectpath%` |
| `godotExe` | string | 可选，覆盖 `playCommand` 首个可执行文件路径；支持 `%projectpath%` |

清单校验把 `assets` 非 Array、`tileSize` 非正数、资产 id 空或重复、
**实例码重复**、图集/图片路径含 `..` 或为空、palette 元素缺 `cell`、功能/步骤/音频**条目码池内重复**、
**字段码跨池/跨功能同码**（三池共用一个码空间，同码 = 静默别名，报错）、步骤**码重复**、音频**码重复**、
时机**id/码池内重复**、字段缺 `kind` 或 kind/type 非法、挂载引用未声明的功能、功能引用未声明的条件、
功能引用未声明的时机、`timing.mode` 非法，
以及 `assets[]` 里 `kind` 非法、scene 同时给 `atlas` 与 `texture`、entity 既无 `prefab` 也无 `visual`，
判为**错误**（编辑器拒绝加载）。
功能 id 与条件 id 重复都是错误
（数组写法不查会静默后者覆盖前者）。

### 2.2 场景资产（`kind: "scene"`）

场景资产两种形态，用 `shape` 区分：

```json
{"id": "rock", "kind": "scene", "shape": "tile", "name": "岩块件套",
 "atlas": "assets/tiles/terrain_atlas.png",
 "cell": {"w": 16, "h": 16},
 "palette": [{"cell": [0, 0], "name": "单块", "cat": "地面"}, {"cell": [1, 0], "name": "顶左"}]}

{"id": "bg_forest", "kind": "scene", "shape": "image", "name": "森林背景",
 "texture": "assets/bg/forest.png", "editorSize": [1280, 720], "anchor": "top_left"}
```

| 键 | 必填 | 语义 |
|---|---|---|
| `id` | 是 | 非空且全清单唯一。**地图瓦片条目第 3 位写的就是它** |
| `kind` | 是 | 恒 `"scene"` |
| `shape` | 是 | `"tile"`（图集批量）或 `"image"`（单张图片实例） |
| `atlas` | tile 必填 | 相对工程根的 PNG 路径，不能含 `..` |
| `cell` | 否 | 图集切片尺寸 `{w, h}`；可非正方形、可大于地图格。缺省用清单 `tileSize` |
| `texture` | image 必填 | 单张图片路径 |
| `editorSize` / `anchor` | 否 | image 的编辑器占位尺寸与锚点（同时是 y 排序基准） |
| `name` | 否 | 左栏「图集列表」显示名；也是 palette 条目无 `cat` 时的兜底类别名 |
| `palette` | 否 | 精选瓦片清单；**缺省/空 = 整张图集按网格全量铺开** |
| `palette[].cell` | 是 | `[atlasX, atlasY]`，按该资产 `cell` 切分后的格子坐标 |
| `palette[].name` | 否 | 显示名，缺省 `"x,y"` |
| `palette[].cat` | 否 | 类别名；缺省用资产 `name` 作类别；再缺「未分类」 |

**索引契约已作废**：地图瓦片条目不再写「图集在清单里的下标」，而是写**资产 id 字符串**。
清单重排、插队、删除资产都不会让既有地图错位（这是 v5 相对 v4 唯一的破坏性变更）。
游戏侧按资产 id 在启动时建立 `{资产 id → TileSet source_id}` 映射，再按映射落瓦片。

游戏侧烘焙 TileSet 的源 0 里必须有 `(4,0)` 这个格子作为隐形碰撞占位瓦片
（编辑器侧常量 `constants.gd::INVISIBLE_CELL`，带整格物理多边形）。游戏侧用它做
solid+矩形碰撞：`col.set_cell(cell, 0, Vector2i(4,0))`。

### 2.3 图层 `meta.layers`（地图级声明）

```json
"layers": [
  {"id": "K2M8", "name": "资产层", "visible": true},
  {"id": "Q5T1", "name": "前景遮挡", "visible": true},
  {"id": "F9W3", "name": "FL", "visible": true}
]
```

**层 = 纯 z 槽，只管画画**：遮挡关系是层的唯一语义；资产只管摆放，层管放在哪一层。
**执行层面与层无关**——不同层的实体照常交互、不需要任何特殊代码；游戏侧逻辑管线不读图层，
层只进渲染管线。

- **混合层**：一层可同时有瓦片和实体；没有固定 BG/FL 语义（`资产层`/`FL` 只是新建图的
  默认名），用户自建任意数量的层（背景差分、前景遮挡、事件区专用层……）。
- 数组序 = **栈序**（底→顶）= 绘制序；同层内瓦片先画、实体后画。
- `id` = 4 位码，出生即定、改名不破引用（实体 `layer` / 瓦片 `tiles` 键都引用它）。
- `visible` = **运行时初始可见**（差分视图用，默认 true）；游戏侧「开关图层显示」类功能
  配合功能字段 `source: "layer:"` 在运行时切层显隐（BOSS 转阶段换景走这条路）。
- 编辑器里新建层默认插到栈顶之下；删层 = 删内容（该层瓦片与实体一并删除，撤销可回）。
- **碰撞不在层栈里**：碰撞与 z 序无关（游戏内不可见），是独立的元数据网格（见 3.3）。
- **清单 `layers[]` 已退役**：图层逐图声明，清单不再有 layers 键。

游戏侧对应：按 `meta.layers` 栈序建渲染容器（栈序 = z 序），每层一个瓦片容器 + 实体节点，
同层瓦片先实体后；碰撞读 `collision` 网格（约 30 行，同 CODES.md 映射模式）。

### 2.4 实体资产 `kind: "entity"`

```json
{
  "id": "portal",
  "kind": "entity",
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
| `id` | 是 | 全清单唯一；**同时是地图 `objects[].asset` 的值** |
| `kind` | 是 | 恒 `"entity"`；**唯一决定放置是否产码、能否挂功能** |
| `name` | 否 | 显示名，缺省用 `id` |
| `prefab` | 二者之一 | 相对工程根的 `.tscn` 路径；**游戏侧按此加载** |
| `visual` | 二者之一 | 无 prefab 时的编辑器呈现：`{mode: "rect"/"sprite"/"none", color, alpha}`；`prefab` 与 `visual` 都没有 = 校验报错 |
| `thumb` | 否 | 缩略图 PNG 路径；缺失时编辑器按 `visual` 声明画占位（不再空白） |
| `editorSize` | 否 | `[w,h]` **像素**，画布占位尺寸。缺省读 prefab 的第一个碰撞形状；再缺用 1 格（tileSize×tileSize） |
| `sizeFields` | 否 | `["w","h"]`：尺寸写在实例 `props` 的这两个键里（格数），取代「按 id 硬编码矩形」 |
| `role` | 否 | 连接语义：`portal` / `exit` / `landing` / `trigger`；见 2.6 |
| `code` | 否 | 4 位实体身份码。缺省由编辑器补发并随清单写回；**不要手工改动** |
| `functions` | 否 | **自带功能（挂载）**：声明池 functions 里功能 id 的数组，声明顺序 = 默认执行顺序；见 2.4.1 |
| `fields` | 否 | 实例级「引用型」参数声明，见 2.4.2 |

**`functions`（挂载）与 `fields` 的分工**：
- `functions` = 类型自带、实例不可删的**功能**（如生命值/攻击/寻敌），声明本体在顶层 functions 池，
  类型只挂 id。值走内容文件（与附加功能同一模型）；未编辑过的实例 = 声明 default。
- `fields` 是「引用型」参数声明，值存实例 `props`。编辑器在内容编辑器右栏按声明渲染
  引用下拉（entity_ref 列实例、map_ref 列地图，§2.4.2），复制/粘贴时按声明重映射。
  语义归游戏侧——编辑器只管选谁、存谁、画布上指给你看。

### 2.4.1 自带功能（挂载）`assets[].functions`

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

编辑器消费 `fields` 的方式：
1. **实体复制/粘贴**：`type == "entity_ref"` 的字段，若值命中块内某实例的旧 id，
   自动替换成新码（声明驱动的重映射）；`functions` 数组里的实例码字符串则不看声明、全量重映射。
2. **区域复制/粘贴**：props 与 functions 都不看声明，命中旧实例码的字符串按 id_map 盲替换。
3. `fields[].id` 必须非空且同类型内唯一（校验规则）。

`of` 键**编辑器完全不读**（没有解析代码）。写它只是给人看的注释。
`type` 其余取值（`map_ref` / `string` 等）编辑器同样不特殊处理——按字符串对待。

因此 `fields` 的本质是「**声明这个键里存的是别的实例的 id**」，好让块复制时能改指向。

### 2.5 功能声明 `functions`

两种写法都支持，归一化后结构相同（`function_decl.gd::functions`）：

```json
"functions": {
  "dialogue": {
    "name": "对话",
    "code": "X7K2",
    "fields": [
      {"id": "text", "code": "M3PQ", "name": "台词",
       "kind": "input", "type": "string", "default": ""}
    ],
    "conditions": ["has_item"]
  }
}
```

```json
"functions": [
  {"id": "dialogue", "code": "X7K2", "name": "对话", "fields": [...], "conditions": ["has_item"]}
]
```

**功能码 / 字段码**：`code` 是 4 位执行码（与地图/实例码同字符集），编辑器加载清单时给缺码
声明自动补发并随清单写回（`ensure_codes`）。**不要手工编 code**；两声明同码 = 静默别名，
校验报**错误**。人类 id 只负责显示与内容目录名——执行引用一律写码：

| 磁盘引用 | 写什么 |
|---|---|
| 地图 `objects[].functions[].fn` | 功能执行码 |
| 地图 `objects[].functions[].trigger` | 时机执行码（可选） |
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
| input | `color` | ColorPickerButton，值存 `"#rrggbb"` 字符串 |
| input | `vector2` | 两个 SpinBox（x / y），值存 `[x, y]` 数组，失焦提交 |
| input | `range` | HSlider + SpinBox，`min`/`max`/`step` 可声明，值存数字 |
| input | `asset_ref` | 资产下拉：`assetKind`（scene/entity）+ 可选 `of: "id,id"` 过滤，值存资产 id |
| choice | — | OptionButton：`options: ["a","b"]` 直给，或 `source` 动态取 |
| input | 其他任意字符串 | 只读展示 + 黄字提示（编辑器不会把数组/对象塞进可写控件） |

choice 的 `source` 取值：`content:<kind>`（列该目录内容条目）、`entity:<id,id>`（清单实体类型，
空 = 不过滤）、`entity_inst:<id,id>`（当前图实例，显示"类型 · (x,y)"，值=实例码，空 = 全部）、
`map`（地图列表）、`audio:`（音频池，值=音频码）、`asset:<kind>[:id,id]`（资产表，值=资产 id）。
值的 JSON 形态与声明不符时只读展示（vector2/range/int/float/choice 一律如此），
**绝不自动改写**。

`default` 决定新建内容时的初值：`bool`→false、`int`→`min`（缺省 0）、`float`/`range`→`min`（缺省 0.0）、
`vector2`→`[min, min]`、`color`→`"#ffffff"`、其他→`""`。

**功能声明里编辑器支持的键**：`id` / `code` / `name` / `fields` / `conditions` / `steps` /
`triggers`（白名单，见 2.5.4）/ `timing` / `view`。其余键（`scope`、`icon`、`params`、
`category`、`group` 等）一律被忽略——归一化保留已知键，未知键不剥离但不参与编辑。
`timing` 是 `{mode: "instant"|"duration"|"continuous"}`，`view` 是呈现提示对象（编辑器只存取）。
**条件依赖与触发时机是两回事**：条件 = 满足才执行，时机 = 什么时候来问这个条件。

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
| `trigger` | 可选，时机**执行码**；缺省省略 = 走功能的默认时机。必须是功能声明 `triggers` 白名单里的时机（校验只查形态，白名单由下拉保证） |
| `enabled` | 可选布尔；缺省省略 = 启用。`false` 是唯一的写盘形态 |

`trigger` 与 `enabled` 都遵守「缺省即省略」：写成默认值不会落盘，手改 JSON 也可直接删掉这两个键。
游戏侧在同一实例上按 `trigger` 决定该绑定挂到哪个判定入口；不读这两个键就相当于"默认时机 + 启用"。

游戏侧若要「顺序执行 vs 并行」，读 `order` 与 `parallel` 自行实现；编辑器不校验语义。

### 2.5.1 条件库 `conditions`（顶层声明池）

条件与功能同类：**游戏侧的代码 + 暴露的可调字段（接口）**。抽成库是为了复用与写法统一——
十个功能都要判「持有物品」，库里写一次。功能声明用 `conditions: [条件 id, ...]` 引用
（同清单内按人类 id 引用，同挂载模型）；引用未声明的条件 = 校验错误。

```json
"conditions": {
  "has_item": {
    "name": "持有物品",
    "fields": [
      {"id": "item", "code": "F7Q2", "name": "物品", "kind": "choice", "options": ["钥匙", "徽章"]}
    ]
  },
  "kill_count": {
    "name": "击杀计数",
    "fields": [
      {"id": "monster", "code": "G8R3", "name": "目标", "kind": "input", "type": "string"},
      {"id": "count", "code": "H9S4", "name": "数量", "kind": "input", "type": "int", "min": 1}
    ]
  }
}
```

分工：**条件库定义"能判断什么"（游戏侧写代码+接口），功能声明定"依赖哪个判断"，编辑器填
"具体是多少"（条件参数在实例上填，与功能参数共存于同一份内容 fields），运行时游戏侧求值**
——不满足就不执行该功能。编辑器全程不写一行判断逻辑，也不解释条件语义。

条件无执行码：功能→条件的引用只发生在清单里（按 id）；磁盘上流转的是**字段码**
（条件字段与功能字段共用一个码空间，校验查重、`ensure_codes` 补码时互相避开）。
条件区在内容表单里跟在功能字段之后，按引用顺序逐条渲染。

### 2.5.2 音频池 `audio`（顶层声明池）

音频与功能/条件同类：**游戏工程声明的资产**。条目 = `{id, name, path}`，path 指向工程内
音频文件（解释权在游戏侧，编辑器不加载、不播放、不校验存在性）；执行码由 `ensure_codes`
补发（码重复 = 校验错误）。

```json
"audio": {
  "bgm_title": {"name": "标题曲", "path": "audio/bgm_title.ogg"},
  "sfx_door":  {"name": "开门音效", "path": "audio/door.wav"}
}
```

功能/条件字段声明 `{"kind": "choice", "source": "audio:"}` 即得音频下拉，值存**音频码**。
BGM 切换、环境音触发、音效播放在哪一步响起，都是功能代码（游戏侧）的事——例如
「环境音触发区」= 一个 `visual: rect` 实体（内置的 `trigger_zone` 就是）挂上带 `audio:`
字段的功能，进区播放、离区停止由功能实现决定。编辑器全程不解释音频语义。

### 2.5.3 步骤池 `steps`（顶层声明池）+ 演出

演出 = 一个功能（挂实例、声明链引用条件库做触发）+ 内容里的**步骤数组**。游戏侧声明
**步骤池**（与 functions 同形：`{id, code, name, fields}`，条目码由 `ensure_codes` 补发），
每个步骤是游戏侧代码 + 暴露字段（move_to / play_anim / wait / show_dialogue …）。
功能声明加可选键 `"steps": true` 标记演出功能。

```json
"steps": {
  "move_to": {"name": "走到目标", "fields": [
    {"id": "target", "code": "T4N8", "name": "目标", "kind": "choice", "source": "entity_inst:"},
    {"id": "dur",    "code": "D5P9", "name": "时长(秒)", "kind": "input", "type": "float"}
  ]},
  "wait": {"name": "等待", "fields": [
    {"id": "sec", "code": "W6Q2", "name": "秒数", "kind": "input", "type": "float", "min": 0}
  ]}
}
```

对应内容文件（演出内容 = 步骤数组主体，普通字段照常共存）：

```json
{
  "id": "…", "function": "<演出功能码>", "name": "开门演出",
  "fields": {},
  "steps": [
    {"step": "<move_to码>", "fields": {"T4N8": "K7Q3", "D5P9": 1.5}},
    {"step": "<wait码>",    "fields": {"W6Q2": 0.5}}
  ]
}
```

步骤字段与功能/条件字段**共用一个码空间**（ensure_codes 补码时避开三池已占码；
校验对跨池同码直接报错）。
编辑器：内容表单对带标记的绑定渲染步骤摘要 + 「编辑演出」子面板（增删/↑↓排序/复制步，
每步填参复用 field widgets 与 choice source）。运行时游戏侧按 steps 顺序解释执行，
触发条件走条件库链路。
**编辑器写法**：子面板改动 = 读全文、改 steps 数组、整文件写回——顶层未知键与
声明缺失的步骤条目都不剥离（表单给 ⚠ 只读提示）。

**步骤条目可选的时间轴键**（缺省省略，保持线性数组可读；读写同一份 `steps`）：

| 键 | 语义 | 缺省 |
|---|---|---|
| `at` | 起始时间（秒，相对绑定开始）。一旦显式就保留——"排在几秒"本身就是信息 | 顺序累加：同轨游标从 0 起，`blocking` 步骤把游标推到 `at+duration` |
| `duration` | 持续时长；0 = 瞬发 | 0 |
| `track` | 轨道号，同轨不重叠、不同轨并行 | 0 |
| `blocking` | 是否阻塞后续同轨步骤；非阻塞 = 下一步与本步同刻开始 | true |

编辑器据此提供**时间轴视图**（与列表视图同一份数据）：拖条块改 `at`、拖右缘改 `duration`、
上下拖换轨（0.1 秒吸附，负值夹回 0）；落盘时剥掉等于缺省的 `duration/track/blocking` 键。
`at` 为负、`duration` 为负、同轨重叠只在演出面板给 ⚠ 警告，不阻断、不改数据。

### 2.5.4 时机池 `triggers`（顶层声明池）

时机是**游戏侧的判定入口**（进入地图、触碰、计时、信号……），编辑器只认识它们的名字与码。
条目 = `{id, name}`，执行码由 `ensure_codes` 补发（池内重复 = 校验错误）：

```json
"triggers": {
  "on_enter": {"name": "进入地图"},
  "on_touch": {"name": "触碰"}
}
```

**时机没有字段**——它只是一个被引用的标签，"进区后判什么"写在功能代码里。
因此时机码**不进字段码空间**（`content_id.field_codes()` 不覆盖 triggers），三池的字段码查重
与补码避让都不受它影响。

功能声明用 `triggers: [时机 id, ...]` 声明**可选时机白名单**，实例绑定再用 `trigger`
写其中一个时机的**执行码**。白名单只限制编辑器下拉给什么，不影响游戏侧解释；
引用未声明的时机 id = 校验错误。

### 2.6 `role` —— 连接语义标签

| role | 含义 | 编辑器用在哪 |
|---|---|---|
| `portal` | 图内/跨图传送门 | 无专属标记（引用连线只看 `props.target_point`，与 role 无关） |
| `exit` | 跨图出口（单向） | 画布画 `↗` + 目标图名角标 |
| `landing` | 传送落点 | 画布画落点描边 |
| `trigger` | 事件（可触发区域） | 无专属标记（矩形由 `visual` 声明画，与 role 无关） |

实体条目必须**显式声明** `role` 才有画布连接标记；不声明就是普通实体，编辑器不按实体 id 猜语义。
`trigger_zone` 由编辑器内置声明（`role: trigger`）。`role` 只在 `exit`/`landing` 两处真正落成画布标记；
`trigger` 的矩形来自资产 `visual` 声明，不靠 role。

**role 只影响画布呈现，不影响数据。**地图里不写 role，游戏侧也不该读 role 决定行为——
按 `scene`（实体 id）或 `prefab` 分发。role 存在的意义是让编辑器在换实体 id 时仍能识别连接语义。

### 2.7 内置实体种类 `trigger_zone`（显示名「事件」）

由编辑器提供，**不需要游戏工程在清单里声明**；加载清单时自动并入（`builtin=true`），
写盘前再剥掉，所以游戏工程的 `editor_manifest.json` 里看不到它。

它**没有任何特殊语义**：就是一个 `visual: rect` 的实体资产，画布按 `visual.mode/color/alpha`
画半透明矩形，尺寸走通用的 `sizeFields`。"这是事件"这件事只落在实例上挂的 `functions[]` 里
（语义全在功能里），资产本身不认识"事件"。

```json
{"id": "trigger_zone", "kind": "entity", "name": "事件", "builtin": true, "role": "trigger",
 "code": "TZ99", "anchor": "top_left", "visual": {"mode": "rect", "color": "#4fc3f7", "alpha": 0.35},
 "sizeFields": ["w", "h"], "fields": []}
```

它**没有 prefab、没有缩略图**，靠 `sizeFields: ["w", "h"]` 从实例 `props` 读尺寸（单位是**格**）。
放置时编辑器写 `props: {"w": 2, "h": 2}`；`w/h` **没有编辑控件**（见 Q8，未开），
要改只能直接改地图 JSON 或靠游戏工程声明自己的同名实体覆盖内置定义。

旧的 `props.mode` / `props.event` / `props.once` **已作废**：触发方式归功能代码，
绑定哪个时机写 `functions[].trigger`（时机码），"只触发一次"由功能实现决定。
这三键留着不影响地图加载，但编辑器既不读也不写，校验也不认它们。

**位置语义**：`trigger_zone` 声明 `anchor: "top_left"`，所以它的 `x/y` 是矩形**左上角格坐标**
（旧数据的语义因此原样保留，不需要迁移）；其他资产缺省 `anchor: "center"`，`x/y` 是锚点所在格的中心。
换算公式见 §3.4。游戏侧若把 `trigger_zone` 按格中心放置，会偏半个矩形。

`trigger_zone` **没有 prefab**，游戏侧必须自己按 `props.w/h` 建 Area2D
（不要指望按 scene 查 prefab 的通用实例化逻辑能处理它，那一步会取不到 prefab 而跳过）。

## 3. 地图 JSON `maps/<名>.json`

### 3.1 顶层结构（格式版本 `version: 5`）

```json
{
  "version": 5,
  "meta": {"name": "TEST", "w": 95, "h": 56, "code": "K7QM",
           "layers": [{"id": "K2M8", "name": "资产层", "visible": true},
                      {"id": "F9W3", "name": "FL", "visible": true}]},
  "spawn": [28, 28],
  "tiles": {"K2M8": [[21, 24, "terrain", 1, 2]], "F9W3": [[5, 9, "terrain", 3, 0]]},
  "collision": [[21, 24], [30, 12, "one_way"], [33, 4, "solid", "r45"]],
  "objects": [
    {"asset": "portal", "code": "QK3T", "layer": "K2M8", "x": 31.5, "y": 28,
     "props": {"target_point": "L8WM"}, "functions": []},
    {"asset": "bg_forest", "layer": "K2M8", "x": 0, "y": 0}
  ]
}
```

> **`objects[]` 是唯一入口**：场景图片实例与实体实例同形（`asset` 指资产），
> 差别只有 `code`——只有 `kind: "entity"` 的资产才有实例码。旧 `entities[]` 段
> 已被校验拒绝，用 `tools/migrate_project.gd` 转换（`scene` 键改名 `asset`）。

| 键 | 必填 | 语义 |
|---|---|---|
| `version` | 是 | 当前为 5；高于 5 = 编辑器打不开（报错），低于 5 = 警告并按当前结构读 |
| `meta` | 否 | 对象。编辑器只读 `name`/`w`/`h`/`code`/`layers`；**其他键原样保留**（游戏侧自定义键安全） |
| `meta.w` / `meta.h` | 否 | 地图格尺寸，缺省 120×56 |
| `meta.code` | 否 | 4 位地图身份码，编辑器缺省补发。改名不改变它 |
| `meta.layers` | 是 | **图层栈**，见 2.3；数组序 = 栈序（底→顶） |
| `spawn` | 否 | `[x, y]` 格坐标，缺省 `[2, 2]`；**给了就必须是两个数字**（否则校验报错） |
| `tiles` | 否 | 对象 `{层id: [瓦片条目...]}`，见 3.2；**键缺失与 `{}` 等价** |
| `collision[]` | 否 | 数组，见 3.3；**键缺失与 `[]` 等价**——编辑器没有任何由地形兜底生成碰撞的逻辑 |
| `objects[]` | 否 | 数组，见 3.4 |

### 3.2 瓦片条目（`tiles` 的值）

瓦片条目 5 元：

```
[x, y, <资产 id>, atlasX, atlasY]
```

| 位 | 语义 |
|---|---|
| 0 | 格坐标 x |
| 1 | 格坐标 y |
| 2 | **资产 id 字符串**（清单 `assets[]` 里 `kind: "scene"` 的 `id`）；编辑器内部映射成 TileSet `source_id`，磁盘不存整数索引 |
| 3 | 图集内格坐标 x |
| 4 | 图集内格坐标 y |

瓦片原点：格 `(x,y)` 的像素矩形 = `Rect2(x*tileSize, y*tileSize, tileSize, tileSize)`，
`tileSize` 取自清单，不是地图。**游戏侧的瓦片像素常量必须与清单 `tileSize` 一致，否则整体错位**
（建议游戏侧也从清单读 `tileSize`，而不是写死 16）。

### 3.3 碰撞条目 `collision[]`

三种写法，**由长到短**（缺省值零冗余写出）：

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

**`collision` 键缺失与 `[]` 等价**——两侧都是「无碰撞」。编辑器没有任何由地形生成碰撞的兜底
（「从地形生成碰撞」是编辑器里的手动辅助功能，只在你点弹窗时执行）。

### 3.4 摆放物条目 `objects[]`

场景图片实例与实体实例**同形**，差别只有 `code`：

```json
{"asset": "portal", "code": "QK3T", "layer": "K2M8", "x": 31.5, "y": 28,
 "props": {"target_point": "L8WM"},
 "functions": [
   {"fn": "X7K2", "content": "TEST-FY9F-QK3T-dialogue-7M2XK9",
    "name": "打招呼", "order": 1, "parallel": false, "trigger": "T111"}
 ]}

{"asset": "bg_forest", "layer": "K2M8", "x": 0, "y": 0}
```

| 键 | 必填 | 语义 |
|---|---|---|
| `asset` | 是 | 资产 id。`kind: "entity"` → 实体实例；`kind: "scene"` + `shape: "image"` → 场景图片实例。**编辑器校验：空 → 错误；不在清单 → 仅警告；图集场景（`shape: "tile"`）不能当摆放物 → 错误** |
| `code` | 仅 entity | 图内唯一实例码（4 位身份码）。**唯一身份**：引用（props 里的 entity_ref 值）、复制重映射、画布连线全靠它。码出生即定、永不回收。**场景实例写 `code` = 校验错误**（`scene` 键本身已作废） |
| `layer` | 否 | 4 位**层码**（= `meta.layers[].id`），摆在哪一层。缺省 = 最底层 |
| `x` / `y` | 否 | **浮点格坐标**，不是像素。锚点换算见下 |
| `transform` | 否 | `{scale: [sx, sy], rotation: 弧度, flip_h: bool, flip_v: bool}`。**缺省整键省略**——读不到就等于 `scale 1/1、rotation 0、不翻转` |
| `props` | 否 | 对象。类型参数 + 自定义键。**编辑器原样保留非空值，不剥离未知键**。带 `sizeFields` 声明的资产（如事件）尺寸也写在这里（格数） |
| `functions` | 否 | 数组，见 2.5；缺省视为空数组，编辑器写出时**总是写这个键**（含 `[]`） |
| `visible` | 否 | 布尔，**编辑器专用显示开关**。缺省 `true`（缺省省略）。游戏侧应忽略 |
| `zPolicy` | 否 | `"auto"`（缺省）/ `"below"` / `"above"`——**同层内分组**，不是全局 z。缺省省略 |
| `sortAnchor` | 否 | `[dx, dy]` 像素，覆盖资产排序点偏移（悬空招牌、挂墙火把）。缺省省略 |

**x/y 与像素的换算**（由资产的 `anchor` 决定，缺省 `center`）：

| `anchor` | 像素位置（节点锚点世界坐标） |
|---|---|
| `center`（缺省） | `((x + 0.5) * tileSize, (y + 0.5) * tileSize)` |
| `top_left` | `(x * tileSize, y * tileSize)` |
| `bottom_center` | `((x + 0.5) * tileSize, (y + 1) * tileSize)` |

锚点决定的是「数据坐标落在格的哪个位置」，**与贴图尺寸无关**：同一格的树不管画多高，
脚底都在该格底边。视觉矩形的左上角 = 锚点像素 − 锚点偏移（偏移由 `anchor` 和实例显示尺寸算出）。

**`props` 的保留策略是「只丢空值」**：`value == null` 或 `str(value) == ""` 的键在保存时消失，
其余（包括编辑器完全不认识的键、嵌套字典、数组）原样保留。
所以游戏侧可以往 `props` 里塞自己的数据，但要接受「空值会被清掉」。

**实例码分配规则**（`_ensure_code`，editor_canvas.gd）：实例码出生即定、**永不回收**——
放置/粘贴时生成一个本图未占用的 4 位码，之后无论复制多少次、引用多少次都不会被复用或重编。
所以 `target_point` 指向某个码是永久安全的，不需要任何引用扫描来保护号段。

> 注意：实例间的指向关系都应放在实体 `props` 里（建议同时声明 `type: "entity_ref"`，
> 编辑器才有下拉编辑入口，复制粘贴时才会跟着重映射）。

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
| 实体码 | 4 | 清单 `assets[].code` | 首次加载清单；随清单写回 |
| 实例码 | 4 | 地图 `objects[].code`（仅 entity） | 放置实例时 |
| 功能码 | 4 | 清单 `functions[].code` | 加载清单时缺则补发（`ensure_codes`） |
| 字段码 | 4 | 清单 `functions[].fields[].code` | 同上 |
| 步骤码 | 4 | 清单 `steps[].code` | 加载清单时缺则补发（ensure_codes） |
| 步骤字段码 | 4 | 清单 `steps[].fields[].code` | 同上 |
| 音频码 | 4 | 清单 `audio[].code` | 加载清单时缺则补发（ensure_codes） |
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

**名字（地图名 / 实体 `name`）一律不进 ID**，改名不破坏内容引用。

**显示壳与执行引用**：内容 ID 第四段保留功能人类 id（显示壳，人眼可读）；
磁盘上的**执行引用**写码——地图 `functions[].fn`、内容文件 `"function"`、内容 `fields` 的键。
两端映射表：编辑器保存清单时生成 `editor/CODES.md`；游戏侧启动读清单重建同款映射
（`functions[].code` ↔ `id`，`fields[].code` ↔ `id`）。

## 6. 游戏侧读取契约

### 6.1 加载顺序

```
main.gd
 ├── 决定地图路径（--map= 参数 > 默认图）
 ├── MapLoader.load_json(path)            # 纯 JSON 读，不校验
 ├── build(root, data)                     # 建各层瓦片/碰撞/实体/出生点
 ├── load_content(fn, id)                  # 功能内容按需读（可自行封装）
 └── 按绑定读 content/<功能id>/<内容ID>.json（§7.2 模式；缺键用声明 default 兜底）
```

**绝不反向写地图**。编辑器是唯一写盘方（`editor_canvas.extract()`）。游戏侧若生成运行时状态
（存档、解锁标记），写到别处，不要回写 `maps/*.json`——否则编辑器下次打开会把它当编辑数据。

### 6.2 `--map=` 参数

试玩时编辑器传 `--map=maps/xxx.json`（绝对或相对工程根）。
建议的解析顺序：`FileAccess.file_exists(原始串)` → 否则 `"res://" + 去掉前导 /`。
游戏侧新增启动参数时保持这个前缀约定，别改 `--map=` 的语义。

其他编辑器会传的参数：`--abilities=dash,glide`、`--hp=N`、`--spawnx/--spawny`（格坐标）。

### 6.3 实例化 `objects[]`

```gdscript
# 游戏侧推荐模型：按 asset 查清单拿 prefab + 锚点，不要扫目录
for o in data.get("objects", []):
	var adef := manifest_asset_def(str(o.get("asset", "")))   # 从清单按 id 查
	if adef.is_empty():
		push_warning("unknown asset: " + str(o.get("asset", "")))
		continue
	if adef.kind != "entity":
		continue          # 场景图片实例：游戏侧按自己的美术需求处理（或忽略）
	var inst := (load(adef.prefab) as PackedScene).instantiate()
	# 锚点换算：center → (x+0.5, y+0.5)；top_left → (x, y)；bottom_center → (x+0.5, y+1)
	var unit := _anchor_unit(adef.get("anchor", "center"))
	inst.position = (Vector2(float(o.get("x", 0)), float(o.get("y", 0))) + unit) * tile_size
	inst.set_meta("code", str(o.get("code", "")))
	inst.set_meta("props", o.get("props", {}))
	inst.set_meta("functions", o.get("functions", []))   # 游戏侧需要时自己注入
	inst.set_meta("asset", str(o.get("asset", "")))
	_apply_transform(inst, o.get("transform", {}))
```

**注入给 prefab 的 metadata 是唯一约定通道**。推荐注入四件：
`code`（实例码，唯一身份，引用靠它）、`props`（几何/引用参数，见 §2.4.1）、
`asset`（资产 id，查清单用）、`functions`（本实例绑定的功能）。
prefab 脚本在 `_ready()` 里读这些 meta，**不要依赖编辑器把值写进场景属性**。

绑定的 `trigger`（时机码）与 `enabled` 就装在 `functions` 数组的条目里，游戏侧自己挑：
`trigger` 缺省 = 默认时机，`enabled` 缺省 = 启用。编辑器只保证这两个键「缺省即省略」。

**`visible` 是编辑器专用**：它只控制编辑画布上是否显示，游戏侧应忽略（别因此隐藏实例）。
**`zPolicy` / `sortAnchor`** 是编辑器内排序分组与排序点，游戏侧若实现自己的 y-sort 才需要读。

**`transform` 缺省整键省略**，读不到就按 `scale 1/1、rotation 0、不翻转` 处理：

```gdscript
func _apply_transform(inst: Node2D, t: Dictionary) -> void:
	if t.is_empty():
		return
	var sc = t.get("scale", null)
	if sc is Array and (sc as Array).size() >= 2:
		inst.scale = Vector2(float(sc[0]), float(sc[1]))
	inst.rotation = float(t.get("rotation", 0.0))
	var fh := bool(t.get("flip_h", false))
	var fv := bool(t.get("flip_v", false))
	if fh or fv:
		# 根节点有 flip_h/flip_v 属性就直接 set，否则遍历子 Sprite2D
		if "flip_h" in inst:
			inst.flip_h = fh
			inst.flip_v = fv
		else:
			for s in inst.find_children("*", "Sprite2D", true, false):
				(s as Sprite2D).flip_h = fh
				(s as Sprite2D).flip_v = fv
```

**未知 `asset` 的处理**：清单里查不到该 id 就跳过并 `push_warning`。
编辑器校验已经会警告「asset is not in the current manifest」，所以运行期跳过是可接受的降级。

### 6.4 参考实现

编辑器不再附带任何示例游戏工程（原 `D:\Game\BIRD\bird` 已于 2026-11-19 删除）。
新工程从零接入时，按 §10 的检查清单逐条自己实现；下面是最小可用的读取骨架：

```gdscript
## TILE 与清单 tileSize 一致；每个资产的 cell 可非正方形（缺省 = TILE）
static func build(root: Node2D, data: Dictionary, manifest: Dictionary) -> Dictionary:
	var meta: Dictionary = data.get("meta", {})
	var mw := int(meta.get("w", 120))
	var mh := int(meta.get("h", 56))
	# 清单 assets[] 里 shape=tile 的条目 → {资产 id: source_id}；磁盘瓦片条目写的是资产 id
	var ts := TileSet.new()
	ts.tile_size = Vector2i(int(manifest.get("tileSize", 16)), int(manifest.get("tileSize", 16)))
	var src_of := {}
	for a in manifest.get("assets", []):
		if not (a is Dictionary) or str(a.get("kind", "")) != "scene" or str(a.get("shape", "")) != "tile":
			continue
		var src := TileSetAtlasSource.new()
		src.texture = load("res://" + str(a.get("atlas", "")))
		var cell: Dictionary = a.get("cell", {})
		src.texture_region_size = Vector2i(int(cell.get("w", ts.tile_size.x)), int(cell.get("h", ts.tile_size.y)))
		src_of[str(a.get("id", ""))] = ts.add_source(src, src_of.size())
	# meta.layers 栈序 = z 序（底→顶）：每层一个瓦片容器（实体节点夹层见 §3.4）
	var layers: Array = meta.get("layers", [])
	var tile_nodes := {}
	for li in layers.size():
		var tm := TileMapLayer.new()
		tm.tile_set = ts
		root.add_child(tm)
		tile_nodes[str((layers[li] as Dictionary).get("id", ""))] = tm
	for lid in (data.get("tiles", {}) as Dictionary):
		var tn: TileMapLayer = tile_nodes.get(str(lid), null)
		if tn == null:
			continue
		for c in (data.get("tiles", {})[lid] as Array):
			var a := c as Array
			if a.size() >= 5:
				# 第 3 位是资产 id → 查 source_id；查不到 = 已删资产，跳过
				var sid: int = int(src_of.get(str(a[2]), -1))
				if sid >= 0:
					tn.set_cell(Vector2i(int(a[0]), int(a[1])), sid, Vector2i(int(a[3]), int(a[4])))
	# 运行时层开关：meta.layers[].visible 先应用（差分视图/BOSS 换景，§2.3）
	for li2 in layers.size():
		var lm: Dictionary = layers[li2]
		var tn2: TileMapLayer = tile_nodes.get(str(lm.get("id", "")), null)
		if tn2 == null:
			continue
		tn2.visible = bool(lm.get("visible", true))
	# collision / objects / spawn 见 §3.3 / §3.4 / 6.3
	return {"tiles": tile_nodes, "rect": Rect2(Vector2.ZERO, Vector2(mw * TILE, mh * TILE))}
```

**不要照抄别人的工程**。上面这段只覆盖分层的瓦片渲染 + 运行时层开关；碰撞类型、实体实例化、
功能消费各自取决于目标游戏，§2.3、§3.3 和 §6.3 给了字段语义，实现自由。
## 7. 新增一个「功能」的标准流程

以「开关门」为例，游戏侧需要动三处、编辑器侧一处。

### 7.1 声明（编辑器侧，改清单）

```json
"functions": {
  "door_toggle": {
    "name": "开关门",
    "code": "D9R4",
    "fields": [
      {"id": "require_flag", "code": "F1A2", "name": "前置标记", "kind": "input", "type": "string", "default": ""},
      {"id": "once",         "code": "B3C4", "name": "只开一次", "kind": "input", "type": "bool",   "default": false},
      {"id": "speed",        "code": "E5D6", "name": "开门速度", "kind": "input", "type": "float",  "default": 2.0, "min": 0.1, "max": 20.0}
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
   `props` 只剩几何/引用（事件尺寸 w/h、target_map/target_point）。
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
| `editorSize` | 像素。省略则编辑器读 prefab 第一个碰撞形状；再省略按 1 格（tileSize×tileSize）画 |
| `functions` | 只挂已在顶层 `functions` 声明过的功能 id；资产目录「自带功能」UI 可点选挂载，也可手写清单 |
| 缩略图烘焙 | 自己写一个截图脚本把 prefab 渲染成 PNG（需窗口，不能 headless）；编辑器只读 `thumb` 路径 |

### 8.3 不要做的事

- **不要手工编 `code`**。4 位实体身份码由编辑器补发并写回清单，手改会让既有内容 ID 前缀失配。
- **不要删除已被引用的实体资产**。清单校验不拦，但地图里会留 `scene` 指向不存在资产的实体，
  游戏侧静默跳过、编辑器只警告。删资产前先扫全项目地图（资产目录的「实例分布」就是干这个的）。

## 9. 新增图集

### 9.1 追加一条 `assets[]`

```json
{"id": "cave", "kind": "scene", "shape": "tile", "name": "洞穴件套",
 "atlas": "assets/tiles/cave_atlas.png", "palette": [...]}
```

**没有「只能追加末尾」的约束了**（v5 起瓦片条目写资产 id，不写下标）。
新条目插在数组任何位置都不影响既有地图。改完保存清单，游戏侧重启即可。

### 9.2 游戏侧要保证的

1. **源 0 已烘焙**：`assets/tiles/terrain_tiles.tres` 必须存在且源 0 有 `(4,0)` 隐形碰撞格。
   游戏侧按 `assets[]` 里的 `id` 建 `{id → source_id}` 映射，映射顺序由游戏侧自定。
2. **`TILE` 一致性**：运行时 `TileSet` 的 `tile_size` 必须等于清单 `tileSize`；
   每个 `TileSetAtlasSource.texture_region_size` 取该资产的 `cell`（可非正方形，缺省 = `tileSize`）。
3. **PNG 必须在 `res://` 下且已导入**。游戏侧加载用 `load("res://" + rel)`，
   路径含 `..` 直接跳过（安全，但静默——查不到图集时只 `push_warning`）。

### 9.3 palette 可省

`palette` 省略或空数组时，编辑器把整张图集按该资产 `cell` 切格全量平铺给用户选。
小图集建议不写 palette；大图集（>8 列）建议写 palette + `cat` 分组，否则左栏要翻很久。

## 10. 游戏工程接入检查清单

要让一个**现有** Godot 工程能被编辑器接管，缺一不可：

| # | 项 | 验收方式 |
|---|---|---|
| 1 | `editor/editor_manifest.json` 存在且能通过清单校验 | 编辑器打开项目不落错误页 |
| 2 | `assets[]` 里有 `shape: "tile"` 的图集，其 PNG 路径存在 | 左栏出现图集列表 |
| 3 | 每图 `meta.layers` 至少一层（新建模板自带 资产层+FL） | 无错误 |
| 4 | `assets[]` 里每个 `kind: "entity"` 有唯一 `id`，且 `prefab` 指向真实 `.tscn`（或声明了 `visual`） | 左栏资产列表出图 |
| 5 | `editor/previews/*.png` 与 `thumb` 对应 | 画布上实体有缩略图 |
| 6 | `maps/` 目录存在（可为空） | 新建地图能保存 |
| 7 | `playCommand` 能拉起游戏并接收 `--map=` | 试玩按钮工作 |
| 8 | 游戏侧 `MapLoader` 读 `meta.w/h`、`meta.layers`、`spawn`、`tiles`、`collision`、`objects` | 试玩画面与编辑画布一致 |
| 9 | 游戏侧按 `scene` 实例化并注入 `code`/`props` | 传送门等按 props 行为正确 |
| 10 | 若用功能系统：`functions` 已声明 + 游戏侧有对应消费代码 | 挂上功能后行为生效 |

### 一次性验证命令

```
godot --path "<你的游戏工程>" -- --map=maps/<地图名>.json
```

能进游戏、地形与编辑画布一致、实体按 `props` 正确行为，就说明第 8、9 条通过。

## 11. 已知边界（照抄编辑器实现，不是待办）

- **`trigger_zone`（事件）只有尺寸没有编辑 UI**。`props.w/h` 只能手改 JSON。见 2.7。
- **图层即遮挡层**。`meta.layers` 是纯 z 槽混合层栈，每层可摆瓦片+实体；碰撞是栈外元层。
- **一个实体实例一个功能只挂一条绑定**。同一功能重复绑定只有「添加功能」菜单会过滤（校验不去重；手改 JSON 可造成重复绑定）。
- **数值参数不走 props**。props 只剩几何/引用（§2.4.1）；值一律内容文件。
- **引用字段的编辑在内容编辑器「引用」区**（§2.4.2）：entity_ref/map_ref 值写实例 props。
- **条件只在声明链上**：条件由功能声明引用（§2.5.1），绑定上没有独立的条件门——
  改条件依赖 = 改游戏工程清单，不是编辑器内操作。
- **内容 ID 不可改**。改名只改 `name`；要换 ID 只能「复制成新 ID」，旧文件留在库里。
- **地图改名不迁移引用**。`target_map` 指名字符串，改名后需手工改。
- **地图 JSON 只有一个写入方**：编辑器 `extract()`。游戏侧回写会造成格式分叉。
- **撤销是整图快照**，只覆盖地图内存态；内容文件改动不进撤销栈。

## 12. 相关文档

| 文档 | 内容 |
|---|---|
| [EDITOR_FEATURES.md](EDITOR_FEATURES.md) | 编辑器功能全貌、快捷键、已知边界索引 |
| [../README.md](../README.md) | 快速上手与目录结构 |