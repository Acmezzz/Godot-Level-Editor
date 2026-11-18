extends RefCounted
## _side_actions_ctrl：从 src/app.gd 拆出的控制器（审查 8.3 表）。宿主状态经 alias 引用。

var app   # 宿主引用
const MapExport := preload("res://src/map_export.gd")

func _init(host) -> void:
	app = host
## T16/K18（批次 10）：地图改名——纯 rename，不迁移引用（拍板）。当前图改名只更新名字记录。
func _rename_map_by_name(old_name: String, new_name: String) -> void:
	if app.manifest.is_empty() or app.map_loaded == false:
		app._set_status("无项目/无地图上下文：改名被跳过")
		return
	var err: String = app.MapStore.rename_map(app.manifest, old_name, new_name)
	if err != "":
		app._set_status("改名失败：" + err)
		return
	if app.canvas.cur_map_name == old_name:
		app.canvas.cur_map_name = new_name
		app.canvas.map_data["meta"]["name"] = new_name
	_refresh_side_panel()
	app._set_status("已改名：%s → %s（引用未迁移）" % [old_name, new_name])

## T16/K18（批次 10）：地图复制——文件级复制，引用原样保留在副本里。
func _duplicate_map_by_name(old_name: String, new_name: String) -> void:
	var err: String = app.MapStore.duplicate_map(app.manifest, old_name, new_name)
	if err != "":
		app._set_status("复制失败：" + err)
		return
	_refresh_side_panel()
	app._set_status("已创建副本：%s → %s" % [old_name, new_name])

func _refresh_side_panel() -> void:
	if app.side_panel == null:
		return
	# PF-05：一次刷新链共享同一份 read_all（旧实现逐图 read，世界页再读一遍 = 每图 2 遍）
	var bad: Array = []
	var all = app.MapStore.read_all(app.manifest, bad)
	var list := []
	for name in all:
		var d = all[name]
		var meta: Dictionary = d.get("meta", {})
		list.append({
			"name": name,
			"w": int(meta.get("w", 0)),
			"h": int(meta.get("h", 0)),
			"ents": (d.get("entities", []) as Array).size(),
		})
	# P-03：坏图不再隐身——列表里也可见（打开时走 graceful 空图）
	for b in bad:
		list.append({"name": str(b.get("name", "")), "w": 0, "h": 0, "ents": 0})
	# 缺口4：缩略图（1px/格小图作列表图标；render_preview 只遍历已用格，开销小；超大图跳过）
	var thumbs := {}
	for nm in all:
		var td: Dictionary = all[nm]
		var tm: Dictionary = td.get("meta", {})
		var tw := maxi(int(tm.get("w", 1)), 1)
		var th := maxi(int(tm.get("h", 1)), 1)
		if tw * th > 65536:
			continue
		thumbs[str(nm)] = ImageTexture.create_from_image(MapExport.render_preview(td, 1, app.canvas.atlas_imgs, int(app.manifest.get("tileSize", 16))))
	# 缺口3：草稿提醒——比正式文件新的自动草稿（有未落盘的工作），置顶展示
	var drafts := []
	var maps_dir := str(app.manifest.get("_maps_dir", ""))
	if maps_dir != "" and DirAccess.dir_exists_absolute(maps_dir):
		for f in DirAccess.get_files_at(maps_dir):
			if not str(f).ends_with(".autosave.json"):
				continue
			var dn := str(f).trim_suffix(".autosave.json")
			var dp := maps_dir.path_join(str(f))
			var real_p := maps_dir.path_join(dn + ".json")
			var real_t := FileAccess.get_modified_time(real_p) if FileAccess.file_exists(real_p) else 0
			if FileAccess.get_modified_time(dp) > real_t:
				drafts.append({"name": dn, "path": dp})
	app.side_panel.set_maps(list, app.cur_map_name, thumbs, drafts)
	_refresh_levels_view()
	_refresh_world(all)
	_refresh_entity_outline()

## 关卡清单面板现在住在项目页外壳里（levels_panel.gd），可能还没建好
func _levels_panel():
	return app.project_shell.levels_panel if app.project_shell != null else null

func _refresh_levels_view() -> void:
	var lp = _levels_panel()
	if lp != null:
		lp.set_levels(app.LevelList.load_levels(app.manifest), app.manifest)

## 刷新「世界地图」页：拓扑 + 可达性（仅银河城模式检查可达性）

func _refresh_world(all = {}) -> void:
	var lp = _levels_panel()
	if lp == null:
		return
	var levels = app.LevelList.load_levels(app.manifest)
	var graph = app.LevelList.build_world_graph(app.manifest, levels, all)
	var unreachable := []
	var start := str(levels.get("start", ""))
	if str(levels.get("mode", "")) == "metroidvania" and start != "":
		unreachable = app.LevelList.unreachable_maps(graph, start)
	lp.set_world(graph, app.cur_map_name, unreachable)

## 保存关卡清单到 <项目>/editor/levels.json

func _save_levels(data: Dictionary) -> void:
	# 先剔除已不存在的地图条目，避免清单指向空气
	var maps = app.MapStore.list_maps(app.manifest)
	var kept := []
	var dropped := []
	for lv in data.get("levels", []):
		var nm := str(lv.get("map", ""))
		if maps.has(nm):
			kept.append(lv)
		else:
			dropped.append(nm)
	data["levels"] = kept
	if not app.LevelList.save_levels(app.manifest, data):
		app._set_status("关卡清单保存失败")
		return
	var mode_text := "大地图" if str(data.get("mode", "")) == "metroidvania" else "选关"
	app._set_status("关卡清单已保存（%s 模式，%d 关）" % [mode_text, kept.size()])
	if not dropped.is_empty():
		app.status.text += "；已剔除不存在的地图: " + ", ".join(dropped)
	_refresh_levels_view()
	_refresh_world()


