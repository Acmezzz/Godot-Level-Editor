extends SceneTree

## 数据层合并回归：原 t_coverage / map_data_validation / map_transaction /
## manifest_contract 等脚本合并为一个。
## 纯数据路径：临时目录造图，不建 UI；EDITOR_PROJECT 缺省时跳过真实项目断言。

const Store := preload("res://src/map_store.gd")
const Validator := preload("res://src/map_data_validation.gd")
const Manifest := preload("res://src/manifest.gd")
const Export := preload("res://src/map_export.gd")
const Playtest := preload("res://src/playtest.gd")

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_manifest_contract()
	_test_map_data_validation()
	_test_map_transaction()
	_test_store_basics()
	_test_names_and_paths()
	_test_command_quoting()
	_test_export()
	_test_playtest_guard()
	_test_entity_editor_size()
	if failures.is_empty():
		print("DATA_LAYER_OK")
	else:
		for failure in failures:
			printerr("DATA_LAYER_FAIL: ", failure)
		print("DATA_LAYER_FAILS=%d" % failures.size())
	quit(failures.size())

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _temp_project(name: String) -> Dictionary:
	var base := "user://data_layer_" + name
	var maps_dir := base.path_join("maps")
	DirAccess.make_dir_recursive_absolute(maps_dir)
	return {"_dir": base, "_maps_dir": maps_dir}

func _map(entities: Array, map_name := "test") -> Dictionary:
	return {"meta": {"name": map_name, "w": 10, "h": 10}, "spawn": [1, 1],
		"terrain": [], "decor": [], "collision": [], "entities": entities}
## 清单契约：合法清单通过；未知图层、重复种类、多图集均被拒。
func _test_manifest_contract() -> void:
	var valid := {
		"tileSize": 16,
		"tiles": [{"id": "rock", "atlas": "assets/rock.png", "palette": [{"cell": [0, 0]}]}],
		"layers": [{"id": "terrain"}, {"id": "decor"}, {"id": "collision"}],
		"entities": [{"id": "portal", "fields": [{"id": "target_point", "type": "entity_ref"}]}],
	}
	var issues := Manifest.validate(valid)
	_check(issues.is_empty(), "valid manifest passes validation")
	var invalid := valid.duplicate(true)
	invalid.layers.append({"id": "hazards"})
	invalid.entities.append({"id": "portal", "fields": "bad"})
	issues = Manifest.validate(invalid)
	var unknown_layer := false
	var duplicate_id := false
	for issue in issues:
		unknown_layer = unknown_layer or str(issue.message).contains("unsupported map layer")
		duplicate_id = duplicate_id or str(issue.message).contains("unique")
	_check(unknown_layer, "unknown map layer is rejected")
	_check(duplicate_id, "duplicate entity id is rejected")
	var multi := valid.duplicate(true)
	multi.tiles.append({"id": "water", "atlas": "assets/water.png"})
	# 批次 9：多图集解锁——第二个 atlas 校验通过（单图集锁已移除）
	_check(Manifest.validate(multi).is_empty(), "multiple atlases are accepted (批次 9)")

## 地图数据校验：结构错误定位、旧格式迁移、坏图拒收。
func _test_map_data_validation() -> void:
	var valid := {
		"meta": {"name": "sample", "w": 10, "h": 8},
		"spawn": [2, 2],
		"terrain": [[1, 2, 0, 0]], "decor": [], "collision": [[1, 2]],
		"entities": [{"scene": "portal", "id": "e_1", "x": 2, "y": 3, "props": {}}],
	}
	_check(Validator.validate(valid, {"entities": [{"id": "portal"}]}).is_empty(),
		"valid map data passes validation")
	var invalid := valid.duplicate(true)
	invalid.terrain = "not-an-array"
	invalid.entities.append({"scene": "portal", "id": "e_1", "x": "bad", "props": []})
	var issues := Validator.validate(invalid)
	var terrain_error := false
	var duplicate_error := false
	var coordinate_error := false
	for issue in issues:
		terrain_error = terrain_error or str(issue.path) == "terrain"
		duplicate_error = duplicate_error or str(issue.message).contains("duplicate entity id")
		coordinate_error = coordinate_error or str(issue.path).ends_with(".x")
	_check(terrain_error, "malformed terrain is reported at terrain path")
	_check(duplicate_error, "duplicate entity id is reported")
	_check(coordinate_error, "bad entity coordinate is reported at .x path")
	var legacy := Store.decode_text(JSON.stringify({
		"meta": {"name": "legacy", "w": 4, "custom": "kept"},
		"spawn": [1.5, 2.0], "terrain": [], "decor": [], "collision": [],
		"entities": [{"scene": "portal", "id": "e_1", "x": 1.5, "y": 2.0, "props": {}}],
	}), "legacy.json", {"entities": [{"id": "portal"}]})
	_check(legacy.ok and legacy.migrated, "legacy map migrates instead of failing")
	if legacy.ok:
		_check(int(legacy.data.entities[0].x) == 1, "migration rounds float coordinates")
		_check(str(legacy.data.meta.custom) == "kept", "migration keeps unknown meta fields")
	var rejected := Store.decode_text(
		JSON.stringify({"terrain": "bad", "meta": {}, "entities": [], "collision": [], "decor": []}),
		"bad.json")
	_check(not rejected.ok, "malformed map is rejected")
	_check(not rejected.errors.is_empty() and str(rejected.errors[0].path) == "terrain",
		"rejection carries the terrain path")
	_test_functions_validation(valid)

