# 游戏侧数据协议参考

本文供实现具体读写协议时按需查阅。开始接入前先读[游戏侧开发规范](GAME_SIDE_STANDARD.md)。

- [项目清单、屏幕布局和游戏渲染](#manifest)
- [地图、投影、坐标和实例](#map-data)
- [内容文件与分层身份](#identity)
- [图组事件、启动入口和试玩回执](#entry-events-playtest)

## 1. 数据落点

```
<游戏工程>/
├── editor/editor_manifest.json      # 清单：图集 / 实体资产 / 功能与字段声明
├── editor/previews/*.png            # 实体缩略图（清单 thumb 指向这里）
├── maps/<地图名>.json               # **正式地图**（游戏侧唯一要读的地图来源）
├── content/<功能id>/<内容ID>.json   # 内容条目（根目录可被清单 contentDir 改）
├── editor/                          # 除清单与明确约定的交换文件外，游戏不读取编辑器私有数据
    ├── drafts/<地图码>.json          # 自动草稿（崩溃后恢复用）
    └── pending/pending-<时间戳>.json # 多文件提交日志（下次启动检查是否写全）
└── assets/                          # 资产发现目录（正式注册表是清单）
    ├── tiles/                       # 图片 → 瓦片图集资产（递归；png/jpg/jpeg/webp/bmp/tga）
    ├── images/                      # 图片 → 图片摆放资产（递归；同上扩展名）
    └── entities/                    # .tscn → 实体资产（递归）
```

旧版草稿曾写在 `maps/<地图名>.autosave.json`：**只有带 `_autosave_of` 键时**才是草稿，
游戏扫描 `maps/` 时应跳过。若要在编辑器打开旧草稿，请移到 `maps/` 外再导入为新地图。无标记的 `*.autosave.json` 仍按普通地图读。
`maps/` 下不应再出现新的编辑器私有文件（现行草稿在 `editor/drafts/`）。

本节只说明「游戏侧该读哪些目录」；**编辑器各入口一次会写哪些文件、按什么顺序写**见 [EDITOR_FEATURES.md](EDITOR_FEATURES.md) 的发布操作说明。

地图名规则（`manifest.gd::is_valid_map_name`）：必须是纯文件名，不含 `/ \ : * ? " < > |`、
不以 `.` 开头、不含 `..`、不以点或空格结尾、不是 Windows 保留设备名
（`CON/PRN/AUX/NUL`、`COM1`–`COM9`、`LPT1`–`LPT9`，带扩展名同样命中，如 `CON.json`）。游戏侧拼路径前照此校验。

## 1.1 资产发现约定

打开项目时，从 `assets/tiles/`、`assets/images/` 和 `assets/entities/` 自动发现未登记文件，
分别补图集、摆放图片和实体条目。子目录递归；图片支持 png、jpg、jpeg、webp、bmp、tga，实体支持 .tscn。
游戏和编辑器均以清单 `assets[]` 中的 ID 和路径为准。目录以外的资产可直接在清单声明。

新条目获得资产 ID，只有实体另有实体类型执行码。发现仅补新条目，不改已有 ID、路径或配置。
移动或改名时，请在重开项目前修改原条目的 `atlas`、`texture` 或 `prefab` 路径，保留原有
`id` 和实体 `code`。若先重开，新路径可能已获得新条目；未被使用时可在清单删除那条新记录，
再修改旧记录的路径。源文件缺失不删除旧条目，放回原路径即可继续使用。
仍可被发现的资产在编辑器中只能停用或重新启用，以免下次打开时重新发码。
新增条目随下次清单保存落盘。旧指纹和待确认字段不再参与资产解析。

<a name="manifest"></a>

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
| `triggers` | dict \| array | 时机池，见 2.5.4。可为图组事件声明 `eventTargets` |
| `collisionTypes` | dict \| array | 碰撞类型池，见 2.8：画布画什么形状/颜色 + 游戏侧解释标签 gameplay |
| `contentDir` | string | 内容根目录（相对工程根），缺省 `content`；不允许 `..` 或绝对路径 |
| `playtest` | object | 可选。试玩面板声明驱动：`flags: [{id, name, arg}]`（勾选后启动参数**原样追加** arg）、`params: [{id, name, arg(含 %d), def, min, max}]`（数字参数，值 ≠ def 才追加）。值只存编辑器本地 prefs，键 = `<项目根>|<地图码>`。未声明 = 面板空态提示 |
| `playtest.executable` | string | 可选。结构化启动：可执行文件路径，支持 `%projectpath%`/`%mapfile%`；配置后编辑器用 `OS.create_process()` **直接启动**，退出状态代表游戏本体 |
| `playtest.args` | string[] | 可选。参数字符串数组，逐项替换 `%mapfile%`、`%projectpath%`（**不加引号**，空格路径由数组分段保证）。Godot 项目示例：`['--path', '%projectpath%', '--', '--map=%mapfile%']`。未配置可执行文件则不启用试玩 |
| `playtest.entryFunctions` | string[] | 可选，须启用 `projectEntry: true`。填写允许作者从内容库启动的功能声明 ID；列表成员必须已声明且互不重复。 |
| `playtest.contentEntryMap` | bool | 可选，须启用 `projectEntry` 并声明 `entryFunctions`。允许为单项内容试玩选择已保存的配对地图。 |
| `playtest.viewEntry` | bool | 可选，须配置结构化启动。开启后，作者可以从参考视图启动该屏幕的已保存版本，不要求配置 `projectEntry`。 |
| `playtest.mapEntry` | bool | 可选，须配置结构化启动。开启后，作者可以从项目流程图按地图码试玩已保存的地图入口。 |
| `playtest.mapEntryPorts` | string[] | 可选，须开启 `mapEntry`。列出允许作为地图试玩入口的端口类型。 |
| `playtest.viewDraft` | bool | 可选，须配置结构化启动并开启 `report: true`。开启后，作者可以试玩当前屏幕的未保存布局。 |
| `preview` | object | 可选。声明独立进程渲染预览，可请求 `screenLayout`、`mapFrame`、`worldFrame` 和 `timelineFrame`。与试玩配置分开。 |
| `mapGenerators` | object | 可选。按生成器 ID 声明从游戏生成可编辑地图的参数。需同时声明 `preview.capabilities` 包含 `generateMap`。 |
| `mapOutputs` | object | 可选。为地图声明具名流程出口；游戏触发，作者接线。 |
| `mapContentSlots` | object | 可选。为地图声明具名内容槽，可绑定内容库中已保存的规则或配置。 |
| `eventLayers` | object | 作者保存的图组事件层，以稳定层 ID 为键。见下文。 |
| `projectContentSlots` | object | 旧项目的具名内容绑定；新共享事件使用 `eventLayers`。 |
| `viewports` | array | 可选。具名参考画幅 `[{id, w, h}]`：宽屏/竖屏/分屏的坐标域身份，id 非空唯一、w/h 必填正数；`viewport_ref` 字段的下拉候选来自这里 |
| `screenModules` | object | 可选。按模块 ID 提供作者可加入布局的成品控件，以及编辑器可配置的字段声明。游戏负责创建控件及执行行为。 |
| `views` | array | 可选。参考视图 `[{view_id, image, pixel_size, hotspots}]`：`view_id` 必填，`image`/`pixel_size`/`hotspots` 可省；hotspot = `{rect: [nx,ny,nw,nh] 全 0..1, target: 对象}`。编辑器可编辑参考图、绘制热点和选择内容目标；游戏定义点击行为 |

清单校验把 `assets` 非 Array、`tileSize` 非正数、资产 id 空或重复、
**实体资产码重复**、图集/图片路径含 `..` 或为空、palette 元素缺 `cell`、功能/步骤/音频**条目码池内重复**、
**字段码跨池/跨功能同码**（三池共用一个码空间，同码 = 静默别名，报错）、步骤**码重复**、音频**码重复**、
时机**id/码池内重复**、字段缺 `kind` 或 kind/type 非法、挂载引用未声明的功能、功能引用未声明的条件、
功能引用未声明的时机、`playtest` 结构错（flags 缺 `arg` / params 的 `arg` 缺 `%d` / id 重复 / name 空 /
`executable` 非字符串 / `args` 非字符串数组）、
顶层可选键形态错（`contentDir` 非字符串、`contentDir` 含 `..` 或绝对路径、`screenSize` 非 `[w,h]` 数值），
以及 `assets[]` 里 `kind` 非法、scene 同时给 `atlas` 与 `texture`、entity 既无 `prefab` 也无 `visual`，
判为**错误**（编辑器拒绝加载）。
功能 id 与条件 id 重复都是错误
（数组写法不查会静默后者覆盖前者）。
内容工作台绘制的热点按图片实际显示区域（不含等比放置留白）归一化。选择内容目标时写入
`"target": {"function": "<功能 id>", "content": "<内容 ID>"}`，可直接按内容库路径解析。
`image` 使用项目相对路径；`pixel_size` 和已有的自定义目标数据保持兼容。
游戏可定义其他目标形态，这类目标可随热点保留，但选择器不会解释其含义。

参考视图可附加 `layout: {viewport, elements}`。设计画幅用 `viewports[].id`，省略时使用
1280 × 720；运行时可套用实际画幅。元素按数组顺序从底到顶，`id` 在单个布局内稳定且唯一。
每项有 `kind`（`panel`、`text`、`button` 或 `module`）、`anchors: [左, 上, 右, 下]`（0..1）、
可选 `offsets: [左, 上, 右, 下]`（像素，默认全零），以及可选 `text`、`style` 和 `target`。
可选 `parent` 指向同一布局中的另一个元素 ID。没有此键时使用画幅，旧布局无需迁移。
每个边的位置为「参照矩形起点 + 锚点 × 参照矩形尺寸 + 像素偏移」；参照矩形是父元素已经解析的矩形，或从原点开始的实际画幅。
例如上下锚点都为 1 时，两条边固定在父级底边的像素偏移处。父级可在子元素之后出现；校验拒绝未知父级、自引用、循环，以及在设计画幅下不具备正宽高的元素。
先按 ID 解析矩形，再按原数组顺序绘制和命中。父级不裁切子元素、不改变叠放关系，也不传递焦点或内容目标。
`hidden: true` 隐藏元素及其后代，它们不参与绘制、命中或焦点导航。
元素可选 `variants`，按 `viewports[].id` 保存稀疏覆盖，例如 `{"wide":{"offsets":[0,-40,0,-40]},"handheld":{"hidden":true}}`。
每项只允许覆盖 `anchors`、`offsets`、`hidden`，缺键沿用该元素的基础值。先选定同一个画幅 ID，再逐元素读取覆盖并解析父级矩形。
游戏在正式运行时按自己的视窗或模式选择声明的画幅 ID，坐标公式仍使用当前实际尺寸；没有选 ID 时使用基础布局。同尺寸的两个画幅可以使用不同布局，协议不会用尺寸代替 ID。
叠放、父级、模块属性、内容连线和本地化数据在画幅间共用。保存校验检查基础设计尺寸和所有写入覆盖的画幅尺寸。
`style` 是游戏侧样式 ID；编辑器给出布局示意，实际控件、字体、交互与样式由游戏实现。
内容目标沿用热点的 `{function, content}`，用于编辑目标和检查删除引用。
功能、条件或步骤字段可用 `kind: "choice", source: "view:"` 选择已保存的参考视图，字段值为 `views[].view_id`。
例如会话内容可选择要显示的屏幕，屏幕按钮再指向另一条内容。游戏按字段码读视图 ID 并显示该视图，流程图列出它读取到的失效目标。作者可在同一张流程图编辑两种连线；文件格式与在各自表单中编辑相同。

元素可选 `imageAsset`，存 `assets[].id`，目标必须是 `kind: "scene", shape: "image"` 的原图资产。
游戏按资产声明中的项目相对 `texture` 路径取图；图片绘在元素边界内、文字下方。
`imageFit` 默认为 `contain`（等比居中完整显示），也可选 `cover`（等比居中并裁切到元素边界）或
`stretch`（拉伸填满元素）。画幅裁边不应改变用于缩放的元素边界。游戏的样式实现仍可决定如何组合这些数据。

布局可声明 `locales: ["fr", "fr-ca"]`；元素在 `textLocales` 中按声明的语言标记保存译文，
原文仍用 `text`。语言标记保存为小写连字符形式，例如 `zh-hans`；解析时先匹配完整标记，
再依次移除最后一个子段，仍无译文则使用原文。译文留空表示移除该条。元素可设置
`fontSize`（8–256 的整数，默认为 24 像素），原文及译文支持显式换行。
预览用编辑器字体检查文字是否超出元素尺寸；游戏字体、样式和自动换行由游戏侧决定。

**可选：游戏渲染快照。** 例如 Godot 工程可配：

```json
{"preview":{"version":1,"executable":"<引擎绝对路径>","args":["--path","%projectpath%","--"],"capabilities":["screenLayout"]}}
```

只有作者点击「游戏渲染预览」才启动程序。编辑器直接传递参数数组，替换
`%projectpath%`，并追加 `--editor-preview=<request.json 的绝对路径>`。不经 shell。
游戏从请求文件读取 UTF-8 JSON：

| 请求字段 | 含义 |
|---|---|
| `version`、`token` | 协议版本（1）及本次请求标识，原样写入回执 |
| `capability` | `screenLayout`（屏幕布局）、`mapFrame`（关卡画面）、`worldFrame`（世界画面）或 `timelineFrame`（演出取样），由游戏在 `preview.capabilities` 中按需声明 |
| `projectPath` | 游戏工程根的绝对路径，可据此读取游戏自己的资产和声明 |
| `viewport`、`locale` | `{w,h}` 为要输出的像素尺寸；语言为空表示原文 |
| `subject` | 所请求能力的快照，见下文 |

对 `screenLayout`，`subject` 是当前参考视图的完整快照，包含未保存的布局、热点和参考图路径。
`viewport.id` 指定本次使用的布局画幅 ID；空串或缺省表示基础布局。它与 `w`、`h` 独立。
请用请求中的视图以及游戏的控件、字体和样式完成渲染。

游戏可通过 `screenModules` 声明自定义控件，例如：

```json
{"screenModules":{"confirm-latch":{"name":"多次确认","outputs":{"accepted":"确认","cancelled":"取消"},"fields":[{"id":"presses","kind":"input","type":"int","min":1,"default":3}]}}}
```

作者在布局中选择模块后，元素写为 `kind: "module"`、`module: "confirm-latch"`，
沿用 `id`、`anchors`、`offsets`、文字及样式。`props` 以声明字段 ID 为键，只保存作者的覆盖值；
游戏应在缺键时应用模块缺省值。若需要键盘或手柄焦点，作者可启用 `focusable: true`（模块默认关闭）。
引用参数沿用通用字段协议。例如 `source: "content:dialogue"` 存内容 ID，`source: "view:"` 存视图 ID，
`type: "asset_ref"` 存资产 ID。编辑器也检查多选、记录和条件行中实际生效的声明缺省值；
显式清空会覆盖缺省值，普通字符串不会被解释为引用。模块的内容参数是依赖，具名出口才是流程连线。
模块没有所属地图。要配置实例、图层、有限格、端口或规则格边，在同一组字段或同一记录行里声明单选地图字段
（`source: "map"`），并在目标字段填 `mapField` 指向它的 ID。候选来自已保存的地图。
实例、图层和有限格存目标 ID；`port_ref` 与 `edge_ref` 的对象若有非空 `map`，以该地图为准。
独立内容、项目演出步骤和屏幕模块中的这两种对象引用，没有声明配对地图时，可在同一字段先选已保存的地图，再选端口或格边。地图码写进引用对象，无需为此增加另一个数据字段。有内容地图上下文时，可在所属图（保存空地图码，运行时继承）和其他图（保存显式地图码）之间选择。
实例上的无配对对象引用也可直接指定其他已保存地图；当前图候选从工作副本取得。
端口数组用 `of: "port_ref"`，可用 `portTypes` 指定逗号分隔的端口类型。实例、内容、步骤和屏幕模块的表单可逐行选择、重排端口；运行时按数组顺序读取，空行 `{}` 表示未连接。规则格边数组用 `of: "edge_ref"`，沿用单个格边的对象格式。
声明 `mapFrame` 且游戏返回对应选点映射时，模块和嵌套记录也可从目标图实景选取实例、端口、有限格或规则格边；
声明 `pickSpace` 的坐标字段可用映射取点。实景读取目标图的已保存版本，确认只修改当前屏幕布局草稿。
声明的 `outputs` 按出口 ID 取值。字符串表示显示名，沿用项目级直连开关；也可写成
`{"accepted":{"name":"进入关卡","maps":true},"cancelled":{"name":"取消","screens":true,"contentTypes":["ending"]}}`。
对象声明按出口限制地图、屏幕和项目级内容类型，独立于项目级直连开关。布局表单和项目流程图使用相同候选规则。
布局元素的 `outputs` 仍以相同 ID 保存标准目标对象，游戏按触发的出口读取。
对于按钮、热点和以字符串命名的出口，
游戏可在清单设 `"directViewTargets": true`，允许保存 `{"view":"screen-id"}`。游戏按 ID 切屏；
原有内容目标仍由内容分发器执行。
游戏也可独立启用 `"directMapTargets": true`，允许同一组入口保存 `{"map":"地图码"}`。
目标使用已保存且唯一的稳定地图码，不使用文件名；游戏收到目标后按码加载实际地图并执行自身的入场逻辑。

地图本身的出口用 `mapOutputs` 声明。例如
`{"mapOutputs":{"completed":{"name":"通关","maps":true,"screens":true,"contentTypes":["ending"]}}}`。
每个 ID 的目标域沿用 `flow_target` 的规则。作者在「设置 → 地图内容与出口」为各张地图接线；
保存后由游戏从 `meta.flowOutputs.completed` 读取标准目标对象。映射中没有该 ID 表示未接线。
例如游戏在完成一局比赛或达成清场条件时读取出口并跳转；不要求地图里存在触发器实例。

地图也可绑定游戏用于入场、比赛、胜负判定或环境的共用内容。例如
`{"mapContentSlots":{"round":{"name":"回合规则","contentTypes":["round_rules"]}}}`。
作者在项目内容库编写 `round_rules` 条目，再在「地图内容与出口」为地图选择一个已保存的条目。
地图保存引用 `meta.contentSlots.round = {"function":"round_rules","content":"project-ranked"}`；
编辑器不复制内容字段，游戏按项目内容契约读回字段（保存键为执行码），按自己的规则使用。
未设置的槽不写入地图；改变共用内容会影响所有仍引用该条目的地图。
若内容读取地图内的实例、端口或格，可在内容槽或允许内容目标的地图出口上声明
`"contentMapContext":"inherit"`。游戏把绑定所在的地图传给内容，按该地图解析本图引用。
作者可用「应用并编辑内容…」打开内容表单，并自动选中绑定所在的地图作为引用上下文。
缺省或 `"independent"` 不传地图；共享内容若使用本图引用，该引用需在每张绑定地图中成立。
整图复制时，如果这类槽、出口或实例绑定引出的内容需要改写本图引用，编辑器会为副本另存该内容，
并沿声明为继承地图或配对到源图的内容链接，另存到达该内容所需的上游条目。无须改写的内容仍共享；
指向其他地图的上下文链接不会被当作本图链路。
整图复制时，地图出口、实例、以及随图上下文可达的内容和步骤中的 `{"map":"源地图码"}`
会改指副本；其他地图和屏幕目标保持原样。这条规则不用于局部复制。
如需从关卡回到屏幕，可在资产实例声明 `{"id":"exit_view","kind":"choice","source":"view:"}`。
作者为每个实例选择目标；游戏在自身的通关或交互逻辑中读取 `props.exit_view` 并按该 ID 切屏。
同一个出口需要兼容不同类型时，可声明 `{"id":"exit_target","kind":"input","type":"flow_target","maps":true,"screens":true,"contentTypes":["story"]}`。
在实例、内容、步骤、屏幕模块或记录子字段中，作者从已发布的候选里选择一个目标；游戏读取 `{"map":"地图码"}`、
`{"view":"屏幕ID"}` 或 `{"function":"功能ID","content":"内容ID"}`。`{}` 表示未连接。
三种候选域由该字段自己声明，与正式启动入口和布局直连开关无关。只有项目级内容可作为目标；实际跳转与状态传递由游戏实现。
如需指定进入地图的位置，在目标声明中加 `"arrivalPorts":["entrance"]`，并为地图中的资产声明同类型端口。
作者可选择已保存地图中匹配类型的实例端口，存储为 `{"map":"地图码","inst":"实例码","port":"端口ID"}`。
编辑当前地图的地图出口或实例属性时，本图的端口候选取自工作副本，因此新摆放或重生成的端口可以与引用一同保存。
声明允许整图目标时，尚未首次保存的本图也可作为这些字段的目标；使用工作副本已分配的地图码。正式启动入口仍从已保存的资源中选择。
此声明适用于 `flow_target`、地图出口、对象形式的屏幕模块具名出口和正式启动入口。

屏幕模块的具名出口若需要把地图传给内容，可在出口声明中加入
`"contentMapContext":"paired","mapField":"board"`，并在模块 `fields` 中声明单选地图字段
`{"id":"board","kind":"choice","source":"map"}`。该出口须允许 `contentTypes`。
作者在布局中选择地图和内容；出口仍存 `{function, content}`，游戏从同一模块的 `props.board`
读取地图（未写入时采用字段默认值），作为运行上下文传给目标内容。这项设置只作用于内容目标。
编辑器检查配对地图是否可读，并沿该内容入口检查本图引用。

若同一屏幕要服务多张地图，可保留调用方的地图上下文：在允许屏幕目标的地图出口、
实例、内容或演出步骤的 `flow_target`，或者屏幕模块的具名出口上声明 `"viewMapContext":"inherit"`。
游戏向目标屏幕传入当前地图；没有当前地图时不推断。屏幕模块的具名出口可用
`"contentMapContext":"inherit"` 将同一上下文传给内容，或在连向下一屏时继续使用
`viewMapContext`。目标的保存格式不变。游戏沿声明的接线传递地图码，并在该地图内解析目标。
`maps: true` 独立控制是否允许不指定端口的地图目标。游戏按地图码加载地图，再按实例和端口决定入场点及行为。
整图复制时，指向本图被复制实例的入场目标随地图和实例一起更新。
局部复制或粘贴时，只有同批复制的入场实例随副本更新；组外端口、仅指定地图的目标和第三张地图上的端口保留原目标。
项目流程图可改接独立内容及其步骤中的 `flow_target`。断开时写入 `{}`，因此即使字段声明了默认目标，也可明确覆盖为未连接。
将字段声明为 `"type":"array","of":"flow_target"` 可保存有序目标列表，目标域仍在字段上声明。列表可混用地图、屏幕、项目内容和入场端口，也允许同一目标出现多次。表单可增删和移动行；流程图可逐项改接、追加或移除。游戏读取数组并决定何时、按何种规则走向相应目标；空对象表示尚未接线。
保存地图后，实例上的 `flow_target` 会作为该地图的出边显示在项目流程图中，可从关系跳回实例字段修改。

实例、内容或步骤中的 `flow_target` 可用 `contentMapContext: "inherit"` 声明由游戏把当前地图传给下一段内容。
从实例出口进入时，当前地图为实例所在图；整图复制时会另存需要改写的内容。
内容或步骤也可用 `contentMapContext: "paired"` 和 `mapField` 指定同一行的地图选择字段。此设置只在出口选择内容时适用；
地图目标本身决定要加载哪张地图，屏幕目标按布局流程执行。目标的数据格式不变，游戏按声明传递地图上下文，
编辑器用同一规则检查下一段内容中的本图引用。
三个目标形式互斥，两个开关都可省略。布局和项目关系图提供候选并报告失效目标；删除屏幕前会列出其来向。
未连接的出口不写键。游戏触发某个出口时读取同名目标，例如确认次数达标用 `accepted`、玩家取消用 `cancelled`。
旧的单目标 `target: {function, content}` 继续可用，已有绑定不会自动转为某个具名出口。
若游戏移除了出口声明，已保存的目标仍可在编辑器中找到并断开；游戏只需处理仍实现的出口。
正式试玩和 `screenLayout` 预览应按同一个模块 ID 构造控件；编辑器不加载模块代码。

对 `mapFrame`，`subject` 结构如下：

| 字段 | 含义 |
|---|---|
| `map` | 当前地图的工作副本，结构和正式地图一致；可包含从未落盘的修改 |
| `manifest` | 当前清单的公开载荷，用于解释这份地图；不含编辑器内部字段 |
| `stagedContent` | 当前地图暂存内容行 `[{function, content, data}]`。按 (功能 ID, 内容 ID) 命中时优先使用 `data`，其余内容仍从项目读取 |
| `camera` | `{center:[x,y],zoom}`：中心在地图根空间像素坐标中；缩放为每个世界像素对应多少输出像素。直接映射时 `output = (world - center) * zoom + viewport / 2`；自定义投影和镜头可将它解释为取景提示 |
| `viewportId` | 选中的清单画幅 ID；空串表示当前编辑器画布大小 |

渲染地图时从快照加载当前地图和清单；跨图、其他已保存内容和素材可以继续走游戏自己的读取路径。
作者可以在 `mapFrame` 窗口调整 `camera.center` 和 `camera.zoom`。跨图默认使用目标图范围，本图默认使用编辑画布相机。`picks.json` 必须对应本次取景后的实际画面；自由镜头仍可按自身投影解释这些参数。

对 `worldFrame`，`subject.manifest.worldLayout` 是布局窗口的完整草稿。相机 `subject.camera`
沿用同一结构，但中心与缩放作用于**项目世界坐标**。空的 `viewportId` 表示取世界布局画布尺寸。
`subject.overrides` 是以地图码为键的 `{map, stagedContent}` 对象：若当前地图已加入布局，
它的工作副本和暂存内容随请求传入。命中时优先使用工作副本；其他分块由游戏按地图码读取正式数据。
游戏可按画幅和取景选取分块，并根据自己的坐标映射、重叠和裁剪策略渲染。

对 `timelineFrame`，`subject` 含 `function`（功能声明 ID）、`content`（内容 ID，未建绑定内容时为空）、
`data`（当前内容快照，包括步骤、字段及暂存版本）、`manifest`（公开清单）和 `viewportId`（空串为默认 1280 × 720）。
`time: {unit, value, seconds}` 给出选定的原单位位置（默认取自播放头，也可在预览窗口直接输入）；
`unit` 是 `seconds`、`frames` 或 `beats`，
有可用时钟时 `seconds` 为编辑器换算的参考秒数，含首拍偏移；缺配置时为 `null`。
游戏按 `data` 与原始位置取样，决定该时刻的镜头、物体、特效等。实例绑定的演出还附 `map`、`camera`、
`stagedContent`、`instance`（实例码）、`bindingId`（可为空）与 `bindingIndex`（绑定行下标）。
同一实例可重复绑定同一功能。用实例码定位对象，再在请求的地图快照中按 `bindingId` 或
`bindingIndex` 定位实际绑定；不要用功能码匹配第一条同类绑定。
已应用的步骤按内容自身的保存规则可来自磁盘或暂存；预览不会主动应用正在输入的字段或发布暂存内容。

这些能力使用同一种输出协议：
在请求同目录写 `frame.png`（像素尺寸严格等于画幅），再写 `result.json`：
`{"version":1,"token":"<原 token>","status":"ready"}`。游戏随后退出。失败时可只写回执，
使用 `"status":"error"` 与 `"message"`。渲染帮助程序应避免弹出抢占焦点的窗口，并且不写正式游戏数据。
编辑器按进程退出、版本、标识与 PNG 尺寸检查结果后显示并清理临时文件；最多等待 12 秒，
请求上限 4 MiB、画幅单边不超过 4096 且总像素不超过 8388608。连续游玩仍用项目试玩。

`mapFrame` 可在同目录额外写 `picks.json`（最多 1 MiB）。只省略该文件即可继续提供只读预览。
游戏负责根据实际渲染结果提供命中区域；编辑器不从图片猜相机矩阵、遮挡或深度。例：

```json
{
  "version": 1,
  "token": "<原 token>",
  "regions": [
    {
      "label": "右视区 · 上层门",
      "screen": [[400, 64], [520, 68], [390, 150]],
      "placement": {"layer": "FL02", "local": [[16, 32], [48, 32], [16, 64]]},
      "collision": {"local": [[32, 48], [64, 48], [32, 80]]},
      "targets": {
        "entity": "DR01",
        "port": {"map": "MAP1", "inst": "DR01", "port": "open"},
        "cell": "upper:1,4",
        "edge": {"map": "MAP1", "cell": [1, 4], "edge": "1,4|2,4"}
      }
    }
  ]
}
```

- `screen` 是画面像素三角形，左上原点，顶点应在画幅边界内。遮挡优先级按数组从前到后；选择当前工具所需类型的首个命中。若命中标为 occludes: true 的区域，而该区未提供当前工具所需的目标，则停止查找，不能透过它选择后方。四边形、多边形和非线性表面可拆成多个三角形，像素相同的三角形可分别提供放置和引用。每块视区可以指向不同图层。
- `placement` 可省略。使用当前地图中实际存在的层 ID。根据三角形内的点击位置在三个对应的**图层局部像素锚点**间插值；无需预加图层偏移或缩放。编辑器精确放置当前已选资产，沿用正常的实例码、功能挂载与撤销规则。透视面可在 placement 附 reciprocalW（按顶点顺序的三个正数，即 1 / clip.w）；编辑器将屏幕重心权重逐项乘以它，再归一化后插值。省略时使用普通仿射插值。
- `targets` 可省略或只提供部分键。实例码、有限格图格 ID、端口和格边值用正常引用格式；端口和格边的 `map` 用当前地图码。字段仅接受原候选也允许的值，因此游戏端不能用回执绕过配对地图或类型筛选。
- `collision` 可省略。它使用地图根空间像素，不用传 `layer`；`local` 和可选的 `reciprocalW` 与 `placement` 使用相同的插值规则。「实景设置出生点」和地图坐标字段使用此映射并遵守遮挡顺序。可以只提供此映射；未提供时不会退回瓦片层坐标。出生点仍保存为地图的 `spawn: [x,y]` 根格坐标。回执版本仍是 1，原有拾取回执可继续使用。
- 单值引用字段声明 `mapField` 并指向另一张地图时，也用该图的已保存 `mapFrame` 拾取。嵌套记录与条件参数的配对地图按所在行读取。游戏应按请求中的地图输出实例、端口、格或格边；编辑器仍使用字段的候选集判断类型、空间和目标身份，不改配对地图。
- `entity_inst:` 和 `cell:` 的 `multiple: true` 选项可在同一实景逐项切换，仍使用同样的 `targets.entity` 或 `targets.cell` 格式；编辑器一次提交字符串数组。
- 有序路线用 `kind: "input", type: "array", of: "choice"`，并指定 `source: "entity_inst:…"` 或 `source: "cell:…"`；可用同一行的 `mapField` 指定整条路线的地图。实景按点击顺序追加目标，存储保留重复项，游戏按数组次序消费。
- 同样可用 `source: "content:<功能ID>"` 或 `source: "view:"` 声明有序内容或屏幕列表。表单可添加、复制、删除和调序；项目流程图可对内容里的此类字段逐项改接或追加，包括重复目标。游戏按保存的数组顺序消费，空串表示该行未连接。普通的 `choice` 加 `multiple: true` 仍是多选集合。
- 实例参数、功能、条件和步骤可给二维 `vector2` 或 `array`（`of: "vector2"`）声明 `pickSpace: "map"`。编辑器使用 `collision.local` 的根空间映射，写入 `[x,y]` 或点数组，单位为地图根空间像素；不要求该位置存在碰撞格、实例或实体目标。支持同一行的 `mapField` 或独立内容的临时地图。声明的 `min`、`max` 仍限制坐标。
- 同样的字段可声明 `pickSpace: "layer"` 与 `layerField: "path_layer"`，其中 `path_layer` 是同一行内单选 `kind: "choice", source: "layer:"` 字段的 ID。两个字段用相同的 `mapField`（如需跨图），也可都省略以使用当前图或临时地图。作者先选层再拾取；编辑器只匹配该层的 `placement`，遇到前方遮挡则停止。值仍为 `[x,y]` 或点数组，单位为图层局部像素；图层 ID 单独保存在图层字段，游戏按该层变换解释。
- 拾取只用与本帧 token 对应的数据。点击仅选中，明确确认才编辑；对于多边形和路径资产，可在同一帧累积同一图层的多个顶点再创建形状。改画幅或工作副本后须重渲染。已保存的地图和内容仍使用原契约，无需保存三角形。

### 从游戏生成可编辑地图

`mapGenerators` 使用稳定 ID，`fields` 按数组顺序显示，可为空。支持 `kind: "input"` 的
`int`、`float`、`bool`、`string`、`asset_ref`、`vector2` 及其数组，也支持单选、多选、`curve` 和 `array` / `of: "record"`。
坐标按声明的二维或三维数值数组传递；路径可用有序坐标数组。曲线沿用内容字段的关键帧格式，生成器自行决定其单位和用途。
选项可直接声明 `options`，或引用项目资产、实体类型、内容、地图、屏幕或音频；生成参数不依赖当前地图上的实例。
记录列表按作者顺序传递，子字段使用 ID；未显式填写的记录子字段可由生成器按声明采用默认值。
每个字段可指定 `name`、`default`，数值可设 `min`、`max`。例如：

```json
{"mapGenerators":{"room":{"name":"生成房间","fields":[
  {"id":"seed","name":"种子","kind":"input","type":"int","min":0,"max":999999,"default":0}
]}}}
```

需要把配置同时用于编辑器和正式游戏时，可用 `{"mapGenerators":{"room":{"contentType":"room_rules"}}}`。
`contentType` 指向 `functions` 中的功能 ID，代替内联 `fields`。可用 `"parameterFields":["seed","placements"]`
按 ID 指定参加生成的字段及顺序；省略则使用该功能的全部字段。只有参加生成的字段须符合上述参数契约。
项目内容仍可保存流程出口、时间轴等其他数据，由正式游戏读取；这些字段不进入生成表单、请求或参数快照。
作者在项目内容库保存该类型的内容后，生成窗口可选用。编辑器按功能字段声明将内容的存储键转换为
参数 ID（记录子字段有执行码时也转换，无执行码时沿用 ID）。缺省顶层字段使用声明默认值，
未存储的记录子字段由游戏生成器处理。正式游戏按原内容契约读取同一文件并自行调用算法。
在生成窗口加载后修改参数只影响本次生成；重生成默认使用地图记录的上次参数快照，也可重新选用已保存配置。

编辑器沿用独立进程请求传输，`capability` 为 `generateMap`、`viewport` 为 `{w:0,h:0}`。
`subject` 为 `{generator, parameters, manifest, target}`，参数以字段 ID 取键，
`manifest` 是公开清单，`target` 提供 `{name,code,version}`。生成程序按当前地图格式写
UTF-8 `map.json`（最多 4 MiB），再按通用协议写 `result.json`；此能力不需要 PNG。
地图必须提供正常图层等地图结构。地图码可省略，编辑器会填入 `target.code`；若生成数据包含指向
自身地图的引用，请直接使用该码。实例资产、功能、内容引用遵循普通地图契约，生成操作不会创建独立内容文件。
游戏进程只向请求目录输出。编辑器校验后可把它打开为普通未保存地图；后续编辑和落盘由作者控制。

重新生成到新地图使用同一个请求，并分配新的目标地图码。
编辑器在 `meta.generatorSource` 保存生成器 ID、参数和原始快照，供下次生成和世界分块差量使用。
重新生成不会修改原地图。

布局可选 `focusStart`（初始按钮 ID）。按钮默认可聚焦，可用 `focusable: false` 排除；
按钮的可选 `focus` 对象以 `up/down/left/right` 为键，值为同一布局内可聚焦按钮的 ID。
编辑器焦点试玩优先使用显式方向；目标在当前画幅完全裁出或未配置时，自动在该方向寻找可见按钮，
按前向距离加两倍横向距离排序，同分保持数组顺序。Tab 按元素顺序在可见按钮间循环；
若指定初始按钮不可见，从首个可见按钮开始。游戏侧绑定对应的输入动作和确认行为。

相关声明校验：`viewports` 的 id 非空唯一、w/h 正数；`views` 的 view_id 非空唯一，`image`、`pixel_size`、`hotspots` 均可省略，但一旦给出必须形态正确（image 字符串、pixel_size 正数、hotspots 数组）；hotspot `rect` 必须是四个 0..1 数、`target` 一旦给出必须是对象；`assets[].ports` 的 id 非空唯一、x/y 数字；
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
| `shape` | 否（缺省 `tile`） | `"tile"`（图集批量）或 `"image"`（单张图片实例） |
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
- 编辑器里新建层默认插到栈顶之下；删层会删除该层的瓦片与实体，可撤销。引用保留原值。
- `source: "layer:"` 的图层 ID 由当前图或 `mapField` 指定的地图解释。局部跨图复制保留源图的坐标空间，需要配对地图字段；整图副本继承图层 ID 和变换，源图的配对引用改用副本图码。已有的第三方地图引用保留原样。
- **碰撞不在层栈里**：碰撞与 z 序无关（游戏内不可见），是独立的元数据网格（见 3.3）。
- 图层逐图声明：图层在每张地图的 `meta.layers`，清单没有 layers 键。

**层参数（可选，缺省省略）**：

瓦片层可设置 `tileGrid`，形如 `{"gridProjection":"orthogonal","gridTopology":"triangles"}`。
缺键时沿用地图格空间；有此对象时必须显式设置 `gridProjection`，可另设 `gridTopology` 和 `gridBasis`，
默认四边格且不继承地图的双基。层格尺寸仍由清单 `tileSize` 决定，宽高沿用地图 `meta.w/h`。
作者可在图层管理的空瓦片层输入自定义双基；已有瓦片的图层通过迁移创建新层。
迁移按原格号或局部像素中心映射，有越界或多格落到同一格时拒绝整批。新层有独立 ID，
继承显示参数，复制瓦片资产、切片及变换位。源层 ID、实例、根碰撞、格图绑定和其他引用保持原样。
读取 `tiles[layerId]` 前用 `GridSpace.resolve_tile_layer(layer, manifest, rootGrid)` 得到本层格几何，
再应用该层的位移和缩放；三角层 x 使用半格列。实例连续坐标、出生点、根碰撞和根格边仍使用地图格系。
「跨层搬动」只改变选中的瓦片、实例坐标和根碰撞格号；实例码及内容绑定不变。
格图、格边和出生点仍指向原位置。它是离线编辑操作，不增加运行时字段；需要搬动关联路线时，作者应在对应工具中更新。
如果游戏把本层地形用于通行，可读取作者生成或手工维护的有限格图；不会自动把本层瓦片写入根碰撞。

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
| `visual` | 二者之一 | 无 prefab 时的编辑器呈现：`{type: "rect"/"poly"/"path", mode: "rect", color, alpha, ...}`。两个键各管一件事：`type` 决定几何种类（缺省 `rect`，校验只查这个键；`poly`/`path` 另可声明 `closed`/`width`/`points`，见 §3.1）；`mode: "rect"` 决定**无贴图时画布是否画半透明矩形占位**（内置事件就靠它，见 §2.7）。没有 `sprite`/`none` 两种模式的实现（写了不生效）。`prefab` 与 `visual` 都没有 = 校验报错 |
| `thumb` | 否 | 缩略图 PNG 路径；缺失时编辑器按 `visual` 声明画占位 |
| `frames` | 否 | 帧动画贴图路径数组（按播放顺序）；编辑器画布按 8fps 循环**预览**（只确认帧序），游戏侧自定播放节奏。预览优先级：thumb > texture（image 资产）> frames 首帧 |
| `editorSize` | 否 | `[w,h]` **像素**，画布占位尺寸。缺省用 1 格（tileSize 尺寸） |
| `sizeFields` | 否 | `["w","h"]`：尺寸写在实例 `props` 的这两个键里（格数），取代「按 id 硬编码矩形」 |
| `role` | 否 | 连接语义：`portal` / `exit` / `landing` / `trigger`；见 2.6 |
| `code` | 否 | 4 位实体身份码。缺省由编辑器补发并随清单写回；**不要手工改动** |
| `functions` | 否 | **自带功能（挂载）**：声明池 functions 里功能 id 的数组，声明顺序 = 默认执行顺序；见 2.4.1 |
| `fields` | 否 | 实例参数及引用声明，见 2.4.2 |
| `ports` | 否 | 端口声明`[{id, x, y, type?}]`：x/y 为锚点局部像素，id 资产内唯一、type 可选字符串；`port_ref` 字段据此出候选。见 2.4.2 |

**`functions`（挂载）与 `fields` 的分工**：
- `functions` = 类型自带、实例不可删的**功能**（如生命值/攻击/寻敌），声明本体在顶层 functions 池，
  类型只挂 id。值走内容文件（与附加功能同一模型）；未编辑过的实例 = 声明 default。
- `fields` 声明实例参数和引用，值存实例 `props`。内容编辑器右栏按声明生成参数控件和引用下拉。
  游戏按自己的模块契约读取这些值；编辑器负责编辑、保存和处理已知的引用关系。

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
| 编辑入口 | 实例值只在内容编辑器编辑 |

挂载功能的参数独立于资产实例的 `props`。同一个实体既可通过 `assets[].fields` 声明实例参数，又可通过 `functions` 声明可复用的功能内容。

### 2.4.2 `fields[]` —— 实例参数及引用声明

普通参数需要显式声明 `kind: "input"` 或 `kind: "choice"`。可使用与功能表单相同的标量、
数组、`of: "record"` 记录数组及静态或动态选项控件。参数写入 `objects[].props`，
顶层和记录子字段都用声明的 `id` 作键；条件行内部沿用条件声明的字段码。
声明 `mapFrame` 预览后，实例参数也可以使用实景拾取：二维点和有序路径支持
`pickSpace: "map"` 或 `pickSpace: "layer"`，后者用同一行的 `layerField` 指定局部空间。
相同的声明适用于记录数组内的字段。编辑器保存的是所选空间的像素坐标，不会自动转换成实例自身的局部坐标。
修改实例顶层的配对地图或图层时，编辑器会列出将被清空的已填写字段。确认后同时更新坐标空间与相关字段；
撤销可恢复旧空间和原值。重新拾取后，游戏按新空间解释坐标。
缺键时表单显示 `default`（或控件初值），只查看不会写入。游戏侧读取缺键时应用模块的默认值；
显式写入的 `0`、`false`、空字符串及空数组是有效覆盖值。
只写 `type` 的旧普通字段不自动生成控件；`entity_ref`、`map_ref`、`edge_ref` 和 `port_ref` 仍按原引用声明处理。

```json
{"id": "activation_count", "name": "触发次数", "kind": "input", "type": "int", "min": 0, "default": 1}
```

```json
{"id": "target_point", "name": "目标", "type": "entity_ref", "of": "spawn_point,portal"}
```

编辑器消费 `fields` 的方式（**声明驱动，不做字符串盲扫**）：
1. **只改声明为引用的字段**：`entity_ref`（实例码）、`port_ref`（端口引用）、`edge_ref`（只改所属图分量）、
   `choice.source` 为 `content:` / `entity_inst:` 的字段。未声明的字符串键一律原样保留，
   哪怕它的值恰好等于某个旧实例码。
2. **组内换新、组外保留**：值命中本次复制集合里的实例 → 换成新码；指向集合外的目标 → 原样保留
   （不让副本错误地指回源对象）。引用属于源图以外的图时同样保留。
3. **`mapField` 配对**：`entity_ref` 声明 `mapField: "<地图字段 id>"` 时，目标域 = 该地图字段的**当前行值**
   （不是全局当前图）。组内引用把配对字段改写成副本所在图；组外跨图引用写成源图键（地图码优先、缺码用图名）。
   无配对字段的组外跨图引用 = **冲突**，整次复制取消并列出原因，不做半套应用。
4. **数组与 record**：`of: "record"` 的数组逐行递归同一套规则，行内兄弟字段就是配对作用域
   （一行内的 `mapField` 只读本行值）；嵌套限深 4。
5. **目标缺失**：引用值指向不存在的实例/内容时，复制不猜、不改写，保留原值。
6. `fields[].id` 必须非空且同类型内唯一（校验规则）。

`of` 键在 `type: "entity_ref"` 时**被编辑器读取**（内容编辑器引用行）：限定实例下拉只列
指定类型（逗号分隔类型 id，可多个）；不写 = 列全部实例。
引用类取值都有专用编辑入口：`entity_ref`（实例下拉，`of` 限定类型）、`map_ref`（地图下拉，值 = 地图码）、
`edge_ref`（格边下拉/画布点选，值 = `{map, cell, edge}`）；
普通参数按声明类型编辑；只用 `string` 存 ID 不会获得引用选择、校验或重映射。

**端口**：资产可声明 `ports: [{id, x, y, type?}]`（`x`/`y` 为锚点局部像素），给开关/插槽/出入口这类
「实例上的具名连接点」一个稳定身份。字段声明 `type: "port_ref"`、`of: "类型,类型"`（可选，按端口 `type` 过滤）时，
值存 `{map: 地图码, inst: 实例码, port: 端口ID}`；块复制只改前两段，端口 id 不变。端口 id 在单个资产内非空唯一。
端口和格边的目标地图都先读值内的 `map`；空时读同一行 `mapField` 配对值，两者都空才是本图。
实例的 `port_ref` 字段可声明 `sourcePort: "端口ID"`，指向同一资产声明的端口，作为画布连线起点；
不指定时从实例视觉锚点起线。源端只影响编辑器呈现，目标值仍是同一份 `{map, inst, port}`。
本图连线可直接在摆放画布上拖放，跨图连线仍从配对图表单或实景选择。

**格边**：字段声明 `type: "edge_ref"` 时存 `{map: 地图码, cell: [x, y], edge: "x1,y1|x2,y2"}`——
「某个格拓扑里的一条边」的稳定身份，用于「同一个对象的不同端点」这类选择。边身份**完全由编辑器从格拓扑推导**，
游戏侧不需要额外声明键：一条边 = 两个共边格，无向边取排序后的代表边（两端点按 (y, x) 字典序排列），
因此 `edge(a,b)` 与 `edge(b,a)` 是同一串；`cell` 恒为该代表边的第一个端点（自洽，不存两套口径）。
邻接口径跟地图拓扑走（quad 四邻 / hex 六邻 / triangles 三邻，`GridSpace.neighbors_any`）。
实景选点的 `targets.edge` 应使用所渲染地图的地图码与规范边。编辑器按该地图快照的根格拓扑和范围验证；
即使两侧没有瓦片也能选。下拉仍只列出两侧有瓦片的共边。
没有声明实景预览时，表单仍可用「用坐标」按两个根格坐标写入同一种引用；编辑器检查根格邻接与范围，并统一端点顺序。
格边复制只改 `map` 分量，`edge` 和 `cell` 不动。跨图粘贴部分实例时，本图格边仍指向源图；
整图复制时，本图格边随副本解释。第三张图上的边和端口仍指原目标，即使目标实例与被复制实例同码。

### 2.5 功能声明 `functions`

游戏按功能、条件和步骤的声明码读取内容字段，并按当前绑定的地图解析本图引用。
没有实例绑定的独立流程若要引用地图实例，请用 `mapField` 显式指定地图；端口和格边也可以在值内写目标地图码。
缩图后保留引用原值；游戏侧仍需处理空值或无法解析的目标。

对于 `source: "content:<功能ID>"`，游戏可在字段声明中说明跳转后的地图上下文：

| `contentMapContext` | 游戏解释及编辑器预检 |
|---|---|
| 省略或 `"independent"` | 这条内容引用不传地图。适合全局菜单、图鉴或纯数据引用。 |
| `"inherit"` | 将调用方当前地图传给目标内容。目标里的本图实例、端口和格边据此解析。没有当前地图时，不推断目标归属。 |
| `"paired"` | 将同一行 `mapField` 指定的地图传给目标内容。配对字段须为单选地图；空值、歧义或目标不可读时不推断。 |

例如，分支记录可声明 `{"id":"next","code":"NEXT","kind":"choice","source":"content:scene","contentMapContext":"paired","mapField":"level"}`，
并在同一行声明 `{"id":"level","code":"LEVL","kind":"choice","source":"map"}`。作者照常选择目标地图与内容；
游戏读取 `LEVL` 和 `NEXT` 并传递上下文，JSON 值格式不变。编辑器沿声明检查所有可能分支，不执行条件、不替游戏切图；
运行时需按同一规则选择分支并载入地图。循环回到同一内容及地图时只检查一次。
项目内容和步骤表单里的「本图候选」只供下拉或实景选值。游戏应在实景选点数据中输出所渲染地图的目标身份；
编辑器验证目标后，通过临时地图选中的无配对端口和格边保留空 `map`，
游戏按运行时收到的地图解析；临时选择不存盘，也不充当跳转的配对地图。

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

游戏侧启动时直接从清单建立稳定声明 ID 与执行码的映射。显示名可修改；稳定 ID 和执行码应保持不变。

**字段声明 = kind（input/choice）+ type**。控件映射（`field_widgets.gd`）：

| kind | type | 控件 |
|---|---|---|
| input | `string` | LineEdit，回车/失焦提交并 strip_edges；`multiline: true` 则 TextEdit（失焦提交） |
| input | `int` / `float` | SpinBox（步进 1.0 / 0.1，`min`/`max` 可声明），失焦/回车提交 |
| input | `bool` | CheckBox，即时写盘 |
| input | `color` | ColorPickerButton，值存 `"#rrggbb"` 字符串 |
| input | `vector2` | N 个 SpinBox，N = 声明 `dims`（`2` 缺省 / `3`，其它值按 2 处理），值存 `[x, y]` 或 `[x, y, z]` 数组，失焦提交 |
| input | `range` | HSlider + SpinBox，`min`/`max`/`step` 可声明，值存数字 |
| input | `asset_ref` | 资产下拉：`assetKind`（scene/entity）+ 可选 `of: "id,id"` 过滤，值存资产 id |
| input | `array` | 可增删行容器，每行一个元素控件（`of` 指基础类型 / choice / `record`；`record` 子字段在 `fields` 里声明并可再嵌 array，限深 4）；值存元素数组 |
| input | `array` + `of: "record"` | 结构化行容器：`fields` 声明子字段（id/code/name/kind/type，可再嵌 array，限深 4）；每行带 ↑↓/复制/删除；值存对象数组 |
| input | `port_ref` | 端口下拉：`of` = 端口类型过滤（可选），值存 `{map, inst, port}` |
| input | `viewport_ref` | 视口下拉 + 归一化 SpinBox：值存 `{viewport, point: [nx, ny]}`；`rect: true` 则 `{viewport, rect: [nx, ny, nw, nh]}` |
| input | `edge_ref` | 格边下拉 + 画布点选：候选 = 地图里两侧都有瓦片的相邻格对（按规范代表边去重），值存 `{map, cell, edge}`；`mapField` 可配对目标图 |
| choice | — | OptionButton：`options: ["a","b"]` 直给，或 `source` 动态取；`multiple: true` 切勾选组，值存字符串数组 |
| input | `curve` / `flow_target` | 曲线关键帧 / 受声明限制的流程目标，见本节及 §2.1 |

choice 的 `source` 取值：`content:<kind>`（列该目录内容条目）、`entity:<id,id>`（清单实体类型，
空 = 不过滤）、`entity_inst:<id,id>`（当前图实例，显示"类型 · (x,y)"，值=实例码，空 = 全部）、
`map`（地图列表）、`audio:`（音频池，值=音频码）、`asset:<kind>[:id,id]`（资产表，值=资产 id）、
`port:<类型,类型>`（配对图优先的实例端口，值=`{map, inst, port}`）、`cell:`（当前图 `meta.cellGraph` 的 cell_id，值=格 id）、
`viewport:`（清单 `viewports` 的画幅 id，值=画幅 id）。
**连续参数（`type: "curve"`）**：实例属性、功能、条件、步骤和屏幕模块可声明数值曲线。例如：

```json
{"id":"zoom","kind":"input","type":"curve","default":[{"time":0,"value":1,"mode":"smooth"},{"time":2,"value":1.5}]}
```

值是以 `time` 严格递增排序的数组，时间非负，时间和数值都必须是有限数字；空数组表示没有关键帧。
每点的 `mode` 控制从该点到下一点的插值：省略或 `linear` 为线性，`hold` 在下一点之前保持原值，
`smooth` 用比例 `u*u*(3-2*u)` 做缓入缓出。`u = (当前时间 - 左时间) / (右时间 - 左时间)`。
曲线的时间单位、零点、区间外行为、循环，以及将数值用在什么参数上，由消费曲线的游戏模块定义。编辑器存储各控制点和插值方式。

值的 JSON 形态与声明不符时只读展示（vector2/range/int/float/choice 一律如此），
**绝不自动改写**。

`default` 决定新建内容时的初值：`bool`→false、`int`→`min`（缺省 0）、`float`/`range`→`min`（缺省 0.0）、
`vector2`→`[min, min]`（`dims: 3` 时 `[min, min, min]`）、`color`→`"#ffffff"`、其他→`""`。

字段行的悬浮说明由编辑器**从已声明的键拼出**（字段 id · 执行码 · 类型与 min/max · 可选值或
`source` · `default`），见 `field_widgets.gd::decl_tooltip`。契约里**没有**独立的「说明」「单位」
键：需要单位时，
把单位写进 `name`（如 `时长(秒)`、`数量(格)`）。

**功能声明里编辑器支持的键**：`id` / `code` / `name` / `fields` / `conditions` / `steps` /
`triggers`（白名单，见 2.5.4）/ `repeatable` / `timing` / `view`。其余键（`scope`、`icon`、`params`、
`category`、`group` 等）一律被忽略——归一化保留已知键，未知键不剥离但不参与编辑。
`timing` 是 `{mode: "instant"|"duration"|"continuous"}`，`view` 是呈现提示对象（编辑器只存取）。
**条件依赖与触发时机是两回事**：条件 = 满足才执行，时机 = 什么时候来问这个条件。

**实例上挂多个功能**：`functions` 是有序数组，每项：

```json
{"fn": "X7K2", "content": "TEST-D4L3-XXXX-X7K2-ABC234", "name": "自我介绍", "order": 1, "parallel": false}
```

| 键 | 语义 |
|---|---|
| `fn` | 功能**执行码**；码未在清单声明只**警告**（允许先放数据后补声明） |
| `bindingId` | 可选，实例内唯一的不透明行 ID；编辑器创建可重复绑定时发放，重排、换绑以及复制整个实例时保留。全图身份需要包含地图和实例码 |
| `mounted` | 可选布尔，true 标记类型自带行；同实例、同功能最多一条继承行 |
| `content` | 内容 ID；空串 = 已绑定功能但还没建内容（合法状态） |
| `name` | 显示名，缺省用 `fn` |
| `order` | 顺序，编辑器在增删时重排为 1..n |
| `parallel` | 布尔，编辑器只存取，**不解释语义** |
| `trigger` | 可选，时机**执行码**；缺省省略 = 走功能的默认时机。必须是功能声明 `triggers` 白名单里的时机（校验只查形态，白名单由下拉保证） |
| `enabled` | 可选布尔；缺省省略 = 启用。`false` 是唯一的写盘形态 |

功能声明可设置 `"repeatable": true`，让作者为同一实例添加多条同功能的绑定，
分别选择内容、启用状态、顺序与触发时机。游戏应逐条遍历 `functions`，不要按 `fn` 收成单值字典。
缺省仍限制作者添加一条；旧数据有多条时，诊断会提示但不删数据。
若功能也在资产类型的挂载列表中，只有继承行不可删除。多个旧行无法确定继承关系时，作者需显式选定。

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

**可配置条件组**：需要由作者选择条件、为多条分支分别设置参数时，可在功能字段、
步骤字段或其 `array of record` 子字段声明：

```json
{"id":"predicates","kind":"input","type":"array","of":"condition",
 "allowedConditions":["hit_window","on_lane"]}
```

内容文件值是有序数组，例如
`[{"condition":"hit_window","fields":{"WIND":110}},
{"condition":"on_lane","fields":{"LANE":2},"negate":true}]`。
`condition` 使用条件声明 ID，`fields` 以条件字段码为键，每行独立。
`negate: true` 表示取反；缺省省略。与原有固定 `functions[].conditions` 的顶层参数兼容，
两者可以并存。条件声明本身不能再嵌套条件数组。

分支可以用 `array of record` 声明，每条记录带条件数组、匹配模式和一个
`source: "content:<功能ID>"` 目标。作者可增删、复制、重排分支和条件，并用流程关系图编辑目标。
游戏模块定义组合方式（如全部满足、任一满足）、空组、优先级、默认分支和执行语义。
未选择或已移除的条件会在诊断中提示，编辑器不会自动替换。

### 2.5.2 音频池 `audio`（顶层声明池）

音频是**游戏工程声明的资产**。条目为 `{id, name, path, previewPath?}`。
`path` 由游戏解释；若它指向项目内的源音频，编辑器也可用于试听，或用可选的 `previewPath` 单独指定。
执行码由 `ensure_codes` 补发（码重复 = 校验错误）。

```json
"audio": {
  "bgm_title": {"name": "标题曲", "path": "audio/bgm_title.ogg"},
  "sfx_door":  {"name": "开门音效", "path": "audio/door.wav"}
}
```

功能/条件字段声明 `{"kind": "choice", "source": "audio:"}` 即得音频下拉，值存**音频码**。
BGM 切换、环境音触发、音效播放在哪一步响起，都是功能代码（游戏侧）的事——例如
「环境音触发区」= 一个 `visual.mode: rect` 实体（内置的 `trigger_zone` 就是）挂上带 `audio:`
字段的功能，进区播放、离区停止由功能实现决定。编辑器全程不解释音频语义。

### 2.5.3 步骤池 `steps`（顶层声明池）+ 演出

演出 = 一个功能（挂实例、声明链引用条件库做触发）+ 内容里的**步骤数组**。游戏侧声明
**步骤池**（与 functions 同形：`{id, code, name, fields}`，条目码由 `ensure_codes` 补发），
每个步骤是游戏侧代码 + 暴露字段（move_to / play_anim / wait / show_dialogue …）。
功能声明加可选键 `"steps": true` 标记演出功能；演出时间基可选 `timebase`：
`"seconds"`（缺省，at/duration 单位秒、0.1 吸附）/ `"frames"`（单位帧、1 帧吸附，格斗帧数据）/
`"beats"`（单位拍、1/4 拍吸附，节奏谱面）——数据形态（at/duration/track）不变，游戏侧按声明解释单位。
游戏侧要区分缺少 `at` 和显式 `at: 0`。缺少时取同轨游标；阻塞步骤将游标推进到原游标和
本步结束时间的较大值，非阻塞步骤不推进游标。若帧基功能用 `timePreview.fpsField` 声明参考帧率，
按此字段的 ID 查到字段码，再读该内容的值；将帧换算为秒时，用帧数除以此帧率。

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

列表可在同一功能及地图作用域内复制和粘贴连续段落。粘贴把新步骤追加到数组末尾，为它们写入显式
`at`：段落最早的生效起点对齐作者指定的时间，其余起点按原有距离平移。步骤码、字段、时长、轨道、
阻塞位和自定义键均保留，引用按原值保存。段落没有独立资源类型，游戏仍照常读取 `steps`。

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

**参考音频**：在 `timePreview.audioField` 指定一个 `source: "audio:"` 字段的 ID，
内容中仍保存音频码。编辑器从对应项目相对 `audio.path` 加载 WAV、OGG 或 MP3；
若游戏运行时使用资源键或专有格式，可额外声明 `previewPath` 指向项目内源文件。
WAV 的 PCM 波形仅作概览；OGG、MP3 可试听与跳转。换算结果是源音频秒数，
例如 `offsetField` 值 `0.237` 表示第零拍对应音频的第 0.237 秒；
负秒段静音，时钟到 0 秒时开始播放。需要毫秒精度的浮点字段可声明 `"step": 0.001`。
试听不会运行游戏逻辑；只有作者主动移动步骤时才按原时间基写回 `at`。

### 2.5.4 时机池 `triggers`（顶层声明池）

时机是**游戏侧的判定入口**（进入地图、触碰、计时、信号……），编辑器只认识它们的名字与码。
条目支持 `id`、`name`、`code`；需要图组事件接线时加 `eventTargets`（见 §6.2）。缺失的执行码由编辑器补发，池内重复会报错。

```json
"triggers": {
  "on_enter": {"name": "进入地图"},
  "on_touch": {"name": "触碰"}
}
```

**时机没有可编辑参数字段**。它是游戏可触发的入口，"进区后判什么"写在功能代码里。
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

它**没有任何特殊语义**：就是一个 `visual.mode: rect`（`type` 缺省 `rect`）的实体资产，画布按 `visual.mode/color/alpha`
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

### 项目世界布局 `worldLayout`（可选）

作者可从地图菜单编排世界分块。布局保存在清单，由地图 `meta.code` 取键，每张地图最多一处：

```json
{"worldLayout":{"version":1,"chunks":{"ABCD":{"origin":[-128,0],"size":[128,128]}}}}
```

`origin` 是世界矩形左上角，`size` 是范围宽高，单位为世界像素；坐标为 ±10000000 内的整数，
宽高是 1 至 10000000 的整数。左、上边界包含，右、下边界不包含。矩形范围不随地图格数或投影变化。
地图改名保留关联；复制得到新地图码，需另行添加到布局。分块可以留空或重叠，游戏自行决定重叠优先级、
坐标换算、相邻分块预载与卸载。地图缺失或重码时，编辑器保留原条目供修复。

程序生成世界可在某一条目上加 `generatedKey`，例如 `"slope/2/0"`。这是游戏计算出的稳定分块键，
区分大小写，在同一世界布局中唯一。作者可在世界布局中给已有地图填键或清空绑定。
游戏生成入口按自己的世界坐标、种子和规则算键，再用清单建立 `generatedKey → 地图码` 索引：
匹配的地图可替换该分块的生成结果，未匹配的分块照常生成。地图不能唯一解析时，游戏可报错或回退。
`origin` 和 `size` 仍供编辑器布局与预览使用；游戏自行确定生成网格及覆盖范围。
绑定替换整个分块；作者可以只修改少数格，但若要采用后续生成结果，可将新地图绑定到该分块。
已有的 `gridDelta` / `contentDelta` 数据原样保留，由旧游戏继续解释。如需带着旧行为迁移，可参考
`tools/legacy/generated_chunk_delta.gd`；在编辑器显式切换为整块替换后，游戏应直接加载作者地图。
新生成地图只记录生成器 ID 和参数，不再复制整份基线。

独立游戏示例使用移动角色的当前分块加左右各一块作为常驻窗口。跨边界时复用已经加载的相邻节点，
挂载新邻块，并卸载过期节点及其物理形状。这个范围和预载时机是示例游戏的策略。

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

<a name="map-data"></a>

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

画布可直接绘制这些实体，使用现有图层和实例数据。闭合形状用
`visual.type: "poly"`（`closed` 默认为 `true`），末点自动连接起点，不重复首点。
开放路径用 `visual.type: "path"`，或 `poly` 配 `closed: false`。闭合至少三点，开放至少两点，
自由绘制最多 512 点；编辑器拒绝新建自交闭环，既有无效点列可读取并修复。
游戏自行决定点列用作碰撞、导航、填充、生成或运动路径；它与地图的格碰撞数组独立。
闭合实体可选 `props.holes: [[[x,y],…],…]`，每一项是一条在同一实例局部坐标系内的内环。
填充和命中按外轮廓减去所有内环；点序方向不限，内环不得接触外边界、互相包含或相交。
省略 `holes` 表示实心。总计最多 512 个顶点与 32 个内环；游戏侧按需要生成带孔的物理或导航数据。
同一实体还可有不相连的附加外轮廓，存为 `props.parts: [{points, holes?}, …]`。
首个外轮廓仍从 `props.points` 和 `props.holes` 读取，附加项使用同一实例原点及变换。
各外环不可相交、接触或嵌套；每个外环的内环只扣除其自身区域。单实体最多 32 个外环，
所有外环和内环合计不超过 512 个顶点，每个外环最多 32 个内环。

独立验收项目演示了正交地图上的实际碰撞：将每个外环及其孔洞按顶点高度切成凸片，
挂在同一个静态碰撞体上，再用角色碰撞体验证移动。两个实体区都会阻挡移动，每个孔洞内及两轮廓之间
都可通行。封闭孔洞内可移动，但从外部穿过实体边界仍会受阻。
同一转换适用于轮廓、路径和端口：先在锚点局部对点做翻转和缩放，再旋转，加上格空间算出的资产锚点，
最后应用图层的缩放与偏移。`sortAnchor` 仅用于排序，贴图显示尺寸也不参与这个转换。
Godot 参考实现可复用 `MapViewData.object_transform_in_layer` 和 `layer_transform`；
视差属于游戏显示相机，不应叠加到物理顶点。

| 键 | 必填 | 语义 |
|---|---|---|
| `version` | 是 | 当前为 7；高于 7 = 编辑器打不开（报错），低于 7 = 警告并按当前结构读（跑迁移脚本升级） |
| `meta` | 否 | 对象。编辑器读写 `name`/`w`/`h`/`code`/`layers` 与 `gridProjection`/`gridTopology`/`gridBasis`（格空间三件），以及独立于整数瓦片格的 `cellGraph`；**其他键原样保留**（游戏侧自定义键安全） |
| `meta.w` / `meta.h` | 否 | 地图格尺寸，缺省 120×56 |
| `meta.code` | 否 | 4 位地图身份码，编辑器缺省补发。改名不改变它 |
| `meta.layers` | 是 | **图层栈**，见 2.3；数组序 = 栈序（底→顶） |
| `meta.gridProjection` | 否 | 逐图投影（B1）：`orthogonal`（缺省）/ `isometric` / `hexagonal`。缺键 = 沿用项目解析（清单任一瓦片资产声明非正交即整项目按它） |
| `meta.gridTopology` | 否 | 格拓扑（B3）：`quads`（缺省）/ `triangles`。三角格 = 每列平行四边形切成两个半格，格号 `(i,row)` 的 `i` 是三角列（`c = floor(i/2)`，奇偶选半格）；六边投影 + 三角格 = 非法组合 |
| `meta.gridBasis` | 否 | 斜平面双基 `[[ux,uy],[vx,vy]]`（B3）：`to_px = g.x·u + g.y·v`。非有限或不可逆（共线/零向量）校验报错 |
| `meta.cellGraph` | 否 | 有限格图（C4）`{cells: [{id, polygon, neighbors}]}`：id 非空唯一，polygon 为 ≥3 个有限的局部 `[x,y]` 点，neighbors 是指向已声明格 ID 的有向邻接。地图菜单支持可视编辑和精确输入 |
| `meta.cellGraph.edges` | 否 | 独立有向连接数组 `[{id, from, to, toMap?, type, props}]`。起点是本图格 ID；`toMap` 省略或空串时终点也在本图，否则 `toMap` 为目标地图的 `meta.code`，`to` 为目标格 ID。边 ID 在源图内唯一，重接不换 ID，允许并行边和自环 |
| `meta.cellGraph.spaces` | 否 | 以空间 ID 为键的对象，每项可含 `name`、`origin`、`axisX`、`axisY` 和 `layer`（图层 ID）。格通过 `cells[].space` 选空间，省略或空串表示地图根空间。格 ID 仍在整张格图内唯一；边可连接不同空间的格 |
| `spawn` | 否 | `[x, y]` 整数格坐标，缺省 `[2, 2]`。三角拓扑的列范围为 `0 ≤ x < 2 × meta.w`，其他拓扑为 `0 ≤ x < meta.w`。越界整数只报警告，便于打开地图修复。 |
| `tiles` | 否 | 对象 `{层id: [瓦片条目...]}`，见 3.2；**键缺失与 `{}` 等价** |
| `collision[]` | 否 | 数组，见 3.3；**键缺失与 `[]` 等价**——编辑器没有任何由地形兜底生成碰撞的逻辑 |
| `objects[]` | 否 | 数组，见 3.4 |

有 `space` 的格，其 `polygon` 是局部像素坐标。投影到地图根空间的公式是
`origin + axisX * x + axisY * y`。默认原点与两轴分别为 `[0,0]`、`[1,0]`、`[0,1]`；
空间必须可逆，支持平移、旋转、缩放和斜切。绑定 `layer` 时，上式的结果是图层局部坐标，
再计算 `layer.offset + layer.scale * 层局部坐标` 得到静态地图根坐标；未绑定时直接使用上式结果。
主画布的高亮和拾取还跟随当前相机视差；视差是表现效果，不写入格的坐标和边。
在编辑器内删除绑定层时，其静态变换并入各空间，保留格位置、身份和边；外部删层会产生缺失绑定警告。
编辑器可从瓦片层生成有限格图。输出仍使用 `cells[].polygon` 和 `neighbors`，不需要新增运行时解析分支。
生成格 ID 形如 `upper:2,4`；游戏应将格 ID 作为不透明字符串。瓦片只用于生成时确定格形和批内共边邻接，
不推断游戏的可行走与碰撞规则。生成后独立格图是连通关系的数据来源；跨层通行由作者填入的有向边定义。
生成格可含编辑器专用的 `generatedFromTile` 字符串，用来识别可续接的原格几何；运行时忽略该字段，
外部工具回写地图时应保留它。续接只添加新旧格之间的邻接，不影响已有格之间的单向或独立连接。
跨层选区搬动格图时保留已有格 ID 和连边，但会从被移动的格移除该生成标记；区域复制的副本也不带此标记。
规则格边的 `edge_ref` 与有限格图的有向边独立。作者可选择在区域复制时映射副本的规则格边引用：
按根格中心换算两端，新端点共边时重建 `map`、`cell` 和 `edge`，其余引用保留原目标。
字段用 `source: "cell:"` 枚举全图格；用 `source: "cell:upper"` 限定在名为 `upper` 的空间。
限定空间同时约束下拉和画布命中，字段值仍是格 ID 字符串。

需要让作者配置连接参数时，在清单声明可选的 `cellGraphEdgeTypes`：

```json
{"cellGraphEdgeTypes":{"stairs":{"name":"楼梯","fields":[
  {"id":"cost","name":"通行代价","kind":"input","type":"int","min":1,"default":3},
  {"id":"direction","kind":"choice","options":["up","down"]}
]}}}
```

`type` 是人类 ID，空串或省略表示通用连接。`props` 以字段 ID 为键，可省略未赋值字段；
创建时将显式 `default` 写入。支持 string、int、float、range、bool 和固定字符串选项（可多选）。
声明变化引起的类型或值漂移会产生定位到该边的警告并保留原数据。通行规则和参数解释由游戏实现。
边 ID 的作用域随地图身份确定，复制整图保留内部边 ID，新图通过自己的地图码区分。
复制时省略 `toMap` 的边随副本继续指向本图；指定了 `toMap` 的边保留原地图码。
目标图改名不改变地图码。跨图边只保存在源地图，不自动产生反向边；
游戏根据地图码加载目标文件，再按格 ID 进入，不要按文件名或本图同名格回退。
简单 `neighbors` 和独立 `edges` 分别存储，由游戏决定如何使用两者。
删除本图格时，编辑器清除其出边和本图内指向它的边；其他地图的入边保留原值。

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
> 这三类都按「格号 → 多边形/中心」换算，口径与编辑器 `src/canvas/grid_space.gd` 一致
> （`to_px`/`to_grid`/`cell_polygon`/`cell_center_px`）。游戏侧要么直接复用该脚本，
> 要么按 §3.1 的三个 meta 键实现同一套公式，否则编辑器与运行时可能选中不同的格。
> 复用时以 `GridSpace.resolve(meta, manifest)` 解析，处理其 `issues`，再用
> `cell_polygon`、`cell_center_px` 绘制，`pick_cell` 拾取，`neighbors_any` 取共边邻格。
> 实例 x/y 是连续数据坐标，按 §3.4 的资产锚点换算后才能用 `pick_cell` 查所在格；三角格地图上尤其不能把实例 x 当三角列。
> `object_anchor_px` 与 `object_anchor_grid` 处理资产锚点与连续坐标之间的换算；图层变换和排序偏移由调用方处理。
> 编辑器可另存副本并改变或移除双基，瓦片、碰撞及规则格引用保留原格号；需要重新解析副本的格空间，并检查保留格号的含义是否符合游戏设计。
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
| 投影（`gridProjection`） | 正交/等距/六边 + `gridBasis` 平行四边形；自定义双基可在新建地图时录入，拾取、几何、对象锚点同用解析结果 | 编辑器对自定义双基采用自绘；运行时可用同一格几何自绘，直接使用预设 `TileMapLayer` 布局无法表达任意基。 |
| 拓扑（`gridTopology`） | `quads` / `triangles`（半格拾取、共边邻接、自绘含 `alt`） | 三角层**没有逐瓦片 Y 交错**：整层一个绘制节点，`ySort` 只对实例生效 |
| 显式投影键 | 新建图会写入显式选择（包括 `"orthogonal"`）；缺键 = 沿用项目解析 | 缺键的地图会随项目默认投影变化。 |

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

场景图片实例与实体实例共用摆放字段。只有实体实例能携带 `code` 和 `functions`：

```json
{"asset": "portal", "code": "QK3T", "layer": "K2M8", "x": 31.5, "y": 28,
 "props": {"target_point": "L8WM"},
 "functions": [
   {"fn": "X7K2", "content": "TEST-FY9F-QK3T-DLOG-7M2XK9",
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
| `props` | 否 | 对象。类型参数 + 自定义键。保留未知键和显式空值；通过专用引用控件断开引用时删除对应的键。带 `sizeFields` 声明的资产（如事件）尺寸也写在这里（格数） |
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

**实例码分配规则**（画布的 `_ensure_code`）：放置/粘贴时生成一个**本图活跃实例集内未占用**的
4 位码（撞码重摇，最多 64 次）；粘贴/复制产生的是新实例、发新码，已有实例的码不会被重编。
码空间 32⁴ ≈ 100 万，同图活跃实例远小于碰撞概率——但「不回收」是编辑流程约定，
**不是全工程历史扫描保证**（已删除实例的码理论上仍可能被新实例抽到）。

> 注意：实例间的指向关系都应放在实体 `props` 里（建议同时声明 `type: "entity_ref"`，
> 编辑器才有下拉编辑入口，复制粘贴时才会跟着重映射）。

<a name="identity"></a>

## 4. 内容 `content/<功能id>/<内容ID>.json`

```json
{
  "id": "TEST-FY9F-QK3T-DLOG-7M2XK9",
  "function": "X7K2",
  "name": "打招呼",
  "fields": {"M3PQ": "你终于回来了。"}
}
```

| 键 | 语义 |
|---|---|
| `id` | 与文件名同名；编辑器写盘时强制覆盖为文件名 |
| `function` | 功能**执行码**。内容目录名使用稳定的功能声明 ID，显示名不参与查找。 |
| `name` | 显示名 |
| `fields` | `{字段执行码: 值}`，码来自清单 `functions[].fields[].code` |

**路径**：`<工程根>/<contentDir>/<function>/<id>.json`，`contentDir` 缺省 `content`。
目录名与文件名都**不能含 `.`**（目录）**或路径分隔符 / `..` / `:`**（文件名）。
文件 id 允许字母/数字/下划线/连字符/点，但不以点开头结尾。

**加载失败**：编辑器的内容读取器对缺失、损坏或非法路径返回 `{}`。游戏实现自己的加载器，为正式入口或必需内容缺失提供定位信息；不要把失效引用误当成正确加载的空内容。

**未知字段不剥离**：`fields` 里编辑器不认识的键（不在声明的码集里）原样保留；
编辑器以**只读行**展示（「未在清单中声明」+ 黄字说明），不提供可写控件，也**不会被删除**。
补回声明（code 须与磁盘键一致）即可恢复编辑。

**改名/复制语义**：改名只是改 `name`（ID 不变）；「复制成新 ID」会生成新的内容码段，
名字沿用弹窗输入。删除实例的绑定**不删除内容文件**——内容条目是库资产，可能被别的实例复用。

## 5. 分层身份码

自动发码的字符集为 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`。游戏应按字符串识别既有 ID 和码，不自行再发码。

| 层 | 长度 | 载体 | 何时发放 |
|---|---|---|---|
| 地图码 | 4 | 地图 `meta.code` | 首次打开该图 |
| 实体码 | 4 | 清单 `assets[].code` | 首次加载清单；随清单写回 |
| 实例码 | 4 | 地图 `objects[].code`（仅 entity） | 放置实例时 |
| 功能码 | 4 | 清单 `functions[].code` | 加载清单时缺则补发（`ensure_codes`） |
| 字段码 | 4 | 清单 `functions[].fields[].code` | 同上 |
| 条件字段码 | 4 | 清单 `conditions[].fields[].code` | 加载清单时缺则补发 |
| 时机码 | 4 | 清单 `triggers[].code` | 加载清单时缺则补发 |
| 步骤码 | 4 | 清单 `steps[].code` | 加载清单时缺则补发（ensure_codes） |
| 步骤字段码 | 4 | 清单 `steps[].fields[].code` | 同上 |
| 音频码 | 4 | 清单 `audio[].code` | 加载清单时缺则补发（ensure_codes） |
| 内容码 | 6 | 内容文件名 | 首次创建内容 |

拼装（`content_id.gd::content_id`）：

```
<地图码>-<实体码>-<实例码>-<功能执行码>-<内容码>
```

例：`TEST` 图上的 `portal`（实体码 `FY9F`）第 7 号实例（实例码 `QK3T`）挂对话：

```
TEST-FY9F-QK3T-DLOG-7M2XK9
```

项目内容库创建的独立条目使用 `project-…` ID 与 `"scope": "project"`，文件仍在
`content/<功能 id>/<内容 ID>.json`，沿用 `function`、`fields` 与可选的 `steps`。
作者可指定固定后缀（例如填 `campaign` 得到 `project-campaign`），便于游戏定义稳定入口。
在内容库把独立条目复制为草稿会保留字段、演出步骤和游戏自定义数据。保存后分配新的独立内容 ID；
已有绑定不改接，副本内的引用保持原值，包括原内容指向自己的引用。
游戏侧应按完整字符串查找 ID，不应以分段规则推导所有内容的地图或实例。
共享绑定到这类内容时，地图或实例复制保留其 ID。对于需要定位到某张地图的引用，
游戏侧声明配对 `map_ref` 字段，作者先填写地图再选目标。游戏侧决定入口和执行语义。
例如功能、条件或步骤声明 `"kind": "choice", "source": "content:ending"` 后，
作者可在项目流程关系图中为该字段选择 `ending` 类型的目标。
游戏仍从该字段读内容 ID，按声明的目标功能目录加载；关系图不生成额外的节点文件、执行脚本或隐式跳转。

**实例内容的任一段缺失 → 不生成内容 ID**（返回空串），内容编辑器会提示「还没有身份码」，此时不写盘。

**读取规则**：新建或复制实例内容用当前的地图码、实体类型码、实例码和功能执行码发号。
已经发布的内容 ID 保持原样。游戏按完整 ID 查找内容，不拆分旧 ID 来判断归属；
执行功能取地图 `functions[].fn` 或内容文件 `"function"` 中的码。

游戏侧启动时直接从清单建立映射
（`functions[].code` ↔ `id`，`fields[].code` ↔ `id`）。

## 6. 游戏侧读取契约

### 6.1 加载顺序

```
main.gd
 ├── 决定地图路径（--map= 参数 > 默认图）
 ├── MapLoader.load_json(path)            # 纯 JSON 读，不校验
 ├── build(root, data)                     # 建各层瓦片/碰撞/实体/出生点
 ├── load_content(fn, id)                  # 功能内容按需读（可自行封装）
 └── 按绑定读 content/<功能id>/<内容ID>.json（缺键用声明 default）
```

正式运行期间，玩家存档、设置和解锁状态应单独存储。生成可编辑地图时，只按生成协议返回数据，由编辑器发布正式地图。

<a name="entry-events-playtest"></a>

### 6.2 `--map=` 参数

在 `playtest.args` 配置 `"--map=%mapfile%"` 才会传入 `--map=` 参数。编辑器逐项替换模板；当前地图试玩传已保存地图的路径，项目入口试玩替换为空。

**可选：由作者选择正式启动入口。** 游戏声明 `startup` 后，工作台显示「启动入口…」。
例如 `{"startup":{"contentTypes":["campaign"],"screens":true,"maps":true}}`。
`contentTypes` 列出允许启动的独立内容功能 ID；`screens` 和 `maps` 启用已保存的屏幕和地图候选。
还可用 `"arrivalPorts":["entrance"]` 启用指定类型的地图入场端口。各目标域可独立启用，编辑器保存一个 `startup.target`：

| 类型 | 保存值 |
|---|---|
| 独立内容 | `{"function":"campaign","content":"project-intro"}` |
| 屏幕 | `{"view":"title-screen"}` |
| 地图 | `{"map":"M123"}`（地图码，改文件名不变） |
| 地图入场端口 | `{"map":"M123","inst":"I456","port":"door"}` |

正常启动时游戏读取这个值并派发；没有 `target` 时沿用自己的默认入口。游戏若收到显式的地图、
内容或屏幕试玩参数，应优先使用该参数；工作台「试玩项目」不传选定内容参数，因此走同一套正常启动逻辑。
如果允许启动的内容需要地图上下文，可声明 `startup.contentMapContext: "paired"`。作者选择内容时也须选择一张已保存地图，
编辑器把地图码存入 `startup.contentMap`。正常开局时游戏把该地图码传给目标内容；屏幕、地图与端口入口不使用该字段。
正式入口与 `playtest.entryFunctions`（哪些内容可单独试玩）是独立声明。
删除当前入口引用的内容或屏幕前，请先更换或清除入口。

图组事件层与启动入口独立。游戏在某个时机条目声明允许的目标，例如：

```json
{"triggers":{"round_finished":{"code":"FIN1","name":"关卡结算","eventTargets":{"contentTypes":["settlement"]}}}}
```

作者可新建一个层，为 `FIN1` 选择允许的目标，并在同一图组绘制层制作页面和实体。
例如游戏声明该时机接受 `settlement` 内容时，编辑器可在项目清单写入：

```json
{"eventLayers":{"LYR1":{"name":"共用结算","maps":["MAP1","MAP3"],"drawingMap":"DRW1","events":{"FIN1":{"function":"settlement","content":"project-results"}}}}}
```

层的键、`maps` 中的地图码、`events` 中的时机码和目标 ID 才是身份；`name` 只用于展示。
省略 `maps` 代表适用于全部地图，包括以后新增的地图；显式空数组不匹配任何地图。
`drawingMap` 是可选的共享绘制地图码。游戏按基础地图码筛选适用层，再按 `drawingMap` 查找 `meta.code` 相同的普通地图文件，将其作为独立绘制层叠加；不要把绘制地图当作基础地图递归匹配。没有 `drawingMap` 的层仍可共享事件。
共享层里的实例、图层和引用保留该绘制地图的身份；实例功能按 `drawingMap` 的地图码解析，基础地图触发的图组事件仍按基础地图码匹配。游戏自行控制共享层何时显示及如何叠放，可以在结算时才显示结算面板。编辑器实景 `mapFrame` 请求在 `subject.eventDrawings` 提供已解析的 `[{layer, map, data}]`，分别是事件层 ID、绘制地图码及地图文档。
地图触发事件时，游戏按当前地图码选取匹配的层，并用时机码查 `events` 中的目标；
各层可重叠，执行先后和冲突策略由游戏决定。没有地图的入口若要复用规则，也可由游戏读取未限定地图的层。
`eventTargets` 与流程目标使用同一组域：`screens`、`maps`、`contentTypes`、`arrivalPorts`。
内容目标保存为 `{"function":"功能声明ID","content":"内容ID"}`；游戏按功能声明解析执行码。
既有 `projectContentSlots` 和 `mapContentSlots`（值位于地图 `meta.contentSlots`）留给原有游戏。
迁移时先由游戏为旧规则声明时机码和目标类型；作者再将指向同一目标的旧绑定合成一层，选择适用地图码。
切换游戏的读取入口后即可从原清单和地图中删除旧绑定。迁移期间游戏应为同一时机选择一种来源，
避免重复执行。单图专属出口继续使用 `mapOutputs`。

**可选：游戏加载回执和无地图入口。** 清单设 `playtest.projectEntry: true` 后，工作台
显示「试玩项目」：先提交工作台数据，再以空的 `%mapfile%` 启动。游戏可将独立内容 ID
作为项目入口（例如 `project-campaign`）。普通「试玩」仍使用当前地图。

若另声明 `playtest.entryFunctions`，作者可在内容库选择该类型的独立项目内容并点「试玩所选内容」。
工作台仍先完成提交，启动时 `%mapfile%` 为空，并在结构化参数中追加
`--editor-entry=<Base64 编码的 UTF-8 JSON>`。解码后为
`{"version":1,"function":"功能声明 ID","content":"所选内容 ID"}`。
游戏按功能和内容 ID 加载入口，并自行决定如何运行它。未收到该参数时沿用游戏默认入口。
此参数独立于 `--editor-playtest`，不要求启用加载回执。

开启 `playtest.contentEntryMap` 后，作者选了试玩地图时，同一个入口对象会额外携带
`"contentMap":"地图码"`；未选择则省略。游戏以此值作为该段内容的地图上下文，不读取正式入口的配对地图。
单项内容试玩只读取已保存的资源，不提交当前地图草稿。

声明 `playtest.mapEntry: true` 后，项目流程图的「试玩所选地图」会以空的 `%mapfile%` 启动，
并发送同一个 `--editor-entry` 参数，解码为 `{"version":1,"map":"地图码"}`。
如果声明 `mapEntryPorts`，作者可在默认入场之外选用该地图上匹配类型的端口，参数同时包含 `inst` 和 `port`。
游戏应按正常地图目标的入场逻辑加载该地图。编辑器不提交当前地图草稿，也不修改正式启动入口。
此方式与从屏幕和项目内容进入一样，加载回执的 `mapDigest` 为空。

若声明 `playtest.viewEntry: true`，同一个 `--editor-entry` 参数也可携带
`{"version":1,"view":"所选 view_id"}`，此时没有 `function` 或 `content`，`%mapfile%` 为空。
游戏应从正式清单里的指定屏幕开始，并沿自己实现的控件与流程继续运行。此入口不提交地图或屏幕草稿；
启用回执时，`mapDigest` 为空，`manifestDigest` 使用实际读取的正式清单。

`playtest.viewDraft: true` 时，试玩当前草稿发送
`{"version":1,"view":"所选 view_id","viewDraft":"临时快照的绝对路径"}`。
快照 JSON 为 `{version:1, token, view, viewport:[width,height], viewportId, locale}`，其中 `view` 是该屏幕完整草稿，
`token` 与本次加载回执相同。游戏应在内存里用它覆盖（或临时新增）同 ID 的屏幕，再从该屏幕进入；
其他屏幕、地图和内容继续读正式文件。画幅和语言是编辑器当前预览设置，`viewportId` 为空串或缺省时使用基础布局。
成功回执还须带 `viewDigest`，为实际读取的快照字节的 SHA-256，不能直接抄请求值。
快照只用于当前进程，编辑器检测到退出后删除；游戏不要把它当成项目资产依赖。

设 `playtest.report: true` 后，结构化 argv 末尾增加
`--editor-playtest=<Base64 编码的 UTF-8 JSON>`，解码得到
`{version: 1, token, path, mapDigest, manifestDigest}`。实际加载和验证数据之后，把回执
先写到同目录的临时文件，再重命名为请求中的 `path`。格式：

```json
{"version":1,"token":"请求中的值","status":"ready","mapDigest":"实际读取的地图 SHA-256","manifestDigest":"实际读取的清单 SHA-256"}
```

项目入口的 `mapDigest` 为空。应根据实际读取的文件计算 SHA-256；不要直接照抄请求摘要。
游戏拒绝加载时回传相同的版本和 token，写入 `status: "error"` 和 `message`。
回执上限为 64 KiB。编辑器在收到回执时更新状态栏，游戏退出后读取最终回执。
回执需要 `playtest.executable` 结构化启动；未启用时不传新参数。
建议的解析顺序：`FileAccess.file_exists(原始串)` → 否则 `"res://" + 去掉前导 /`。
游戏侧新增启动参数时保持这个前缀约定，别改 `--map=` 的语义。

`playtest.flags` 和 `playtest.params` 声明的参数会按作者选择追加。指定位置试玩额外传 `--spawnx` 和 `--spawny`（根格坐标）。

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
| 内置种类（如 `trigger_zone`） | 编辑器内存补入，默认不会写盘 | 游戏侧有自己的实现；尺寸读 `props.w`、`props.h`（§2.7） |

按 `objects[].asset` 查找声明，按 §3.4 的坐标与锚点规则定位，再应用实例变换和所属图层的变换。游戏自定实例参数注入方式，可用构造参数、初始化方法或节点 metadata。约定的是 JSON 字段，编辑器不会把参数反写到 prefab。

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
