extends "res://tests/_suite_base.gd"
## C2（§7.4）：内容库批量引用扫描——实例绑定 + 内容入边一次读盘，筛选与行详情共用。

const ReferenceUsage := preload("res://src/project/reference_usage.gd")
const MapStore := preload("res://src/map/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")

const TMP := "user://test_c2_lib_tmp"

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

func _wipe() -> void:
	_nuke(TMP)

func _manifest() -> Dictionary:
	return {"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "contentDir": "content",
		"functions": [{"id": "dlg", "name": "对话", "code": "FN01", "fields": [
			{"id": "NEXT", "type": "string", "code": "F001", "source": "content:dlg"}]}]}
func test_bulk_edges_instances_and_contents() -> void:
	_wipe()
	var m := _manifest()
	# 两个内容 + 一张绑定图 + 一条内容间入边
	ok(ContentStore.write(m, "dlg", "C1", {"id": "C1", "function": "FN01", "name": "甲", "fields": {"F001": "C2"}}), "write C1")
	ok(ContentStore.write(m, "dlg", "C2", {"id": "C2", "function": "FN01", "name": "乙", "fields": {}}), "write C2")
	var md := MapStore.new_map("m1", 40, 30)
	(md.get("meta", {}) as Dictionary)["code"] = "M1"
	md["objects"] = [
		{"code": "AAAA", "asset": "npc", "x": 0, "y": 0, "functions": [{"fn": "FN01", "content": "C1"}, {"fn": "FN01", "content": "C1"}]},
		{"code": "BBBB", "asset": "npc", "x": 1, "y": 0, "functions": [{"fn": "FN01", "content": "C1"}]}]
	ok(MapStore.write(m, "m1", md), "write map")
	var bulk := ReferenceUsage.content_edges_bulk(m, "dlg", ["C1", "C2", "C3"], "m1",
		[{"cid": "C1", "code": "AAAA"}, {"cid": "C1", "code": "LIVE1"}])
	var refs: Dictionary = bulk.get("refs", {})
	var c1: Dictionary = refs.get("C1", {})
	var c2: Dictionary = refs.get("C2", {})
	var c3: Dictionary = refs.get("C3", {})
	var inst: Dictionary = c1.get("instances", {})
	ok(inst.has("m1"), "C1 bound on m1")
	eq((inst.get("m1", []) as Array).size(), 3, "C1 has 2 disk bindings + 1 live")
	eq(int(c1.get("n", 0)), 3, "C1 n = 2 disk bindings + 1 live")
	eq(int(c2.get("n", 0)), 1, "C2 inbound from C1 field")
	eq(int(c3.get("n", 0)), 0, "C3 unreferenced")