extends RefCounted
## Shared drop-down for authored destinations owned by a map or project.

const Widgets := preload("res://src/ui/field_widgets.gd")
const Targets := preload("res://src/project/startup_targets.gd")

static func build(manifest: Dictionary, domains: Dictionary, value: Variant, set_value: Callable, working_map := {}) -> Control:
	var decl := domains.merged({"kind": "input", "type": "flow_target"}, true)
	var options := func(_decl: Dictionary) -> Array:
		return Targets.destination_options(manifest, domains, working_map).map(func(row):
			return {"v": JSON.stringify(row.target), "t": row.name})
	return Widgets.build(decl, value, set_value, options).ctl
