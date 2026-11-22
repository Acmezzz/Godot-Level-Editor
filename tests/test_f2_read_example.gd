extends "res://tests/_suite_base.gd"
## §7.6（F2）可手算对照的游戏读取示例：`door_toggle` 的三字段按**执行码**读，
## 缺键走声明 default；同一份声明以 dict / array 两种写法载入后解析到同一个内容目录。
## 这一组断言就是 GAME_SIDE_STANDARD §7.2 示例的运行时等价物。

const FunctionDecls := preload("res://src/content/function_decl.gd")
const ContentStore := preload("res://src/content/content_store.gd")

const TMP := "user://test_f2_read_example"

func _fields() -> Array:
	return [
		{"id": "require_flag", "code": "F1A2", "name": "前置标记", "kind": "input", "type": "string", "default": ""},
		{"id": "once", "code": "B3C4", "name": "只开一次", "kind": "input", "type": "bool", "default": false},
		{"id": "speed", "code": "E5D6", "name": "开门速度", "kind": "input", "type": "float", "default": 2.0, "min": 0.1, "max": 20.0},
	]

## 游戏侧最小读取：码 → 字段 id 的表 + 按码取值（缺键回退声明 default）。
func _read_by_code(manifest: Dictionary, data: Dictionary) -> Dictionary:
	var decl: Dictionary = FunctionDecls.functions(manifest).get("door_toggle", {})
	var by_code := {}
	for fd in (decl.get("fields", []) as Array):
		by_code[str((fd as Dictionary).get("code", ""))] = fd
	var f: Dictionary = data.get("fields", {}) if data.get("fields", null) is Dictionary else {}
	var out := {}
	for code in by_code:
		var fd2: Dictionary = by_code[code]
		var v = f.get(code, null)
		if v == null:
			v = fd2.get("default", null)
		out[str(fd2.get("id", ""))] = v
	return out

func test_door_toggle_hand_checked_example() -> void:
	var m := {"functions": {"door_toggle": {"name": "开关门", "code": "D9R4", "fields": _fields()}}}
	# 手算对照夹具：一次开门 = 需要 key、只开一次、速度 3.25 秒/格
	var got := _read_by_code(m, {"fields": {"F1A2": "key", "B3C4": true, "E5D6": 3.25}})
	eq(str(got.get("require_flag", "")), "key", "按码 F1A2 读到 key")
	eq(bool(got.get("once", false)), true, "按码 B3C4 读到 true")
	eq(float(got.get("speed", 0.0)), 3.25, "按码 E5D6 读到 3.25")
	# 缺键夹具：三个字段都回落到声明 default
	var empty := _read_by_code(m, {"fields": {}})
	eq(str(empty.get("require_flag", "X")), "", "缺键 → default 空串")
	eq(bool(empty.get("once", true)), false, "缺键 → default false")
	eq(float(empty.get("speed", 0.0)), 2.0, "缺键 → default 2.0")

func test_dict_and_array_forms_share_content_dir() -> void:
	DirAccess.make_dir_recursive_absolute(TMP.path_join("content"))
	var dict_form := {"_dir": TMP, "contentDir": "content",
		"functions": {"door_toggle": {"name": "开关门", "code": "D9R4", "fields": _fields()}}}
	var arr_form := {"_dir": TMP, "contentDir": "content",
		"functions": [{"id": "door_toggle", "name": "开关门", "code": "D9R4", "fields": _fields()}]}
	eq(ContentStore.path_for(dict_form, "door_toggle", "C001"), ContentStore.path_for(arr_form, "door_toggle", "C001"),
		"两种写法解析到同一个内容文件路径")
	eq(FunctionDecls.functions(arr_form)["door_toggle"].get("fields", []).size(), 3, "数组写法归一化后字段数一致")
	eq(ContentStore.declared_kinds(dict_form), ContentStore.declared_kinds(arr_form), "声明目录集一致")
	DirAccess.remove_absolute(TMP.path_join("content"))
	DirAccess.remove_absolute(TMP)

## 三种摆放形态都能被同一份 objects[] 读到：场景图片、prefab 实体、只有 visual 的实体。
func test_object_shapes_readable() -> void:
	var m := {"assets": [
		{"id": "A001", "kind": "scene", "shape": "image", "texture": "a.png"},
		{"id": "A002", "kind": "entity", "prefab": "p.tscn"},
		{"id": "A003", "kind": "entity", "visual": {"mode": "rect"}},
	]}
	var objs := [
		{"asset": "A001", "x": 1.0, "y": 2.0},
		{"asset": "A002", "code": "E001", "x": 3.0, "y": 4.0},
		{"asset": "A003", "code": "E002", "x": 5.0, "y": 6.0},
	]
	for o in objs:
		var ad := {}
		for a in (m.get("assets", []) as Array):
			if str((a as Dictionary).get("id", "")) == str((o as Dictionary).get("asset", "")):
				ad = a
		ok(not ad.is_empty(), "摆放物能找到资产声明: " + str((o as Dictionary).get("asset", "")))
		if str(ad.get("kind", "")) == "entity":
			ok(str(ad.get("prefab", "")) != "" or ad.get("visual", null) != null,
				"实体资产有 prefab 或 visual 之一: " + str(ad.get("id", "")))
		else:
			eq(str(ad.get("shape", "")), "image", "场景图片摆放物是 shape=image")
