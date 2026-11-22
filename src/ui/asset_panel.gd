extends VBoxContainer
## 实体资产目录：左列图鉴列表 + 右侧详情（名称/缩略图、自带功能挂载、实例分布清点、删除）。
## 清单对象与写回动作由 app.gd 注入：manifest 字典、save_manifest 回调。
## 视觉统一走 UiTheme / UiKit。

const ImageProbe := preload("res://src/assets/image_probe.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const MapStore := preload("res://src/map/map_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const ProjectAudit := preload("res://src/project/project_audit.gd")   # 使用统计（C3）

var manifest := {}
var save_manifest: Callable
var host = null  # 宿主 app（确认框复用其链路）

var asset_list: ItemList
var _filter_edit: LineEdit
var mounts_box: VBoxContainer
var name_edit: LineEdit
var thumb: TextureRect
var _detail_hint: Label
var extra: VBoxContainer

var _edef: Dictionary = {}
var _loading := false

## 整页底色：直接画在控件自身，不额外插入节点、不占布局，也不会露出默认灰
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Th.BG_BASE)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

# —— UI 构建 ——
func build() -> void:
	add_theme_constant_override("separation", 0)
	# 顶栏（标题/项目徽章）已收进项目页外壳 project_shell.gd，这里只做内容区

	# —— 图鉴详情（资产视图的唯一页面：左列图鉴列表 + 右侧详情） ——
	var detail_view := Kit.hbox(0)
	detail_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(detail_view)

	var left_wrap := PanelContainer.new()
	left_wrap.custom_minimum_size = Vector2(272, 0)
	left_wrap.size_flags_horizontal = Control.SIZE_FILL
	left_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left_sb := Th.box(Th.BG_PANEL, Th.BORDER, 0, 10, 10)
	left_sb.set_border_width_all(0)
	left_sb.border_width_right = 1
	left_wrap.add_theme_stylebox_override("panel", left_sb)
	detail_view.add_child(left_wrap)
	var left := Kit.vbox(8)
	left_wrap.add_child(left)
	left.add_child(Kit.section_label("图鉴"))
	# 过滤视图：名称/id 关键字过滤（资产多起来后的基本效率件）
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "过滤：名称/id"
	_filter_edit.clear_button_enabled = true
	_filter_edit.text_changed.connect(func(_t: String): refresh_list())
	left.add_child(_filter_edit)
	asset_list = ItemList.new()
	asset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	asset_list.icon_mode = ItemList.ICON_MODE_LEFT
	asset_list.fixed_icon_size = Vector2i(40, 40)
	asset_list.item_clicked.connect(_on_asset_pick)
	left.add_child(asset_list)

	var detail_scroll := ScrollContainer.new()
	detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	detail_view.add_child(detail_scroll)
	var det_margin := MarginContainer.new()
	det_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	det_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	det_margin.add_theme_constant_override("margin_left", 18)
	det_margin.add_theme_constant_override("margin_right", 18)
	det_margin.add_theme_constant_override("margin_top", 14)
	det_margin.add_theme_constant_override("margin_bottom", 18)
	detail_scroll.add_child(det_margin)
	var det := Kit.vbox(12)
	det.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	det_margin.add_child(det)

	# 头部：大图 + 名称
	var hdr := Kit.hbox(16)
	det.add_child(hdr)
	_detail_hint = Kit.hint_label("没有匹配的资产", 320)
	_detail_hint.visible = false
	det.add_child(_detail_hint)
	var thumb_wrap := PanelContainer.new()
	thumb_wrap.add_theme_stylebox_override("panel", Th.box(Th.BG_VOID, Th.BORDER, Th.R_CONTAINER, 8, 8))
	hdr.add_child(thumb_wrap)
	thumb = TextureRect.new()
	thumb.custom_minimum_size = Vector2(160, 160)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb_wrap.add_child(thumb)

	var name_box := Kit.vbox(8)
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	hdr.add_child(name_box)
	name_box.add_child(Kit.section_label("图鉴名称"))
	name_edit = LineEdit.new()
	name_edit.add_theme_font_size_override("font_size", Th.FS_LG)
	name_box.add_child(name_edit)
	name_box.add_child(Kit.hint_label("名称即时写回清单，下次试玩生效"))

	det.add_child(Kit.divider())
	det.add_child(Kit.section_label("自带功能（挂载）"))
	det.add_child(Kit.hint_label(
		"类型自带、实例不可删的功能：从清单 functions 声明池里挑，值在内容编辑器按实例填。", 460))
	mounts_box = Kit.vbox(6)
	det.add_child(mounts_box)

	extra = Kit.vbox(8)
	det.add_child(Kit.divider())
	det.add_child(extra)

	# 编辑态只改内存；失焦/回车统一提交（每击键全量写盘+整表重建太重）
	name_edit.text_changed.connect(func(t: String):
		if _edef.is_empty() or _loading:
			return
		_edef["name"] = t)
	name_edit.text_submitted.connect(func(_t: String): _commit_name())
	name_edit.focus_exited.connect(_commit_name)

