extends RefCounted
## _side_actions_ctrl：从 src/app.gd 拆出的控制器。宿主状态经 app 引用。

var app   # 宿主引用

func _init(host) -> void:
	app = host
## 地图改名——纯 rename，不迁移引用（拍板）。当前图改名只更新名字记录。
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

## 地图复制——文件级复制，引用原样保留在副本里。
func _duplicate_map_by_name(old_name: String, new_name: String) -> void:
	var err: String = app.MapStore.duplicate_map(app.manifest, old_name, new_name)
	if err != "":
		app._set_status("复制失败：" + err)
		return
	app._set_status("已创建副本：%s → %s" % [old_name, new_name])


func _scene_name(sid: String) -> String:
	return preload("res://src/assets/asset_decl.gd").name_of(app.manifest, sid)


func _open_map_by_name(map_name: String) -> void:
	if map_name == app.cur_map_name:
		return
	if not await app._confirm_discard("打开地图 " + map_name):
		return
	var p := EditorManifest.map_path(app.manifest, map_name)
	if p == "" or not FileAccess.file_exists(p):
		app._set_status(" 地图不存在: " + map_name)
		return
	await app._load_map_file(p)


## （历史遗留：按 id 批量删实体的入口随旧面板删除，此控制器已无此职责）
