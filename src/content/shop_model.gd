extends RefCounted
## 商店资源校验：条目物品引用、重复物品、价格与库存合法性。
## known_items 是 {id: true} 形式的物品白名单；为空时跳过物品存在性检查。

const MODEL := "shop"

static func validate(shop: Dictionary, known_items: Dictionary = {}) -> Array:
	var issues: Array = []
	var entries = shop.get("entries", [])
	if not (entries is Array):
		issues.append(_issue("error", "entries", "商店条目必须是数组"))
		return issues
	var seen := {}
	for i in (entries as Array).size():
		var entry = (entries as Array)[i]
		var field := "entries[%d]" % i
		if not (entry is Dictionary):
			issues.append(_issue("error", field, "条目必须是对象"))
			continue
		var item := str((entry as Dictionary).get("item", ""))
		if item == "":
			issues.append(_issue("error", field + ".item", "条目缺少物品 id"))
		elif seen.has(item):
			issues.append(_issue("error", field + ".item", "物品重复: " + item))
		else:
			seen[item] = true
			if not known_items.is_empty() and not known_items.has(item):
				issues.append(_issue("error", field + ".item", "物品不存在: " + item))
		var price = (entry as Dictionary).get("price", 0)
		if not _is_number(price):
			issues.append(_issue("error", field + ".price", "价格必须是数字"))
		elif float(price) < 0.0:
			issues.append(_issue("error", field + ".price", "价格不能为负: " + str(price)))
		var stock = (entry as Dictionary).get("stock", -1)
		if not _is_number(stock):
			issues.append(_issue("error", field + ".stock", "库存必须是数字"))
		elif float(stock) != floorf(float(stock)) or float(stock) < -1.0:
			issues.append(_issue("error", field + ".stock", "库存必须为整数，且只能是 -1（无限）或 >= 0"))
	return issues

## 从清单 items 生成物品白名单。
static func item_index(manifest: Dictionary) -> Dictionary:
	var out := {}
	for item in manifest.get("items", []):
		if item is Dictionary and str(item.get("id", "")) != "":
			out[str(item.get("id", ""))] = item
	return out

static func _is_number(value) -> bool:
	return value is int or value is float

static func _issue(level: String, field: String, message: String) -> Dictionary:
	return {"level": level, "model": MODEL, "field": field, "message": message}