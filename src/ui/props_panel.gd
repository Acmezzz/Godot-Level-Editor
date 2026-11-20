extends RefCounted
## 「从地形生成碰撞」弹窗控制器。右栏检查器删除后，字段编辑走内容编辑器与资产目录，
## 这里只剩这一个辅助功能。
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")

var app   # 宿主引用

func _init(host) -> void:
	app = host

# —— 自动生成碰撞面板（辅助功能；手动摆放仍是首选） ——
func open_collision_gen() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var shell: Dictionary = app._popup_body("从地形生成碰撞", "只写碰撞层，不改地形；整体算一个撤销步。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var strat := OptionButton.new()
	strat.add_item("全部地形格（整块实心）")
	strat.add_item("仅顶部表面（可站立平台）")
	strat.add_item("仅外轮廓（贴边一圈）")
	body.add_child(UiKitScript.field_row("策略", strat, UiKitScript.LABEL_W))
	var replace_cb := CheckBox.new()
	replace_cb.text = "先清空现有碰撞再生成"
	replace_cb.button_pressed = false
	body.add_child(replace_cb)
	var one_way_cb := CheckBox.new()
	one_way_cb.text = "只碰顶面（one-way：可从下方跳穿）"
	one_way_cb.button_pressed = false
	body.add_child(one_way_cb)
	var preview := UiKitScript.wrap_label("", app.POPUP_BODY_W, UiThemeScript.ACCENT_HI)
	body.add_child(preview)
	var refresh_preview := func():
		var n: int = app.canvas.count_auto_collision(_collision_strategy(strat.selected), replace_cb.button_pressed)
		if n == 0 and not replace_cb.button_pressed:
			# 已有碰撞覆盖了全部候选格：说清为什么是 0，而不是让人以为功能坏了
			preview.text = "这些格子已经有碰撞了；要重算请勾选「先清空现有碰撞」"
			preview.add_theme_color_override("font_color", UiThemeScript.TEXT_MUTE)
		else:
			preview.text = "将写入 %d 格碰撞" % n
			preview.add_theme_color_override("font_color", UiThemeScript.ACCENT_HI)
	strat.item_selected.connect(func(_i: int): refresh_preview.call())
	replace_cb.toggled.connect(func(_on: bool): refresh_preview.call())
	refresh_preview.call()
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	var gen_cb := func():
		var n: int = app.canvas.generate_collision(_collision_strategy(strat.selected), replace_cb.button_pressed, one_way_cb.button_pressed)
		pop.hide()
		app._set_status("已生成 %d 格碰撞（Ctrl+Z 撤销）" % n)
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("生成", gen_cb, "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

func _collision_strategy(idx: int) -> String:
	match idx:
		1: return "top"
		2: return "outline"
		_: return "full"
