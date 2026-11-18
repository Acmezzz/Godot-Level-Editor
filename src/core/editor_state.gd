extends RefCounted
## _editor_state_ctrl：从 src/app.gd 拆出的控制器（审查 8.3 表）。宿主状态经 alias 引用。

var app   # 宿主引用

func _init(host) -> void:
	app = host
## 唯一写入口。参数留空表示「保持当前值」。
func _apply_state(tool := "", layer := -1) -> void:
	if layer >= 0 and layer != app.canvas.active_layer:
		var moved_from: int = app.canvas.active_layer
		app.canvas.active_layer = layer
		if _is_tiles_layer(layer):
			app.last_tiles_layer = layer
		# 图层是被工具"顺带"改掉的，要说清楚，否则用户会觉得图层莫名跳了
		if tool != "" and moved_from != layer:
			app._set_status("已切到「%s」图层（该工具在此层才可用）" % app._layer_label(layer))
	if tool != "":
		app.canvas.tool = tool
	_sync_ui()


func _sync_ui() -> void:
	# 工具按钮高亮：以 app.canvas.tool 为唯一依据，不依赖是谁点的
	for k in app.tool_buttons.keys():
		var b := app.tool_buttons[k] as Button
		if b:
			b.button_pressed = (k == app.canvas.tool)
	# 调色板页签跟随图层类型
	var lt := _layer_type(app.canvas.active_layer)
	if lt == "tiles":
		app._set_palette_page("tiles")
	elif lt == "entities":
		app._set_palette_page("entities")
	app._refresh_tool_meta()
	app._sync_layer_buttons()
	app._refresh_view_toggles()


func _layer_type(i: int) -> String:
	var layers: Array = app.manifest.get("layers", [])
	if i >= layers.size():
		return "entities"
	return str(layers[i].get("type", "tiles"))


func _is_tiles_layer(i: int) -> bool:
	return _layer_type(i) == "tiles"

## 某种工具要求的图层类型；"" = 无要求（属性/出生点在哪层都能用）

func _layer_kind_for_tool(tool_name: String) -> String:
	match tool_name:
		"paint", "rect": return "tiles"
		"stamp": return "entities"
		"erase": return ""        # 擦除按当前层语义走（瓦片层擦瓦片、实体层删实体）
		_: return ""

## 工具切换到 target 时该落在哪个图层。
## 原则：能留在当前层就留（不抢用户正在编辑的层），只有工具确实用不了才挪。

func _layer_for_tool(tool_name: String, cur_layer: int) -> int:
	var want := _layer_kind_for_tool(tool_name)
	if want == "":
		return cur_layer
	if _layer_type(cur_layer) == want:
		return cur_layer
	# 当前是碰撞层（grid）时，瓦片类工具可以留在碰撞层上继续画——grid 也吃瓦片写入
	if want == "tiles" and _layer_type(cur_layer) == "grid":
		return cur_layer
	if want == "entities":
		return app.canvas._ent_layer_index()
	return app.last_tiles_layer if _is_tiles_layer(app.last_tiles_layer) else _first_tiles_layer()


func _first_tiles_layer() -> int:
	var layers: Array = app.manifest.get("layers", [])
	for i in layers.size():
		if str(layers[i].get("type", "tiles")) == "tiles":
			return i
	return 0

## 工具按钮 / 快捷键入口

func _set_tool(name: String) -> void:
	_apply_state(name, _layer_for_tool(name, app.canvas.active_layer))

## 图层下拉入口

func _on_layer(i: int) -> void:
	# 切到碰撞层：它默认是隐藏的，进来就自动显示——否则用户看不见自己在画什么
	if app.canvas._is_grid_layer(i) and not app.canvas.is_layer_visible(i):
		app.canvas.set_layer_hidden(i, false)
	# 切层后若当前工具在该层用不了，换成该层的默认工具，并把按钮高亮同步过去
	_apply_state(_tool_for_layer(i), i)

## 某图层下应该用什么工具（当前工具可用就保留）

func _tool_for_layer(i: int) -> String:
	var lt := _layer_type(i)
	var cur: String = app.canvas.tool
	if lt == "entities":
		# 实体层只认盖章 / 属性 / 出生点；涂刷、矩形在这里无意义
		if cur == "stamp" or cur == "select" or cur == "spawn":
			return cur
		return "stamp"
	# 瓦片 / 碰撞层：盖章在这里放不了东西
	if cur == "stamp":
		return "paint"
	return cur

## 资产栏点瓦片：设好待画瓦片，切到瓦片工具，并保证落在能画的图层

func _on_tile_pick(i: int, _at: Vector2 = Vector2.ZERO, _mb: int = 0) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	var meta: Dictionary = app.tile_list.get_item_metadata(i)
	# K3 MRU：只有带 cell 的行才走选瓦片流程（MRU 标题行/类别行直接忽略）
	if not meta.has("cell"):
		return
	# K3 MRU：记录最近使用（会话内，最多 8 格，重复使用时提到最前）
	var mc: Vector2i = meta.get("cell", Vector2i.ZERO)
	_record_tile_mru("%d:%d,%d" % [int(meta.get("atlas", 0)), mc.x, mc.y])
	app.canvas.paint_cell = meta.get("cell", Vector2i.ZERO)
	# 批次 9：多图集——调色板 metadata 带 atlas（TileSet source_id），选瓦片时一起落笔
	app.canvas.paint_atlas = int(meta.get("atlas", 0))
	app.canvas.stamp_thumb = null
	# 保留碰撞层（在碰撞层选瓦片仍是要画碰撞）；否则回到最近用的瓦片层
	var cur: int = app.canvas.active_layer
	var target: int = cur if (_layer_type(cur) == "tiles" or _layer_type(cur) == "grid") \
		else app.last_tiles_layer
	_apply_state("paint", target)

## 资产栏点实体：设好待盖章实体，切到盖章工具，并切到实体层

## K3 MRU：最近使用瓦片记录（批次 9 键 "atlas:x,y"——多图集瓦片各自记录）
func _record_tile_mru(key_str: String) -> void:
	if key_str == "":
		return
	var mru: Array = app.tile_mru
	mru.erase(key_str)
	mru.push_front(key_str)
	if mru.size() > 8:
		mru.resize(8)

func _on_ent_pick(i: int, _at: Vector2 = Vector2.ZERO, _mb: int = 0) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	app.canvas.stamp_scene = str(app.ent_list.get_item_metadata(i))
	app.canvas.stamp_thumb = app.ent_list.get_item_icon(i)
	_apply_state("stamp", app.canvas._ent_layer_index())