## 名称提交（写盘）
func _commit_name() -> void:
	if _edef.is_empty() or _loading:
		return
	save_manifest.call()

# —— 视图切换 ——
func show_detail(sid: String) -> void:
	refresh_list(sid)

# —— 图鉴列表 ——
## 图鉴列表：focus_sid 显式定位；空 = 保留当前选中（E1：切去内容/关卡再回来
## 仍停在同一份资产上，不悄悄跳回第一项）。选中项已不存在时才落到第一项。
func refresh_list(focus_sid := "") -> void:
	var keep := focus_sid
	if keep == "":
		var at := asset_list.get_selected_items()
		if not at.is_empty():
			keep = str(asset_list.get_item_metadata(at[0]))
	asset_list.clear()
	var focus_idx := -1
	var idx := 0
	for edef in AssetDecl.of_kind(manifest, "entity"):
		if bool((edef as Dictionary).get("builtin", false)):
			continue
		var sid := str((edef as Dictionary).get("id", ""))
		if not _matches_filter(sid, edef as Dictionary):
			continue
		asset_list.add_item(_list_label(sid, edef as Dictionary), _asset_texture(edef))
		# tooltip 露出 id、类别与停用状态——地图数据引用的是 id，界面上看不到就没法排查
		# P03：循环里已握着归一化声明，类别直接取，不再按 id 回查整表
		var tip := "%s · %s · %s" % [AssetDecl.category_of_decl(edef as Dictionary), sid,
			str((edef as Dictionary).get("name", sid))]
		if bool((edef as Dictionary).get("disabled", false)):
			tip += "\n已停用：不进调色板，原 ID 保留"
		elif bool((edef as Dictionary).get("retired", false)):
			if (edef as Dictionary).has("relinkCandidates"):
				tip += "\n改名待确认：多个同指纹候选"
			else:
				tip += "\n停用：" + str((edef as Dictionary).get("retiredPath", "")) + " 已不在磁盘上"
		asset_list.set_item_tooltip(idx, tip)
		asset_list.set_item_metadata(idx, sid)
		if sid == keep:
			focus_idx = idx
		idx += 1
	if focus_idx < 0 and asset_list.item_count > 0:
		focus_idx = 0
	if focus_idx >= 0:
		asset_list.select(focus_idx)
		_show_detail(str(asset_list.get_item_metadata(focus_idx)))
	else:
		# 列表空（含「删掉最后一个资产」）：右栏必须走空态，否则名称框/挂载/分布/删除按钮
		# 全部滞留上一项，残留闭包还会往已 erase 的字典里写。
		_show_detail("")

## 列表显示名：停用/待确认的资产带前缀，扫一眼就知道哪些需要处理（A4）
func _list_label(sid: String, edef: Dictionary) -> String:
	# E3：显示名走共用查询（AssetDecl.label），与画布选材同一口径
	# P03：循环里已握着归一化声明，直接取，不再按 id 回查整表
	var nm := AssetDecl.label_of_decl(edef, sid)
	if bool(edef.get("disabled", false)):
		return "⊗ " + nm + "（已停用）"
	if bool(edef.get("retired", false)):
		if edef.has("relinkCandidates"):
			return "⚠ " + nm + "（改名待确认）"
		return "⊘ " + nm + "（停用）"
	return nm

## 过滤视图：名称/id 任一包含关键字（大小写不敏感）。
## 名称查询同走 AssetDecl.label：未填 name 的资产按 id 也能被搜到。
func _matches_filter(sid: String, edef: Dictionary) -> bool:
	var q := str(_filter_edit.text).strip_edges().to_lower()
	if q == "":
		return true
	return sid.to_lower().contains(q) or AssetDecl.label_of_decl(edef, sid).to_lower().contains(q)

