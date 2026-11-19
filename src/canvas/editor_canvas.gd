class_name EditorCanvas
extends Node2D
## 清单驱动的关卡画布（数据化编辑器）：
## 图层 = 地图 meta.layers 声明的混合层栈（层=纯 z 槽，一层可混瓦片+实体，
## 栈序即绘制序；碰撞是栈外元层）；瓦片层 = 运行时构建的 TileMapLayer
## （图集 PNG → TileSet，不依赖游戏工程资源）；实体 = 缩略图 Sprite2D
## （数据占位，不实例化游戏 prefab）；出生点 = Marker2D。保存/装载纯 JSON。

signal modified
signal cursor_info(text: String)

const K := preload("res://src/core/constants.gd")   # 共享常量统一在 core/constants.gd
const TilesetCache := preload("res://src/canvas/tileset_cache.gd")   # PF-02：TileSet 构建缓存
const INVISIBLE_CELL := K.INVISIBLE_CELL
const BuiltinKinds := preload("res://src/content/builtin_kinds.gd")   # 内置种类（trigger_zone 等）
const MapStoreRef := preload("res://src/map_store.gd")   # 地图数据层（读全工程/写盘）
const ContentIdRef := preload("res://src/content/content_id.gd")   # 分层身份码

var active_layer := 0          # 0..N-1 = 层栈下标，N = 碰撞元层
var place_kind := "tiles"      # 放置语义跟资产走："tiles"=涂瓦片 / "entity"=摆实体（左栏驱动）
var paint_cell := Vector2i(0, 0)  # 当前瓦片（纯手动，不自动变形）
var brush_size := 1               # 笔刷边长（格）
var stamp_scene := ""
var stamp_thumb: Texture2D
var show_grid := true
## 框选开关（左栏「框选」按钮）：打开后任意层普通左键拖动都进入框选；
## 关闭时保留 Ctrl+拖动作为兼容入口。输入分派见 canvas_input.gd。
var select_mode := false
var zoom := 2.0
var manifest: Dictionary
var map_data := {}
var cur_map_name := ""
var map_root: Node2D
# 层栈节点：下标 = meta.layers 栈序；每层 = 一个瓦片 TileMapLayer + 一个实体容器。
# 树序 = 栈序（底→顶），碰撞网格与红叠加在栈外（永远画在最上）。
var layer_tiles: Array = []
var layer_ents: Array = []
var spawn: Marker2D
var tile_set: TileSet
var atlas_tex: Texture2D
var atlas_img: Image
# 多图集：全部图集（索引 = TileSet source_id = 地图格 atlas 维度）
var atlas_imgs: Array = []
# 实体 by_id 索引缓存——_mark/load_data 置脏，绘制连线时 O(n) 复用
var _ent_by_id := {}
var _ent_by_id_dirty := true
var atlas_texs: Array = []
# 当前笔刷的图集索引与碰撞类型/形状（碰撞层涂刷用）
var paint_atlas := 0
var collision_type := "solid"
var collision_shape := ""
# 碰撞类型元数据 {Vector2i: {type, shape}}——solid+矩形不记（缺省值，零冗余）
var _collision_meta: Dictionary = {}
var thumbs := {}
## 实体类型 → 编辑器占位尺寸（像素）。有值时画布按该尺寸画框（比缩略图更接近游戏碰撞）。
var ent_sizes := {}
var tile_px := 16
var modified_flag := false
var cam_pos := Vector2.ZERO      # 相机中心（世界坐标）
var collision: TileMapLayer      # 碰撞图层（grid 型：只有隐形块）
var coll_view: CollisionView     # 碰撞的可视节点（红色叠加），显隐由图层接口控制
# 图层可见性 / 锁定（索引 = active_layer，含实体层；按图层顺序）
var layer_hidden := {}
var layer_locked := {}

# —— 相机：zoom/位置 → viewport canvas_transform ——
func _update_cam() -> void:
	var vp := get_viewport()
	if vp == null:
		return  # 无视口（headless 测试）时跳过相机更新
	var half := vp.get_visible_rect().size * 0.5
	vp.canvas_transform = Transform2D(0.0, Vector2(zoom, zoom), 0.0, half - cam_pos * zoom)

# —— 图层栈：地图 meta.layers 声明（[{id, name, visible}]，栈序 = 数组序，底→顶） ——
## 层=纯 z 槽只管画画；清单 layers[] 已退役，层词汇逐图声明。
func layers_decl() -> Array:
	var m: Dictionary = map_data.get("meta", {}) if map_data != null else {}
	var L = m.get("layers", null)
	return L if L is Array and not (L as Array).is_empty() else []

func layer_count() -> int:
	return layers_decl().size()

func layer_id(i: int) -> String:
	var L := layers_decl()
	return str((L[i] as Dictionary).get("id", "")) if i >= 0 and i < L.size() else ""

func layer_name(i: int) -> String:
	var L := layers_decl()
	return str((L[i] as Dictionary).get("name", "")) if i >= 0 and i < L.size() else ""

## 层码 → 栈下标；未知返回 -1
func _layer_index_of(lid: String) -> int:
	for i in layer_count():
		if layer_id(i) == lid:
			return i
	return -1

## 碰撞是栈外元层：下标恒 = 栈层数（下拉里排最后）
func collision_index() -> int:
	return layer_count()

func _is_grid_layer(i: int) -> bool:
	return i == collision_index() and collision != null

func _layer_node(i: int) -> TileMapLayer:
	if _is_grid_layer(i):
		return collision
	if i >= 0 and i < layer_tiles.size():
		return layer_tiles[i]
	return null

