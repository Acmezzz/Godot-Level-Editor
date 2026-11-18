extends RefCounted
## 关卡清单（<项目>/editor/levels.json）：定义所有地图的关卡组织方式。
## 支持两种模式：
##   "metroidvania"（大地图/银河城）：地图互相连通，按 area 分区，入口互相指向
##   "level_select"（选关）：线性关卡列表，逐关解锁，无跨图传送要求
##
## 结构：
## {
##   "mode": "metroidvania" | "level_select",
##   "start": "level1",              # 新游戏入口
##   "levels": [
##     { "map": "level1", "name": "苔原入口", "order": 1,
##       "area": "tundra", "unlock": "", "secret": false }
##   ]
## }

const Store := preload("res://src/map_store.gd")
const ManifestScript := preload("res://src/manifest.gd")

const MODE_METROIDVANIA := "metroidvania"
const MODE_LEVEL_SELECT := "level_select"
const FILE_REL := "editor/levels.json"

## 清单文件路径
static func file_path(m: Dictionary) -> String:
	var dir := str(m.get("_dir", ""))
	if dir == "":
		return ""
	return dir.path_join(FILE_REL)

## 读清单；不存在时返回带默认值的空清单（不写盘）
static func load_levels(m: Dictionary) -> Dictionary:
	var p := file_path(m)
	var out := {"mode": MODE_LEVEL_SELECT, "start": "", "levels": []}
	if p == "" or not FileAccess.file_exists(p):
		# 没有清单时按地图文件名生成一份建议清单（不改盘）
		out["levels"] = suggest_levels(m)
		var maps := Store.list_maps(m)
		if not maps.is_empty():
			out["start"] = maps[0]
		return out
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return out
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		# P-24：清单损坏 → 建议清单回退，避免「打开→保存」把空清单写盘覆盖好数据
		out["levels"] = suggest_levels(m)
		var maps := Store.list_maps(m)
		if not maps.is_empty():
			out["start"] = maps[0]
		return out
	if not parsed.has("mode"):
		parsed["mode"] = MODE_LEVEL_SELECT
	if not (parsed.get("levels") is Array):
		parsed["levels"] = []
	# P-24：过滤非字典条目（坏元素不再流进 UI/校验）
	parsed["levels"] = (parsed.get("levels", []) as Array).filter(func(x): return x is Dictionary)
	return parsed

## 写清单；返回是否成功（P-02/S-02：走 MapStore.write_json 原子写单入口）
static func save_levels(m: Dictionary, data: Dictionary) -> bool:
	var p := file_path(m)
	if p == "":
		return false
	var dir := p.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	return Store.write_json(p, data)

## 按现有地图文件生成建议清单条目（order 按文件名排序）
static func suggest_levels(m: Dictionary) -> Array:
	var out := []
	var i := 1
	for name in Store.list_maps(m):
		out.append({
			"map": name,
			"name": name,
			"order": i,
			"area": "",
			"unlock": "",
			"secret": false,
		})
		i += 1
	return out

## 取某个地图的条目；没有返回 {}
static func entry_of(data: Dictionary, map_name: String) -> Dictionary:
	for lv in data.get("levels", []):
		if str(lv.get("map", "")) == map_name:
			return lv
	return {}

