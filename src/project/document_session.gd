extends RefCounted
## 当前地图的身份、操作令牌和磁盘基线。

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

## 抬文档令牌：任何「可能让旧请求失效」的动作（开图/切项目）都先调它。
## 返回新代次，调用方拿它做 _doc_stale 判定。
func bump() -> int:
	generation += 1
	return generation

## 开图/切项目：换文档身份，更新磁盘基线，令牌 +1。
## 传空 name_ = 关文档（无图状态）。返回新代次。
func open_doc(root: String, code: String, name_: String, path: String, digest := "", mtime := 0) -> int:
	set_identity(root, code, name_, path, digest, mtime)
	revision = 0
	return bump()

## 只换身份与基线，不动令牌（新建图的收尾：代次已在 _begin_doc_op 抬过）。
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
