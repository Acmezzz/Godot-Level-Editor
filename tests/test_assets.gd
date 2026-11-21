extends "res://tests/_suite_base.gd"
## 资产表 assets[]：归一化、palette 展平、cell 尺寸、编辑期原件入口。

const AD := preload("res://src/assets/asset_decl.gd")
const ImageProbe := preload("res://src/assets/image_probe.gd")

func _m() -> Dictionary:
	return {
		"_dir": "/proj",
		"tileSize": 16,
		"assets": [
			{"id": "terrain", "kind": "scene", "shape": "tile", "name": "地形",
				"atlas": "a/terrain.png", "cell": {"w": 16, "h": 32},
				"palette": [{"cell": [0, 0], "name": "草", "cat": "地面"},
					{"cell": [1, 0], "name": "石"}],
				"custom": "游戏侧自定义键"},
			{"id": "bg", "kind": "scene", "shape": "image", "name": "背景",
				"texture": "a/bg.png", "editorSize": [640, 360], "anchor": "top_left"},
			{"id": "door", "kind": "entity", "name": "门", "prefab": "p/door.tscn", "code": "D111"},
		],
	}

func test_kind_split() -> void:
	var m := _m()
	eq(AD.all(m).size(), 3, "三条资产")
	eq(AD.is_entity(m, "door"), true, "door 是实体")
	eq(AD.is_entity(m, "terrain"), false, "terrain 是场景")
	eq(AD.of_kind(m, "entity").size(), 1, "实体过滤")
	eq(AD.tile_sets(m).size(), 1, "图集型场景只有一个")

func test_unknown_keys_preserved() -> void:
	eq(str(AD.by_id(_m(), "terrain").get("custom", "")), "游戏侧自定义键", "未知键保留")

func test_palette_flatten() -> void:
	var pal := AD.palette_of(_m(), "terrain")
	eq(pal.size(), 2, "palette 两条")
	eq(pal[0].cell, Vector2i(0, 0), "cell 转 Vector2i")
	eq(str(pal[0].cat), "地面", "cat")
	eq(str(pal[1].cat), "", "无 cat = 空串（调用方用图集名兜底）")

func test_cell_size_non_square() -> void:
	eq(AD.cell_size(_m(), "terrain"), Vector2i(16, 32), "非正方形 cell 原样取出")
	# 未声明 cell 时退回地图格
	var m2 := _m()
	(m2.assets[0] as Dictionary).erase("cell")
	eq(AD.cell_size(m2, "terrain"), Vector2i(16, 16), "缺省带回落 tileSize")

func test_editor_size_and_instance_size() -> void:
	eq(AD.editor_size(_m(), "bg"), Vector2(640, 360), "editorSize 原样")
	eq(AD.instance_size(_m(), "bg", {}, Vector2(16, 16)), Vector2(640, 360), "无 sizeFields 用 editorSize")
	var m2 := _m()
	(m2.assets[1] as Dictionary)["sizeFields"] = ["w", "h"]
	eq(AD.instance_size(m2, "bg", {"w": 3, "h": 2}, Vector2(16, 16)), Vector2(48, 32), "sizeFields 读 props 格数")
	eq(AD.instance_size(m2, "bg", {"w": 0, "h": -5}, Vector2(16, 16)), Vector2(16, 16), "非法格数兜底 1 格")

func test_live_list_is_original() -> void:
	var m := _m()
	var live := AD.live_by_id(m, "door")
	live["name"] = "改过的门"
	eq(str(AD.live_by_id(m, "door").get("name")), "改过的门", "编辑期入口直接改清单原件")
	# 归一化视图必须深拷贝：改视图不能污染清单原件（否则 UI 一读就把数据写坏）
	AD.by_id(m, "door")["name"] = "视图里改的"
	eq(str(AD.live_by_id(m, "door").get("name")), "改过的门", "归一化视图是深拷贝")

func test_mounts_filter_undeclared() -> void:
	var m := _m()
	(m.assets[2] as Dictionary)["functions"] = ["f1", "nope"]
	m["functions"] = {"f1": {"name": "F", "code": "F111"}}
	var mounts := AD.mounts(m, "door")
	eq(mounts.size(), 1, "未声明的挂载被过滤")
	eq(str(mounts[0].get("code")), "F111", "挂载带执行码")

## A4：prefab 探针按节点块解析，首个 CollisionShape2D 挂在未挂载节点下时不采用。
const TMP := "user://test_assets_tmp"

func _mk(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(TMP.path_join(rel).get_base_dir())
	var f := FileAccess.open(TMP.path_join(rel), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()

func _wipe() -> void:
	for f in DirAccess.get_files_at(TMP):
		DirAccess.remove_absolute(TMP.path_join(str(f)))
	for d in DirAccess.get_directories_at(TMP):
		_wipe_dir(TMP.path_join(str(d)))
	DirAccess.remove_absolute(TMP)

func _wipe_dir(p: String) -> void:
	for f in DirAccess.get_files_at(p):
		DirAccess.remove_absolute(p.path_join(str(f)))
	for d in DirAccess.get_directories_at(p):
		_wipe_dir(p.path_join(str(d)))
	DirAccess.remove_absolute(p)

func test_prefab_probe_skips_unmounted_shape() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_mk("assets/entities/two.tscn", """[gd_scene load_steps=3 format=3]

[sub_resource type="RectangleShape2D" id="Shape_big"]
size = Vector2(64, 64)

[sub_resource type="RectangleShape2D" id="Shape_ok"]
size = Vector2(24, 12)

[node name="Root" type="Node2D"]

[node name="Ghost" type="Node2D" parent="MissingParent"]

[node name="GhostShape" type="CollisionShape2D" parent="MissingParent"]
shape = SubResource("Shape_big")

[node name="Body" type="Area2D" parent="."]

[node name="BodyShape" type="CollisionShape2D" parent="Body"]
shape = SubResource("Shape_ok")
""")
	eq(ImageProbe.prefab_collision_size(TMP, "assets/entities/two.tscn"), Vector2(24, 12),
		"取已挂载节点的形状，不取未挂载的首个 CollisionShape2D")
	# 嵌套 parent 写的是完整路径（"Body/Arm"）：必须按路径求可达
	_mk("assets/entities/nested.tscn", """[gd_scene load_steps=3 format=3]

[sub_resource type="RectangleShape2D" id="Shape_arm"]
size = Vector2(8, 10)

[sub_resource type="RectangleShape2D" id="Shape_body"]
size = Vector2(40, 40)

[node name="Root" type="Node2D"]

[node name="Body" type="Area2D" parent="."]

[node name="Arm" type="Node2D" parent="Body"]

[node name="ArmShape" type="CollisionShape2D" parent="Body/Arm"]
shape = SubResource("Shape_arm")

[node name="BodyShape" type="CollisionShape2D" parent="Body"]
shape = SubResource("Shape_body")
""")
	eq(ImageProbe.prefab_collision_size(TMP, "assets/entities/nested.tscn"), Vector2(8, 10),
		"嵌套路径 parent 也判定为已挂载（按文件顺序取首个挂载形状）")
	_wipe()
