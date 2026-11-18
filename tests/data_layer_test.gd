extends SceneTree

## 数据层合并回归：原 crossmap_test / t_coverage / cross_map_semantics_regression /
## map_data_validation / map_transaction / manifest_contract 六个脚本合并为一个。
## 纯数据路径：临时目录造图，不建 UI；BIRD_PROJECT 缺省时跳过真实项目断言。

const Store := preload("res://src/map_store.gd")
const Validate := preload("res://src/map_validate.gd")
const Validator := preload("res://src/map_data_validation.gd")
const Manifest := preload("res://src/manifest.gd")
const Export := preload("res://src/map_export.gd")
const LevelList := preload("res://src/level_list.gd")
const CrossMap := preload("res://src/cross_map.gd")
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
	_test_validate_and_migrate()
	_test_relationship_semantics()
	_test_single_map_validation()
	_test_level_unlock_validation()
	_test_plan_pick()
	_test_export()
	_test_level_list_and_graph()
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

func _has(issues: Array, map_name: String, needle: String, ent_id := "") -> bool:
	for issue in issues:
		if str(issue.get("map", "")) != map_name:
			continue
		if ent_id != "" and str(issue.get("ent_id", "")) != ent_id:
			continue
		if str(issue.get("message", "")).contains(needle):
			return true
	return false

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
	_check(_has(Validate.validate_all(m), "bad", "地图文件损坏"), "validation reports the corrupt map")

	var empty := {"_maps_dir": str(m._dir).path_join("no_such_dir")}
	_check(Store.list_maps(empty) == [], "list_maps returns empty for a missing directory")
	var bad2: Array = []
	Store.read_all(empty, bad2)
	_check(bad2.is_empty(), "read_all on a missing directory reports nothing")

	_check(Store.next_entity_id({"entities": [{"id": "e_1"}, {"id": "e_3"}]}) == "e_4",
		"next_entity_id fills the first gap")
	_check(Store.next_entity_id({}) == "e_1", "next_entity_id starts at e_1 when empty")
	_check(Store.next_entity_id({"entities": ["junk", {"scene": "x"}, {"id": "e_2"}]}) == "e_3",
		"next_entity_id tolerates garbage entries")

	var d := {"entities": [{"scene": "exit", "id": "x1",
		"props": {"target_map": "m2", "target_point": "p1"}}]}
	_check(Store.clear_exit_pair(d, "x1", "m2", "p1"), "clear_exit_pair clears a matching pair")
	_check((d.entities[0].props as Dictionary).is_empty(), "cleared exit leaves props empty")
	var d2 := {"entities": [{"scene": "exit", "id": "x1",
		"props": {"target_map": "m3", "target_point": "p9"}}]}
	_check(not Store.clear_exit_pair(d2, "x1", "m2", "p1"), "clear_exit_pair leaves a mismatched exit")
	var d3 := {"entities": [{"scene": "portal", "id": "x1",
		"props": {"target_map": "m2", "target_point": "p1"}}]}
	_check(not Store.clear_exit_pair(d3, "x1", "m2", "p1"), "clear_exit_pair leaves non-exit entities")
	_check(not Store.clear_exit_pair({}, "x1", "m2", "p1"), "clear_exit_pair tolerates empty data")
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
## 跨图校验与改名迁移：悬空门、一对多、死链、单向出口、无目标图、旧格式升级。
func _test_validate_and_migrate() -> void:
	var m := _temp_project("migrate")
	Store.write(m, "a", _map([
		{"scene": "portal", "id": "e_1", "x": 1, "y": 1, "props": {"target_point": "e_99"}},
		{"scene": "portal", "id": "e_2", "x": 2, "y": 2, "props": {"target_point": "e_3"}},
		{"scene": "portal", "id": "e_3", "x": 3, "y": 3, "props": {"target_point": "e_2"}},
		{"scene": "portal", "id": "e_4", "x": 4, "y": 4, "props": {"target_point": "e_3"}},
	], "a"))
	Store.write(m, "b", _map([
		{"scene": "exit", "id": "e_1", "x": 1, "y": 1,
			"props": {"target_map": "nope", "target_point": "e_1"}},
	], "b"))
	Store.write(m, "c", _map([
		{"scene": "exit", "id": "e_1", "x": 1, "y": 1,
			"props": {"target_map": "d", "target_point": "e_1"}},
	], "c"))
	Store.write(m, "d", _map([{"scene": "exit", "id": "e_1", "x": 1, "y": 1, "props": {}}], "d"))
	Store.write(m, "e", _map([
		{"scene": "exit", "id": "e_1", "x": 1, "y": 1,
			"props": {"target_map": "c", "target_point": "e_1"}},
	], "e"))

	var issues := Validate.validate_all(m)
	_check(_has(issues, "a", "不存在的实体", "e_1"), "dangling portal target is detected")
	_check(_has(issues, "a", "被多个门引用", "e_3"), "one-to-many portal targeting is detected")
	_check(_has(issues, "b", "目标地图不存在", "e_1"), "exit to a missing map is detected")
	_check(_has(issues, "c", "没有指回来", "e_1"), "one-way exit is detected")
	_check(_has(issues, "d", "没有配置目标地图", "e_1"), "exit without target map is detected")

	_check(Validate.migrate_map_rename(m, "c", "c2").get("ok", false), "rename migration succeeds")
	var e_props: Dictionary = Store.read(m, "e").entities[0].get("props", {})
	_check(str(e_props.get("target_map", "")) == "c2", "rename rewrites inbound target_map")

	# 旧图没有 version：读出时应升级并取整坐标，同时保留未知字段
	Store.write(m, "old", _map([
		{"scene": "portal", "id": "e_1", "x": 2.7, "y": 3.2, "props": {}},
	], "old"))
	var old_data := Store.read(m, "old")
	_check(int(old_data.get("version", 0)) == 3, "reading an old map upgrades its version")
	var old_ent: Dictionary = old_data.entities[0]
	_check(int(old_ent.get("x", 0)) == 2 and int(old_ent.get("y", 0)) == 3,
		"upgrade rounds entity coordinates")
	_remove_project(m)

