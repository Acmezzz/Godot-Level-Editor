# 第三轮复审修复清单

基线 `cccfd3e`。按发布影响和依赖拆批，逐项记录完成状态。项目格式沿用 v7。

## 发布阻断

- [ ] A1 暂存键误作内容 ID。会话快照保留真实 `fn_id/cid`，非法目标写前中止，依赖仍在时不得丢弃暂存（`document_session.gd`、`content_form.gd`、`document_commit.gd`）。
- [ ] A2 文件创建、替换、删除和改名统一检查前置状态。数据与摘要同源，创建意图从发号保留，冻结计划拒绝无效目标（`document_commit.gd`、`content_store.gd`、`map_store.gd`）。
- [ ] A3 跨图清理按逐图收据同步当前画布与基线，涵盖部分成功和读盘不完整（`issues_drawer.gd`、`map_file.gd`、`project_audit.gd`）。

## 数据完整性与编辑正确性

- [ ] B1 提交互斥、冻结清单和地图、修订对账及试玩收据（`map_file.gd`、`document_commit.gd`）。
- [ ] B2 清单覆盖确认和同源摘要（`app.gd`、`manifest.gd`）。
- [ ] B3 改名收据、未落盘改名依赖、整图复制校验（`map_store.gd`、`map_file.gd`）。
- [ ] B4 恢复日志记录操作、来源和预期摘要，保留部分成功详情（`recovery.gd`、`document_commit.gd`）。
- [ ] B5 延迟放弃暂存，统一切图与恢复发布流程，防止草稿误选撞码图或覆写已落盘码（`map_file.gd`、`manifest.gd`）。
- [ ] B6 表单失败保留、绑定和步骤命令身份（`field_widgets.gd`、`content_editor.gd`、`content_form.gd`、`steps_panel.gd`）。
- [ ] B7 批改、关系图和配对引用确认后的旧值复验（`batch_ops.gd`、`rel_graph.gd`、`ref_ops.gd`）。
- [ ] B8 整图、实例、区域复制统一内容复合键及源工作副本（`clone_plan.gd`、`selection_ops.gd`、`region_ops.gd`）。
- [ ] B9 资产删除扫描完整性与清单改动发布边界（`asset_panel.gd`、`project_audit.gd`）。
- [ ] B10 扫描双向唯一重链、指纹刷新、候选复验与发号查重（`asset_scan.gd`）。
- [ ] B11 拓扑感知裁剪与确认后修订复验（`map_resize.gd`、`map_dialogs.gd`）。
- [ ] B12 未解析实例、变换和字段往返，未解析瓦片参与编辑及撤销（`entity_factory.gd`、`undo_history.gd`、`tool_ops.gd`）。
- [ ] B13 碰撞手势分流与瓦片替换切片复验（`canvas_input.gd`、`tile_replace.gd`）。
- [ ] B14 导出和内容预览的显隐、图层、格形、变换及排序口径（`map_export.gd`、`content_preview.gd`）。

## 性能、维护与诊断

- [ ] C1 地图与声明的版本化索引，关系图复用目录结果。
- [ ] C2 三角瓦片块级失效、相机可见集、碰撞与区域查询、内容预览修订。
- [ ] C3 导出工作量预算及时间轴视口、重叠统计。
- [ ] C4 地图类型与数值校验、独立坐标查重、格图和格边引用。
- [ ] C5 收敛文档、编解码、撤销、写盘和审计职责。
- [ ] C6 保留逐目标诊断，减少日志回填成本。
- [ ] C7 Prefab 尺寸探测与试玩偏好迁移。

按发布阻断、数据正确性、性能与结构的顺序实施。每批记录具体修复与验证结果。跨文件部分成功保留逐文件结果，三角裁剪按格拓扑判断。导出的一致范围与规模预算在对应批次写明。
