class_name EditorCanvas
extends Node2D
## 清单驱动的关卡画布（数据化编辑器）：
## 图层 = 地图 meta.layers 声明的混合层栈（层=纯 z 槽，一层可混瓦片+摆放物，
## 栈序即绘制序；碰撞是栈外元层）；瓦片层 = 运行时构建的 TileMapLayer
## （图集 PNG → TileSet，不依赖游戏工程资源）；摆放物 = EntityNode
## （场景图片与实体共用同一数据形状，不实例化游戏 prefab）；出生点 = Marker2D。保存/装载纯 JSON。

signal modified
signal cursor_info(text: String)

const K := preload("res://src/core/constants.gd")   # 共享常量统一在 core/constants.gd
const TilesetCache := preload("res://src/canvas/tileset_cache.gd")   # PF-02：TileSet 构建缓存
const INVISIBLE_CELL := K.INVISIBLE_CELL
const MapStoreRef := preload("res://src/map/map_store.gd")   # 地图数据层（读全工程/写盘）
const ContentIdRef := preload("res://src/content/content_id.gd")   # 分层身份码
const AssetDecl := preload("res://src/assets/asset_decl.gd")   # 清单资产表（assets[]）
const EntityNodeRef := preload("res://src/canvas/entity_node.gd")   # 摆放物节点（场景/实体共用）
const GridSpaceScript := preload("res://src/canvas/grid_space.gd")   # 格↔像素转换层（正交/等距）
const TriTileViewScript := preload("res://src/canvas/tri_tile_view.gd")   # B3：三角格自绘层
const MapFormat := preload("res://src/map/map_format.gd")   # 格式版本/瓦片变换位（v7）
const FunctionDeclsRef := preload("res://src/content/function_decl.gd")   # 挂载补齐（C09）

var active_layer := 0          # 0..N-1 = 层栈下标，N = 碰撞元层
var place_kind := "tiles"      # 放置语义跟资产走："tiles"=涂瓦片 / "object"=摆实例（左栏驱动）
var paint_cell := Vector2i(0, 0)  # 当前瓦片（纯手动，不自动变形）

## 瓦片笔刷变换（v7/E08）：alt = 0-7 的 D4 组合编号（map_format 组合表）。
## R 在群上左乘 90°，X 左乘水平翻转——八个档位全可达，翻转在任何旋转档都有效。
var tile_alt := 0

func cycle_tile_rotation() -> void:
	tile_alt = MapFormat.alt_rotate90(tile_alt)
	_hint("瓦片笔刷：%s（R 再转 90°，X 翻转）" % MapFormat.alt_label(tile_alt))
	queue_redraw()

func toggle_tile_flip() -> void:
	tile_alt = MapFormat.alt_flip_h(tile_alt)
	_hint("瓦片笔刷：%s（X 再翻，R 旋转）" % MapFormat.alt_label(tile_alt))
	queue_redraw()

## 吸管回填笔刷变换（E08）：吸取掉的瓦片带着它的 alt 回来，下一笔与原瓦片同向
func set_tile_alt(alt: int) -> void:
	tile_alt = alt & 7
var brush_size := 1               # 笔刷边长（格）
var stamp_asset := ""             # 待放置的资产 id（entity 或 shape=image 的 scene）
var stamp_thumb: Texture2D
var show_grid := true
## 吸附开关：开（默认）= 落点吸附格；关 = 保留浮点位置（亚格摆放）
var snap_to_grid := true
## 框选开关（左栏「框选」按钮）：打开后任意层普通左键拖动都进入框选；
## 关闭时保留 Ctrl+拖动作为兼容入口。输入分派见 canvas_input.gd。
var select_mode := false
var zoom := 2.0
var manifest: Dictionary
## E2：根 app 引用（引用字段写入口需要状态栏/确认框）。由 editor_layout 在挂树前注入；
## 空 = 未注入（引用连线的写入口自动降级为不可用，其余编辑不受影响）。
var app_host = null
var map_data := {}
var cur_map_name := ""
var map_root: Node2D
# 层栈节点：下标 = meta.layers 栈序；每层 = 一个瓦片 TileMapLayer + 一个实体容器。
# 树序 = 栈序（底→顶），碰撞网格与红叠加在栈外（永远画在最上）。
var layer_tiles: Array = []
var layer_ents: Array = []
## B3 三角拓扑：每层一个自绘视图（与 layer_tiles 同序；非三角拓扑时为空）
var tri_views: Array = []
var spawn: Marker2D
var tile_set: TileSet
var atlas_tex: Texture2D
var atlas_img: Image
## 装载时未能解析的瓦片（资产缺失/图集读不到）：按层保存原始 6 元组，
## 提取时原样写回——缺素材不允许把已存瓦片记录抹掉（D02）。
var _unresolved_tiles := {}
# 多图集：全部图集（索引 = TileSet source_id = 地图格 atlas 维度）
var atlas_imgs: Array = []
# 实体 by_id 索引缓存——_mark/load_data 置脏，绘制连线时 O(n) 复用
var _ent_by_id := {}
var _ent_by_id_dirty := true
var atlas_texs: Array = []
# 清单里 shape=tile 的资产（顺序 = TileSet source_id）与 id→source_id 映射
var _tile_assets: Array = []
var _src_of_asset := {}
# 当前笔刷：资产 id + 图集内 cell（source_id 落笔时查）
var paint_asset := ""
var collision_type := "solid"
var collision_shape := ""
# 碰撞类型元数据 {Vector2i: {type, shape}}——solid+矩形不记（缺省值，零冗余）
var _collision_meta: Dictionary = {}
var thumbs := {}
## 实体类型 → 编辑器占位尺寸（像素）。有值时画布按该尺寸画框（比缩略图更接近游戏碰撞）。
var ent_sizes := {}
var tile_w := 16   # 格宽（像素）；tileSize 标量时 tile_h = tile_w
var tile_h := 16   # 格高（像素）；矩形格 [w,h]（R-01 批 1c）
var grid   # GridSpaceScript：格↔像素转换层（正交/等距），_cell_of 与落点换算走它
var modified_flag := false
## 文档操作互斥（A2）：保存确认/写入期间暂停撤销与重做，避免快照在写盘中途被恢复。
var doc_busy := false
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
	# 层参数预览：parallax ≠ 1 的层按相机位移反向平移（远景半速、0 = 固定）。
	# offset/scale 在 load_data 时已作用到层容器；这里只补视差分量。
	var meta: Dictionary = map_data.get("meta", {}) if map_data != null else {}
	var mw := int(meta.get("w", 0)) * tile_w
	var mh := int(meta.get("h", 0)) * tile_h
	var center := Vector2(mw * 0.5, mh * 0.5)
	for n in layer_ents:
		var root := n as Node2D
		if root == null or not is_instance_valid(root):
			continue
		var par := float(root.get_meta("parallax", 1.0))
		var off: Vector2 = root.get_meta("base_pos", root.position)
		if not root.has_meta("base_pos"):
			root.set_meta("base_pos", root.position)
		root.position = off + (cam_pos - center) * (1.0 - par)


# —— 运行时 TileSet：从清单 assets[] 的 shape=tile 资产构建（按资产缓存，见 tileset_cache.gd） ——
func _build_tileset() -> bool:
	var all_sets: Array = AssetDecl.tile_sets(manifest)
	# 故障隔离（A4）：一个图集文件缺失只影响它自己的瓦片，不拖垮整张图的 TileSet。
	# 停用资产仍参与构建——已有瓦片要能继续渲染，停用只把它从调色板摘掉。
	_tile_assets = []
	for a in all_sets:
		var ap := str((a as Dictionary).get("atlas_abs", ""))
		if ap == "" or not FileAccess.file_exists(ap):
			push_warning("图集缺失，已跳过: %s (%s)" % [str((a as Dictionary).get("id", "")), ap])
			continue
		_tile_assets.append(a)
	if _tile_assets.is_empty():
		return false
	var lst: Array = []
	for a in _tile_assets:
		var d: Dictionary = a
		var aid := str(d.get("id", ""))
		var ys := {}
		for p in AssetDecl.palette_of(manifest, aid):
			var pe: Dictionary = p
			ys["%d,%d" % [(pe.cell as Vector2i).x, (pe.cell as Vector2i).y]] = int(pe.get("ySortOrigin", 0))
		lst.append({"id": aid,
			"atlas_abs": str(d.get("atlas_abs", "")),
			"cell": AssetDecl.cell_size(manifest, aid),
			"ysort": ys})
	var got := TilesetCache.build(lst, Vector2i(tile_w, tile_h), _map_projection())
	if got.is_empty():
		return false
	atlas_imgs = got.imgs
	atlas_texs = got.texs
	tile_set = got.ts
	# 资产 id ↔ source_id 双向映射（磁盘写资产 id，TileMapLayer 要整数）
	_src_of_asset.clear()
	for i in (got.ids as Array).size():
		_src_of_asset[str((got.ids as Array)[i])] = i
	atlas_img = got.imgs[0] if not (got.imgs as Array).is_empty() else null
	atlas_tex = got.texs[0] if not (got.texs as Array).is_empty() else null
	return true

