extends "res://tests/_suite_base.gd"
## AssetScan 扫描制用例（临时目录 user://test_asset_scan_tmp，用例自清理）：
## 发现新资源，保留已登记的路径和 ID。

const AssetScan := preload("res://src/project/asset_scan.gd")

const TMP := "user://test_asset_scan_tmp"

func _nuke(p: String) -> void:
	if not DirAccess.dir_exists_absolute(p):
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		return
	for f in DirAccess.get_files_at(p):
		DirAccess.remove_absolute(p.path_join(str(f)))
	for d in DirAccess.get_directories_at(p):
		_nuke(p.path_join(str(d)))
	DirAccess.remove_absolute(p)

func _mk(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(TMP.path_join(rel).get_base_dir())
	var f := FileAccess.open(TMP.path_join(rel), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()

func test_scan_add_codes() -> void:
	_nuke(TMP)
	_mk("assets/tiles/a.png", "A")
	_mk("assets/tiles/sub/b.jpg", "B")
	_mk("assets/images/c.png", "C")
	_mk("assets/entities/d.tscn", "[gd_scene]")
	var m := {"_dir": TMP, "assets": []}
	ok(AssetScan.sync(m), "首次扫描补条目")
	eq((m.assets as Array).size(), 4, "条目入 assets")
	for e in m.assets:
		eq(str((e as Dictionary).id).length(), 4, "资产 id=4 位码")
	var ent: Dictionary = {}
	for e in m.assets:
		if (e as Dictionary).get("prefab", "") != "":
			ent = e
	eq(str(ent.get("code", "")), str(ent.get("id", "")), "实体条目 code=id")
	eq(str(ent.get("prefab", "")), "assets/entities/d.tscn", "实体 rel 保留子目录")
	var tile: Dictionary = {}
	for e in m.assets:
		if str((e as Dictionary).get("atlas", "")) == "assets/tiles/a.png":
			tile = e
	eq(str(tile.get("kind", "")), "scene", "瓦片条目 kind=scene")
	eq(str(tile.get("shape", "")), "tile", "瓦片条目 shape=tile")
	ok(not tile.has("code"), "瓦片资产没有实体类型码")
	ok(not AssetScan.sync(m), "重复扫描不改清单")
	_nuke(TMP)

func test_scan_keeps_registered_identity() -> void:
	_nuke(TMP)
	_mk("assets/entities/new.tscn", "[gd_scene]")
	_mk("outside.png", "outside")
	var asset := {"id": "A1", "kind": "entity", "code": "EXST", "prefab": "assets/entities/old.tscn", "disabled": true}
	var m := {"_dir": TMP, "assets": [asset]}
	ok(AssetScan.sync(m), "新路径是新资产；缺失条目保留")
	eq(asset.prefab, "assets/entities/old.tscn", "不猜测移动路径")
	eq(asset.code, "EXST", "保留实体类型码")
	eq(m.assets.size(), 2, "约定目录之外的文件不登记")
	_mk("assets/entities/old.tscn", "[gd_scene]")
	ok(AssetScan.will_rediscover(m, asset), "文件在扫描目录时停用可保留原 ID")
	ok(not AssetScan.sync(m), "停用条目仍占用原路径")
	eq(m.assets[0], asset, "已登记的条目原样保留")
	_nuke(TMP)
