extends RefCounted
## 声明池缓存指纹（F1/P03）：项目目录 + 池的递归结构哈希。
##
## 各声明域（assets/functions/steps/conditions/triggers/audio）的归一化视图缓存
## 原先用 `JSON.stringify(整个池)` 当指纹——1000 条资产上每次访问约 3 ms，
## 而绘制热路径每帧按实例访问几十上百次，等于每帧几秒。
## `Variant.hash()` 是引擎内的递归结构哈希：同内容同哈希、嵌套改动必变
## （探针实测：数组里套字典再套数组，深层改一格哈希就变），
## 1000 条约 65 µs，快两个数量级。哈希碰撞（2^-32 量级）表现为一次陈旧视图，
## 下一次池内容变化即自愈——它替换的不是正确性检查，而是「指纹本身的成本」。

## 池缺键时返回带标记的串，与「池存在但为空」区分，避免旧缓存误命中。
## 数组与 {id: body} 两种写法都认。
static func of(m: Dictionary, key: String) -> String:
	var dir := str(m.get("_dir", ""))
	var pool = m.get(key, null)
	if pool is Array:
		return "%s\u0001%d" % [dir, (pool as Array).hash()]
	if pool is Dictionary:
		return "%s\u0001%d" % [dir, (pool as Dictionary).hash()]
	return "%s\u0001-" % dir