## 资产 id → TileSet source_id；未知返回 -1（地图里指向已删资产）
func source_of_asset(aid: String) -> int:
	return int(_src_of_asset.get(aid, -1))

## source_id → 资产 id；未知返回空串
func asset_of_source(sid: int) -> String:
	if sid < 0 or sid >= _tile_assets.size():
		return ""
	return str((_tile_assets[sid] as Dictionary).get("id", ""))

## 资产在图集里的切片尺寸（像素）；非 tile 资产退回地图格。
func asset_cell(aid: String) -> Vector2i:
	return AssetDecl.cell_size(manifest, aid)

## E1：同图重建（undo/尺寸调整）时按层码找回原激活层。空串 = 不恢复。
var _active_lid_before := ""

# —— 装载地图数据 ——
func load_data(data: Dictionary, map_name: String, keep_cam := false, keep_dirty := false) -> void:
	# E1：同图重建（撤销恢复/尺寸调整）按层码找回原激活层——必须在换掉 map_data
	# **之前**取层码，否则读到的是新图的层栈配旧下标。
	var same_map_reload := str(cur_map_name) == map_name and keep_cam
	_active_lid_before = layer_id(active_layer) \
		if same_map_reload and active_layer >= 0 and active_layer < layer_count() else ""
	# 进入即抬代数；await 恢复后比对——过期 = 期间又有更新的重建进入，本协程退出
	_rebuild_gen += 1
	var gen := _rebuild_gen
	map_data = data
	cur_map_name = map_name
	# 清单 tileSize 是「一格 = 多少像素」的唯一真相：网格/边界/实体对齐/碰撞视图全用它。
	# 标量 = 正方形格；[w,h] = 矩形格（B1：正整数像素，畸形值回退 16×16）。
	var gsize: Vector2i = GridSpaceScript.tile_size_of(manifest)
	tile_w = gsize.x
	tile_h = gsize.y
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
	# 剪贴板是纯数据快照（E12）：切图后仍可用，不随载图清空
	# （区域剪贴板自带源图名/码，跨图粘贴时据此补配对地图字段）。
	_collision_meta.clear()
	_drag_entity = null
	_drag_entities.clear()
	_drag_origins.clear()
	_drag_moved = false
	# 区域拖动快照清干净：跨图残留旧图实体的 freed 引用（注释声称的「输入/区域状态复位」补齐）
	_move_snap = {}
	_move_from = Vector2i.ZERO
	if not keep_dirty:
		layer_hidden.clear()
		layer_locked.clear()
	var saved_cam := cam_pos
	var saved_zoom := zoom
	if map_root:
		map_root.queue_free()
		# 不在场景树内（headless 直调）时 get_tree() 为 null——旧 root 的释放排到退出即可，
		# 协程同步走到重建分支（gen 守卫仍然保护并发重建）
		var tree := get_tree()
		if tree != null:
			await tree.process_frame
	# 代数过期 = 期间又有更新一次的重建进入——本协程退出，root 交给最新协程创建
		if gen != _rebuild_gen:
			return
	map_root = Node2D.new()
	map_root.z_index = -1   # 地图内容整体沉到画布参照层之下（碰撞叠加/网格/幽灵画在 canvas 自绘层）
	map_root.name = "MapRoot"
	add_child(map_root)
	_build_tileset()
	# 格↔像素转换层（正交/等距）：瓦片资产清单就位后才能判投影
	grid = GridSpaceScript.new(Vector2i(tile_w, tile_h), _map_projection())
	# B3：可选双基向量斜平面（meta.gridBasis）。非法声明静默不生效——校验页会报具体键。
	var bmeta: Dictionary = map_data.get("meta", {}) if map_data.get("meta", {}) is Dictionary else {}
	var bparsed: Dictionary = GridSpaceScript.parse_basis(bmeta)
	if bool(bparsed.get("ok", false)) and (bparsed.get("u", Vector2.ZERO) as Vector2) != Vector2.ZERO:
		grid.set_basis(bparsed.get("u", Vector2.ZERO), bparsed.get("v", Vector2.ZERO))
	# B3：可选格拓扑（meta.gridTopology = triangles）：格号 evens/odds 组合成平行四边形列。
	var tparsed: Dictionary = GridSpaceScript.parse_topology(bmeta, _map_projection())
	grid.set_topology(str(tparsed.get("topology", "quads")))
	# 旧图冻结生效投影（B1）：此后清单资产增删不再改变这张图的空间口径
	_freeze_projection()
	# 背景：整块铺满视口（比地图尺寸大得多），作为地图之外区域的底色
	var meta: Dictionary = data.get("meta", {})
	# 分层身份码：地图段。老图没有就补发（保存在 meta.code，地图改名不影响它）。
	# 统一走项目级分配器，避免新图与缺码老图撞上同码后互相覆盖（D08）。
	if str(meta.get("code", "")) == "":
		if MapStoreRef.ensure_code(manifest, data):
			map_data = data
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
	var map_size := Vector2(mw * tile_w, mh * tile_h)
	bg.size = map_size * 6.0
	bg.position = -map_size * 2.5
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_root.add_child(bg)
	# 地图区域内只比背景亮一档——目的是提示"这里是可编辑边界"，不该抢地形视觉
	var field := ColorRect.new()
	field.name = "Field"
	field.color = Color("#101520")
	field.position = Vector2.ZERO
	field.size = Vector2(mw * tile_w, mh * tile_h)
	field.z_index = -9
	field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_root.add_child(field)
	# 层栈节点：按 meta.layers 栈序创建。遮挡模型（REFACTOR_PLAN 3.7）：层 = 三段容器，
	# below / YSort（瓦片 + auto 实体同住一个 y-sorted 父）/ above；全程不写 z_index，跨层只认栈序。
	layer_tiles.clear()
	layer_ents.clear()
	tri_views.clear()
	var L := layers_decl()
	for li in L.size():
		var ld: Dictionary = L[li] if L[li] is Dictionary else {}
		var ly := bool(ld.get("ySort", false))
		var root := Node2D.new()
		root.name = "Layer%d" % li
		var below := Node2D.new()
		below.name = "Below"
		var ysp := Node2D.new()
		ysp.name = "YSort"
		ysp.y_sort_enabled = ly
		var tn := TileMapLayer.new()
		tn.name = "Tiles"
		tn.tile_set = tile_set
		tn.y_sort_enabled = ly
		ysp.add_child(tn)
		# B3 三角拓扑：TileMapLayer 表现不了半格三角，叠一个自绘视图（数据仍住在 tn）
		if grid != null and grid.is_tri():
			var tv := TriTileViewScript.new()
			tv.name = "TriTiles"
			tv.setup(tn, grid, self)
			ysp.add_child(tv)
			tri_views.append(tv)
			tn.visible = false   # 数据节点不显示；可见性由 TriTileView 跟随层显隐
		var above := Node2D.new()
		above.name = "Above"
		root.add_child(below)
		root.add_child(ysp)
		root.add_child(above)
		# 层参数预览：offset/scale 作用在层容器；parallax 在 _update_cam 里叠加相机位移
		var off = ld.get("offset", null)
		if off is Array and (off as Array).size() >= 2:
			root.position = Vector2(float((off as Array)[0]), float((off as Array)[1]))
		var sc = ld.get("scale", null)
		if sc is int or sc is float:
			root.scale = Vector2.ONE * float(sc)
		root.set_meta("parallax", float(ld.get("parallax", 1.0)))
		# 层混合模式（v7/E11）：材质挂到**实际绘制内容的子节点**（Below/YSort/Above/瓦片层），
		# 根节点只是容器不画东西——挂根上子节点不继承，混合模式等于没生效。
		var blend := str(ld.get("blend", "mix"))
		if blend == "add" or blend == "mul":
			for dn in [below, ysp, tn, above]:
				var mat := CanvasItemMaterial.new()
				mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD if blend == "add" \
					else CanvasItemMaterial.BLEND_MODE_MUL
				(dn as CanvasItem).material = mat
		map_root.add_child(root)
		layer_tiles.append(tn)
		layer_ents.append(root)
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
	coll_view.setup(collision, tile_w, grid)
	coll_view.canvas_ref = self   # 读 _collision_meta 做类型化分色分形
	coll_view.manifest = manifest   # 碰撞类型颜色按清单 collisionTypes 声明
	# 涂瓦片：tiles = {层id: [[x,y,资产id,ax,ay,alt]...]}（6 元，第 3 位是资产 id 字符串）
	var tiles_data = data.get("tiles", {})
	if not (tiles_data is Dictionary):
		tiles_data = {}
	_unresolved_tiles.clear()
	var missing_assets := {}
	for li2 in L.size():
		var lid := layer_id(li2)
		var tn2: TileMapLayer = layer_tiles[li2]
		for c in (tiles_data.get(lid, []) as Array):
			var arr := c as Array
			var src: int = source_of_asset(str(arr[2]))
			if src < 0:
				# 资产缺失（清单还没同步/图集读不到）：保留原始记录，保存时原样写回
				if not _unresolved_tiles.has(lid):
					_unresolved_tiles[lid] = []
				(_unresolved_tiles[lid] as Array).append((arr as Array).duplicate())
				missing_assets[str(arr[2])] = true
				continue
			var alt: int = int(arr[5]) if (arr as Array).size() >= 6 else 0
			TilesetCache.set_cell_alt(tn2, Vector2i(int(arr[0]), int(arr[1])), src,
				Vector2i(int(arr[3]), int(arr[4])), alt)
	if not missing_assets.is_empty():
		var names: Array = missing_assets.keys()
		_hint("有 %d 种瓦片资产未能装载（%s）：这些瓦片已保留，补齐清单/图集后重开可恢复" % [
			names.size(), ", ".join(PackedStringArray(names.slice(0, 4)))])
	# 碰撞条目对象（v6）：{x, y}，type 缺省省略（solid）、shape 缺省省略（矩形）。
	# 读侧兼容 v5 数组条目（在内存里归一成对象，保存时写对象），写侧只产对象。
	for c in data.get("collision", []):
		var ce := {}
		if c is Dictionary:
			ce = c
		elif c is Array and (c as Array).size() >= 2:
			var ca: Array = c
			ce = {"x": int(ca[0]), "y": int(ca[1])}
			if (ca as Array).size() >= 3 and str(ca[2]) != "" and str(ca[2]) != "solid":
				ce["type"] = str(ca[2])
			if (ca as Array).size() >= 4 and str(ca[3]) != "":
				ce["shape"] = str(ca[3])
		else:
			continue
		var ccell := Vector2i(int(ce.get("x", 0)), int(ce.get("y", 0)))
		collision.set_cell(ccell, 0, INVISIBLE_CELL)
		var tname := str(ce.get("type", "solid"))
		var sname := str(ce.get("shape", ""))
		if tname != "solid" or sname != "":
			_collision_meta[ccell] = {"type": tname, "shape": sname}
	# 摆放物：objects[] 统一收场景图片与实体（数据形状一致，仅 entity 带 code）。
	# 位置 = 浮点格坐标 + anchor 换算；transform/visible/zPolicy 缺省整键省略。
	var bottom := layer_id(0)
	var mount_filled := false
	for e in data.get("objects", []):
		if not (e is Dictionary):
			continue
		var aid := str((e as Dictionary).get("asset", ""))
		if aid == "":
			continue
		var n := make_object(aid)
		n.code = str((e as Dictionary).get("code", ""))
		n.props = (e as Dictionary).get("props", {}) if (e as Dictionary).get("props", {}) is Dictionary else {}
		n.functions = (e as Dictionary).get("functions", []) if (e as Dictionary).get("functions", []) is Array else []
		# C09：载图即补齐类型挂载（只在工作副本上，不碰选中事件）；缺的补一条 mounted 行并标脏
		if n.is_entity():
			var fill := FunctionDeclsRef.fill_bindings(manifest, aid, n.functions)
			if bool(fill.get("changed", false)):
				n.functions = fill.get("functions", [])
				mount_filled = true
		n.data_transform = (e as Dictionary).get("transform", {}) if (e as Dictionary).get("transform", {}) is Dictionary else {}
		n.raw = (e as Dictionary).duplicate(true)
		n.z_policy = str((e as Dictionary).get("zPolicy", "auto"))
		n.visible_flag = bool((e as Dictionary).get("visible", true))
		var lid := str((e as Dictionary).get("layer", bottom))
		var ei := _layer_index_of(lid)
		if ei < 0:
			ei = 0
		n.layer_id = layer_id(ei)
		n.refresh_visual()   # props 就位后再算一次尺寸（sizeFields 资产按 props 定大小）
		n.apply_grid(float((e as Dictionary).get("x", 0)), float((e as Dictionary).get("y", 0)))
		_place_in_layer(n, ei)
		_ensure_code(n)
	# 出生点（数据是格坐标，画布上落在格中心）
	spawn = Marker2D.new()
	spawn.name = "Spawn"
	var sp: Array = data.get("spawn", [2, 2])
	spawn.position = grid.cell_center_px(Vector2i(int(sp[0]), int(sp[1])))
	map_root.add_child(spawn)
	# 地图装载后同步碰撞可视节点与图层可见性（按图层索引恢复，不只是节点 flag）
	coll_view.refresh()
	for i in layer_count() + 1:
		_layer_ops_ctrl._apply_layer_shown(i)

	# 相机：撤销时保持视角，否则对准出生点
	if keep_cam:
		cam_pos = saved_cam
		zoom = saved_zoom
	else:
		cam_pos = spawn.position
	_update_cam()
	# keep_dirty：撤销/重做恢复路径不抹脏标记（快照恢复后内容与磁盘
	# 不一致就是脏的），普通载入清零；emit 只在这里发一次，undo/redo 不再自己发。
	# C09：载图补齐过挂载 → 工作副本与磁盘不一致，必须标脏，等作者保存。
	modified_flag = keep_dirty or mount_filled
	if mount_filled:
		_hint("已给实例补齐类型自带功能（挂载）——保存后写入地图")
	# 换图后层数可能变少：激活层钳回合法区间（0..层栈数，含碰撞元层下标）。
	# E1：同图重建（撤销恢复/尺寸调整）按**层码**找回原激活层——层栈增删后
	# 下标会漂，沿用下标会悄悄切到邻居层。
	var want_lid := _active_lid_before
	if want_lid != "":
		var li2: int = _layer_index_of(want_lid)
		if li2 >= 0:
			active_layer = li2
	_active_lid_before = ""
	active_layer = clampi(active_layer, 0, layer_count())
	_ent_by_id_dirty = true   # 整图载入（含撤销恢复）索引置脏
	map_rev += 1              # 整图替换后下游缓存必须重扫
	ents_rev += 1
	vis_rev += 1              # 层栈重建：可见集合缓存作废（P01）
	modified.emit()
	# 载入后选区引用已失效——发 null 让属性面板/侧栏同步清空，悬空引用不再滞留
	entity_selected.emit(null)