func _on_asset_pick(idx: int, _at: Vector2 = Vector2.ZERO, mb: int = 0) -> void:
	# 只认左键（与实体大纲列表同一约定）
	if mb != MOUSE_BUTTON_LEFT:
		return
	_show_detail(str(asset_list.get_item_metadata(idx)))

func _show_detail(sid: String) -> void:
	# 清单原件（不是归一化副本）：名称/挂载的改动要直接写回 assets[]
	_edef = AssetDecl.live_by_id(manifest, sid)
	if _edef.is_empty():
		# 空匹配（例如详情里删掉了当前资产）不能留上一项的陈旧数据
		name_edit.text = ""
		thumb.texture = null
		_mount_rows({})
		# extra 里挂着实例分布与删除按钮，也必须清掉
		for child in extra.get_children():
			extra.remove_child(child)
			child.queue_free()
		_detail_hint.text = "没有匹配的资产"
		_detail_hint.visible = true
		return
	_detail_hint.visible = false
	if bool(_edef.get("disabled", false)):
		_detail_hint.text = "已停用：不进调色板，但保留原 ID；重新启用即恢复。"
		_detail_hint.visible = true
	elif bool(_edef.get("retired", false)):
		# A4：停用/待确认状态在详情顶部给出可操作说明（列表前缀只是索引线索）
		var amb: bool = _edef.has("relinkCandidates")
		_detail_hint.text = "改名待确认：在下方候选里选一个路径" if amb else \
			"停用：源文件不在 %s。把文件放回原位后重开项目即可恢复；已有引用仍按原 ID 解析。" % str(_edef.get("retiredPath", ""))
		_detail_hint.visible = true
	_loading = true
	name_edit.text = str(_edef.get("name", sid))
	thumb.texture = _asset_texture(_edef)
	_mount_rows(_edef)
	for child in extra.get_children():
		extra.remove_child(child)
		child.queue_free()
	_add_config_section(sid)
	_add_scan_section(sid)
	_add_distribution_section(sid)
	var already: bool = bool(_edef.get("disabled", false))
	var del := Kit.button("永久删除（不可恢复）" if already else "删除此资产",
		func(): _delete_asset_checked(sid), "ghost")
	del.add_theme_color_override("font_color", Th.ERR)
	del.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	extra.add_child(del)
	_loading = false

