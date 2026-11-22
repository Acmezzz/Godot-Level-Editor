extends RefCounted
## _editor_state_ctrl：从 src/app.gd 拆出的控制器。宿主状态经 app 引用。

var app   # 宿主引用
## A1：进出碰撞元层要保住原笔刷——碰撞层没有资产可涂，若直接把 place_kind 留着不管，
## 回到层栈时左栏显示的是上次的资产、实际语义却可能已在碰撞里被改掉。
var _brush_before_collision := ""   # 进碰撞层前的 place_kind；"" = 还没进过

func _init(host) -> void:
	app = host
## 唯一写入口。place_kind（瓦片/实体）即画笔语义。
## tool 只为吸管服务：吸到瓦片后必须真正回到「涂刷」语义（以前 tool 被忽略，
## 吸管停在碰撞层/摆放语义里，吸到的笔刷落不下去）。层切换规则与 _on_tile_pick 一致。
func _apply_state(tool := "", layer := -1) -> void:
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
		if app.canvas.active_layer == app.canvas.collision_index():
			remember_brush("tiles")   # 停在碰撞层：只登记待恢复笔刷（A1）
		else:
			app.canvas.place_kind = "tiles"
	_sync_ui()

## 记住「离开碰撞层后该恢复的笔刷」（左栏在碰撞层里点了资产类别时调用）。
## 碰撞层本身不摆资产；这里只登记意图，等真正切回层栈再落地。
func remember_brush(kind: String) -> void:
	if kind == "tiles" or kind == "object":
		_brush_before_collision = kind
func _gesture_hint(i: int) -> String:
	if i >= 0 and i == app.canvas.collision_index():
		return "左键拖动涂，右键擦除，开「框选」后拖动框选"
	if app.canvas.place_kind == "object":
		return "左键放置 / 选中拖动，右键删除，开「框选」后拖动框选"
	return "左键拖动涂，右键擦除，开「框选」后拖动框选"


func _sync_ui() -> void:
	# 空状态（无地图）不进碰撞页：此时 collision_index()==0 且 active_layer==0 会假命中
	if not app.map_loaded:
		app._set_palette_page("")
		app._refresh_tool_meta()
		app._sync_layer_buttons()
		app._refresh_view_toggles()
		return
	# 调色板跟随 place_kind（左栏选了瓦片还是可摆放资产）；碰撞元层例外——没有资产，显示类型/形状控件。
	if app.canvas.active_layer == app.canvas.collision_index():
		app._set_palette_page("")
		_sync_collision_controls()
	elif app.canvas.place_kind == "tiles":
		app._set_palette_page("tiles")
	else:
		app._set_palette_page(app._palette_ctrl.current_category())
	app._refresh_tool_meta()
	app._sync_layer_buttons()
	app._refresh_view_toggles()

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
	var asset := str(meta.get("asset", ""))
	_record_tile_mru("%s:%d,%d" % [asset, mc.x, mc.y])
	app.canvas.paint_cell = mc
	# 笔刷 = 资产 id（落笔时查 source_id）；空 id 说明这一行没有资产，拒绝入笔
	if asset == "":
		return
	app.canvas.paint_asset = asset
	app.canvas.stamp_thumb = null
	# 选瓦片 = 进入瓦片放置语义；active_layer 保持不变（层栈混瓦片+实体）。
	# 停在碰撞层时只登记待恢复笔刷，不改碰撞层当前的语义（A1）。
	if app.canvas.active_layer == app.canvas.collision_index():
		remember_brush("tiles")
	else:
		app.canvas.place_kind = "tiles"
	_apply_state("paint")

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
## 实体与图片场景都能摆；图集瓦片走 _on_tile_pick。
func _on_ent_pick(i: int, _at: Vector2 = Vector2.ZERO, _mb: int = 0) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	app.canvas.stamp_asset = str(app.ent_list.get_item_metadata(i))
	app.canvas.stamp_thumb = app.ent_list.get_item_icon(i)
	# active_layer 保持不变：实例可摆任何栈层。停在碰撞层时只登记待恢复笔刷（A1）。
	if app.canvas.active_layer == app.canvas.collision_index():
		remember_brush("object")
	else:
		app.canvas.place_kind = "object"
	_apply_state("stamp")
