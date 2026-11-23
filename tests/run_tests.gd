extends SceneTree
## 测试入口（headless）：godot --headless --path . --script res://tests/run_tests.gd
## 发现 res://tests/ 下所有 test_*.gd，逐个实例化并运行 test_* 方法。
## 无断言或运行期脚本异常均判失败。
## 退出码：失败用例 > 0 时 1，否则 0（门禁式用法）。

const ScriptErrorCapture := preload("res://addons/godot_ai/testing/script_error_capture.gd")

func _init() -> void:
	var capture := ScriptErrorCapture.new()
	OS.add_logger(capture)
	var dir := DirAccess.open("res://tests")
	var suites := []
	if dir != null:
		for f in dir.get_files():
			if str(f).begins_with("test_") and str(f).ends_with(".gd"):
				suites.append("res://tests/" + str(f))
	suites.sort()
	var passed := 0
	var failed := 0
	for path in suites:
		var s = load(path)
		if s == null or not (s is GDScript):
			print("SUITE-LOAD-FAIL ", path)
			failed += 1
			continue
		var inst = (s as GDScript).new()
		for m in inst.get_method_list():
			var mname: String = str(m.name)
			if not mname.begins_with("test_"):
				continue
			inst.failures.clear()
			var n0: int = inst.assert_count
			capture.begin_capture()
			inst.call(mname)
			var errors := capture.end_capture()
			for error in errors:
				print("FAIL  ", path.get_file(), " :: ", mname, " :: ", error)
			var crashed: bool = inst.assert_count == n0
			for msg in inst.failures:
				print("FAIL  ", path.get_file(), " :: ", mname, " :: ", msg)
			if crashed:
				print("FAIL  ", path.get_file(), " :: ", mname, " :: 无断言（用例中途崩溃？）")
				failed += 1
			elif inst.failures.is_empty() and errors.is_empty():
				passed += 1
				print("PASS  ", path.get_file(), " :: ", mname)
			else:
				failed += 1
	OS.remove_logger(capture)
	print("TESTS-DONE passed=%d failed=%d" % [passed, failed])
	quit(1 if failed > 0 else 0)