## 全层实体合集（层栈化后实体分散在各层容器）
func ents_all() -> Array:
	var out := []
	for n in layer_ents:
		if n != null and is_instance_valid(n):
			out.append_array((n as Node2D).get_children())
	return out

## 图层「看得到的那个节点」：碰撞层看 coll_view（红块），其余看数据节点本身。
## 可见性/隐藏一律作用在这个节点上，保证所有图层的显示逻辑走同一条路。
func _layer_display_node(i: int) -> Node2D:
	if _is_grid_layer(i):
		return coll_view
	if i >= 0 and i < layer_ents.size():
		return layer_ents[i]
	return null

## 设置图层可见/锁定；隐藏 = 该层瓦片与实体一起隐（视觉遮挡，锁定阻止编辑写入）
func set_layer_hidden(i: int, now_hidden: bool) -> void:
	layer_hidden[i] = now_hidden
	if _is_grid_layer(i):
		if coll_view:
			coll_view.visible = not now_hidden
	elif i >= 0 and i < layer_tiles.size():
		(layer_tiles[i] as TileMapLayer).visible = not now_hidden
		if i < layer_ents.size():
			(layer_ents[i] as Node2D).visible = not now_hidden
	queue_redraw()

## 图层当前是否可见（未隐藏）。所有图层默认可见——包括碰撞层：用户明确要求
## 开图就能看到碰撞（整图染红是可接受的代价）。显隐只由 layer_hidden 记录决定。
func is_layer_visible(i: int) -> bool:
	if layer_hidden.has(i):
		return not bool(layer_hidden[i])
	return true

func set_layer_locked(i: int, locked: bool) -> void:
	layer_locked[i] = locked

func is_layer_locked(i: int) -> bool:
	return bool(layer_locked.get(i, false))

# —— 运行时 TileSet：从清单图集 PNG 构建（按路径缓存，见 tileset_cache.gd） ——
func _build_tileset() -> bool:
	var tiles: Array = manifest.get("tiles", [])
	if tiles.is_empty():
		return false
	# 多图集：manifest tiles[] 每项一个图集，source_id = 索引
	var paths := []
	for t in tiles:
		var p := str((t as Dictionary).get("atlas_abs", ""))
		if p == "" or not FileAccess.file_exists(p):
			return false
		paths.append(p)
	var got := TilesetCache.get_or_build_multi(paths, int(manifest.get("tileSize", 16)))
	if got.is_empty():
		return false
	atlas_imgs = got.imgs
	atlas_texs = got.texs
	atlas_img = got.imgs[0]
	atlas_tex = got.texs[0]
	tile_set = got.ts
	return true