## 世界图关系语义：exit→落点是合法单向，exit→exit 必须精确互指，无效边不算可达。
func _test_relationship_semantics() -> void:
	var m := _temp_project("semantics")
	Store.write(m, "a", _map([
		_exit("e_pair_a", "b", "e_pair_b"),
		_exit("e_oneway", "b", "p_b"),
		_exit("e_broken", "b", "e_broken_b"),
		_exit("e_invalid", "d", "missing_point"),
		{"scene": "exit", "id": "e_unconfigured", "x": 1, "y": 1,
			"props": {"target_point": "p_local"}},
		_point("p_local"),
	], "a"))
	Store.write(m, "b", _map([
		_exit("e_pair_b", "a", "e_pair_a"),
		_exit("e_broken_b", "c", "p_c"),
		_point("p_b"),
	], "b"))
	Store.write(m, "c", _map([_point("p_c")], "c"))
	Store.write(m, "d", _map([], "d"))

	var issues := Validate.validate_all(m)
	_check(not _has(issues, "a", "没有指回来", "e_oneway"),
		"an exit targeting a destination spawn point is a valid one-way link")
	_check(_has(issues, "a", "没有指回来", "e_broken"),
		"an exit targeting another exit still needs an exact reciprocal link")
	_check(_has(issues, "a", "没有被任何门/出口使用", "p_local"),
		"an unconfigured exit does not consume a same-map spawn point")
	_check(not _has(issues, "b", "没有被任何门/出口使用", "p_b"),
		"a cross-map one-way link consumes its destination spawn point")

	var levels := {"levels": [
		{"map": "a", "order": 1}, {"map": "b", "order": 2},
		{"map": "c", "order": 3}, {"map": "d", "order": 4},
	]}
	var graph := LevelList.build_world_graph(m, levels, Store.read_all(m))
	var ab := _edge(graph, "a", "b")
	_check(int(ab.get("paired_count", 0)) == 1, "only the exact reciprocal pair counts as paired")
	_check(int(ab.get("one_way_count", 0)) == 1, "the spawn-point link counts as one-way")
	_check(int(ab.get("broken_count", 0)) == 1, "the unpaired exit-to-exit link counts as broken")
	_check(not bool(ab.get("paired", true)), "a mixed connection is not labeled wholly paired")
	var ad := _edge(graph, "a", "d")
	_check(int(ad.get("invalid_count", 0)) == 1, "an exit to a missing point counts as invalid")
	_check(LevelList.unreachable_maps(graph, "a").has("d"),
		"an invalid link does not make a map reachable")
	_remove_project(m)