## v2 §5.3：实例 functions 结构校验——空 content 是「未填」不是错误；
## 未知 fn 只警告（项目侧可以先放数据再补实现）；类型错了才报错。
func _test_functions_validation(valid: Dictionary) -> void:
	var m := {"entities": [{"id": "portal"}], "functions": {"dialogue": {"fields": []}, "shop": {}}}
	var ok := valid.duplicate(true)
	ok.entities = [{"scene": "portal", "id": "e_1", "x": 2, "y": 3, "props": {},
		"functions": [
			{"fn": "dialogue", "content": "", "name": "", "order": 1, "parallel": false},
			{"fn": "shop", "content": "TEST-portal-e_1-shop-ABC234", "name": "杂货", "order": 2, "parallel": true},
		]}]
	_check(Validator.validate(ok, m).is_empty(), "valid functions array passes validation")
	var bad := valid.duplicate(true)
	bad.entities = [{"scene": "portal", "id": "e_1", "x": 2, "y": 3, "props": {},
		"functions": ["not-an-object"]}]
	_check(_has_path(Validator.validate(bad, m), "entities[0].functions[0]"),
		"non-object function entry is reported")
	var bad2 := valid.duplicate(true)
	bad2.entities = [{"scene": "portal", "id": "e_1", "x": 2, "y": 3, "props": {},
		"functions": [{"fn": "dialogue", "content": 7, "order": "first", "parallel": "yes"}]}]
	var issues2 := Validator.validate(bad2, m)
	_check(_has_path(issues2, "entities[0].functions[0].content"), "non-string content is reported")
	_check(_has_path(issues2, "entities[0].functions[0].order"), "non-numeric order is reported")
	_check(_has_path(issues2, "entities[0].functions[0].parallel"), "non-boolean parallel is reported")
	var undeclared := valid.duplicate(true)
	undeclared.entities = [{"scene": "portal", "id": "e_1", "x": 2, "y": 3, "props": {},
		"functions": [{"fn": "teleport", "content": "x", "name": "去矿洞", "order": 1}]}]
	var warn_ok := false
	for issue in Validator.validate(undeclared, m):
		if str(issue.path).ends_with(".fn") and str(issue.severity) == "warning":
			warn_ok = true
	_check(warn_ok, "undeclared function is a warning, not an error")
	var not_array := valid.duplicate(true)
	not_array.entities = [{"scene": "portal", "id": "e_1", "x": 2, "y": 3, "props": {}, "functions": {}}]
	_check(_has_path(Validator.validate(not_array, m), "entities[0].functions"),
		"functions must be an array")

func _has_path(issues: Array, path: String) -> bool:
	for issue in issues:
		if str(issue.path) == path:
			return true
	return false
