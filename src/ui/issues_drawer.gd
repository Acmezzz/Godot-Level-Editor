extends RefCounted
## IssuesDrawer：问题抽屉 + 全项目自检（从 editor_layout.gd 拆出，宿主 = editor_layout）

const ProjectAudit := preload("res://src/project/project_audit.gd")
const EntityNodeScript := preload("res://src/canvas/entity_node.gd")
const MapStore := preload("res://src/map/map_store.gd")
const ReferenceViews := preload("res://src/ui/reference_view_library.gd")
const MapFlowDialog := preload("res://src/ui/map_flow_dialog.gd")

var host   # editor_layout 宿主
var app    # 根应用（= host.app）
var _audit_incomplete := false   # 上次自检有图读不出来 → 清除必须禁用
var _clear_btn: Button = null

func _init(h) -> void:
	host = h
	app = h.app

## 同名转发属性（读写穿透到宿主，搬动文本零改动）
var _issues_btn:
	get: return host._issues_btn
	set(v): host._issues_btn = v
var _issues_drawer:
	get: return host._issues_drawer
	set(v): host._issues_drawer = v
var _issues_list:
	get: return host._issues_list
	set(v): host._issues_list = v
var _issues_scroll:
	get: return host._issues_scroll
	set(v): host._issues_scroll = v
var _issues_items:
	get: return host._issues_items
	set(v): host._issues_items = v

## 同名包装方法（真实实现经 host 转发）
func _set_status(msg: String) -> void:
	host._set_status(msg)

## —— 问题抽屉（REFACTOR_PLAN 4.6-3）：project_audit 的呈现层 ——

func _build_issues_drawer() -> PanelContainer:
	var box := PanelContainer.new()
	var sb = app.UiThemeScript.box(app.UiThemeScript.BG_PANEL, app.UiThemeScript.BORDER, 0, 10, 6)
	sb.set_border_width_all(0)
	sb.border_width_top = 1
	box.add_theme_stylebox_override("panel", sb)
	var head = app.UiKitScript.hbox(8)
	# 标题即开关：点一下折叠/展开条目列表
	var head_btn: Button = app.UiKitScript.button("问题 0", func(): _toggle_issues_drawer(), "plain")
	head_btn.tooltip_text = "展开 / 收起问题列表（自检入口：地图菜单「检查项目完整性」）"
	_issues_btn = head_btn
	head.add_child(head_btn)
	head.add_child(app.UiKitScript.spacer())
	var rerun: Button = app.UiKitScript.button("重扫", func(): _run_audit(false), "ghost")
	rerun.tooltip_text = "重新扫描全项目"  # 读回校验锚
	head.add_child(rerun)
	var clear_btn: Button = app.UiKitScript.button("清除悬空", func(): _clear_dangling(), "ghost")
	clear_btn.tooltip_text = "把悬空引用字段的值清掉（字段留空=未填），写回前的快照在 editor/history/maps/<地图码>/"  # 读回校验锚
	_clear_btn = clear_btn
	head.add_child(clear_btn)
	# 条目列表（展开时显示；行点击跳转；ScrollContainer 封顶防吞屏）
	_issues_drawer = box
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_issues_scroll = scroll
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 2)
	_issues_list = body
	var col := VBoxContainer.new()
	col.add_child(head)
	col.add_child(scroll)
	scroll.add_child(body)
	box.add_child(col)
	body.visible = false
	scroll.visible = false   # E3：折叠态连滚动容器一起收（只藏 body 外层仍占最小高度）
	box.visible = false
	return box

## —— 全项目自检（REFACTOR_PLAN 4.6-3）：project_audit 的呈现层 ——

## 展开/收起条目列表。展开时先重扫再显示——条目永远新鲜（C-20 配套）。
## E3：折叠要把 ScrollContainer 一起收起——只藏内层 body 时外层仍按
## custom_minimum_size 占着最高 160px 的空白（U05）。
func _toggle_issues_drawer() -> void:
	if not _issues_list:
		return
	var expanding: bool = not _issues_list.visible
	if expanding:
		_run_audit(false)
	_set_issues_open(expanding)