## 单图校验模式：悬空门 + 指向不存在地图的出口都要报出来。
func _test_single_map_validation() -> void:
	var m := _temp_project("single")
	var data := _map([
		{"scene": "portal", "id": "e_p", "x": 1, "y": 1, "props": {"target_point": "e_99"}},
		{"scene": "exit", "id": "e_1", "x": 2, "y": 2,
			"props": {"target_map": "ghost", "target_point": "e_1"}},
	], "solo")
	var issues := Validate.validate_map(m, "solo", data)
	_check(_has(issues, "solo", "传送门指向不存在的实体"), "single-map mode detects a dangling portal")
	_check(_has(issues, "solo", "目标地图不存在或无法读取"), "single-map mode detects an exit to a missing map")
	_remove_project(m)

## 关卡清单校验：解锁前置地图不存在必须报错（与「缺失地图文件」区分开）。
func _test_level_unlock_validation() -> void:
	var m := _temp_project("unlock")
	Store.write(m, "l1", _map([], "l1"))
	var bad := {"mode": "level_select", "start": "l1",
		"levels": [{"map": "l1", "order": 1, "unlock": "ghost"}]}
	_check(_has(Validate.validate_levels(m, bad), "l1", "解锁前置地图不存在"),
		"missing unlock prerequisite is reported")
	_remove_project(m)
