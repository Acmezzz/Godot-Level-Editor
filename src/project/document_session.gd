extends RefCounted
## DocumentSession（§4.4-2）：一个文档（当前地图）的**常驻**工作副本。
## 生命周期跟着「打开/新建/改名/保存/切项目」，一次提交不重建它——
## 提交只是读它的一份冻结快照（snapshot）。持有：
##   项目身份 project_root / 文档令牌 (generation, revision) / 图身份 (code, name, path)
##   / 正式基线 (opened_digest, opened_mtime) / 暂存内容 contents / 清单补码标记 codes_pending。
## 提交编排走 document_commit.gd；本类只管「当前这份文档现在长什么样」。

var project_root := ""
var map_code := ""
var map_name := ""
var map_path := ""
var doc_key := ""
## 文档令牌：generation 每次开图/切项目自增（旧请求据此作废），revision 每次改动自增。
var generation := 0
var revision := 0
## 正式基线：打开/上次保存后磁盘上那份文件的摘要与 mtime（外部改动检测的锚点）。
var opened_digest := ""
var opened_mtime := 0
var codes_pending := false
var contents := {}

## 抬文档令牌：任何「可能让旧请求失效」的动作（开图/切项目）都先调它。
## 返回新代次，调用方拿它做 _doc_stale 判定。
func bump() -> int:
	generation += 1
	return generation

## 开图/切项目：换文档身份，清基线与暂存，令牌 +1。
## 传空 name_ = 关文档（无图状态）。返回新代次。
func open_doc(root: String, code: String, name_: String, path: String, digest := "", mtime := 0) -> int:
	set_identity(root, code, name_, path, digest, mtime)
	codes_pending = false
	contents.clear()
	revision = 0
	return bump()

## 只换身份与基线，不动暂存与令牌（新建图的收尾：代次已在 _begin_doc_op 抬过）。
func set_identity(root: String, code: String, name_: String, path: String, digest := "", mtime := 0) -> void:
	project_root = root
	map_code = code
	map_name = name_
	map_path = path
	doc_key = root.path_join(code if code != "" else name_)
	opened_digest = digest
	opened_mtime = mtime

## 改名/另存：图身份与基线一起换（文档还是同一份，令牌不动）。
func rename_doc(name_: String, path: String, digest := "", mtime := 0) -> void:
	map_name = name_
	map_path = path
	doc_key = project_root.path_join(map_code if map_code != "" else name_)
	opened_digest = digest
	opened_mtime = mtime

## 保存成功：基线前移（此后外部改动 = 相对这次写入的内容）。
func note_saved(path: String, digest: String, mtime: int) -> void:
	map_path = path
	opened_digest = digest
	opened_mtime = mtime

## 本次请求是否已过期（期间又开了别的图/切了项目）。过期请求不得发布图名/路径/基线。
func stale(gen: int) -> bool:
	return gen != generation

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
		"map_path": map_path,
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
