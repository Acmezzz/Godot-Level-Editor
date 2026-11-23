extends RefCounted
## _side_actions_ctrl：从 src/app.gd 拆出的控制器。宿主状态经 app 引用。

var app   # 宿主引用

func _init(host) -> void:
	app = host
## 地图改名/整图复制都不在控制器里：改名走 map_file.rename_map_now（改文件 + 同步身份），
## 复制走 map_file.on_duplicate（C2 整图克隆：新码/新内容/引用重映射）。这里不留第二套实现。


## 资产 id → 显示名（未声明时原样返回 id，便于发现清单缺失）
func _scene_name(aid: String) -> String:
	return preload("res://src/assets/asset_decl.gd").name_of(app.manifest, aid)


func _open_map_by_name(map_name: String) -> void:
	if map_name == app.cur_map_name:
		return
	# 先确认目标存在，再问「要不要丢改动」：目标不存在还先丢改动 = 白白损失工作
	var p := EditorManifest.map_path(app.manifest, map_name)
	if p == "" or not FileAccess.file_exists(p):
		app._set_status(" 地图不存在: " + map_name)
		return
	if not await app._confirm_discard("打开地图 " + map_name):
		return
	await app._load_map_file(p)


## （历史遗留：按 id 批量删实体的入口随旧面板删除，此控制器已无此职责）
