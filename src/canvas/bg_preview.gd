extends RefCounted
## _bg_ctrl：背景图组的画布预览（视差背景，编辑器侧）。
## 数据源：manifest.bgGroups = {组名: {layers: [{img, scale, z, tint, alpha, mirror}]}}，
## 地图引用 map_data.bgGroup = 组名（"" = 无背景，只剩底色）。
## 编辑器预览 = 视差近似模拟：世界坐标 = 基准 + 相机位移 × (1-系数)；
## 游戏侧用真 Parallax2D（map_loader._build_bg），两侧公式一致。

var cvs   # 宿主（editor_canvas）
var _nodes := []   # [{node: Sprite2D, base: Vector2, scale: Vector2}]
var _tex_cache := {}   # D4（批次 10）：rel 路径 → ImageTexture，undo/redo/换图不重读盘

func _init(host) -> void:
	cvs = host

## 清掉全部预览节点（换图/重建前调用）
func clear() -> void:
	for it in _nodes:
		if is_instance_valid(it.node):
			it.node.queue_free()
	_nodes.clear()

## 相机更新时调用：视差模拟（与游戏侧 Parallax2D 同一套公式）
func update_parallax() -> void:
	for it in _nodes:
		if is_instance_valid(it.node):
			(it.node as Sprite2D).position = it.base + cvs.cam_pos * (Vector2.ONE - it.scale)

## 显隐开关（状态栏「背景」）
func set_visible(v: bool) -> void:
	for it in _nodes:
		if is_instance_valid(it.node):
			(it.node as Sprite2D).visible = v

## 按 map_data.bgGroup 重建预览层（load_data / 背景弹窗保存后调用）
func rebuild() -> void:
	clear()
	var data: Dictionary = cvs.map_data
	if data.is_empty():
		return
	var gname := str(data.get("bgGroup", ""))
	if gname == "":
		return
	var groups: Dictionary = cvs.manifest.get("bgGroups", {})
	var gdef: Dictionary = groups.get(gname, {})
	var layers: Array = (gdef.get("layers", []) as Array)
	if layers.is_empty():
		return
	var base_dir: String = str(cvs.manifest.get("_dir", ""))
	var meta: Dictionary = data.get("meta", {})
	var map_bottom := float(int(meta.get("h", 56)) * int(cvs.tile_px))
	for lay in layers:
		if not (lay is Dictionary):
			continue
		var rel := str(lay.get("img", "")).lstrip("/")
		if rel == "" or rel.contains(".."):
			continue
		var tex = _tex_cache.get(rel, null)   # D4：按路径缓存
		if tex == null:
			var img := Image.load_from_file(base_dir.path_join(rel))
			if img == null:
				continue
			tex = ImageTexture.create_from_image(img)
			_tex_cache[rel] = tex
		var sc: Array = lay.get("scale", [0.3, 0.1])
		var s := Vector2(
			clampf(float(sc[0]) if sc.size() > 0 else 0.3, 0.0, 2.0),
			clampf(float(sc[1]) if sc.size() > 1 else 0.1, 0.0, 2.0))
		var tn: Array = lay.get("tint", [1.0, 1.0, 1.0])
		var al := clampf(float(lay.get("alpha", 1.0)), 0.0, 1.0)
		var col := Color(
			float(tn[0]) if tn.size() > 0 else 1.0,
			float(tn[1]) if tn.size() > 1 else 1.0,
			float(tn[2]) if tn.size() > 2 else 1.0, al)
		var z := clampi(int(lay.get("z", -8)), -40, 40)
		var w := float(tex.get_width())
		# C5（批次 12 修正）：平铺份数按「地图宽×视差系数+视口宽」双边覆盖动态算——
		# 位移 = cam_pos×(1-s)，需要覆盖 [0, cam_pos×s + vw]，固定 3 份或漏乘系数都会露底色
		var map_w := float(int(meta.get("w", 120)) * int(cvs.tile_px))
		var vw: float = cvs.get_viewport_rect().size.x
		var copies := maxi(3, int(ceil(2.0 * (map_w * s.x + vw) / maxf(w, 1.0))) + 2)
		var half := float((copies - 1) / 2)
		for k in copies:
			var off := float(k) - half
			var spr := Sprite2D.new()
			spr.texture = tex
			spr.centered = false
			spr.modulate = col
			spr.z_index = z
			var base := Vector2(-w * 0.5 + off * w, map_bottom - float(tex.get_height()))
			spr.position = base + cvs.cam_pos * (Vector2.ONE - s)
			cvs.map_root.add_child(spr)
			spr.visible = cvs.bg_visible
			_nodes.append({"node": spr, "base": base, "scale": s})
