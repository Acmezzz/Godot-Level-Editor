# 对抗性审查（2026-11-28）

> 前两轮（R1 全量通读 / R2 修复复核）之后，本轮换攻击姿势：不按文件通读，**按攻击面构造具体场景去打**——竞态、键类型、边界值、跨层不变量、恢复路径。裁定标准：真 BUG = 有真实触发路径且后果不合成；优化 = 收益/成本比明确；吹毛求疵不列。

## 1. 攻击面清单与裁定总表

| # | 攻击面 | 攻击场景 | 裁定 |
| --- | --- | --- | --- |
| 1 | 身份码唯一性 | 4 位码空间 32⁴≈105 万，几千实例地图生日碰撞到千分之几 | **安全**：所有发放点（画布/MCP/ClonePlan/层码/格图码/图组码）都带查重重发循环；唯一性需求范围=图内，跨图重复合法（地图码分层） |
| 2 | 草稿 overlay × 人工编辑 | 画布脏时 MCP publish 改同一图 → 人工保存静默覆盖？ | **安全**：publish 侧 baseline（can_write）+ 人工侧 `_confirm_map_write` 外部改动确认 + pending log，三层防线 |
| 3 | undo × 外部改写 × doc_busy | publish 后 undo 差量恢复 | **安全**：内容差量带两侧摘要（refused_external）、整图快照恢复后保存必经外部改动确认；`_restoring`/`doc_busy`/重建窗口哨兵成体系 |
| 4 | JSON 数字键/float-int | int 键落盘变字符串键、Vector2i(3.0) | **安全**：持久化字典全字符串键（cellGraph spaces/edges、tiles 键=层码）；坐标 int() 转换点全覆盖 |
| 5 | WAV 裁切 | 压缩格式按字节裁、RIFF 对齐、8-bit 符号 | **安全**：格式白名单（8/16-bit PCM）双防护（`_wav_clip` 与 `_pcm_envelope`），RIFF pad/size 正确，XOR 0x80 与 decode_s8 一致 |
| 6 | 多文件提交半途崩溃 | recover_log 深比较 entries；rename 场景 back() 误取 | **安全**：rename 场景被 L93-94 显式 continue，resume 只走非 rename 路径 |
| 7 | cell_graph 拆层 detach | 拆层后格图边漂移 | **安全**：detach_layer 带层变换换算；undo 快照含 cellGraph 全量 |
| 8 | 浮点累积 | playhead/parallax/缩放漂移 | **安全**：playhead 只在拖拽时 _snap 设置，无 _process 累积；编辑器无长时累积场景 |
| 9 | 异步间隙状态漂移 | 重建窗口读画布、双击重入、模态确认期间改写 | **发现 A-1**（live_map 哨兵未翻译）；其余有哨兵/防抖/确认-再比对防护 |
| 10 | 边界值 | MCP map.patch 改尺寸 | **发现 A-2**（尺寸无校验）；region 负 w/h 返回空=吹毛求疵不列 |

## 2. 确认缺陷（要修）

### A-1（P3）MCP live_map 在画布重建窗口返回空数据当真值

- **触发路径**：undo 恢复/层重建的 `load_data` await 窗口内（`map_loaded` 保持 true，`extract()` 返回 `{}` 哨兵），MCP `query_content kind=live_map` 返回 `{"data": {}}`——客户端（尤其 AI 批量代理）会把空地图当真实数据继续推理。
- **位置**：src/mcp/workbench.gd:219。
- **第一性原理**：`extract()` 的空字典是**内部哨兵**（"此刻读不到一致状态"），出口必须把哨兵翻译成错误，而不是让哨兵穿透到协议层冒充数据。同类语义已在 map_resize.open（L138-140"地图重建中"）翻译过——live_map 漏了。
- **方案**（一行）：
  ```gdscript
  "live_map":
      if not app.map_loaded:
          return {"error": "当前未打开地图。"}
      var data: Dictionary = app.canvas.extract()
      if data.is_empty():
          return {"error": "画布正在重建，请稍后重试。"}
      return {"data": data}
  ```
- **影响面**：无（纯出口翻译，不改 extract 契约）。