# —— 缩略图注入（app 启动时把实体缩略图交给画布） ——
func _ready() -> void:
	z_index = 5   # canvas 自绘（网格/幽灵/碰撞叠加/出生标记）盖在地图子树之上
	_selection_ops_ctrl = preload("res://src/canvas/selection_ops.gd").new(self)
	_region_ops_ctrl = preload("res://src/canvas/region_ops.gd").new(self)
	_layer_ops_ctrl = preload("res://src/canvas/layer_ops.gd").new(self)
	_entity_factory_ctrl = preload("res://src/canvas/entity_factory.gd").new(self)
	_undo_history_ctrl = preload("res://src/core/undo_history.gd").new(self)
	_canvas_draw_ctrl = preload("res://src/canvas/canvas_draw.gd").new(self)
	_canvas_input_ctrl = preload("res://src/canvas/canvas_input.gd").new(self)
	_tool_ops_ctrl = preload("res://src/canvas/tool_ops.gd").new(self)
	# E2：实例引用字段的统一写入口（宿主 = 根 app：状态栏/确认框在那边）。
	# app_host 由 editor_layout 在 add_child 之前注入（_ready 时已就位）。
	_ref_ops_ctrl = preload("res://src/canvas/ref_ops.gd").new(app_host)
	# 视口尺寸变化时重绘底色（否则窗口缩放后底板会露出旧底色）
	get_viewport().size_changed.connect(func(): queue_redraw())
	queue_redraw()

