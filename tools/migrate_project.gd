extends SceneTree
## 一次性迁移脚本：把游戏工程搬成 v6 契约（跑完即可删除，不进长期代码库）。
##
##   godot --headless --path <编辑器工程> --script res://tools/migrate_project.gd -- <游戏项目目录>
##
## 做三件事：
##   1. 清单 tiles[] + entities[] → assets[]（kind=scene/entity；tile 场景带 shape=tile）
##   2. 地图 version → 6；瓦片条目第 3 位「图集索引」→「资产 id 字符串」
##   3. 地图 entities[] → objects[]（scene→asset 键）；collision[] 数组条目 → 对象 {x, y}
##   4. 幂等：已是终态的数据再跑一遍不产生改动；缺失目录/空清单/半截数据一律跳过并打印
##
## 明确不搬运的东西（结构不同，交人工处理，脚本只报告）：
##   - 清单 entities[] 里同时带 role/functions/fields 的条目会被原样保留这些键

const MapStore := preload("res://src/map/map_store.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("用法: -- <游戏项目目录>[,<另一个项目目录>...]")
		quit(2)
		return
	var failed := 0
	for raw in args:
		for dir in str(raw).split(",", false):
			var d := str(dir).strip_edges()
			if d == "":
				continue
			print("=== 迁移 ", d)
			if not DirAccess.dir_exists_absolute(d):
				print("  跳过：目录不存在")
				continue
			if _migrate_manifest(d) < 0:
				failed += 1
			if _migrate_maps(d) < 0:
				failed += 1
			if _migrate_map_codes(d) < 0:
				failed += 1
	quit(1 if failed > 0 else 0)

## 返回 0 = 有改动或本来就不用改；-1 = 出错（跳过继续下一个项目）
func _migrate_manifest(dir: String) -> int:
	var p := dir.path_join("editor/editor_manifest.json")
	if not FileAccess.file_exists(p):
		print("  跳过清单：文件不存在")
		return 0
	var data = _read_json(p)
	if not (data is Dictionary):
		print("  跳过清单：JSON 不是对象")
		return -1
	var m: Dictionary = data
	var has_legacy: bool = m.has("tiles") or m.has("entities")
	if not has_legacy:
		if not m.has("assets"):
			print("  清单无 tiles/entities/assets：跳过")
			return 0
		print("  清单已是 assets[]：跳过")
		return 0
	var assets: Array = m.get("assets", []) if m.get("assets", []) is Array else []
	var taken := {}
	for a in assets:
		if a is Dictionary:
			taken[str((a as Dictionary).get("id", ""))] = true
	# tiles[]：图集 → scene/tile 资产；索引即地图瓦片条目第 3 位要替换成的资产 id
	var index_to_id := {}
	var tiles_raw = m.get("tiles", [])
	if tiles_raw is Array:
		for i in (tiles_raw as Array).size():
			var t = (tiles_raw as Array)[i]
			if not (t is Dictionary):
				print("  tiles[%d] 不是对象：跳过" % i)
				continue
			var td: Dictionary = (t as Dictionary).duplicate(true)
			td["kind"] = "scene"
			td["shape"] = "tile"
			var aid := str(td.get("id", ""))
			if aid == "":
				aid = "tile_%d" % i
				td["id"] = aid
			if taken.has(aid):
				aid = "%s_%d" % [aid, i]
				td["id"] = aid
			taken[aid] = true
			index_to_id[i] = aid
			assets.append(td)
	# entities[]：实体类型 → kind=entity 资产
	var ents_raw = m.get("entities", [])
	if ents_raw is Array:
		for j in (ents_raw as Array).size():
			var e = (ents_raw as Array)[j]
			if not (e is Dictionary):
				print("  entities[%d] 不是对象：跳过" % j)
				continue
			var ed: Dictionary = (e as Dictionary).duplicate(true)
			ed["kind"] = "entity"
			if str(ed.get("id", "")) == "":
				print("  entities[%d] 缺 id：跳过" % j)
				continue
			if taken.has(str(ed["id"])):
				print("  entities[%d] id 与图集重名（%s）：保留图集，实体改名为 %s_e" % [j, ed["id"], ed["id"]])
				ed["id"] = str(ed["id"]) + "_e"
			taken[str(ed["id"])] = true
			assets.append(ed)
	m.erase("tiles")
	m.erase("entities")
	m["assets"] = assets
	if _write_json(p, m) < 0:
		return -1
	print("  清单 → assets[]（%d 条；图集 %d 个可索引）" % [assets.size(), index_to_id.size()])
	return 0

func _migrate_maps(dir: String) -> int:
	var maps_dir := dir.path_join("maps")
	if not DirAccess.dir_exists_absolute(maps_dir):
		print("  跳过地图：目录不存在")
		return 0
	var d := DirAccess.open(maps_dir)
	if d == null:
		print("  跳过地图：目录打不开")
		return -1
	# 图集索引 → 资产 id：读的是刚迁移过的清单（tiles[] 顺序已在 _migrate_manifest 里消失，
	# 所以这里从清单的 assets[] 反查——按 shape=tile 的声明顺序对齐原 tiles[] 索引）
	var order: Array = []
	var manifest = _read_json(dir.path_join("editor/editor_manifest.json"))
	if manifest is Dictionary:
		for a in (manifest as Dictionary).get("assets", []):
			if a is Dictionary and str((a as Dictionary).get("kind", "")) == "scene" \
					and str((a as Dictionary).get("shape", "")) == "tile":
				order.append(str((a as Dictionary).get("id", "")))
	var changed := 0
	for f in d.get_files():
		if not str(f).ends_with(".json") or str(f).ends_with(".autosave.json"):
			continue
		var p := maps_dir.path_join(str(f))
		var data = _read_json(p)
		if not (data is Dictionary):
			print("  跳过 %s：JSON 不是对象" % f)
			continue
		var md: Dictionary = data
		var dirty := false
		var tiles = md.get("tiles", null)
		if tiles is Dictionary:
			for lid in (tiles as Dictionary):
				var cells = (tiles as Dictionary)[lid]
				if not (cells is Array):
					continue
				for k in (cells as Array).size():
					var c = (cells as Array)[k]
					if not (c is Array):
						continue
					# v6→v7：5 元追加第 6 位 alt=0（幂等）；5 元且第 3 位是数字 = 更老的 v4/v5 索引形态，
					# 先换资产 id 再补位（order 反查逻辑不变）
					if (c as Array).size() == 6:
						continue
					if (c as Array).size() == 5 and not ((c as Array)[2] is String):
						var idx := int((c as Array)[2])
						if idx < 0 or idx >= order.size():
							print("  %s：瓦片索引 %d 无对应资产（保留原值）" % [f, idx])
							continue
						(c as Array)[2] = str(order[idx])
					if (c as Array).size() == 5:
						(c as Array).append(0)
						dirty = true
		# entities[] → objects[]：同结构，只把 scene 键改名 asset（x/y 原样保留，浮点由编辑器再写）
		var old_ents = md.get("entities", null)
		if old_ents is Array:
			var objs: Array = md.get("objects", []) if md.get("objects", []) is Array else []
			for ent in (old_ents as Array):
				if not (ent is Dictionary):
					continue
				var od: Dictionary = (ent as Dictionary).duplicate(true)
				if od.has("scene"):
					od["asset"] = str(od["scene"])
					od.erase("scene")
				objs.append(od)
			md["objects"] = objs
			md.erase("entities")
			dirty = true
		# collision[]：v5 数组条目 → v6 对象 {x, y, type?, shape?}（缺省省略，幂等）
		var cols = md.get("collision", null)
		if cols is Array:
			var outc: Array = []
			var conv := false
			for ce in (cols as Array):
				if ce is Dictionary:
					outc.append(ce)
					continue
				if not (ce is Array) or (ce as Array).size() < 2:
					continue
				var ca: Array = ce
				var od := {"x": int(ca[0]), "y": int(ca[1])}
				if (ca as Array).size() >= 3 and str(ca[2]) != "" and str(ca[2]) != "solid":
					od["type"] = str(ca[2])
				if (ca as Array).size() >= 4 and str(ca[3]) != "":
					od["shape"] = str(ca[3])
				outc.append(od)
				conv = true
			if conv:
				md["collision"] = outc
				dirty = true
		# 层参数 / collisionTypes / ySortOrigin 是**加键不破形**：清单/地图加可选键不迁移。
		if int(md.get("version", 0)) != MapStore.FORMAT_VERSION:
			md["version"] = MapStore.FORMAT_VERSION
			dirty = true
		if dirty:
			if _write_json(p, md) < 0:
				print("  写盘失败：%s" % f)
				continue
			changed += 1
	print("  地图 → v7（改动 %d 个文件）" % changed)
	return 0

## v7 地图码：全图补发 meta.code（保存时也会补，迁移一次到位）；
## objects[].props.target_map 与内容 map_ref 字段值按「图名 → 码」重映射（跨图引用全码化）。
func _is_map_json(f) -> bool:
	return str(f).ends_with(".json") and not str(f).ends_with(".autosave.json")

func _migrate_map_codes(dir: String) -> int:
	var maps_dir := dir.path_join("maps")
	if not DirAccess.dir_exists_absolute(maps_dir):
		return 0
	var ContentId := preload("res://src/content/content_id.gd")
	var d := DirAccess.open(maps_dir)
	if d == null:
		return -1
	# pass 1：补码（顺序处理，后图防撞已写盘的前图码）
	var codes := {}   # 图名（文件名）→ 码
	for f in d.get_files():
		if not _is_map_json(f):
			continue
		var p := maps_dir.path_join(str(f))
		var md = _read_json(p)
		if not (md is Dictionary):
			continue
		var meta: Dictionary = (md as Dictionary).get("meta", {}) if (md as Dictionary).get("meta", {}) is Dictionary else {}
		if str(meta.get("code", "")) == "":
			var c := ContentId.new_inst_code()
			while codes.values().has(c):
				c = ContentId.new_inst_code()
			meta["code"] = c
			(md as Dictionary)["meta"] = meta
			if _write_json(p, md) < 0:
				print("  补码写盘失败：%s" % str(f))
		codes[str(f).get_basename()] = str(meta.get("code", ""))
	# 名→码表：旧值（图名）→ 码
	var name_to_code := {}
	for nm in codes:
		name_to_code[nm] = codes[nm]
	# map_ref 字段码集（三池声明里 type=map_ref 的字段码）
	var mapref_codes := {}
	var manifest = _read_json(dir.path_join("editor/editor_manifest.json"))
	if manifest is Dictionary:
		for pool in ["functions", "conditions", "steps"]:
			var decl = (manifest as Dictionary).get(pool, null)
			if not (decl is Array or decl is Dictionary):
				continue
			var items: Array = []
			if decl is Array:
				items = decl
			else:
				for k in (decl as Dictionary):
					items.append((decl as Dictionary)[k])
			for it in items:
				if not (it is Dictionary):
					continue
				for fd in ((it as Dictionary).get("fields", []) if (it as Dictionary).get("fields", []) is Array else []):
					if fd is Dictionary and str((fd as Dictionary).get("type", "")) == "map_ref":
						mapref_codes[str((fd as Dictionary).get("code", ""))] = true
	var remapped := 0
	# pass 2a：地图 props.target_map
	for f in d.get_files():
		if not _is_map_json(f):
			continue
		var p := maps_dir.path_join(str(f))
		var md = _read_json(p)
		if not (md is Dictionary):
			continue
		var dirty2 := false
		for ob in ((md as Dictionary).get("objects", []) if (md as Dictionary).get("objects", []) is Array else []):
			if not (ob is Dictionary):
				continue
			var props: Dictionary = (ob as Dictionary).get("props", {}) if (ob as Dictionary).get("props", {}) is Dictionary else {}
			var tv := str(props.get("target_map", ""))
			if tv != "" and name_to_code.has(tv):
				props["target_map"] = name_to_code[tv]
				(ob as Dictionary)["props"] = props
				dirty2 = true
		if dirty2:
			remapped += 1
			if _write_json(p, md) < 0:
				print("  重映射写盘失败：%s" % str(f))
	# pass 2b：内容 map_ref 字段值
	var cdir := str((manifest as Dictionary).get("contentDir", "content") if manifest is Dictionary else "content")
	var content_dir := dir.path_join(cdir)
	if DirAccess.dir_exists_absolute(content_dir):
		var dc := DirAccess.open(content_dir)
		if dc != null:
			for kind in dc.get_directories():
				var dk := content_dir.path_join(str(kind))
				var dc2 := DirAccess.open(dk)
				if dc2 == null:
					continue
				for cf in dc2.get_files():
					if not str(cf).ends_with(".json"):
						continue
					var cp := dk.path_join(str(cf))
					var cd = _read_json(cp)
					if not (cd is Dictionary):
						continue
					var fields: Dictionary = (cd as Dictionary).get("fields", {}) if (cd as Dictionary).get("fields", {}) is Dictionary else {}
					var cdirty := false
					for fk in fields:
						if mapref_codes.has(str(fk)):
							var fv = fields[fk]
							if fv is String and name_to_code.has(str(fv)):
								fields[fk] = name_to_code[str(fv)]
								cdirty = true
					if cdirty:
						(cd as Dictionary)["fields"] = fields
						if _write_json(cp, cd) < 0:
							print("  内容重映射写盘失败：%s" % str(cf))
						else:
							remapped += 1
	print("  地图码：补发 %d 图 + 重映射 %d 处" % [codes.size(), remapped])
	return 0

func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return JSON.parse_string(text)

func _write_json(path: String, data: Dictionary) -> int:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return -1
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return 0
