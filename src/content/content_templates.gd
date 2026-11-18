extends RefCounted
## 新建资源模板：创建即可用，不是空壳。
## 全屏内容库与实例内容抽屉共用，避免两处各写一份模板而慢慢跑偏。

static func for_kind(kind: String) -> Dictionary:
	match kind:
		"dialogues":
			return {"version": 1, "start": "n1", "nodes": [
				{"id": "n1", "speaker": "", "text": "", "next": ""}]}
		"events":
			return {"version": 1, "steps": []}
		"shops":
			return {"version": 1, "entries": []}
		"defs":
			return {"version": 1, "name": "", "components": {}}
		_:
			return {"version": 1}

## 每种资源的 id 前缀（新建时自动拼编号）
static func prefix_for(kind: String) -> String:
	match kind:
		"dialogues": return "dlg"
		"events": return "evt"
		"shops": return "shop"
		"defs": return "def"
		_: return "new"
