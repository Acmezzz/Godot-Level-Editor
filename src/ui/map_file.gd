extends RefCounted
## 地图文件生命周期控制器：新建/打开/保存/改名（纯改名，引用不迁移）/
## 自动保存/试玩/尺寸/导出。状态经宿主访问；写盘统一走 MapStore
## （.tmp 原子替换，正式保存带 .history 轮转备份）。
const MapExport := preload("res://src/map/map_export.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")
const K := preload("res://src/core/constants.gd")
const MapStore := preload("res://src/map/map_store.gd")
const Recovery := preload("res://src/map/recovery.gd")

var app   # 宿主引用

func _init(host) -> void:
	app = host

const AUTOSAVE_INTERVAL_MS := 120000
var _last_autosave_msec := 0
var _opened_mtime := 0   # A4.3：打开地图时记录的磁盘 mtime（保存时对比检测外部改动）
var _last_alive_poll := 0   # PF-04：存活轮询节流
var _play_pid := 0
var _play_started_msec: int = 0
var _play_program := ""        # A6：实际启动的程序（结构化配置的 exe 或模板首个 token）
var _play_args_text := ""      # A6：实际参数（数组直启时原样，模板时为空）
var _play_tracked := true      # false = 跟踪的是包装进程（playCommand 模板）
## 文档身份（A2）：切图/退出/保存都用它判断“当前请求是否仍是同一个文档”。
## generation 每次切图自增；await 回来后代次不符 = 请求已过期，绝不发布图名/路径/基线。
var _doc_generation := 0
var _doc_project_root := ""
## 打开/上次保存时目标文件的文本摘要（A2）：同秒同长度的外部改动靠它识别——
## mtime 是秒级粒度，长度也可能撞巧，摘要才是可靠基线。
var _opened_digest := ""
## 最近一次在新建/重命名弹窗里确认的名字（顶栏常驻名字框已移除，这里记住值供预填）
var _name_memo := ""

## 进入一次会影响当前文档的操作（新建/切图）：抬代数并返回本次代次。
func _begin_doc_op() -> int:
	_doc_generation += 1
	return _doc_generation

## 本次请求是否已过期（期间又切了图/退出了项目）。过期请求不得发布图名/路径。
func _doc_stale(gen: int) -> bool:
	return gen != _doc_generation

