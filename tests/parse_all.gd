extends SceneTree

## 全量解析门禁：src 下所有 GDScript + tests 下所有测试脚本逐个 load。
## 目的只有一个——任何文件语法坏了立刻暴露。新增 src 文件时必须登记到这里。

const SRC := [
	"res://src/app.gd",
	"res://src/manifest.gd", "res://src/manifest_validation.gd",
	"res://src/map_data_validation.gd", "res://src/playtest.gd",
	"res://src/map_store.gd", "res://src/cross_map.gd",
	"res://src/map_validate.gd", "res://src/map_export.gd",
	"res://src/level_list.gd",
	"res://src/core/constants.gd", "res://src/core/editor_state.gd",
	"res://src/core/undo_history.gd", "res://src/core/side_actions.gd",
	"res://src/canvas/editor_canvas.gd", "res://src/canvas/collision_view.gd",
	"res://src/canvas/selection_ops.gd", "res://src/canvas/canvas_draw.gd",
	"res://src/canvas/canvas_input.gd", "res://src/canvas/tool_ops.gd",
	"res://src/canvas/tileset_cache.gd", "res://src/canvas/bg_preview.gd",
	"res://src/ui/map_thumb.gd", "res://src/ui/side_panel.gd",
	"res://src/ui/world_map_view.gd", "res://src/ui/asset_panel.gd",
	"res://src/ui/editor_layout.gd", "res://src/ui/props_panel.gd",
	"res://src/ui/cross_map_picker.gd", "res://src/ui/map_file.gd",
	"res://src/ui/palette_panel.gd", "res://src/ui/content_panel.gd",
	"res://src/ui/content_dock.gd", "res://src/ui/project_shell.gd",
	"res://src/ui/content_editor.gd",
	"res://src/ui/manifest_panel.gd", "res://src/ui/levels_panel.gd", "res://src/ui/collapsible.gd",
	"res://src/ui/content_editors/dialogue_editor.gd",
	"res://src/ui/content_editors/event_editor.gd",
	"res://src/ui/content_editors/shop_editor.gd",
	"res://src/ui/content_editors/def_editor.gd",
	"res://src/content/content_store.gd", "res://src/content/dialogue_model.gd",
	"res://src/content/event_model.gd", "res://src/content/shop_model.gd",
	"res://src/content/def_model.gd", "res://src/content/content_validate.gd",
	"res://src/content/builtin_kinds.gd", "res://src/content/content_templates.gd",
	"res://src/content/content_id.gd",
]

const TESTS := [
	"res://tests/parse_all.gd",
	"res://tests/data_layer_test.gd", "res://tests/content_model_test.gd", "res://tests/content_panel_test.gd",
	"res://tests/def_regression_test.gd", "res://tests/entity_copy_regression_test.gd",
	"res://tests/props_undo_regression_test.gd",
	"res://tests/portal_mode_regression_test.gd", "res://tests/shortcut_test.gd",
]

func _init() -> void:
	var errs := 0
	for path in SRC + TESTS:
		var script = load(path)
		if script == null or not script.can_instantiate():
			errs += 1
			print("PARSE_FAIL ", path)
		else:
			print("PARSE_OK ", path)
	quit(errs)