## E3：生效配置 + 声明位置（审查 §3.6 / D17）：切片尺寸、分类、锚点、图集路径与
## 声明在清单里的位置——游戏侧配置出问题时，设计者能一眼定位到改哪儿。
## 源素材与图集切片仍由游戏侧维护，这里只读。
func _add_config_section(sid: String) -> void:
	var d := AssetDecl.by_id(manifest, sid)
	if d.is_empty():
		return
	extra.add_child(Kit.section_label("生效配置"))
	var box := Kit.vbox(2)
	extra.add_child(box)
	box.add_child(Kit.text_label("类别：%s · kind=%s%s" % [
		AssetDecl.category_of(manifest, sid), str(d.get("kind", "")),
		(" · shape=" + str(d.get("shape", ""))) if str(d.get("kind", "")) == "scene" else ""],
		Th.TEXT_SOFT, Th.FS_SMALL))
	box.add_child(Kit.text_label("锚点：%s" % str(d.get("anchor", "center")), Th.TEXT_SOFT, Th.FS_SMALL))
	var kind := str(d.get("kind", ""))
	if kind == "scene" and str(d.get("shape", "")) == "tile":
		var cs := AssetDecl.cell_size(manifest, sid)
		box.add_child(Kit.text_label("切片：%d×%d px" % [cs.x, cs.y], Th.TEXT_SOFT, Th.FS_SMALL))
		var pal: Array = AssetDecl.palette_of(manifest, sid)
		var cats: Array = []
		var seen := {}
		for p in pal:
			var cn := str((p as Dictionary).get("cat", ""))
			if cn != "" and not seen.has(cn):
				seen[cn] = true
				cats.append(cn)
		box.add_child(Kit.text_label("图集切片：%d 条%s" % [pal.size(),
			(" · 分类 " + ", ".join(PackedStringArray(cats))) if not cats.is_empty() else "（未配 palette = 整图平铺）"],
			Th.TEXT_SOFT, Th.FS_SMALL))
		var atlas := str(d.get("atlas", ""))
		if atlas != "":
			box.add_child(Kit.text_label("图集：%s%s" % [atlas,
				"" if FileAccess.file_exists(str(d.get("atlas_abs", ""))) else "（文件缺失）"],
				Th.TEXT_SOFT if FileAccess.file_exists(str(d.get("atlas_abs", ""))) else Th.WARN, Th.FS_META))
	elif kind == "scene":
		var es := AssetDecl.editor_size(manifest, sid)
		if es != Vector2.ZERO:
			box.add_child(Kit.text_label("编辑尺寸：%d×%d px" % [int(es.x), int(es.y)], Th.TEXT_SOFT, Th.FS_SMALL))
	else:
		var sizes := AssetDecl.size_fields(manifest, sid)
		if not sizes.is_empty():
			box.add_child(Kit.text_label("尺寸字段：%s" % ", ".join(PackedStringArray(sizes)),
				Th.TEXT_SOFT, Th.FS_SMALL))
	# 声明位置：assets[] 里的下标 + 键路径（清单是数组或 {id: body} 两种写法）
	var at := -1
	var raw = manifest.get("assets", null)
	if raw is Array:
		for i in (raw as Array).size():
			var it = (raw as Array)[i]
			if it is Dictionary and str((it as Dictionary).get("id", "")) == sid:
				at = i
				break
	elif raw is Dictionary:
		at = -1
	var where := "assets[%d]" % at if at >= 0 else "assets[\"%s\"]" % sid
	box.add_child(Kit.text_label("声明位置：editor_manifest.json · %s" % where, Th.TEXT_MUTE, Th.FS_META))
	# E3：图鉴 → 回画布保持所选资产（可直接开摆）
	if AssetDecl.placeable(manifest, sid) and not bool(d.get("disabled", false)):
		var row := Kit.hbox(6)
		var go := Kit.button("回画布用这个资产", func(): _use_on_canvas(sid), "ghost")
		go.tooltip_text = "切回关卡视图并把画布笔刷设成这个资产"
		row.add_child(go)
		box.add_child(row)

## E3：图鉴回画布——把所选资产设成画布笔刷（瓦片取第一条 palette 切片；实体/图片进入摆放模式）。
func _use_on_canvas(sid: String) -> void:
	if host == null or host.canvas == null:
		return
	var d := AssetDecl.by_id(manifest, sid)
	var kind := str(d.get("kind", ""))
	if kind == "scene" and str(d.get("shape", "")) == "tile":
		var pal := AssetDecl.palette_of(manifest, sid)
		var cell := Vector2i.ZERO
		if not pal.is_empty():
			cell = (pal[0] as Dictionary).get("cell", Vector2i.ZERO)
		host.canvas.paint_cell = cell
		host.canvas.paint_asset = sid
		host.canvas.stamp_thumb = null
		_set_brush_kind(host, "tiles")
		host._apply_state("paint")
		host._set_status("画布笔刷已设为瓦片资产 %s（切片 %d,%d）" % [AssetDecl.label(manifest, sid), cell.x, cell.y])
	else:
		host.canvas.stamp_asset = sid
		host.canvas.stamp_thumb = _asset_texture(d)
		_set_brush_kind(host, "object")
		host._apply_state("stamp")
		host._set_status("画布笔刷已设为 %s：在画布上点一下即可摆放" % AssetDecl.label(manifest, sid))
	host._set_mode("map")

## 图鉴带资产回画布（A1）：停在碰撞元层时只记「回去用什么画」，
## 直接写 place_kind 会在离开碰撞层时被恢复值盖掉。
func _set_brush_kind(host, kind: String) -> void:
	if host.canvas.active_layer == host.canvas.collision_index():
		host._editor_state_ctrl.remember_brush(kind)
	else:
		host.canvas.place_kind = kind

