# 2D游戏编辑器 MCP

这个 MCP 由 2D游戏编辑器进程运行。Windows 导出包可以单独运行；开发用的 Godot IDE 插件、仓库里的 Node 驱动与本服务无关。MCP 的写入范围是游戏的地图、内容 JSON 和清单中供作者配置的部分，没有源文件读写、终端、脚本执行或任意路径写入工具。

## 启动和连接

发布包包含 `2D游戏编辑器.exe` 和同名的 `2D游戏编辑器.pck`，两者必须放在同一目录。MCP 随 EXE 一起提供，无需另装插件或 Node.js。

从 PowerShell 启动，例如：

~~~powershell
& '.\2D游戏编辑器.exe' -- --bird-mcp '--bird-project=D:/Game/My Game'
codex mcp add bird-editor --url http://127.0.0.1:47821/mcp
~~~

- 不指定 --bird-project 时沿用编辑器的最近工程，也可以在编辑器里选择工程。
- 默认不启动 MCP。用 --bird-mcp 开启，用 --bird-mcp=端口 改端口。MCP 只监听 IPv4 回环地址。
- 如果设置 BIRD_MCP_TOKEN，编辑器要求客户端使用同一 Bearer Token。连接时加 --bearer-token-env-var BIRD_MCP_TOKEN；启动编辑器和 Codex 的环境都要能读到该变量。
- 从新的 Codex 会话调用工具。MCP 是 Streamable HTTP；POST 返回 JSON，通知返回 202，无长期 SSE 连接。媒体作为 MCP 标准图片或音频内容块返回。图形模式才有编辑器界面截图。

## 制作流程

先调用 describe_project 确认当前工程、游戏声明和 ID。create 建草稿，逐批 apply_changes 或 generate_map；用 query_content 和 validate 检查候选状态，用 capture_editor 或 render_preview 看画面。publish 的 previewOnly 给出目标和基线，确认后用原 revision 正式提交。各种操作都作用于选中的游戏工程，切换工程时草稿不会跟到另一工程。

人工复核时，从关卡空画布或顶栏「地图 ▾」进入「查看 MCP 草稿…」，选择草稿和地图。弹窗标明当前预览版本；AI 继续修改后可点「刷新草稿」。预览不切图、不写入正式文件。发布后，在「地图 ▾」选正式地图继续编辑。

| 工具 | 参数和行为 |
| --- | --- |
| describe_project | 无参返回已打开工程和清单。section 可单看声明，path 可切换到已有的最近工程。首次可在界面选择或通过启动参数指定。 |
| query_content | kind 可取 assets、functions、bindings、maps、map、layers、objects、tiles、collision、ports、edges、cells、references、timeline、contents、content、views、world、groups、candidates、inbound、live_map。map 用地图码，function 用清单功能 ID，content 用完整内容 ID。提供 draft 时读候选状态；live_map 始终读人工画布工作副本。画布重建或位置、尺寸、顶点的拖动尚未完成时会提示稍后重试，并保留正在进行的操作。 |
| manage_draft | action 为 list / create / open / save / diff / undo / redo / discard。每次成功批改持久化为独立版本。diff 给出涉及的对象、字段路径及可比较的前后值；summaryOnly:true 省略完整候选文档，基线不匹配时标记 baselineConflict 并省略该项字段比较。undo/redo/discard 要当前 revision。 |
| apply_changes | draft、revision、operations。整批作为一次撤销；返回新版本、ID、别名与格式警告。 |
| generate_map | 无 generator 列出可用生成器；仅给 generator 查参数与预设。给 name、draft、revision 执行；可提供 preset 和 parameters。给 sourceMap 则继承该地图的生成来源和参数，结果写为新的可编辑地图。 |
| capture_editor | target 为 window / popup / canvas / control / tree / draft_map。window 默认。tree 返回当前可见路径和坐标；可以把控件路径放到 control，或把弹窗路径放到 window 并指定 target:popup。rect 可按像素再裁剪；delayMs 可在定位后稍候。 |
| render_preview | capability 为 mapFrame / screenLayout / timelineFrame / worldFrame / playtestFrame，取决于游戏声明。可指定 draft、profile、width、height、locale、camera。timelineFrame 按 times 取样，支持秒和声明的帧/拍单位。 |
| preview_asset | asset 查看声明、贴图、图形或动画。cell 选图集格；frames 传动画下标数组。audio 用执行码或声明 ID，返回时长与可播放附件。PCM WAV 支持波形与按秒传 start / duration 裁切；OGG、MP3 返回原始音频附件。 |
| validate | 无参检查工程清单、地图和主要引用；有 draft 时加入候选、修改内容以及发布冲突检查。map 或 function/content 可指定检查对象。游戏逻辑仍通过试玩验证。 |
| playtest | action 为 start / status / capture / stop。start 的 entry 为 project / map / content / screen；target 见下文。 |
| publish | draft、revision。previewOnly:true 只报告待写入的文件和校验结果；正式发布比对基线、保留文件历史、写入提交记录并刷新编辑器。如果有打开的人工编辑表单或待保存的地图内容，请先在编辑器保存或关闭相应编辑，再正式发布；此时仍可只读预检。发布成功清空这份草稿的改动。若正式文件已写但草稿尚未整理，返回 published:true、publishedRevision 和 cleanupPending:true；用同一 revision 重试，只会继续整理草稿。 |

