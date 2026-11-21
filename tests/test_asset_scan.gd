extends "res://tests/_suite_base.gd"
## AssetScan 扫描制用例（临时目录 user://test_asset_scan_tmp，用例自清理）：
## 新文件补条目发码 / 改名 md5 重链 / 消失标缺失 / 约定外条目不碰。

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
	var out := AssetScan.sync(m)
	eq((out.added as Array).size(), 4, "四个约定文件全补条目")
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
	eq((m["_scan_hashes"] as Dictionary).size(), 4, "指纹表 4 条落 manifest")
	var out2 := AssetScan.sync(m)
	eq((out2.added as Array).size(), 0, "二次扫描零新增")
	eq(int(out2.renamed), 0, "二次扫描零重链")
	eq((out2.missing as Array).size(), 0, "二次扫描零缺失")

func test_scan_rename_relink() -> void:
	_nuke(TMP)
	_mk("assets/tiles/old.png", "SAME")
	var m := {"_dir": TMP, "assets": []}
	var out1 := AssetScan.sync(m)
	eq((out1.added as Array).size(), 1, "首次扫描补条目")
	var id0 := str((m.assets as Array)[0].id)
	DirAccess.remove_absolute(TMP.path_join("assets/tiles/old.png"))
	_mk("assets/tiles/new.png", "SAME")
	var out2 := AssetScan.sync(m)
	eq(int(out2.renamed), 1, "md5 命中 → 重链")
	eq((out2.added as Array).size(), 0, "重链不另发新条目")
	eq((out2.missing as Array).size(), 0, "重链不标缺失")
	eq(str((m.assets as Array)[0].id), id0, "重链后码不变")
	eq(str((m.assets as Array)[0].atlas), "assets/tiles/new.png", "条目指向 new.png")

func test_scan_missing_kept() -> void:
	_nuke(TMP)
	_mk("assets/tiles/old.png", "SAME")
	var m := {"_dir": TMP, "assets": []}
	AssetScan.sync(m)
	var id0 := str((m.assets as Array)[0].id)
	DirAccess.remove_absolute(TMP.path_join("assets/tiles/old.png"))
	var out := AssetScan.sync(m)
	eq((out.missing as Array).size(), 1, "消失文件标缺失")
	eq(str((out.missing as Array)[0]), id0, "缺失列表 = 资产 id")
	eq((m.assets as Array).size(), 1, "条目不删")
	eq(str((m.assets as Array)[0].atlas), "assets/tiles/old.png", "条目路径不动")

func test_scan_outside_untouched() -> void:
	_nuke(TMP)
	_mk("custom/x.png", "Q")
	_mk("assets/tiles/keep.png", "R")
	var m := {"_dir": TMP, "assets": [
		{"id": "A1", "kind": "scene", "shape": "tile", "atlas": "custom/x.png"}]}
	var out := AssetScan.sync(m)
	eq((out.added as Array).size(), 1, "约定目录文件照常补条目")
	eq((out.missing as Array).size(), 0, "约定外条目不标缺失")
	eq((m.assets as Array).size(), 2, "手写条目原样保留")
	eq(str((m.assets as Array)[0].atlas), "custom/x.png", "约定外路径不改写")