## 多图事务：全量覆盖、失败回滚到字节一致、新图被撤回。
func _test_map_transaction() -> void:
	var maps_dir := ProjectSettings.globalize_path("user://map_tx_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(maps_dir)
	var m := {"_maps_dir": maps_dir}
	_check(Store.write(m, "a", _marker_map("a", "before-a")), "transaction seeds map a")
	_check(Store.write(m, "b", _marker_map("b", "before-b")), "transaction seeds map b")
	var updates := {"a": _marker_map("a", "after-a"), "b": _marker_map("b", "after-b"),
		"c": _marker_map("c", "new-c")}
	var ok := Store.write_transaction(m, {"a": updates.a, "b": updates.b})
	_check(ok.get("ok", false), "transaction overwrites existing maps")
	_check(str(Store.read(m, "a").meta.marker) == "after-a", "first map contains the update")
	_check(str(Store.read(m, "b").meta.marker) == "after-b", "second map contains the update")

	# 让第二目标位置变成目录，迫使提交在中途失败；回滚基准是本次事务前的字节
	var blocked := Store.path_for(m, "b")
	var before_a := _read_bytes(Store.path_for(m, "a"))
	DirAccess.remove_absolute(blocked)
	DirAccess.make_dir_absolute(blocked)
	_check(DirAccess.dir_exists_absolute(blocked), "blocking directory is in place")
	var failed := Store.write_transaction(m, {"a": updates.a, "c": updates.c, "b": updates.b})
	_check(not failed.get("ok", true), "later commit failure is surfaced")
	_check(str(failed.get("failed_map", "")) == "b", "failure names the blocked destination")
	_check(failed.get("rollback_ok", false), "partial commit rolls back")
	_check(_read_bytes(Store.path_for(m, "a")) == before_a, "rollback restores first map byte-for-byte")
	_check(DirAccess.dir_exists_absolute(blocked), "blocking directory is left intact")
	_check(not FileAccess.file_exists(Store.path_for(m, "c")), "rollback removes the committed new map")
	DirAccess.remove_absolute(blocked)
	DirAccess.remove_absolute(maps_dir)

## 存储层：坏图隔离、列表过滤、编号分配、出口配对清理。
func _test_store_basics() -> void:
	var m := _temp_project("store")
	_check(Store.write(m, "ok1", _map([], "ok1")), "store writes a map")
	var af := FileAccess.open(m._maps_dir.path_join("ok1.autosave.json"), FileAccess.WRITE)
	af.store_string("{}")
	af.close()
	var nf := FileAccess.open(m._maps_dir.path_join("readme.txt"), FileAccess.WRITE)
	nf.store_string("x")
	nf.close()
	_check(Store.list_maps(m) == ["ok1"], "list_maps filters autosave and non-json, then sorts")

	var badp := str(m._maps_dir).path_join("bad.json")
	var bf := FileAccess.open(badp, FileAccess.WRITE)
	bf.store_string("{oops not json")
	bf.close()
	var bad: Array = []
	var all := Store.read_all(m, bad)
	_check(bad.size() == 1 and str(bad[0].get("name", "")) == "bad", "read_all reports the corrupt map")
	_check(all.has("ok1"), "read_all still loads healthy maps")

	var empty := {"_maps_dir": str(m._dir).path_join("no_such_dir")}
	_check(Store.list_maps(empty) == [], "list_maps returns empty for a missing directory")
	var bad2: Array = []
	Store.read_all(empty, bad2)
	_check(bad2.is_empty(), "read_all on a missing directory reports nothing")

	_remove_project(m)

## 地图名校验与路径穿越拒绝；命令变量替换不会重复加引号。
func _test_names_and_paths() -> void:
	for good in ["level_1", "a", "地图01"]:
		_check(Manifest.is_valid_map_name(good), "valid map name rejected: " + good)
	for bad_name in ["", "..", "../evil", "a/b", "a\\b", "C:evil", ".hidden", "con"]:
		_check(not Manifest.is_valid_map_name(bad_name), "invalid map name accepted: " + bad_name)
	var m := {"_maps_dir": "D:/proj/maps"}
	_check(Manifest.map_path(m, "level_1") == "D:/proj/maps/level_1.json", "map_path joins normally")
	_check(Manifest.map_path(m, "../evil") == "", "map_path refuses traversal")

func _test_command_quoting() -> void:
	var c1 := Manifest.substitute_vars("game --map=%mapfile%", "D:/a b/c.json", "D:/p")
	_check(c1 == "game --map=\"D:/a b/c.json\"", "spaces force quoting: " + c1)
	var c2 := Manifest.substitute_vars("game --map=\"%mapfile%\"", "D:/a b/c.json", "D:/p")
	_check(c2 == "game --map=\"D:/a b/c.json\"", "existing quotes are not doubled: " + c2)
	var m := {"_dir": "D:/proj",
		"playCommand": "\"D:/old/godot.exe\" --path \"D:/p\" -- --map=%mapfile%",
		"godotExe": "%projectpath%/tools/godot.exe"}
	var cmd := Manifest.resolved_play_command(m, "D:/proj/maps/a.json")
	_check(cmd.begins_with("\"D:/proj/tools/godot.exe\""), "godotExe overrides the first command token")

## 预览图与统计：尺寸、实体计数、越界实体不崩溃。
func _test_export() -> void:
	var data := {
		"meta": {"name": "t", "w": 8, "h": 6}, "spawn": [1, 1],
		"terrain": [[0, 0, 0, 0]], "decor": [], "collision": [[1, 1]],
		"entities": [
			{"scene": "crawler", "id": "e_1", "x": 2, "y": 2, "props": {}},
			{"scene": "exit", "id": "e_2", "x": 3, "y": 3, "props": {"target_map": "x"}},
		]}
	var img := Export.render_preview(data, 4)
	_check(img.get_width() == 32 and img.get_height() == 24, "preview image matches tile size × zoom")
	var txt := Export.stats_text("t", data)
	_check(txt.contains("实体总数: 2"), "stats text counts entities")
	_check(txt.contains("crawler: 1"), "stats text groups by scene")
	var data2 := data.duplicate(true)
	data2["entities"].append({"scene": "crawler", "id": "e_9", "x": 999, "y": 999, "props": {}})
	_check(Export.render_preview(data2, 4).get_width() == 32, "out-of-bounds entity is skipped")
## 试玩启动守卫：命令首参解析四态，缺可执行文件时提前拒绝（不真的拉起进程）。
func _test_playtest_guard() -> void:
	_check(Playtest._first_token("game.exe --flag") == "game.exe", "bare exe token parses")
	_check(Playtest._first_token('"D:/a b/game.exe" --flag') == "D:/a b/game.exe", "quoted exe token parses")
	_check(Playtest._first_token("game.exe") == "game.exe", "single-token command parses")
	_check(Playtest._first_token("   ") == "", "blank command yields an empty token")
	_check(not Playtest.launch_tracked({"playCommand": ""}, "x.json").ok,
		"launch without a playCommand is rejected")
	var missing := Playtest.launch_tracked({"playCommand": "D:/definitely_missing_zz.exe %mapfile%"}, "x.json")
	_check(not missing.ok and str(missing.error).contains("找不到"),
		"missing executable is rejected before spawning")

## 实体编辑器占位尺寸：需要真实游戏清单，未设置 EDITOR_PROJECT 时跳过。
func _test_entity_editor_size() -> void:
	var project := OS.get_environment("EDITOR_PROJECT")
	if project == "":
		print("SKIP entity_editor_size (EDITOR_PROJECT unset)")
		return
	var manifest := Manifest.load_from(project)
	_check(not manifest.has("_error"), "game manifest loads from EDITOR_PROJECT")
	if manifest.has("_error"):
		return
	var crawler := {}
	var portal := {}
	for entity in manifest.get("entities", []):
		if str(entity.get("id", "")) == "crawler":
			crawler = entity
		elif str(entity.get("id", "")) == "portal":
			portal = entity
	_check(not crawler.is_empty(), "crawler entry exists in the game manifest")
	if not crawler.is_empty():
		_check(Manifest.entity_editor_size(manifest, crawler) == Vector2(11, 7),
			"editor size comes from the prefab collision shape")
		var override := crawler.duplicate(true)
		override["editorSize"] = [20, 12]
		_check(Manifest.entity_editor_size(manifest, override) == Vector2(20, 12),
			"editorSize overrides the prefab shape")
	_check(not portal.is_empty(), "portal entry exists in the game manifest")
	if not portal.is_empty():
		_check(Manifest.entity_editor_size(manifest, portal) == Vector2(20, 20),
			"circle collision yields a square editor size")
	_check(Manifest.entity_editor_size(manifest, {"id": "x"}) == Vector2.ZERO,
		"missing size source yields zero")
	_check(Manifest.prefab_collision_size(project, "scenes/nope.tscn") == Vector2.ZERO,
		"missing prefab yields zero size")

func _marker_map(map_name: String, marker: String) -> Dictionary:
	return {"meta": {"name": map_name, "w": 8, "h": 6, "marker": marker},
		"spawn": [1, 1], "terrain": [], "decor": [], "collision": [], "entities": []}

func _read_bytes(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var bytes := file.get_buffer(file.get_length())
	file.close()
	return bytes

func _remove_project(m: Dictionary) -> void:
	var dir := str(m.get("_maps_dir", ""))
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		return
	var handle := DirAccess.open(dir)
	if handle != null:
		for filename in handle.get_files():
			DirAccess.remove_absolute(dir.path_join(filename))
	DirAccess.remove_absolute(dir)
	var base := str(m.get("_dir", ""))
	if base != "" and DirAccess.dir_exists_absolute(base):
		DirAccess.remove_absolute(base)