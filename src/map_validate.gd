extends RefCounted
## 引用完整性校验 + 改名引用迁移。纯逻辑，无 UI、只通过 MapStore 读写。
##
## 校验范围（跨全部地图）：
##   - portal.target_point 悬空（同图找不到该 id）
##   - portal ↔ portal 一对多（同一门被多个门引用）
##   - exit.target_map 指向不存在的地图
##   - exit.target_point 在目标地图找不到
##   - exit ↔ exit 不成对（A 指向 B，但 B 没指回 A）
##   - spawn_point 未被任何门/出口使用（提示级）

const Store := preload("res://src/map_store.gd")
const ManifestScript := preload("res://src/manifest.gd")

## 返回问题数组，每项：
##   {level: "error"|"warn", map, ent_id, scene, field, message}
static func validate_all(m: Dictionary) -> Array:
	var issues: Array = []
	var bad: Array = []
	var all := Store.read_all(m, bad)
	# P-03：坏图不再隐身——校验页直接报 error（T-04 的被测行为）
	for b in bad:
		issues.append(_level_issue("error", str(b.get("name", "")), "地图文件损坏无法参与校验：" + str(b.get("reason", ""))))
	var exits_by_target := _exit_targets_of(m, all)
	for map_name in all:
		var data: Dictionary = all[map_name]
		var ids := _ids_of(data)
		# P-08：同图重复实体 id（_ids_of 后者覆盖前者，旧实现零检测）
		for eid in _dup_ids(data):
			issues.append(_issue("error", map_name, {"id": eid}, "", "实体 id 重复: " + eid))
		_collect_portal_issues(m, map_name, data, ids, issues)
		_collect_exit_issues(m, map_name, data, ids, issues, all)
		_collect_orphan_points(m, map_name, data, ids, issues, (exits_by_target.get(map_name, {}) as Dictionary))
		_collect_landing_blocked(m, map_name, data, issues)
	return issues

## 单图校验（只查本图实体；跨图部分按需读目标图）
static func validate_map(m: Dictionary, map_name: String, data: Dictionary) -> Array:
	var issues: Array = []
	var ids := _ids_of(data)
	for eid in _dup_ids(data):
		issues.append(_issue("error", map_name, {"id": eid}, "", "实体 id 重复: " + eid))
	_collect_portal_issues(m, map_name, data, ids, issues)
	_collect_exit_issues(m, map_name, data, ids, issues, {})
	_collect_orphan_points(m, map_name, data, ids, issues, (_exit_targets_of(m, Store.read_all(m)).get(map_name, {}) as Dictionary))
	_collect_landing_blocked(m, map_name, data, issues)
	return issues

## 关卡清单校验：清单条目与地图文件的一致性、入口与解锁引用
static func validate_levels(m: Dictionary, levels: Dictionary) -> Array:
	var issues: Array = []
	var maps := Store.list_maps(m)
	var seen := {}
	var arr: Array = levels.get("levels", [])
	for lv in arr:
		if not (lv is Dictionary):
			continue
		var map_name := str(lv.get("map", ""))
		if map_name == "":
			issues.append(_level_issue("error", "", "关卡条目缺少 map 字段"))
			continue
		if seen.has(map_name):
			issues.append(_level_issue("error", map_name, "关卡清单里重复出现该地图"))
		seen[map_name] = true
		if not maps.has(map_name):
			issues.append(_level_issue("error", map_name, "关卡清单指向不存在的地图文件"))
		var unlock := str(lv.get("unlock", ""))
		# P-07：自解锁必然恒真跳过旧检查——单独报错
		if unlock == map_name:
			issues.append(_level_issue("error", map_name, "解锁前置不能是自己"))
		elif unlock != "" and not seen.has(unlock) and not maps.has(unlock):
			issues.append(_level_issue("error", map_name, "解锁前置地图不存在: " + unlock))
	var start := str(levels.get("start", ""))
	if start == "":
		issues.append(_level_issue("warn", "", "关卡清单没有设置起始关"))
	elif not maps.has(start):
		issues.append(_level_issue("error", start, "起始关指向不存在的地图"))
	# 有地图但不在清单里
	for map_name in maps:
		if not seen.has(map_name):
			issues.append(_level_issue("warn", map_name, "地图存在但未加入关卡清单"))
	return issues

static func _level_issue(level: String, map_name: String, msg: String) -> Dictionary:
	return {"level": level, "map": map_name, "ent_id": "", "scene": "", "field": "levels", "message": msg}

## 收集重复实体 id（P-08）
static func _dup_ids(data: Dictionary) -> Array:
	var seen := {}
	var dups := {}
	for ent in data.get("entities", []):
		if not (ent is Dictionary):
			continue
		var eid := str(ent.get("id", ""))
		if eid == "":
			continue
		if seen.has(eid):
			dups[eid] = true
		seen[eid] = true
	return dups.keys()