# —— 装载地图数据 ——
func load_data(data: Dictionary, map_name: String, keep_cam := false, keep_dirty := false) -> void:
	# 进入即抬代数；await 恢复后比对——过期 = 期间又有更新的重建进入，本协程退出
	_rebuild_gen += 1
	var gen := _rebuild_gen
	map_data = data
	cur_map_name = map_name
	# 清单 tileSize 是「一格 = 多少像素」的唯一真相：网格/边界/实体对齐/碰撞视图全用它。
	# 此前只建 tileset 时读了它，tile_px 本体从不赋值（恒 16）——tileSize≠16 的项目全画布错位。
	tile_px = int(manifest.get("tileSize", 16))
	# 节点全部重建：选区/剪贴板引用失效，清空（剪贴板只存模板数据可保留，但引用选区必须清）
	selected_entity = null
	selected_multi.clear()
	# 手势单点复位（手势与起手按键清零）
	end_gesture()
	# 输入/区域状态一并复位：上个图的粘贴预览、区域选区、右键擦除、拖拽中状态
	# 不能带进这张图；拖拽标志不重置会让 undo 后松手推出冗余快照。
	# 图层显隐/锁定是按图的编辑状态，跨图泄漏会让人对着空气解锁——换图时清空。
	# undo（keep_dirty=true）恢复的是同一张图，保留锁定状态不被误清。
	_paste_mode = false
	_region_sel = Rect2i(-1, 0, 0, 0)
	_region_clip = {}
	_last_copy_region = false
	_collision_meta.clear()
	_drag_entity = null
	_drag_entities.clear()
	_drag_origins.clear()
	_drag_moved = false
	if not keep_dirty:
		layer_hidden.clear()
		layer_locked.clear()
	var saved_cam := cam_pos
	var saved_zoom := zoom
	if map_root:
		map_root.queue_free()
		await get_tree().process_frame
 # 代数过期 = 期间又有更新一次的重建进入——本协程退出，root 交给最新协程创建
		if gen != _rebuild_gen:
			return
	map_root = Node2D.new()
	map_root.z_index = -1   # 地图内容整体沉到画布参照层之下（碰撞叠加/网格/幽灵画在 canvas 自绘层）
	map_root.name = "MapRoot"
	add_child(map_root)
	_build_tileset()
	# 背景：整块铺满视口（比地图尺寸大得多），作为地图之外区域的底色
	var meta: Dictionary = data.get("meta", {})
	# 分层身份码：地图段。老图没有就补发（保存在 meta.code，地图改名不影响它）
	if str(meta.get("code", "")) == "":
		meta["code"] = ContentIdRef.new_map_code()
		map_data["meta"] = meta
	# 图层栈：meta.layers 缺失/为空时补默认两层（资产层/FL）——不是旧数据迁移，
	# 是新建图的同款默认；层词汇逐图声明。
	var dl = meta.get("layers", null)
	if not (dl is Array) or (dl as Array).is_empty():
		meta["layers"] = [
			{"id": ContentIdRef.new_inst_code(), "name": "资产层", "visible": true},
			{"id": ContentIdRef.new_inst_code(), "name": "FL", "visible": true},
		]
		map_data["meta"] = meta
	var mw := int(meta.get("w", K.DEFAULT_MAP_W))
	var mh := int(meta.get("h", K.DEFAULT_MAP_H))
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = Color("#0b0e13")
	bg.z_index = -10
	# 覆盖范围远大于地图（相机可平移出界）。纯按地图尺寸算，不查 viewport——
	# load_data 可能在节点还没进树时被调用，get_viewport_rect() 会报错。
	var map_size := Vector2(mw * tile_px, mh * tile_px)
	bg.size = map_size * 6.0
	bg.position = -map_size * 2.5
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_root.add_child(bg)
	# 地图区域内只比背景亮一档——目的是提示"这里是可编辑边界"，不该抢地形视觉
	var field := ColorRect.new()
	field.name = "Field"
	field.color = Color("#101520")
	field.position = Vector2.ZERO
	field.size = Vector2(mw * tile_px, mh * tile_px)
	field.z_index = -9
	field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_root.add_child(field)
	# 层栈节点：按 meta.layers 栈序创建（每层 = 瓦片 TileMapLayer + 实体容器），树序 = 栈序
	layer_tiles.clear()
	layer_ents.clear()
	var L := layers_decl()
	for li in L.size():
		var tn := TileMapLayer.new()
		tn.name = "LayerTiles%d" % li
		tn.tile_set = tile_set
		map_root.add_child(tn)
		layer_tiles.append(tn)
		var en := Node2D.new()
		en.name = "LayerEnts%d" % li
		map_root.add_child(en)
		layer_ents.append(en)
	# 碰撞图层（grid 型：画上去的都是隐形碰撞块）
	# 数据仍是 TileMapLayer（隐形格），但节点本身不显示——它那格图集像素会画成灰白网格。
	# 可视表达交给 CollisionView，由图层接口统一控制显隐，和地形/装饰/实体一致。
	collision = TileMapLayer.new()
	collision.name = "Collision"
	collision.tile_set = tile_set
	collision.visible = false
	collision.z_index = 2
	map_root.add_child(collision)
	coll_view = CollisionView.new()
	coll_view.name = "CollisionView"
	coll_view.z_index = 2
	map_root.add_child(coll_view)
	coll_view.setup(collision, tile_px)
	coll_view.canvas_ref = self   # 读 _collision_meta 做类型化分色分形
	# 涂瓦片：tiles = {层id: [[x,y,atlas,ax,ay]...]}（5 元，atlas=图集索引）
	var tiles_data = data.get("tiles", {})
	if not (tiles_data is Dictionary):
		tiles_data = {}
	for li2 in L.size():
		var lid := layer_id(li2)
		var tn2: TileMapLayer = layer_tiles[li2]
		for c in (tiles_data.get(lid, []) as Array):
			var arr := c as Array
			tn2.set_cell(Vector2i(int(arr[0]), int(arr[1])), int(arr[2]), Vector2i(int(arr[3]), int(arr[4])))
	# 碰撞：[x,y] = solid 缺省（契约零冗余）；[x,y,type,shape] 记入类型元数据（solid+矩形不记）
	for c in data.get("collision", []):
		var ccell := Vector2i(int(c[0]), int(c[1]))
		collision.set_cell(ccell, 0, INVISIBLE_CELL)
		var tname := str(c[2]) if (c as Array).size() >= 3 else "solid"
		var sname := str(c[3]) if (c as Array).size() >= 4 else ""
		if tname != "solid" or sname != "":
			_collision_meta[ccell] = {"type": tname if tname != "" else "solid", "shape": sname}
	# 实体：数据化占位（缩略图 Sprite2D，带 metadata scene=id），按 meta "layer" 入对应层容器
	var tile := int(manifest.get("tileSize", 16))
	var bottom := layer_id(0)
	for e in data.get("entities", []):
		var sid := str(e.get("scene", ""))
		var spr := Sprite2D.new()
		spr.texture = thumbs.get(sid)
		spr.position = Vector2(int(e.get("x", 0)) * tile + tile / 2.0, int(e.get("y", 0)) * tile + tile / 2.0)
		spr.set_meta("scene", sid)
		spr.set_meta("props", e.get("props", {}))
 # 分层身份码：实例段。老实体没有就由 _ensure_code 统一补发
		spr.set_meta("code", str(e.get("code", "")))
 # 实例功能绑定：只做存取，UI 由内容编辑器负责；缺失/类型不对时置空数组，
 # 让 extract 始终能写出 functions 键（含空数组），不清空就残留旧图绑定。
		var fns = e.get("functions", [])
		spr.set_meta("functions", fns if fns is Array else [])
 # 触发区没有缩略图，靠尺寸矩形呈现；位置按矩形中心对齐
		if BuiltinKinds.is_builtin(sid):
			spr.texture = null
			var tprops: Dictionary = e.get("props", {}) if e.get("props", {}) is Dictionary else {}
			spr.position += trigger_zone_size(tprops) * 0.5 - Vector2(tile, tile) * 0.5
		spr.flip_h = bool(e.get("flip_h", false))
		var lid := str(e.get("layer", bottom))
		var ei := _layer_index_of(lid)
		if ei < 0:
			ei = 0
		spr.set_meta("layer", layer_id(ei))
		(layer_ents[ei] as Node2D).add_child(spr)
		_fit_sprite(spr, sid)
		_ensure_code(spr)
	# 出生点
	spawn = Marker2D.new()
	spawn.name = "Spawn"
	var sp: Array = data.get("spawn", [2, 2])
	spawn.position = Vector2(int(sp[0]) * tile + tile / 2.0, int(sp[1]) * tile + tile / 2.0)
	map_root.add_child(spawn)
	# 地图装载后同步碰撞可视节点与图层可见性（按图层索引恢复，不只是节点 flag）
	coll_view.refresh()
	for i in layer_count() + 1:
		var dn := _layer_display_node(i)
		if dn:
			dn.visible = is_layer_visible(i)
		if i < layer_tiles.size():
			(layer_tiles[i] as TileMapLayer).visible = is_layer_visible(i)

	# 相机：撤销时保持视角，否则对准出生点
	if keep_cam:
		cam_pos = saved_cam
		zoom = saved_zoom
	else:
		cam_pos = spawn.position
	_update_cam()
	# keep_dirty：撤销/重做恢复路径不抹脏标记（快照恢复后内容与磁盘
	# 不一致就是脏的），普通载入清零；emit 只在这里发一次，undo/redo 不再自己发。
	modified_flag = keep_dirty
	# 换图后层数可能变少：激活层钳回合法区间（0..层栈数，含碰撞元层下标）
	active_layer = clampi(active_layer, 0, layer_count())
	_ent_by_id_dirty = true   # 整图载入（含撤销恢复）索引置脏
	map_rev += 1              # 整图替换后下游缓存必须重扫
	ents_rev += 1
	modified.emit()
	# 载入后选区引用已失效——发 null 让属性面板/侧栏同步清空，悬空引用不再滞留
	entity_selected.emit(null)