## 落点选择计划：拒绝分支、新建落点、复用落点、出口配对、三种 unbind 计划。
func _test_plan_pick() -> void:
	var m := _temp_project("planpick")
	Store.write(m, "target", _map([
		{"scene": "exit", "id": "e_1", "x": 2, "y": 2,
			"props": {"target_map": "far", "target_point": "e_9"}},
		_point("sp_1"),
	], "target"))
	Store.write(m, "own", _map([{"scene": "exit", "id": "e_2", "x": 1, "y": 1, "props": {}}], "own"))

	_check(not CrossMap.plan_pick(m, "", "own", "e_2", "exit", "", "", Vector2i.ZERO).ok,
		"plan_pick rejects an empty target map")
	_check(not CrossMap.plan_pick(m, "own", "own", "e_2", "exit", "", "", Vector2i.ZERO).ok,
		"plan_pick rejects linking a map to itself")
	_check(not CrossMap.plan_pick(m, "target", "own", "e_2", "exit", "zz", "crawler", Vector2i.ZERO).ok,
		"plan_pick rejects a non-reusable scene as target")
	_check(not CrossMap.plan_pick(m, "target", "own", "e_2", "portal", "e_1", "exit", Vector2i.ZERO).ok,
		"plan_pick rejects pairing a portal with an exit")
	_check(not CrossMap.plan_pick(m, "ghost", "own", "e_2", "exit", "", "", Vector2i.ZERO).ok,
		"plan_pick rejects a missing target map")

	var created := CrossMap.plan_pick(m, "target", "own", "e_2", "exit", "", "", Vector2i(7, 7))
	var new_ok: bool = created.ok and str(created.acted) == "new" and str(created.id).begins_with("e_")
	if new_ok:
		for ent in created.data.get("entities", []):
			if str(ent.get("id", "")) == str(created.id):
				new_ok = str(ent.get("scene", "")) == "spawn_point" and int(ent.get("x", -1)) == 7
	_check(new_ok, "plan_pick plans a new spawn point at the requested cell")

	var reused := CrossMap.plan_pick(m, "target", "own", "e_2", "exit", "sp_1", "spawn_point", Vector2i.ZERO)
	_check(reused.ok and str(reused.acted) == "reuse", "plan_pick reuses an existing spawn point")

	var paired := CrossMap.plan_pick(m, "target", "own", "e_2", "exit", "e_1", "exit", Vector2i.ZERO)
	var pair_ok: bool = paired.ok and str(paired.acted) == "pair"
	if pair_ok:
		var peer = Store.find_entity(paired.data, "e_1")
		pair_ok = str(peer.get("props", {}).get("target_map", "")) == "own" \
			and str(peer.get("props", {}).get("target_point", "")) == "e_2"
		pair_ok = pair_ok and (paired.unbind as Array).size() == 1 \
			and str((paired.unbind as Array)[0][0]) == "far"
	_check(pair_ok, "plan_pick rewrites the peer exit and schedules the stale unbind")

	# 旧对端在本地图：只进 unbind_local，由调用方清内存，不写盘
	Store.write(m, "target", _map([
		{"scene": "exit", "id": "e_1", "x": 2, "y": 2,
			"props": {"target_map": "own", "target_point": "e_2"}},
	], "target"))
	var local := CrossMap.plan_pick(m, "target", "own", "e_3", "exit", "e_1", "exit", Vector2i.ZERO)
	_check(local.ok and (local.unbind_local as Array).has("e_2"),
		"plan_pick schedules a local unbind for a same-map stale peer")

	# 旧对端在目标图内部：要写盘的 data 里旧出口 props 必须被清掉
	Store.write(m, "target", _map([
		{"scene": "exit", "id": "e_1", "x": 2, "y": 2,
			"props": {"target_map": "target", "target_point": "e_5"}},
		{"scene": "exit", "id": "e_5", "x": 4, "y": 4,
			"props": {"target_map": "target", "target_point": "e_1"}},
	], "target"))
	var in_target := CrossMap.plan_pick(m, "target", "own", "e_3", "exit", "e_1", "exit", Vector2i.ZERO)
	var cleared := false
	if in_target.ok:
		var stale = Store.find_entity(in_target.data, "e_5")
		cleared = not stale.is_empty() and str(stale.get("props", {}).get("target_map", "")) == ""
	_check(cleared, "plan_pick clears the stale peer inside the destination map")
	_remove_project(m)

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
## 关卡清单读写、校验与世界拓扑（含孤立可达性）。
func _test_level_list_and_graph() -> void:
	var base := "user://data_layer_levels"
	var maps_dir := base.path_join("maps")
	DirAccess.make_dir_recursive_absolute(maps_dir)
	var m := {"_dir": base, "_maps_dir": maps_dir}
	# 上次运行残留的 levels.json 会让「无清单生成建议」断言假失败，先删
	var stale := LevelList.file_path(m)
	if FileAccess.file_exists(stale):
		DirAccess.remove_absolute(stale)
	for f in ["l1", "l2", "l3"]:
		Store.write(m, f, _map([], f))

	var d := LevelList.load_levels(m)
	var arr: Array = d.get("levels", [])
	_check(arr.size() == 3, "levels are suggested from the maps directory")
	_check(str(d.get("start", "")) != "", "a start level is suggested")

	d["mode"] = LevelList.MODE_LEVEL_SELECT
	d["start"] = "l2"
	for i in arr.size():
		(arr[i] as Dictionary)["unlock"] = "l1" if i > 0 else ""
	_check(LevelList.save_levels(m, d), "levels save succeeds")
	var back := LevelList.load_levels(m)
	_check(str(back.get("mode", "")) == LevelList.MODE_LEVEL_SELECT, "levels mode round-trips")
	_check(str(back.get("start", "")) == "l2", "levels start round-trips")
	_check((back.get("levels", []) as Array).size() == 3, "levels entries round-trip")
	_check(str(LevelList.entry_of(back, "l2").get("map", "")) == "l2", "entry_of finds a level")

	var bad := {"mode": LevelList.MODE_METROIDVANIA, "start": "ghost", "levels": [
		{"map": "l1", "order": 1}, {"map": "l1", "order": 2}, {"map": "nope", "order": 3}]}
	var issues := Validate.validate_levels(m, bad)
	var has_missing := false
	var has_duplicate := false
	var has_start := false
	var has_unlisted := false
	for issue in issues:
		var msg := str(issue.get("message", ""))
		has_missing = has_missing or msg.contains("不存在的地图文件")
		has_duplicate = has_duplicate or msg.contains("重复出现")
		has_start = has_start or msg.contains("起始关指向不存在")
		has_unlisted = has_unlisted or msg.contains("未加入关卡清单")
	_check(has_missing, "levels validation detects a missing map file")
	_check(has_duplicate, "levels validation detects duplicate entries")
	_check(has_start, "levels validation detects a bad start level")
	_check(has_unlisted, "levels validation warns about unlisted maps")

	# 拓扑：l1 ↔ l2 双向连通，l3 孤立
	Store.write(m, "l1", _map([
		{"scene": "exit", "id": "e_1", "x": 1, "y": 1,
			"props": {"target_map": "l2", "target_point": "e_1"}},
	], "l1"))
	Store.write(m, "l2", _map([
		{"scene": "exit", "id": "e_1", "x": 1, "y": 1,
			"props": {"target_map": "l1", "target_point": "e_1"}},
	], "l2"))
	var graph := LevelList.build_world_graph(m, back)
	_check((graph.get("nodes", []) as Array).size() == 3, "world graph lists every map")
	_check((graph.get("edges", []) as Array).size() == 2, "world graph lists one edge per direction")
	var paired := 0
	for edge in graph.get("edges", []):
		if bool((edge as Dictionary).get("paired", false)):
			paired += 1
	_check(paired == 2, "both directions are marked paired")
	var unreachable := LevelList.unreachable_maps(graph, "l1")
	_check(unreachable.size() == 1 and str(unreachable[0]) == "l3",
		"reachability finds the isolated map")

	if FileAccess.file_exists(stale):
		DirAccess.remove_absolute(stale)
	for f in ["l1", "l2", "l3"]:
		var p := Store.path_for(m, f)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	DirAccess.remove_absolute(maps_dir)
	DirAccess.remove_absolute(base)

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

## 实体编辑器占位尺寸：需要真实游戏清单，未设置 BIRD_PROJECT 时跳过。
func _test_entity_editor_size() -> void:
	var project := OS.get_environment("BIRD_PROJECT")
	if project == "":
		print("SKIP entity_editor_size (BIRD_PROJECT unset)")
		return
	var manifest := Manifest.load_from(project)
	_check(not manifest.has("_error"), "game manifest loads from BIRD_PROJECT")
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

func _exit(ent_id: String, target_map: String, target_point: String) -> Dictionary:
	return {"scene": "exit", "id": ent_id, "x": 1, "y": 1,
		"props": {"target_map": target_map, "target_point": target_point}}

func _point(ent_id: String) -> Dictionary:
	return {"scene": "spawn_point", "id": ent_id, "x": 2, "y": 2, "props": {}}

func _edge(graph: Dictionary, from_map: String, to_map: String) -> Dictionary:
	for edge in graph.get("edges", []):
		if str(edge.get("from", "")) == from_map and str(edge.get("to", "")) == to_map:
			return edge
	return {}

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