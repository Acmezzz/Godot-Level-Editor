extends RefCounted
## DocumentSession（§7.1）：一个文档（当前地图）的工作副本。
## 持有地图码/图名、切图代次、修订号、打开基线与暂存内容；
## 提交编排走 document_commit.gd。

var map_code := ""
var map_name := ""
var doc_key := ""
var generation := 0
var revision := 0
var opened_digest := ""
var opened_mtime := 0
var codes_pending := false
var contents := {}

## §7.1 stage_content：登记一条暂存内容（同 ID 覆盖 = 值更新）。返回 {status, error}。
func stage_content(fn_id: String, cid: String, data: Dictionary, ent := "", bind_index := -1, doc := "") -> Dictionary:
	if fn_id == "" or cid == "":
		return {"status": "error", "error": "功能 id 与内容 ID 必须非空"}
	contents[cid] = {"fn_id": fn_id, "data": data, "ent": ent, "bind_index": bind_index, "doc": doc}
	revision += 1
	return {"status": "ok", "error": ""}

## §7.1 snapshot：提交编排的冻结输入。contents 行已按 doc_key 过滤（R02）。
func snapshot() -> Dictionary:
	return {
		"token": "%d-%d" % [generation, revision],
		"revision": revision,
		"map": map_code,
		"map_name": map_name,
		"doc_key": doc_key,
		"opened_digest": opened_digest,
		"manifest_changes": {"codes_pending": codes_pending},
		"contents": rows_for(doc_key),
	}

## 当前文档（doc_key 匹配）的暂存行 [{fn_id, cid, data}]——提交日志/草稿冻结目标用（R04）。
func rows_for(doc: String) -> Array:
	var out: Array = []
	for cid in contents:
		var st: Dictionary = contents[cid]
		if doc != "" and str(st.get("doc", "")) != doc:
			continue
		out.append({"fn_id": str(st.get("fn_id", "")), "cid": str(cid),
			"data": (st.get("data", {}) as Dictionary).duplicate(true)})
	return out