# —— 缩略图注入（app 启动时把实体缩略图交给画布） ——
func _ready() -> void:
	z_index = 5   # canvas 自绘（网格/幽灵/碰撞叠加/出生标记）盖在地图子树之上
	_selection_ops_ctrl = preload("res://src/canvas/selection_ops.gd").new(self)
	_undo_history_ctrl = preload("res://src/core/undo_history.gd").new(self)
	_canvas_draw_ctrl = preload("res://src/canvas/canvas_draw.gd").new(self)
	_canvas_input_ctrl = preload("res://src/canvas/canvas_input.gd").new(self)
	_tool_ops_ctrl = preload("res://src/canvas/tool_ops.gd").new(self)
	# 视口尺寸变化时重绘底色（否则窗口缩放后底板会露出旧底色）
	get_viewport().size_changed.connect(func(): queue_redraw())
	queue_redraw()

func set_thumbs(t: Dictionary) -> void:
	thumbs = t

## 设置实体的编辑器占位尺寸（像素）；用于画布上画真实占位框
func set_entity_sizes(sizes: Dictionary) -> void:
	ent_sizes = sizes

## 某个 scene 的编辑器占位尺寸；0 表示未知（退回缩略图原始尺寸）
func _size_of(scene_id: String) -> Vector2:
	var v = ent_sizes.get(scene_id, null)
	if v is Vector2 and (v as Vector2) != Vector2.ZERO:
		return v
	return Vector2.ZERO

## 实体在世界里的显示尺寸（像素）。
## 唯一来源：清单 editorSize / prefab 碰撞尺寸；没有就用 1 格。
## 缩略图只作为贴图内容，尺寸一律由这里定——不同大小的实体因此能正确呈现，
## 而不是「96×96 画布按原尺寸画，看着都一样大」。
func entity_display_size(scene_id: String) -> Vector2:
	var sz := _size_of(scene_id)
	if sz == Vector2.ZERO:
		sz = Vector2(tile_px, tile_px)
	return sz

## 实例级显示尺寸：触发区这类「尺寸存在实例 props 里」的实体不能用种类尺寸。
## 其它实体等价于 entity_display_size。
func entity_display_size_of(spr: Node) -> Vector2:
	if spr != null and is_instance_valid(spr):
		var sid := str(spr.get_meta("scene", ""))
		if BuiltinKinds.is_builtin(sid):
			return trigger_zone_size(spr.get_meta("props", {}))
		return entity_display_size(sid)
	return Vector2(tile_px, tile_px)

## 触发区矩形尺寸：props.w/h 是格数，转成像素。缺省或非法时退回 1 格。
func trigger_zone_size(props: Dictionary) -> Vector2:
	var w := int(props.get("w", 1))
	var h := int(props.get("h", 1))
	if w <= 0:
		w = 1
	if h <= 0:
		h = 1
	return Vector2(w * tile_px, h * tile_px)

## 触发区左上角格坐标：实例位置是矩形左上角，不是中心。
func trigger_zone_origin(spr: Node) -> Vector2:
	if spr == null:
		return Vector2.ZERO
	return (spr as Node2D).position - entity_display_size_of(spr) * 0.5

## 把缩略图缩放成适合该实体的显示尺度。
## 贴图原始分辨率可能远大于占位尺寸（96px 图 ↔ 14px 实体），
## 这里按「内容填满占位框」放缩，保证形状清晰且大小与占位一致。
func _fit_sprite(spr: Sprite2D, scene_id: String) -> void:
	var tex := spr.texture
	if tex == null:
		return
	var target := entity_display_size(scene_id)
	var tsize := tex.get_size()
	if tsize.x <= 0.0 or tsize.y <= 0.0:
		return
	# 保持比例塞进占位框（不拉伸变形）；放大时取整数倍避免像素糊（实现与注释对齐）
	var k := minf(target.x / tsize.x, target.y / tsize.y)
	if k > 1.0:
		k = maxf(1.0, floorf(k))
	spr.scale = Vector2(k, k)

