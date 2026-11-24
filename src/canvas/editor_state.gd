extends RefCounted
## _editor_state_ctrl：从 src/app.gd 拆出的控制器。宿主状态经 app 引用。

var app   # 宿主引用
## A1：进出碰撞元层要保住原笔刷——碰撞层没有资产可涂，若直接把 place_kind 留着不管，
## 回到层栈时左栏显示的是上次的资产、实际语义却可能已在碰撞里被改掉。
var _brush_before_collision := ""   # 进碰撞层前的 place_kind；"" = 还没进过

func _init(host) -> void:
	app = host
## 切换图层；画布吸管可同时切回瓦片笔刷。
func apply(tool := "", layer := -1) -> void:
	if layer >= 0 and layer != app.canvas.active_layer:
		var ci: int = app.canvas.collision_index()
		if layer == ci:
			_brush_before_collision = app.canvas.place_kind
		elif app.canvas.active_layer == ci and _brush_before_collision != "":
			# 离开碰撞层：恢复进层前的笔刷语义（资产本身没被改过，仍留在 paint/stamp 上）
			app.canvas.place_kind = _brush_before_collision
			_brush_before_collision = ""
		app.canvas.active_layer = layer
		app._set_status("已切到「%s」图层：%s" % [app._layer_label(layer), _gesture_hint(layer)])
	if tool == "paint" and app.map_loaded:
		set_brush("tiles")
	sync_ui()

## 在碰撞层选资产时，只更新离开碰撞层后恢复的笔刷。
func set_brush(kind: String) -> void:
	if app.canvas.active_layer == app.canvas.collision_index():
		_brush_before_collision = kind
	else:
		app.canvas.place_kind = kind

func _gesture_hint(i: int) -> String:
	if i >= 0 and i == app.canvas.collision_index():
		return "左键拖动涂，右键擦除，开「框选」后拖动框选"
	if app.canvas.place_kind == "object":
		return "左键放置 / 选中拖动，右键删除，开「框选」后拖动框选"
	return "左键拖动涂，右键擦除，开「框选」后拖动框选"


func sync_ui() -> void:
	if not app.map_loaded:
		app._layout_ctrl._set_palette_page("")
	elif app.canvas.active_layer == app.canvas.collision_index():
		app._layout_ctrl._set_palette_page("")
		_sync_collision_controls()
	elif app.canvas.place_kind == "tiles":
		app._layout_ctrl._set_palette_page("tiles")
	else:
		app._layout_ctrl._set_palette_page(app._palette_ctrl.current_category())
	app._layout_ctrl._refresh_tool_meta()
	app._layout_ctrl._refresh_layer_panel()
	app._layout_ctrl._refresh_view_toggles()

## 碰撞类型/形状下拉与画布笔刷状态对齐（画布是唯一真相）。
## 笔刷类型不在合法池里（缺省 solid、切项目换池）时，下行回落到首个合法类型，
## 避免「下拉显示首项、实际涂的却是池里没有的 solid」。
func _sync_collision_controls() -> void:
	if app._coll_type_opt != null and app._coll_type_opt.item_count > 0:
		var found := false
		for i in app._coll_type_opt.item_count:
			if str(app._coll_type_opt.get_item_metadata(i)) == app.canvas.collision_type:
				app._coll_type_opt.select(i)
				found = true
				break
		if not found:
			app._coll_type_opt.select(0)
			app.canvas.collision_type = str(app._coll_type_opt.get_item_metadata(0))
	if app._coll_shape_opt != null:
		for i in app._coll_shape_opt.item_count:
			if str(app._coll_shape_opt.get_item_metadata(i)) == app.canvas.collision_shape:
				app._coll_shape_opt.select(i)
				break


func pick_tile(i: int) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	var meta: Dictionary = app.tile_list.get_item_metadata(i)
	# 只有带 cell 的行才走选瓦片流程（MRU 标题行/类别行直接忽略）
	if not meta.has("cell"):
		return
	# 记录最近使用（会话内，最多 8 格，重复使用时提到最前）
	var mc: Vector2i = meta.get("cell", Vector2i.ZERO)
	var asset := str(meta.get("asset", ""))
	_record_tile_mru("%s:%d,%d" % [asset, mc.x, mc.y])
	app.canvas.paint_cell = mc
	# 笔刷 = 资产 id（落笔时查 source_id）；空 id 说明这一行没有资产，拒绝入笔
	if asset == "":
		return
	app.canvas.paint_asset = asset
	app.canvas.stamp_thumb = null
	set_brush("tiles")
	sync_ui()

## 最近使用瓦片记录（键 "资产id:x,y"——多图集瓦片各自记录）
func _record_tile_mru(key_str: String) -> void:
	if key_str == "":
		return
	var mru: Array = app.tile_mru
	mru.erase(key_str)
	mru.push_front(key_str)
	if mru.size() > 8:
		mru.resize(8)

## 左栏点资产：设好待放置资产，切到摆放模式（place_kind 驱动画布手势）。
## 实体与图片场景都能摆；图集瓦片走 pick_tile。
func pick_object(i: int, _at: Vector2, _mb: int) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	app.canvas.stamp_asset = str(app.ent_list.get_item_metadata(i))
	app.canvas.stamp_thumb = app.ent_list.get_item_icon(i)
	set_brush("object")
	sync_ui()
