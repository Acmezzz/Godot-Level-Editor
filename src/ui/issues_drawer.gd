extends RefCounted
## 显示手动项目自检结果。

const ProjectAudit := preload("res://src/project/project_audit.gd")
const EntityNodeScript := preload("res://src/canvas/entity_node.gd")
const ReferenceViews := preload("res://src/ui/reference_view_library.gd")
const MapFlowDialog := preload("res://src/ui/map_flow_dialog.gd")
const ProjectSlotsDialog := preload("res://src/ui/project_content_slots_dialog.gd")
const StartupDialog := preload("res://src/ui/startup_dialog.gd")

var app
var _issues_btn: Button
var _issues_drawer: PanelContainer
var _issues_list: VBoxContainer
var _issues_scroll: ScrollContainer
var _issues_items: Array = []

func _init(editor_app) -> void:
	app = editor_app

func build() -> PanelContainer:
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
	var rerun: Button = app.UiKitScript.button("重扫", func(): run_audit(false), "ghost")
	rerun.tooltip_text = "重新扫描全项目"  # 读回校验锚
	head.add_child(rerun)
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
	scroll.visible = false
	box.visible = false
	return box

## —— 全项目自检（REFACTOR_PLAN 4.6-3）：project_audit 的呈现层 ——

func _toggle_issues_drawer() -> void:
	_issues_scroll.visible = not _issues_scroll.visible

## 跑全项目审计并刷新抽屉。open_after=自检菜单入口（跑完自动展开列表）。
func run_audit(open_after := true) -> void:
	var audit_meta := {}
	var items: Array = ProjectAudit.audit(app.manifest, audit_meta)
	_issues_items = items
	_issues_btn.text = "问题 %d" % items.size()
	_populate_issues()
	_issues_scroll.custom_minimum_size.y = minf(items.size() * 26.0 + 6.0, 160.0)
	if open_after:
		_issues_scroll.show()
	_issues_drawer.show()
	if items.is_empty():
		app._set_status("自检通过：未发现问题")
	else:
		app._set_status("自检完成：发现 %d 个问题%s" % [items.size(),
			"（有地图读不出来，结果不完整）" if audit_meta.get("incomplete", false) else ""])

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
	if typ == "project_slot":
		ProjectSlotsDialog.open(app, j.id)
		return
	if typ == "startup":
		StartupDialog.open(app)
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
			MapFlowDialog.open(app, j.section, j.field)
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
