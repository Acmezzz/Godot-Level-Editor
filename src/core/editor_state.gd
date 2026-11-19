extends RefCounted
## _editor_state_ctrl：从 src/app.gd 拆出的控制器。宿主状态经 app 引用。

var app   # 宿主引用

func _init(host) -> void:
	app = host
## 唯一写入口。没有工具概念——层类型即画笔语义。
## 第一个参数保留只为兼容吸管的 tool_requested(tool, layer) 信号，值被忽略。
func _apply_state(_tool := "", layer := -1) -> void:
	if layer >= 0 and layer != app.canvas.active_layer:
		var moved_from: int = app.canvas.active_layer
		app.canvas.active_layer = layer
		if _is_tiles_layer(layer):
			app.last_tiles_layer = layer
		if moved_from != layer:
			app._set_status("已切到「%s」图层：%s" % [app._layer_label(layer), _gesture_hint(layer)])
	_sync_ui()
func _gesture_hint(i: int) -> String:
	if _layer_type(i) == "entities":
		return "左键放置 / 选中拖动，右键删除，开「框选」后拖动框选"
	return "左键拖动涂，右键擦除，开「框选」后拖动框选"


func _sync_ui() -> void:
	# 调色板跟随图层类型（唯一一套切换；页签已删）
	# grid 层（碰撞）没有瓦片/实体资产——两个列表藏起来，显示碰撞类型/形状控件。
	var lt := _layer_type(app.canvas.active_layer)
	if lt == "grid":
		app._set_palette_page("")
		_sync_collision_controls()
	elif lt == "tiles":
		app._set_palette_page("tiles")
 # 装饰层没有独立资产（图一）：装饰↔地形切换时重填瓦片列表
		app._palette_ctrl.sync_layer_view()
	else:
		app._set_palette_page("entities")
	app._refresh_tool_meta()
	app._sync_layer_buttons()
	app._refresh_view_toggles()

## 碰撞类型/形状下拉与画布笔刷状态对齐（画布是唯一真相）
func _sync_collision_controls() -> void:
	if app._coll_type_opt != null:
		for i in app._coll_type_opt.item_count:
			if str(app._coll_type_opt.get_item_metadata(i)) == app.canvas.collision_type:
				app._coll_type_opt.select(i)
				break
	if app._coll_shape_opt != null:
		for i in app._coll_shape_opt.item_count:
			if str(app._coll_shape_opt.get_item_metadata(i)) == app.canvas.collision_shape:
				app._coll_shape_opt.select(i)
				break


func _layer_type(i: int) -> String:
	var layers: Array = app.manifest.get("layers", [])
	if i >= layers.size():
		return "entities"
	return str(layers[i].get("type", "tiles"))


func _is_tiles_layer(i: int) -> bool:
	return _layer_type(i) == "tiles"

## 层下拉入口：切层就是唯一的「换画笔」动作

func _on_layer(i: int) -> void:
	_apply_state("", i)

func _on_tile_pick(i: int, _at: Vector2 = Vector2.ZERO, _mb: int = 0) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	var meta: Dictionary = app.tile_list.get_item_metadata(i)
	# 只有带 cell 的行才走选瓦片流程（MRU 标题行/类别行直接忽略）
	if not meta.has("cell"):
		return
	# 记录最近使用（会话内，最多 8 格，重复使用时提到最前）
	var mc: Vector2i = meta.get("cell", Vector2i.ZERO)
	_record_tile_mru("%d:%d,%d" % [int(meta.get("atlas", 0)), mc.x, mc.y])
	app.canvas.paint_cell = meta.get("cell", Vector2i.ZERO)
	# 多图集——调色板 metadata 带 atlas（TileSet source_id），选瓦片时一起落笔
	app.canvas.paint_atlas = int(meta.get("atlas", 0))
	app.canvas.stamp_thumb = null
	# 保留碰撞层（在碰撞层选瓦片仍是要画碰撞）；否则回到最近用的瓦片层
	var cur: int = app.canvas.active_layer
	var target: int = cur if (_layer_type(cur) == "tiles" or _layer_type(cur) == "grid") \
		else app.last_tiles_layer
	_apply_state("paint", target)

## 最近使用瓦片记录（键 "atlas:x,y"——多图集瓦片各自记录）
func _record_tile_mru(key_str: String) -> void:
	if key_str == "":
		return
	var mru: Array = app.tile_mru
	mru.erase(key_str)
	mru.push_front(key_str)
	if mru.size() > 8:
		mru.resize(8)

## 左栏点实体：设好待放置实体，切到实体层（层类型即画笔语义，无独立工具）
func _on_ent_pick(i: int, _at: Vector2 = Vector2.ZERO, _mb: int = 0) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	app.canvas.stamp_scene = str(app.ent_list.get_item_metadata(i))
	app.canvas.stamp_thumb = app.ent_list.get_item_icon(i)
	_apply_state("stamp", app.canvas._ent_layer_index())
