extends RefCounted
## 跨图落点/出口配对的纯数据规划：不写盘、不碰 UI，便于 headless 测试。
## app.gd 负责把返回的 data 与 unbind 列表落盘并做失败回滚。

const Store := preload("res://src/map_store.gd")
const ManifestScript := preload("res://src/manifest.gd")

## 规划一次跨图点选。
## 返回：
##   {ok, error, data, id, acted("reuse"/"new"/"pair"), unbind:[[map, exit_id, peer_map, peer_id], ...],
##    unbind_local:[exit_id, ...]  ← 旧对端在本地图：调用方只清内存 props（未保存修改不能被写盘覆盖）}
## data 是目标地图修改后的完整数据（调用方负责写盘）。
static func plan_pick(
		m: Dictionary,
		tmap: String,
		own_map: String,
		own_id: String,
		current_scene: String,
		picked_id: String,
		picked_scene: String,
		cell: Vector2i) -> Dictionary:
	if tmap == "":
		return {"ok": false, "error": "先选目标地图"}
	if tmap == own_map:
		return {"ok": false, "error": "目标地图不能是当前地图（图内传送请用传送门）"}
	# role 声明优先、id 回退（模型阶段 1）：可复用 = landing/exit；只有 exit↔exit 配对
	if picked_id != "" and not (ManifestScript.has_role(m, picked_scene, "landing")
			or ManifestScript.has_role(m, picked_scene, "exit")):
		return {"ok": false, "error": "这里只能复用传送落点或跨图出口"}
	if ManifestScript.has_role(m, picked_scene, "exit") and not ManifestScript.has_role(m, current_scene, "exit"):
		return {"ok": false, "error": "只有跨图出口可以与另一张地图的出口配对"}
	if own_id == "":
		return {"ok": false, "error": "当前实体还没有 id，无法建立连接"}

	var data := Store.read(m, tmap)
	if data.is_empty():
		return {"ok": false, "error": "找不到或无法读取目标地图: " + tmap}

	var ents: Array = data.get("entities", [])
	var chosen_id := picked_id
	var acted := "reuse"
	var unbind: Array = []
	var unbind_local: Array = []   # 旧对端在本地图的出口 id：调用方清内存 props

	if chosen_id == "":
		chosen_id = Store.next_entity_id(data)
		ents.append({"scene": ManifestScript.id_for_role(m, "landing"), "id": chosen_id, "x": cell.x, "y": cell.y, "props": {}})
		acted = "new"
	elif ManifestScript.has_role(m, picked_scene, "exit"):
		var target := Store.find_entity(data, chosen_id)
		if target.is_empty():
			return {"ok": false, "error": "目标地图里找不到出口 " + chosen_id}
		var old_peer: Dictionary = target.get("props", {})
		var old_peer_map := str(old_peer.get("target_map", ""))
		var old_peer_id := str(old_peer.get("target_point", ""))
		# 目标出口原来连着别的图：把对端也解绑，避免一对多残留
		# 对端就是自己地图时不解绑：本地仍有未保存修改，写盘会把它们覆盖掉
		if old_peer_map != "" and old_peer_id != "":
			if old_peer_map == tmap:
				# BUG-10：旧对端就在目标图里——直接改本次要写盘的 data，否则目标图内
				# 残留指向 tmap/chosen_id 的单向引用，校验报「没有指回来」。
				var old_t := Store.find_entity(data, old_peer_id)
				if not old_t.is_empty() and ManifestScript.has_role(m, str((old_t as Dictionary).get("scene", "")), "exit"):
					var op: Dictionary = (old_t as Dictionary).get("props", {})
					op.erase("target_map")
					op.erase("target_point")
					(old_t as Dictionary)["props"] = op
			elif old_peer_map != own_map:
				unbind.append([old_peer_map, old_peer_id, tmap, chosen_id])
			else:
				# 旧对端在本地图：不能由写盘覆盖（本地有未保存修改），交给调用方清内存
				unbind_local.append(old_peer_id)
		var props: Dictionary = target.get("props", {})
		props["target_map"] = own_map
		props["target_point"] = own_id
		target["props"] = props
		acted = "pair"

	if acted != "pair":
		data["entities"] = ents
	return {"ok": true, "data": data, "id": chosen_id, "acted": acted, "unbind": unbind, "unbind_local": unbind_local}