func _refresh_entity_outline() -> void:
	if app.side_panel == null or not app.map_loaded or app.canvas.entities == null:
		return
	var out := []
	for e in app.canvas.entities.get_children():
		var spr := e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		var sid := str(spr.get_meta("scene", ""))
		var c = app.canvas._cell_of(spr.position)
		out.append({
			"id": str(spr.get_meta("ent_id", "")),
			"scene": sid,
			"name": _scene_name(sid),
			"x": c.x,
			"y": c.y,
		})
	app.side_panel.set_entities(out)


func _scene_name(sid: String) -> String:
	for e in app.manifest.get("entities", []):
		if str(e.get("id", "")) == sid:
			return str(e.get("name", sid))
	return sid


func _open_map_by_name(map_name: String) -> void:
	if map_name == app.cur_map_name:
		return
	if not await app._confirm_discard("打开地图 " + map_name):
		return
	var p := EditorManifest.map_path(app.manifest, map_name)
	if p == "" or not FileAccess.file_exists(p):
		app._set_status(" 地图不存在: " + map_name)
		return
	app._load_map_file(p)

## 点击实体大纲条目 → 视野对准该实体。
## 不清空已有框选：列表里 Ctrl/Shift 多选后还要能做批量操作，
## 一次点击就把选择重置掉会让「多选 → 批量编辑」没法用。

func _focus_entity(ent_id: String) -> void:
	if not app.map_loaded:
		return
	for e in app.canvas.entities.get_children():
		var spr := e as Sprite2D
		if spr and str(spr.get_meta("ent_id", "")) == ent_id:
			app.canvas.cam_pos = spr.position
			app.canvas._update_cam()
			app.canvas.flash_entity(ent_id, 3000)
			# 已在框选集合里就保留整组；否则设为单选
			if not app.canvas.selected_multi.has(spr):
				app.canvas.selected_entity = spr
				app.canvas.selected_multi = [spr]
			else:
				app.canvas.selected_entity = spr
			app.canvas.entity_selected.emit(spr)
			app._set_status(" 已定位 " + ent_id)
			return
	app._set_status(" 找不到实体 " + ent_id)


func _delete_entities_by_id(ids: Array) -> void:
	if not app.map_loaded or ids.is_empty():
		return
	app.canvas._push_undo()
	var victims := []
	for e in app.canvas.entities.get_children():
		var spr := e as Sprite2D
		if spr and ids.has(str(spr.get_meta("ent_id", ""))):
			victims.append(spr)
# BUG-08：悬空引用清理——被删实体不能留在选区里，否则属性面板会对已 free 节点写 props
	var victims_set := {}
	for v in victims:
		victims_set[v] = true
		app.canvas.entities.remove_child(v)
		v.free()
	app.canvas.selected_multi = app.canvas.selected_multi.filter(func(s): return is_instance_valid(s) and not victims_set.has(s))
	if is_instance_valid(app.canvas.selected_entity) and victims_set.has(app.canvas.selected_entity):
		app.canvas.selected_entity = null
	if app.selected_spr != null and (not is_instance_valid(app.selected_spr) or victims_set.has(app.selected_spr)):
		app.selected_spr = null
	app.canvas._mark()
	app._set_status(" 已删除 %d 个实体" % victims.size())
	_refresh_entity_outline()
	# B8：批量删除后立即重建属性面板（不再显示已删实体的陈旧 UI）
	app._rebuild_props_panel()


## 收集校验问题（不落 UI）：内容编辑器弹窗与隐藏侧栏共用同一份数据源。
func _collect_issues(all_maps: bool) -> Array:
	var issues: Array = []
	if all_maps:
		issues = app.MapValidate.validate_all(app.manifest)
	else:
		if not app.map_loaded:
			return []
		var data = app.canvas.extract()
		issues = app.MapValidate.validate_map(app.manifest, app.cur_map_name, data)
	# 关卡清单永远一起校验（它描述的是整体组织，与单图/全图正交）
	issues.append_array(app.MapValidate.validate_levels(app.manifest, app.LevelList.load_levels(app.manifest)))
	# 内容资源（对话/事件/商店/定义）与地图引用一起校验：只做一遍，避免单图模式漏掉跨资源问题
	var ContentValidate := preload("res://src/content/content_validate.gd")
	issues.append_array(ContentValidate.validate_all(app.manifest, app.manifest))
	return issues

## 落 UI 的旧入口：隐藏侧栏的问题页签还消费它（visible=false，刷新链仍在用）。
func _run_validate(all_maps: bool) -> void:
	var issues: Array = _collect_issues(all_maps)
	if issues.is_empty() and not app.map_loaded:
		return
	app.side_panel.set_issues(issues)
	app.side_panel.select_tab(2)
	var errors := 0
	for it in issues:
		if str(it.get("level", "")) == "error":
			errors += 1
	app._set_status(" 校验完成：%d 个问题（%d 个错误）" % [issues.size(), errors])


func _focus_issue(map_name: String, ent_id: String) -> void:
	if map_name == "" or ent_id == "":
		return
	if map_name != app.cur_map_name:
		await _open_map_by_name(map_name)
	if map_name == app.cur_map_name:
		_focus_entity(ent_id)
