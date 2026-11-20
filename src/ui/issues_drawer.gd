extends RefCounted
## IssuesDrawer：问题抽屉 + 全项目自检（从 editor_layout.gd 拆出，宿主 = editor_layout）

const ProjectAudit := preload("res://src/project/project_audit.gd")
const EntityNodeScript := preload("res://src/canvas/entity_node.gd")

var host   # editor_layout 宿主
var app    # 根应用（= host.app）

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
	var wrap := PanelContainer.new()
	var sb = app.UiThemeScript.box(app.UiThemeScript.BG_PANEL, app.UiThemeScript.BORDER, 0, 10, 6)
	sb.set_border_width_all(0)
	sb.border_width_top = 1
	wrap.add_theme_stylebox_override("panel", sb)
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
	# 条目列表（展开时显示；行点击跳转；ScrollContainer 封顶防吞屏）
	_issues_drawer = wrap
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
	wrap.add_child(col)
	body.visible = false
	wrap.visible = false
	return wrap

## —— 全项目自检（REFACTOR_PLAN 4.6-3）：project_audit 的呈现层 ——

## 展开/收起条目列表
func _toggle_issues_drawer() -> void:
	if _issues_list:
		_issues_list.visible = not _issues_list.visible

## 跑全项目审计并刷新抽屉。open_after=自检菜单入口（跑完自动展开列表）。
func _run_audit(open_after := true) -> void:
	var items: Array = ProjectAudit.audit(app.manifest)
	_issues_items = items
	if _issues_btn:
		_issues_btn.text = "问题 %d" % items.size()
	_populate_issues()
	if _issues_scroll:
		_issues_scroll.custom_minimum_size.y = minf(items.size() * 26.0 + 6.0, 160.0)
	if open_after and _issues_list:
		_issues_list.visible = true
	if _issues_drawer:
		_issues_drawer.visible = true
	if items.is_empty():
		app._set_status("自检通过：未发现问题")
	else:
		app._set_status("自检完成：发现 %d 个问题" % items.size())

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

## 行点击跳转：地图问题开图；实例问题开图后选中；清单问题不可跳转
func _jump_to(it: Dictionary) -> void:
	var j := it.get("jump", {}) as Dictionary
	var typ := str(j.get("type", ""))
	if typ == "" or app.canvas == null:
		return
	var map := str(j.get("map", ""))
	if typ == "entity":
		if map != "" and (map != app.cur_map_name or not app.map_loaded):
			await app._open_map_by_name(map)
		if app.map_loaded and map == app.cur_map_name:
			_select_by_code(str(j.get("code", "")))
	elif map != "" and (map != app.cur_map_name or not app.map_loaded):
		app._open_map_by_name(map)

## 选中本图指定实例码的节点（找不到给状态提示）
func _select_by_code(code: String) -> void:
	if code == "" or app.canvas == null:
		return
	var n: Node = null
	for e in app.canvas.ents_all():
		var en := e as EntityNodeScript
		if en != null and en.code == code:
			n = en
			break
	if n == null:
		app._set_status("未找到实例 %s" % code)
		return
	app.canvas.selected_entity = n
	app.canvas.selected_multi.clear()
	app.canvas.entity_selected.emit(n)
	app.canvas.queue_redraw()