## 扫描状态（A4）：停用条目给恢复按钮；改名歧义给候选路径按钮（确认重链）。
func _add_scan_section(sid: String) -> void:
	if bool(_edef.get("disabled", false)):
		extra.add_child(Kit.section_label("扫描状态"))
		var row0 := Kit.hbox(6)
		row0.add_child(Kit.button("重新启用", func():
			preload("res://src/project/asset_scan.gd").enable(manifest, sid)
			save_manifest.call()
			refresh_list(sid), "primary"))
		extra.add_child(row0)
		extra.add_child(Kit.hint_label(
			"此条目已停用：不再出现在调色板，但保留原 ID——已有引用仍能定位到它，重新启用即恢复。", 460))
		return
	if not bool(_edef.get("retired", false)):
		return
	extra.add_child(Kit.section_label("扫描状态"))
	var box := Kit.vbox(4)
	extra.add_child(box)
	box.add_child(Kit.hint_label("原路径：" + str(_edef.get("retiredPath", "（无）")), 460))
	var cands: Array = []
	var raw = _edef.get("relinkCandidates", [])
	if raw is PackedStringArray or raw is Array:
		for c in raw:
			cands.append(str(c))
	if cands.is_empty():
		var row := Kit.hbox(6)
		row.add_child(Kit.button("恢复（文件已放回原位）", func():
			preload("res://src/project/asset_scan.gd").restore(manifest, sid)
			save_manifest.call()
			refresh_list(sid), "primary"))
		box.add_child(row)
		box.add_child(Kit.hint_label("引用检查：地图或内容里仍按此 ID 引用时会继续定位到本条目。", 460))
		return
	for c in cands:
		var r2 := Kit.hbox(6)
		var lbl := Kit.text_label(c, Th.TEXT_MUTE, Th.FS_META)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		r2.add_child(lbl)
		r2.add_child(Kit.button("用这个路径", func():
			preload("res://src/project/asset_scan.gd").confirm_relink(manifest, sid, c)
			save_manifest.call()
			refresh_list(sid), "primary"))
		box.add_child(r2)

## 实例分布（只读视图）：按地图折叠列实例 id 与坐标，供清点/删除检查。
## 自带功能的值 = 实例绑定内容（内容编辑器填），未填的用声明 default（游戏侧兜底）。
var _dist_rows: VBoxContainer

func _add_distribution_section(sid: String) -> void:
	extra.add_child(Kit.section_label("实例分布"))
	_dist_rows = Kit.vbox(4)
	extra.add_child(_dist_rows)
	_fill_distribution(sid)

func _fill_distribution(sid: String) -> void:
	if _dist_rows == null:
		return
	for c in _dist_rows.get_children():
		_dist_rows.remove_child(c)
		c.queue_free()
	var usage := _usage(sid)
	var dist: Dictionary = usage.get("by_map", {})
	# C3：读不出的源文件必须显形——否则「没有实例」是假的
	var unreadable: Array = usage.get("unreadable", [])
	if not unreadable.is_empty():
		_dist_rows.add_child(Kit.text_label(
			"⚠ 统计不完整：%d 张地图读不出来（%s），这些图的引用未计入" % [
				unreadable.size(), ", ".join(PackedStringArray(unreadable))],
			Th.WARN, Th.FS_SMALL))
	if dist.is_empty():
		_dist_rows.add_child(Kit.hint_label("没有已放置实例", 220))
		return
	var total := 0
	for map_name in dist:
		total += (dist[map_name] as Array).size()
		# 每张地图一个折叠段（默认收起，展开时才建行——懒构建）。
		_dist_rows.add_child(_dist_map_section(str(map_name), dist[map_name]))
	var foot := "共 %d 个实例 / %d 张地图 · 自带功能值在内容编辑器按实例填（未填的用声明默认值）" % [total, dist.size()]
	_dist_rows.add_child(Kit.hint_label(foot, 460))

## 单张地图的折叠段：标题按钮切换，首展时才构建行。
func _dist_map_section(map_name: String, rows: Array) -> Control:
	var box := Kit.vbox(2)
	var built := {"done": false}
	var body := Kit.vbox(2)
	body.visible = false
	var head := Kit.button(_dist_head_text(map_name, rows.size(), false), Callable(), "ghost")
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.pressed.connect(func():
		if not built.done:
			built.done = true
			for r in rows:
				body.add_child(_dist_row(map_name, r))
		body.visible = not body.visible
		head.text = _dist_head_text(map_name, rows.size(), body.visible))
	box.add_child(head)
	box.add_child(body)
	return box

