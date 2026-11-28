extends VBoxContainer
## 资产目录（工作台 →「资产」）：左列图鉴（图集 / 场景图片 / 实体三类都在），右侧详情。
## 资产声明的变更经应用写入项目清单。

const ImageProbe := preload("res://src/assets/image_probe.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const AssetScan := preload("res://src/project/asset_scan.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const BuiltinKinds := preload("res://src/assets/builtin_kinds.gd")
const ReferenceUsage := preload("res://src/project/reference_usage.gd")   # 使用统计（C3）
const Catalog := preload("res://src/content/authoring_catalog.gd")

var manifest := {}
var host = null  # 宿主 app（确认框复用其链路）

var asset_list: ItemList
var _filter_edit: LineEdit
var _filter_category: OptionButton
var _filter_used: CheckBox
var mounts_box: VBoxContainer
var mounts_section: VBoxContainer
var name_edit: LineEdit
var thumb: TextureRect
var _detail_hint: Label
var _detail_scroll: ScrollContainer
var _empty: VBoxContainer
var _asset_count: Label
var _asset_id: Label
var _preview_label: Label
var _selected_asset := ""
var extra: VBoxContainer

var _edef: Dictionary = {}
var _loading := false
## 建详情时的名字基线：写盘失败要能退回（否则失败的名字留在内存里，别处保存会带进清单）。
var _edef_name_before := ""

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

	var left_wrap := Kit.frame(SIDE_RIGHT, 12, 12)
	left_wrap.custom_minimum_size.x = 274
	detail_view.add_child(left_wrap)
	var left := Kit.vbox(8)
	left_wrap.add_child(left)
	var list_head := Kit.hbox()
	list_head.add_child(Kit.section_label("资产目录"))
	list_head.add_child(Kit.spacer())
	_asset_count = Kit.text_label("", Th.TEXT_DIM, Th.FS_SMALL)
	list_head.add_child(_asset_count)
	left.add_child(list_head)
	_filter_category = OptionButton.new()
	for label in ["全部类别", "瓦片", "图片", "实体"]:
		_filter_category.add_item(label)
	_filter_category.item_selected.connect(func(_i: int): refresh_list())
	left.add_child(_filter_category)
	_filter_used = CheckBox.new()
	_filter_used.text = "只看当前地图已用"
	_filter_used.toggled.connect(func(_on: bool): refresh_list())
	left.add_child(_filter_used)
	# 过滤视图：名称/id 关键字过滤（资产多起来后的基本效率件）
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "搜索资产名称或 ID"
	_filter_edit.clear_button_enabled = true
	_filter_edit.text_changed.connect(func(_t: String): refresh_list())
	left.add_child(_filter_edit)
	asset_list = ItemList.new()
	asset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	asset_list.icon_mode = ItemList.ICON_MODE_LEFT
	asset_list.fixed_icon_size = Vector2i(40, 40)
	asset_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	asset_list.item_selected.connect(func(idx: int):
		_show_detail(str(asset_list.get_item_metadata(idx))))
	left.add_child(asset_list)

	var right := Kit.vbox()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_view.add_child(right)
	_empty = Kit.empty_state("", "没有资产", "在游戏工程中声明资产后，回到这里查看。")
	_empty.hide()
	right.add_child(_empty)
	var detail_scroll := ScrollContainer.new()
	_detail_scroll = detail_scroll
	detail_scroll.follow_focus = true
	detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(detail_scroll)
	var det_margin := MarginContainer.new()
	det_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	det_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	det_margin.add_theme_constant_override("margin_left", 18)
	det_margin.add_theme_constant_override("margin_right", 18)
	det_margin.add_theme_constant_override("margin_top", 14)
	det_margin.add_theme_constant_override("margin_bottom", 18)
	detail_scroll.resized.connect(func():
		det_margin.add_theme_constant_override("margin_right", maxi(18, int(detail_scroll.size.x) - 900)))
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
	det.move_child(_detail_hint, 0)
	var thumb_wrap := PanelContainer.new()
	thumb_wrap.add_theme_stylebox_override("panel", Th.box(Th.BG_VOID, Th.BORDER, Th.R_CONTAINER, 8, 8))
	hdr.add_child(thumb_wrap)
	thumb = TextureRect.new()
	thumb.custom_minimum_size = Vector2(144, 144)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb_wrap.add_child(thumb)
	_preview_label = Kit.hint_label("无图片预览")
	_preview_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preview_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb_wrap.add_child(_preview_label)

	var name_box := Kit.vbox(8)
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	hdr.add_child(name_box)
	name_box.add_child(Kit.section_label("资产详情"))
	_asset_id = Kit.clipped_label("", Th.TEXT_DIM, Th.FS_SMALL)
	name_box.add_child(_asset_id)
	name_edit = LineEdit.new()
	name_edit.add_theme_font_size_override("font_size", Th.FS_LG)
	name_box.add_child(name_edit)
	name_edit.placeholder_text = "资产显示名"
	name_box.add_child(Kit.hint_label("修改显示名后，按 Enter 或离开输入框保存。"))

	mounts_section = Kit.vbox(6)
	det.add_child(mounts_section)
	mounts_section.add_child(Kit.section_label("自带功能"))
	mounts_section.add_child(Kit.hint_label(
		"所有此类实例都带有这些功能；在内容工作区为各实例填写参数。"))
	mounts_box = Kit.vbox(6)
	mounts_section.add_child(mounts_box)

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

## 名称提交（写盘）。写失败不留「看起来已保存」的假象：把名字退回提交前的值并重建详情。
func _commit_name() -> void:
	if _edef.is_empty() or _loading or str(_edef.get("name", _edef_name_before)) == _edef_name_before:
		return
	var sid := str(_edef.get("id", ""))
	if await host._save_manifest_file_async():
		refresh_list(sid)
		return
	# 写盘失败（状态栏已报原因）：内存里改过的名字不能留着，否则别处保存会把失败值带进清单
	var name_now := str(_edef.get("name", ""))
	if name_now != _edef_name_before:
		_edef["name"] = _edef_name_before
		refresh_list(sid)

# —— 视图切换 ——
func show_detail(sid: String) -> void:
	refresh_list(sid)

# —— 图鉴列表 ——
## 图鉴列表：focus_sid 显式定位；空 = 保留当前选中（E1：切去内容/关卡再回来
## 仍停在同一份资产上，不悄悄跳回第一项）。选中项已不存在时才落到第一项。
func refresh_list(focus_sid := "") -> void:
	var keep := focus_sid
	if keep == "":
		keep = _selected_asset
	asset_list.clear()
	var focus_idx := -1
	var idx := 0
	# 图鉴 = 清单里的全部非内置资产（实体 + 场景/图集）：只列实体会让瓦片/装饰资产
	# 在编辑器里既搜不到也看不了引用，删/停用也没有入口（V4 P1）。of_kind("") = 不限种类。
	_filter_used.disabled = host == null or not host.map_loaded
	var data: Dictionary = host.canvas.map_data if not _filter_used.disabled else {}
	for row in Catalog.asset_rows(manifest, data):
		var edef: Dictionary = row.decl
		var sid := str(edef.get("id", ""))
		if BuiltinKinds.is_injected(manifest, sid):
			continue
		if (_filter_category.selected > 0 and row.category != _filter_category.get_item_text(_filter_category.selected)) \
				or (_filter_used.button_pressed and not _filter_used.disabled and row.used == 0):
			continue
		if not _matches_filter(sid, edef as Dictionary):
			continue
		asset_list.add_item(_list_label(sid, edef as Dictionary), _asset_texture(edef))
		# tooltip 露出 id、类别与停用状态——地图数据引用的是 id，界面上看不到就没法排查
		# P03：循环里已握着归一化声明，类别直接取，不再按 id 回查整表
		var tip := "%s · %s · %s" % [AssetDecl.category_of_decl(edef as Dictionary), sid,
			str((edef as Dictionary).get("name", sid))]
		if bool((edef as Dictionary).get("disabled", false)):
			tip += "\n已停用：不进调色板，原 ID 保留"
		asset_list.set_item_tooltip(idx, tip)
		asset_list.set_item_metadata(idx, sid)
		if sid == keep:
			focus_idx = idx
		idx += 1
	_asset_count.text = str(asset_list.item_count)
	if focus_idx < 0 and asset_list.item_count > 0:
		focus_idx = 0
	if focus_idx >= 0:
		asset_list.select(focus_idx)
		asset_list.ensure_current_is_visible()
		_show_detail(str(asset_list.get_item_metadata(focus_idx)))
		if _filter_edit.text.strip_edges() != "" and keep != "":
			_selected_asset = keep
	else:
		# 列表空（含「删掉最后一个资产」）：右栏必须走空态，否则名称框/挂载/分布/删除按钮
		# 全部滞留上一项，残留闭包还会往已 erase 的字典里写。
		_show_detail("")

## 停用的资产在图鉴保留原 ID 和标记。
func _list_label(sid: String, edef: Dictionary) -> String:
	# E3：显示名走共用查询（AssetDecl.label），与画布选材同一口径
	# P03：循环里已握着归一化声明，直接取，不再按 id 回查整表
	var nm := AssetDecl.label_of_decl(edef, sid)
	if bool(edef.get("disabled", false)):
		return "⊗ " + nm + "（已停用）"
	return nm

## 过滤视图：名称/id 任一包含关键字（大小写不敏感）。
## 名称查询同走 AssetDecl.label：未填 name 的资产按 id 也能被搜到。
func _matches_filter(sid: String, edef: Dictionary) -> bool:
	var q := str(_filter_edit.text).strip_edges().to_lower()
	if q == "":
		return true
	return q in ("%s %s %s" % [sid, AssetDecl.label_of_decl(edef, sid), edef.get("tags", [])]).to_lower()

func _show_detail(sid: String) -> void:
	# 清单原件（不是归一化副本）：名称/挂载的改动要直接写回 assets[]
	_edef = AssetDecl.live_by_id(manifest, sid)
	_detail_scroll.visible = not _edef.is_empty()
	_empty.visible = _edef.is_empty()
	_empty.get_node("Title").text = "没有匹配的资产" if _filter_edit.text.strip_edges() != "" else "还没有资产"
	_empty.get_node("Hint").text = "清空搜索，或换一个关键词。" if _filter_edit.text.strip_edges() != "" \
		else "在游戏工程中声明资产后，回到这里查看。"
	if _edef.is_empty():
		# 空匹配（例如详情里删掉了当前资产）不能留上一项的陈旧数据
		name_edit.text = ""
		thumb.texture = null
		_mount_rows({})
		# extra 里挂着资产操作按钮，也必须清掉
		for child in extra.get_children():
			extra.remove_child(child)
			child.queue_free()
		_detail_hint.text = "没有匹配的资产"
		_detail_hint.visible = true
		return
	if _selected_asset != sid:
		_detail_scroll.scroll_vertical = 0
	_selected_asset = sid
	_asset_id.text = "资产 ID · " + sid
	_asset_id.tooltip_text = sid
	_detail_hint.visible = false
	if bool(_edef.get("disabled", false)):
		_detail_hint.text = "已停用：不进调色板，但保留原 ID；重新启用即恢复。"
		_detail_hint.visible = true
	_loading = true
	_edef_name_before = str(_edef.get("name", sid))
	name_edit.text = _edef_name_before
	thumb.texture = _asset_texture(_edef)
	_preview_label.visible = thumb.texture == null
	_mount_rows(_edef)
	for child in extra.get_children():
		extra.remove_child(child)
		child.queue_free()
	_add_config_section(sid)
	var discoverable := AssetScan.will_rediscover(manifest, _edef)
	if bool(_edef.get("disabled", false)):
		extra.add_child(Kit.button("重新启用", func(): _enable_asset(sid), "primary"))
		if discoverable:
			_loading = false
			return
	var del := Kit.button("停用资产" if discoverable else "删除此资产",
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
		var go := Kit.button("在地图上使用", func(): _use_on_canvas(sid), "plain")
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
		host._editor_state_ctrl.set_brush("tiles")
		host._editor_state_ctrl.sync_ui()
		host._set_status("画布笔刷已设为瓦片资产 %s（切片 %d,%d）" % [AssetDecl.label(manifest, sid), cell.x, cell.y])
	else:
		host.canvas.stamp_asset = sid
		host.canvas.stamp_thumb = _asset_texture(d)
		host._editor_state_ctrl.set_brush("object")
		host._editor_state_ctrl.sync_ui()
		host._set_status("画布笔刷已设为 %s：在画布上点一下即可摆放" % AssetDecl.label(manifest, sid))
	host._set_mode("map")

func _enable_asset(sid: String) -> void:
	var candidate := manifest.duplicate(true)
	AssetDecl.live_by_id(candidate, sid).erase("disabled")
	if await host._save_manifest_file_async(Callable(), candidate, "assets"):
		refresh_list(sid)

## 删除资产前引用检查——列出仍在使用该类型的地图与实例数；有引用需确认
func _deletion_usage(sid: String) -> Dictionary:
	var live: Dictionary = host.canvas.extract() if host.map_loaded else {}
	if host.map_loaded and live.is_empty():
		return {"bad": [{"name": "当前地图重建中"}]}
	var staged: Array = []
	if host.project_shell != null and host.project_shell.content_editor != null:
		staged = host.project_shell.content_editor.staged_rows_current_doc()
	return ReferenceUsage.asset_deletion_usage(manifest, sid, live, staged)

func _delete_asset_checked(sid: String) -> void:
	if BuiltinKinds.is_injected(manifest, sid):
		host._set_status(" 内置种类由编辑器提供，不能删除")
		return
	var source := manifest
	var original := AssetDecl.live_by_id(source, sid)
	if original.is_empty() or not is_same(original, _edef):
		return
	var baseline := original.duplicate(true)
	var erase_will_dangle := not AssetScan.will_rediscover(source, original)
	var usage := _deletion_usage(sid) if erase_will_dangle else {}
	var views: Array = usage.get("views", [])
	if not views.is_empty():
		host._set_status("参考视图「%s」仍在使用此资产（共 %d 处）：%s。请先修改引用。" %
			[views[0].view, views.size(), views[0].path])
		return
	var bad: Array = usage.get("bad", [])
	if not bad.is_empty():
		host._set_status("无法完整检查资产引用：%s（共 %d 处），删除已中止" % [bad[0].get("name", ""), bad.size()])
		return
	var c_refs: Array = usage.get("contents", [])
	var d_refs: Array = usage.get("drafts", [])
	var text := ""
	if not erase_will_dangle:
		text = "将停用资产「%s」(%s)。\n\n条目与 ID 保留：不再出现在调色板，已有引用仍能定位；可随时重新启用。" % [str(_edef.get("name", sid)), sid]
	else:
		text = "将删除资产「%s」(%s)，不可撤销。" % [str(_edef.get("name", sid)), sid]
	var maps: Dictionary = usage.get("maps", {})
	if erase_will_dangle:
		var lines: PackedStringArray = []
		for map_name in maps:
			lines.append("%s × %d" % [map_name, maps[map_name]])
		var live_count := int(usage.get("live", 0))
		if not lines.is_empty():
			text += "\n\n正式地图中的受影响条目（含瓦片与实例）：%s。" % ", ".join(lines)
		if live_count > 0:
			text += "\n当前画布另计 %d 个受影响条目（可与正式地图重叠）。" % live_count
	if erase_will_dangle and not c_refs.is_empty():
		var crefs: Array[String] = []
		for r in c_refs:
			crefs.append("%s/%s.%s" % [str((r as Dictionary).get("kind", "")),
				str((r as Dictionary).get("id", "")), str((r as Dictionary).get("field", ""))])
		text += "\n\n有 %d 份内容的引用字段指向它（%s）：删除后这些字段悬空。" % [
			c_refs.size(), ", ".join(PackedStringArray(crefs.slice(0, 5)))]
	if erase_will_dangle and not d_refs.is_empty():
		text += "\n\n草稿（%s）里也在用它：删除后恢复草稿会带回悬空引用。" % \
			", ".join(PackedStringArray(d_refs.slice(0, 5)))
	if not await host._confirm_action("删除资产", text, "删除"):
		return
	var guard := func() -> bool:
		return is_same(host.manifest, source) and is_same(AssetDecl.live_by_id(source, sid), original) \
			and original == baseline and (not erase_will_dangle or _deletion_usage(sid) == usage)
	if not guard.call():
		host._set_status("确认期间资产或引用已变更，请重新检查")
		return
	var candidate := source.duplicate(true)
	if erase_will_dangle:
		(candidate.assets as Array).erase(AssetDecl.live_by_id(candidate, sid))
	else:
		var row := AssetDecl.live_by_id(candidate, sid)
		row["disabled"] = true
	if not await host._save_manifest_file_async(guard, candidate, "assets"):
		return
	_edef = {}
	refresh_list()
	host._set_status("已删除资产 %s" % sid if erase_will_dangle else "已停用资产 %s（可恢复）" % sid)

# —— 自带功能编辑器 ——
## 挂载 = 类型自带的 functions 声明 id 列表；实例绑定在放置/载图时自动补齐（C09）。
## 声明本体（fields/kind/type）在清单 functions 池，属开发契约——这里只挂载，不编辑声明。
func _mount_rows(edef: Dictionary) -> void:
	for c in mounts_box.get_children():
		mounts_box.remove_child(c)
		c.queue_free()
	mounts_section.visible = edef.get("kind") == "entity"
	if not mounts_section.visible:
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
		await host._save_manifest_file_async())
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
	await host._save_manifest_file_async()


## 资产缩略图：裁掉透明留白后再用。
## 预览图统一 96×96 画布 + 中间十几像素的图形，不裁的话列表里只剩一个点。
var _tex_cache := {}   # path→ImageTexture 缓存，同一图只读一次盘
func _asset_texture(edef: Dictionary) -> Texture2D:
	var rel := str(edef.get("thumb", ""))
	if rel == "" and edef.get("kind") == "scene":
		rel = str(edef.get("atlas" if edef.get("shape") == "tile" else "texture", ""))
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