## 文件内容摘要；不存在/打不开返回 ""。
func _file_digest(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var d := f.get_as_text().sha256_text()
	f.close()
	return d

## 项目 maps 目录内的未占用名字（D03）：外部地图导入绝不覆盖同名项目图。
func _unique_map_name(base: String) -> String:
	if not FileAccess.file_exists(EditorManifest.map_path(app.manifest, base)):
		return base
	var i := 2
	while i < 1000:
		var cand := "%s_%d" % [base, i]
		if not FileAccess.file_exists(EditorManifest.map_path(app.manifest, cand)):
			return cand
		i += 1
	return base + "_imported"

## 地图文件生命周期——新建/打开/保存/改名（纯改名，引用不迁移）/自动保存/试玩/尺寸/导出
func confirm_discard(action: String) -> bool:
	if not app.map_loaded or not app.canvas.modified_flag:
		return true
	# 确认框开着时冻结撤销/重做（A2）：期间 Ctrl+Z 把画布换掉，用户确认的就不是同一份内容
	if app.canvas != null:
		app.canvas.doc_busy = true
	var answer := await _ask_discard(action)
	_release_busy()
	return answer

func _ask_discard(action: String) -> bool:
	var dlg := ConfirmationDialog.new()
	dlg.title = "未保存的修改"
	dlg.dialog_text = "地图 %s 有未保存修改。\n继续%s将丢失这些修改。" % [app.cur_map_name, action]
	# 自动保存草稿存得进、捞不出——放弃修改时至少把草稿路径说出来，
	# 否则用户以为这份保险不存在。草稿在「打开」里同样可被识别并归位（见 load_map_file）。
	var draft_path := str(app.manifest.get("_maps_dir", "")).path_join(str(app.cur_map_name) + ".autosave.json")
	if FileAccess.file_exists(draft_path):
		dlg.dialog_text += "\n\n最近一次自动保存的草稿在：\n%s\n放弃后仍可从「打开」中载入它找回内容。" % draft_path
	dlg.ok_button_text = "放弃修改并继续"
	dlg.cancel_button_text = "取消"
	# 中文正文需要足够宽度，否则 ConfirmationDialog 的 Label 会被压成一条看不见的窄条
	dlg.min_size = Vector2i(460, 0)
	app.add_child(dlg)
	var answer := [false]
	dlg.confirmed.connect(func(): answer[0] = true)
	dlg.popup_centered()
	# 等对话框真正关闭：确认 → true，取消/关闭 → false
	while dlg.visible:
		await app.get_tree().process_frame
	dlg.queue_free()
	return answer[0]

## 通用确认框：删除/不可撤销动作统一走这里（文本与确定钮文案可定制）
func confirm_action(title: String, text: String, ok_text := "确定", _danger := false) -> bool:
	var dlg := ConfirmationDialog.new()
	dlg.title = title
	dlg.dialog_text = text
	dlg.ok_button_text = ok_text
	dlg.cancel_button_text = "取消"
	dlg.min_size = Vector2i(460, 0)
	app.add_child(dlg)
	var answer := [false]
	dlg.confirmed.connect(func(): answer[0] = true)
	dlg.popup_centered()
	while dlg.visible:
		await app.get_tree().process_frame
	dlg.queue_free()
	return answer[0]

## 新建地图：名字在弹窗里输入（顶栏已无常驻名字框）
func on_new() -> void:
	var shell: Dictionary = app._popup_body("新建地图", "名字同时作文件名与显示名。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	# 记住上次填的名字，但已存在的名字不预填（否则一按确定必然撞重名）
	if _name_memo != "" and not FileAccess.file_exists(EditorManifest.map_path(app.manifest, _name_memo)):
		name_edit.text = _name_memo
	name_edit.placeholder_text = "地图名"
	body.add_child(UiKitScript.field_row("地图名", name_edit))
	var err_label := UiKitScript.text_label("", UiThemeScript.WARN, UiThemeScript.FS_SMALL)
	err_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_label.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	body.add_child(err_label)
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("确定",
		func(): create_map_from_dialog(name_edit, err_label, pop), "primary"))
	name_edit.text_submitted.connect(func(_t: String): create_map_from_dialog(name_edit, err_label, pop))
	body.add_child(btn_row)
	app._open_popup(pop)

## 新建弹窗确定：校验 → 未保存确认 → 载入空图
func create_map_from_dialog(name_edit: LineEdit, err_label: Label, pop: PopupPanel) -> void:
	var n: String = name_edit.text.strip_edges()
	if n == "":
		err_label.text = "先填地图名"
		return
	if not EditorManifest.is_valid_map_name(n):
		err_label.text = "地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头"
		return
	if FileAccess.file_exists(EditorManifest.map_path(app.manifest, n)):
		err_label.text = "同名地图已存在：换个名字，或直接打开它"
		return
	err_label.text = ""
	_name_memo = n
	# 先收新建弹窗再开确认框：确认框是模态窗口，会让新建弹窗失焦自动 hide，
	# 而 hide 连带 queue_free——之后确认框还要 await，留着也会被释放。
	pop.hide()
	if not await confirm_discard("新建"):
		return
	var gen := _begin_doc_op()
	app.canvas.set_thumbs(app._entity_thumbs())
	await app.canvas.load_data(MapStore.new_map(n, K.DEFAULT_MAP_W, K.DEFAULT_MAP_H), n)
	if _doc_stale(gen):
		return   # 期间又切了别的图：本次载入结果已被更新的一次重建取代
	app.cur_map_name = n
	app.cur_map_path = EditorManifest.map_path(app.manifest, n)
	_doc_project_root = str(app.manifest.get("_dir", ""))
	_opened_mtime = 0
	_opened_digest = ""
	app._sync_play_cfg_to_map()
	app._set_map_loaded(true)
	app.canvas.undo_stack.clear()
	app.canvas.redo_stack.clear()
	app._set_status(" 新建空地图 " + n + "（先保存再试玩）")

## 重命名当前地图：弹窗输入新名（顶栏名字框已移除，就地改名入口改到这里）
func on_rename() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var old_name: String = _effective_map_name()
	if old_name == "":
		app._set_status("当前地图没有名字，无法重命名")
		return
	var shell: Dictionary = app._popup_body("重命名地图", "只改文件名与显示名，跨图引用不迁移；还没存过盘的新图会按新名直接保存。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	# 当前名就是上次「新建」时填的名字（打开/改名也会同步 _name_memo）
	name_edit.text = old_name
	name_edit.placeholder_text = "地图名"
	body.add_child(UiKitScript.field_row("新名字", name_edit))
	var err_label := UiKitScript.text_label("", UiThemeScript.WARN, UiThemeScript.FS_SMALL)
	err_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_label.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	body.add_child(err_label)
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("确定",
		func(): rename_current_from_dialog(old_name, name_edit, err_label, pop), "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

## 重命名弹窗确定：校验 → MapStore.rename_map → 同步当前名/路径
func rename_current_from_dialog(old_name: String, name_edit: LineEdit, err_label: Label, pop: PopupPanel) -> void:
	var nn: String = name_edit.text.strip_edges()
	if nn == "" or nn == old_name:
		pop.hide()
		return
	if not EditorManifest.is_valid_map_name(nn):
		err_label.text = "地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头"
		return
	# 真正的文件级改名（含「未落盘 → 按新名写盘」）统一走 rename_map_now
	var was_on_disk := FileAccess.file_exists(EditorManifest.map_path(app.manifest, old_name))
	var err := rename_map_now(old_name, nn, true)
	if err != "":
		err_label.text = "改名失败：" + err
		return
	pop.hide()
	if was_on_disk:
		app._set_status("已改名：%s → %s（引用未迁移）" % [old_name, nn])
	else:
		app._set_status("已改名并保存：%s → %s（原图未落盘，已按新名写入磁盘）" % [old_name, nn])

## 真正的地图重命名：改文件（或按新名落盘）+ 同步当前编辑身份。
## 返回错误信息，"" = 成功。allow_write_unsaved 允许「原图还没落盘」时把画布内容按新名写盘
## （只有当前正在编辑的那张图才有内容可写；清单里的幽灵条目不能凭空造文件）。
func rename_map_now(old_name: String, new_name: String, allow_write_unsaved := false) -> String:
	var nn := new_name.strip_edges()
	if nn == "" or nn == old_name:
		return ""
	if not EditorManifest.is_valid_map_name(nn):
		return "名称非法"
	var old_path := EditorManifest.map_path(app.manifest, old_name)
	var new_path := EditorManifest.map_path(app.manifest, nn)
	if new_path == "":
		return "名称非法"
	if FileAccess.file_exists(new_path):
		return "同名地图已存在"
	var is_current: bool = app.map_loaded and old_name == _effective_map_name()
	var on_disk := old_path != "" and FileAccess.file_exists(old_path)
	if on_disk:
		var err: String = app.MapStore.rename_map(app.manifest, old_name, nn)
		if err != "":
			return err
	elif allow_write_unsaved and is_current:
		# 原图未落盘（新建后还没保存）：改名必须真正落地，否则只改内存名 =
		# 面板显示新名、磁盘上始终没文件，用户看到的「重命名」是假的。
		var data: Dictionary = app.canvas.extract()
		if data.is_empty():   # 重建窗口哨兵：此刻写盘会把空图落成新文件
			return " 地图重建中，请稍后再试"
		data.meta.name = nn
		if not app.MapStore.write(app.manifest, nn, data):
			return "无法写入 " + new_path
	else:
		return "原图不存在（先保存该地图）"
	if is_current:
		_name_memo = nn
		app.cur_map_name = nn
		app.cur_map_path = new_path
		app.canvas.cur_map_name = nn
		if app.canvas.map_data.has("meta"):
			app.canvas.map_data["meta"]["name"] = nn
		# 历史随地图码走（A3）：码不变则目录不变；无码兜底到图名的旧记录搬到新名下
		var mcode := str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", ""))
		Recovery.migrate_history(app.manifest, mcode, old_name, mcode, nn)
		_opened_mtime = FileAccess.get_modified_time(new_path)
		_opened_digest = _file_digest(new_path)
		# 刚才已把内容写进新文件：脏标记与自动保存计时归零，
		# 否则状态栏还挂着「未保存」、两分钟后又多写一份 .autosave.json。
		if not on_disk:
			app.canvas.modified_flag = false
			_last_autosave_msec = Time.get_ticks_msec()
		app._sync_play_cfg_to_map()
	return ""

func on_open() -> void:
	if not await confirm_discard("打开另一张地图"):
		return
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.current_dir = str(app.manifest.get("_maps_dir", ""))
	fd.add_filter("*.json")
	fd.file_selected.connect(load_map_file)
	app.add_child(fd)
	fd.popup_centered(Vector2i(700, 500))

func load_map_file(p: String) -> void:
	# load_data 是协程（节点重建中间 await 一帧）：必须等它完成，否则切图刚返回时
	# 实体还在重建中——内容页 after_switch 刷新会拿到半重建的画布（列表/点选全乱）。
	# 文档代次（A2）：双击/连续切图时只有最后一次请求可以发布图名与路径。
	# 未保存确认在上层入口（打开/侧栏）做；这里只做真实载入。
	var gen := _begin_doc_op()
	var result: Dictionary = app.MapStore.read_path(p, app.manifest)
	if not result.ok:
		app._set_status(" 打开失败: " + _format_issues(result.errors))
		return
	var data: Dictionary = result.data
	if not result.warnings.is_empty():
		app._set_status(" 地图已打开但有兼容警告: " + _format_issues(result.warnings))
	# 旧草稿归位（A3）：maps/<名>.autosave.json 只有在带 _autosave_of 时才算草稿来源；
	# 缺标记的按普通地图处理（不擅自当成草稿，也不会静默丢文件）。
	var was_draft := str(p.get_file()).ends_with(".autosave.json")
	var base := p.get_file().get_basename()
	if was_draft:
		var owner := Recovery.legacy_draft_owner(app.manifest, p)
		if owner != "":
			base = owner if owner != base.trim_suffix(".autosave") else base.trim_suffix(".autosave")
			p = EditorManifest.map_path(app.manifest, base)
		else:
			was_draft = false   # 无来源标记：就是一普通地图文件，名字保留 .autosave
	# 正式保存剥离 _autosave_of：重开时按正式图识别
	if data.has("_autosave_of"):
		data.erase("_autosave_of")
	# 只认项目 maps 目录内的正式文件（D03）：项目外/别处的同名图必须显式导入，
	# 否则保存会按当前项目拼路径，悄悄覆盖另一个文件。
	var canon := str(p).simplify_path()
	var maps_root := str(app.manifest.get("_maps_dir", "")).simplify_path()
	var outside := maps_root != "" and not canon.begins_with(maps_root.path_join(""))
	if outside and not was_draft:
		if not await app._confirm_action("导入外部地图",
			"这张图不在当前项目的 maps 目录内：\n%s\n\n导入会把它复制为项目内的 %s.json。" % [canon, base],
			"导入并打开"):
			return
		# D03：导入目标不能是已存在的项目图——同名不同内容时覆盖等于删掉别人的图
		var target := _unique_map_name(base)
		if target != base:
			app._set_status(" 项目内已有同名地图，导入为 " + target + ".json")
		base = target
		if not app.MapStore.write(app.manifest, base, data):
			app._set_status("导入失败：无法写入 " + EditorManifest.map_path(app.manifest, base))
			return
		p = EditorManifest.map_path(app.manifest, base)
		canon = str(p).simplify_path()
		if target == base:
			app._set_status("已导入外部地图 → " + p)
	if _doc_stale(gen):
		return   # 读取/确认期间又发起了更新的切图请求：本次不再改画布
	_opened_mtime = FileAccess.get_modified_time(p)
	_opened_digest = _file_digest(p)
	app.canvas.set_thumbs(app._entity_thumbs())
	await app.canvas.load_data(data, base)
	if _doc_stale(gen):
		return
	app.cur_map_name = base
	app._sync_play_cfg_to_map()
	app.cur_map_path = p
	_name_memo = base
	app._set_map_loaded(true)
	app.canvas.undo_stack.clear()
	app.canvas.redo_stack.clear()
	# 画布重建成功后才发布项目根（A2）：外部导入/切项目期间路径已变，旧根不得残留
	_doc_project_root = str(app.manifest.get("_dir", ""))
	var tcount := 0
	for lid in (data.get("tiles", {}) as Dictionary):
		tcount += ((data.get("tiles", {}) as Dictionary)[lid] as Array).size()
	var objs: Array = data.get("objects", [])
	app._set_status(" 已打开 %s%s（%d 瓦片 / %d 摆放物）" % [
		base, "（草稿归位，保存写回正式文件）" if was_draft else "", tcount, objs.size()])

func _format_issues(issues: Array) -> String:
	var lines: Array[String] = []
	for issue in issues:
		lines.append("%s: %s" % [str(issue.get("path", "map")), str(issue.get("message", "invalid data"))])
	return "; ".join(lines)

## 当前地图名的兜底对齐：app.cur_map_name 与 canvas.cur_map_name 两处记录，以 canvas 为准
func _effective_map_name() -> String:
	var n: String = str(app.cur_map_name).strip_edges()
	var cname: String = str(app.canvas.cur_map_name)
	if cname != "" and cname != n:
		var cpath := EditorManifest.map_path(app.manifest, cname)
		if FileAccess.file_exists(cpath):
			app.cur_map_name = cname
			app.cur_map_path = cpath
			_opened_mtime = FileAccess.get_modified_time(cpath)
			_opened_digest = _file_digest(cpath)
			return cname
	return n

## 统一提交入口（A2）：先结束编辑手势，再按「清单 → 内容 → 地图」顺序落盘。
## 返回 {status, written, error}；status = ok / cancelled / failed。
## 任何一步失败即停，已写文件保留，调用方按 written 显示脏状态。
func commit_document(reason := "") -> Dictionary:
	if app.canvas != null and app.canvas.has_method("end_gesture"):
		app.canvas.end_gesture()
	if app.canvas != null:
		app.canvas.doc_busy = true   # 确认/写入期间冻结撤销与重做
	var written: Array = []
	# 0) 多文件提交日志（A3）：首次改写前登记各目标基线/预期；成功全部写完后清除。
	#    崩溃或中途失败时，下次启动 scan_pending 能判断哪些已写、哪些可同 ID 重试。
	var log_entries: Array = []
	if app.map_loaded and app.cur_map_path != "" and FileAccess.file_exists(app.cur_map_path):
		log_entries.append({"path": app.cur_map_path, "baseline": _opened_digest,
			"expect": "", "kind": "map", "id": app.cur_map_name})
	if bool(app.manifest.get("_codes_issued", false)):
		log_entries.append({"path": str(app.manifest.get("_dir", "")).path_join("editor/editor_manifest.json"),
			"baseline": "", "expect": "", "kind": "manifest", "id": ""})
	if app.project_shell != null and app.project_shell.content_editor != null:
		for pf in app.project_shell.content_editor.pending_paths():
			log_entries.append({"path": pf, "baseline": "", "expect": "", "kind": "content", "id": ""})
	var log_path := Recovery.begin_pending(app.manifest, reason, log_entries) if not log_entries.is_empty() else ""
	# 1) 清单补发的身份码（内容/地图引用它们之前必须落盘）：顺序不能和内容对调——
	# 内容文件里带的是执行码，清单没写成功就写内容会留下查无对应的码。
	if bool(app.manifest.get("_codes_issued", false)):
		if not await app._save_manifest_file_async():
			_release_busy()
			# 日志保留：下次启动能看出「清单未写/内容未写」，按同 ID 重试（A3）
			return {"status": "cancelled", "written": written, "error": "清单补码保存被取消或失败"}
		written.append("manifest")
		Recovery.mark_pending_done(app.manifest, log_path, 0)
	# 2) 内容页正在编辑的连续控件值 + 暂存内容（新 ID/新绑定）
	if app.project_shell != null and app.project_shell.content_editor != null:
		var staged_before: bool = app.project_shell.content_editor.has_staged_content()
		if not app.project_shell.content_editor.commit():
			_release_busy()
			return {"status": "failed", "written": written, "error": "暂存内容写盘失败"}
		if staged_before:
			written.append("content")
	# 3) 地图
	if app.map_loaded and app.canvas != null and app.canvas.modified_flag:
		if not await on_save():
			_release_busy()
			return {"status": "failed", "written": written, "error": "地图保存失败"}
		written.append("map")
	_release_busy()
	# 全部写成功：提交日志完成使命（A3）
	Recovery.clear_pending(app.manifest, log_path)
	if reason != "":
		app._set_status(" 已提交（%s）%s" % [reason, ("：" + ", ".join(PackedStringArray(written))) if not written.is_empty() else "：无待写改动"])
	return {"status": "ok", "written": written, "error": ""}

## 解除文档忙状态（保存失败/取消路径也必须走到，否则撤销永久失效）
func _release_busy() -> void:
	if app.canvas != null:
		app.canvas.doc_busy = false

## 保存当前地图；返回是否成功（试玩前依赖它决定是否继续）
## 直接入口（Ctrl+S）也冻结撤销/重做；已在 commit_document 内嵌套调用时沿用外层标记。
func on_save() -> bool:
	if app.canvas == null or app.canvas.doc_busy:
		return await _save_now()
	app.canvas.doc_busy = true
	var ok := await _save_now()
	_release_busy()
	return ok

func _save_now() -> bool:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return false
	var gen := _doc_generation   # 保存属于发起时的那个文档（A2）：等待后必须仍指向同一份
	var n: String = _effective_map_name()
	if n == "":
		app._set_status(" 当前地图没有名字：先「新建地图」并填名字")
		return false
	if not EditorManifest.is_valid_map_name(n):
		app._set_status(" 地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头")
		return false
	var data: Dictionary = app.canvas.extract()
	if data.is_empty():   # 重建窗口哨兵：绝不能把空快照写盘
		app._set_status(" 地图重建中，保存已跳过：请稍后再试")
		return false
	# 依赖身份先落盘（D06）：本次画布可能用到刚补发的资产码/功能码；地图引用它们前
	# 清单必须先写成功，否则取消/前置失败会留下指向不存在身份的地图。
	if bool(app.manifest.get("_codes_issued", false)):
		if not await app._save_manifest_file_async():
			app._set_status(" 保存中止：清单补码写入失败，地图未写盘")
			return false
	data.meta.name = n
	MapStore.ensure_code(app.manifest, data)   # 地图码（v7）：保存时补发，跨图引用写码的前提
	var path := EditorManifest.map_path(app.manifest, n)
	if path == "":
		app._set_status(" 地图名不合法: " + n)
		return false
	# 保存期间项目/文档被换掉（确认框还开着时切了项目）：此时代次不同，写盘会落到别的项目
	if _doc_stale(gen) or (_doc_project_root != "" and _doc_project_root != str(app.manifest.get("_dir", ""))):
		app._set_status(" 保存中止：文档已切换，本次改动未写入")
		return false
	# 外部变更检测——打开后磁盘内容变了 = 别处改过这份文件（本次保存会覆盖外部改动）。
	# 摘要优先（A2）：mtime 是秒级粒度，同秒同长度的外部编辑 mtime/长度都撞得上，只有内容摘要能识别。
	var ext_changed := false
	if FileAccess.file_exists(path):
		var cur_digest := _file_digest(path)
		if _opened_digest != "" and cur_digest != "":
			ext_changed = cur_digest != _opened_digest
		elif _opened_mtime > 0:
			ext_changed = FileAccess.get_modified_time(path) != _opened_mtime
	# 基线随确认更新：用户确认覆盖的就是「此刻这份内容」，之后若再被改才中止
	var baseline := _opened_digest
	if ext_changed:
		# C-20：保存前确认而不是覆盖后提示——外部改动是别人的工作，覆盖是破坏性动作
		if not await app._confirm_action("外部改动",
			"地图文件在编辑器打开后被外部修改过。\n覆盖保存将丢失外部改动（上一轮已在 maps/.history 自动备份）。",
			"覆盖保存"):
			app._set_status(" 已取消保存（保留磁盘上的外部改动）")
			return false
		baseline = _file_digest(path)
	# 确认等待期间内容又被外部改过：避免「确认的是 A、覆盖的是 B」
	if baseline != "" and FileAccess.file_exists(path) and _file_digest(path) != baseline:
		app._set_status(" 保存中止：确认期间文件又被外部改写，请重新检查后再保存")
		return false
	# 写盘收敛到 MapStore 单入口（.tmp 原子替换，中途崩溃不留半截 JSON）；
	# 写前校验不过时把首个错误带回状态栏，避免只看到「保存失败」无从下手。
	if not app.MapStore.write(app.manifest, n, data):
		var why: String = app.MapStore.write_error(app.manifest, data)
		app._set_status(" 保存失败: %s%s" % [path, ("（%s）" % why) if why != "" else ""])
		return false
	_opened_mtime = FileAccess.get_modified_time(path)
	_opened_digest = _file_digest(path)
	app.canvas.cur_map_name = n
	app.canvas.map_data["meta"] = data.meta
	app.cur_map_name = n
	app.cur_map_path = path
	app._sync_play_cfg_to_map()
	app.canvas.modified_flag = false
	_last_autosave_msec = Time.get_ticks_msec()
	var tcount2 := 0
	for lid2 in (data.get("tiles", {}) as Dictionary):
		tcount2 += ((data.get("tiles", {}) as Dictionary)[lid2] as Array).size()
	var msg := " 已保存 %s（%d 瓦片 / %d 摆放物）" % [n, tcount2, (data.get("objects", []) as Array).size()]
	app._set_status(msg)
	# 正式保存成功：草稿完成使命，删掉（A3）；历史快照此时才纳入（见 MapStore.write）
	_drop_draft_for(n)
	return true

## 自动保存草稿（A3）：写到 <项目>/editor/drafts/<地图码>.json，记录目标路径、
## 正式图基线摘要、地图快照、待提交文件与预留 ID，供崩溃/退出后整份恢复。
## 旧位置（maps/<名>.autosave.json）只在 _autosave_of 命中时作为来源兼容读取。
func maybe_autosave() -> void:
	if not app.map_loaded or not app.canvas.modified_flag or app.cur_map_name == "":
		return
	if Time.get_ticks_msec() - _last_autosave_msec < AUTOSAVE_INTERVAL_MS:
		return
	write_draft_now()

## 立即写草稿（退出确认「保留草稿」、定时器共用；失败退避，不刷屏也不放弃）。
func write_draft_now() -> bool:
	var data: Dictionary = app.canvas.extract()
	if data.is_empty():   # 重建窗口哨兵：本轮跳过，下个周期再存
		return false
	var name := _effective_map_name()
	if name == "":
		return false
	data.meta.name = name
	var code := str((data.get("meta", {}) as Dictionary).get("code", ""))
	var target := EditorManifest.map_path(app.manifest, name)
	var path := Recovery.write_draft(app.manifest, code, name, target,
		Recovery.digest(target), data, _pending_files(), _pending_ids())
	if path == "":
		# 失败退避：半间隔后再试，状态栏只说一次当前问题
		_last_autosave_msec = Time.get_ticks_msec() - AUTOSAVE_INTERVAL_MS / 2
		app._set_status(" 草稿写入失败（%s）：稍后自动重试" % "editor 目录不可写")
		return false
	_last_autosave_msec = Time.get_ticks_msec()
	app._set_status(" 已自动保存草稿 → %s" % path.get_file())
	return true

## 待提交内容文件清单（草稿记录用）：内容页暂存的新 ID 与其功能码。
func _pending_files() -> Array:
	var out: Array = []
	if app.project_shell == null or app.project_shell.content_editor == null:
		return out
	var staged: Dictionary = app.project_shell.content_editor.staged_snapshot()
	for cid in staged:
		out.append({"path": "content/%s/%s.json" % [str((staged[cid] as Dictionary).get("fn_id", "")), str(cid)],
			"id": str(cid)})
	return out

func _pending_ids() -> Array:
	var out: Array = []
	for e in _pending_files():
		out.append(str((e as Dictionary).get("id", "")))
	return out

## 恢复草稿：把快照载入画布并标记脏（正式文件未动，Ctrl+S 才写回）。
func restore_draft(map_name: String) -> bool:
	var draft := Recovery.read_draft(app.manifest, "", map_name)
	if draft.is_empty():
		app._set_status(" 没有可恢复的草稿：" + map_name)
		return false
	var snap = draft.get("snapshot", null)
	if not (snap is Dictionary) or (snap as Dictionary).is_empty():
		app._set_status(" 草稿内容为空，无法恢复：" + map_name)
		return false
	# 基线不同 = 正式图在草稿之后被改过：保留草稿并提示冲突（A3），不静默覆盖
	var target := str(draft.get("targetPath", ""))
	var base := str(draft.get("baseline", ""))
	if target != "" and base != "" and FileAccess.file_exists(target) and Recovery.digest(target) != base:
		if not await app._confirm_action("草稿与正式图冲突",
			"正式图在草稿保存后被改动过。\n恢复会把草稿载入画布（磁盘文件不动），Ctrl+S 将覆盖正式图。\n草稿已另存副本保留。",
			"仍然恢复"):
			return false
		_keep_conflict_copy(map_name)
	var gen := _begin_doc_op()
	app.canvas.set_thumbs(app._entity_thumbs())
	await app.canvas.load_data((snap as Dictionary).duplicate(true), map_name, false, true)
	if _doc_stale(gen):
		return false
	app.cur_map_name = map_name
	app.cur_map_path = target if target != "" else EditorManifest.map_path(app.manifest, map_name)
	_name_memo = map_name
	_doc_project_root = str(app.manifest.get("_dir", ""))
	_opened_mtime = FileAccess.get_modified_time(app.cur_map_path) if FileAccess.file_exists(app.cur_map_path) else 0
	_opened_digest = Recovery.digest(app.cur_map_path)
	app._sync_play_cfg_to_map()
	app._set_map_loaded(true)
	app.canvas.undo_stack.clear()
	app.canvas.redo_stack.clear()
	app.canvas.modified_flag = true   # 草稿内容与磁盘不同：必须显式保存
	app._set_status(" 已恢复草稿 %s（Ctrl+S 写回正式图）" % map_name)
	return true

## 冲突时保留草稿副本（原草稿保留，另存一份带时间戳的）
func _keep_conflict_copy(map_name: String) -> void:
	var src := Recovery.draft_path(app.manifest, "", map_name)
	var text := Recovery.read_text(src)
	if text == "":
		return
	Recovery.write_text(src.get_basename() + ".conflict.json", text)

## 正式保存成功后删掉对应草稿（草稿已完成使命）
func _drop_draft_for(name: String) -> void:
	var code := str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", ""))
	Recovery.remove_draft(app.manifest, code, name)

## 打开项目时提示可恢复草稿（A3）：有草稿就列出来，让用户选恢复/查看正式图/丢弃。
func offer_draft_recovery() -> void:
	var keys := Recovery.list_drafts(app.manifest)
	if keys.is_empty():
		return
	var names: Array[String] = []
	for k in keys:
		names.append(str(k))
	app._set_status(" 发现 %d 份未完成草稿：打开地图菜单可恢复（%s）" % [names.size(), ", ".join(PackedStringArray(names))])

func on_play(spawn_tiles: Vector2i = Vector2i(-1, -1)) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	if _effective_map_name() == "":
		app._set_status(" 试玩前先「新建地图」并填名字")
		return
	# 试玩只拿「成功提交后的项目内路径」（A2）：先走统一提交（清单码 → 内容 → 地图），
	# 失败就停，避免游戏侧读到半套内容。
	var res: Dictionary = await commit_document("试玩前提交")
	if str(res.get("status", "")) != "ok":
		app._set_status(" 试玩中止：" + str(res.get("error", "提交未完成")))
		return
	# 新建后未标脏的图提交不会写盘：这里补一次正式保存，否则游戏侧收到不存在的路径
	if not FileAccess.file_exists(str(app.cur_map_path)):
		if not await on_save():
			app._set_status(" 试玩中止：地图未保存成功")
			return
	var maps_root := str(app.manifest.get("_maps_dir", "")).simplify_path()
	var play_path := str(app.cur_map_path).simplify_path()
	if maps_root == "" or play_path == "" or not play_path.begins_with(maps_root.path_join("")):
		app._set_status(" 试玩中止：地图不在当前项目 maps 目录内，拒绝启动")
		return
	var play_res := Playtest.launch_tracked(app.manifest, play_path, app._play_args(spawn_tiles))
	if not play_res.get("ok", false):
		app._set_status(" 试玩失败: " + str(play_res.get("error", "")))
		return
	_play_pid = int(play_res.get("pid", 0))
	_play_started_msec = Time.get_ticks_msec()
	_play_program = str(play_res.get("program", ""))
	_play_args_text = " ".join(play_res.get("args", PackedStringArray()))
	_play_tracked = bool(play_res.get("tracked", false))
	# 状态里说清「启动了什么、又在跟踪什么」：模板包装进程退出 ≠ 游戏退出
	var what := _play_program.get_file() if _play_program != "" else "playCommand"
	var tail := Playtest.log_tail(str(app.manifest.get("_dir", "")), 2)
	app._set_status(" 试玩启动: %s %s%s%s" % [what, play_path.get_file(),
		"（跟踪包装进程）" if not _play_tracked else "",
		("；日志: " + tail) if tail != "" else ""])

## 试玩进程跟踪：退出后回报一次（Windows tasklist 轮询）

func poll_playtest() -> void:
	# is_alive 是阻塞的 tasklist 调用，每帧轮询会卡主线程——1s 节流
	if Time.get_ticks_msec() - _last_alive_poll < 1000:
		return
	_last_alive_poll = Time.get_ticks_msec()
	if _play_pid <= 0:
		return
	# 刚启动的头几秒 tasklist 可能还查不到，先跳过
	if Time.get_ticks_msec() - _play_started_msec < 4000:
		return
	if Playtest.is_alive(_play_pid):
		return
	var secs := int((Time.get_ticks_msec() - _play_started_msec) / 1000.0)
	var prog := _play_program
	_play_pid = 0
	# 试玩日志尾随——游戏侧写 editor/playtest.log，退出后取最后几行（无文件 = 原消息）
	var tail := Playtest.log_tail(str(app.manifest.get("_dir", "")), 4)
	var who := prog.get_file() if prog != "" else "进程"
	var tracked_note := "" if _play_tracked else "（跟踪的包装进程已退出）"
	if tail != "":
		app._set_status(" 试玩%s退出（%s，%d 秒）· 日志: %s" % [who, tracked_note, secs, tail.replace("\n", " | ")])
	else:
		app._set_status(" 试玩%s已退出%s（运行 %d 秒）" % [who, tracked_note, secs])

## 试玩配置弹窗（v7）：清单 playtest.flags/params 声明驱动，替代写死的 dash/glide/hp。
## flags → 勾选框（启用时启动参数原样追加 flag.arg）；params → SpinBox（追加 arg 以 %d 填数）。
## 值只存编辑器本地 prefs（键 = flag/param id），不写进地图 JSON；清单未声明 = 空态提示。
func _open_play_cfg() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var pt: Dictionary = app.manifest.get("playtest", {}) if app.manifest is Dictionary else {}
	var flags: Array = pt.get("flags", []) if pt.get("flags", null) is Array else []
	var params: Array = pt.get("params", []) if pt.get("params", null) is Array else []
	var shell = app._popup_body("试玩配置 —— %s" % app.cur_map_name,
		"只存编辑器本地，不写进地图 JSON。声明在清单 playtest.flags / playtest.params。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	if flags.is_empty() and params.is_empty():
		body.add_child(app.UiKitScript.hint_label(
			"清单未声明 playtest 项——在 editor_manifest.json 加 \"playtest\" 后重开清单（示例见 GAME_SIDE_STANDARD §试玩）。",
			app.POPUP_BODY_W))
	var states := {}   # {id: Callable} 应用时逐项收集（勾选=布尔，数字=整数）
	for f in flags:
		var fd: Dictionary = f
		var fid := str(fd.get("id", ""))
		var cb := CheckBox.new()
		cb.text = str(fd.get("name", fid))
		cb.button_pressed = bool(app.play_cfg.get(fid, false))
		body.add_child(cb)
		states[fid] = func() -> Variant: return cb.button_pressed
	for p2 in params:
		var pd: Dictionary = p2
		var pid := str(pd.get("id", ""))
		var sp := SpinBox.new()
		sp.min_value = float(pd.get("min", 0))
		sp.max_value = float(pd.get("max", 999999))
		sp.step = 1
		sp.value = float(int(app.play_cfg.get(pid, int(pd.get("def", 0)))))
		body.add_child(app.UiKitScript.field_row(str(pd.get("name", pid)), sp, UiKitScript.LABEL_W))
		states[pid] = func() -> Variant: return int(sp.value)
	var btn_row = app.UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(app.UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	var apply_cfg := func():
		var cfg := {}
		for sid in states:
			cfg[sid] = (states[sid] as Callable).call()
		app.play_cfg = cfg
		app._prefs[_prefs_key()] = app.play_cfg
		app._save_prefs()
		pop.hide()
		app._set_status("试玩配置已应用（仅影响试玩启动参数）")
	btn_row.add_child(app.UiKitScript.button("应用", apply_cfg, "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

func _play_args(spawn_tiles := Vector2i(-1, -1)) -> PackedStringArray:
	var out: PackedStringArray = []
	var pt: Dictionary = app.manifest.playtest if (app.manifest is Dictionary and app.manifest.playtest is Dictionary) else {}
	var flags: Array = pt.get("flags", []) if pt.get("flags", null) is Array else []
	var params: Array = pt.get("params", []) if pt.get("params", null) is Array else []
	for f in flags:
		var fd: Dictionary = f
		var fid := str(fd.get("id", ""))
		if bool(app.play_cfg.get(fid, false)) and str(fd.get("arg", "")) != "":
			out.append(str(fd.get("arg")))
	for p2 in params:
		var pd: Dictionary = p2
		var pid := str(pd.get("id", ""))
		if app.play_cfg.has(pid):
			var v := int(app.play_cfg.get(pid, 0))
			if v != int(pd.get("def", 0)):
				var arg := str(pd.get("arg", "%d"))
				out.append(arg % v if arg.contains("%d") else arg)
	if spawn_tiles.x >= 0 and spawn_tiles.y >= 0:
		out.append("--spawnx=%d" % spawn_tiles.x)
		out.append("--spawny=%d" % spawn_tiles.y)
	return out


## 试玩配置（v7）：prefs 由 {abilities:[],hp} 旧形态展平为 {flag_id: bool, param_id: int}。
## 旧键 abilities[] 展开成对应 flag id 勾选、hp 落到 hp 键——与旧 CLI 参数一一对应。
## 偏好键（A6）= <项目根>|<地图码>：两个项目有同名地图时配置不串，改名也不丢。
func _prefs_key() -> String:
	var root := str(app.manifest.get("_dir", ""))
	var code := ""
	if app.canvas != null and app.canvas.map_data.get("meta", null) is Dictionary:
		code = str((app.canvas.map_data["meta"] as Dictionary).get("code", ""))
	if code == "":
		code = str(app.cur_map_name)
	return root.path_join("|") + code

func _sync_play_cfg_to_map() -> void:
	var raw = app._prefs.get(_prefs_key(), null)
	# 兼容旧键（纯图名）：只在项目键缺失时回退一次，读到即迁移到新键
	if not (raw is Dictionary):
		var legacy = app._prefs.get(app.cur_map_name, null)
		if legacy is Dictionary:
			raw = legacy
			app._prefs[_prefs_key()] = legacy
	if not (raw is Dictionary):
		app.play_cfg = {}
		return
	var cfg := {}
	var old_ab = (raw as Dictionary).get("abilities", null)
	if old_ab is Array:
		for x in (old_ab as Array):
			cfg[str(x)] = true
	var old_hp = (raw as Dictionary).get("hp", null)
	if old_hp != null:
		cfg["hp"] = int(old_hp)
	for k in (raw as Dictionary):
		if not cfg.has(k):
			cfg[k] = (raw as Dictionary)[k]
	app.play_cfg = cfg
	app._prefs[_prefs_key()] = cfg
	app._save_prefs()
