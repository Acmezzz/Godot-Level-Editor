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
## 首个挂载节点的 CollisionShape2D；找不到再退回任意可达节点，最后才用声明兜底。
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
	# 可达性：从根逐层展开。.tscn 的 parent 是相对根的节点路径（"A/B"），
	# 不是叶名——按完整路径求不动点，parent 链断掉的节点整棵算未挂载。
	var reachable := {"": true, ".": true}
	var changed := true
	while changed:
		changed = false
		for n in nodes:
			var npath := _node_path(n)
			if reachable.has(npath):
				continue
			if reachable.has(str((n as Dictionary).get("parent", ""))):
				reachable[npath] = true
				changed = true
	var mounted: Array = []
	for n in nodes:
		if reachable.has(_node_path(n)):
			(n as Dictionary)["reachable"] = true
			mounted.append(n)
	# 优先：挂载节点里的 CollisionShape2D（按文件顺序）
	for n in mounted:
		if str((n as Dictionary).get("type", "")) == "CollisionShape2D":
			var sid := str((n as Dictionary).get("shape", ""))
			if shapes.has(sid):
				return shapes[sid]
	# 其次：任意节点的 CollisionShape2D（老文件/嵌套场景）
	for n in nodes:
		if str((n as Dictionary).get("type", "")) == "CollisionShape2D":
			var sid2 := str((n as Dictionary).get("shape", ""))
			if shapes.has(sid2):
				return shapes[sid2]
	# 没有 CollisionShape2D：单个形状时直接用它（保持旧行为），多个形状不猜
	if shapes.size() == 1:
		for k in shapes:
			return shapes[k]
	return Vector2.ZERO

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
	if par == "" or par == ".":
		return nm
	return par + "/" + nm