func set_thumbs(t: Dictionary) -> void:
	thumbs = t


## 出生点：画布上的可拖对象。
## 命中容差 0.6 格——它只有一个绿十字那么大，严格点中几乎不可能。
func _on_spawn(pos: Vector2) -> bool:
	if spawn == null or not is_instance_valid(spawn):
		return false
	var lp := root_cell(pos)
	return pos.distance_to(to_layer_world(collision_index(), grid.cell_center_px(lp))) <= grid.cell_max() * 0.6 \
		or pos.distance_to(spawn.get_global_position()) <= grid.cell_max() * 0.6

## 拖动出生点：位置对齐到格中心（数据只存格坐标，浮点位置保存会被取整回去）
func _drag_spawn_to(pos: Vector2) -> void:
	if spawn == null or not is_instance_valid(spawn):
		return
	var c := root_cell(pos)
	spawn.position = grid.cell_center_px(c)
	queue_redraw()

# —— 坐标换算 ——
## 转发：选区命中跨层（顶层向下取第一个）；tool_ops 擦除用单层版
func _entity_hit(pos: Vector2) -> EntityNode:
	return _selection_ops_ctrl._entity_hit(pos)

## 指定层的实体命中（擦除只认当前层；层隐藏时直接无命中）
func _entity_hit_on(li: int, pos: Vector2) -> EntityNode:
	if li < 0 or li >= layer_count() or not is_layer_visible(li):
		return null
	return _selection_ops_ctrl._entity_hit_in(_layer_entities(li), pos, li)

func _cell_of(pos: Vector2) -> Vector2i:
	return grid.pick_cell(_active_local(pos))

## —— 层局部坐标（E02）——
## 层参数 offset/scale/parallax 作用在层容器上：瓦片格号、实例 position、poly 点集
## 全在**层局部**空间。拾取先世界→候选层局部再取格；拖拽先算世界位移、逐层逆变换。
## 活动层容器（碰撞元层取 map_root——碰撞格与出生点都在根空间）。
func active_layer_root() -> Node2D:
	if active_layer < layer_ents.size() and active_layer >= 0:
		return layer_ents[active_layer] as Node2D
	if map_root != null and is_instance_valid(map_root):
		return map_root
	return null

## 第 i 层的世界变换（无层节点时 = 原点，画布自身无变换）
func layer_xform(i: int) -> Transform2D:
	var root := _layer_ents_or_collision(i)
	if root == null:
		return Transform2D.IDENTITY
	return root.get_global_transform()

func _layer_ents_or_collision(i: int) -> Node2D:
	if i >= 0 and i < layer_ents.size():
		return layer_ents[i] as Node2D
	if _is_grid_layer(i) and map_root != null and is_instance_valid(map_root):
		return map_root
	return null

## 世界 → 层局部
func to_layer_local(i: int, world: Vector2) -> Vector2:
	return layer_xform(i).affine_inverse() * world

## 层局部 → 世界
func to_layer_world(i: int, local: Vector2) -> Vector2:
	return layer_xform(i) * local

## 活动层局部（鼠标输入换算入口）。碰撞元层住在 map_root 空间（与出生点同系）。
func _active_local(world: Vector2) -> Vector2:
	if active_layer == collision_index():
		return map_root.get_global_transform().affine_inverse() * world if is_map_ready() else world
	return to_layer_local(clampi(active_layer, 0, maxi(layer_count() - 1, 0)), world)

## 根空间格号（出生点/区域原点这类层栈外的格用；map_root 无变换时 = 世界）
func root_cell(world: Vector2) -> Vector2i:
	var lp := world
	if is_map_ready():
		lp = map_root.get_global_transform().affine_inverse() * world
	return grid.pick_cell(lp)

## 世界位移 → 层局部位移（拖拽/微调共用；只取线性部分，不带平移）
func world_delta_local(i: int, delta: Vector2) -> Vector2:
	return layer_xform(i).affine_inverse().basis_xform(delta)

## 地图投影：地图自己的 meta.gridProjection 优先（B1 逐图投影），缺键沿用项目解析
## （任一瓦片资产声明 isometric/hexagonal 即整项目按该投影）。旧图首次保存时把生效投影
## 冻结进 meta（见 _freeze_projection），此后与清单资产增删解耦。
func _map_projection() -> String:
	var meta: Dictionary = map_data.get("meta", {}) if map_data is Dictionary else {}
	var own := str(meta.get("gridProjection", ""))
	if own == "isometric" or own == "hexagonal" or own == "orthogonal":
		return own
	return GridSpaceScript.project_projection(manifest)

## 旧图冻结投影（B1）：地图缺 meta.gridProjection 时，把当前生效投影写进内存 meta。
## 只改内存（随首次保存落盘），不标脏——打开旧图不应该因为读一眼就变脏。
func _freeze_projection() -> void:
	if not (map_data is Dictionary):
		return
	var meta: Dictionary = map_data.get("meta", {}) if map_data.get("meta", {}) is Dictionary else {}
	if meta.has("gridProjection"):
		return
	var proj := _map_projection()
	if proj == "orthogonal":
		return   # 正交是缺省，不写冗余键
	meta["gridProjection"] = proj
	map_data["meta"] = meta

## 活动层局部格号（坐标栏/涂刷路径共用）
func _active_cell(pos: Vector2) -> Vector2i:
	return grid.pick_cell(_active_local(pos))

## 地图已装载且 root 有效（E14：无图时输入/绘制提前返回，不碰坐标换算）
func is_map_ready() -> bool:
	return map_root != null and is_instance_valid(map_root)

## 是否有内容（B1）：瓦片/碰撞/实例任一非空——投影切换守卫的依据。
## 普通设置只允许在空图上切投影；带内容的切换必须先做显式转换并保存副本。
func has_content() -> bool:
	for tn in layer_tiles:
		if not (tn as TileMapLayer).get_used_cells().is_empty():
			return true
	if collision != null and not collision.get_used_cells().is_empty():
		return true
	return not ents_all().is_empty()

## 格空间方向向量 → 像素位移（方向键微调/原位复制的格对齐移动；正交 = 轴对齐，等距沿菱形方向，六边沿格中心连线）
func grid_dir_px(dx: int, dy: int) -> Vector2:
	return grid.to_px(Vector2(dx, dy)) - grid.to_px(Vector2.ZERO)

## —— 最终可见性（E06） ——
## 实例眼睛 + 所属层显隐。命中/框选/连线/出口角标/预览全走这里，
## 不能只看节点 visible（层隐藏时节点旗标仍是 true）。
func is_entity_shown(n: EntityNode) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	if not n.visible_flag:
		return false
	var li := _layer_index_of(n.layer_id)
	return li < 0 or is_layer_visible(li)

## 可见实例合集（绘制连线/出口/框选候选的公共入口）。
## P01：按 (ents_rev, vis_rev, 层栈) 缓存——鼠标每动一像素都调它，
## 原实现每次全量遍历 + 逐实例 _layer_index_of 线性查层。
func ents_shown() -> Array:
	var key := "%d:%d:%d" % [ents_rev, vis_rev, layer_count()]
	if key == _shown_key:
		return _shown_cache
	var out := []
	for e in ents_all():
		var n := e as EntityNode
		if n != null and is_entity_shown(n):
			out.append(n)
	_shown_cache = out
	_shown_key = key
	return out

