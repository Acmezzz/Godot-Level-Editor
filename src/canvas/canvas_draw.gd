extends RefCounted
## _canvas_draw_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 alias 引用。

var cvs   # 宿主引用

const BuiltinKinds := preload("res://src/content/builtin_kinds.gd")
const ManifestScript := preload("res://src/manifest.gd")   # K10：出口 role 判定
const K := preload("res://src/core/constants.gd")

func _init(host) -> void:
	cvs = host
func _draw() -> void:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
		return
	var pos = cvs.get_global_mouse_position()
	var c = cvs._cell_of(pos)
	# 网格覆盖整个地图边界（meta w×h），碰撞/实体放在地形外也有网格
	var meta0: Dictionary = cvs.map_data.get("meta", {})
	var map_rect := Rect2i(0, 0, int(meta0.get("w", K.DEFAULT_MAP_W)), int(meta0.get("h", K.DEFAULT_MAP_H)))
	if cvs.show_grid:
		var origin = Vector2(map_rect.position) * cvs.tile_px
		var endv = Vector2(map_rect.end) * cvs.tile_px
 # 网格按可视区间裁剪——120×56 满图每帧 176 条抗锯齿线，鼠标一动就全付。
 # 可见世界矩形由 canvas_transform 反变换得到（headless 无视口时退回整图）。
		var vis := Rect2(origin, endv - origin)
		var vp: Viewport = cvs.get_viewport()
		if vp != null:
			vis = vp.get_canvas_transform().affine_inverse() * Rect2(Vector2.ZERO, vp.get_visible_rect().size)
		var x0 := maxf(origin.x, floorf(vis.position.x / cvs.tile_px) * cvs.tile_px)
		var x1 := minf(endv.x, ceilf(vis.end.x / cvs.tile_px) * cvs.tile_px)
		var y0 := maxf(origin.y, floorf(vis.position.y / cvs.tile_px) * cvs.tile_px)
		var y1 := minf(endv.y, ceilf(vis.end.y / cvs.tile_px) * cvs.tile_px)
		var gx := x0
		while gx <= x1:
			cvs.draw_line(Vector2(gx, maxf(y0, origin.y)), Vector2(gx, minf(y1, endv.y)), Color(1, 1, 1, 0.07), 1.0, true)
			gx += cvs.tile_px
		var gy := y0
		while gy <= y1:
			cvs.draw_line(Vector2(maxf(x0, origin.x), gy), Vector2(minf(x1, endv.x), gy), Color(1, 1, 1, 0.07), 1.0, true)
			gy += cvs.tile_px
	# 幽灵预览：只看「当前层 + 手上拿着什么」，没有工具要判断
	var on_ent_layer: bool = cvs.active_layer == cvs._ent_layer_index()
	if Rect2(Vector2(map_rect.position) * cvs.tile_px, Vector2(map_rect.size) * cvs.tile_px).has_point(pos):
		if on_ent_layer:
 # 实体层：手上拿着资产就画它的幽灵，否则画「点这里会选中」的提示框
			if cvs.stamp_thumb:
 # 幽灵按实体的真实占位尺寸画，和落下去之后一样大，便于对位
				var dsz = cvs.entity_display_size(cvs.stamp_scene)
				var gts = cvs.stamp_thumb.get_size()
				var k := minf(dsz.x / maxf(gts.x, 1.0), dsz.y / maxf(gts.y, 1.0))
				var center = Vector2(c) * cvs.tile_px + Vector2(cvs.tile_px, cvs.tile_px) * 0.5
				cvs.draw_texture_rect(cvs.stamp_thumb, Rect2(center - gts * k * 0.5, gts * k),
					false, Color(1, 1, 1, 0.5))
 # 占位框：告诉用户这个实体在游戏里占多大
				cvs.draw_rect(Rect2(center - dsz * 0.5, dsz), Color(0.35, 0.95, 0.95, 0.6), false, 1.0)
			elif cvs.BuiltinKinds.is_builtin(cvs.stamp_scene):
 # 内置种类没有贴图：按落下后的默认 2×2 画矩形幽灵，否则光标处什么都看不到
				var gsz := Vector2(cvs.tile_px * 2, cvs.tile_px * 2)
				cvs.draw_rect(Rect2(Vector2(c) * cvs.tile_px, gsz), Color(0.55, 0.85, 1.0, 0.35), true)
				cvs.draw_rect(Rect2(Vector2(c) * cvs.tile_px, gsz), Color(0.55, 0.85, 1.0, 0.8), false, 1.5)
			else:
				cvs.draw_rect(Rect2(Vector2(c) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)),
					Color(0.55, 0.85, 1.0, 0.5), false, 1.0)
		else:
 # 瓦片 / 碰撞层：笔刷范围轮廓 + 中心格瓦片幽灵（碰撞层不画瓦片图，只画范围）
			var tsz := float(cvs.tile_px)
			var brect := _brush_rect(c)
			var tint := Color(1.0, 0.45, 0.45, 0.55) if cvs._is_grid_layer(cvs.active_layer) else Color(1, 1, 1, 0.5)
			cvs.draw_rect(brect, tint, false, 1.0)
 # 无图集（headless 测试/清单缺图）时不画幽灵，避免 draw_texture_rect_region 空纹理警告
			if cvs.atlas_tex != null and not cvs._is_grid_layer(cvs.active_layer):
				cvs.draw_texture_rect_region(cvs.atlas_tex,
					Rect2(Vector2(c) * cvs.tile_px, Vector2(tsz, tsz)),
					Rect2(Vector2(cvs.paint_cell) * cvs.tile_px, Vector2(tsz, tsz)),
					Color(1, 1, 1, 0.5))
	# 碰撞叠加由 CollisionView 节点绘制（图层接口控制显隐），这里不再特例绘制。
	# 地图边界（meta w×h，关卡的实际范围）
	var meta: Dictionary = cvs.map_data.get("meta", {})
	var bounds := Rect2(Vector2.ZERO, Vector2(
		int(meta.get("w", K.DEFAULT_MAP_W)) * cvs.tile_px,
		int(meta.get("h", K.DEFAULT_MAP_H)) * cvs.tile_px))
	cvs.draw_rect(bounds, Color(1, 1, 1, 0.35), false, 2.0)
	# 游玩视野预览（跟随鼠标）：鼠标在哪 = 假设玩家在那，屏幕里能看到什么
	var ss: Array = cvs.manifest.get("screenSize", [640, 360])
	var view_here := Rect2(pos - Vector2(ss[0], ss[1]) * 0.5, Vector2(ss[0], ss[1]))
	cvs.draw_rect(view_here, Color(0.35, 0.65, 1.0, 0.20), false, 1.0)
	# 出生点开局视野（稍实一些）+ 显式出生标记（绿框 + 十字准星）
	var spos = cvs.spawn.position
	var screen_rect := Rect2(spos - Vector2(ss[0], ss[1]) * 0.5, Vector2(ss[0], ss[1]))
	cvs.draw_rect(screen_rect, Color(0.35, 0.65, 1.0, 0.40), false, 1.0)
	# 出生点标记：只在实体层画成「可拖」的样子，其余层画淡一些——避免在地形层误导成可点
	var spawn_draggable: bool = cvs.active_layer == cvs._ent_layer_index()
	var half = cvs.tile_px * 0.5
	var srect := Rect2(spos - Vector2(half, half), Vector2(cvs.tile_px, cvs.tile_px))
	var spawn_col := Color(0.3, 1.0, 0.5, 0.9) if spawn_draggable else Color(0.3, 1.0, 0.5, 0.35)
	cvs.draw_rect(srect, spawn_col, false, 2.0)
	cvs.draw_line(Vector2(spos.x - 6, spos.y), Vector2(spos.x + 6, spos.y), spawn_col, 2.0)
	cvs.draw_line(Vector2(spos.x, spos.y - 6), Vector2(spos.x, spos.y + 6), spawn_col, 2.0)
	# 传送门等引用连线：props.target_entity 指向同图另一实例（黄线）
	# 先建 {ent_id: spr} 索引——O(n²) 双重遍历改为 O(n)
	var by_id = cvs._ent_by_id_index()   # D5：脏标记缓存
	# 实体层再叠加「出口角标 / 落点描边 / 占位框 / 触发区」——原先各扫一遍 entities，
	# 鼠标每动一像素就付 5 次 O(n)。现在一次遍历按类别收集，再分段绘制。
	var exits: Array = []
	var landings: Array = []
	var boxes: Array = []
	var zones: Array = []
	for e in cvs.entities.get_children():
		var spr := e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		var sid := str(spr.get_meta("scene", ""))
		var props: Dictionary = spr.get_meta("props", {}) if spr.get_meta("props", {}) is Dictionary else {}
 # 同图引用连线
		var tid := str(props.get("target_point", ""))
		if tid != "":
			var spr2 = by_id.get(tid, null)
			if spr2 and spr2 != spr:
				var wobble := str(props.get("target_map", "")) != ""
				var col := Color(0.4, 0.4, 1.0, 0.6) if wobble else Color(1.0, 0.85, 0.3, 0.6)
				cvs.draw_line(spr.position, spr2.position, col, 1.5)
 # 跨图出口「已接好」角标——有 target_map 的 exit 画 ↗+目标图名
		if ManifestScript.has_role(cvs.manifest, sid, "exit"):
			var tmap := str(props.get("target_map", ""))
			if tmap != "":
				exits.append([spr.position, tmap])
 # 传送落点（青色描边）与出生 marker（绿十字）拉开色系
		if ManifestScript.has_role(cvs.manifest, sid, "landing"):
			landings.append(spr)
 # 实体实际占位（清单 editorSize 或 prefab 碰撞尺寸）：青色实框
		var sz = cvs._size_of(sid)
		if sz != Vector2.ZERO:
			boxes.append([spr.position, sz])
 # 触发区：没有贴图，用半透明矩形 + 事件名标签表示
		if BuiltinKinds.is_builtin(sid):
			zones.append(spr)
	if not exits.is_empty():
		var fnt: Font = ThemeDB.fallback_font   # K10：Node2D 无 Control 主题接口，用引擎兜底字体
		if fnt != null:
			for it in exits:
				cvs.draw_string(fnt, it[0] + Vector2(-10, -12), "↗" + str(it[1]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.35, 0.9, 1.0, 0.9))
	for lp in landings:
		var lsz: Vector2 = cvs.entity_display_size_of(lp)
		cvs.draw_rect(Rect2(lp.position - lsz * 0.5, lsz), Color(0.35, 0.9, 1.0, 0.45), false, 1.5)
	# 选中实体高亮
	if cvs.selected_entity and is_instance_valid(cvs.selected_entity):
		var sr := Rect2(cvs.selected_entity.position - Vector2(cvs.tile_px, cvs.tile_px) * 0.75, Vector2(cvs.tile_px, cvs.tile_px) * 1.5)
		cvs.draw_rect(sr, Color(1.0, 0.85, 0.3, 0.9), false, 2.0)
	# 框选拖拽矩形（Ctrl+拖动，实体层或瓦片层都画同一个框）
	if cvs._drag_box:
		var br := Rect2(cvs._drag_start.min(pos), (cvs._drag_start - pos).abs())
		cvs.draw_rect(br, Color(1.0, 0.85, 0.3, 0.15), true)
		cvs.draw_rect(br, Color(1.0, 0.85, 0.3, 0.8), false, 1.5)
	# 框选集合高亮（小黄框）
	for s in cvs.selected_multi:
		if is_instance_valid(s):
			var sz = cvs.entity_display_size_of(s)
			var mr: Rect2 = Rect2((s as Sprite2D).position - sz * 0.5, sz).grow(maxf(cvs.tile_px * 0.25, 2.0))
			cvs.draw_rect(mr, Color(1.0, 0.85, 0.3, 0.85), false, 1.5)
	# 多选集合的外接框：明确标出「这一块可以整体拖动」。
	# 框内空白处按下就能拖，鼠标悬停在框内时加亮，给出可操作性暗示。
	var multi = cvs._valid_multi()
	if multi.size() > 1 and cvs._ent_layer_index() == cvs.active_layer:
		var mb = cvs._multi_bounds(multi).grow(cvs._multi_hot())
		var hot = mb.has_point(pos)
		cvs.draw_rect(mb, Color(1.0, 0.85, 0.3, 0.22 if hot else 0.10), true)
		cvs.draw_rect(mb, Color(1.0, 0.85, 0.3, 0.9 if hot else 0.5), false, 2.0 if hot else 1.0)
		if cvs._drag_entity == null:
 # 角标提示：拖动整组
			cvs.draw_string(ThemeDB.fallback_font, mb.position + Vector2(4, -4),
				"%d 个实体 · 拖动可整体移动" % multi.size(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(1.0, 0.85, 0.3, 0.9 if hot else 0.55))
	# 实体实际占位（清单 editorSize 或 prefab 碰撞尺寸）：青色实框，已在上面的单次遍历里收集
	for it in boxes:
		var s4: Vector2 = it[0]
		var sz: Vector2 = it[1]
		var r4 := Rect2(s4 - sz * 0.5, sz)
		cvs.draw_rect(r4, Color(0.35, 0.95, 0.95, 0.85), false, 1.0)
 # 十字标中心，便于对格
		cvs.draw_line(Vector2(r4.position.x, s4.y), Vector2(r4.end.x, s4.y), Color(0.35, 0.95, 0.95, 0.25), 1.0)
		cvs.draw_line(Vector2(s4.x, r4.position.y), Vector2(s4.x, r4.end.y), Color(0.35, 0.95, 0.95, 0.25), 1.0)
	# 触发区：没有贴图，用半透明矩形 + 事件名标签表示；绑定事件的用实色，未绑定的用警示色
	_draw_trigger_zones(zones)
	# 区域选区轮廓（瓦片层 Ctrl+拖动框选的结果）
	if cvs._region_sel.size.x > 0 and cvs._ent_layer_index() != cvs.active_layer:
		var rr := Rect2(Vector2(cvs._region_sel.position) * cvs.tile_px, Vector2(cvs._region_sel.size) * cvs.tile_px)
		cvs.draw_rect(rr, Color(1.0, 0.85, 0.3, 0.8), false, 2.0)
	# 区域拖动预览：整块幽灵按当前格偏移跟手，松手才真搬
	if cvs._move_active and not cvs._move_snap.is_empty():
		var md: Vector2i = cvs._move_cell_delta
		for t in cvs._move_snap.get("terrain", []):
			if cvs.atlas_tex != null:
				cvs.draw_texture_rect_region(cvs.atlas_tex,
					Rect2(Vector2(Vector2i(int(t[0]), int(t[1])) + md) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)),
					Rect2(Vector2(int(t[3]), int(t[4])) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)),
					Color(1, 1, 1, 0.6))
		for t in cvs._move_snap.get("decor", []):
			if cvs.atlas_tex != null:
				cvs.draw_texture_rect_region(cvs.atlas_tex,
					Rect2(Vector2(Vector2i(int(t[0]), int(t[1])) + md) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)),
					Rect2(Vector2(int(t[3]), int(t[4])) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)),
					Color(1, 1, 1, 0.6))
		for t in cvs._move_snap.get("collision", []):
			var mc: Vector2i = Vector2i(int(t[0]), int(t[1])) + md
			cvs.draw_rect(Rect2(Vector2(mc) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)), Color(1.0, 0.25, 0.25, 0.45), true)
		for s in cvs._move_snap.get("ents", []):
			if is_instance_valid(s):
				var tex0: Texture2D = cvs.thumbs.get(str((s as Sprite2D).get_meta("scene", "")))
				var er0 := Rect2((s as Sprite2D).position + Vector2(md) * cvs.tile_px - Vector2(cvs.tile_px, cvs.tile_px) * 0.5,
					Vector2(cvs.tile_px, cvs.tile_px))
				if tex0 != null:
					cvs.draw_texture_rect(tex0, er0, false, Color(1, 1, 1, 0.6))
		var gr0 := Rect2(Vector2(cvs._region_sel.position + md) * cvs.tile_px, Vector2(cvs._region_sel.size) * cvs.tile_px)
		cvs.draw_rect(gr0, Color(0.45, 1.0, 0.75, 0.9), false, 2.0)
	# 区域粘贴预览：三层幽灵跟随鼠标，左键落位
	if cvs._paste_mode and not cvs._region_clip.is_empty():
		var org = cvs._cell_of(pos)
		for t in cvs._region_clip.get("terrain", []):
			var tc = org + Vector2i(t[0], t[1])
			if cvs.atlas_tex != null:
				cvs.draw_texture_rect_region(cvs.atlas_tex,
					Rect2(Vector2(tc) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)),
					Rect2(Vector2(t[2], t[3]) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)),
					Color(1, 1, 1, 0.5))
		for t in cvs._region_clip.get("decor", []):
			var d2 = org + Vector2i(t[0], t[1])
			if cvs.atlas_tex != null:
				cvs.draw_texture_rect_region(cvs.atlas_tex,
					Rect2(Vector2(d2) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)),
					Rect2(Vector2(t[2], t[3]) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)),
					Color(1, 1, 1, 0.5))
		for t in cvs._region_clip.get("collision", []):
			var cc = org + Vector2i(t[0], t[1])
			cvs.draw_rect(Rect2(Vector2(cc) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px)), Color(1.0, 0.25, 0.25, 0.35), true)
 # 实体幽灵：区域碎片里的实体也预览
		for t in cvs._region_clip.get("entities", []):
			var ec2 = org + Vector2i(int(t.get("dx", 0)), int(t.get("dy", 0)))
			var tex: Texture2D = cvs.thumbs.get(str(t.get("scene", "")))
			var er := Rect2(Vector2(ec2) * cvs.tile_px, Vector2(cvs.tile_px, cvs.tile_px))
			if tex != null:
				cvs.draw_texture_rect(tex, er, false, Color(1, 1, 1, 0.55))
			else:
				cvs.draw_rect(er, Color(0.6, 1.0, 0.6, 0.4), true)
		var gr := Rect2(Vector2(org) * cvs.tile_px, Vector2(cvs._region_clip.get("size", Vector2i.ONE)) * cvs.tile_px)
		cvs.draw_rect(gr, Color(1.0, 0.85, 0.3, 0.9), false, 2.0)