查询列表可用 search、offset、limit。assets 传 map 时给出当前图的实际使用量；functions 可传 map、instance、trigger，返回候选及理由。objects / bindings 可传 map 或 mapCodes 限定跨图范围，也可按 asset、layer、function 或 instance 筛选；bindings 另支持按 content、trigger 筛选并返回真实 sequence。contents 支持用显示名查正式或草稿内容。objects / tiles / collision 支持 region:[x,y,w,h]，这是当前数据域的格坐标。tiles 需要 layer；objects 的 objectIndex 可定位无实例码的场景摆放物。ports 支持按 types 筛选。candidates 可传流转声明 domains，或字段原声明 field；使用 map 指定其空间上下文。inbound 支持 view 或 function/content。

如果修改时提示找不到可编辑的地图，先调用无参 `validate`。不可读取的地图按文件名和出错字段返回原始校验原因。旧版碰撞数组需要先用源码仓库的 `tools/migrate_project.gd` 迁移，再重新打开工程。

### 批量编辑

operations 的每个对象包含 op。写入数据时，字段、步骤、触发和连接都应采用游戏侧声明要求的键和值。比如功能入口用声明 ID，绑定保存时由编辑器转为执行码；内容 fields 的键使用执行码。编辑器替新资源分配稳定 ID。加 as 可选定批内别名，后续用 $别名引用；别名仅在同批有效。

| 操作 | 操作对象 |
| --- | --- |
| map.create | name、width、height；可选 projection（orthogonal / isometric / hexagonal）、topology（triangles）。 |
| map.patch / map.rename / map.delete | map；patch 的 data 可改 meta 中的参数（例如格图、流程数据、尺寸）和 spawn；rename 额外给 name。 |
| layer.put / layer.delete / layer.move | map。put 省略 layer 新建，data 使用图层声明结构；修改、删除、移动指定 layer，move 给目标 index。删除前需移走图层上的瓦片和对象。 |
| tiles.set / collision.set | map。tiles 额外传 layer；cells 是记录数组，每项包含整数 x、y。瓦片记录含 asset、atlas:[x,y] 和可选 alt；碰撞用地图格式中的 type 等字段。remove:true 擦除该格。 |
| instance.put / instance.delete | map；新建用 data.asset，修改或删除有实例码的摆放物用 instance；没有实例码的场景摆放物用 objectIndex。若同时提供两者，必须指向同一行。下标会随批内操作和草稿版本变化。可编辑 data.layer、x/y、props、transform，也可用 world:[x,y] 按世界像素定位。 |
| binding.put / binding.delete | map、instance；新建给 function，已有绑定用 binding（存储字段 bindingId）。data 可改 content、trigger、order、parallel、enabled、name；index（从 0 开始）可重排绑定列表，data.order（从 1 开始）也可指定同一位置；同时提供时须一致。创建、移动或删除后按列表顺序更新执行顺序。trigger 使用该功能已声明的时机执行码，空字符串为默认时机；传声明 ID、未知码或此功能未开放的码会被拒绝。 |
| content.put / content.delete | function、content（新建省略）。新建同时给 map 和 instance 可发放实例内容 ID；省略 map 时建立项目内容。data 可改 name、fields、steps 等。 |
| view.put / view.delete | view，可在 put 中省略以分配新 ID；data 可写布局、元素、热区、导航与本地化等屏幕数据。 |
| group.put / group.delete | group，可在 put 中省略以分配新 ID；data 可写 name、maps、drawingMap、drawOrder、events。绘制文档可用同批 map.create 创建，图组的整组顺序以 drawOrder 表示，底图为 0。省略 maps 使图组应用于适用的普通地图。 |
| startup.set | data.target 选入口，data.contentMap 选配对地图；null 可清除。入口可用类型由游戏侧 startup 声明决定。 |
| slot.set | slot 指已有项目内容槽位，data.target 给 {function,content} 或 null。 |
| project.set | value 整体替换 section：views / viewports 用数组，eventLayers / worldLayout 用对象。清空列表用 `[]`，清空图组用 `{}`；涉及 ID 的键也支持同批别名。 |