## 展开态 = 列表与滚动容器同时可见（两处状态只在这一处写）。
func _set_issues_open(open: bool) -> void:
	if _issues_list != null:
		_issues_list.visible = open
	if _issues_scroll != null:
		_issues_scroll.visible = open

## 跑全项目审计并刷新抽屉。open_after=自检菜单入口（跑完自动展开列表）。
## 有图读不出来时检查范围不完整 → 禁用「清除悬空」（D07：范围不明只提示不动手）。
func _run_audit(open_after := true) -> void:
	var audit_meta := {}
	var items: Array = ProjectAudit.audit(app.manifest, audit_meta)
	_issues_items = items
	_audit_incomplete = bool(audit_meta.get("incomplete", false))
	if _clear_btn:
		_clear_btn.disabled = _audit_incomplete
		_clear_btn.tooltip_text = "有地图读不出来，检查范围不完整：先修好地图文件再清除" \
			if _audit_incomplete else "把悬空引用字段的值清掉（字段留空=未填），写回前的快照在 editor/history/maps/<地图码>/"
	if _issues_btn:
		_issues_btn.text = "问题 %d" % items.size()
	_populate_issues()
	if _issues_scroll:
		_issues_scroll.custom_minimum_size.y = minf(items.size() * 26.0 + 6.0, 160.0)
	if open_after:
		_set_issues_open(true)
	if _issues_drawer:
		_issues_drawer.visible = true
	if items.is_empty():
		app._set_status("自检通过：未发现问题")
	else:
		app._set_status("自检完成：发现 %d 个问题%s" % [items.size(),
			"（有地图读不出来，结果不完整）" if _audit_incomplete else ""])

## 条目列表：一行一条，点击跳转
func _populate_issues() -> void:
	for c in _issues_list.get_children():
		_issues_list.remove_child(c)
		c.queue_free()
	if _issues_items.is_empty():
		var lb = app.UiKitScript.text_label("扫描完成：未发现问题",
			app.UiThemeScript.OK, app.UiThemeScript.FS_SMALL)
		_issues_list.add_child(lb)
		return
	for it in _issues_items:
		_issues_list.add_child(_issue_row(it))

func _issue_row(it: Dictionary) -> Control:
	var sev := str(it.get("severity", "warning"))
	var icon := "⛔" if sev == "error" else "⚠"
	var txt := "%s %s — %s" % [icon, str(it.get("path", "")), str(it.get("message", ""))]
	var b: Button = app.UiKitScript.button(txt, func(): _jump_to(it), "ghost")
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.tooltip_text = txt
	return b

## 行点击跳转：地图问题开图；实例问题开图后选中；资产问题开资产页；清单问题不可跳转。
## E1：实例问题落到**内容页**并展开对应实例的引用区（字段级定位）。
func _jump_to(it: Dictionary) -> void:
	var j := it.get("jump", {}) as Dictionary
	var typ := str(j.get("type", ""))
	if typ == "" or app.canvas == null:
		return
	if typ == "content":
		app.project_shell.content_editor._library.open_issue(j)
		return
	if typ == "view":
		ReferenceViews.open(app, str(j.id), j)
		return
	if typ == "asset":
		# A4：停用/待确认的资产在资产页有恢复与候选按钮
		app._set_mode("asset", str(j.get("id", "")))
		return
	var map := str(j.get("map", ""))
	if typ == "entity":
		var want_map: String = map if map != "" else str(app.cur_map_name)
		if want_map != "" and (want_map != app.cur_map_name or not app.map_loaded):
			await app._open_map_by_name(want_map)
			# 开图失败/用户取消：保留抽屉条目和输入，给出文件与重试动作
			if not app.map_loaded or want_map != app.cur_map_name:
				app._set_status("跳到实例失败：%s 未打开（可重试，或先修好这个地图文件）" % want_map)
				return
		var code := str(j.get("code", ""))
		if code != "" and not _select_by_code(code):
			app._set_status("跳到实例失败：%s 里没有实例 %s（可能已删除）" % [app.cur_map_name, code])
			return
		# 内容页并定位到该实例（focus = 实例码）；有 prop 时把对应引用行标出来
		app._set_mode("content", code)
		if app.project_shell != null and app.project_shell.content_editor != null:
			app.project_shell.content_editor.highlight_field(str(j.get("prop", "")))
	elif typ == "map_flow":
		if map != app.cur_map_name or not app.map_loaded:
			await app._open_map_by_name(map)
		if app.map_loaded and map == app.cur_map_name:
			app._set_mode("map")
			MapFlowDialog.open(app, str(j.field))
	elif map != "" and (map != app.cur_map_name or not app.map_loaded):
		app._open_map_by_name(map)