## 层码是否可编辑（锁定）：未知层码不阻止（数据兜底落在 0 层）
func is_layer_code_locked(lid: String) -> bool:
	var li := _layer_index_of(lid)
	return li >= 0 and is_layer_locked(li)

## 放置/拖动落点：吸附开启时把「数据格坐标」四舍五入到整格（对齐锚点在格内的位置，
## 与实例尺寸无关）。关闭时原样保留。
## 六边形（B1）：格坐标 = 连续反算（不取最近中心），锚点偏移按包围盒内单位算，
## 不再把正交的 +0.5 格偏量塞进六边中心坐标。
func snap_point(p: Vector2, n: EntityNode = null) -> Vector2:
	var unit: Vector2 = n.anchor_unit() if n != null else Vector2(0.5, 0.5)
	return snap_anchor_px(unit, p)

## 指定层的层局部吸附（实例拖拽收尾/粘贴共用）：入参已是该层局部像素。
func snap_point_local(li: int, p: Vector2, n: EntityNode = null) -> Vector2:
	var unit: Vector2 = n.anchor_unit() if n != null else Vector2(0.5, 0.5)
	return snap_anchor_px(unit, p)

## 按「格内锚点单位坐标」吸附像素点（幽灵预览与实例落点共用同一口径）。
## 入参是**层局部空间**的像素点（E02）；世界坐标调用方先 to_layer_local。
func snap_anchor_px(unit: Vector2, p: Vector2) -> Vector2:
	if not snap_to_grid:
		return p
	if grid.is_tri():
		# B3 三角格：吸附到三角形重心（格号 = (三角列, 行)）
		var tri: Vector2i = grid.pick_cell(p)
		return grid.tri_center_px(tri.x, tri.y)
	if grid.is_hex():
		var off: Vector2 = (unit - Vector2(0.5, 0.5)) * Vector2(grid.tile)
		var gh: Vector2 = grid.to_continuous_grid(p - off)
		return grid.to_px(Vector2(roundf(gh.x), roundf(gh.y))) + off
	var g = grid.to_grid(p) - unit
	return grid.to_px(Vector2(roundf(g.x), roundf(g.y)) + unit)

# —— 涂刷/擦除（图层硬规则：瓦片/碰撞层禁盖章，实体层禁涂刷；笔刷 = 以 c 为基准的 brush_size×brush_size 格，偶数尺寸时 c 偏右下） ——
func _hint(t: String) -> void:
	cursor_info.emit(t)

# —— 实例身份：4 位码（唯一身份：引用/重映射/连线全用它） ——
## 码出生时在本图活跃实例集内查重（`_fresh_inst_code` 撞码重摇），不查已删实例的历史码——
## 所以「不回收」是编辑流程约定，不是全工程扫描保证。
# 重建代数——load_data 是协程，期间再进一次 load_data 时，先进者按代数退出防孤儿 map_root
var _rebuild_gen := 0

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
		# 吸管连资产一起吸（多图集瓦片吸取后原样落笔），变换位也一并吸回（E08）
		paint_asset = asset_of_source(tn.get_cell_source_id(c))
		set_tile_alt(MapFormat.alt_of_godot(tn.get_cell_alternative_tile(c)))
		# 不直写 active_layer——直写会短路 editor_state 的切层分支（状态文案不出）；
		# 经 tool_requested 走 _apply_state 单一写入口
		_hint("已吸取 %s %s（切到该层涂刷）" % [str(ac), MapFormat.alt_label(tile_alt)])
		tool_requested.emit("paint", li)
		return
	_hint("该格没有可吸取的瓦片（碰撞层不参与吸管）")

## 整图入视野（Home）——相机对中 + 缩放夹回 0.5~6.0。
## 取可见对象、瓦片与碰撞的并集（E14）：只有瓦片时背景图/纯实体图会拟合到默认空范围。
func _fit_view() -> void:
	if not is_map_ready() or layer_tiles.is_empty():
		_hint("无地图：先新建或打开一张地图")
		return
	# 用第一个非空矩形做种子再合并——Rect2i() 以 (0,0) 为种子会让 union 恒含原点，
	# 内容不贴原点时 Home 的中心与缩放全错
	var used := Rect2i()
	var seed_set := {"has": false}
	var take := func(r: Rect2i):
		if r.size == Vector2i.ZERO:
			return
		used = r if not (seed_set.has as bool) else used.merge(r)
		seed_set["has"] = true
	for li in layer_tiles.size():
		if is_layer_visible(li):
			take.call((layer_tiles[li] as TileMapLayer).get_used_rect())
	if collision != null and is_layer_visible(collision_index()):
		take.call(collision.get_used_rect())
	for e in ents_all():
		var n := e as EntityNode
		if n == null or n.asset == "" or not is_entity_shown(n):
			continue
		var r := n.rect()
		var li: int = _layer_index_of(n.layer_id)
		if li >= 0:
			r = layer_xform(li) * r
		take.call(Rect2i(floori(r.position.x / float(maxi(tile_w, 1))), floori(r.position.y / float(maxi(tile_h, 1))),
			maxi(1, ceili(r.size.x / float(maxi(tile_w, 1)))), maxi(1, ceili(r.size.y / float(maxi(tile_h, 1))))))
	if not seed_set.has:
		used = Rect2i(0, 0, 10, 10)
	cam_pos = grid.cell_center_px(Vector2i(used.get_center()))
	var vp := get_viewport_rect().size
	# 视野拟合用地图像素包围盒（等距/六边 = 多边形包围盒，不是格子数×格宽）
	var pb = grid.map_bounds(used)
	zoom = clampf(minf(vp.x / maxf(pb.size.x, 1.0), vp.y / maxf(pb.size.y, 1.0)) * 0.9, 0.5, 6.0)
	_update_cam()

# —— 选择实体 ——
signal entity_selected(node: EntityNode)

var selected_entity: EntityNode = null
var selected_multi: Array = []   # 框选集合（Del / 复制粘贴用）
## 引用指向预览：内容编辑器里编辑引用字段时，画布高亮被指实例（存实例码）
var ref_highlight := ""
## E1：把相机对到某实例（选点确认后切回视图时，目标必须真的出现在视野里；
## 否则「已选目标」只存在于数据里，用户看不到自己刚指的那一格）。
func focus_entity_code(code: String) -> bool:
	var n = _ent_by_code_index().get(code, null)
	if n == null or not is_instance_valid(n):
		return false
	cam_pos = _w_for(n as EntityNode)
	_update_cam()
	queue_redraw()
	return true

## 实例世界位置（视觉锚点，扣 sortAnchor）；与 canvas_draw._w 同口径
func _w_for(n: EntityNode) -> Vector2:
	var li: int = _layer_index_of(n.layer_id)
	var lp := n.position - n.sort_anchor()
	return lp if li < 0 else to_layer_world(li, lp)
