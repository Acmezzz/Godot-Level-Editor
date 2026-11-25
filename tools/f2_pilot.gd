extends SceneTree
## F2 发布证据：用计划 §3 的「区域刷怪」最小接入片段跑真实加载链。
## 在一个临时游戏工程里：写 §3 清单 → Manifest 载入（补码/扫描）→ 建地图并放两个生成点实例
## → 建内容文件（两条「生成一组」步骤：数量 3/5、分别指向两个落点、at 0/2.5）
## → 重新从磁盘读取，逐项核对地图码/内容 ID/步骤码/字段码/配对数，最后清理。
## 用法：godot --headless --path . --script res://tools/f2_pilot.gd
const Manifest := preload("res://src/project/manifest.gd")
const MapStore := preload("res://src/map/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentId := preload("res://src/content/content_id.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const PILOT := "user://f2_pilot_project"

var fails: Array[String] = []
var checks := 0

func _init() -> void:
	call_deferred("_run")

func _ok(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		fails.append(msg)

func _run() -> void:
	_clean(PILOT)
	DirAccess.make_dir_recursive_absolute(PILOT.path_join("editor"))
	DirAccess.make_dir_recursive_absolute(PILOT.path_join("maps"))
	# §3 清单片段 + 两个生成点实体（编辑部需要真实资产载体）+ 刷怪区域
	var manifest_doc := {
		"projectName": "F2 试点",
		"tileSize": 16,
		"assets": [
			{"id": "spawner", "kind": "entity", "prefab": "spawner.tscn", "editorSize": [16, 16],
				"fields": [
					{"id": "link", "name": "连到", "kind": "input", "type": "entity_ref"},
					{"id": "kind", "name": "生成物", "kind": "input", "type": "string"},
				]},
		],
		"functions": {"spawn_wave": {"name": "刷怪", "steps": true, "timebase": "seconds",
			"fields": []}},
		"steps": {"spawn_group": {"name": "生成一组", "fields": [
			{"id": "count", "name": "数量", "kind": "input", "type": "int", "min": 1, "default": 3},
			{"id": "point", "name": "生成点", "kind": "choice", "source": "entity_inst:"},
		]}},
	}
	_write_json(PILOT.path_join("editor/editor_manifest.json"), manifest_doc)

	# —— 载入（和编辑器同一入口：补码 + 资产扫描 + 挂接项目目录）——
	var m := Manifest.load_from(PILOT)
	_ok(not m.has("_error"), "清单载入: " + str(m.get("_error", "")))
	_ok(str(m.get("_error", "")) == "", "清单无结构错误")
	var fn_code := FunctionDecls.fn_code(m, "spawn_wave")
	_ok(fn_code.length() == 4, "功能条目码已发放: " + fn_code)
	var step := StepDecls.step_by_code(m, _step_code_of(m, "spawn_group"))
	_ok(not step.is_empty(), "步骤池可查 spawn_group")
	var flds: Dictionary = {}
	for fd in (step.get("fields", []) as Array):
		flds[str((fd as Dictionary).get("id", ""))] = str((fd as Dictionary).get("code", ""))
	_ok(str(flds.get("count", "")).length() == 4, "步骤字段 count 有码: " + str(flds.get("count", "")))
	_ok(str(flds.get("point", "")).length() == 4, "步骤字段 point 有码: " + str(flds.get("point", "")))
	var ent_code := ""
	for a in (m.get("assets", []) as Array):
		if str((a as Dictionary).get("id", "")) == "spawner":
			ent_code = str((a as Dictionary).get("code", ""))
	_ok(ent_code.length() == 4, "实体资产码已发放: " + ent_code)

	# —— 建图：两个生成点实例 + 一个刷怪区域，绑定功能并写内容 ——
	var doc := MapStore.new_map("试点图", 30, 20)
	var map_code := str((doc.get("meta", {}) as Dictionary).get("code", ""))
	_ok(map_code.length() == 4, "地图码 4 位: " + map_code)
	var layer_id := str(((doc.meta.layers as Array)[0] as Dictionary).get("id", ""))
	var a_code := ContentId.new_inst_code()
	var b_code := ContentId.new_inst_code()
	var zone_code := ContentId.new_inst_code()
	var objects: Array = doc.get("objects", [])
	objects.append({"asset": "spawner", "code": a_code, "x": 4.0, "y": 4.0, "layer": layer_id,
		"props": {}, "functions": []})
	objects.append({"asset": "spawner", "code": b_code, "x": 12.0, "y": 4.0, "layer": layer_id,
		"props": {}, "functions": []})
	# 刷怪区域：同一资产作载体（试点约定），承载 spawn_wave 绑定
	var cid := ContentId.content_id(map_code, ent_code, zone_code, "spawn_wave")
	_ok(cid != "", "内容 ID 可拼出（四段身份齐备）")
	objects.append({"asset": "spawner", "code": zone_code, "x": 20.0, "y": 10.0, "layer": layer_id,
		"props": {},
		"functions": [{"fn": fn_code, "content": cid, "name": "", "order": 1, "parallel": false}]})
	doc["objects"] = objects
	_ok(MapStore.write(m, "试点图", doc), "地图落盘")

	# 内容文件：两条步骤，数量/落点/时间各不同
	var content := {
		"id": cid, "function": fn_code, "name": "spawn_wave",
		"fields": {},
		"steps": [
			{"step": "", "fields": {}, "at": 0.0, "duration": 0.0, "track": 0},
			{"step": "", "fields": {}, "at": 2.5, "duration": 0.0, "track": 0},
		],
	}
	var sc := _step_code_of(m, "spawn_group")
	(content.steps as Array)[0] = {"step": sc, "at": 0.0, "duration": 0.0, "track": 0,
		"fields": {str(flds["count"]): 3, str(flds["point"]): a_code}}
	(content.steps as Array)[1] = {"step": sc, "at": 2.5, "duration": 0.0, "track": 0,
		"fields": {str(flds["count"]): 5, str(flds["point"]): b_code}}
	_ok(ContentStore.write(m, "spawn_wave", cid, content), "内容文件落盘")

	# —— 重新从磁盘读（模拟关闭再打开项目）——
	var m2 := Manifest.load_from(PILOT)
	_ok(not m2.has("_error"), "二次载入无错")
	var r := MapStore.read_path(MapStore.path_for(m2, "试点图"), m2)
	_ok(bool(r.get("ok", false)), "重开地图通过校验")
	var d2: Dictionary = r.get("data", {})
	_ok(str((d2.get("meta", {}) as Dictionary).get("code", "")) == map_code, "地图码往返不变")
	var objs2: Array = d2.get("objects", [])
	_ok(objs2.size() == 3, "三个摆放物往返: " + str(objs2.size()))
	var zone: Dictionary = objs2[2]
	var fns: Array = zone.get("functions", [])
	_ok(fns.size() == 1 and str((fns[0] as Dictionary).get("content", "")) == cid, "绑定内容 ID 往返")
	var c_res := ContentStore.read_ex(m2, "spawn_wave", cid)
	_ok(str(c_res.get("status", "")) == "ok", "内容重读成功: " + str(c_res.get("error", "")))
	var cc: Dictionary = c_res.get("data", {})
	var steps2: Array = cc.get("steps", [])
	_ok(steps2.size() == 2, "两条步骤往返")
	_ok(str((steps2[0] as Dictionary).get("step", "")) == sc, "步骤码往返")
	var f0: Dictionary = (steps2[0] as Dictionary).get("fields", {})
	var f1: Dictionary = (steps2[1] as Dictionary).get("fields", {})
	_ok(int(f0.get(str(flds["count"]), 0)) == 3 and int(f1.get(str(flds["count"]), 0)) == 5,
		"两波数量 3/5 按字段码往返")
	_ok(str(f0.get(str(flds["point"]), "")) == a_code and str(f1.get(str(flds["point"]), "")) == b_code,
		"两个落点按实例码往返且可区分")
	_ok(is_equal_approx(float((steps2[0] as Dictionary).get("at", -1.0)), 0.0)
		and is_equal_approx(float((steps2[1] as Dictionary).get("at", -1.0)), 2.5),
		"at 0 / 2.5 往返（timebase=seconds 原单位）")
	# 实例引用字段的作用域解析：本图实例下拉应能列出两个落点且带码
	var lst := RefFields.map_instances(m2, map_code, ["spawner"])
	_ok(lst.size() == 3, "本图实例枚举 3 个（含区域载体）: " + str(lst.size()))
	var codes: Array = []
	for it in lst:
		codes.append(str((it as Dictionary).get("v", "")))
	_ok(codes.has(a_code) and codes.has(b_code), "两个落点码都在枚举里")

	_clean(PILOT)
	if fails.is_empty():
		print("F2_PILOT_OK checks=", checks)
	else:
		for f in fails:
			print("F2_PILOT_FAIL ", f)
	quit(0 if fails.is_empty() else 1)

func _step_code_of(m: Dictionary, sid: String) -> String:
	var d: Dictionary = StepDecls.step_decl(m, sid)
	return str(d.get("code", ""))

func _write_json(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

func _clean(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_clean(dir.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
