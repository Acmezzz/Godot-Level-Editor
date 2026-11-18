extends RefCounted
## _editor_state_ctrl：从 src/app.gd 拆出的控制器（审查 8.3 表）。宿主状态经 alias 引用。

var app   # 宿主引用

func _init(host) -> void:
	app = host
## 唯一写入口。参数留空表示「保持当前值」。
## v2 §2.2：工具不再是用户可选的状态——它由层类型派生。
## 这里接受 tool 只是为了兼容吸管等内部调用，最终值仍按层归一。
func _apply_state(tool := "", layer := -1) -> void:
	if layer >= 0 and layer != app.canvas.active_layer:
		var moved_from: int = app.canvas.active_layer
		app.canvas.active_layer = layer
		if _is_tiles_layer(layer):
			app.last_tiles_layer = layer
		if moved_from != layer:
			app._set_status("已切到「%s」图层：%s" % [app._layer_label(layer), _gesture_hint(layer)])
	if layer >= 0:
		app.canvas.tool = _default_tool_for_layer(layer)
	elif tool != "":
		app.canvas.tool = tool
	_sync_ui()

## 层类型对应的唯一「画笔」语义：实体层放置/选中，其余层涂刷。
func _default_tool_for_layer(i: int) -> String:
	return "stamp" if _layer_type(i) == "entities" else "paint"

## 状态栏给一句「这一层怎么用」，替代被删掉的工具按钮
func _gesture_hint(i: int) -> String:
	if _layer_type(i) == "entities":
		return "左键放置 / 选中拖动，右键删除，Ctrl+拖动框选"
	return "左键拖动涂，右键擦除，Shift+拖动填矩形，Ctrl+拖动框选"


func _sync_ui() -> void:
	# 调色板跟随图层类型（v2：这是唯一一套切换，页签按钮已删）
	var lt := _layer_type(app.canvas.active_layer)
	if lt == "tiles" or lt == "grid":
		app._set_palette_page("tiles")
	else:
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

## v2：工具概念已废除。下面三个 `_*_for_tool` 只剩「旧调用点兼容」的意义——
## 它们不再驱动任何界面，也不再让状态在工具与图层之间互相拉扯。
## 保留函数体是为了 app.gd 的委托与若干测试仍能调用而不报错。

func _layer_kind_for_tool(_tool_name: String) -> String:
	return ""


func _layer_for_tool(_tool_name: String, cur_layer: int) -> int:
	return cur_layer


func _first_tiles_layer() -> int:
	var layers: Array = app.manifest.get("layers", [])
	for i in layers.size():
		if str(layers[i].get("type", "tiles")) == "tiles":
			return i
	return 0

## 旧工具入口：不切层，只把画笔语义按当前层归一（数字键已删，仅吸管等内部调用还在用）

func _set_tool(_name: String) -> void:
	_apply_state("", app.canvas.active_layer)

## 层下拉入口：切层就是唯一的「换画笔」动作

func _on_layer(i: int) -> void:
	# 切到碰撞层：它默认是隐藏的，进来就自动显示——否则用户看不见自己在画什么
	if app.canvas._is_grid_layer(i) and not app.canvas.is_layer_visible(i):
		app.canvas.set_layer_hidden(i, false)
	_apply_state("", i)

## 某图层下应该用什么工具——v2 起由层类型唯一决定，没有「保留当前工具」这回事

func _tool_for_layer(i: int) -> String:
	return _default_tool_for_layer(i)

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