## 出生点：画布上的可拖对象。
## 命中容差 0.6 格——它只有一个绿十字那么大，严格点中几乎不可能。
func _on_spawn(pos: Vector2) -> bool:
	if spawn == null or not is_instance_valid(spawn):
		return false
	return pos.distance_to(spawn.position) <= tile_px * 0.6

## 拖动出生点：位置对齐到格中心（数据只存格坐标，浮点位置保存会被取整回去）
func _drag_spawn_to(pos: Vector2) -> void:
	if spawn == null or not is_instance_valid(spawn):
		return
	var c := _cell_of(pos)
	spawn.position = Vector2(c.x * tile_px + tile_px / 2.0, c.y * tile_px + tile_px / 2.0)
	queue_redraw()

# —— 坐标换算 ——
## 转发：选区命中跨层（顶层向下取第一个）；tool_ops 擦除用单层版
func _entity_hit(pos: Vector2) -> Sprite2D:
	return _selection_ops_ctrl._entity_hit(pos)

## 指定层的实体命中（擦除只认当前层）
func _entity_hit_on(li: int, pos: Vector2) -> Sprite2D:
	if li < 0 or li >= layer_ents.size():
		return null
	return _selection_ops_ctrl._entity_hit_in((layer_ents[li] as Node2D).get_children(), pos)

func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(pos.x / tile_px)), int(floor(pos.y / tile_px)))

# —— 涂刷/擦除（图层硬规则：瓦片/碰撞层禁盖章，实体层禁涂刷；笔刷 = 以 c 为基准的 brush_size×brush_size 格，偶数尺寸时 c 偏右下） ——
func _hint(t: String) -> void:
	cursor_info.emit(t)

# —— 实例身份：4 位码（唯一身份：引用/重映射/连线全用它） ——
## 码出生即定、永不回收，所以不需要「发号前防空洞复用」的全工程扫描。
# 重建代数——load_data 是协程，期间再进一次 load_data 时，先进者按代数退出防孤儿 map_root
var _rebuild_gen := 0

## 老实体/新建实体没有码就补发；已有（载图恢复）保留
func _ensure_code(spr: Sprite2D) -> void:
	if str(spr.get_meta("code", "")) == "":
		spr.set_meta("code", _fresh_inst_code())

## 生成一个本图未占用的实例码（码空间 100 万+，撞码重摇即可）
func _fresh_inst_code() -> String:
	for i in 64:
		var c := ContentIdRef.new_inst_code()
		if not _code_taken(c):
			return c
	return ContentIdRef.new_inst_code()

func _code_taken(c: String) -> bool:
	for e in ents_all():
		if str((e as Sprite2D).get_meta("code", "")) == c:
			return true
	return false

# —— 吸管 + 整图入视野 ——
signal tool_requested(tool: String, layer: int)

## 吸管：从顶层向下取光标格瓦片为当前笔刷；吸到哪层就切到哪层。
## 经 tool_requested 信号走 app._apply_state 单一写入口切层，保持左栏与状态同步。
func _pick_tile(pos: Vector2) -> void:
	if map_root == null or not is_instance_valid(map_root) or layer_tiles.is_empty():
		_hint("无地图：先新建或打开一张地图")
		return
	var c := _cell_of(pos)
	for li in range(layer_count() - 1, -1, -1):
		var tn: TileMapLayer = layer_tiles[li]
		var ac := tn.get_cell_atlas_coords(c)
		if ac == Vector2i(-1, -1):
			continue
		paint_cell = ac
		paint_atlas = tn.get_cell_source_id(c)   # 吸管连 atlas 一起吸（多图集瓦片吸取后原样落笔）
		active_layer = li
		_hint("已吸取 %s（切到涂刷）" % str(ac))
		tool_requested.emit("paint", li)
		return
	_hint("该格没有可吸取的瓦片（碰撞层不参与吸管）")

## 整图入视野（Home）——相机对中 + 缩放夹回 0.5~6.0
func _fit_view() -> void:
	if map_root == null or not is_instance_valid(map_root) or layer_tiles.is_empty():
		_hint("无地图：先新建或打开一张地图")
		return
	var used := Rect2i()
	for tn in layer_tiles:
		used = used.merge((tn as TileMapLayer).get_used_rect())
	if used.size == Vector2i.ZERO:
		used = Rect2i(0, 0, 10, 10)
	cam_pos = Vector2(used.get_center()) * tile_px
	var vp := get_viewport_rect().size
	var w := maxf(float(used.size.x), 1.0) * tile_px
	var h := maxf(float(used.size.y), 1.0) * tile_px
	zoom = clampf(minf(vp.x / w, vp.y / h) * 0.9, 0.5, 6.0)
	_update_cam()

# —— 选择实体 ——
signal entity_selected(spr: Sprite2D)