### A-2（P3）MCP map.patch 可写入非法尺寸，产出"打不开的图"或语义矛盾图

- **触发路径**：`map.patch` 遍历 meta 键时只保护 code/name/layers（src/mcp/edits.gd:152-154），`meta.w/h` 可被设为 0、负数或任意值：
  - `w/h <= 0`：map_data_validation.gd:34 报 error → 图在下次打开时被读链路拒绝，**变成打不开的图**（自伤且 AI 客户端难以自诊断）；
  - `w/h > 0` 任意值：校验器不查"瓦片在声明尺寸外"（只查 spawn 越界=warning），落盘一张"声明 5×5 但瓦片在 200 处"的语义矛盾图。
- **第一性原理**：**协议入口的数据约束必须与校验器同界**——同一个不变量在两处表达必然漂移；修复不是"再加一层防御"，而是让入口复用同一判据（`>0 整数`，即 map_data_validation.gd:34 的同一口径）。
- **方案**（edits.gd map.patch 分支加一段）：
  ```gdscript
  if data.meta.has("w") or data.meta.has("h"):
      for key in ["w", "h"]:
          if data.meta.has(key) and (not EditorManifest._is_integral_number(data.meta[key]) or int(data.meta[key]) <= 0):
              return {"error": "meta.%s 必须是正整数；缩小尺寸请用编辑器的地图尺寸弹窗（会裁剪越界数据）。" % key}
  ```
  （若 `_is_integral_number` 不可达，用与 map_data_validation 相同的 `value is int or value is float` 判据；同时 EDITOR_MCP.md 的 map.patch 行补一句"w/h 必须为正整数，缩小不裁剪数据"。）
- **影响面**：MCP 客户端改尺寸的正确姿势不变（patch 正整数 + 用 tiles.set 重铺），只拦非法值。

## 3. 吹毛求疵清单（明确不修，防止误伤）

- workbench._page 的 region 负 w/h：Rect2 负尺寸 has_point 恒 false → 返回空列表。客户端参数错误返回空结果可接受，不为它加分支。
- MCP publish 后 `sess.opened_digest` 不更新 → 下次人工保存必弹"外部改动"确认：这是安全设计的正确代价（publish 写的候选内容≠画布状态），保持现状。
- steps_panel 家族内 `host._form.公开方法` 访问（L258/1208）：家族内浅层访问，与 N1/N2 的跨面板私有链不同级。
- map_flow_dialog._library（R2 N1）/ steps_panel._form._resolve_options（R2 N2）：已在 R2 行动清单，本轮不重复计。

## 4. 行动清单

| 级别 | 事项 | 动作 |
| --- | --- | --- |
| P3 | A-1 live_map 哨兵穿透（workbench.gd:219） | extract 空时返回"画布正在重建"错误，一行 |
| P3 | A-2 map.patch 尺寸无校验（edits.gd:152-158） | w/h 加正整数校验（与 map_data_validation.gd:34 同口径）+ MCP 文档补一句 |
| — | 吹毛求疵清单（§3） | 明确不修 |
| — | R2 遗留 N1/N2（私有访问漏改 2 处） | 维持 R2 方案不变 |

## 5. 方法与覆盖说明

- 本轮按攻击面构造场景（身份码/并发/undo 矩阵/键类型/WAV/崩溃恢复/detach/浮点/异步间隙/边界值共 10 面），不是按文件通读——R1 已逐行读过 118 文件，本轮目标是"R1 的盲区"：**跨层不变量与协议边界**。
- 攻击用过的证据源：发放点全集 rg、调用链逐层读、Godot 音频格式语义（8-bit signed 存储）、JSON 序列化键类型、Rect2 负尺寸行为。
- 裁定口径：触发路径可复现 + 后果不合成才列；"AI 客户端可能踩中"按批量自动化场景加权（live_map/map.patch 都是 MCP 批量流的真实高频入口）。
- 覆盖盲区如实声明：没有跑运行时验证（未启动编辑器实测重建窗口命中概率）；A-1/A-2 由代码路径推演确认，修复时顺手在 test_authoring_mcp.py 补两个断言即可锁住。