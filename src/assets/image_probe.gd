extends RefCounted
## ImageProbe：图像/场景探针（从 manifest.gd 拆出的纯静态域）。
## 预览图透明裁边 + prefab 场景碰撞尺寸探测——清单加载链与缩略图共用。

## 把图像裁到不透明内容的最小外接框（四周透明留白削掉）。
## 预览图多是 96×96 画布 + 中间十几像素的小图，不裁的话在画布上就是个点。
## 留 1px 余量，避免裁得过紧导致相邻像素被过滤掉。全透明图原样返回。

static func trim_alpha(img: Image) -> Image:
	if img == null:
		return null
	var used := img.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return img
	var pad := 1
	var x0 := maxi(used.position.x - pad, 0)
	var y0 := maxi(used.position.y - pad, 0)
	var x1 := mini(used.position.x + used.size.x + pad, img.get_width())
	var y1 := mini(used.position.y + used.size.y + pad, img.get_height())
	var rect := Rect2i(x0, y0, x1 - x0, y1 - y0)
	if rect.position == Vector2i.ZERO and rect.size == img.get_size():
		return img
	var out := Image.create(rect.size.x, rect.size.y, false, img.get_format())
	out.blit_rect(img, rect, Vector2i.ZERO)
	return out

## 从 .tscn 里读第一个 CollisionShape2D / RectangleShape2D 的尺寸（像素）。
## 找不到或解析失败返回 Vector2.ZERO。不做完整场景解析，只按行扫描关键字段。
static func prefab_collision_size(project_dir: String, prefab_rel: String) -> Vector2:
	var p: String = project_dir.path_join(prefab_rel) if project_dir != "" else prefab_rel
	if p == "" or not FileAccess.file_exists(p):
		return Vector2.ZERO
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return Vector2.ZERO
	var text := f.get_as_text()
	f.close()
	# 收集形状尺寸：Rectangle 用 size，Circle 用 radius*2，Capsule 用 radius*2 + height
	var sizes := {}
	var cur_id := ""
	var cur_kind := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("[sub_resource type="):
			var idpos := line.find("id=\"")
			cur_id = ""
			cur_kind = ""
			if idpos >= 0:
				var rest := line.substr(idpos + 4)
				cur_id = rest.substr(0, rest.find("\""))
			if line.contains("RectangleShape2D"):
				cur_kind = "rect"
			elif line.contains("CircleShape2D"):
				cur_kind = "circle"
			elif line.contains("CapsuleShape2D"):
				cur_kind = "capsule"
			continue
		if cur_id == "" or cur_kind == "":
			continue
		if line.begins_with("size = Vector2("):
			var inner := line.trim_prefix("size = Vector2(").trim_suffix(")")
			var parts := inner.split(",")
			if parts.size() == 2:
				sizes[cur_id] = Vector2(parts[0].strip_edges().to_float(), parts[1].strip_edges().to_float())
		elif line.begins_with("radius = ") and cur_kind == "circle":
			var r := line.trim_prefix("radius = ").to_float()
			sizes[cur_id] = Vector2(r * 2.0, r * 2.0)
		elif line.begins_with("radius = ") and cur_kind == "capsule":
			sizes[cur_id + "_r"] = Vector2(line.trim_prefix("radius = ").to_float(), 0)
		elif line.begins_with("height = ") and cur_kind == "capsule":
			var h := line.trim_prefix("height = ").to_float()
			var rv: Vector2 = sizes.get(cur_id + "_r", Vector2(0, 0))
			sizes[cur_id] = Vector2(rv.x * 2.0, h)
		elif line.begins_with("[") and not line.begins_with("[sub_resource"):
			cur_id = ""
			cur_kind = ""
	# 找到第一个 CollisionShape2D 节点引用的 shape，取其 size
	for raw2 in text.split("\n"):
		var line2 := raw2.strip_edges()
		if line2.begins_with("[node") and line2.contains("CollisionShape2D"):
			# 在同一节点块内找 shape = SubResource("...")
			var idx := text.find(line2)
			if idx < 0:
				continue
			var block := text.substr(idx, 400)
			var spos := block.find("shape = SubResource(\"")
			if spos >= 0:
				var rest2 := block.substr(spos + 20)
				var sid := rest2.substr(0, rest2.find("\""))
				if sizes.has(sid):
					return sizes[sid]
	# 没有 CollisionShape2D：退回第一个收集到的形状尺寸（可能是圆/胶囊）
	for k in sizes:
		return sizes[k]
	return Vector2.ZERO
