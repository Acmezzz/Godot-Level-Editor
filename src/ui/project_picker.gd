extends RefCounted
## ProjectPicker：项目选择页 + 项目记忆（从 app.gd 拆出，宿主 = app）。
## 函数体逐字节原样迁入；跨边界引用经 host（app）转发——
## 同名 const 重声明 + 同名转发属性 + 同名包装方法，搬动文本零改动。

const SettingsCfg := "user://settings.cfg"

var host   # app 宿主

func _init(h) -> void:
	host = h

## 同名转发属性（读写穿透到宿主）
var project_dirs:
	get: return host.project_dirs
	set(v): host.project_dirs = v
var project_names:
	get: return host.project_names
	set(v): host.project_names = v
var cur_project_dir:
	get: return host.cur_project_dir
	set(v): host.cur_project_dir = v
var manifest:
	get: return host.manifest
	set(v): host.manifest = v
var _ent_thumbs_cache:
	get: return host._ent_thumbs_cache
	set(v): host._ent_thumbs_cache = v

## 同名包装方法（真实实现经 host 转发）
func show_picker(err := "") -> void:
	host._show_picker(err)
func _build_editor_ui() -> void:
	host._build_editor_ui()
func enter_project(dir: String, loaded_manifest: Dictionary) -> void:
	host._enter_project(dir, loaded_manifest)
func remember_project(dir: String, pname: String) -> void:
	_remember_project(dir, pname)
func add_child(c: Node) -> void:
	host.add_child(c)
func get_children():
	return host.get_children()
func remove_child(c: Node) -> void:
	host.remove_child(c)

func _load_projects() -> void:
	var cf := ConfigFile.new()
	if cf.load(SettingsCfg) == OK:
		var dirs = cf.get_value("projects", "dirs", [])
		if dirs is Array:
			for d in dirs:
				if str(d) != "" and not project_dirs.has(str(d)):
					project_dirs.append(str(d))
		var names = cf.get_value("projects", "names", {})
		if names is Dictionary:
			project_names = (names as Dictionary).duplicate()
		cur_project_dir = str(cf.get_value("projects", "last", ""))
		# 兼容单项目旧格式
		var old := str(cf.get_value("project", "dir", ""))
		if old != "" and not project_dirs.has(old):
			project_dirs.append(old)
			if cur_project_dir == "":
				cur_project_dir = old

func _save_projects() -> void:
	var cf := ConfigFile.new()
	cf.set_value("projects", "dirs", project_dirs)
	cf.set_value("projects", "names", project_names)
	cf.set_value("projects", "last", cur_project_dir)
	cf.save(SettingsCfg)

## 登记一个项目到列表头（最近使用置顶）；名字取清单 projectName，缺省用目录名。
func _remember_project(dir: String, pname: String) -> void:
	project_dirs.erase(dir)
	project_dirs.push_front(dir)
	project_names[dir] = pname if pname != "" else dir.get_file()
	cur_project_dir = dir
	_save_projects()

func _forget_project(dir: String) -> void:
	project_dirs.erase(dir)
	project_names.erase(dir)
	if cur_project_dir == dir:
		cur_project_dir = ""
	_save_projects()

# —— 项目选择页 ——
func _show_picker(err := "") -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 10)
	add_child(v)
	var t := Label.new()
	t.text = "关卡编辑器"
	t.add_theme_font_size_override("font_size", 28)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var hint := Label.new()
	hint.text = "选一个游戏项目（内含 editor/editor_manifest.json）；可同时管理多个项目"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(hint)
	if err != "":
		var el := Label.new()
		el.text = err
		el.modulate = Color(1, 0.4, 0.4)
		el.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(el)
	if not project_dirs.is_empty():
		# E3：项目多的长列表要有滚动路径（U05）。选择页整列铺满窗口、内容居中，
		# 列表占据剩余高度并在其中滚动，不会把按钮顶出可视区。
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(520, 0)
		scroll.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		v.add_child(scroll)
		var list := VBoxContainer.new()
		list.custom_minimum_size = Vector2(520, 0)
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(list)
		for dir in project_dirs:
			list.add_child(_project_row(str(dir)))
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		var add := Button.new()
		add.text = "打开其它项目文件夹…"
		add.pressed.connect(_pick_project)
		row.add_child(add)
		v.add_child(row)
	else:
		var hb := HBoxContainer.new()
		hb.alignment = BoxContainer.ALIGNMENT_CENTER
		var btn := Button.new()
		btn.text = "打开项目文件夹…"
		btn.pressed.connect(_pick_project)
		hb.add_child(btn)
		v.add_child(hb)

## 选择页的一行：项目名（+ 路径）+ 「打开」+「移除记录」。
## 移除只删记录不动磁盘——用户可能只是临时不想看见它。
func _project_row(dir: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := Label.new()
	nm.text = str(project_names.get(dir, dir.get_file()))
	nm.add_theme_font_size_override("font_size", 16)
	info.add_child(nm)
	var path_lbl := Label.new()
	path_lbl.text = dir
	path_lbl.modulate = Color(1, 1, 1, 0.5)
	path_lbl.add_theme_font_size_override("font_size", 11)
	info.add_child(path_lbl)
	row.add_child(info)
	var open := Button.new()
	open.text = "打开"
	open.pressed.connect(func(): _open_project(dir))
	row.add_child(open)
	var forget := Button.new()
	forget.text = "移除记录"
	forget.pressed.connect(func():
		_forget_project(dir)
		_show_picker())
	row.add_child(forget)
	return row

## 从列表里选一个项目打开；清单坏了就回选择页并说明原因。
func _open_project(dir: String) -> void:
	var m := EditorManifest.load_from(dir)
	if m.has("_error"):
		_show_picker(m["_error"])
		return
	manifest = m
	enter_project(dir, m)

func _pick_project() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.dir_selected.connect(_on_project_picked)
	add_child(fd)
	fd.popup_centered(Vector2i(700, 500))

# —— 项目选定：读清单 → 进编辑器界面 ——
func _on_project_picked(dir: String) -> void:
	_open_project(dir)