## 触发区矩形：半透明填充 + 边框 + 左上角事件名标签。
## 未绑定事件时用警示色——它在地图里是"死"的，必须在画布上一眼能看出来。
## zones 由 _draw 的单次实体遍历收集，这里不再自己扫 entities。
func _draw_trigger_zones(zones: Array) -> void:
	for node in zones:
		var spr := node as Sprite2D
		if spr == null or not is_instance_valid(spr):
			continue
		var props: Dictionary = spr.get_meta("props", {}) if spr.get_meta("props", {}) is Dictionary else {}
		var size_rect: Vector2 = cvs.entity_display_size_of(spr)
		var rect := Rect2(spr.position - size_rect * 0.5, size_rect)
		var event_id := str(props.get("event", ""))
		var col := Color(0.55, 0.85, 1.0, 0.95) if event_id != "" else Color(1.0, 0.55, 0.35, 0.95)
		cvs.draw_rect(rect, Color(col, 0.16), true)
		cvs.draw_rect(rect, col, false, 1.5)
 # 左上角标签：事件 id + 触发方式，太长时截断
		var label := event_id if event_id != "" else "(未绑定事件)"
		label += " · " + str(props.get("mode", "enter"))
		if bool(props.get("once", false)):
			label += " · 一次"
		cvs.draw_string(ThemeDB.fallback_font, rect.position + Vector2(3, -3),
			label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x * cvs.zoom, 10, col)

# 笔刷覆盖矩形（世界坐标）

func _brush_rect(c: Vector2i) -> Rect2:
	var half = cvs.brush_size / 2
	return Rect2(Vector2(c.x - half, c.y - half) * cvs.tile_px, Vector2(cvs.brush_size, cvs.brush_size) * cvs.tile_px)
## —— 拆到 src/canvas/selection_ops.gd 的委托（调用点保持不变） ——