`map.patch` 的 `meta.w`、`meta.h` 若设置具体值，必须为正整数。值为 `null` 时删除该键，读取时采用缺省尺寸。调小尺寸只改地图格数，会保留已有地图内容；要同时裁剪越界数据，请使用编辑器的「调整地图边界」。非法尺寸会使批次失败，并返回 `meta.w` 或 `meta.h` 的校验原因，草稿版本不变。

瓦片可以保留在地图的名义格范围之外。`apply_changes` 和 `validate` 会按图层列出超界数量和一个坐标示例；它是警告，不阻止保存或发布。检查用的是该图层的格系：三角层有 `2 × w` 列。误放时可扩大地图，或用 `tiles.set` 的 `remove:true` 擦除。`layer.put` 的 `parallax` 接受有限数值，负值表示反向滚动。

### 截屏、实景和试玩

- 截编辑器：panel 可选 map、assets、content、groups、screens、world、viewports、startup、flow、library、playtest、timeline。map 可指定地图码、instance 可聚焦关卡或内容中的实体；屏幕用 view；演出给 function、content，time 移动编辑器时间轴播放头。已经打开的其它编辑器窗口可直接用 window、popup 或 tree/control 查看。临时读草稿画布用 target:"draft_map"、draft 和 map，不替换当前人工编辑的地图；可指定 camera:{center:[x,y],zoom:数值} 和画幅。
- 游戏实景由游戏的 preview 声明提供。mapFrame 传 map；screenLayout 传 view；timelineFrame 传 function/content，也可加 map、instance、binding。图组快照随地图上下文一起传给渲染器。worldFrame 使用世界布局。游戏可在画面里提供可回填的拾取区域，结果中包含三角形、目标 ID、局部坐标和遮挡信息。playtestFrame 是游戏提供的离线取样接口，与正在运行的游戏画面分开。
- 试玩入口的 target：地图 {map} 或 {map,inst,port}，内容 {function,content} 或 {function,content,contentMap}，屏幕 {view}。默认使用正式内容；现有屏幕草稿试玩协议允许传 draft 捕获该屏幕快照，其余内容仍来自正式数据。其它未发布地图或演出可先用预览查看。status 返回游戏实际提供的加载回执。
- 试玩实时截图为可选扩展。游戏若需要支持，应声明 playtest.report:true 和 playtest.captureFrames:true。游戏在现有 --editor-playtest= 参数解出回执 path 和 token 后，监听同目录的 <回执名去掉.json>.frame.request.json。请求形状为 {version:1,token,id,width,height,result}。核对 token，按指定画幅获取**本次运行**画面，先写临时 PNG 后改名到请求的 result 路径。编辑器读取后清理请求和结果。不接入扩展时，其它试玩和离线预览照常可用。

## 源码仓库：重新导出与验收

在 Godot 的「项目 → 导出」选择 **Windows Desktop**。默认 EXE 路径是 `dist/2D游戏编辑器.exe`（先创建 `dist`，也可选其他输出目录）。导出配置排除源码仓库的开发插件、工具和测试。

`tools/release_check.py` 跑编辑器回归；`tools/test_authoring_mcp.py` 用 `--editor` 指定导出的 EXE，通过 HTTP 验证编辑、截图、试玩和发布。`--godot` 用于启动测试工程，运行发布版编辑器本身不需要安装 Godot。
