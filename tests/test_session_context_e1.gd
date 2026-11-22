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
func test_has_code() -> void:
	var ents := [{"code": "K111"}, {"code": "K222"}]
	ok(SessionContext.has_code(ents, "K222"), "命中")
	ok(not SessionContext.has_code(ents, "K333"), "未命中")
	ok(not SessionContext.has_code(ents, ""), "空码不算命中")

## 地图身份：有码比码，无码比图名（老图）
func test_same_map_identity() -> void:
	ok(SessionContext.same_map({"map_code": "M111", "map_name": "a"}, "M111", "b"), "码一致即同图（改名不丢）")
	ok(not SessionContext.same_map({"map_code": "M111", "map_name": "a"}, "M222", "a"), "码不同 = 另一张图")
	ok(SessionContext.same_map({"map_code": "", "map_name": "a"}, "", "a"), "老图按名比")
	ok(not SessionContext.same_map({"map_code": "", "map_name": "a"}, "", "b"), "老图名不同")

## 画布选点只给「同图实例引用」：跨图配对（map_ref 域）不给
func test_canvas_pick_scope() -> void:
	ok(FieldWidgets.wants_canvas_pick({"kind": "choice", "source": "entity_inst:spawn"}), "同图实例引用")
	ok(FieldWidgets.wants_canvas_pick({"type": "entity_ref", "of": "spawn"}), "entity_ref 无 mapField")
	ok(not FieldWidgets.wants_canvas_pick({"type": "entity_ref", "of": "spawn", "mapField": "target_map"}),
		"配对地图字段：目标图不一定是本图")
	ok(not FieldWidgets.wants_canvas_pick({"type": "map_ref"}), "地图引用不是实例")
	ok(not FieldWidgets.wants_canvas_pick({"kind": "input", "type": "int"}), "普通数值字段")

## 选点候选的类型白名单来自声明的 of
func test_canvas_pick_types() -> void:
	eq(FieldWidgets.canvas_pick_types({"type": "entity_ref", "of": "spawn,boss"}),
		["spawn", "boss"], "of 白名单")
	eq(FieldWidgets.canvas_pick_types({"type": "entity_ref"}), [], "未声明 of = 不限")