## E1 临时选点：非空 = 画布处于「为引用字段挑目标」模式，只高亮不写数据。
## 目标码只在宿主点「确认」时才提交；取消/Esc 什么都不改（选中也不动）。
signal pick_mode_picked(code: String)
## E1：右键在选点模式里 = 取消（单独一条信号：空码是合法提交值，不能和取消混用）
signal pick_mode_cancelled
var pick_mode_active := false
var pick_mode_code := ""       # 已点中的候选实例码（"" = 还没点；确认提交的就是它）
var pick_mode_hover := ""      # 光标下的候选（只做高亮预览，不参与提交）
var pick_mode_hint := ""       # 确认条文字（由宿主设定：字段名 + 操作说明）
var pick_mode_accept := "entity"  # "entity" = 只认实体；"any" = 实体与场景实例都可选
var pick_mode_owner := ""      # 发起方标记（"content" / "steps"），归宿主管
var pick_mode_types: Array = []  # E2：声明的 of 白名单（空 = 不限资产类型）
@warning_ignore("unused_private_class_variable")
var _clipboard: Array = []       # 实例复制模板 [{asset, code, dx, dy, transform, functions, props}]
var _region_sel := Rect2i(-1, 0, 0, 0)  # 区域框选结果（瓦片层 Ctrl+C 用）
var _region_clip := {}           # 区域快照 {tiles:{层id:[...]}, collision[], entities[], size}
var _paste_mode := false         # 区域粘贴预览态（幽灵跟随鼠标）
# 区域拖动搬迁（框选后按住区内拖动）：按下只快照，松手才擦源写目标
var _move_snap := {}
var _move_from := Vector2i.ZERO
## 拆分后经 cvs._move_grab 供 region_ops 读写（类内未用 = 分析器看不到跨控制器引用）
@warning_ignore("unused_private_class_variable")
var _move_grab := Vector2.ZERO
@warning_ignore("unused_private_class_variable")
var _move_cell_delta := Vector2i.ZERO
var _selection_ops_ctrl   # SelectionOps：实体选区/剪贴板控制器
var _region_ops_ctrl   # RegionOps：区域复制/剪切/粘贴/搬迁控制器
var _layer_ops_ctrl   # LayerOps：层栈运行时与管理
var _entity_factory_ctrl   # EntityFactory：实体工厂/实例码发号
var _undo_history_ctrl   # UndoHistory：快照式撤销/重做控制器
var _canvas_draw_ctrl   # CanvasDraw：绘制控制器
var _canvas_input_ctrl   # CanvasInput：鼠标输入路由控制器
var _tool_ops_ctrl   # ToolOps：左键/右键语义执行控制器
## E2 连线：引用端点拖动（跨控制器读写，分析器看不到类内使用）
var _ref_ops_ctrl   # RefOps：实例引用字段统一写入口
@warning_ignore("unused_private_class_variable")
var _link_node: EntityNode = null
@warning_ignore("unused_private_class_variable")
var _link_fd := {}
@warning_ignore("unused_private_class_variable")
var _link_hover := ""
@warning_ignore("unused_private_class_variable")
var _link_grab := Vector2.ZERO
@warning_ignore("unused_private_class_variable")
var _link_can_clear := false
var _last_copy_region := false   # 最近一次复制是区域还是实体（Ctrl+V 分发）

# —— 选择提交入口（E09）——
## 放置/工作台选中/删除统一走这里：画布单选+多选+信息条必须一起更新。
## 只发信号不写 selected_entity 会让「信息条显示新件、Del 删旧组」。
func commit_selection(n: EntityNode, multi: Array = []) -> void:
	selected_entity = n
	selected_multi = multi.filter(func(x): return is_instance_valid(x))
	entity_selected.emit(n)
	queue_redraw()

# —— E1 临时选点：为引用字段在画布上挑目标（确认才提交） ——

## 进入选点模式：不碰选中/数据；候选高亮画在画布层，宿主负责确认条与提交。
## want_types（E2）：声明的 of 白名单；非空时候选只认这些资产类型——与连线把手同一判据，
## 不让「画布选…」点到一个字段收不下的目标。
func begin_pick_mode(owner: String, accept: String, hint: String, want_types: Array = []) -> void:
	pick_mode_active = true
	pick_mode_owner = owner
	pick_mode_accept = accept if accept == "any" else "entity"
	pick_mode_code = ""
	pick_mode_hover = ""
	pick_mode_hint = hint
	pick_mode_types = want_types.duplicate()
	queue_redraw()

## 退出选点模式（确认/取消都走这里）：只清模式状态，不动选中与字段值。
func end_pick_mode() -> void:
	pick_mode_active = false
	pick_mode_code = ""
	pick_mode_hover = ""
	pick_mode_hint = ""
	pick_mode_owner = ""
	pick_mode_types = []
	queue_redraw()

## 选点模式下光标处的候选实例码（"" = 不可选）。命中口径与普通选择一致；
## accept=entity 时跳过场景实例（它们没有实例码，不能进引用字段）。
func pick_candidate_at(pos: Vector2) -> String:
	var n := _entity_at(pos)
	if n == null or not is_instance_valid(n):
		return ""
	if n.code == "":
		return ""
	if pick_mode_accept == "entity" and not n.is_entity():
		return ""
	if not pick_mode_types.is_empty() and not pick_mode_types.has(n.asset):
		return ""
	return n.code

## 框选集合提交：首成员作单选，整组进多选，一次 emit
func commit_multi(multi: Array) -> void:
	var valid: Array = []
	for s in multi:
		if is_instance_valid(s):
			valid.append(s)
	selected_multi = valid
	selected_entity = valid[0] if not valid.is_empty() else null
	entity_selected.emit(selected_entity)
	queue_redraw()

## 选区是否触碰锁定/隐藏层（E04）：app 级快捷键（方向键微调、Ctrl+D）也要走同一检查，
## 不能只靠画布内命令自检——否则锁定层内容会被键盘改掉。
func selection_touches_locked(sel: Array) -> bool:
	return _selection_ops_ctrl._selection_touches_locked(sel)

## Ctrl+D 原位复制（C2：与粘贴/整图复制同一条 ClonePlan 流程）。
## 副本偏移 offset 格、落回原件所在层、身份与附属内容全部独立；一个撤销步 + 选中新副本。
## 返回是否真的复制了（锁层/计划冲突时 false，状态提示已由本函数或调用方给出）。
func duplicate_selected_at_offset(srcs: Array, offset: Vector2i) -> bool:
	var ClonePlan := preload("res://src/content/clone_plan.gd")
	if map_root == null:
		return false
	var rows: Array = []
	var live: Array = []
	for s in srcs:
		var n := s as EntityNode
		if n == null or not is_instance_valid(n) or n.asset == "":
			continue
		live.append(n)
		rows.append({"asset": n.asset, "code": n.code,
			"props": n.props.duplicate(true), "functions": n.functions.duplicate(true)})
	if live.is_empty():
		return false
	var plan: Dictionary = ClonePlan.build(
		{"data": {"objects": rows}, "manifest": manifest, "map": cur_map_name},
		{"data": map_data, "manifest": manifest, "map": cur_map_name})
	if str(plan.get("status", "")) != "ok":
		_hint("复制已取消：" + ClonePlan.conflicts_text(plan.get("conflicts", [])))
		return false
	# 内容先落盘（A2）：写失败不动画布
	var ContentStore := preload("res://src/content/content_store.gd")
	for pc in (plan.get("pending_contents", []) as Array):
		var pd: Dictionary = pc
		if not ContentStore.write(manifest, str(pd.get("fn_id", "")), str(pd.get("id", "")),
				pd.get("data", {}) as Dictionary):
			_hint("复制已取消：新内容 %s 写入失败" % str(pd.get("id", "")))
			return false
	_push_undo()
	var remapped: Array = (plan.get("map_patch", {}) as Dictionary).get("objects", [])
	var copies: Array = []
	for i in live.size():
		var orig: EntityNode = live[i]
		var row: Dictionary = remapped[i] if i < remapped.size() else {}
		var dup: EntityNode = make_object(orig.asset)
		dup.props = (row.get("props", {}) as Dictionary).duplicate(true) \
			if row.get("props", null) is Dictionary else orig.props.duplicate(true)
		dup.functions = (row.get("functions", []) as Array).duplicate(true) \
			if row.get("functions", null) is Array else orig.functions.duplicate(true)
		dup.data_transform = orig.data_transform.duplicate(true)
		dup.z_policy = orig.z_policy
		dup.visible_flag = orig.visible_flag
		# sortAnchor 与未知对象键随原件走（E12：完整对象负载）
		var raw: Dictionary = orig.raw.duplicate(true)
		if str(row.get("code", "")) != "":
			raw["code"] = str(row.get("code", ""))
		dup.raw = raw
		dup.code = str(row.get("code", ""))
		dup.refresh_visual()
		dup.position = orig.position + grid_dir_px(offset.x, offset.y)
		var oi: int = _layer_index_of(orig.layer_id)
		if oi < 0:
			oi = 0
		dup.layer_id = layer_id(oi)
		_place_in_layer(dup, oi)
		_ensure_code(dup)   # 计划已给码；无码实例（场景图片）在这里也不会产码
		copies.append(dup)
	_mark()
	commit_multi(copies)
	var n_contents: int = (plan.get("pending_contents", []) as Array).size()
	_hint("已复制 %d 个实例%s（Ctrl+Z 撤销）" % [
		copies.size(), ("，复制内容 %d 条" % n_contents) if n_contents > 0 else ""])
	return not copies.is_empty()