static func _ids_of(data: Dictionary) -> Dictionary:
	var out := {}
	for ent in data.get("entities", []):
		if ent is Dictionary:
			out[str(ent.get("id", ""))] = ent
	return out

static func _issue(level: String, map_name: String, ent: Dictionary, field: String, msg: String) -> Dictionary:
	return {
		"level": level,
		"map": map_name,
		"ent_id": str(ent.get("id", "")),
		"scene": str(ent.get("scene", "")),
		"field": field,
		"message": msg,
	}

static func _collect_portal_issues(m: Dictionary, map_name: String, data: Dictionary, ids: Dictionary, issues: Array) -> void:
	var inbound := {}
	for ent in data.get("entities", []):
		if not (ent is Dictionary) or not ManifestScript.has_role(m, str(ent.get("scene", "")), "portal"):
			continue
		var props: Dictionary = ent.get("props", {})
		var tgt := str(props.get("target_point", ""))
		if tgt == "":
			continue
		if not ids.has(tgt):
			issues.append(_issue("error", map_name, ent, "target_point",
				"传送门指向不存在的实体 " + tgt))
			continue
		var tgt_ent: Dictionary = ids[tgt]
		# P-05：目标 role 白名单——传送门只能指向落点/传送门（role 判断，声明优先）
		if not (ManifestScript.has_role(m, str(tgt_ent.get("scene", "")), "landing")
				or ManifestScript.has_role(m, str(tgt_ent.get("scene", "")), "portal")):
			issues.append(_issue("error", map_name, ent, "target_point",
				"传送门的目标 %s 是 %s，应为传送落点或传送门" % [tgt, str(tgt_ent.get("scene", ""))]))
			continue
		if ManifestScript.has_role(m, str(tgt_ent.get("scene", "")), "portal"):
			# 双向配对：对方必须指回来
			var back := str(tgt_ent.get("props", {}).get("target_point", ""))
			if back != str(ent.get("id", "")):
				issues.append(_issue("error", map_name, ent, "target_point",
					"传送门 %s 与 %s 不成对（对方指向 %s）" % [str(ent.get("id", "")), tgt, back if back != "" else "空"]))
			if not inbound.has(tgt):
				inbound[tgt] = []
			inbound[tgt].append(str(ent.get("id", "")))
	# 一对多：同一个门被多个门指向
	for target_id in inbound:
		var sources: Array = inbound[target_id]
		if sources.size() > 1:
			var tgt_ent2: Dictionary = ids.get(target_id, {})
			issues.append(_issue("error", map_name, tgt_ent2, "target_point",
				"传送门 %s 被多个门引用：%s（应一对一）" % [target_id, ", ".join(sources)]))

static func _collect_exit_issues(m: Dictionary, map_name: String, data: Dictionary, _ids: Dictionary, issues: Array, all: Dictionary) -> void:
	for ent in data.get("entities", []):
		if not (ent is Dictionary) or not ManifestScript.has_role(m, str(ent.get("scene", "")), "exit"):
			continue
		var props: Dictionary = ent.get("props", {})
		var tmap := str(props.get("target_map", ""))
		var tpt := str(props.get("target_point", ""))
		if tmap == "":
			issues.append(_issue("warn", map_name, ent, "target_map", "跨图出口没有配置目标地图"))
			continue
		# P-06：出口指向自身地图 = 配置错误（图内传送应使用传送门）
		if tmap == map_name:
			issues.append(_issue("error", map_name, ent, "target_map", "出口指向自身地图（图内传送应使用传送门）"))
			continue
		var target_data: Dictionary = all.get(tmap, {}) if all.has(tmap) else Store.read(m, tmap)
		if target_data.is_empty():
			issues.append(_issue("error", map_name, ent, "target_map",
				"目标地图不存在或无法读取：" + tmap))
			continue
		if tpt == "":
			issues.append(_issue("error", map_name, ent, "target_point",
				"目标地图 %s 已选但未选落点" % tmap))
			continue
		var target_ids := _ids_of(target_data)
		if not target_ids.has(tpt):
			issues.append(_issue("error", map_name, ent, "target_point",
				"目标地图 %s 找不到落点 %s" % [tmap, tpt]))
			continue
		# P-05：出口目标 role 白名单（声明优先，id 回退）
		var peer: Dictionary = target_ids[tpt]
		if not (ManifestScript.has_role(m, str(peer.get("scene", "")), "landing")
				or ManifestScript.has_role(m, str(peer.get("scene", "")), "exit")):
			issues.append(_issue("error", map_name, ent, "target_point",
				"出口的目标 %s 是 %s，应为传送落点或跨图出口" % [tpt, str(peer.get("scene", ""))]))
			continue
		if ManifestScript.has_role(m, str(peer.get("scene", "")), "exit"):
			var pp: Dictionary = peer.get("props", {})
			if str(pp.get("target_map", "")) != map_name or str(pp.get("target_point", "")) != str(ent.get("id", "")):
				issues.append(_issue("error", map_name, ent, "target_point",
					"%s 的出口 %s 没有指回来（对方指向 %s/%s）" % [
						tmap, tpt, str(pp.get("target_map", "")), str(pp.get("target_point", ""))]))