## 构建世界地图拓扑：节点（地图）+ 有向边（跨图 exit 连接）。
## all 传入外部已读好的 read_all 结果（PF-05：一次刷新链只读一遍盘），为空时自读。
## 返回 {nodes: [...], edges: [...]}
static func build_world_graph(m: Dictionary, levels: Dictionary, all = {}) -> Dictionary:
	var nodes: Array = []
	var edges: Array = []
	if all == null or (all as Dictionary).is_empty():
		all = Store.read_all(m)
	# 先按关卡清单顺序建节点
	var listed := {}
	for lv in levels.get("levels", []):
		var map_name := str(lv.get("map", ""))
		listed[map_name] = true
		var d: Dictionary = all.get(map_name, {})
		var meta: Dictionary = d.get("meta", {})
		nodes.append({
			"map": map_name,
			"name": str(lv.get("name", map_name)),
			"w": int(meta.get("w", 0)),
			"h": int(meta.get("h", 0)),
			"ents": (d.get("entities", []) as Array).size(),
			"area": str(lv.get("area", "")),
			"order": int(lv.get("order", 0)),
			"issues": 0,
			"in_list": true,
		})
	# 清单外的地图也补上（标为未编入）
	for map_name in all:
		if listed.has(map_name):
			continue
		var d2: Dictionary = all[map_name]
		var meta2: Dictionary = d2.get("meta", {})
		nodes.append({
			"map": map_name,
			"name": map_name,
			"w": int(meta2.get("w", 0)),
			"h": int(meta2.get("h", 0)),
			"ents": (d2.get("entities", []) as Array).size(),
			"area": "",
			"order": 999,
			"issues": 1,   # 未编入清单 = 显示红点
			"in_list": false,
		})

	# Classify each configured exit by its actual destination relationship.
	var relation_counts := {}
	for from_map in all:
		var data: Dictionary = all[from_map]
		for ent in data.get("entities", []):
			if not (ent is Dictionary) or not ManifestScript.has_role(m, str(ent.get("scene", "")), "exit"):
				continue
			var props: Dictionary = ent.get("props", {})
			var to_map := str(props.get("target_map", ""))
			if to_map == "" or to_map == str(from_map):
				continue
			var relation := _world_exit_relation(m, str(from_map), ent, all)
			var key: String = str(from_map) + "\u0001" + to_map
			if not relation_counts.has(key):
				relation_counts[key] = {
					"paired_count": 0, "one_way_count": 0,
					"broken_count": 0, "invalid_count": 0,
				}
			var counts: Dictionary = relation_counts[key]
			var count_key := "invalid_count" if relation == "" else relation + "_count"
			counts[count_key] = int(counts.get(count_key, 0)) + 1
	for key: String in relation_counts:
		var parts := key.split("\u0001")
		var from_map2 := parts[0]
		var to_map2 := parts[1]
		var counts: Dictionary = relation_counts[key]
		var paired_count := int(counts.get("paired_count", 0))
		var one_way_count := int(counts.get("one_way_count", 0))
		var broken_count := int(counts.get("broken_count", 0))
		var invalid_count := int(counts.get("invalid_count", 0))
		var count := paired_count + one_way_count + broken_count + invalid_count
		edges.append({
			"from": from_map2,
			"to": to_map2,
			"count": count,
			"paired_count": paired_count,
			"one_way_count": one_way_count,
			"broken_count": broken_count,
			"invalid_count": invalid_count,
			"valid_count": paired_count + one_way_count,
			"paired": count > 0 and paired_count == count,
		})
	return {"nodes": nodes, "edges": edges}

static func _world_exit_relation(m: Dictionary, from_map: String, ent: Dictionary, all: Dictionary) -> String:
	var props: Dictionary = ent.get("props", {})
	var to_map := str(props.get("target_map", ""))
	var target_id := str(props.get("target_point", ""))
	if to_map == "" or to_map == from_map or target_id == "" or not all.has(to_map):
		return ""
	var target_ids := _world_ids_of(all[to_map])
	if not target_ids.has(target_id):
		return ""
	var target: Dictionary = target_ids[target_id]
	var target_scene := str(target.get("scene", ""))
	if ManifestScript.has_role(m, target_scene, "landing"):
		return "one_way"
	if not ManifestScript.has_role(m, target_scene, "exit"):
		return ""
	var peer_props: Dictionary = target.get("props", {})
	if str(peer_props.get("target_map", "")) == from_map \
			and str(peer_props.get("target_point", "")) == str(ent.get("id", "")):
		return "paired"
	return "broken"

static func _world_ids_of(data: Dictionary) -> Dictionary:
	var ids := {}
	for ent in data.get("entities", []):
		if ent is Dictionary:
			ids[str(ent.get("id", ""))] = ent
	return ids

## 找出从 start 出发不可达的地图（银河城可达性检查）
static func unreachable_maps(graph: Dictionary, start: String) -> Array:
	var adj := {}
	for ed in graph.get("edges", []):
		if int(ed.get("valid_count", ed.get("count", 1))) <= 0:
			continue
		var f := str(ed.get("from", ""))
		if not adj.has(f):
			adj[f] = []
		(adj[f] as Array).append(str(ed.get("to", "")))
	var visited := {}
	var queue := [start]
	while not queue.is_empty():
		var cur = queue.pop_front()
		if visited.has(cur):
			continue
		visited[cur] = true
		for nxt in adj.get(cur, []):
			if not visited.has(nxt):
				queue.append(nxt)
	var out := []
	for nd in graph.get("nodes", []):
		var nm := str(nd.get("map", ""))
		if not visited.has(nm):
			out.append(nm)
	return out
