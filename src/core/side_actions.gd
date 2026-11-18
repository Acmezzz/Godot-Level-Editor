extends RefCounted
## _side_actions_ctrl：从 src/app.gd 拆出的控制器（审查 8.3 表）。宿主状态经 alias 引用。

var app   # 宿主引用

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
	# app 侧的地图身份也要同步：保存/试玩都以 app.cur_map_name 为准，不同步会写回旧文件名
	if app.cur_map_name == old_name:
		app.cur_map_name = new_name
		app.cur_map_path = app.MapStore.path_for(app.manifest, new_name)
	app._set_status("已改名：%s → %s（引用未迁移）" % [old_name, new_name])

## T16/K18（批次 10）：地图复制——文件级复制，引用原样保留在副本里。
func _duplicate_map_by_name(old_name: String, new_name: String) -> void:
	var err: String = app.MapStore.duplicate_map(app.manifest, old_name, new_name)
	if err != "":
		app._set_status("复制失败：" + err)
		return
	app._set_status("已创建副本：%s → %s" % [old_name, new_name])


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


## 收集校验问题（不落 UI）：内容编辑器弹窗与校验入口共用同一份数据源。
func _collect_issues(all_maps: bool) -> Array:
	var issues: Array = []
	if all_maps:
		issues = app.MapValidate.validate_all(app.manifest)
	else:
		if not app.map_loaded:
			return []
		var data = app.canvas.extract()
		issues = app.MapValidate.validate_map(app.manifest, app.cur_map_name, data)
	# 内容资源（对话/事件/商店/定义）与地图引用一起校验：只做一遍，避免单图模式漏掉跨资源问题
	var ContentValidate := preload("res://src/content/content_validate.gd")
	issues.append_array(ContentValidate.validate_all(app.manifest, app.manifest))
	return issues

## 校验入口：结果写状态栏（问题详情可从内容编辑器的校验弹窗看）。
func _run_validate(all_maps: bool) -> void:
	var issues: Array = _collect_issues(all_maps)
	if issues.is_empty() and not app.map_loaded:
		return
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
