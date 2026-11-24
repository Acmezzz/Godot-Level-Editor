extends RefCounted
## _canvas_draw_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。

var cvs   # 宿主引用

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")
const K := preload("res://src/core/constants.gd")
const EdgeRefRef := preload("res://src/map/edge_ref.gd")   # §7.4：格边高亮/取值
const TriTileViewScript := preload("res://src/canvas/tri_tile_view.gd")   # 格多边形贴图 UV

func _init(host) -> void:
	cvs = host
func _draw() -> void:
	if not cvs.is_map_ready():
		return
	var pos = cvs.get_global_mouse_position()
	var c = cvs._cell_of(pos)
	var li: int = cvs.active_layer
	var paint_grid: GridSpace = cvs.tile_grid_for_layer(li)
	var layer_frame: Transform2D = cvs.layer_xform(li)
	var local_mouse_for_grid: Vector2 = cvs._active_local(pos)
	# 网格覆盖整个地图边界（meta w×h），碰撞/实体放在地形外也有网格
	var meta0: Dictionary = cvs.map_data.get("meta", {})
	var map_rect := Rect2i(0, 0, int(meta0.get("w", K.DEFAULT_MAP_W)), int(meta0.get("h", K.DEFAULT_MAP_H)))
	if cvs.show_grid:
		# 网格按可视区间裁剪——120×56 满图每帧 176 条抗锯齿线，鼠标一动就全付。
		# 可见世界矩形由 canvas_transform 反变换得到（headless 无视口时退回整图包围盒）。
		var mb = cvs.grid.map_bounds(map_rect)
		var vis := Rect2(mb.position, mb.size)
		var vp: Viewport = cvs.get_viewport()
		if vp != null:
			vis = vp.get_canvas_transform().affine_inverse() * Rect2(Vector2.ZERO, vp.get_visible_rect().size)
		var segs = cvs.grid.grid_lines(vis, map_rect)
		for k in range(0, segs.size(), 2):
			cvs.draw_line(segs[k], segs[k + 1], Color(1, 1, 1, 0.07), 1.0, true)
		if paint_grid != cvs.grid:
			var local_vis := MapViewData.xform_rect(layer_frame.affine_inverse(), vis)
			var local_lines := paint_grid.grid_lines(local_vis, map_rect)
			for k in range(0, local_lines.size(), 2):
				cvs.draw_line(layer_frame * local_lines[k], layer_frame * local_lines[k + 1],
					Color(0.3, 0.8, 0.95, 0.22), 1.0, true)
		
	# 幽灵预览：只看「手上拿着什么」，没有工具要判断
	var on_ent: bool = cvs.place_kind == "object" and not cvs._is_grid_layer(cvs.active_layer)
	if cvs._geometry_draw.active():
		cvs._geometry_draw.draw(pos)
	elif (on_ent and cvs.grid.map_bounds(map_rect).has_point(local_mouse_for_grid)) \
			or (not on_ent and paint_grid.cell_in_map(c, map_rect.size.x, map_rect.size.y)):
		if on_ent:
			# 摆放模式：手上拿着资产就画它的幽灵，否则画「点这里会选中」的提示框
			if cvs.stamp_asset != "":
				var ad := AssetDecl.by_id(cvs.manifest, cvs.stamp_asset)
				var unit: Vector2 = EntityNode.anchor_unit_of(ad)
				var gsz: Vector2 = cvs.entity_display_size(cvs.stamp_asset)
				# 带 sizeFields 的资产落下时带 2×2 默认尺寸（tool_ops._stamp），幽灵按同一尺寸画
				if ad.get("sizeFields", null) is Array and (ad.get("sizeFields", []) as Array).size() >= 2:
					gsz = Vector2(2, 2) * Vector2(cvs.grid.tile)
				# 幽灵在**活动层局部空间**生成再变到世界（E02）：层偏移/缩放时，
				# 预览与落笔位置一致（落笔 position 就是层局部位）。
				var li_a: int = clampi(cvs.active_layer, 0, maxi(cvs.layer_count() - 1, 0))
				var local_mouse: Vector2 = cvs.to_layer_local(li_a, pos)
				var anchor_l: Vector2 = local_mouse
				if cvs.snap_to_grid:
					anchor_l = cvs.snap_anchor_px(unit, local_mouse)
				var xf: Transform2D = cvs.layer_xform(li_a)
				# 幽灵按落点的真实占位画（锚点由资产声明决定），和落下去之后完全一致
				var grect := Rect2(anchor_l - EntityNode.anchor_off_of(unit, gsz), gsz)
				grect = Rect2(xf * grect.position, grect.size * Vector2(xf.x.length(), xf.y.length()))
				var gtex: Texture2D = cvs.stamp_thumb
				if gtex == null and str(ad.get("shape", "")) == "image":
					gtex = EntityNode.texture_of(cvs.manifest, str(ad.get("texture", "")))
				if gtex != null:
					cvs.draw_texture_rect(gtex, grect, false, Color(1, 1, 1, 0.5))
					cvs.draw_rect(grect, Color(0.35, 0.95, 0.95, 0.6), false, 1.0)
				else:
					# 无贴图的资产（visual: rect）：按声明画彩色矩形幽灵
					var vis = ad.get("visual", null)
					var col := Color(0.55, 0.85, 1.0, 0.35)
					if vis is Dictionary and str((vis as Dictionary).get("color", "")) != "":
						col = Color(str((vis as Dictionary).get("color")))
						col.a = 0.35
					cvs.draw_rect(grect, col, true)
					cvs.draw_rect(grect, Color(col, 0.85), false, 1.5)
					# poly/path 幽灵（R-02）：按声明缺省点集跟手画形状轮廓
					var gvt := str((vis as Dictionary).get("type", "rect")) if vis is Dictionary else "rect"
					if gvt != "rect":
						var gpts := PackedVector2Array()
						var dpts = (vis as Dictionary).get("points", null)
						if not (dpts is Array) or (dpts as Array).size() < 2:
							dpts = [[0, 0], [cvs.grid.tile.x, 0], [0, cvs.grid.tile.y]] if gvt == "poly" \
								else [[0, 0], [cvs.grid.tile.x, 0]]
						for gp2: Vector2 in _gpts_vec(dpts as Array):
							gpts.append(xf * (anchor_l + gp2))
						var gcol := Color(col.r, col.g, col.b, 0.8)
						if gvt == "path":
							cvs.draw_polyline(gpts, gcol, 3.0, true)
						elif gpts.size() >= 3:
							gpts.append(gpts[0])
							cvs.draw_polyline(gpts, gcol, 1.5, true)
			else:
				var gp: PackedVector2Array = layer_frame * cvs.grid.cell_polygon(cvs.grid.pick_cell(local_mouse_for_grid))
				cvs.draw_polyline(gp + PackedVector2Array([gp[0]]), Color(0.55, 0.85, 1.0, 0.5), 1.0, true)
		else:
			# 瓦片 / 碰撞层：笔刷范围轮廓 + 中心格瓦片幽灵（碰撞层不画瓦片图，只画范围）
			var bcell := Vector2i(c.x - cvs.brush_size / 2, c.y - cvs.brush_size / 2)
			var bpoly: PackedVector2Array = layer_frame * paint_grid.grid_polygon(bcell, bcell + Vector2i(cvs.brush_size, cvs.brush_size))
			var tint := Color(1.0, 0.45, 0.45, 0.55) if cvs._is_grid_layer(cvs.active_layer) else Color(1, 1, 1, 0.5)
			cvs.draw_polyline(bpoly + PackedVector2Array([bpoly[0]]), tint, 1.0, true)
			# 无图集（headless 测试/清单缺图）时不画幽灵，避免 draw_texture_rect_region 空纹理警告
			if not cvs._is_grid_layer(cvs.active_layer):
				# 笔刷幽灵跟 paint_asset 走（多图集项目不再画成 0 号图集的错图）
				var bsrc: int = cvs.source_of_asset(cvs.paint_asset)
				var gtex: Texture2D = cvs.atlas_texs[bsrc] \
					if bsrc >= 0 and bsrc < (cvs.atlas_texs as Array).size() else null
				# 幽灵落在活动层局部空间（层 offset/scale 跟手），格形按拓扑走
				_draw_tile_ghost(gtex, c, cvs.asset_cell(cvs.paint_asset), cvs.paint_cell,
					cvs.tile_alt, clampi(cvs.active_layer, -1, cvs.layer_count() - 1), 0.5)
	# 碰撞叠加由 CollisionView 节点绘制（图层接口控制显隐），这里不再特例绘制。
	# 地图边界（meta w×h，关卡的实际范围）。w/h 是**列数**：三角拓扑下不能用
	# grid_polygon（它吃三角列号，会把边界折半），走列号口径的 map_rect_polygon
	var meta: Dictionary = cvs.map_data.get("meta", {})
	var bpoly = cvs.grid.map_rect_polygon(Vector2i.ZERO,
		Vector2i(int(meta.get("w", K.DEFAULT_MAP_W)), int(meta.get("h", K.DEFAULT_MAP_H))))
	cvs.draw_polyline(bpoly + PackedVector2Array([bpoly[0]]), Color(1, 1, 1, 0.35), 2.0, true)
	# 游玩视野预览（跟随鼠标）：鼠标在哪 = 假设玩家在那，屏幕里能看到什么
	var ss: Array = cvs.manifest.get("screenSize", [640, 360])
	var view_here := Rect2(pos - Vector2(ss[0], ss[1]) * 0.5, Vector2(ss[0], ss[1]))
	cvs.draw_rect(view_here, Color(0.35, 0.65, 1.0, 0.20), false, 1.0)
	# 出生点开局视野（稍实一些）+ 显式出生标记（绿框 + 十字准星）
	var spos = cvs.spawn.position
	var screen_rect := Rect2(spos - Vector2(ss[0], ss[1]) * 0.5, Vector2(ss[0], ss[1]))
	cvs.draw_rect(screen_rect, Color(0.35, 0.65, 1.0, 0.40), false, 1.0)
	# 出生点标记：摆放模式下画成「可拖」的样子，其余画淡一些——避免误导成可点
	var spawn_draggable: bool = on_ent and not cvs.select_mode and not cvs.is_layer_locked(cvs.active_layer)
	var spawn_col := Color(0.3, 1.0, 0.5, 0.9) if spawn_draggable else Color(0.3, 1.0, 0.5, 0.35)
	var sg = cvs.grid.pick_cell(spos)
	var spoly = cvs.grid.cell_polygon(sg)
	cvs.draw_polyline(spoly + PackedVector2Array([spoly[0]]), spawn_col, 2.0, true)
	cvs.draw_line(Vector2(spos.x - 6, spos.y), Vector2(spos.x + 6, spos.y), spawn_col, 2.0)
	cvs.draw_line(Vector2(spos.x, spos.y - 6), Vector2(spos.x, spos.y + 6), spawn_col, 2.0)
	# 引用连线：props.target_point 指向同图另一实例（跨图蓝线 / 同图黄线）
	# 先建 {code: node} 索引——O(n²) 双重遍历改为 O(n)
	var by_code = cvs._ent_by_code_index()   # 脏标记缓存
	# 出口角标 / 落点描边 / 占位框 / 事件区（各层都画）——原先各扫一遍实例集，
	# 鼠标每动一像素就付 5 次 O(n)。现在一次遍历按类别收集，再分段绘制。
	# 只画最终可见的实例（E06）：层隐藏/实例眼睛关掉的内容不参与任何叠加绘制。
	var exits: Array = []
	var landings: Array = []
	var boxes: Array = []
	var zones: Array = []
	for e in cvs.ents_shown():
		var n := e as EntityNode
		if n == null or n.asset == "":
			continue
		var sid := n.asset
		var props: Dictionary = n.props
		var wp := _w(n)
		# 同图引用连线
		var tid := str(props.get("target_point", ""))
		if tid != "":
			var n2 = by_code.get(tid, null)
			if n2 and n2 != n and cvs.is_entity_shown(n2):
				var wobble := str(props.get("target_map", "")) != ""
				var col := Color(0.4, 0.4, 1.0, 0.6) if wobble else Color(1.0, 0.85, 0.3, 0.6)
				cvs.draw_line(wp, _w(n2), col, 1.5)
		# 跨图引用角标（C3）：值 = 地图码，显示时码→名解析一次（code_map 带缓存）。
		# ① 旧约定：role=exit 且 props.target_map 已填；
		# ② 声明驱动：类型声明的 map_ref 字段（含被 entity_ref 配对用的）已填。
		# 两者同一呈现：↗ + 目标图名，让人一眼看到「这条引用跨图了」。
		# P01：声明读实例自带的 decl（创建时归一化好的那份），不在每帧按 id 重查声明池。
		var edecl: Dictionary = n.decl
		var tmap := str(props.get("target_map", "")) \
			if str(edecl.get("role", "")) == "exit" else ""
		if tmap == "":
			for fd in (edecl.get("fields", []) as Array):
				if not (fd is Dictionary):
					continue
				if str((fd as Dictionary).get("type", "")) != "map_ref":
					continue
				var mv := str(props.get(str((fd as Dictionary).get("id", "")), ""))
				if mv != "":
					tmap = mv
					break
		if tmap != "":
			exits.append([wp, tmap])
		# 传送落点（青色描边）与出生 marker（绿十字）拉开色系
		if str(edecl.get("role", "")) == "landing":
			landings.append(n)
		# 实例实际占位（清单 editorSize 或 prefab 碰撞尺寸）：青色实框
		boxes.append(_wr(n))
		# 无贴图的 visual:rect 资产（内置事件区等）：按声明画彩色矩形，不再认 props.event/mode/once。
		var vis = edecl.get("visual", null)
		if n.texture == null and vis is Dictionary and str((vis as Dictionary).get("mode", "")) == "rect":
			zones.append(n)
	if not exits.is_empty():
		var fnt: Font = ThemeDB.fallback_font   # Node2D 无 Control 主题接口，用引擎兜底字体
		if fnt != null:
			# 唯一码显示图名，无法解析时保留原值。
			var cm: Dictionary = cvs.exit_map_names
			for it in exits:
				var shown := str(it[1])
				if cm.has(shown):
					shown = str(cm[shown])
				cvs.draw_string(fnt, it[0] + Vector2(-10, -12), "↗" + shown,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.35, 0.9, 1.0, 0.9))
	for lp in landings:
		cvs.draw_rect(_wr(lp as EntityNode), Color(0.35, 0.9, 1.0, 0.45), false, 1.5)
	# 选中实例高亮（按实例自己的矩形，不是固定 1.5 格）。层局部 → 世界（E02）。
	if cvs.selected_entity and is_instance_valid(cvs.selected_entity):
		var sn: EntityNode = cvs.selected_entity
		var sli: int = cvs._layer_index_of(sn.layer_id)
		var sw := _w(sn)
		cvs.draw_rect(_wr(sn).grow(2.0), Color(1.0, 0.85, 0.3, 0.9), false, 2.0)
		# 排序点十字（R-04/E11）：排序点 = position 本身（含 sortAnchor 偏移），
		# 视觉锚点 = position - sortAnchor。缺省（无 sortAnchor）排序点 = 视觉锚点，不画。
		var sa := sn.sort_anchor()
		if sa != Vector2.ZERO:
			var sp: Vector2 = sw   # position 世界坐标 = 排序点
			var va: Vector2 = sw - sa if sli < 0 else cvs.layer_xform(sli).basis_xform(-sa)
			var scol := Color(0.85, 0.4, 1.0, 0.9)
			cvs.draw_line(sp + Vector2(-5, 0), sp + Vector2(5, 0), scol, 1.5)
			cvs.draw_line(sp + Vector2(0, -5), sp + Vector2(0, 5), scol, 1.5)
			cvs.draw_line(va, sp, Color(0.85, 0.4, 1.0, 0.45), 1.0)
		# 尺寸把手（R-04）：带 sizeFields 的选中实例右下角画把手方块（拖动调 props w/h）
		var sfh = (sn.decl as Dictionary).get("sizeFields", null)
		if sfh is Array and (sfh as Array).size() >= 2:
			var cr: Vector2 = _wr(sn).end
			var side = maxf(cvs.grid.cell_max() * 0.3, 6.0)
			cvs.draw_rect(Rect2(cr - Vector2.ONE * side * 0.5, Vector2.ONE * side), Color(0.85, 0.4, 1.0, 0.9), true)
		# 顶点把手（R-02）：选中 poly/path 实例画顶点方块（拖动/双击加点/右键删点）
		if (sn as EntityNode).visual_type() != "rect":
			var vside := 7.0 / maxf(cvs.zoom, 0.01)
			var rings: Array = cvs._vertex_world_rings(sn as EntityNode)
			for i in rings.size():
				var tint := Color("#dba8ff") if i == 0 else Color("#63e8d1")
				for wp: Vector2 in rings[i]:
					cvs.draw_rect(Rect2(wp - Vector2.ONE * vside * 0.5, Vector2.ONE * vside), tint, true)
	# 引用指向预览：编辑引用字段时高亮被指实例（青色粗框）
	if cvs.ref_highlight != "":
		var hs = cvs._ent_by_code_index().get(cvs.ref_highlight, null)
		if hs and is_instance_valid(hs):
			cvs.draw_rect(_wr(hs as EntityNode).grow(4.0), Color(0.2, 1.0, 0.9, 0.95), false, 2.5)
	# E2 连线把手：选中实例的本图引用端点（拖动换落点）。画在选中高亮之后、框选之前。
	_draw_link_handles()
	# 框选拖拽矩形（框选开关或 Ctrl+拖动，摆放模式或瓦片模式都画同一个框）
	if cvs._drag_box:
		var br := Rect2(cvs._drag_start.min(pos), (cvs._drag_start - pos).abs())
		cvs.draw_rect(br, Color(1.0, 0.85, 0.3, 0.15), true)
		cvs.draw_rect(br, Color(1.0, 0.85, 0.3, 0.8), false, 1.5)
	# 框选集合高亮（小黄框）
	for s in cvs.selected_multi:
		if is_instance_valid(s):
			var mr: Rect2 = _wr(s as EntityNode).grow(maxf(cvs.grid.cell_max() * 0.25, 2.0))
			cvs.draw_rect(mr, Color(1.0, 0.85, 0.3, 0.85), false, 1.5)
	# 多选集合的外接框：明确标出「这一块可以整体拖动」。
	# 框内空白处按下就能拖，鼠标悬停在框内时加亮，给出可操作性暗示。
	# 框选组可跨层（成员可属不同层），绘制与层无关。
	var multi = cvs._valid_multi()
	if multi.size() > 1:
		var mb = cvs._multi_bounds(multi).grow(cvs._multi_hot())
		var hot = mb.has_point(pos)
		cvs.draw_rect(mb, Color(1.0, 0.85, 0.3, 0.22 if hot else 0.10), true)
		cvs.draw_rect(mb, Color(1.0, 0.85, 0.3, 0.9 if hot else 0.5), false, 2.0 if hot else 1.0)
		if cvs._drag_entity == null:
			# 角标提示：拖动整组
			cvs.draw_string(ThemeDB.fallback_font, mb.position + Vector2(4, -4),
				"%d 个实例 · 拖动可整体移动" % multi.size(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(1.0, 0.85, 0.3, 0.9 if hot else 0.55))
	# 实体实际占位（清单 editorSize 或 prefab 碰撞尺寸）：青色实框，已在上面的单次遍历里收集
	for it in boxes:
		var r4: Rect2 = it
		cvs.draw_rect(r4, Color(0.35, 0.95, 0.95, 0.85), false, 1.0)
		# 十字标中心，便于对格
		var c4 := r4.get_center()
		cvs.draw_line(Vector2(r4.position.x, c4.y), Vector2(r4.end.x, c4.y), Color(0.35, 0.95, 0.95, 0.25), 1.0)
		cvs.draw_line(Vector2(c4.x, r4.position.y), Vector2(c4.x, r4.end.y), Color(0.35, 0.95, 0.95, 0.25), 1.0)
	# 无贴图的 visual:rect 资产：按声明画占位矩形，不再读 props.event/mode/once。
	_draw_visual_rects(zones)
	if cvs._region_sel.size.x > 0:
		var selected_li: int = cvs._layer_index_of(cvs._region_layer)
		if cvs._region_layer == "" or selected_li == cvs.active_layer:
			_draw_grid_region(cvs._region_sel.position, cvs._region_sel.size, selected_li, Color(1.0, 0.85, 0.3, 0.8))
	# 区域拖动预览：整块幽灵按当前格偏移跟手，松手才真搬。
	# 每层瓦片在自己的层局部格里，预览按层变换到世界（E02）。
	if cvs.world_region_mode:
		cvs._world_region_move.draw(cvs._move_snap)
	if cvs._move_active and not cvs._move_snap.is_empty() and not cvs._move_snap.has("world"):
		var md: Vector2i = cvs._move_cell_delta
		# 区域原点按投影几何平移（与 _finish_region_move 同一原语）
		var morg: Vector2i = cvs._region_sel.position + md
		var move_li: int = cvs._layer_index_of(cvs._move_snap.get("tile_layer", ""))
		# tiles = {层id: [[x,y,资产id,ax,ay]...]}——按条目所属层变换到世界
		for lid2 in (cvs._move_snap.get("tiles", {}) as Dictionary):
			var lli2: int = cvs._layer_index_of(str(lid2))
			var move_grid: GridSpace = cvs.tile_grid_for_layer(lli2)
			for t in (cvs._move_snap.get("tiles", {}) as Dictionary)[lid2]:
				# 按条目自己的资产 id 取纹理与切片尺寸（预览与真实落笔一致）
				var aid2 := str((t as Array)[2])
				var ai2: int = cvs.source_of_asset(aid2)
				var tex2: Texture2D = cvs.atlas_texs[ai2] \
					if ai2 >= 0 and ai2 < (cvs.atlas_texs as Array).size() else null
				# 幽灵落点与真实搬移同一原语（六边行错位/三角半格列）：不能格号直接相加
				var dst2: Vector2i = move_grid.cell_from_offset(morg, move_grid.relative_cell(
					Vector2i(int((t as Array)[0]), int((t as Array)[1])), cvs._region_sel.position))
				_draw_tile_ghost(tex2, dst2, cvs.asset_cell(aid2),
					Vector2i(int((t as Array)[3]), int((t as Array)[4])),
					int((t as Array)[5]) if (t as Array).size() >= 6 else 0, lli2, 0.6)
		for t in cvs._move_snap.get("collision", []):
			var mc: Vector2i = cvs.grid.cell_from_offset(morg, cvs.grid.relative_cell(Vector2i(int(t[0]), int(t[1])), cvs._region_sel.position))
			cvs.draw_colored_polygon(cvs.grid.cell_polygon(mc), Color(1.0, 0.25, 0.25, 0.45))
		for e0 in cvs._move_snap.get("ents", []):
			# 快照条目 {dx,dy,asset,...}：按区域原点 + 偏移画（快照只存数据，不存节点）
			var d0: Dictionary = e0
			var gaid := str(d0.get("asset", ""))
			var gprops0: Dictionary = d0.get("props", {}) if d0.get("props", {}) is Dictionary else {}
			var gsz0: Vector2 = AssetDecl.instance_size(cvs.manifest, gaid, gprops0, Vector2(cvs.grid.tile))
			# dx/dy 是连续格坐标偏移：基准点由格号折回连续坐标（三角拓扑 = 平行四边形列）
			var gbase0: Vector2 = cvs.grid.cell_origin_continuous(morg)
			var ep: Vector2 = gbase0 \
				+ Vector2(float(d0.get("dx", 0.0)), float(d0.get("dy", 0.0)))
			var gu := EntityNode.anchor_unit_of(AssetDecl.by_id(cvs.manifest, gaid))
			var anchor0: Vector2 = cvs.grid.to_px(ep + gu)
			if cvs.grid.is_hex_geom():
				anchor0 = cvs.grid.region_origin_px(morg) + d0.get("pixel_offset", Vector2.ZERO)
			var gr := Rect2(anchor0 - EntityNode.anchor_off_of(gu, gsz0), gsz0)
			# 实例幽灵跟随目标层变换（新位置落回各自层）
			var eli: int = cvs._layer_index_of(str(d0.get("layer", "")))
			gr = _wrect_local(gr, eli)
			var gtex0: Texture2D = cvs.thumbs.get(gaid)
			if gtex0 != null:
				cvs.draw_texture_rect(gtex0, gr, false, Color(1, 1, 1, 0.6))
			else:
				cvs.draw_rect(gr, Color(0.6, 1.0, 0.6, 0.35), true)
		_draw_grid_region(morg, cvs._region_sel.size, move_li, Color(0.45, 1.0, 0.75, 0.9))
	# 区域粘贴预览：各层幽灵跟随鼠标，左键落位
	var world_paste: bool = cvs._paste_mode and cvs._region_clip.get("world", false)
	var show_paste: bool = cvs._paste_mode and not world_paste and not cvs._region_clip.is_empty() and cvs._region_ops_ctrl.region_clip_matches()
	if world_paste:
		cvs._world_region_move.draw_paste(pos)
	elif show_paste and cvs._region_clip.has("tile_rows"):
		_draw_layer_paste(pos)
	elif show_paste:
		var org: Vector2i = cvs.grid.region_origin(cvs._cell_of(pos), int(cvs._region_clip.get("parity", -1)))
		# 幽灵按**目标层**画，与真实粘贴同一套层重映射（同图按 id、跨图按唯一层名、
		# 匹配不上落最底层）——否则预览停在源层位置，落位后内容跳到别的层（V4 P1）。
		var lnames_g: Dictionary = cvs._region_clip.get("layer_names", {})
		var clip_map_g := str(cvs._region_clip.get("map", ""))
		var same_map_g: bool = clip_map_g == "" or clip_map_g == cvs.cur_map_name
		var missed_g: Array = []
		for lidg in (cvs._region_clip.get("tiles", {}) as Dictionary):
			var lig: int = cvs._region_ops_ctrl._paste_layer_index(str(lidg), lnames_g, missed_g, same_map_g)
			for t in ((cvs._region_clip.get("tiles", {}) as Dictionary)[lidg]) as Array:
				# 落点与真实粘贴同一原语（六边行错位/三角半格列）
				var tc = cvs.grid.cell_from_offset(org, Vector2i(int((t as Array)[0]), int((t as Array)[1])))
				# 按条目自己的资产 id 取纹理与切片尺寸（同上）
				var aid3 := str((t as Array)[2])
				var ai3: int = cvs.source_of_asset(aid3)
				var tex3: Texture2D = cvs.atlas_texs[ai3] \
					if ai3 >= 0 and ai3 < (cvs.atlas_texs as Array).size() else null
				_draw_tile_ghost(tex3, tc, cvs.asset_cell(aid3),
					Vector2i(int((t as Array)[3]), int((t as Array)[4])),
					int((t as Array)[5]) if (t as Array).size() >= 6 else 0, lig, 0.5)
		for t in cvs._region_clip.get("collision", []):
			var cc = cvs.grid.cell_from_offset(org, Vector2i(int(t[0]), int(t[1])))
			cvs.draw_colored_polygon(cvs.grid.cell_polygon(cc), Color(1.0, 0.25, 0.25, 0.35))
	# 实例幽灵：区域碎片里的实例也预览（按资产声明的实例尺寸，不只是 1 格）
		for t in cvs._region_clip.get("ents", []):
			var gaid2 := str(t.get("asset", ""))
			var gprops: Dictionary = t.get("props", {}) if t.get("props", {}) is Dictionary else {}
			var gsz: Vector2 = AssetDecl.instance_size(cvs.manifest, gaid2, gprops, Vector2(cvs.grid.tile))
			# dx/dy 是格坐标（浮点）：与落位后的 apply_grid 同一口径
			var eg: Vector2 = cvs.grid.cell_origin_continuous(org) + Vector2(float(t.get("dx", 0.0)), float(t.get("dy", 0.0)))
			var gu2 := EntityNode.anchor_unit_of(AssetDecl.by_id(cvs.manifest, gaid2))
			var anchor2: Vector2 = cvs.grid.to_px(eg + gu2)
			if cvs.grid.is_hex_geom():
				anchor2 = cvs.grid.region_origin_px(org) + t.get("pixel_offset", Vector2.ZERO)
			var er := Rect2(anchor2 - EntityNode.anchor_off_of(gu2, gsz), gsz)
			# 实例也画在它将要落进去的那一层（同一条重映射规则）
			var eli2: int = cvs._region_ops_ctrl._paste_layer_index(
				str(t.get("layer", "")), lnames_g, missed_g, same_map_g)
			er = _wrect_local(er, eli2)
			var tex: Texture2D = cvs.thumbs.get(gaid2)
			if tex == null:
				var ad2 := AssetDecl.by_id(cvs.manifest, gaid2)
				if str(ad2.get("shape", "")) == "image":
					tex = EntityNode.texture_of(cvs.manifest, str(ad2.get("texture", "")))
			if tex != null:
				cvs.draw_texture_rect(tex, er, false, Color(1, 1, 1, 0.55))
			else:
				cvs.draw_rect(er, Color(0.6, 1.0, 0.6, 0.4), true)
		var ppoly = cvs.grid.grid_polygon(org, org + Vector2i(cvs._region_clip.get("size", Vector2i.ONE)))
		cvs.draw_polyline(ppoly + PackedVector2Array([ppoly[0]]), Color(1.0, 0.85, 0.3, 0.9), 2.0, true)
	# E1 临时选点覆盖层（候选高亮 + 提示条）最后画：必须压在其它叠加之上
	_draw_pick_mode()

func _draw_grid_region(origin: Vector2i, size: Vector2i, li: int, color: Color) -> void:
	var frame: Transform2D = cvs.layer_xform(li)
	var poly: PackedVector2Array = frame * cvs.tile_grid_for_layer(li).grid_polygon(origin, origin + size)
	if not poly.is_empty():
		poly.append(poly[0])
		cvs.draw_polyline(poly, color, 2.0, true)

func _draw_layer_paste(pos: Vector2) -> void:
	var li: int = cvs.active_layer
	var grid: GridSpace = cvs.tile_grid_for_layer(li)
	var clip: Dictionary = cvs._region_clip
	var origin := grid.region_origin(cvs._active_cell(pos), int(clip.parity))
	for row in clip.tile_rows:
		var target := grid.cell_from_offset(origin, Vector2i(row[0], row[1]))
		var aid: String = row[2]
		var src: int = cvs.source_of_asset(aid)
		var tex: Texture2D = cvs.atlas_texs[src] if src >= 0 and src < cvs.atlas_texs.size() else null
		_draw_tile_ghost(tex, target, cvs.asset_cell(aid), Vector2i(row[3], row[4]), int(row[5]), li, 0.5)
	_draw_grid_region(origin, clip.size, li, Color(1.0, 0.85, 0.3, 0.9))

## 幽灵点集归一化：[[x,y],...] → Vector2 数组（R-02）
func _gpts_vec(raw: Array) -> Array:
	var out := []
	for pt in raw:
		if pt is Array and (pt as Array).size() >= 2:
			out.append(Vector2(float((pt as Array)[0]), float((pt as Array)[1])))
	return out

## 实例锚点/矩形 → 世界坐标（E02）：nodes 的 position/rect 在各自层局部空间，
## 画布自绘层没有层变换，所有叠加绘制先经过这里。位置取视觉锚点（扣掉 sortAnchor）。
func _w(n: EntityNode) -> Vector2:
	var li: int = cvs._layer_index_of(n.layer_id)
	var lp := n.position - n.sort_anchor()
	return lp if li < 0 else cvs.to_layer_world(li, lp)

func _wr(n: EntityNode) -> Rect2:
	var li: int = cvs._layer_index_of(n.layer_id)
	return n.aabb() if li < 0 else cvs.layer_xform(li) * n.aabb()

## 层局部位图落位矩形 → 世界矩形（区域预览瓦片）
func _wrect_local(r: Rect2, li: int) -> Rect2:
	if li < 0:
		return r
	var xf: Transform2D = cvs.layer_xform(li)
	return Rect2(xf * r.position, r.size * Vector2(xf.x.length(), xf.y.length()))

## 单格瓦片幽灵（笔刷/搬移/粘贴共用）：按**格形**贴图——三角与斜基走格多边形 + tri_uvs，
## 其余走矩形切片；最后按目标层变换变到世界。层有 offset/scale 时幽灵与落笔一致（V4 P1：
## 此前幽灵直接画在根空间，缩放层上跟手位置与落下的瓦片错开）。
func _draw_tile_ghost(tex: Texture2D, cell: Vector2i, cs: Vector2i, atl: Vector2i, alt: int,
		li: int, alpha: float) -> void:
	if tex == null or cs == Vector2i.ZERO:
		return
	var tint := Color(1, 1, 1, alpha)
	var tile_grid: GridSpace = cvs.tile_grid_for_layer(li)
	if tile_grid.is_tri() or tile_grid.has_basis:
		var poly: PackedVector2Array = tile_grid.cell_polygon(cell)
		var pts := PackedVector2Array()
		for p: Vector2 in poly:
			pts.append(p if li < 0 else cvs.to_layer_world(li, p))
		var uvs: PackedVector2Array = TriTileViewScript.tri_uvs(pts, atl, cs, tex.get_size(), alt)
		if uvs.size() == pts.size():
			var cols := PackedColorArray()
			for _i in pts.size():
				cols.append(tint)
			cvs.draw_polygon(pts, cols, uvs, tex)
		return
	cvs.draw_texture_rect_region(tex, _wrect_local(tile_grid.cell_tex_rect(cell, cs), li),
		Rect2(Vector2(atl) * Vector2(cs), Vector2(cs)), tint)

## visual:rect 资产的画布呈现：颜色/alpha 读资产声明，尺寸走实例 rect()。
## 不含 props.event/mode/once 分支——事件就是绑定了功能的实体，语义只在 functions[] 里。
func _draw_visual_rects(nodes: Array) -> void:
	for node in nodes:
		var n := node as EntityNode
		if n == null or not is_instance_valid(n):
			continue
		var vis: Dictionary = (n.decl.get("visual", {}) as Dictionary) if n.decl.get("visual", null) is Dictionary else {}
		var col := Color(str(vis.get("color", "#4fc3f7")))
		var alpha := float(vis.get("alpha", 0.35))
		var rect := n.rect()
		cvs.draw_rect(rect, Color(col, alpha), true)
		cvs.draw_rect(rect, Color(col, minf(1.0, alpha + 0.5)), false, 1.5)

func _draw_link_handles() -> void:
	if cvs.gesture == cvs.Gesture.LINK_DRAG:
		var pos: Vector2 = cvs.get_global_mouse_position()
		var hot: String = cvs._link_hover
		cvs.draw_line(cvs._link_origin, pos, Color.AQUAMARINE, 2.0, true)
		if cvs._link_fd.get("type") == "port_ref":
			_draw_port_markers(cvs._link_fd_types, hot)
		else:
			var node := cvs._ent_by_code_index().get(hot) as EntityNode
			if is_instance_valid(node):
				cvs.draw_rect(_wr(node).grow(3.0), Color.AQUAMARINE, false, 2.0)
		return
	var handles: Array = cvs._link_handles()
	var side := maxf(cvs.grid.cell_max() * 0.28, 5.0)
	for h in handles:
		var fd: Dictionary = h.fd
		var is_port: bool = fd.get("type") == "port_ref"
		var col := Color.GOLD if is_port else Color.AQUAMARINE
		if h.has_target:
			cvs.draw_line(h.from, h.at, col, 1.5, true)
			if is_port:
				cvs.draw_circle(h.at, 4.0 / maxf(cvs.zoom, 0.01), col)
		if is_port or not h.has_target:
			cvs.draw_line(h.from, h.handle, Color(col, 0.55), 1.2, true)
		cvs.draw_rect(Rect2(h.handle - Vector2.ONE * side * 0.5, Vector2.ONE * side), col)
		if is_port or handles.size() > 1:
			cvs.draw_string(ThemeDB.fallback_font, h.handle + Vector2(side, -side),
				str(fd.get("name", fd.id)), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)

func _draw_port_markers(types: Array, hover: String, selected := "") -> void:
	var radius: float = 5.0 / maxf(cvs.zoom, 0.01)
	for marker in cvs.port_markers(types):
		var chosen: bool = marker.value == selected
		var hot: bool = marker.value == hover
		var col := Color.AQUAMARINE if chosen or hot else Color(0.85, 0.75, 0.3, 0.8)
		cvs.draw_circle(marker.pos, radius * (1.6 if chosen or hot else 1.0), col)
		if chosen or hot:
			cvs.draw_string(ThemeDB.fallback_font, marker.pos + Vector2(radius * 2, 0),
				marker.label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)

## E1 临时选点覆盖层：候选实例高亮 + 顶部提示条（提示条用屏幕坐标，画在最上层）。
## 已点中的候选实线粗框，悬停预览虚线细框——两者可同时存在（悬停下一个看效果）。
## C4：accept == "cell" 时高亮的是有限格图的多边形，不是实例框。
func _draw_pick_mode() -> void:
	if not cvs.pick_mode_active:
		return
	var hover: String = str(cvs.pick_mode_hover)
	if cvs.pick_mode_accept == "cell":
		_draw_pick_cells(hover)
	elif cvs.pick_mode_accept == "edge":
		_draw_pick_edges(hover)
	elif cvs.pick_mode_accept == "port":
		_draw_port_markers(cvs.pick_mode_types, hover, cvs.pick_mode_code)
	elif hover != "" and hover != str(cvs.pick_mode_code):
		var hn = cvs._ent_by_code_index().get(hover, null)
		if hn != null and is_instance_valid(hn):
			cvs.draw_rect(_wr(hn as EntityNode).grow(2.0), Color(0.55, 0.95, 1.0, 0.55), false, 1.0)
	if cvs.pick_mode_accept not in ["cell", "edge", "port"] and cvs.pick_mode_code != "":
		var hs = cvs._ent_by_code_index().get(cvs.pick_mode_code, null)
		if hs != null and is_instance_valid(hs):
			var r: Rect2 = _wr(hs as EntityNode).grow(4.0)
			cvs.draw_rect(r, Color(0.2, 1.0, 0.9, 0.15), true)
			cvs.draw_rect(r, Color(0.2, 1.0, 0.9, 0.95), false, 2.5)
	# 提示条贴在视口左上：把屏幕坐标换算回画布坐标（画布在 SubViewport 里，
	# 相机变换作用于世界层；自绘层的文本直接用 canvas_transform 的逆）
	var vp: Viewport = cvs.get_viewport()
	var at := Vector2(12, 12)
	if vp != null:
		at = vp.get_canvas_transform().affine_inverse() * at
	var text: String = cvs.pick_mode_hint
	if cvs.pick_mode_code != "":
		var shown: String = cvs.pick_mode_code
		if cvs.pick_mode_accept == "edge":
			shown = str(EdgeRefRef.edge_of(JSON.parse_string(cvs.pick_mode_code)))
		if cvs.pick_mode_accept == "port":
			var port = JSON.parse_string(shown)
			if port is Dictionary:
				shown = "%s · %s" % [port.inst, port.port]
		text += "　已点：%s（左键可换，Enter/确认提交）" % shown
	elif cvs.pick_mode_accept == "port":
		text += "　左键点端口，Esc 取消"
	elif cvs.pick_mode_accept == "cell":
		text += "　左键点格图里的格子，Esc 取消"
	elif cvs.pick_mode_accept == "edge":
		text += "　左键点格边（靠近两格分界），Esc 取消"
	else:
		text += "　左键点实例，Esc 取消"
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var box := Rect2(at - Vector2(6, 4), Vector2(w + 12, 22))
	cvs.draw_rect(box, Color(0.06, 0.1, 0.14, 0.92), true)
	cvs.draw_rect(box, Color(0.2, 1.0, 0.9, 0.8), false, 1.0)
	cvs.draw_string(font, at + Vector2(0, 12), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		Color(0.75, 1.0, 0.95, 0.95))

## C4：格图选点的多边形高亮（根空间多边形 → 世界坐标）。悬停细框、已选粗框填充。
func _draw_pick_cells(hover: String) -> void:
	if hover != "" and hover != str(cvs.pick_mode_code):
		_draw_cell_poly(hover, Color(0.55, 0.95, 1.0, 0.55), false, 1.0)
	if str(cvs.pick_mode_code) != "":
		_draw_cell_poly(str(cvs.pick_mode_code), Color(0.2, 1.0, 0.9, 0.95), true, 2.5)

func _draw_cell_poly(id: String, col: Color, fill: bool, width: float) -> void:
	var world: PackedVector2Array = cvs.cell_polygon_world(id)
	if world.size() < 3:
		return
	if fill:
		cvs.draw_colored_polygon(world, Color(col.r, col.g, col.b, 0.15))
	world.append(world[0])
	cvs.draw_polyline(world, col, width)

## §7.4：格边选点高亮（边 ID → 两格中心连线，画成世界空间短线）。
## 悬停青色细线，已选粗线 + 两端点方块，便于看清到底指的是哪条分界。
func _draw_pick_edges(hover: String) -> void:
	if hover != "" and hover != str(cvs.pick_mode_code):
		_draw_edge_line(hover, Color(0.55, 0.95, 1.0, 0.75), 1.5, false)
	if str(cvs.pick_mode_code) != "":
		_draw_edge_line(str(cvs.pick_mode_code), Color(0.2, 1.0, 0.9, 0.95), 3.0, true)

func _draw_edge_line(json_or_id: String, col: Color, width: float, marks: bool) -> void:
	# 值是 {map, cell, edge} 的 JSON 串（选点候选编码）；也接受裸边 ID（保守兜底）
	var e := json_or_id
	if json_or_id.begins_with("{"):
		e = str(EdgeRefRef.edge_of(JSON.parse_string(json_or_id)))
	var seg: PackedVector2Array = cvs.edge_segment_world(e)
	if seg.size() != 2:
		return
	cvs.draw_line(seg[0], seg[1], col, width, true)
	if not marks:
		return
	var side := maxf(cvs.grid.cell_max() * 0.22, 4.0)
	for p in seg:
		var r := Rect2(p - Vector2.ONE * side * 0.5, Vector2.ONE * side)
		cvs.draw_rect(r, Color(col, 0.9), true)

