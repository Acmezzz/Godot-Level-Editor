extends "res://tests/_suite_base.gd"

const Delta := preload("res://src/map/generated_chunk_delta.gd")
const Generated := preload("res://src/map/generated_map_merge.gd")
const Maps := preload("res://src/map/map_store.gd")

func test_content_delta_applies_map_flow_by_slot() -> void:
	var base := Maps.new_map("authored", 8, 8, "orthogonal")
	base.meta.flowOutputs = {"exit": {"map": "HUB"}, "obsolete": {"view": "hint"}}
	base.meta.contentSlots = {"round": {"function": "rules", "content": "standard"}}
	var authored := base.duplicate(true)
	authored.meta.flowOutputs = {"exit": {"view": "score"}, "bonus": {"map": "BONUS"}}
	authored.meta.contentSlots.round.content = "ranked"
	Generated.attach(authored, base, "demo", {})
	var runtime := base.duplicate(true)
	runtime.meta.code = "seed-7"
	runtime.meta.flowOutputs.exit = {"map": "HUB", "inst": "DOOR7", "port": "entry"}
	runtime.meta.flowOutputs.seed = {"view": "seed-hint"}
	runtime.meta.contentSlots.seed = {"function": "rules", "content": "seed-7"}
	var original := runtime.duplicate(true)
	var result := Delta.apply(runtime, Delta.compile(authored, Delta.CONTENT))
	eq(result.error, "", "flow edits apply on top of a generated seed")
	if result.has("map"):
		eq(result.map.meta.flowOutputs, {
			"exit": {"view": "score"}, "bonus": {"map": "BONUS"}, "seed": {"view": "seed-hint"},
		}, "replace each changed target as a whole, remove old links and keep seed-only links")
		eq(result.map.meta.contentSlots, {
			"round": {"function": "rules", "content": "ranked"},
			"seed": {"function": "rules", "content": "seed-7"},
		}, "use the authored rules alongside seed-only rules")
		eq(result.map.meta.code, "seed-7", "the game retains its runtime identity")
	eq(runtime, original, "the generated input remains unchanged")
	var grid := Delta.apply(runtime, Delta.compile(authored, Delta.GRID))
	eq(grid.error, "", "the grid-only mode still applies")
	if grid.has("map"):
		eq(grid.map.meta.flowOutputs, original.meta.flowOutputs, "the grid-only mode does not change flow")
		eq(grid.map.meta.contentSlots, original.meta.contentSlots, "the grid-only mode does not change rules")

func test_layer_frame_and_grid_changes_have_distinct_overlay_rules() -> void:
	var base := Maps.new_map("seed", 8, 8, "orthogonal")
	var layer: String = base.meta.layers[0].id
	base.tiles[layer] = [[1, 2, "terrain", 0, 0, 0]]
	var authored := base.duplicate(true)
	authored.meta.layers[0].offset = [12, 4]
	authored.meta.layers[0].scale = 1.5
	authored.meta.layers[0].parallax = 0.75
	Generated.attach(authored, base, "demo", {})
	var runtime := base.duplicate(true)
	runtime.tiles[layer].append([4, 3, "terrain", 0, 0, 0])
	var result := Delta.apply(runtime, Delta.compile(authored, Delta.CONTENT))
	eq(result.error, "", "the new frame applies to the whole compatible seed layer")
	if result.has("map"):
		eq(result.map.tiles[layer], runtime.tiles[layer], "tile coordinates remain local")
		eq(result.map.meta.layers[0], authored.meta.layers[0], "all edited frame parameters are carried over")
		ok(not runtime.meta.layers[0].has("offset"), "runtime input is untouched")
	authored.meta.layers[0].tileGrid = {"gridProjection": "isometric"}
	authored.tiles[layer] = [[2, 1, "terrain", 0, 0, 0]]
	var migration := Delta.compile(authored, Delta.CONTENT)
	var conflict := Delta.apply(runtime, migration)
	ok(not conflict.has("map") and conflict.error.contains("格系"), "do not reinterpret a seed's extra tiles")
	result = Delta.apply(base, migration)
	eq(result.error, "", "an unchanged tile table can be replaced with the authored migration")
	if result.has("map"):
		eq(result.map.tiles[layer], authored.tiles[layer], "use only the migrated tile coordinates")
	ok(not Delta.compile(authored, Delta.GRID).error.is_empty(), "grid-only mode does not modify the frame")