var selected_entity: Sprite2D = null
var selected_multi: Array = []   # 框选集合（Del / 复制粘贴用）
## 引用指向预览：内容编辑器里编辑引用字段时，画布高亮被指实例（存实例码）
var ref_highlight := ""
@warning_ignore("unused_private_class_variable")
var _clipboard: Array = []       # 实体复制模板 [{scene, code, dx, dy, flip_h, functions, props}]
var _region_sel := Rect2i(-1, 0, 0, 0)  # 区域框选结果（瓦片层 Ctrl+C 用）
var _region_clip := {}           # 区域快照 {tiles:{层id:[...]}, collision[], entities[], size}
var _paste_mode := false         # 区域粘贴预览态（幽灵跟随鼠标）
# 区域拖动搬迁（框选后按住区内拖动）：按下只快照，松手才擦源写目标
var _move_snap := {}
var _move_from := Vector2i.ZERO
var _move_grab := Vector2.ZERO
var _move_cell_delta := Vector2i.ZERO
var _selection_ops_ctrl   # SelectionOps：实体选区/剪贴板/区域复制粘贴控制器
var _undo_history_ctrl   # UndoHistory：快照式撤销/重做控制器
var _canvas_draw_ctrl   # CanvasDraw：绘制控制器
var _canvas_input_ctrl   # CanvasInput：鼠标输入路由控制器
var _tool_ops_ctrl   # ToolOps：左键/右键语义执行控制器
var _last_copy_region := false   # 最近一次复制是区域还是实体（Ctrl+V 分发）

# —— 框选集合有效性过滤 ——
func _valid_multi() -> Array:
	var out := []
	for s in selected_multi:
		if is_instance_valid(s):
			out.append(s)
	return out

# —— 自动生成碰撞：从**当前层**瓦片推导碰撞（层栈化后「当前层自审」，不再认 terrain id） ——
## strategy: "full"(全部) / "top"(仅顶部表面) / "outline"(仅外轮廓)
## replace=true 先清空碰撞层再生成
func generate_collision(strategy := "full", replace := false, one_way_top := false) -> int:
	if map_root == null:
		_hint("无地图：先新建或打开一张地图")
		return 0
	if is_layer_locked(collision_index()):
		_hint("碰撞层已锁定：先解锁")
		return 0
	var src := _layer_node(active_layer)
	if src == null or active_layer == collision_index():
	 # _layer_node 对碰撞元层返回 collision 节点本身——自动碰撞若不拦，
	 # 就会从碰撞层读瓦片生成碰撞（自己抄自己）
		_hint("切到一个瓦片层再用自动碰撞（当前是碰撞元层）")
		return 0
	_push_undo()
	if replace:
		for c in collision.get_used_cells():
			set_collision_cell(c, false)
	var added := 0
	for c in src.get_used_cells():
		if not _collision_wanted(c, strategy):
			continue
		if collision.get_cell_source_id(c) != -1:
			continue
 # 顶部策略可生成 one_way（自动碰撞策略扩展，契约类型 one_way）
		var typ := "one_way" if (strategy == "top" and one_way_top) else "solid"
		set_collision_cell(c, true, typ)
		added += 1
	_mark(false)   # 自动碰撞只写碰撞层
	queue_redraw()
	return added

## 预览：不写入，只算会新增多少格
func count_auto_collision(strategy := "full", replace := false) -> int:
	if map_root == null:
		return 0
	var src := _layer_node(active_layer)
	if src == null or active_layer == collision_index():
		return 0   # 碰撞元层不是瓦片来源（同 generate_collision）
	var n := 0
	for c in src.get_used_cells():
		if not _collision_wanted(c, strategy):
			continue
		if not replace and collision.get_cell_source_id(c) != -1:
			continue
		n += 1
	return n

func _collision_wanted(c: Vector2i, strategy: String) -> bool:
	match strategy:
		"top":
			return not _has_terrain_at(c + Vector2i(0, -1))
		"outline":
			return not _has_terrain_at(c + Vector2i(1, 0)) \
				or not _has_terrain_at(c + Vector2i(-1, 0)) \
				or not _has_terrain_at(c + Vector2i(0, 1)) \
				or not _has_terrain_at(c + Vector2i(0, -1))
		_:
			return true

## 碰撞格统一写入口——涂刷/擦除/矩形/粘贴/自动生成全走这里，类型元数据跟着走。
## solid+矩形不记 meta（缺省值零冗余）；其余记 {type, shape}；擦除连 meta 一起清。
func set_collision_cell(c: Vector2i, on: bool, type := "solid", shape := "") -> void:
	if on:
		collision.set_cell(c, 0, INVISIBLE_CELL)
		if type != "solid" or shape != "":
			_collision_meta[c] = {"type": type, "shape": shape}
		else:
			_collision_meta.erase(c)
	else:
		collision.erase_cell(c)
		_collision_meta.erase(c)

# ——— 修改标记 ——
## 整图版本号：任何写入（瓦片/碰撞/实体/绑定）都 +1。内容编辑器的预览瓦片数组以它为缓存键。
var map_rev := 0
## 实体集版本号：只有实体增删/改 id/meta 绑定时 +1。实例列表与预览实体数组以它为缓存键。
var ents_rev := 0

## ents_changed=false：只改了地形/装饰/碰撞，实体集没动——不必让实体索引失效。
func _mark(ents_changed := true) -> void:
	modified_flag = true
	map_rev += 1
	if ents_changed:
		_ent_by_id_dirty = true   # 实体集变了，索引置脏
		ents_rev += 1             # 下游缓存（内容编辑器实例/预览数组）随之失效
	# 碰撞可视节点是数据的镜像，任何写入（涂刷/擦除/矩形/生成/粘贴/撤销）后都要重画。
	# 统一在这里刷新，避免每个调用点各记一次、漏掉就出现「数据改了但红块没变」。
	if coll_view and is_instance_valid(coll_view):
		coll_view.refresh()
	modified.emit()