# —— 框选集合有效性过滤 ——
func _valid_multi() -> Array:
	var out := []
	for s in selected_multi:
		if is_instance_valid(s):
			out.append(s)
	return out


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
## 镜像视图刷新范围也按数据来源拆（P01）：普通瓦片涂改不该重建碰撞全层，
## 碰撞涂改也不该重画三角瓦片自绘。窄入口见 _mark_tiles / _mark_collision。
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
	# 三角自绘层同样镜像瓦片数据（drop_cell/mark 后必须重画）
	for tv in tri_views:
		if tv != null and is_instance_valid(tv):
			(tv as Node).refresh()
	modified.emit()

## P01：只改瓦片（地形/装饰）——碰撞数据没动，红块不必重建。
## 方形瓦片由 TileMapLayer 自己在 set_cell/erase_cell 后重绘；
## 三角拓扑下叠的自绘层仍需重建（数据住在 TileMapLayer 里，自绘层读不到变更通知）。
func _mark_tiles() -> void:
	modified_flag = true
	map_rev += 1
	for tv in tri_views:
		if tv != null and is_instance_valid(tv):
			(tv as Node).refresh()
	modified.emit()

## P01：只改碰撞层——实体与瓦片都没动，只刷红块镜像。
func _mark_collision() -> void:
	modified_flag = true
	map_rev += 1
	if coll_view and is_instance_valid(coll_view):
		coll_view.refresh()
	modified.emit()

## 图层显隐版本号：ents_shown() 的可见集合缓存以它为键之一（层隐藏改变可见性
## 但不改实体集，ents_rev 抓不到）。实例眼睛开关走 visible_flag → 调用方照常 _mark()。
var vis_rev := 0

## 可见实例合集缓存：绘制每帧都取（P01 前是每帧全量遍历 + 逐实例查层）。
var _shown_cache: Array = []
var _shown_key := ""

## 实例 {code: EntityNode} 索引——绘制连线 O(n) 复用；置脏后首次取用重建。
## 场景实例没有 code，不进索引（引用/连线只认实体）。
func _ent_by_code_index() -> Dictionary:
	if _ent_by_id_dirty:
		var out := {}
		for e0 in ents_all():
			var n := e0 as EntityNode
			if n != null and n.code != "":
				out[n.code] = n
		_ent_by_id = out
		_ent_by_id_dirty = false
	return _ent_by_id

## 实例码是否指向本图实例（引用字段高亮用：跨图引用码在本图不存在，不能高亮）。
func is_entity_code_local(code: String) -> bool:
	if code == "":
		return false
	return _ent_by_code_index().has(code)

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
enum Gesture { NONE, PAN, ENTITY_VERTEX, PAINT, BOX, SPAWN_DRAG, ERASE, ENTITY_DRAG, ENTITY_RESIZE, REGION_MOVE, LINK_DRAG }
var gesture: int = Gesture.NONE
## 起手按键：中键松手只清中键起的平移，不会误杀 Space+左键的平移（反之亦然）。
var gesture_button := 0

func begin_gesture(g: int, button := 0) -> void:
	gesture = g
	gesture_button = button

func end_gesture() -> void:
	gesture = Gesture.NONE
	gesture_button = 0

## 取消未完成的**预览型**手势并恢复原值（E05）：拖动/尺寸/顶点/出生点/区域搬迁
## 在活体上写的是候选值，相机平移或保存读取前必须先归位，否则落点/草稿带着半途状态。
## 涂刷/擦除是已提交的笔画，不在此列（它们各自在首个真实改动前压过撤销）。
## 返回是否取消了某手势（调用方据此给状态栏反馈）。
func cancel_preview_gesture() -> bool:
	match gesture:
		Gesture.ENTITY_DRAG:
			for i in _drag_entities.size():
				if is_instance_valid(_drag_entities[i]):
					(_drag_entities[i] as EntityNode).position = _drag_origins[i]
			_drag_entity = null
			_drag_entities.clear()
			_drag_origins.clear()
			_drag_moved = false
		Gesture.ENTITY_RESIZE:
			if _resize_node != null and is_instance_valid(_resize_node):
				var orig: Dictionary = _resize_orig
				_resize_node.props[str(orig.get("wf", "w"))] = int(orig.get("w", 1))
				_resize_node.props[str(orig.get("hf", "h"))] = int(orig.get("h", 1))
				_resize_node.refresh_visual()
			_resize_node = null
			_resize_moved = false
		Gesture.ENTITY_VERTEX:
			if _vertex_node != null and is_instance_valid(_vertex_node):
				_vertex_node.points_write(_vertex_orig)
				_vertex_node.refresh_visual()
			_vertex_node = null
			_vertex_moved = false
		Gesture.SPAWN_DRAG:
			if spawn != null and is_instance_valid(spawn):
				spawn.position = _spawn_origin
		Gesture.REGION_MOVE:
			_move_snap = {}
			_move_cell_delta = Vector2i.ZERO
		Gesture.LINK_DRAG:
			# E2：连线拖动只在松手时写数据，取消只需清暂存（画布未被改动）
			_link_node = null
			_link_fd = {}
			_link_hover = ""
			_link_grab = Vector2.ZERO
			_link_can_clear = false
		_:
			return false
	end_gesture()
	queue_redraw()
	return true

## 派生只读位（绘制块与松手分派仍按这两个语义判断）
## 手势派生只读位：canvas_draw/canvas_input 经 cvs._drag_box 读取
@warning_ignore("unused_private_class_variable")
var _drag_box: bool:
	get:
		return gesture == Gesture.BOX
@warning_ignore("unused_private_class_variable")
var _move_active: bool:
	get:
		return gesture == Gesture.REGION_MOVE

@warning_ignore("unused_private_class_variable")
var _drag_start := Vector2.ZERO
# 实例拖拽移动
var _drag_entity: EntityNode = null
var _drag_entities: Array = []
var _drag_origins: Array = []
@warning_ignore("unused_private_class_variable")
var _drag_grab := Vector2.ZERO
var _drag_moved := false
var _resize_node: EntityNode = null   # R-04 尺寸把手拖拽的目标实例（带 sizeFields）
var _resize_orig: Dictionary = {}     # 起手时的 {wf, hf, w, h}
var _resize_origin := Vector2.ZERO    # 起手时 rect 左上角快照（center 锚点下 rect 原点随尺寸漂移，必须冻结）
var _resize_moved := false
var _vertex_node: EntityNode = null   # R-02 顶点把手拖拽的目标实例（poly/path）
var _vertex_idx := -1                 # 拖拽中的顶点下标
var _vertex_orig: Array = []          # 起手点集快照（Vector2 数组）
var _vertex_moved := false
## 出生点拖动起手位置（E05：起手中断要能归位，不能留在半途格）
var _spawn_origin := Vector2.ZERO
## 笔画上一格（E13）：快速涂/擦时鼠标事件会跳格，逐帧按格路径补涂中间格
var _stroke_last_cell := Vector2i.ZERO
var _stroke_has_last := false
## 涂刷笔画的撤销快照推迟到首个真实改动前才压（点击不动 = 零副作用，与出生点拖动同模式）
## 涂刷撤销快照推迟标记：tool_ops 经 cvs._paint_pushed 读写
@warning_ignore("unused_private_class_variable")
var _paint_pushed := false

# —— 区域复制粘贴（层栈瓦片 + 碰撞 + 实体打包快照） ——
func _any_layer_locked() -> bool:
	for i in layer_count() + 1:
		if is_layer_locked(i):
			return true
	return false


# —— 绘制：网格 + 光标幽灵预览 ——

func _select_entity_at(pos: Vector2) -> void:
	_selection_ops_ctrl._select_entity_at(pos)

func _entity_at(pos: Vector2) -> EntityNode:
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

func _begin_entity_drag(n: EntityNode, pos: Vector2) -> void:
	_selection_ops_ctrl._begin_entity_drag(n, pos)

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
func rotate_selected_90() -> bool:
	return _selection_ops_ctrl.rotate_selected_90()
func scale_selected(d: float) -> bool:
	return _selection_ops_ctrl.scale_selected(d)
func _resize_handle_hit(pos: Vector2) -> bool:
	return _selection_ops_ctrl._resize_handle_hit(pos)