func test_content_delta_changes_layer_stack_without_discarding_seed_tiles() -> void:
	var base := Maps.new_map("seed", 8, 8, "orthogonal")
	base.meta.layers = [{"id": "base", "name": "Base"}, {"id": "strip", "name": "Strip"}, {"id": "back", "name": "Back"}]
	base.tiles["strip"] = [[1, 2, "terrain", 0, 0, 0]]
	var authored := base.duplicate(true)
	authored.meta.layers.remove_at(1)
	authored.meta.layers.insert(1, {"id": "fx", "name": "Effects", "tileGrid": {"gridProjection": "isometric"}})
	authored.tiles.erase("strip")
	authored.tiles["fx"] = [[2, 1, "terrain", 0, 0, 0]]
	Generated.attach(authored, base, "demo", {})
	var plan := Delta.compile(authored, Delta.CONTENT)
	eq(plan.error, "", "content overlay permits a new independent grid")
	var runtime := base.duplicate(true)
	runtime.tiles["back"] = [[4, 4, "terrain", 0, 0, 0]]
	var result := Delta.apply(runtime, plan)
	eq(result.error, "", "merge the new stack into a compatible seed")
	if result.has("map"):
		eq(result.map.meta.layers.map(func(layer): return layer.id), ["base", "fx", "back"], "authored layer order")
		eq(result.map.tiles.fx, authored.tiles.fx, "new layer tiles come from the author")
		eq(result.map.tiles.back, runtime.tiles.back, "seed tiles on another layer survive")
		ok(not result.map.tiles.has("strip"), "removed layer no longer owns a tile table")
	runtime.tiles.strip.append([3, 3, "terrain", 0, 0, 0])
	var conflict := Delta.apply(runtime, plan)
	ok(not conflict.has("map") and conflict.error.contains("strip"), "do not drop seed-specific tiles")

func test_graph_delta_keeps_seed_topology_and_rejects_dangling_endpoints() -> void:
	var base := Maps.new_map("seed", 8, 8, "orthogonal")
	var poly := [[0, 0], [8, 0], [0, 8]]
	base.meta.cellGraph = {"spaces": {"deck": {"origin": [0, 0]}},
		"cells": [{"id": "a", "polygon": poly, "space": "deck", "neighbors": ["b"]},
			{"id": "b", "polygon": poly}],
		"edges": [{"id": "link", "from": "a", "to": "b", "props": {"cost": 9}}]}
	var authored := base.duplicate(true)
	var graph: Dictionary = authored.meta.cellGraph
	graph.spaces.deck.origin = [12, 5]
	graph.cells.pop_back()
	graph.cells.append({"id": "c", "polygon": poly})
	graph.cells[0].neighbors = ["c"]
	graph.edges[0].to = "c"
	graph.edges[0].props.cost = 3
	Generated.attach(authored, base, "demo", {})
	var plan := Delta.compile(authored, Delta.CONTENT)
	var runtime := base.duplicate(true)
	graph = runtime.meta.cellGraph
	graph.cells.append({"id": "seed", "polygon": poly})
	graph.cells[0].neighbors.append("seed")
	graph.edges[0].props["seedOnly"] = true
	graph.spaces.deck["name"] = "Seed deck"
	var result := Delta.apply(runtime, plan)
	eq(result.error, "", "merge authored and seed routes")
	if result.has("map"):
		var out: Dictionary = result.map.meta.cellGraph
		eq(out.cells.map(func(row): return row.id), ["a", "seed", "c"], "patch by stable ID")
		eq(out.cells[0].neighbors, ["seed", "c"], "retain seed-only adjacency")
		eq(out.spaces.deck, {"origin": [12, 5], "name": "Seed deck"}, "retain unrelated space fields")
		eq(out.edges[0].props, {"cost": 3, "seedOnly": true}, "retain unrelated edge properties")
	graph.edges.append({"id": "seed-link", "from": "seed", "to": "b"})
	var conflict := Delta.apply(runtime, plan)
	ok(not conflict.has("map") and conflict.error.contains("seed-link"), "do not leave a dangling route")
	eq(graph.edges[0].to, "b", "failed overlay leaves runtime unchanged")

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

func test_anonymous_edits_preserve_seed_decor_and_counts() -> void:
	var base := Maps.new_map("seed", 8, 8, "orthogonal")
	var layer: String = base.meta.layers[0].id
	base.objects = [{"asset": "sign", "x": 1, "y": 2}, {"asset": "sign", "x": 1, "y": 2}]
	var authored := base.duplicate(true)
	authored.objects[0].x = 3
	authored.spawn = [4, 2]
	authored.meta.layers[0].blend = "add"
	Generated.attach(authored, base, "demo", {})
	var plan := Delta.compile(authored, Delta.CONTENT)
	var runtime := base.duplicate(true)
	runtime.objects[0] = {"asset": "sign", "layer": layer, "x": 1.0, "y": 2.0, "visible": true}
	runtime.objects.append({"asset": "sign", "layer": layer, "x": 5, "y": 1})
	runtime.meta.layers[0].ySort = true
	var patched := Delta.apply(runtime, plan)
	eq(patched.error, "", "exact baseline decor can be moved without a code")
	if patched.has("map"):
		eq(patched.map.objects.map(func(row): return row.x), [1, 5, 3], "remove only one copy and append moved placement")
		eq(patched.map.spawn, [4, 2], "apply authored entrance")
		ok(patched.map.meta.layers[0].ySort and patched.map.meta.layers[0].blend == "add",
			"layer style overrides only authored fields")
	runtime.objects = [runtime.objects[2]]
	var conflict := Delta.apply(runtime, plan)
	ok(not conflict.has("map") and conflict.error.contains("无码"), "a different seed cannot silently remove unrelated decor")
	runtime.meta.layers[0].tileGrid = {"gridProjection": "isometric"}
	ok(Delta.apply(runtime, plan).error.contains("图层"), "independent tile projection is part of spatial compatibility")