## 实体 {code: Sprite2D} 索引——绘制连线 O(n) 复用；置脏后首次取用重建
func _ent_by_code_index() -> Dictionary:
	if _ent_by_id_dirty:
		var out := {}
		for e0 in ents_all():
			var spr0 = e0 as Sprite2D
			if spr0:
				out[str(spr0.get_meta("code", ""))] = spr0
		_ent_by_id = out
		_ent_by_id_dirty = false
	return _ent_by_id

# —— 撤销/重做（快照式：每次笔画/盖章/删除/移动前存整图状态） ——
# 快照以 JSON 字符串保存：比嵌套 Variant 字典省内存，深拷贝天然隔离。
const UNDO_MAX := 80
var undo_stack := []
var redo_stack := []

# —— 输入状态 ——
## 手势互斥。原来平铺 8 个布尔位（_panning/_drag_paint/_drag_box/_drag_spawn/
## _rmb_erase/_drag_entity/_move_active/_paste_mode），无互斥——拖实体时按中键会平移+拖动并行，
## 拖出生点时按右键会拖动+擦除并行。现在只留一个枚举：起手即接管，松手即清零，
## 任何新起手都会顶掉上一个手势（物理上不可能叠加）。
## _paste_mode 是「模式」不是手势（跨点击存活），不在枚举里。
enum Gesture { NONE, PAN, PAINT, BOX, SPAWN_DRAG, ERASE, ENTITY_DRAG, REGION_MOVE }
var gesture: int = Gesture.NONE
## 起手按键：中键松手只清中键起的平移，不会误杀 Space+左键的平移（反之亦然）。
var gesture_button := 0

func begin_gesture(g: int, button := 0) -> void:
	gesture = g
	gesture_button = button

func end_gesture() -> void:
	gesture = Gesture.NONE
	gesture_button = 0

## 派生只读位（绘制块与松手分派仍按这两个语义判断）
var _drag_box: bool:
	get:
		return gesture == Gesture.BOX
var _move_active: bool:
	get:
		return gesture == Gesture.REGION_MOVE

@warning_ignore("unused_private_class_variable")
var _drag_start := Vector2.ZERO
# 实体拖拽移动
var _drag_entity: Sprite2D = null
var _drag_entities: Array = []
var _drag_origins: Array = []
@warning_ignore("unused_private_class_variable")
var _drag_grab := Vector2.ZERO
var _drag_moved := false

# —— 区域复制粘贴（层栈瓦片 + 碰撞 + 实体打包快照） ——
func _any_layer_locked() -> bool:
	for i in layer_count() + 1:
		if is_layer_locked(i):
			return true
	return false

# —— 层管理：新建/删除/上下移（先 extract 快照 → 在快照上改 → load_data 重建） ——
## 顺序是硬约束：extract 按节点下标取瓦片、按声明序取层码，两者必须对齐——
## 不能「先改活体 meta 再 extract 反向同步」（会串层/丢瓦片）。
## 撤销快照由 _push_undo 在改动前压栈；重建窗口期（extract 返回 {}）放弃操作。
## 新层默认插到栈顶之下——新建即可画前景遮挡。
func layer_add(name: String) -> void:
	if map_root == null or not is_instance_valid(map_root):
		return
	_push_undo()
	var snap := extract()
	if snap.is_empty():
		return
	var meta: Dictionary = snap.get("meta", {})
	var L: Array = meta.get("layers", [])
	var entry := {"id": ContentIdRef.new_inst_code(), "name": name if name != "" else "新层", "visible": true}
	if L.size() >= 2:
		L.insert(L.size() - 1, entry)
	else:
		L.append(entry)
	meta["layers"] = L
	snap["meta"] = meta
	_load_snap_layers(snap, layer_id(active_layer))

## 删层 = 删内容：快照上摘掉层声明，该层瓦片与实体一并过滤（撤销可回）。
## 拒绝时静默返回；调用方（层管理 UI）负责给状态栏反馈。
func layer_del(i: int) -> void:
	if map_root == null or not is_instance_valid(map_root) or i < 0 or i >= layer_count():
		return
	if layer_count() <= 1:
		return
	_push_undo()
	var snap := extract()
	if snap.is_empty():
		return
	var active_id := layer_id(active_layer)
	var lid := layer_id(i)
	var meta: Dictionary = snap.get("meta", {})
	var L: Array = meta.get("layers", [])
	L.remove_at(i)
	meta["layers"] = L
	snap["meta"] = meta
	var tiles: Dictionary = snap.get("tiles", {})
	tiles.erase(lid)
	snap["tiles"] = tiles
	var keep := []
	for e in (snap.get("entities", []) as Array):
		if str((e as Dictionary).get("layer", "")) != lid:
			keep.append(e)
	snap["entities"] = keep
	_load_snap_layers(snap, active_id)

func layer_rename(i: int, name: String) -> void:
	var L := layers_decl()
	if i < 0 or i >= L.size() or str(name) == "":
		return
	_push_undo()
	(L[i] as Dictionary)["name"] = str(name)
	_mark(false)   # 只改 meta，不动节点

func layer_move(i: int, dir: int) -> void:
	if map_root == null or not is_instance_valid(map_root):
		return
	var L := layers_decl()
	var nj := i + dir
	if i < 0 or i >= L.size() or nj < 0 or nj >= L.size():
		return
	_push_undo()
	var snap := extract()
	if snap.is_empty():
		return
	var active_id := layer_id(active_layer)
	var meta: Dictionary = snap.get("meta", {})
	var SL: Array = meta.get("layers", [])
	var tmp = SL[i]
	SL[i] = SL[nj]
	SL[nj] = tmp
	meta["layers"] = SL
	snap["meta"] = meta
	_load_snap_layers(snap, active_id)

