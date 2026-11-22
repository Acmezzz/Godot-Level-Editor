extends RefCounted
## _canvas_draw_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。

var cvs   # 宿主引用

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const ManifestScript := preload("res://src/project/manifest.gd")   # 出口 role 判定
const MapStoreRef := preload("res://src/map/map_store.gd")   # 地图码→名解析（出口角标）
const K := preload("res://src/core/constants.gd")

func _init(host) -> void:
	cvs = host
func _draw() -> void:
	if not cvs.is_map_ready():
		return
	var pos = cvs.get_global_mouse_position()
	var c = cvs._cell_of(pos)
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
		
	# 幽灵预览：只看「手上拿着什么」，没有工具要判断
	var on_ent: bool = cvs.place_kind == "object"
	if cvs.grid.map_bounds(map_rect).has_point(pos):
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
				var gp = cvs.grid.cell_polygon(c)
				cvs.draw_polyline(gp + PackedVector2Array([gp[0]]), Color(0.55, 0.85, 1.0, 0.5), 1.0, true)
		else:
			# 瓦片 / 碰撞层：笔刷范围轮廓 + 中心格瓦片幽灵（碰撞层不画瓦片图，只画范围）
			var bcell := Vector2i(c.x - cvs.brush_size / 2, c.y - cvs.brush_size / 2)
			var bpoly = cvs.grid.grid_polygon(bcell, bcell + Vector2i(cvs.brush_size, cvs.brush_size))
			var tint := Color(1.0, 0.45, 0.45, 0.55) if cvs._is_grid_layer(cvs.active_layer) else Color(1, 1, 1, 0.5)
			cvs.draw_polyline(bpoly + PackedVector2Array([bpoly[0]]), tint, 1.0, true)
			# 无图集（headless 测试/清单缺图）时不画幽灵，避免 draw_texture_rect_region 空纹理警告
			if not cvs._is_grid_layer(cvs.active_layer):
				# 笔刷幽灵跟 paint_asset 走（多图集项目不再画成 0 号图集的错图）
				var bsrc: int = cvs.source_of_asset(cvs.paint_asset)
				var gtex: Texture2D = cvs.atlas_texs[bsrc] \
					if bsrc >= 0 and bsrc < (cvs.atlas_texs as Array).size() else null
				if gtex != null:
					var cs: Vector2i = cvs.asset_cell(cvs.paint_asset)
					cvs.draw_texture_rect_region(gtex,
						cvs.grid.cell_tex_rect(c, cs),
						Rect2(Vector2(cvs.paint_cell) * Vector2(cs), Vector2(cs)),
						Color(1, 1, 1, 0.5))
	# 碰撞叠加由 CollisionView 节点绘制（图层接口控制显隐），这里不再特例绘制。
	# 地图边界（meta w×h，关卡的实际范围）
	var meta: Dictionary = cvs.map_data.get("meta", {})
	var bpoly = cvs.grid.grid_polygon(Vector2i.ZERO,
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
	var spawn_draggable: bool = cvs.place_kind == "object"
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
		var tmap := str(props.get("target_map", "")) \
			if ManifestScript.has_role(cvs.manifest, sid, "exit") else ""
		if tmap == "":
			var ad0 := AssetDecl.by_id(cvs.manifest, sid)
			for fd in (ad0.get("fields", []) as Array):
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
		if ManifestScript.has_role(cvs.manifest, sid, "landing"):
			landings.append(n)
		# 实例实际占位（清单 editorSize 或 prefab 碰撞尺寸）：青色实框
		boxes.append(_wr(n))
		# 无贴图的 visual:rect 资产（内置事件区等）：按声明画彩色矩形，不再认 props.event/mode/once。
		var vis = AssetDecl.by_id(cvs.manifest, sid).get("visual", null)
		if n.texture == null and vis is Dictionary and str((vis as Dictionary).get("mode", "")) == "rect":
			zones.append(n)
	if not exits.is_empty():
		var fnt: Font = ThemeDB.fallback_font   # Node2D 无 Control 主题接口，用引擎兜底字体
		if fnt != null:
			# 值 = 地图码（v7）：显示时码→名解析一次（code_map 带缓存）；老数据存名兜底原样显示
			var cm: Dictionary = MapStoreRef.code_map(cvs.manifest)
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
			var vside := maxf(cvs.grid.cell_max() * 0.3, 6.0)
			for wp: Vector2 in cvs._vertex_worlds(sn as EntityNode):
				cvs.draw_rect(Rect2(wp - Vector2.ONE * vside * 0.5, Vector2.ONE * vside), Color(0.85, 0.4, 1.0, 0.9), true)
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
	# 区域选区轮廓（框选的结果——开关或 Ctrl+拖动，可跨层）。
	# 选区是 root 空间格号，轮廓画在 root 空间（层偏移不影响框选口径，E02）。
	if cvs._region_sel.size.x > 0:
		var rpoly = cvs.grid.grid_polygon(cvs._region_sel.position, cvs._region_sel.end)
		cvs.draw_polyline(rpoly + PackedVector2Array([rpoly[0]]), Color(1.0, 0.85, 0.3, 0.8), 2.0, true)
	# 区域拖动预览：整块幽灵按当前格偏移跟手，松手才真搬。
	# 每层瓦片在自己的层局部格里，预览按层变换到世界（E02）。
	if cvs._move_active and not cvs._move_snap.is_empty():
		var md: Vector2i = cvs._move_cell_delta
		# tiles = {层id: [[x,y,资产id,ax,ay]...]}——按条目所属层变换到世界
		for lid2 in (cvs._move_snap.get("tiles", {}) as Dictionary):
			var lli2: int = cvs._layer_index_of(str(lid2))
			for t in (cvs._move_snap.get("tiles", {}) as Dictionary)[lid2]:
				# 按条目自己的资产 id 取纹理与切片尺寸（预览与真实落笔一致）
				var aid2 := str((t as Array)[2])
				var ai2: int = cvs.source_of_asset(aid2)
				var tex2: Texture2D = cvs.atlas_texs[ai2] \
					if ai2 >= 0 and ai2 < (cvs.atlas_texs as Array).size() else null
				if tex2 != null:
					var cs2: Vector2i = cvs.asset_cell(aid2)
					var dst2: Rect2 = cvs.grid.cell_tex_rect(
						Vector2i(int((t as Array)[0]), int((t as Array)[1])) + md, cs2)
					cvs.draw_texture_rect_region(tex2, _wrect_local(dst2, lli2),
						Rect2(Vector2(int((t as Array)[3]), int((t as Array)[4])) * Vector2(cs2), Vector2(cs2)),
						Color(1, 1, 1, 0.6))
		for t in cvs._move_snap.get("collision", []):
			var mc: Vector2i = Vector2i(int(t[0]), int(t[1])) + md
			cvs.draw_colored_polygon(cvs.grid.cell_polygon(mc), Color(1.0, 0.25, 0.25, 0.45))
		for e0 in cvs._move_snap.get("ents", []):
			# 快照条目 {dx,dy,asset,...}：按区域原点 + 偏移画（快照只存数据，不存节点）
			var d0: Dictionary = e0
			var gaid := str(d0.get("asset", ""))
			var gprops0: Dictionary = d0.get("props", {}) if d0.get("props", {}) is Dictionary else {}
			var gsz0: Vector2 = AssetDecl.instance_size(cvs.manifest, gaid, gprops0, Vector2(cvs.grid.tile))
			var ep: Vector2 = Vector2(cvs._region_sel.position + md) \
				+ Vector2(float(d0.get("dx", 0.0)), float(d0.get("dy", 0.0)))
			var gu := EntityNode.anchor_unit_of(AssetDecl.by_id(cvs.manifest, gaid))
			var gr := Rect2(cvs.grid.to_px(ep + gu) - EntityNode.anchor_off_of(gu, gsz0), gsz0)
			# 实例幽灵跟随目标层变换（新位置落回各自层）
			var eli: int = cvs._layer_index_of(str(d0.get("layer", "")))
			gr = _wrect_local(gr, eli)
			var gtex0: Texture2D = cvs.thumbs.get(gaid)
			if gtex0 != null:
				cvs.draw_texture_rect(gtex0, gr, false, Color(1, 1, 1, 0.6))
			else:
				cvs.draw_rect(gr, Color(0.6, 1.0, 0.6, 0.35), true)
		var mpoly = cvs.grid.grid_polygon(cvs._region_sel.position + md, cvs._region_sel.end + md)
		cvs.draw_polyline(mpoly + PackedVector2Array([mpoly[0]]), Color(0.45, 1.0, 0.75, 0.9), 2.0, true)
	# 区域粘贴预览：各层幽灵跟随鼠标，左键落位
	if cvs._paste_mode and not cvs._region_clip.is_empty():
		var org = cvs._cell_of(pos)
		# tiles = {层id: [[dx,dy,资产id,ax,ay]...]}——预览不区分层，统一原色
		for cells2 in (cvs._region_clip.get("tiles", {}) as Dictionary).values():
			for t in cells2:
				var tc = org + Vector2i(int((t as Array)[0]), int((t as Array)[1]))
				# 按条目自己的资产 id 取纹理与切片尺寸（同上）
				var aid3 := str((t as Array)[2])
				var ai3: int = cvs.source_of_asset(aid3)
				var tex3: Texture2D = cvs.atlas_texs[ai3] \
					if ai3 >= 0 and ai3 < (cvs.atlas_texs as Array).size() else null
				if tex3 != null:
					var cs3: Vector2i = cvs.asset_cell(aid3)
					cvs.draw_texture_rect_region(tex3,
						cvs.grid.cell_tex_rect(tc, cs3),
						Rect2(Vector2(int((t as Array)[3]), int((t as Array)[4])) * Vector2(cs3), Vector2(cs3)),
						Color(1, 1, 1, 0.5))
		for t in cvs._region_clip.get("collision", []):
			var cc = org + Vector2i(t[0], t[1])
			cvs.draw_colored_polygon(cvs.grid.cell_polygon(cc), Color(1.0, 0.25, 0.25, 0.35))
	# 实例幽灵：区域碎片里的实例也预览（按资产声明的实例尺寸，不只是 1 格）
		for t in cvs._region_clip.get("ents", []):
			var gaid2 := str(t.get("asset", ""))
			var gprops: Dictionary = t.get("props", {}) if t.get("props", {}) is Dictionary else {}
			var gsz: Vector2 = AssetDecl.instance_size(cvs.manifest, gaid2, gprops, Vector2(cvs.grid.tile))
			# dx/dy 是格坐标（浮点）：与落位后的 apply_grid 同一口径
			var eg: Vector2 = Vector2(org) + Vector2(float(t.get("dx", 0.0)), float(t.get("dy", 0.0)))
			var gu2 := EntityNode.anchor_unit_of(AssetDecl.by_id(cvs.manifest, gaid2))
			var er := Rect2(cvs.grid.to_px(eg + gu2) - EntityNode.anchor_off_of(gu2, gsz), gsz)
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

## 层局部矩形/多边形 → 世界（区域轮廓/预览共用）
func _lpoly_rect(r: Rect2i, li: int) -> PackedVector2Array:
	var poly: PackedVector2Array = cvs.grid.grid_polygon(r.position, r.end)
	if li < 0:
		return poly
	var xf: Transform2D = cvs.layer_xform(li)
	var out := PackedVector2Array()
	for p: Vector2 in poly:
		out.append(xf * p)
	return out

## 层局部位图落位矩形 → 世界矩形（区域预览瓦片）
func _wrect_local(r: Rect2, li: int) -> Rect2:
	if li < 0:
		return r
	var xf: Transform2D = cvs.layer_xform(li)
	return Rect2(xf * r.position, r.size * Vector2(xf.x.length(), xf.y.length()))

## visual:rect 资产的画布呈现：颜色/alpha 读资产声明，尺寸走实例 rect()。
## 不含 props.event/mode/once 分支——事件就是绑定了功能的实体，语义只在 functions[] 里。
func _draw_visual_rects(nodes: Array) -> void:
	for node in nodes:
		var n := node as EntityNode
		if n == null or not is_instance_valid(n):
			continue
		var vis: Dictionary = AssetDecl.by_id(cvs.manifest, n.asset).get("visual", {})
		var col := Color(str(vis.get("color", "#4fc3f7")))
		var alpha := float(vis.get("alpha", 0.35))
		var rect := n.rect()
		cvs.draw_rect(rect, Color(col, alpha), true)
		cvs.draw_rect(rect, Color(col, minf(1.0, alpha + 0.5)), false, 1.5)

## E2 连线把手：每条本图引用一条线（源锚点 → 落点），源端与落点各一个方块把手。
## 拖动中：线跟手、光标下的候选实例高亮。把手画在世界空间（层变换已作用）。
func _draw_link_handles() -> void:
	var handles: Array = cvs._link_handles()
	var pos: Vector2 = cvs.get_global_mouse_position()
	if cvs.gesture == cvs.Gesture.LINK_DRAG:
		# 拖动中：从源锚点画到光标；候选实例青框预览落点
		var src: Vector2 = Vector2.ZERO
		for h in handles:
			var hd: Dictionary = h
			if hd.get("fd", {}) == cvs._link_fd:
				src = hd.get("from", Vector2.ZERO)
				break
		cvs.draw_line(src, pos, Color(0.2, 1.0, 0.9, 0.85), 2.0, true)
		var hov = cvs._ent_by_code_index().get(str(cvs._link_hover), null)
		if hov != null and is_instance_valid(hov):
			cvs.draw_rect(_wr(hov as EntityNode).grow(3.0), Color(0.2, 1.0, 0.9, 0.9), false, 2.0)
		var hs := maxf(cvs.grid.cell_max() * 0.32, 6.0)
		cvs.draw_rect(Rect2(pos - Vector2.ONE * hs * 0.5, Vector2.ONE * hs), Color(0.2, 1.0, 0.9, 0.95), true)
		return
	if handles.is_empty():
		return
	var side := maxf(cvs.grid.cell_max() * 0.28, 5.0)
	var stub: Vector2 = Vector2(maxf(cvs.grid.cell_max() * 0.56, 10.0), -maxf(cvs.grid.cell_max() * 0.56, 10.0))
	for h in handles:
		var hd2: Dictionary = h
		var from: Vector2 = hd2.get("from", Vector2.ZERO)
		var at: Vector2 = hd2.get("at", from)
		var has_t: bool = bool(hd2.get("has_target", false))
		# 有落点 = 实线青；空引用 = 一条斜向短线（把手在线段末端，不压锚点）
		var col := Color(0.2, 1.0, 0.9, 0.9) if has_t else Color(0.2, 1.0, 0.9, 0.55)
		if has_t:
			cvs.draw_line(from, at, col, 1.5, true)
		else:
			cvs.draw_line(from, from + stub, col, 1.2, true)
		# 端点把手：方形（区别于顶点的实心方块略小）
		cvs.draw_rect(Rect2(at - Vector2.ONE * side * 0.5, Vector2.ONE * side), Color(0.2, 1.0, 0.9, 0.95), true)
		# 名字角标：字段名（多个引用字段时才需要区分）
		if handles.size() > 1:
			var fname := str((hd2.get("fd", {}) as Dictionary).get("name", ""))
			if fname != "":
				cvs.draw_string(ThemeDB.fallback_font, at + Vector2(side, -side),
					fname, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)

## E1 临时选点覆盖层：候选实例高亮 + 顶部提示条（提示条用屏幕坐标，画在最上层）。
## 已点中的候选实线粗框，悬停预览虚线细框——两者可同时存在（悬停下一个看效果）。
func _draw_pick_mode() -> void:
	if not cvs.pick_mode_active:
		return
	var hover: String = str(cvs.pick_mode_hover)
	if hover != "" and hover != str(cvs.pick_mode_code):
		var hn = cvs._ent_by_code_index().get(hover, null)
		if hn != null and is_instance_valid(hn):
			cvs.draw_rect(_wr(hn as EntityNode).grow(2.0), Color(0.55, 0.95, 1.0, 0.55), false, 1.0)
	if cvs.pick_mode_code != "":
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
		text += "　已点：%s（左键可换，Enter/确认提交）" % cvs.pick_mode_code
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

