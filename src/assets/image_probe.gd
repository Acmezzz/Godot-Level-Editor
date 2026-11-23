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

## 从 .tscn 里读「已挂载」的 CollisionShape2D 形状尺寸（像素）——A4。
## 旧实现按 400 字符窗口抓 shape 引用：节点块被截断、且取第一个 CollisionShape2D
## （可能挂在未挂载的兄弟节点下）。现在按节点块解析：
##   [node name="X" type="Y" parent="..."]  → 记录类型与 parent 链
##   shape = SubResource("id")             → 该节点引用的形状
## 只认「从根可达」的节点（parent 链逐层在文件里存在），优先返回挂在目标形状/
## 首个已启用的 CollisionShape2D；没有可靠的挂载形状就由资产声明兜底。
static func prefab_collision_size(project_dir: String, prefab_rel: String) -> Vector2:
	var p: String = project_dir.path_join(prefab_rel) if project_dir != "" else prefab_rel
	if p == "" or not FileAccess.file_exists(p):
		return Vector2.ZERO
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return Vector2.ZERO
	var text := f.get_as_text()
	f.close()
	var shapes := _parse_shapes(text)
	if shapes.is_empty():
		return Vector2.ZERO
	var nodes := _parse_nodes(text)   # [{name, type, parent, shape}]
	var by_path := {}
	for node: Dictionary in nodes:
		by_path[_node_path(node)] = node
	var transforms := {}
	for node: Dictionary in nodes:
		if node.type != "CollisionShape2D" or bool(node.get("disabled", false)) or not shapes.has(node.shape):
			continue
		var xf = _mounted_transform(_node_path(node), by_path, transforms, {})
		if xf is Transform2D:
			var dims: Vector2 = shapes[node.shape]
			var basis: Transform2D = xf
			var size := basis.x.abs() * dims.x + basis.y.abs() * dims.y
			if size.is_finite() and size.x > 0.0 and size.y > 0.0:
				return size
	return Vector2.ZERO

static func _mounted_transform(path: String, nodes: Dictionary, cache: Dictionary, active: Dictionary) -> Variant:
	if cache.has(path):
		return cache[path]
	if active.has(path) or not nodes.has(path):
		return null
	active[path] = true
	var node: Dictionary = nodes[path]
	var xf := Transform2D(float(node.get("rotation", 0.0)), node.get("scale", Vector2.ONE), 0.0, Vector2.ZERO)
	if path != "." and not bool(node.get("top_level", false)):
		var parent = _mounted_transform(str(node.get("parent", "")), nodes, cache, active)
		if not parent is Transform2D:
			active.erase(path)
			return null
		xf = parent * xf
	active.erase(path)
	cache[path] = xf
	return xf

## 解析 sub_resource 形状表：{id: Vector2}。rect 用 size，circle/radius，capsule 组合。
static func _parse_shapes(text: String) -> Dictionary:
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
		if line.begins_with("[") and not line.begins_with("[sub_resource"):
			cur_id = ""
			cur_kind = ""
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
			sizes[cur_id + "\u0001r"] = Vector2(line.trim_prefix("radius = ").to_float(), 0)
		elif line.begins_with("height = ") and cur_kind == "capsule":
			var h := line.trim_prefix("height = ").to_float()
			var rv: Vector2 = sizes.get(cur_id + "\u0001r", Vector2(0, 0))
			sizes[cur_id] = Vector2(rv.x * 2.0, h)
	for key in sizes.keys():
		if str(key).ends_with("r"):
			sizes.erase(key)
	return sizes

## 解析节点块：只取 [node] 头行 + 块内 shape 引用。parent 保持原始字符串
## （"." = 根的子节点；"Node/Child" = 现有节点名）。
static func _parse_nodes(text: String) -> Array:
	var out: Array = []
	var cur: Dictionary = {}
	var in_node := false
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("[node"):
			if not cur.is_empty():
				out.append(cur)
			cur = {"name": _attr(line, "name"), "type": _attr(line, "type"),
				"parent": _attr(line, "parent"), "shape": ""}
			in_node = true
			continue
		if line.begins_with("[") and not line.begins_with("[sub_resource"):
			if in_node and not cur.is_empty():
				out.append(cur)
			cur = {}
			in_node = false
			continue
		if in_node and line.begins_with("shape = SubResource(\""):
			var rest := line.substr(line.find("SubResource(\"") + 13)
			cur["shape"] = rest.substr(0, rest.find("\""))
		elif in_node and line.begins_with("rotation = "):
			cur["rotation"] = line.trim_prefix("rotation = ").to_float()
		elif in_node and line == "disabled = true":
			cur["disabled"] = true
		elif in_node and line == "top_level = true":
			cur["top_level"] = true
		elif in_node and line.begins_with("scale = Vector2("):
			# 节点缩放参与碰撞体积（放大过的 prefab 占位盒要跟着放大）
			var inner := line.trim_prefix("scale = Vector2(").trim_suffix(")")
			var parts := inner.split(",")
			if parts.size() == 2:
				cur["scale"] = Vector2(parts[0].strip_edges().to_float(),
					parts[1].strip_edges().to_float())
	if not cur.is_empty():
		out.append(cur)
	return out

## 取 [node ...] 头行里的 key="value"
static func _attr(line: String, key: String) -> String:
	var token := key + "=\""
	var idx := line.find(token)
	if idx < 0:
		return ""
	var rest := line.substr(idx + token.length())
	return rest.substr(0, rest.find("\""))

## 节点在场景里的完整路径：根的子节点 = name；更深层 = parent + "/" + name。
## tscn 的 parent 写的是相对根的路径（"Body/Arm"），不是叶名。
static func _node_path(n: Dictionary) -> String:
	var nm := str(n.get("name", ""))
	var par := str(n.get("parent", ""))
	if par == "":
		return "."
	if par == ".":
		return nm
	return par + "/" + nm
