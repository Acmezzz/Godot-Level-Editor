extends "res://tests/_suite_base.gd"

const Delta := preload("res://src/map/generated_chunk_delta.gd")
const Generated := preload("res://src/map/generated_map_merge.gd")
const Maps := preload("res://src/map/map_store.gd")

func test_stable_identity_conflict_rejects_the_entire_patch() -> void:
	var base := Maps.new_map("seed", 8, 8, "orthogonal")
	var row := {"asset": "door", "code": "GATE", "layer": base.meta.layers[0].id,
		"x": 2, "y": 2, "props": {"obsolete": true}}
	base.objects.append(row)
	var authored := base.duplicate(true)
	authored.objects[0].erase("props")
	authored.collision = [{"x": 2, "y": 3}]
	Generated.attach(authored, base, "demo", {})
	var plan := Delta.compile(authored, Delta.CONTENT)
	eq(plan.error, "", "compile grid and object edits together")
	var runtime := base.duplicate(true)
	runtime.objects[0].props["seedOnly"] = "keep"
	var patched := Delta.apply(runtime, plan)
	eq(patched.error, "", "same logical instance across seeds")
	eq(patched.map.objects[0].props, {"seedOnly": "keep"}, "deleting the last authored prop keeps unrelated seed props")
	runtime.objects[0].asset = "different"
	var snapshot := runtime.duplicate(true)
	var mismatch := Delta.apply(runtime, plan)
	ok(mismatch.error.contains("GATE") and not mismatch.has("map") and runtime == snapshot,
		"same code with a different asset does not apply even the grid changes")
	runtime.objects.clear()
	var missing := Delta.apply(runtime, plan)
	ok(missing.error.contains("GATE") and not missing.has("map"), "missing edited instance fails without creating it")
