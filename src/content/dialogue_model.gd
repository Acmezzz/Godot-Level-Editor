extends RefCounted
## 对话资源校验：节点 id、起始节点、分支目标、终止节点与可达性。
## 纯逻辑，不读写盘；issue 结构与 map_validate 一致（level/field/message）。

const MODEL := "dialogue"

static func validate(dialogue: Dictionary) -> Array:
	var issues: Array = []
	var raw_nodes = dialogue.get("nodes", [])
	if not (raw_nodes is Array) or (raw_nodes as Array).is_empty():
		issues.append(_issue("error", "nodes", "对话至少需要一个节点"))
		return issues
	var ids := {}
	for node in raw_nodes:
		if not (node is Dictionary):
			issues.append(_issue("error", "nodes", "节点必须是对象"))
			continue
		var nid := str((node as Dictionary).get("id", ""))
		if nid == "":
			issues.append(_issue("error", "nodes", "节点缺少 id"))
			continue
		if ids.has(nid):
			issues.append(_issue("error", nid, "节点 id 重复: " + nid))
			continue
		ids[nid] = node
	if ids.is_empty():
		return issues
	var start := str(dialogue.get("start", ""))
	if start == "":
		issues.append(_issue("error", "start", "对话缺少起始节点"))
	elif not ids.has(start):
		issues.append(_issue("error", "start", "起始节点不存在: " + start))
	_collect_edges(ids, issues)
	if start != "" and ids.has(start):
		_collect_reachability(ids, start, issues)
	return issues

## 检查 next 与选项目标是否悬空；选项必须给出目标节点。
static func _collect_edges(ids: Dictionary, issues: Array) -> void:
	for nid in ids:
		var node: Dictionary = ids[nid]
		var nxt := str(node.get("next", ""))
		if nxt != "" and not ids.has(nxt):
			issues.append(_issue("error", nid + ".next", "指向不存在的节点: " + nxt))
		var choices = node.get("choices", [])
		if not (choices is Array):
			continue
		for i in (choices as Array).size():
			var choice = (choices as Array)[i]
			var field := "%s.choices[%d]" % [nid, i]
			if not (choice is Dictionary):
				issues.append(_issue("error", field, "选项必须是对象"))
				continue
			var cnext := str((choice as Dictionary).get("next", ""))
			if cnext == "":
				issues.append(_issue("error", field + ".next", "选项缺少目标节点"))
			elif not ids.has(cnext):
				issues.append(_issue("error", field + ".next", "指向不存在的节点: " + cnext))

## 从起始节点广度遍历：报告不可达节点，并在没有可达终止节点时给警告。
static func _collect_reachability(ids: Dictionary, start: String, issues: Array) -> void:
	var seen := {}
	var queue: Array = [start]
	var has_terminal := false
	while not queue.is_empty():
		var cur := str(queue.pop_front())
		if seen.has(cur) or not ids.has(cur):
			continue
		seen[cur] = true
		var node: Dictionary = ids[cur]
		var targets := _targets_of(node)
		if targets.is_empty() or bool(node.get("end", false)):
			has_terminal = true
		for tgt in targets:
			if not seen.has(tgt):
				queue.append(tgt)
	for nid in ids:
		if not seen.has(nid):
			issues.append(_issue("warn", nid, "节点不可到达: " + str(nid)))
	if not has_terminal:
		issues.append(_issue("warn", "nodes", "对话没有可达的终止节点"))

static func _targets_of(node: Dictionary) -> Array:
	var out: Array = []
	var nxt := str(node.get("next", ""))
	if nxt != "":
		out.append(nxt)
	var choices = node.get("choices", [])
	if choices is Array:
		for choice in choices:
			if choice is Dictionary:
				var cnext := str((choice as Dictionary).get("next", ""))
				if cnext != "":
					out.append(cnext)
	return out

static func _issue(level: String, field: String, message: String) -> Dictionary:
	return {"level": level, "model": MODEL, "field": field, "message": message}