func _dist_head_text(map_name: String, n: int, open: bool) -> String:
	return ("▾ " if open else "▸ ") + "%s × %d" % [map_name, n]

## 全项目使用统计（C3）：唯一实现是 ProjectAudit.asset_usage（与引用自检共用读盘），
## 这里只补「当前图以画布内存为底」的差异——磁盘底册+内存补丁的混合体
## 会让新增未保存的实例不出现、已删除的还留着。
func _usage(sid: String) -> Dictionary:
	var cur := ""
	var live_rows: Array = []
	if host != null and host.canvas != null and is_instance_valid(host.canvas):
		cur = str(host.cur_map_name)
		for e in host.canvas.ents_all():
			var n := e as EntityNode
			if n == null or n.asset != sid:
				continue
			var c: Vector2i = n.cell()
			live_rows.append({"id": n.code, "x": c.x, "y": c.y})
	return ProjectAudit.asset_usage(manifest, sid, cur, live_rows)

## 兼容旧调用（删除检查只看每图实例数）：{地图名: [{id,x,y}]}
func _instance_distribution(sid: String) -> Dictionary:
	return _usage(sid).get("by_map", {})

## 分布行（只读）：id · 坐标。值在内容编辑器按实例填，这里不再提供第二套编辑入口
## （旧 props.stats 双写就是两个编辑面各写各的造成的分裂）。
func _dist_row(map_name: String, r: Dictionary) -> Control:
	var row := Kit.hbox(10)
	var rid := str(r.get("id", ""))
	var ids := Kit.text_label(rid, Th.TEXT_MUTE, Th.FS_META)
	ids.custom_minimum_size = Vector2(84, 0)
	ids.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ids.tooltip_text = "%s  (%d,%d)" % [map_name, int(r.get("x", 0)), int(r.get("y", 0))]
	row.add_child(ids)
	var pos := Kit.text_label("(%d, %d)" % [int(r.get("x", 0)), int(r.get("y", 0))], Th.TEXT_MUTE, Th.FS_META)
	pos.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pos.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(pos)
	return row



## 删除资产前引用检查——列出仍在使用该类型的地图与实例数；有引用需确认
func _delete_asset_checked(sid: String) -> void:
	if bool(_edef.get("builtin", false)):
		host._set_status(" 内置种类由编辑器提供，不能删除")
		return
	# 有引用先列出来；没有引用也要问一次——删资产不可撤销
	var dist := _instance_distribution(sid)
	var permanent: bool = bool(_edef.get("disabled", false))
	var scanned_asset: bool = str(_edef.get("scanFingerprint", "")) != "" \
		or str(_edef.get("retiredPath", "")) != ""
	var text := ""
	if permanent:
		text = "将永久删除已停用资产「%s」(%s)，不可恢复。" % [str(_edef.get("name", sid)), sid]
	elif scanned_asset:
		# A4/D12：扫描资产「删除」= 停用记录（保 ID 可恢复）
		text = "将停用资产「%s」(%s)。\n\n条目与 ID 保留：不再出现在调色板，已有引用仍能定位；可随时重新启用。" % [str(_edef.get("name", sid)), sid]
	else:
		text = "将删除资产「%s」(%s)，不可撤销。" % [str(_edef.get("name", sid)), sid]
	if not dist.is_empty():
		var lines := []
		var total := 0
		for map_name in dist:
			var n: int = (dist[map_name] as Array).size()
			total += n
			lines.append("%s × %d" % [map_name, n])
		text += "\n\n还有 %d 张地图在用（共 %d 个实例）：%s。\n%s" % [dist.size(), total, ", ".join(lines),
			"停用后这些实体从调色板消失；引用仍按原 ID 解析。" if scanned_asset and not permanent \
			else "删除后这些实体失去调色板/占位框/导出依据。"]
	else:
		text += "\n\n当前没有地图实例在用它。"
	if not await host._confirm_action("删除资产", text, "删除"):
		return
	# 已停用的扫描条目：这一步是「永久删除」，真从清单里抹掉（用户已明确放弃）
	if permanent:
		manifest.get("assets", []).erase(_edef)
		save_manifest.call()
		_edef = {}
		refresh_list()
		return
	# 扫描产出的条目不 erase：记停用，保 ID 可恢复（D12）。
	# 否则源文件还在目录里，下次扫描就带新 ID 回来，旧引用全断。
	if scanned_asset:
		preload("res://src/project/asset_scan.gd").disable(manifest, sid)
		host._set_status(" 已停用资产 %s（条目保留，可在资产页恢复）" % sid)
	else:
		manifest.get("assets", []).erase(_edef)
	save_manifest.call()
	_edef = {}
	# 删除后留在图鉴：刷新列表并落到第一项（没有则给空态提示）
	refresh_list()