## 选中本图指定实例码的节点（找不到返回 false，调用方给失败反馈）
func _select_by_code(code: String) -> bool:
	if code == "" or app.canvas == null:
		return false
	var n: Node = null
	for e in app.canvas.ents_all():
		var en := e as EntityNodeScript
		if en != null and en.code == code:
			n = en
			break
	if n == null:
		return false
	app.canvas.commit_selection(n as EntityNode)
	return true

## 一键清除悬空引用（D07）：把 audit 报出的 fix 项落地——按地图分组，逐图重读文件、
## **重跑引用检查并复验字段当前值仍是报告里的坏值**（报告可能过期：期间可能已修好/
## 改指向/目标图补上了对象），只清「新鲜报告里仍是同一条」的项；写盘成功才计数。
## 当前图有脏改动时先走 A2 提交再清（否则清完磁盘、画布下次保存又把值写回去）。
## 检查范围不完整（有图读不出来）时整条操作只提示、不动手。
func _clear_dangling() -> void:
	if _audit_incomplete:
		app._set_status(" 清除中止：有地图读不出来，检查范围不完整（先修好地图文件再重扫）")
		return
	# 报告里的 fix 带着预期旧值（expect）：没有预期值的旧条目一律不清（宁可不做）
	var by_map := {}
	for it in _issues_items:
		if str(it.get("kind", "")) != "ref":
			continue
		var fx = it.get("fix", null)
		if not (fx is Dictionary):
			continue
		var fx2: Dictionary = fx
		var mn := str(fx2.get("map", ""))
		if mn == "":
			continue
		if not by_map.has(mn):
			by_map[mn] = []
		(by_map[mn] as Array).append(fx2)
	if by_map.is_empty():
		app._set_status(" 没有可清除的悬空引用（先重扫）")
		return
	# R16：批量清理是跨图写盘动作——先列作用范围让作者确认（保存边界：当前图脏改动
	# 随后的提交里一并落盘），再动手。
	var scope_lines: Array[String] = []
	for mn2 in by_map:
		scope_lines.append("%s × %d 项" % [str(mn2), (by_map[mn2] as Array).size()])
	var root := str(app.manifest.get("_dir", ""))
	var gen: int = app._map_file_ctrl.sess.generation
	if not await app._confirm_action("清除悬空引用",
		"将对 %d 张图写盘清除悬空引用：\n%s\n\n每张图重读文件并复验旧值，已失效的项会跳过。" % [
			by_map.size(), "\n".join(scope_lines)],
		"清除"):
		app._set_status(" 已取消清除悬空引用")
		return
	if str(app.manifest.get("_dir", "")) != root or app._map_file_ctrl.sess.stale(gen):
		app._set_status(" 清除中止：确认期间已切换文档")
		return
	# 当前活体也可能是其他地图的引用目标，先保存它再对正式文件做判断。
	if app.map_loaded and (app.canvas.modified_flag or by_map.has(app.cur_map_name)):
		var res: Dictionary = await app._map_file_ctrl.commit_document("清除悬空引用前提交")
		if str(res.get("status", "")) != "ok" or app._map_file_ctrl.sess.stale(gen) or app.canvas.modified_flag:
			app._set_status(" 清除中止：" + str(res.get("error", "当前图已变化或未提交")))
			return
	MapStore.invalidate_read_cache()
	MapStore.invalidate_code_map()
	var fresh_meta := {}
	ProjectAudit.audit(app.manifest, fresh_meta)
	if bool(fresh_meta.get("incomplete", false)):
		app._set_status(" 清除中止：最新扫描范围不完整")
		return
	var total := 0
	var skipped := 0
	var failed := 0
	var per_map: Array[String] = []   # R16：逐文件（逐图）结果，写完一并列出
	# §4.4-4：跨图清理是一次多文件提交（N 张地图）——构造一份冻结计划交给执行器，
	# 日志、写前复验与逐目标收据与常规提交同一口径（以前这里是裸 MapStore.write，无日志）。
	var DC := preload("res://src/project/document_commit.gd")
	var frozen: Array = []
	var planned := {}
	for mn in by_map:
		var fix_list: Array = by_map[mn]
		var r: Dictionary = MapStore.read_path(MapStore.path_for(app.manifest, mn), app.manifest)
		if not bool(r.get("ok", false)):
			app._set_status(" 清除中止：%s 无法读取，请重扫" % str(mn))
			return
		var d: Dictionary = r.get("data", {}) as Dictionary
		# 新鲜报告 = 目标作用域的唯一判据：字段现在仍声明为悬空引用才动
		var res2: Dictionary = ProjectAudit.apply_ref_fixes(app.manifest, str(mn), fix_list, d)
		skipped += int(res2.get("skipped", 0))
		if not bool(res2.get("changed", false)):
			per_map.append("%s：无改动（%d 项已不成立）" % [str(mn), int(res2.get("skipped", 0))])
			continue
		var path := MapStore.path_for(app.manifest, str(mn))
		frozen.append({"kind": "map", "id": str(mn), "path": path,
			"map_data": d, "baseline": str(r.get("digest", ""))})
		planned[path] = int(res2.get("erased", 0))
	var reload_digest := ""
	var commit_error := ""
	if not frozen.is_empty():
		var prep := DC.prepare_frozen("清除悬空引用（%d 张图）" % frozen.size(), app.manifest, frozen)
		if prep.status != "ok":
			app._set_status(" 清除中止：" + str(prep.get("error", "提交计划为空")))
			return
		var result: Dictionary = DC.new().apply_frozen(prep.plan)
		for row in result.get("targets", []):
			var path := str(row.get("path", ""))
			var name_ := str(row.get("id", ""))
			var status := str(row.get("status", ""))
			if status != "written":
				failed += 1
				per_map.append("%s：%s" % [name_, status])
				continue
			var count := int(planned.get(path, 0))
			total += count
			per_map.append("%s：清除 %d 项" % [name_, count])
			if app.map_loaded and path == str(app.cur_map_path):
				reload_digest = str(row.get("digest", ""))
		if result.status != "ok":
			commit_error = str(result.get("error", ""))
			if commit_error == "" and not result.get("conflicts", []).is_empty():
				commit_error = str(result.conflicts[0].get("message", ""))
	if reload_digest != "":
		await app._map_file_ctrl.load_map_file(str(app.cur_map_path), reload_digest)
		if app._map_file_ctrl.sess.opened_digest != reload_digest:
			per_map.push_front("当前图已写盘，但重载失败，请重新打开")
	if commit_error != "":
		per_map.push_front(commit_error)
	_run_audit(false)
	if total == 0:
		app._set_status(" 没有清掉任何悬空引用（%d 项已不成立，%d 张图写入失败）%s" % [
			skipped, failed, ("：" + "；".join(per_map)) if not per_map.is_empty() else ""])
		return
	# R16：逐文件结果列出（状态栏单条合并；地图多时列前 6 张，其余以「等 N 张」收尾）
	var detail := "；".join(per_map.slice(0, 6)) \
		+ ("等 %d 张图" % per_map.size() if per_map.size() > 6 else "")
	app._set_status(" 已清除 %d 个悬空引用%s%s｜%s" % [total,
		("，跳过 %d 项已失效报告" % skipped) if skipped > 0 else "",
		("，%d 张图写入失败" % failed) if failed > 0 else "", detail])
