extends SceneTree
## 工具：headless 全量加载 src/ 下所有 .gd，检查入口和依赖是否能编译。
## 编辑器级 GDScript 警告由 release_check.py 通过 Godot 语言服务器单独读取。
## 用法：godot --headless --path . --script res://tools/warn_scan.gd

func _init() -> void:
	var files := []
	var stack := ["res://src"]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for dname in dir.get_directories():
			stack.append(dir_path.path_join(dname))
		for f in dir.get_files():
			if str(f).ends_with(".gd"):
				files.append(dir_path.path_join(f))
	files.sort()
	var fails := 0
	for f in files:
		var s = load(f)
		if not s is GDScript or not s.can_instantiate():
			print("LOAD-FAIL ", f)
			fails += 1
	print("SCAN-DONE files=%d fails=%d" % [files.size(), fails])
	quit(0 if not files.is_empty() and fails == 0 else 1)
