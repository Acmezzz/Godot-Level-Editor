extends SceneTree

## 实例 functions 绑定回归（v2 §5.3）：经 extract → load_data 往返不丢（批次 B 引入的持久化契约）。
## （原属性表单撤销回归：表单已随 props_panel 删除；字符串字段/stats 的撤销
## 语义由 undo_history 的快照测试与 shortcut_test 覆盖。）

const CanvasScript := preload("res://src/canvas/editor_canvas.gd")

var canvas
var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	canvas = CanvasScript.new()
	root.add_child(canvas)
	canvas.manifest = {
		"tileSize": 16,
		"layers": [],
		"tiles": [],
		"entities": [{
			"id": "test_entity",
			"name": "Test Entity",
			"fields": [],
			"stats": [],
		}]
	}
	canvas.set_thumbs({})
	# —— v2 §5.3：functions 绑定经 extract → load_data 往返不丢（批次 B 引入的持久化契约） ——
	var fn_data := {
		"meta": {"name": "undo", "w": 8, "h": 6}, "spawn": [1, 1],
		"terrain": [], "decor": [], "collision": [],
		"entities": [{"scene": "test_entity", "id": "e_1", "x": 2, "y": 2, "props": {},
			"functions": [{"fn": "dialogue", "content": "TEST-test_entity-e_1-dialogue-DEMO01", "name": "问好", "order": 1, "parallel": true}]}],
	}
	await canvas.load_data(fn_data, "undo")
	var ex: Dictionary = canvas.extract()
	var ex_fns: Array = (ex.entities[0] as Dictionary).get("functions", [])
	_check(ex_fns.size() == 1
		and str((ex_fns[0] as Dictionary).get("fn", "")) == "dialogue"
		and str((ex_fns[0] as Dictionary).get("content", "")) == "TEST-test_entity-e_1-dialogue-DEMO01",
		"extract keeps the instance function binding (fn/content)")
	_check(bool((ex_fns[0] as Dictionary).get("parallel", false)),
		"extract keeps the parallel flag")
	await canvas.load_data(ex, "undo")
	var fns_meta: Array = (_current_entity().get_meta("functions", []) as Array)
	_check(fns_meta.size() == 1 and str((fns_meta[0] as Dictionary).get("name", "")) == "问好",
		"load_data restores the binding into sprite meta")
	canvas._push_undo()
	_current_entity().set_meta("functions", [])
	canvas._mark()
	_check(canvas.undo(), "undo available after clearing the binding")
	await process_frame
	var restored: Array = (_current_entity().get_meta("functions", []) as Array)
	_check(restored.size() == 1 and str((restored[0] as Dictionary).get("fn", "")) == "dialogue",
		"undo restores a cleared function binding")

	if is_instance_valid(canvas):
		canvas.queue_free()
	await process_frame
	if failures.is_empty():
		print("PROPS_UNDO_REGRESSION_OK")
		quit(0)
	else:
		for failure in failures:
			printerr("PROPS_UNDO_REGRESSION_FAIL: ", failure)
		quit(1)

func _current_entity() -> Sprite2D:
	for node in canvas.entities.get_children():
		if str(node.get_meta("ent_id", "")) == "e_1":
			return node as Sprite2D
	return null

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		printerr("PROPS_UNDO_REGRESSION_FAIL: ", message)
