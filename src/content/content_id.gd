extends RefCounted
## 分层身份码：地图-实体-实例-功能-内容 五段。
## 前三段是各层实体的稳定身份码（4 位，出生时发放，存在载体上，改名不变）；
## 功能段保留功能人类 id（显示壳，人眼可读）；真正的执行引用（functions[].fn、
## 内容 "function"、fields 键）用 4 位执行码——见 function_decl.gd。
## 内容段 6 位。名字（地图名/类型名/编号 e_N）只是展示层，不进 ID。
## 不挂 class_name，按项目惯例用 preload 引用。

const ContentStore := preload("res://src/content/content_store.gd")

## 可打印且不含 I/O/0/1 的字符集，长度 32，恰好覆盖 randi() 的低 5 位。
const CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const LAYER_LEN := 4    # 地图/实体/实例段
const CONTENT_LEN := 6  # 内容段

static func _code(n: int) -> String:
	var out := ""
	for _i in n:
		out += CHARS[randi() % CHARS.length()]
	return out

## 各层身份码：出生时发放，存在对应载体上（地图 meta / 清单 entities / 实体 meta）
static func new_map_code() -> String:
	return _code(LAYER_LEN)
static func new_entity_code() -> String:
	return _code(LAYER_LEN)
static func new_inst_code() -> String:
	return _code(LAYER_LEN)

## 功能段 / 字段段的执行码：与地图、实例码同一字符集同一长度。
## 它才是磁盘上的执行引用（地图 functions[].fn、内容 fields 的键）；
## 人类名（功能 id / 字段 id）只负责显示与内容目录名，改名不破数据。
static func new_fn_code() -> String:
	return _code(LAYER_LEN)

## 组装内容 ID：前三段稳定身份 + 功能人类 id，末段 6 位随机码保证唯一。
## 输入含空段（旧数据没发过码）时返回空串，不产出脏 ID。
static func content_id(map_code: String, ent_code: String, inst_code: String, fn_id: String) -> String:
	if map_code == "" or ent_code == "" or inst_code == "" or fn_id == "":
		return ""
	return "%s-%s-%s-%s-%s" % [map_code, ent_code, inst_code, fn_id, _code(CONTENT_LEN)]

## 在候选 ID 上查重；冲突时只换末段内容码（保留分层身份前缀），用尽次数返回空串。
static func unique(m: Dictionary, fn_id: String, candidate: String, max_tries := 32) -> String:
	if candidate == "":
		return ""
	var taken := {}
	for id in ContentStore.list_ids(m, fn_id):
		taken[str(id)] = true
	# 最后一段是内容码；用 rfind 定位，前缀里即使有连字符也不会被切开。
	var cut := candidate.rfind("-")
	var prefix := candidate if cut < 0 else candidate.substr(0, cut)
	for i in maxi(max_tries, 1):
		var id := candidate if i == 0 else prefix + "-" + _code(CONTENT_LEN)
		if not taken.has(id) and ContentStore.is_valid_id(id):
			return id
	return ""