func _begin_entity_resize(n: EntityNode, pos: Vector2) -> void:
	_selection_ops_ctrl._begin_entity_resize(n, pos)
func _move_resize_preview(pos: Vector2) -> void:
	_selection_ops_ctrl._move_resize_preview(pos)
func _finish_entity_resize() -> void:
	_selection_ops_ctrl._finish_entity_resize()

## —— R-02 顶点编辑转发 ——
func _vertex_worlds(n: EntityNode) -> Array:
	return _selection_ops_ctrl._vertex_worlds(n)
func _vertex_handle_hit(pos: Vector2) -> int:
	return _selection_ops_ctrl._vertex_handle_hit(pos)
func _begin_vertex_drag(n: EntityNode, idx: int) -> void:
	_selection_ops_ctrl._begin_vertex_drag(n, idx)
func _move_vertex_preview(pos: Vector2) -> void:
	_selection_ops_ctrl._move_vertex_preview(pos)
func _finish_vertex_drag() -> void:
	_selection_ops_ctrl._finish_vertex_drag()
func _add_vertex_at(pos: Vector2) -> bool:
	return _selection_ops_ctrl._add_vertex_at(pos)
func _delete_vertex_at(pos: Vector2) -> bool:
	return _selection_ops_ctrl._delete_vertex_at(pos)

## —— E2 空间连线转发 ——
func _link_handles() -> Array:
	return _selection_ops_ctrl._link_handles()
func _link_handle_hit(pos: Vector2) -> Dictionary:
	return _selection_ops_ctrl._link_handle_hit(pos)
func _begin_link_drag(h: Dictionary, pos: Vector2) -> void:
	_selection_ops_ctrl._begin_link_drag(h, pos)
func _move_link_preview(pos: Vector2) -> void:
	_selection_ops_ctrl._move_link_preview(pos)
func _finish_link_drag() -> void:
	await _selection_ops_ctrl._finish_link_drag()

func copy_region() -> void:
	_region_ops_ctrl.copy_region()

## 区域拖动搬迁（框选后按住区内拖动）
func _in_region_sel(pos: Vector2) -> bool:
	return _region_ops_ctrl._in_region_sel(pos)

func _begin_region_move(pos: Vector2) -> void:
	_region_ops_ctrl._begin_region_move(pos)

func _move_region_preview(pos: Vector2) -> void:
	_region_ops_ctrl._move_region_preview(pos)

func _finish_region_move() -> void:
	_region_ops_ctrl._finish_region_move()

func cut_region() -> void:
	_region_ops_ctrl.cut_region()

func _paste_region(origin: Vector2i) -> void:
	_region_ops_ctrl._paste_region(origin)

func _cell_rect(a: Vector2, b: Vector2) -> Rect2i:
	# 区域框选几何归 RegionOps（E03：松手转发曾错发到选区控制器，调用必炸）
	return _region_ops_ctrl._cell_rect(a, b)
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
	# 只读提交状态（E05）：拖动/尺寸/顶点/出生点/区域搬迁在手势期间把候选值写在活体上，
	# 保存、草稿与撤销快照直接读取会拿到半途坐标。提取前先取消未完成的预览手势归位。
	cancel_preview_gesture()
	return _undo_history_ctrl.extract()
## —— 拆到 src/canvas/canvas_draw.gd 的委托（调用点保持不变） ——
func _draw() -> void:
	_canvas_draw_ctrl._draw()

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

## 自动碰撞委托（碰撞弹窗调用；源层缺省由画布回退到第一个普通层）
func count_auto_collision(strategy := "full", replace := false, src_override := -1) -> int:
	return _tool_ops_ctrl.count_auto_collision(strategy, replace, src_override)

func generate_collision(strategy := "full", replace := false, one_way_top := false, src_override := -1) -> int:
	return _tool_ops_ctrl.generate_collision(strategy, replace, one_way_top, src_override)

## 「当前层自审」：active_layer 的瓦片格判定（自动碰撞/边缘类逻辑共用）
func _has_terrain_at(c: Vector2i) -> bool:
	var tn := _layer_node(active_layer)
	return tn != null and tn.get_cell_source_id(c) != -1

## 碰撞生成从当前 active_layer 读取，若停在碰撞元层，自动退到第一个有瓦片的普通层。
## 返回选中的源层下标；没有可用层返回 -1。
func _collision_source_layer() -> int:
	if active_layer >= 0 and active_layer != collision_index() and _layer_node(active_layer) != null:
		return active_layer
	for i in layer_count():
		if i == collision_index():
			continue
		if _layer_node(i) != null:
			return i
	return -1

func _has_terrain_in(c: Vector2i, li: int) -> bool:
	if li < 0:
		return false
	var tn := _layer_node(li)
	return tn != null and tn.get_cell_source_id(c) != -1

## —— 拆到 src/canvas/layer_ops.gd / entity_factory.gd / tool_ops.gd（调用点保持不变） ——

func layers_decl() -> Array:
	return _layer_ops_ctrl.layers_decl()
func layer_count() -> int:
	return _layer_ops_ctrl.layer_count()
func layer_id(i: int) -> String:
	return _layer_ops_ctrl.layer_id(i)
func layer_name(i: int) -> String:
	return _layer_ops_ctrl.layer_name(i)
func _layer_index_of(lid: String) -> int:
	return _layer_ops_ctrl._layer_index_of(lid)
func collision_index() -> int:
	return _layer_ops_ctrl.collision_index()
func _is_grid_layer(i: int) -> bool:
	return _layer_ops_ctrl._is_grid_layer(i)
func _layer_node(i: int) -> TileMapLayer:
	return _layer_ops_ctrl._layer_node(i)
func ents_all() -> Array:
	return _layer_ops_ctrl.ents_all()
func _layer_entities_of(root: Node2D) -> Array:
	return _layer_ops_ctrl._layer_entities_of(root)
func _layer_entities(li: int) -> Array:
	return _layer_ops_ctrl._layer_entities(li)
func _place_in_layer(n: EntityNode, li: int) -> void:
	_layer_ops_ctrl._place_in_layer(n, li)
func _layer_display_node(i: int) -> Node2D:
	return _layer_ops_ctrl._layer_display_node(i)
func set_layer_hidden(i: int, now_hidden: bool) -> void:
	_layer_ops_ctrl.set_layer_hidden(i, now_hidden)
func is_layer_visible(i: int) -> bool:
	return _layer_ops_ctrl.is_layer_visible(i)
func set_layer_locked(i: int, locked: bool) -> void:
	_layer_ops_ctrl.set_layer_locked(i, locked)
func is_layer_locked(i: int) -> bool:
	return _layer_ops_ctrl.is_layer_locked(i)
func layer_add(new_name: String) -> void:
	await _layer_ops_ctrl.layer_add(new_name)
func layer_del(i: int) -> void:
	await _layer_ops_ctrl.layer_del(i)
func layer_rename(i: int, new_name: String) -> void:
	await _layer_ops_ctrl.layer_rename(i, new_name)
func layer_move(i: int, dir: int) -> void:
	await _layer_ops_ctrl.layer_move(i, dir)
func layer_set_visible(i: int, v: bool) -> void:
	await _layer_ops_ctrl.layer_set_visible(i, v)
func layer_set_blend(i: int, blend: String) -> void:
	await _layer_ops_ctrl.layer_set_blend(i, blend)
func layer_set_param(i: int, key: String, v) -> void:
	await _layer_ops_ctrl.layer_set_param(i, key, v)
func _load_snap_layers(snap: Dictionary, active_id: String) -> void:
	await _layer_ops_ctrl._load_snap_layers(snap, active_id)
func make_object(aid: String) -> EntityNode:
	return _entity_factory_ctrl.make_object(aid)
func set_entity_sizes(sizes: Dictionary) -> void:
	_entity_factory_ctrl.set_entity_sizes(sizes)
func entity_display_size(aid: String) -> Vector2:
	return _entity_factory_ctrl.entity_display_size(aid)
func is_placeable(aid: String) -> bool:
	return _entity_factory_ctrl.is_placeable(aid)
func _ensure_code(n: EntityNode) -> void:
	_entity_factory_ctrl._ensure_code(n)
func _fresh_inst_code() -> String:
	return _entity_factory_ctrl._fresh_inst_code()
