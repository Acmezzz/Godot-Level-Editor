extends RefCounted
## 当前地图的操作令牌与上次打开或保存的磁盘摘要。

var generation := 0
var revision := 0
var opened_digest := ""

func bump() -> int:
	generation += 1
	return generation

func stale(gen: int) -> bool:
	return gen != generation