## 汇总有效的跨图出口目标落点，供孤儿落点提示使用。
static func _exit_targets_of(m: Dictionary, all: Dictionary) -> Dictionary:
	var out := {}
	for other_name in all:
		var od: Dictionary = all[other_name]
		for ent in od.get("entities", []):
			if not (ent is Dictionary) or not ManifestScript.has_role(m, str(ent.get("scene", "")), "exit"):
				continue
			var pp: Dictionary = ent.get("props", {})
			var tm := str(pp.get("target_map", ""))
			var tp := str(pp.get("target_point", ""))
			if tm == "" or tp == "" or tm == str(other_name) or not all.has(tm):
				continue
			var target_ids := _ids_of(all[tm])
			if not target_ids.has(tp):
				continue
			var target: Dictionary = target_ids[tp]
			if not ManifestScript.has_role(m, str(target.get("scene", "")), "landing"):
				continue
			if not out.has(tm):
				out[tm] = {}
			(out[tm] as Dictionary)[tp] = true
	return out

static func _collect_orphan_points(m: Dictionary, map_name: String, data: Dictionary, ids: Dictionary, issues: Array, exit_used: Dictionary) -> void:
	var used := {}
	for ent in data.get("entities", []):
		if not (ent is Dictionary) or not ManifestScript.has_role(m, str(ent.get("scene", "")), "portal"):
			continue
		var tpt := str(ent.get("props", {}).get("target_point", ""))
		if ids.has(tpt) and ManifestScript.has_role(m, str((ids[tpt] as Dictionary).get("scene", "")), "landing"):
			used[tpt] = true
	# Other maps' valid exit references also consume this map's spawn points.
	for k in exit_used:
		used[str(k)] = true
	for ent in data.get("entities", []):
		if not (ent is Dictionary) or not ManifestScript.has_role(m, str(ent.get("scene", "")), "landing"):
			continue
		var eid := str(ent.get("id", ""))
		if not used.has(eid):
			issues.append(_issue("warn", map_name, ent, "", "落点 " + eid + " 没有被任何门/出口使用"))

## K24：落点静态占位检查——出生点/落点实体所在格有 collision 格 = 占位被堵。
## 纯数据查询（不是运行时可达性）；文档口径同步：格级占位检查做，运行时路径可达性不做。
static func _collect_landing_blocked(m: Dictionary, map_name: String, data: Dictionary, issues: Array) -> void:
	var solid := {}
	for c in data.get("collision", []):
		if c is Array and (c as Array).size() >= 2:
			solid[Vector2i(int(c[0]), int(c[1]))] = true
	var cells := []
	var sp = data.get("spawn", null)
	if sp is Array and (sp as Array).size() >= 2:
		cells.append(["出生点", int(sp[0]), int(sp[1])])
	for ent in data.get("entities", []):
		if not (ent is Dictionary):
			continue
		if ManifestScript.has_role(m, str(ent.get("scene", "")), "landing"):
			cells.append(["落点 %s" % str(ent.get("id", "")), int(ent.get("x", 0)), int(ent.get("y", 0))])
	for entry in cells:
		if solid.has(Vector2i(int(entry[1]), int(entry[2]))):
			issues.append(_issue("error", map_name, {"id": str(entry[0]), "scene": ""}, "",
				"%s所在格有碰撞（%d,%d）——落点被堵，游戏内会卡死/无法到达" % [str(entry[0]), int(entry[1]), int(entry[2])]))

## 地图改名后，把所有其他地图里 target_map == old 的出口改成 new。
## 返回 {ok, changed: [[map, ent_id], ...], failed: [map, ...]}
static func migrate_map_rename(m: Dictionary, old_name: String, new_name: String) -> Dictionary:
	var changed: Array = []
	var failed: Array = []
	for map_name in Store.list_maps(m):
		if map_name == old_name:
			continue
		var data := Store.read(m, map_name)
		if data.is_empty():
			continue
		var touched := false
		for ent in data.get("entities", []):
			if not (ent is Dictionary) or not ManifestScript.has_role(m, str(ent.get("scene", "")), "exit"):
				continue
			var props: Dictionary = ent.get("props", {})
			if str(props.get("target_map", "")) == old_name:
				props["target_map"] = new_name
				ent["props"] = props
				touched = true
				changed.append([map_name, str(ent.get("id", ""))])
		if touched and not Store.write(m, map_name, data):
			failed.append(map_name)
	return {"ok": failed.is_empty(), "changed": changed, "failed": failed}
