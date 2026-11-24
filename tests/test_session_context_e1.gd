extends "res://tests/_suite_base.gd"
## E1：视图切换的身份校验与会话记忆（纯逻辑部分，无 UI）。

const SessionContext := preload("res://src/ui/session_context.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")

func _fns() -> Array:
	return [{"fn": "A111", "content": "c1"}, {"fn": "B222", "content": ""}]

## 展开的功能按执行码找回；换绑/删功能 → -1（不猜邻近下标）
func test_fn_index_by_code() -> void:
	eq(SessionContext.fn_index_of(_fns(), "B222"), 1, "按执行码定位")
	eq(SessionContext.fn_index_of(_fns(), "Z999"), -1, "未知码不猜")
	eq(SessionContext.fn_index_of(_fns(), ""), -1, "空码 = 未展开")
	eq(SessionContext.fn_index_of([], "A111"), -1, "空绑定数组")

## 步骤下标收敛：超出当前步数落回最后一步；未选中保持 -1；空数组一律 -1
func test_step_index_clamp() -> void:
	eq(SessionContext.step_index(5, 3), 2, "删步骤后收敛到末项")
	eq(SessionContext.step_index(1, 3), 1, "合法下标不动")
	eq(SessionContext.step_index(-1, 3), -1, "未选中保持 -1")
	eq(SessionContext.step_index(0, 0), -1, "空步骤数组")

## 实例码存在性（空码不算命中）
