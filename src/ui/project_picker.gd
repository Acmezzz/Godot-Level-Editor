extends RefCounted
## ProjectPicker：项目选择页 + 项目记忆（从 app.gd 拆出，宿主 = app）。
## 函数体逐字节原样迁入；跨边界引用经 host（app）转发——
## 同名 const 重声明 + 同名转发属性 + 同名包装方法，搬动文本零改动。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
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

## 同名包装方法（真实实现经 host 转发）
func show_picker(err := "") -> void:
	_show_picker(err)
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
	var background := ColorRect.new()
	background.color = Th.BG_BASE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var card := PanelContainer.new()
	card.custom_minimum_size.x = 640
	card.add_theme_stylebox_override("panel", Th.box(Th.BG_PANEL, Th.BORDER, 12, 24, 20))
	center.add_child(card)

	var v := Kit.vbox(14)
	card.add_child(v)
	v.add_child(Kit.text_label(str(ProjectSettings.get_setting("application/config/name")), Th.TEXT, 26))
	v.add_child(Kit.hint_label("打开游戏工程，编辑关卡、实例内容和资产。", 520))
	if err != "":
		v.add_child(Kit.wrap_label(err, 520, Th.ERR))
	var head := Kit.hbox(12)
	head.add_child(Kit.section_label("最近项目"))
	head.add_child(Kit.spacer())
	head.add_child(Kit.button("打开项目文件夹…", _pick_project, "primary"))
	v.add_child(head)
	if project_dirs.is_empty():
		var empty := Kit.empty_state("", "还没有项目", "选择包含 editor/editor_manifest.json 的游戏工程目录。")
		empty.custom_minimum_size.y = 106
		v.add_child(empty)
		return

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = minf(float(project_dirs.size()) * 64.0, 320.0)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var list := Kit.vbox(6)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for dir in project_dirs:
		list.add_child(_project_row(str(dir)))

## 移除只删最近项目记录，不修改工程文件。
func _project_row(dir: String) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", Th.box(Th.BG_BASE, Th.BORDER, Th.R_CONTROL, 12, 8))
	var row := Kit.hbox(10)
	card.add_child(row)
	var info := Kit.vbox(3)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	info.add_child(Kit.clipped_label(str(project_names.get(dir, dir.get_file())), Th.TEXT, Th.FS_MD))
	info.add_child(Kit.clipped_label(dir, Th.TEXT_DIM, Th.FS_SMALL))
	row.add_child(Kit.button("打开", func(): _open_project(dir)))
	var forget := Kit.button("移除记录", func():
		_forget_project(dir)
		_show_picker(), "ghost")
	forget.tooltip_text = "从最近项目中移除，工程文件保留"
	row.add_child(forget)
	return card

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
	fd.title = "打开项目文件夹"
	fd.ok_button_text = "选择文件夹"
	fd.cancel_button_text = "取消"
	fd.display_mode = FileDialog.DISPLAY_LIST
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	# 选完/取消都释放：否则每次点「打开项目」都会留下一个隐藏对话框
	fd.dir_selected.connect(func(dir: String):
		fd.queue_free()
		_on_project_picked(dir))
	fd.canceled.connect(func(): fd.queue_free())
	add_child(fd)
	fd.popup_centered(Vector2i(700, 500))

# —— 项目选定：读清单 → 进编辑器界面 ——
func _on_project_picked(dir: String) -> void:
	_open_project(dir)
