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
	eq(str(tile.get("scanFingerprint", "")), str(FileAccess.get_md5(TMP.path_join("assets/tiles/a.png"))),
		"指纹持久化在条目上（A4：不再依赖运行时 _scan_hashes）")
	var out2 := AssetScan.sync(m)
	eq((out2.added as Array).size(), 0, "二次扫描零新增")
	eq(int(out2.renamed), 0, "二次扫描零重链")
	eq((out2.missing as Array).size(), 0, "二次扫描零缺失")
	eq(bool(out2.changes), false, "静止状态扫描不算变更（不弄脏清单）")

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

## A4：重启前后改名——指纹持久化在条目上，新进程（换 manifest 字典往返 JSON）照样重链。
func test_scan_rename_after_restart() -> void:
	_nuke(TMP)
	_mk("assets/tiles/old.png", "SAME-2")
	var m := {"_dir": TMP, "assets": []}
	AssetScan.sync(m)
	var id0 := str((m.assets as Array)[0].id)
	# 模拟关闭项目：清单往返 JSON（运行时键剥掉，剩持久化字段）
	var disk := JSON.parse_string(JSON.stringify({"assets": m.assets})) as Dictionary
	DirAccess.remove_absolute(TMP.path_join("assets/tiles/old.png"))
	_mk("assets/tiles/renamed.png", "SAME-2")
	var m2 := {"_dir": TMP, "assets": (disk as Dictionary)["assets"]}
	var out := AssetScan.sync(m2)
	eq(int(out.renamed), 1, "重启后仍能按持久指纹重链")
	eq(str((m2.assets as Array)[0].id), id0, "重启重链后码不变")

## A4：同指纹双候选 → 保留旧 ID + 候选列表，不发新 ID；确认后重链生效。
func test_scan_ambiguous_two_candidates() -> void:
	_nuke(TMP)
	_mk("assets/tiles/old.png", "DUP")
	var m := {"_dir": TMP, "assets": []}
	AssetScan.sync(m)
	var id0 := str((m.assets as Array)[0].id)
	DirAccess.remove_absolute(TMP.path_join("assets/tiles/old.png"))
	_mk("assets/tiles/a.png", "DUP")
	_mk("assets/tiles/b.png", "DUP")
	var out := AssetScan.sync(m)
	eq((out.ambiguous as Array).size(), 1, "双候选报歧义")
	eq(int(out.renamed), 0, "歧义不自动重链")
	eq((m.assets as Array).size(), 1, "歧义不发新 ID")
	eq(str((m.assets as Array)[0].id), id0, "歧义保留旧 ID")
	ok(bool((m.assets as Array)[0].get("retired", false)), "歧义条目记为停用待确认")
	eq((m.assets as Array)[0].get("relinkCandidates", []).size(), 2, "候选路径留档")
	# 再次扫描：候选没变 → 不重复算变更
	var out2 := AssetScan.sync(m)
	eq(bool(out2.changes), false, "歧义状态静止后不再弄脏清单")
	eq((out2.ambiguous as Array).size(), 1, "歧义仍然报给界面")
	# 用户确认其一 → 指向该路径、清停用；被放弃的候选文件按新文件补码
	ok(AssetScan.confirm_relink(m, id0, "assets/tiles/b.png"), "确认重链成功")
	eq(str((m.assets as Array)[0].atlas), "assets/tiles/b.png", "条目指向确认的候选")
	ok(not (m.assets as Array)[0].has("retired"), "确认后清停用")
	var out3 := AssetScan.sync(m)
	eq(int(out3.renamed), 0, "确认后不再重链")
	eq((out3.added as Array).size(), 1, "被放弃的候选文件是新文件，补发新码")
	eq((m.assets as Array).size(), 2, "确认后两个文件各有一条")
	eq(str((m.assets as Array)[0].id), id0, "原 ID 留在确认的候选上")

## A4：停用后重扫不发新 ID；恢复后原引用生效。
func test_scan_retire_restore_keeps_id() -> void:
	_nuke(TMP)
	_mk("assets/entities/e.tscn", "[gd_scene node]")
	var m := {"_dir": TMP, "assets": []}
	AssetScan.sync(m)
	var id0 := str((m.assets as Array)[0].id)
	DirAccess.remove_absolute(TMP.path_join("assets/entities/e.tscn"))
	var out := AssetScan.sync(m)
	eq((out.retired as Array).size(), 1, "消失文件记停用")
	eq((m.assets as Array).size(), 1, "停用不删条目")
	eq(str((m.assets as Array)[0].id), id0, "停用保留原 ID")
	eq(str((m.assets as Array)[0].get("retiredPath", "")), "assets/entities/e.tscn", "原路径留档")
	# 停用静止：再扫不发新 ID、不重复算变更
	var out2 := AssetScan.sync(m)
	eq((out2.added as Array).size(), 0, "停用后重扫不发新 ID")
	eq(bool(out2.changes), false, "停用状态静止不弄脏清单")
	# 文件回到原位 → 自动恢复，原 ID 与引用继续有效
	_mk("assets/entities/e.tscn", "[gd_scene node]")
	var out3 := AssetScan.sync(m)
	ok(not (m.assets as Array)[0].has("retired"), "文件回来后自动解除停用")
	eq((m.assets as Array).size(), 1, "恢复不另发条目")
	eq(str((m.assets as Array)[0].id), id0, "恢复后原引用仍指向同一 ID")
	eq((out3.added as Array).size(), 0, "恢复不新增")

## A4/D12：图鉴删除扫描资产 = 停用记录，源文件还在目录里也不带新 ID 回来。
func test_scan_disable_keeps_id() -> void:
	_nuke(TMP)
	_mk("assets/tiles/keep.png", "K")
	var m := {"_dir": TMP, "assets": []}
	AssetScan.sync(m)
	var id0 := str((m.assets as Array)[0].id)
	ok(AssetScan.disable(m, id0), "停用成功")
	eq((m.assets as Array).size(), 1, "停用不删条目")
	var out := AssetScan.sync(m)
	eq((out.added as Array).size(), 0, "停用资产的文件不被当新文件发码")
	eq((m.assets as Array).size(), 1, "停用后条目仍唯一")
	eq(str((m.assets as Array)[0].id), id0, "原 ID 保留")
	ok(AssetScan.enable(m, id0), "重新启用成功")
	ok(not (m.assets as Array)[0].has("disabled"), "启用后清标记")
	AssetScan.sync(m)
	eq((m.assets as Array).size(), 1, "启用后不重复发码")

## A4：缺 assets 键的最小清单 + 只补实体码的清单都能扫描（D12）。
func test_scan_minimal_manifest() -> void:
	_nuke(TMP)
	_mk("assets/tiles/t.png", "T")
	var m := {"_dir": TMP}   # 完全没有 assets 键
	var out := AssetScan.sync(m)
	eq((out.added as Array).size(), 1, "缺 assets 键也能补条目")
	ok(m.get("assets", null) is Array, "assets 键被挂回清单")
	# 只有实体码、没有指纹的实体条目：原位不丢，指纹补上
	var m2 := {"_dir": TMP, "assets": [
		{"id": "A1", "kind": "entity", "code": "A1", "prefab": "assets/entities/missing.tscn"}]}
	_mk("assets/entities/missing.tscn", "[gd_scene]")
	AssetScan.sync(m2)
	var ent := (m2.assets as Array)[0] as Dictionary
	eq(str(ent.id), "A1", "只补实体码的条目原位保留")
	ok(str(ent.get("scanFingerprint", "")) != "", "缺指纹的实体条目补上指纹")
