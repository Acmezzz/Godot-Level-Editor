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
├── editor/editor_manifest.json      # 清单：图集 / 实体资产 / 功能与字段声明
├── editor/previews/*.png            # 实体缩略图（清单 thumb 指向这里）
├── maps/<地图名>.json               # **正式地图**（游戏侧唯一要读的地图来源）
├── content/<功能id>/<内容ID>.json   # 内容条目（根目录可被清单 contentDir 改）
├── editor/                          # 编辑器私有，游戏侧一律忽略
    ├── drafts/<地图码>.json          # 自动草稿（崩溃后恢复用）
    ├── history/maps/<地图码>/        # 保存前原文件快照（保留深度见 EDITOR_FEATURES §7.3）
    ├── pending/pending-<时间戳>.json # 多文件提交日志（下次启动检查是否写全）
    └── CODES.md                     # 人类名 ↔ 执行码对照表（每次保存清单重写）
└── assets/                          # 资产目录（扫描制：目录约定 = 注册表）
    ├── tiles/                       # 图片 → 瓦片图集资产（递归；png/jpg/jpeg/webp/bmp/tga）
    ├── images/                      # 图片 → 图片摆放资产（递归；同上扩展名）
    └── entities/                    # .tscn → 实体资产（递归）
```

旧版草稿曾写在 `maps/<地图名>.autosave.json`：**只有带 `_autosave_of` 键时**才是草稿，
游戏扫描 `maps/` 时必须跳过；普通 `*.autosave.json` 后缀的地图仍可能被列出，按普通地图读。
`maps/` 下不应再出现新的编辑器私有文件（现行草稿在 `editor/drafts/`）。

本节只说明「游戏侧该读哪些目录」；**编辑器各入口一次会写哪些文件、按什么顺序写**由
`EDITOR_FEATURES.md` §7.3「各入口提交哪些文件」唯一规定（含地图历史 20 份、
内容历史 3 轮），此处不重复维护。

地图名规则（`manifest.gd::is_valid_map_name`）：必须是纯文件名，不含 `/ \ : * ? " < > |`、
不以 `.` 开头、不含 `..`、不以点或空格结尾、不是 Windows 保留设备名
（`CON/PRN/AUX/NUL`、`COM1`–`COM9`、`LPT1`–`LPT9`，带扩展名同样命中，如 `CON.json`）。游戏侧拼路径前照此校验。

## 1.1 资产发现约定（扫描制，2026-11-21 拍板）

**目录约定 = 资产注册表**：文件放进约定目录即资产，编辑器打开项目时扫描自动发现，零登记。

- **目录**：`assets/tiles/` 图片→瓦片图集资产、`assets/images/` 图片→图片摆放资产、
  `assets/entities/` .tscn→实体资产；子目录递归；约定目录之外的文件扫描不碰。
- **扩展名**：图片 = png/jpg/jpeg/webp/bmp/tga（`Image.load_from_file` 原生可读）；实体 = .tscn。
- **身份**：资产 id = 4 位资产码（`ContentId.new_asset_code`；已发放的码不重编）；`name` = 文件名 stem。
  **文件名只是显示壳**：改名后老路径消失，扫描按持久化指纹 `scanFingerprint`（md5）一对一重链原条目，
  码与地图引用全部不破；有多个同指纹候选时记 `relinkCandidates` 待用户确认，不猜。
- **消失 / 约定外**：文件消失 → 条目保留 + 标 `retired`（停用，可恢复）+ 校验警告；
  条目指向约定目录之外的文件 → 扫描完全不碰（手写条目零兼容）。
- **细配置仍走清单条目**：palette/cell/锚点/挂载功能/editorSize 等写进 `assets[]` 条目覆盖缺省，
  扫描只补骨架条目，已存在的条目从不改写。
  扫描变化（新增/重链）随下次清单保存落盘（`_codes_issued` 标记位）。
- 游戏侧读取契约不变：仍按清单 `assets[]` 条目拿 id/prefab/atlas（见 §6/§9），不要扫目录。

## 2. 清单 `editor/editor_manifest.json`

### 2.1 顶层键（全部可选，缺失走默认值）

| 键 | 类型 | 编辑器行为 |
|---|---|---|
| `version` | int | 缺省补 `1`；只作迁移锚点，编辑器不按版本号拒绝清单 |
| `projectName` | string | 顶栏品牌名，缺省空 |
| `tileSize` | number 或 [w,h] | 正数（正方形格）或两个正数（矩形格，宽高可不同），否则清单报错；缺省 16。格宽/格高像素 |
| `screenSize` | [w,h] | 游玩视野框尺寸，缺省 `[640,360]`；纯编辑器视觉 |
| `assets` | array | **统一资产表**，`kind` 区分场景/实体，见 2.2 / 2.4 |
| `tiles` | — | 非法键：出现即校验报错；瓦片资产在 `assets[]`（`kind: "scene"`, `shape: "tile"`） |
| `entities` | — | 非法键：出现即校验报错；实体资产在 `assets[]`（`kind: "entity"`） |
| `functions` | dict \| array | 功能声明，见 2.5 |
| `triggers` | dict \| array | 时机池，见 2.5.4。只有 `{id, name}`，是功能/绑定引用的标签 |
| `collisionTypes` | dict \| array | 碰撞类型池，见 2.8：画布画什么形状/颜色 + 游戏侧解释标签 gameplay |
| `contentDir` | string | 内容根目录（相对工程根），缺省 `content`；不允许 `..` 或绝对路径 |
| `playCommand` | string | 试玩命令模板；支持 `%mapfile%`、`%projectpath%` |
| `godotExe` | string | 可选，覆盖 `playCommand` 首个可执行文件路径；支持 `%projectpath%` |
| `playtest` | object | 可选。试玩面板声明驱动：`flags: [{id, name, arg}]`（勾选后启动参数**原样追加** arg）、`params: [{id, name, arg(含 %d), def, min, max}]`（数字参数，值 ≠ def 才追加）。值只存编辑器本地 prefs，键 = `<项目根>|<地图码>`（A6：两项目同名地图不串）。未声明 = 面板空态提示 |
| `playtest.executable` | string | 可选（A6）。结构化启动：可执行文件路径，支持 `%projectpath%`/`%mapfile%`；配置后编辑器用 `OS.create_process()` **直接启动**，退出状态代表游戏本体 |
| `playtest.args` | string[] | 可选（A6）。参数字符串数组，逐项替换 `%mapfile%`、`%projectpath%`（**不加引号**，空格路径由数组分段保证）。Godot 项目示例：`['--path', '%projectpath%', '--', '--map=%mapfile%']`。未配 `executable` 时退回 `playCommand` 模板，状态栏会标明跟踪的是包装进程 |
| `viewports` | array | 可选（C5）。具名参考画幅 `[{id, w, h}]`：宽屏/竖屏/分屏的坐标域身份，id 非空唯一、w/h 必填正数；`viewport_ref` 字段的下拉候选来自这里 |
| `views` | array | 可选（C5）。只读参考 `[{view_id, image, pixel_size, hotspots}]`：hotspot = `{rect: [nx,ny,nw,nh] 全 0..1, target: 对象}`。编辑器只校验形态与展示，不解释 target 语义；没有热点映射时只展示，不猜世界位置 |

清单校验把 `assets` 非 Array、`tileSize` 非正数、资产 id 空或重复、
**实例码重复**、图集/图片路径含 `..` 或为空、palette 元素缺 `cell`、功能/步骤/音频**条目码池内重复**、
**字段码跨池/跨功能同码**（三池共用一个码空间，同码 = 静默别名，报错）、步骤**码重复**、音频**码重复**、
时机**id/码池内重复**、字段缺 `kind` 或 kind/type 非法、挂载引用未声明的功能、功能引用未声明的条件、
功能引用未声明的时机、`timing.mode` 非法、`playtest` 结构错（flags 缺 `arg` / params 的 `arg` 缺 `%d` / id 重复 / name 空 /
`executable` 非字符串 / `args` 非字符串数组）、
顶层可选键形态错（`playCommand`/`godotExe`/`contentDir` 非字符串、`contentDir` 含 `..` 或绝对路径、`screenSize` 非 `[w,h]` 数值），
以及 `assets[]` 里 `kind` 非法、scene 同时给 `atlas` 与 `texture`、entity 既无 `prefab` 也无 `visual`，
判为**错误**（编辑器拒绝加载）。
功能 id 与条件 id 重复都是错误
（数组写法不查会静默后者覆盖前者）。
新键同样校验（C1–C5）：`viewports` 的 id 非空唯一、w/h 正数；`views` 的 view_id 非空唯一、image 字符串、
pixel_size 正数、hotspot rect 四个 0..1 数且 target 为对象；`assets[].ports` 的 id 非空唯一、x/y 数字；
`of: "record"` 的数组字段要求非空 `fields`（子字段 id 唯一、kind input|choice、type 白名单、嵌套限深 4）；
地图 `meta.cellGraph` 见 §3.1（坏格图 = 地图校验错误）。

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

**索引契约**：地图瓦片条目写**资产 id 字符串**，不写「图集在清单里的下标」。
清单重排、插队、删除资产都不会让既有地图错位。
游戏侧按资产 id 在启动时建立 `{资产 id → TileSet source_id}` 映射，再按映射落瓦片。

**碰撞不依赖任何图集**：`(4,0)` 隐形格只是编辑器内部碰撞层的载体（自建 5×1 切片源，
常量 `constants.gd::INVISIBLE_CELL`），不是游戏侧契约。通用游戏工程可直接读 `collision[]`
（§3.3）建 `CollisionShape2D`/物理多边形，无需烘焙占位瓦片、也无需固定图集名。
只有你真的声明了图集资产（`shape: "tile"`）时，才需要为它配置对应的 TileSet 图源。

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
  默认名），用户自建任意数量的层（背景差分、前景编辑、事件区专用层……）。
- 数组序 = **栈序**（底→顶）= 绘制序；同层内瓦片先画、实体后画（层未开 `ySort` 时）。
- `id` = 4 位码，出生即定、改名不破引用（实体 `layer` / 瓦片 `tiles` 键都引用它）。
- `visible` = **运行时初始可见**（差分视图用，默认 true）；游戏侧「开关图层显示」类功能
  配合功能字段 `source: "layer:"` 在运行时切层显隐（BOSS 转阶段换景走这条路）。
- 编辑器里新建层默认插到栈顶之下；删层 = 删内容（该层瓦片与实体一并删除，撤销可回）。
- **碰撞不在层栈里**：碰撞与 z 序无关（游戏内不可见），是独立的元数据网格（见 3.3）。
- 图层逐图声明：图层在每张地图的 `meta.layers`，清单没有 layers 键。

**层参数（可选，缺省省略）**：

| 键 | 语义 | 缺省 |
|---|---|---|
| `parallax` | 视差系数：1.0 = 跟随，0.5 = 半速，0 = 固定（编辑器画布按相机位移反向平移预览） | 1.0 |
| `ySort` | 该层内瓦片与实例一起按排序点 y 绘制（遮挡模型，见下） | false |
| `blend` | 层混合模式：`mix`（缺省，省略）/ `add`（加法，发光类）/ `mul`（相乘，遮罩类）；编辑器层管理弹窗可改，画布与游戏侧渲染端挂对应材质 | 省略 = mix |
| `offset` | `[x, y]` 像素，层的整体偏移 | `[0, 0]` |
| `scale` | 层的整体缩放 | 1.0 |

**录入方式**：层管理弹窗（图层栏的 ⚙）逐项可改——`blend` 是三项下拉（混合/加法/相乘），
`ySort` 是勾选框，`parallax`/`offset.x`/`offset.y`/`scale` 是回车提交的数字框（`scale` 拒绝 ≤0）。
每次提交都是一条撤销；空值/缺省值一律省略不写盘。

**遮挡模型（3.7）**：层是硬边界——跨层只按栈序，任何对象都不能越过层；**全程不写 `z_index`**。
同层内三个分段，树序保证顺序、段内 y-sort 保证交错：

```
层容器（不启用 y_sort）
├── below   永久被同层所有东西盖住（zPolicy: below 的实例进这里）
├── YSort   瓦片 + zPolicy:auto 的实例同住一个 y-sorted 父（层声明 ySort:true 时生效）
└── above   永久盖住同层所有东西（zPolicy: above 的实例进这里）
```

排序点 = 资产 `anchor`（实例覆盖 `sortAnchor`），瓦片用 palette 条目 `ySortOrigin`
（像素，相对切片顶部，缺省 = 切片底部）。`zPolicy` 是同层内的分组，不是全局 z。
未开 `ySort` 的层：YSort 段退化为摆放先后（树序）。

游戏侧对应：按 `meta.layers` 栈序建渲染容器，**每层建同样的三段容器、不写 `z_index`**；
瓦片与 auto 实例放进同一个 y-sorted 父节点（层声明 ySort 时开 `y_sort_enabled`）；
碰撞读 `collision` 网格。

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
| `thumb` | 否 | 缩略图 PNG 路径；缺失时编辑器按 `visual` 声明画占位 |
| `frames` | 否 | 帧动画贴图路径数组（按播放顺序）；编辑器画布按 8fps 循环**预览**（只确认帧序），游戏侧自定播放节奏。预览优先级：thumb > texture（image 资产）> frames 首帧 |
| `editorSize` | 否 | `[w,h]` **像素**，画布占位尺寸。缺省读 prefab 的第一个碰撞形状；再缺用 1 格（tileSize 尺寸） |
| `sizeFields` | 否 | `["w","h"]`：尺寸写在实例 `props` 的这两个键里（格数），取代「按 id 硬编码矩形」 |
| `role` | 否 | 连接语义：`portal` / `exit` / `landing` / `trigger`；见 2.6 |
| `code` | 否 | 4 位实体身份码。缺省由编辑器补发并随清单写回；**不要手工改动** |
| `functions` | 否 | **自带功能（挂载）**：声明池 functions 里功能 id 的数组，声明顺序 = 默认执行顺序；见 2.4.1 |
| `fields` | 否 | 实例级「引用型」参数声明，见 2.4.2 |
| `ports` | 否 | 端口声明（C3）`[{id, x, y, type?}]`：x/y 为锚点局部像素，id 资产内唯一、type 可选字符串；`port_ref` 字段据此出候选。见 2.4.2 |

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

**编辑器只主动写几何/引用类键**：触发区 `w/h`、`target_map`/`target_point` 这类引用值写在 `props`；
数值类参数编辑器不主动写进 props（游戏侧自己塞的键原样保留，见 §3.4 的保留策略）。

### 2.4.2 `fields[]` —— 引用型参数声明

```json
{"id": "target_point", "name": "目标", "type": "entity_ref", "of": "spawn_point,portal"}
```

编辑器消费 `fields` 的方式（**声明驱动，不做字符串盲扫**）：
1. **只改声明为引用的字段**：`entity_ref`（实例码）、`port_ref`（端口引用）、
   `choice.source` 为 `content:` / `entity_inst:` 的字段。未声明的字符串键一律原样保留，
   哪怕它的值恰好等于某个旧实例码。
2. **组内换新、组外保留**：值命中本次复制集合里的实例 → 换成新码；指向集合外的目标 → 原样保留
   （不让副本错误地指回源对象）。引用属于源图以外的图时同样保留。
3. **`mapField` 配对**：`entity_ref` 声明 `mapField: "<地图字段 id>"` 时，目标域 = 该地图字段的**当前行值**
   （不是全局当前图）。组内引用把配对字段改写成副本所在图；组外跨图引用写成源图键（地图码优先、缺码用图名）。
   无配对字段的组外跨图引用 = **冲突**，整次复制取消并列出原因，不做半套应用。
4. **数组与 record**：`of: "record"` 的数组逐行递归同一套规则，行内兄弟字段就是配对作用域
   （一行内的 `mapField` 只读本行值）；嵌套限深 4。
5. **目标缺失**：引用值指向不存在的实例/内容时，复制不猜、不改写，保留原值；
   引用完整性由项目自检（`ProjectAudit`）另行报告。
6. `fields[].id` 必须非空且同类型内唯一（校验规则）。

`of` 键在 `type: "entity_ref"` 时**被编辑器读取**（内容编辑器引用行）：限定实例下拉只列
指定类型（逗号分隔类型 id，可多个）；不写 = 列全部实例。
引用类取值都有专用编辑入口：`entity_ref`（实例下拉，`of` 限定类型）、`map_ref`（地图下拉，值 = 地图码）；
其余取值（`string` 等）编辑器按字符串对待。

因此 `fields` 的本质是「**声明这个键里存的是别的实例的 id**」，好让块复制时能改指向。

**端口（C3）**：资产可声明 `ports: [{id, x, y, type?}]`（`x`/`y` 为锚点局部像素），给开关/插槽/出入口这类
「实例上的具名连接点」一个稳定身份。字段声明 `type: "port_ref"`、`of: "类型,类型"`（可选，按端口 `type` 过滤）时，
值存 `{map: 地图码, inst: 实例码, port: 端口ID}`；块复制只改前两段，端口 id 不变。端口 id 在单个资产内非空唯一。

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
| input | `array` | 可增删行容器，每行一个元素控件（`of` 指基础类型或 choice，不嵌套 array）；值存元素数组 |
| input | `array` + `of: "record"` | 结构化行容器（C1）：`fields` 声明子字段（id/code/name/kind/type，可再嵌 array，限深 4）；每行带 ↑↓/复制/删除；值存对象数组 |
| input | `port_ref` | 端口下拉（C3）：`of` = 端口类型过滤（可选），值存 `{map, inst, port}` |
| input | `viewport_ref` | 视口下拉 + 归一化 SpinBox（C5）：值存 `{viewport, point: [nx, ny]}`；`rect: true` 则 `{viewport, rect: [nx, ny, nw, nh]}` |
| choice | — | OptionButton：`options: ["a","b"]` 直给，或 `source` 动态取；`multiple: true` 切勾选组，值存字符串数组 |
| input | 其他任意字符串 | 只读展示 + 黄字提示（编辑器不会把数组/对象塞进可写控件） |

choice 的 `source` 取值：`content:<kind>`（列该目录内容条目）、`entity:<id,id>`（清单实体类型，
空 = 不过滤）、`entity_inst:<id,id>`（当前图实例，显示"类型 · (x,y)"，值=实例码，空 = 全部）、
`map`（地图列表）、`audio:`（音频池，值=音频码）、`asset:<kind>[:id,id]`（资产表，值=资产 id）、
`port:<类型,类型>`（配对图优先的实例端口，值=`{map, inst, port}`）、`cell:`（当前图 `meta.cellGraph` 的 cell_id，值=格 id）、
`viewport:`（清单 `viewports` 的画幅 id，值=画幅 id）。
值的 JSON 形态与声明不符时只读展示（vector2/range/int/float/choice 一律如此），
**绝不自动改写**。

`default` 决定新建内容时的初值：`bool`→false、`int`→`min`（缺省 0）、`float`/`range`→`min`（缺省 0.0）、
`vector2`→`[min, min]`、`color`→`"#ffffff"`、其他→`""`。

字段行的悬浮说明由编辑器**从已声明的键拼出**（字段 id · 执行码 · 类型与 min/max · 可选值或
`source` · `default`），见 `field_widgets.gd::decl_tooltip`。契约里**没有**独立的「说明」「单位」
键：需要自由文字或单位时，游戏侧先把键写进本文档，编辑器才接——不自行发明。当前惯例是
把单位写进 `name`（如 `时长(秒)`、`数量(格)`）。

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
功能声明加可选键 `"steps": true` 标记演出功能；演出时间基可选 `timebase`：
`"seconds"`（缺省，at/duration 单位秒、0.1 吸附）/ `"frames"`（单位帧、1 帧吸附，格斗帧数据）/
`"beats"`（单位拍、1/4 拍吸附，节奏谱面）——数据形态（at/duration/track）不变，游戏侧按声明解释单位。

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
**显式 `0` 是保留的**：`at: 0` 与省略等价但不剥除（那是「排在开头」的显式表达）；
`duration`/`track`/`blocking` 等于缺省值时才剥。

**`frames`/`beats` 的换算参数也从声明来**（`functions[].timePreview`，`TimelineClock.from_decl`）：
`fpsField` / `offsetField` / `subdivisionsPerBeat` / `tempoStep` + `bpmField`（速度段 = 一个步骤填 BPM，
`beat` 严格递增、BPM 有限正数）。声明里写**字段 id**，编辑器按功能字段声明转成字段码再读值。
声明了但解析不到（缺字段码、BPM 段为空）→ 面板给具体缺项提示，按原单位继续编辑，不阻断。
**速度段按区间两端换算**：跨段长音的秒数 = 各段 `Δbeat × 60 / bpm` 累加，不是单一 BPM 外推。

**试听现状（缺口，别按想象实现）**：编辑器只解析并显示音频曲目身份（`source: "audio:"` 的值 = 音频码），
**没有**编辑器内播放、波形或听觉对齐，也不回写 `at`。校对偏移只能在游戏侧做。

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
放置时编辑器写 `props: {"w": 2, "h": 2}`。**改尺寸**：选中实例后拖右下角尺寸把手（一次拖动一条撤销），
或在属性区直接填。带 `sizeFields` 声明的自建资产同样适用这套把手（键名取自声明）。

`props.mode` / `props.event` / `props.once` 不是有效键：触发方式归功能代码，
绑定哪个时机写 `functions[].trigger`（时机码），"只触发一次"由功能实现决定。
编辑器既不读也不写这三键，校验也不认它们。

**位置语义**：`trigger_zone` 声明 `anchor: "top_left"`，所以它的 `x/y` 是矩形**左上角格坐标**
（旧数据的语义因此原样保留，不需要迁移）；其他资产缺省 `anchor: "center"`，`x/y` 是锚点所在格的中心。
换算公式见 §3.4。游戏侧若把 `trigger_zone` 按格中心放置，会偏半个矩形。

`trigger_zone` **没有 prefab**，游戏侧必须自己按 `props.w/h` 建 Area2D
（不要指望按 scene 查 prefab 的通用实例化逻辑能处理它，那一步会取不到 prefab 而跳过）。

### 2.8 碰撞类型池 `collisionTypes`（顶层声明池）

碰撞**类型集**由清单声明；类型决定画布画什么（形状/颜色），语义归游戏侧：

```json
"collisionTypes": {
  "solid":   {"name": "阻挡", "shape": "rect", "gameplay": "block"},
  "one_way": {"name": "单向", "shape": "rect", "gameplay": "one_way"},
  "ice":     {"name": "冰面", "shape": "rect", "gameplay": "slide", "color": "#88ccff"}
}
```

| 键 | 说明 |
|---|---|
| `name` | 编辑器下拉显示名 |
| `shape` | 编辑器画什么：`rect` / `triangle_r` / `triangle_l` / `circle` / `polygon`（缺省 `rect`；画布目前只画 rect/斜坡，其余按矩形画） |
| `gameplay` | 游戏侧自己的解释标签，编辑器只存取不解释 |
| `color` | 可选，画布色块颜色（`#rrggbb`）；未声明按 id 稳定取色 |

缺省池 = 内置四类（solid/one_way/ladder/hazard）；**声明即整体覆盖**（不混搭内置）。
碰撞条目的 `type` 写类型 id，校验只查形状与唯一性；未声明的类型 id 游戏侧自行降级。

## 3. 地图 JSON `maps/<名>.json`

### 3.1 顶层结构（格式版本 `version: 7`）

```json
{
  "version": 7,
  "meta": {"name": "TEST", "w": 95, "h": 56, "code": "K7QM",
           "layers": [{"id": "K2M8", "name": "资产层", "visible": true,
                       "parallax": 0.5, "ySort": false, "offset": [0, 0], "scale": 1.0},
                      {"id": "F9W3", "name": "FL", "visible": true}]},
  "spawn": [28, 28],
  "tiles": {"K2M8": [[21, 24, "terrain", 1, 2, 0]], "F9W3": [[5, 9, "terrain", 3, 0, 0]]},
  "collision": [{"x": 21, "y": 24}, {"x": 30, "y": 12, "type": "one_way"},
                {"x": 33, "y": 4, "type": "hazard", "shape": "r45"}],
  "objects": [
    {"asset": "portal", "code": "QK3T", "layer": "K2M8", "x": 31.5, "y": 28,
     "props": {"target_point": "L8WM"}, "functions": []},
    {"asset": "bg_forest", "layer": "K2M8", "x": 0, "y": 0}
  ]
}
```

> **`objects[]` 是唯一入口**：场景图片实例与实体实例同形（`asset` 指资产），
> 差别只有 `code`——只有 `kind: "entity"` 的资产才有实例码。`entities[]` 键校验报错，
> 用 `tools/migrate_project.gd` 转换（`scene` 键改名 `asset`）；`collision[]` 条目是对象
> `{x, y, type?, shape?}`（缺省省略），旧数组形态校验报错，跑迁移脚本转换。
>
> **几何实体（R-02）**：资产声明 `visual: {type: "poly"/"path", color/alpha/closed/width, points}` 的实体，
> 编辑器在实例 `props.points` 写 `[[x,y],…]`（像素、相对实例锚点）——曲线赛道/区域/路径用它表达，
> 游戏侧读 props 透传（如建 Line2D/Polygon2D，点序即编辑器画布顺序）。

| 键 | 必填 | 语义 |
|---|---|---|
| `version` | 是 | 当前为 7；高于 7 = 编辑器打不开（报错），低于 7 = 警告并按当前结构读（跑迁移脚本升级） |
| `meta` | 否 | 对象。编辑器读写 `name`/`w`/`h`/`code`/`layers` 与 `gridProjection`/`gridTopology`/`gridBasis`（格空间三件），只读参考 `cellGraph`；**其他键原样保留**（游戏侧自定义键安全） |
| `meta.w` / `meta.h` | 否 | 地图格尺寸，缺省 120×56 |
| `meta.code` | 否 | 4 位地图身份码，编辑器缺省补发。改名不改变它 |
| `meta.layers` | 是 | **图层栈**，见 2.3；数组序 = 栈序（底→顶） |
| `meta.gridProjection` | 否 | 逐图投影（B1）：`orthogonal`（缺省）/ `isometric` / `hexagonal`。缺键 = 沿用项目解析（清单任一瓦片资产声明非正交即整项目按它） |
| `meta.gridTopology` | 否 | 格拓扑（B3）：`quads`（缺省）/ `triangles`。三角格 = 每列平行四边形切成两个半格，格号 `(i,row)` 的 `i` 是三角列（`c = floor(i/2)`，奇偶选半格）；六边投影 + 三角格 = 非法组合 |
| `meta.gridBasis` | 否 | 斜平面双基 `[[ux,uy],[vx,vy]]`（B3）：`to_px = g.x·u + g.y·v`。非有限或不可逆（共线/零向量）校验报错 |
| `meta.cellGraph` | 否 | 有限格图（C4）`{cells: [{id, polygon, neighbors}]}`：只读参考层，id 非空唯一、polygon ≥3 个 `[x, y]` 数字点、neighbors 目标必须已声明；内容字段用 `source: "cell:"` 枚举。第一版不进 v7 整数瓦片坐标 |
| `spawn` | 否 | `[x, y]` 格坐标，缺省 `[2, 2]`；**给了就必须是两个数字**（否则校验报错） |
| `tiles` | 否 | 对象 `{层id: [瓦片条目...]}`，见 3.2；**键缺失与 `{}` 等价** |
| `collision[]` | 否 | 数组，见 3.3；**键缺失与 `[]` 等价**——编辑器没有任何由地形兜底生成碰撞的逻辑 |
| `objects[]` | 否 | 数组，见 3.4 |

### 3.2 瓦片条目（`tiles` 的值）

瓦片条目 6 元。第 6 位 alt = 变换位（0-7：bit0 水平翻转 / bit1 垂直翻转 / bit2 转置90°，0 = 原样）；
游戏侧落瓦片时转成 TileSet alternative，与编辑器互转口径见 `src/map/map_format.gd` 的 `alt_to_godot`/`alt_of_godot`：

```
[x, y, <资产 id>, atlasX, atlasY, alt]
```

| 位 | 语义 |
|---|---|
| 0 | 格坐标 x |
| 1 | 格坐标 y |
| 2 | **资产 id 字符串**（清单 `assets[]` 里 `kind: "scene"` 的 `id`）；编辑器内部映射成 TileSet `source_id`，磁盘不存整数索引 |
| 3 | 图集内格坐标 x |
| 4 | 图集内格坐标 y |
| 5 | 变换位 alt（0-7）；`alt != 0` 的瓦片用对应变换落盘/渲染，缺省 0 |

瓦片原点：格 `(x,y)` 的像素矩形 = `Rect2(x*TILE_W, y*TILE_H, TILE_W, TILE_H)`，
TILE_W/TILE_H = 清单 `tileSize`（标量或 `[w,h]` 矩形格），取自清单，不是地图。
**游戏侧的瓦片像素常量必须与清单 `tileSize` 一致，否则整体错位**
（建议游戏侧也从清单读 `tileSize`，而不是写死 16）。

> **非正交投影的格原语**：上面的矩形公式只对 `orthogonal` 成立。等距（`isometric`）格是 2:1 菱形，
> 六边（`hexagonal`）是 odd-r 错行尖顶六角，斜平面（`gridBasis`）是任意平行四边形——
> 这三类都按「格号 → 多边形/中心」换算，口径与编辑器 `src/canvas/grid_space.gd` 完全一致
> （`to_px`/`to_grid`/`cell_polygon`/`cell_center_px`）。游戏侧要么直接复用该脚本，
> 要么按 §3.1 的三个 meta 键实现同一套公式，否则编辑器与运行时不会选中同一格。
>
> **三角格（`gridTopology: "triangles"`）**：格号 `(i,row)` 的 `i` 是三角列，
> `c = floor(i/2)`、奇偶选半格；偶半格顶点 `(0,0),(1,0),(0,1)`，奇半格 `(1,1),(0,1),(1,0)`（单位基，
> 再按 `c,row` 平移后过 `to_px`）。瓦片数据仍是同一份六元组——编辑器用自绘层按三角形轮廓贴图集切片
> （切片按包围盒做 UV 映射），游戏侧同样要把一个图集切片贴进三角形；`TileMapLayer` 本身表达不了半格三角。
> 拾取按对角线 `x+y=1` 分半格，邻接是共边三条（见 `GridSpace.neighbors_tri`）。
> **`alt` 同样要消费**：编辑器三角自绘把第 6 位变换位施加在切片内部（`tri_tile_view.tri_uvs`，
> 与方形瓦片的 alternative 位同义）。自绘三角却不处理 `alt` 会让翻转/转置的瓦片在运行时丢变换。

**当前支持边界（照实写，不要按想象补）**：

| 维度 | 已支持 | 已知边界 |
|---|---|---|
| 投影（`gridProjection`） | 正交/等距/六边 + `gridBasis` 任意平行四边形；拾取、几何、对象锚点同一套 | `gridBasis` 下**瓦片仍由预设布局的 TileMapLayer 画**——编辑器画布自绘按基向量铺，运行时若用 `TileMapLayer` 自动布局会与格线偏离（自己设 `tile_layout` 或自绘） |
| 拓扑（`gridTopology`） | `quads` / `triangles`（半格拾取、共边邻接、自绘含 `alt`） | 三角层**没有逐瓦片 Y 交错**：整层一个绘制节点，`ySort` 只对实例生效 |
| 显式投影键 | 新建图按用户选择原值落盘；缺键 = 沿用项目解析 | 显式「正交」与「继承项目默认」在磁盘上都能表现为缺键——要区分必须写 `"orthogonal"` |

### 3.3 碰撞条目 `collision[]`

`collision[]` 条目是对象，缺省省略（写盘规则 `undo_history.extract`）：

```json
{"x": 21, "y": 24}                                # = solid + 矩形
{"x": 30, "y": 12, "type": "one_way"}             # 类型化的矩形
{"x": 33, "y": 4, "type": "hazard", "shape": "r45"}   # 类型化 + 斜坡
```

| 键 | 语义 | 缺省 |
|---|---|---|
| `x` / `y` | 格坐标 | 必填 |
| `type` | 碰撞类型 id；语义归游戏侧 | `"solid"` |
| `shape` | 形状：`""`（矩形）/ `r45` / `l45` | `""` |

**类型集由清单 `collisionTypes` 声明**（见 §2.8）。缺省池是内置四类（solid/one_way/ladder/hazard），
声明即整体覆盖；`gameplay` 是游戏侧自己的解释标签，编辑器只存取不解释。
编辑器画布按声明的 `shape`/`color` 画色块；游戏侧按 `type` 分发行为。

**形状**（只对 solid / one_way 有意义，其他类型按整格）：

| shape | 多边形（相对格左上，16×16） |
|---|---|
| `""` | 整格矩形 `(0,0)-(T,0)-(T,T)-(0,T)` |
| `r45` | 右高：`(0,T)-(T,0)-(T,T)` |
| `l45` | 左高：`(0,0)-(T,T)-(0,T)` |

**游戏侧必须按缺省值解释**（没有 `type` 键 = solid、没有 `shape` 键 = 矩形），不能要求显式键。
v5 的定长数组条目校验报错（跑 `tools/migrate_project.gd`）。

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
| `code` | 仅 entity | 图内唯一实例码（4 位身份码）。**唯一身份**：引用（props 里的 entity_ref 值）、复制重映射、画布连线全靠它。码在本图活跃实例内唯一、不随复制重编（见下方分配规则）。**场景实例写 `code` = 校验错误**（`scene` 键非法） |
| `layer` | 否 | 4 位**层码**（= `meta.layers[].id`），摆在哪一层。缺省 = 最底层 |
| `x` / `y` | 否 | **浮点格坐标**，不是像素。锚点换算见下 |
| `transform` | 否 | `{scale: [sx, sy], rotation: 弧度, flip_h: bool, flip_v: bool}`。**缺省整键省略**——读不到就等于 `scale 1/1、rotation 0、不翻转` |
| `props` | 否 | 对象。类型参数 + 自定义键。**编辑器原样保留非空值，不剥离未知键**。带 `sizeFields` 声明的资产（如事件）尺寸也写在这里（格数） |
| `functions` | 否 | 数组，见 2.5；缺省视为空数组，编辑器写出时**总是写这个键**（含 `[]`） |
| `visible` | 否 | 布尔，**编辑器专用显示开关**。缺省 `true`（缺省省略）。游戏侧应忽略 |
| `zPolicy` | 否 | `"auto"`（缺省）/ `"below"` / `"above"`——**同层内分组**，不是全局 z。缺省省略 |
| `sortAnchor` | 否 | `[dx, dy]` 像素，覆盖资产排序点偏移（悬空招牌、挂墙火把）。缺省省略 |

**x/y 与像素的换算**（TILE_W/TILE_H = 清单 `tileSize` 标量或 `[w,h]`；由资产的 `anchor` 决定，缺省 `center`）：

| `anchor` | 像素位置（节点锚点世界坐标） |
|------|---|
| `center`（缺省） | `((x + 0.5) * TILE_W, (y + 0.5) * TILE_H)` |
| `top_left` | `(x * TILE_W, y * TILE_H)` |
| `bottom_center` | `((x + 0.5) * TILE_W, (y + 1) * TILE_H)` |

锚点决定的是「数据坐标落在格的哪个位置」，**与贴图尺寸无关**：同一格的树不管画多高，
脚底都在该格底边。视觉矩形的左上角 = 锚点像素 − 锚点偏移（偏移由 `anchor` 和实例显示尺寸算出）。

**`props` 的保留策略是「只丢空值」**：`value == null` 或 `str(value) == ""` 的键在保存时消失，
其余（包括编辑器完全不认识的键、嵌套字典、数组）原样保留。
所以游戏侧可以往 `props` 里塞自己的数据，但要接受「空值会被清掉」。

**实例码分配规则**（`_ensure_code`，entity_factory.gd）：放置/粘贴时生成一个**本图活跃实例集内未占用**的
4 位码（撞码重摇，最多 64 次）；粘贴/复制产生的是新实例、发新码，已有实例的码不会被重编。
码空间 32⁴ ≈ 100 万，同图活跃实例远小于碰撞概率——但「不回收」是编辑流程约定，
**不是全工程历史扫描保证**（已删除实例的码理论上仍可能被新实例抽到）。

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

**工作目录不可配置**（明确约定，不是遗漏）：`OS.create_process` 不设 cwd，子进程继承编辑器自身的工作目录，
不保证是游戏工程根。游戏侧读相对路径必须靠显式参数（`--path`、`%projectpath%` 等，在清单 `playtest.args` 里写），
不要依赖 cwd。

### 6.3 实例化 `objects[]`

**四条呈现路径**（同一个 `objects[]` 条目，按资产声明分流）：

| 资产形态 | 怎么读 | 说明 |
|---|---|---|
| `kind: "scene"`, `shape: "image"` | `texture` + `editorSize`，无 `code` | 背景/装饰图片，游戏侧按自己的美术需求摆放或忽略 |
| `kind: "entity"` 有 `prefab` | `load(prefab).instantiate()` | 主路径；注入 metadata 见下 |
| `kind: "entity"` 只有 `visual` | 没有场景可载入 | 编辑器只按 `visual` 画占位；游戏侧自行渲染（或跳过） |
| 内置种类（如 `trigger_zone`） | 声明在清单里但 `builtin: true` | 游戏侧有自己的实现；尺寸走 `props.sizeFields`（§2.7） |

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

编辑器不附带示例游戏工程。
新工程从零接入时，按 §10 的检查清单逐条自己实现；下面是最小可用的读取骨架。
骨架覆盖：投影解析 → 图集 source 建表 → 按 `meta.layers` 栈序建层 → 瓦片六元组（含 `alt`）→
运行时层开关 → 碰撞对象（含类型/形状）→ 尺寸矩形。

**验证状态**：这段骨架的**正交**路径按编辑器实现逐行核对过；等距/六边/三角与带 `gridBasis`
的路径只给出公式，**没有**在真实工程里跑过（`grep` 得到的公式与 `grid_space.gd` 一致，但不等于
渲染结果一致）。跨投影接入请自己先跑一遍对照样例再标为可用——别把「抄了公式」当成「验证过」。

```gdscript
# 清单缺 tileSize 时的格尺寸（注意不是写死 16×16）
const TILE_W := 16
const TILE_H := 16

## 0) 投影解析（§3.1 三个 meta 键 + 清单项目的缺省）
##    缺 meta.gridProjection 时沿用「清单任一瓦片资产声明非正交即整项目按它」。
static func resolve_projection(data: Dictionary, manifest: Dictionary) -> String:
	var meta: Dictionary = data.get("meta", {})
	var gp := str(meta.get("gridProjection", ""))
	if gp == "isometric" or gp == "hexagonal" or gp == "orthogonal":
		return gp
	for a in manifest.get("assets", []):
		if not (a is Dictionary) or str(a.get("kind", "")) != "scene" or str(a.get("shape", "")) != "tile":
			continue
		var p := str(a.get("gridProjection", "orthogonal"))
		if p == "isometric" or p == "hexagonal":
			return p
	return "orthogonal"

## 1) 格号 ↔ 像素（与编辑器 grid_space.gd 同口径；非正交时游戏侧必须用同一套公式）
##    ortho: 左上角系；iso: 2:1 菱形顶点系；hex: odd-r 错行尖顶（只对整数格有中心语义）。
##    gridBasis 存在时为任意平行四边形，优先级高于投影预设。
static func cell_to_px_g(g: Vector2, proj: String, basis: Array) -> Vector2:
	if basis.size() == 2:
		var u: Array = basis[0]
		var v: Array = basis[1]
		return Vector2(float(u[0]), float(u[1])) * g.x + Vector2(float(v[0]), float(v[1])) * g.y
	var tw := float(TILE_W)
	var th := float(TILE_H)
	if proj == "hexagonal":
		var off := 0.5 if posmod(floori(g.y), 2) == 1 else 0.0
		return Vector2((g.x + off) * tw + tw * 0.5, g.y * th * 0.75 + th * 0.5)
	if proj == "isometric":
		return Vector2((g.x - g.y) * tw * 0.5, (g.x + g.y) * th * 0.5)
	return g * Vector2(tw, th)

## 对象数据坐标 x/y 是**格**坐标（浮点），锚点换算见 §3.4 的表——
## 直接 (x,y) * TILE 只对 top_left 成立；center 要 +0.5，bottom_center 要 +0.5/+1。
## 非正交投影下格中心不是「格号 + 0.5」：六边是格中心系，等距是菱形顶点系平移半格。
static func anchor_unit(anchor: String) -> Vector2:
	match anchor:
		"center":
			return Vector2(0.5, 0.5)
		"bottom_center":
			return Vector2(0.5, 1.0)
	return Vector2.ZERO       # top_left（含缺省）

static func object_px(x: float, y: float, anchor: String, proj: String, basis: Array) -> Vector2:
	var g := Vector2(x, y)
	if proj == "hexagonal":
		# 六边：to_px 已是格中心系且原生支持格内分数（行距 0.75），亚格位移**不能**按整格高算。
		# 锚点换算成相对格中心的像素偏移：anchor_unit - (0.5,0.5) 再乘格尺寸。
		return cell_to_px_g(g, proj, basis) + (anchor_unit(anchor) - Vector2(0.5, 0.5)) * Vector2(TILE_W, TILE_H)
	# 正交/等距：锚点换算成格单位再加，过 to_px（等距仍是菱形顶点系平移半格）
	return cell_to_px_g(g + anchor_unit(anchor), proj, basis)

## 2) 建层 + 瓦片（含 alt）；3) 碰撞对象
static func build(root: Node2D, data: Dictionary, manifest: Dictionary) -> Dictionary:
	var meta: Dictionary = data.get("meta", {})
	var mw := int(meta.get("w", 120))
	var mh := int(meta.get("h", 56))
	var proj := resolve_projection(data, manifest)
	var basis: Array = meta.get("gridBasis", []) if meta.get("gridBasis", null) is Array else []
	# 清单 assets[] 里 shape=tile 的条目 → {资产 id: source_id}；磁盘瓦片条目写的是资产 id
	var ts := TileSet.new()
	var tw = manifest.get("tileSize", [TILE_W, TILE_H])
	if tw is Array and (tw as Array).size() == 2:
		ts.tile_size = Vector2i(int((tw as Array)[0]), int((tw as Array)[1]))
	else:
		ts.tile_size = Vector2i(int(tw), int(tw))
	# 非正交投影必须设 tile_shape，否则 TileMapLayer 按方形布局画（编辑器 tileset_cache 同口径）：
	# 等距 = 菱形、六边 = 六角。正交保持缺省 TILE_SHAPE_SQUARE。
	if proj == "isometric":
		ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	elif proj == "hexagonal":
		ts.tile_shape = TileSet.TILE_SHAPE_HEXAGON
	# 注意：自定义 tile_layout 不是「跟着形状自动算」的。编辑器按自己画的格位置渲染，
	# 运行时若依赖 TileMapLayer 的自动布局，等距/六边的格原点可能与编辑器差半个切片——
	# 这种情况要么自己设 tile_layout（原点偏移 = 与编辑器 to_px 的差），要么按格自绘。
	var src_of := {}
	for a in manifest.get("assets", []):
		if not (a is Dictionary) or str(a.get("kind", "")) != "scene" or str(a.get("shape", "")) != "tile":
			continue
		var src := TileSetAtlasSource.new()
		# 清单里的 atlas 是**项目相对路径**（游戏工程里 = res:// 下的路径）；
		# 编辑器另存一份 atlas_abs（绝对路径，只给编辑器读写），游戏侧不要读它。
		src.texture = load("res://" + str(a.get("atlas", "")))
		# 资产切片尺寸：cell 是 {w,h} 或 [w,h]（§2.2，编辑器 asset_decl.cell_size 同口径）；
		# 标量 16 也接受；缺省 = 地图格尺寸。切片可非正方形、可大于地图格。
		var cell = a.get("cell", null)
		var csz := ts.tile_size
		if cell is Dictionary:
			var cw := int((cell as Dictionary).get("w", 0))
			var ch := int((cell as Dictionary).get("h", 0))
			if cw > 0 and ch > 0:
				csz = Vector2i(cw, ch)
		elif cell is Array and (cell as Array).size() >= 2:
			var aw := int((cell as Array)[0])
			var ah := int((cell as Array)[1])
			if aw > 0 and ah > 0:
				csz = Vector2i(aw, ah)
		elif cell is int or cell is float:
			csz = Vector2i(int(cell), int(cell))
		src.texture_region_size = csz
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
			if a.size() < 5:
				continue
			# 第 3 位是资产 id → 查 source_id；查不到 = 资产不在清单，跳过
			var sid: int = int(src_of.get(str(a[2]), -1))
			if sid < 0:
				continue
			var atlas := Vector2i(int(a[3]), int(a[4]))
			var src2 := ts.get_source(sid) as TileSetAtlasSource
			if not src2.has_tile(atlas):
				src2.create_tile(atlas)      # 按需注册：只建图里实际用到的格
			# 第 6 位 alt（编辑器口径 0-7）→ Godot alternative 位
			var alt := int(a[5]) if a.size() >= 6 else 0
			var galt := 0
			if alt & 1:
				galt |= 4096                 # h flip
			if alt & 2:
				galt |= 8192                 # v flip
			if alt & 4:
				galt |= 16384                # 转置 90°
			if galt != 0 and not src2.get_alternative_tiles(atlas).has(galt):
				src2.create_alternative_tile(atlas, galt)
			tn.set_cell(Vector2i(int(a[0]), int(a[1])), sid, atlas, galt)
	# 运行时层开关：meta.layers[].visible 先应用（差分视图/BOSS 换景，§2.3）
	for li2 in layers.size():
		var lm: Dictionary = layers[li2]
		var tn2: TileMapLayer = tile_nodes.get(str(lm.get("id", "")), null)
		if tn2 == null:
			continue
		tn2.visible = bool(lm.get("visible", true))
	# 碰撞：对象条目 {x, y, type?, shape?}，缺 type = solid、缺 shape = 矩形（§3.3）。
	# 编辑器不写定长数组；类型语义归游戏侧，这里只把类型/形状交出去。
	var coll := []
	for e in (data.get("collision", []) as Array):
		if not (e is Dictionary):
			continue
		var ce: Dictionary = e
		coll.append({
			"cell": Vector2i(int(ce.get("x", 0)), int(ce.get("y", 0))),
			"type": str(ce.get("type", "solid")),
			"shape": str(ce.get("shape", "")),
		})
	# collision / objects / spawn 见 §3.3 / §3.4 / 6.3
	var px := Vector2(mw * ts.tile_size.x, mh * ts.tile_size.y)   # 矩形格两个分量都要用
	return {"tiles": tile_nodes, "collision": coll, "projection": proj,
		"rect": Rect2(Vector2.ZERO, px)}
```

**不要照抄别人的工程**。上面这段覆盖分层瓦片渲染（含 `alt` 与运行时层开关）、投影解析与格↔像素换算、
碰撞对象读取；实体实例化、功能消费各自取决于目标游戏，§2.3、§3.3、§3.4 和 §6.3 给了字段语义，实现自由。

**这段骨架仍不负责的部分**（按需自己补）：

| 场景 | 需要做什么 |
|---|---|
| 三角格（`meta.gridTopology = "triangles"`） | `TileMapLayer` 表达不了半格三角；按 §3.2 的「三角格」说明自绘（顶点 + 图集切片按包围盒做 UV 映射）。格号 `(i,row)` 的 `i` 是三角列 |
| 等距/六边的对象锚点 | 等距沿用 `cell_to_px_g`（菱形顶点系，`center` = 格号+0.5 即菱形中心）；六边走 `object_px` 的六边分支（格中心系 + 连续亚格 + `(anchor_unit - 0.5) × 格尺寸` 的像素偏移），与编辑器 `entity_node.world_of_grid` 同口径 |
| 碰撞形状 `r45`/`l45` | 按 §3.3 的多边形表建 CollisionPolygon2D；矩形格用整格 |
| `props.sizeFields` 尺寸 | 带 `sizeFields` 声明的资产（事件区）宽高在 `props` 里，单位是格 |

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
## 清单允许 dict 与 array 两种写法（§2.5），两边都要处理——只写 dict 会在数组写法下静默空表。
func _build_code_tables(manifest: Dictionary) -> void:
	var fns = manifest.get("functions", {})
	var items: Array = []
	if fns is Dictionary:
		for fid in (fns as Dictionary):
			var d = (fns as Dictionary)[fid]
			if d is Dictionary:
				items.append([str(fid), d])
	elif fns is Array:
		for d in (fns as Array):
			if d is Dictionary:
				items.append([str((d as Dictionary).get("id", "")), d])
	for pair in items:
		var fid := str(pair[0])
		var d: Dictionary = pair[1]
		fn_by_code[str(d.get("code", ""))] = fid
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
	# 内容 fields 的键就是**字段执行码**：直接按码读（§7.6 手算对照）。先用缺键夹具
	# 校验默认值，再上真数据；不要经人类名映射表转一手——那查的是另一套键。
	var flag := str(f.get("F1A2", ""))
	var once := bool(f.get("B3C4", false))
	var spd := float(f.get("E5D6", 2.0))
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
  "kind": "entity",
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
| `id` | 全局唯一，且**用英文小写下划线**——它就是地图 `objects[].asset` 值，也是游戏侧查表的键 |
| `prefab` | 相对工程根的 `.tscn`。**根节点必须是 `Node2D` 系**，否则 `position` 注入无效 |
| `thumb` | 96×96 左右的 PNG 到 `editor/previews/`。没有它画布上是空白方块，但仍可放置 |
| `editorSize` | 像素。省略则编辑器读 prefab 第一个碰撞形状；再省略按 1 格（tileSize 尺寸）画 |
| `functions` | 只挂已在顶层 `functions` 声明过的功能 id；资产目录「自带功能」UI 可点选挂载，也可手写清单 |
| 缩略图烘焙 | 自己写一个截图脚本把 prefab 渲染成 PNG（需窗口，不能 headless）；编辑器只读 `thumb` 路径 |

### 8.3 不要做的事

- **不要手工编 `code`**。4 位实体身份码由编辑器补发并写回清单，手改会让既有内容 ID 前缀失配。
- **不要删除已被引用的实体资产**。清单校验不拦，但地图里会留 `asset` 指向不存在资产的实例，
  游戏侧静默跳过、编辑器只警告。删资产前先扫全项目地图（资产目录的「实例分布」就是干这个的）。

## 9. 新增图集

图集文件放进 `assets/tiles/`（扫描制，§1.1）即自动获得条目（id = 4 位资产码）；下面是手工追加 / 细配置的写法。

### 9.1 追加一条 `assets[]`

```json
{"id": "cave", "kind": "scene", "shape": "tile", "name": "洞穴件套",
 "atlas": "assets/tiles/cave_atlas.png", "palette": [...]}
```

**没有「只能追加末尾」的约束了**（v5 起瓦片条目写资产 id，不写下标）。
新条目插在数组任何位置都不影响既有地图。改完保存清单，游戏侧重启即可。

### 9.2 游戏侧要保证的

1. **按声明建源**：为每个声明的图集资产建一个 `TileSetAtlasSource`（`texture` = 清单 `atlas`，
   `texture_region_size` = 该资产 `cell`）。游戏侧按 `assets[]` 里的 `id` 建 `{id → source_id}` 映射，
   映射顺序与 source_id 编号由游戏侧自定。**没有固定图集名、没有必须占位的 `(4,0)` 格**——
   碰撞走 `collision[]` 数据（§3.3），不靠隐形瓦片。
2. **`TILE` 一致性**：运行时 `TileSet` 的 `tile_size` 必须等于清单 `tileSize`（标量 = 正方形，`[w,h]` = 矩形格）；
   每个 `TileSetAtlasSource.texture_region_size` 取该资产的 `cell`（可非正方形，缺省 = 清单 tileSize）。
3. **PNG 必须在 `res://` 下且已导入**。游戏侧加载用 `load("res://" + rel)`，
   路径含 `..` 直接跳过（安全，但静默——查不到图集时只 `push_warning`）。

### 9.3 palette 可省

`palette` 省略或空数组时，编辑器把整张图集按该资产 `cell` 切格全量平铺给用户选。
小图集建议不写 palette；大图集（>8 列）建议写 palette + `cat` 分组，否则左栏要翻很久。

## 10. 游戏工程接入检查清单

要让一个**现有** Godot 工程能被编辑器接管，第 1、3、6、8 条缺一不可；
其余按项目需要选（没有瓦片图集也能只用实体/内容；不想用试玩按钮就不配 `playCommand`）。

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
| 9 | 游戏侧按 `objects[].asset` 查资产并实例化，注入 `code`/`props` | 传送门等按 props 行为正确 |
| 10 | 若用功能系统：`functions` 已声明 + 游戏侧有对应消费代码 | 挂上功能后行为生效 |
| 11 | 若用结构化行：字段 `kind: "input", type: "array", of: "record"` + 非空 `fields` | 清单校验通过，内容表单出行容器 |
| 12 | 若用端口引用：先在该资产声明 `ports[]`，字段 `type: "port_ref"` | 内容表单端口下拉有候选 |
| 13 | 若用有限格图：地图 `meta.cellGraph` + 字段 `source: "cell:"` | 地图校验通过，下拉列出格 id |
| 14 | 若用视口参考：清单 `viewports[]` + 字段 `type: "viewport_ref"` | 下拉列出画幅，默认 `0,0` 归一化点 |

### 一次性验证命令

```
godot --path "<你的游戏工程>" -- --map=maps/<地图名>.json
```

能进游戏、地形与编辑画布一致、实体按 `props` 正确行为，就说明第 8、9 条通过。

## 11. 已知边界（照抄编辑器实现，不是待办）

- **`trigger_zone`（事件）没有专属属性表单**：它只有尺寸（画布把手可拖）和挂载功能，
  没有独立的「事件属性」面板——触发方式与条件都在功能声明与内容里。见 §2.7。
- **图层即遮挡层**。`meta.layers` 是纯 z 槽混合层栈，每层可摆瓦片+实体；碰撞是栈外元层。
- **一个实体实例一个功能只挂一条绑定**。同一功能重复绑定只有「添加功能」菜单会过滤（校验不去重；手改 JSON 可造成重复绑定）。
- **数值参数不走 props**。props 只剩几何/引用（§2.4.1）；值一律内容文件。
- **引用字段的编辑在内容编辑器「引用」区**（§2.4.2）：entity_ref/map_ref 值写实例 props。
- **条件只在声明链上**：条件由功能声明引用（§2.5.1），绑定上没有独立的条件门——
  改条件依赖 = 改游戏工程清单，不是编辑器内操作。
- **内容 ID 不可改**。改名只改 `name`；要换 ID 只能「复制成新 ID」，旧文件留在库里。
- **跨图引用写地图码（v7）**。`target_map` / map_ref 字段值 = 目标图 `meta.code`（4 位码，保存/迁移时补发），图改名不再破坏引用；游戏侧读各图 meta.code 建码→文件映射解析落点。老数据存图名的，跑一次 tools/migrate_project.gd 重映射。
- **地图 JSON 只有一个写入方**：编辑器 `extract()`。游戏侧回写会造成格式分叉。
- **撤销粒度是混合的**：瓦片/碰撞的涂刷与擦除存**笔画差量**（每手势一条，`kind: "delta"`），
  实例增删与全局操作（尺寸/层/粘贴等）存**整图快照**。两种条目同栈、undo/redo 同路径；
  只覆盖地图内存态，内容文件改动不进撤销栈。
- **能力扩展是「数据 + 下拉」而不是新编辑器**（C1–C5）：结构化行、端口引用、格图引用、视口参考
  都只做声明校验 + 候选 + 值读写；画布上的端口连线、格边描边、视口热点叠绘**没有**实现，
  也不生成运行时行为（归游戏侧）。
- **`cellGraph` 不进整数瓦片坐标**：它只提供 `cell_id` 字符串身份与多边形命中，
  不改变 `tiles` 六元组的 `(x,y)` 口径，也不改变碰撞格。

## 12. 相关文档

| 文档 | 内容 |
|---|---|
| [EDITOR_FEATURES.md](EDITOR_FEATURES.md) | 编辑器功能全貌、快捷键、已知边界索引 |
| [../README.md](../README.md) | 快速上手与目录结构 |