# —— 自带功能（挂载）编辑器 ——
## 挂载 = 类型自带的 functions 声明 id 列表；实例绑定在放置/载图时自动补齐（C09）。
## 声明本体（fields/kind/type）在清单 functions 池，属开发契约——这里只挂载，不编辑声明。
func _mount_rows(edef: Dictionary) -> void:
	for c in mounts_box.get_children():
		mounts_box.remove_child(c)
		c.queue_free()
	if edef.is_empty():
		return
	var mounted: Array = edef.get("functions", []) if (edef.get("functions", []) is Array) else []
	for mid in mounted:
		mounts_box.add_child(_mount_row(edef, str(mid)))
	if mounted.is_empty():
		mounts_box.add_child(Kit.hint_label("这个类型没有自带功能。", 420))
	_add_mount_row(edef, mounted)

## 单个挂载行：显示名 + 移除钮。
func _mount_row(edef: Dictionary, mid: String) -> Control:
	var row := Kit.hbox(8)
	var lbl := Kit.text_label(FunctionDecls.function_name(manifest, mid), Th.TEXT, Th.FS_SMALL)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.tooltip_text = mid
	row.add_child(lbl)
	row.add_child(Kit.del_button(func(): _unmount(edef, mid)))
	return row

## 底部添加行：下拉列出「已声明未挂载」的功能；选中即挂载（写清单）。
func _add_mount_row(edef: Dictionary, mounted: Array) -> void:
	var sel := OptionButton.new()
	sel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	sel.add_item("＋ 挂载功能…")
	var pool := FunctionDecls.functions(manifest)
	var any := false
	for k in pool.keys():
		if mounted.has(str(k)):
			continue
		var d: Dictionary = pool[k]
		sel.add_item(str(d.get("name", k)))
		sel.set_item_metadata(sel.get_item_count() - 1, str(k))
		any = true
	if not any:
		sel.disabled = true
		sel.tooltip_text = "声明池里没有可挂载的新功能了"
		sel.select(0)
		mounts_box.add_child(sel)
		return
	sel.item_selected.connect(func(idx: int):
		if idx == 0:
			sel.select(0)
			return
		var fid := str(sel.get_item_metadata(idx))
		var arr: Array = edef.get("functions", []) if (edef.get("functions", []) is Array) else []
		arr.append(fid)
		edef["functions"] = arr
		mounts_box.remove_child(sel)
		mounts_box.queue_redraw()
		_mount_rows(edef)
		save_manifest.call())
	sel.select(0)
	mounts_box.add_child(sel)

## 摘除挂载：从类型 functions 数组删 id；已有实例的绑定不受影响（绑定按码解析，码不变）。
func _unmount(edef: Dictionary, mid: String) -> void:
	var arr: Array = edef.get("functions", []) if (edef.get("functions", []) is Array) else []
	if not arr.has(mid):
		return
	arr.erase(mid)
	edef["functions"] = arr
	_mount_rows(edef)
	save_manifest.call()


## 资产缩略图：裁掉透明留白后再用。
## 预览图统一 96×96 画布 + 中间十几像素的图形，不裁的话列表里只剩一个点。
var _tex_cache := {}   # path→ImageTexture 缓存，同一图只读一次盘
func _asset_texture(edef: Dictionary) -> Texture2D:
	var rel := str(edef.get("thumb", ""))
	if rel == "":
		return null
	var p: String = str(manifest.get("_dir", "")).path_join(rel)
	if not FileAccess.file_exists(p):
		return null
	if _tex_cache.has(p):
		return _tex_cache[p]
	var img := Image.load_from_file(p)
	if img == null:
		return null
	var tex: ImageTexture = ImageTexture.create_from_image(ImageProbe.trim_alpha(img))
	_tex_cache[p] = tex
	return tex
