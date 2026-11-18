extends RefCounted
## 分层内容 ID 生成器：地图-实体-实例-功能-随机码。
## 不挂 class_name，按项目惯例用 preload 引用；随机码去掉易混的 I/O/0/1。

const ContentStore := preload("res://src/content/content_store.gd")

## 可打印且不含 I/O/0/1 的字符集，长度 32，恰好覆盖 randi() 的低 5 位。
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_LEN := 6

static func _random_code() -> String:
	var out := ""
	for _i in CODE_LEN:
		out += CODE_CHARS[randi() % CODE_CHARS.length()]
	return out

## 生成候选 ID；输入片段拼出不合法的整体 id 时返回空串，不产出脏数据。
static func make(map_name: String, ent_type: String, inst_id: String, fn_id: String) -> String:
	var out := "%s-%s-%s-%s-%s" % [map_name, ent_type, inst_id, fn_id, _random_code()]
	return out if ContentStore.is_valid_id(out) else ""

## 在候选 ID 上查重；冲突时只换末尾随机码（保留分层前缀），用尽次数返回空串。
static func unique(m: Dictionary, kind: String, candidate: String, max_tries := 32) -> String:
	if candidate == "":
		return ""
	var taken := {}
	for id in ContentStore.list_ids(m, kind):
		taken[str(id)] = true
	# 最后一段是随机码；用 rsplit 定位，前缀里即使有连字符也不会被切开。
	var cut := candidate.rfind("-")
	var prefix := candidate if cut < 0 else candidate.substr(0, cut)
	for i in maxi(max_tries, 1):
		var id := candidate if i == 0 else prefix + "-" + _random_code()
		if not taken.has(id) and ContentStore.is_valid_id(id):
			return id
	return ""