## 运行时初始可见（差分视图用）；编辑视图显隐走 set_layer_hidden，两回事。
func layer_set_visible(i: int, v: bool) -> void:
	var L := layers_decl()
	if i < 0 or i >= L.size():
		return
	_push_undo()
	(L[i] as Dictionary)["visible"] = v
	_mark(false)

## 层操作收尾：按新快照重建，激活层跟随身份（同码层下标，层没了落最底层）。
func _load_snap_layers(snap: Dictionary, active_id: String) -> void:
	load_data(snap, cur_map_name, true, true)
	var ni := _layer_index_of(active_id)
	active_layer = ni if ni >= 0 else 0

# —— 绘制：网格 + 光标幽灵预览 ——

func _select_entity_at(pos: Vector2) -> void:
	_selection_ops_ctrl._select_entity_at(pos)

func _entity_at(pos: Vector2) -> Sprite2D:
	return _selection_ops_ctrl._entity_at(pos)

func _box_select(a: Vector2, b: Vector2) -> void:
	_selection_ops_ctrl._box_select(a, b)

func _multi_bounds(targets: Array) -> Rect2:
	return _selection_ops_ctrl._multi_bounds(targets)

func _inside_multi_box(pos: Vector2) -> bool:
	return _selection_ops_ctrl._inside_multi_box(pos)

## 框选组热区外扩量（像素）：绘制与命中共用，保证所见即所点
func _multi_hot() -> float:
	return _selection_ops_ctrl._multi_hot()

func _begin_entity_drag(spr: Sprite2D, pos: Vector2) -> void:
	_selection_ops_ctrl._begin_entity_drag(spr, pos)

func _begin_group_drag(pos: Vector2) -> void:
	_selection_ops_ctrl._begin_group_drag(pos)

func _move_drag_preview(pos: Vector2) -> void:
	_selection_ops_ctrl._move_drag_preview(pos)

func _finish_entity_drag() -> void:
	_selection_ops_ctrl._finish_entity_drag()

func copy_selection() -> void:
	_selection_ops_ctrl.copy_selection()

func cut_selection() -> void:
	_selection_ops_ctrl.cut_selection()

func paste_at(pos: Vector2) -> void:
	_selection_ops_ctrl.paste_at(pos)

func delete_selection() -> void:
	_selection_ops_ctrl.delete_selection()

func flip_selected() -> bool:
	return _selection_ops_ctrl.flip_selected()

func copy_region() -> void:
	_selection_ops_ctrl.copy_region()

## 区域拖动搬迁（框选后按住区内拖动）
func _in_region_sel(pos: Vector2) -> bool:
	return _selection_ops_ctrl._in_region_sel(pos)

func _begin_region_move(pos: Vector2) -> void:
	_selection_ops_ctrl._begin_region_move(pos)

func _move_region_preview(pos: Vector2) -> void:
	_selection_ops_ctrl._move_region_preview(pos)

func _finish_region_move() -> void:
	_selection_ops_ctrl._finish_region_move()

func cut_region() -> void:
	_selection_ops_ctrl.cut_region()

func _paste_region(origin: Vector2i) -> void:
	_selection_ops_ctrl._paste_region(origin)

func _cell_rect(a: Vector2, b: Vector2) -> Rect2i:
	return _selection_ops_ctrl._cell_rect(a, b)
## —— 拆到 src/core/undo_history.gd 的委托（调用点保持不变） ——
func _snapshot() -> String:
	return _undo_history_ctrl._snapshot()

func _restore(snapshot) -> void:
	await _undo_history_ctrl._restore(snapshot)

func _push_undo() -> void:
	_undo_history_ctrl._push_undo()

func undo() -> bool:
	return await _undo_history_ctrl.undo()

func redo() -> bool:
	return await _undo_history_ctrl.redo()

func extract() -> Dictionary:
	return _undo_history_ctrl.extract()
## —— 拆到 src/canvas/canvas_draw.gd 的委托（调用点保持不变） ——
func _draw() -> void:
	_canvas_draw_ctrl._draw()

func _brush_rect(c: Vector2i) -> Rect2:
	return _canvas_draw_ctrl._brush_rect(c)
## —— 拆到 src/canvas/canvas_input.gd 的委托（调用点保持不变） ——
func _unhandled_input(event: InputEvent) -> void:
	_canvas_input_ctrl._unhandled_input(event)

func cancel_paste_mode() -> void:
	_canvas_input_ctrl.cancel_paste_mode()
## —— 拆到 src/canvas/tool_ops.gd 的委托（调用点保持不变） ——
func _apply_tool(pos: Vector2) -> void:
	_tool_ops_ctrl._apply_tool(pos)

func _brush_cells(c: Vector2i) -> Array:
	return _tool_ops_ctrl._brush_cells(c)

func _paint(c: Vector2i) -> void:
	_tool_ops_ctrl._paint(c)

func _erase_at(pos: Vector2) -> void:
	_tool_ops_ctrl._erase_at(pos)

func _erase_hits(pos: Vector2) -> bool:
	return _tool_ops_ctrl._erase_hits(pos)

func _stamp(c: Vector2i) -> void:
	_tool_ops_ctrl._stamp(c)

## 「当前层自审」：active_layer 的瓦片格判定（自动碰撞/边缘类逻辑共用）
func _has_terrain_at(c: Vector2i) -> bool:
	var tn := _layer_node(active_layer)
	return tn != null and tn.get_cell_source_id(c) != -1
