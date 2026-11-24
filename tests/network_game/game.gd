extends SceneTree
## Runtime owns the stock and dispatch rules. No editor scripts are loaded.

var manifest_path := "res://editor/editor_manifest.json"
var request := {}
var map_code := ""
var nodes := {}
var arrivals: Array[Dictionary] = []

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--editor-playtest="):
			request = JSON.parse_string(Marshalls.base64_to_utf8(arg.substr(arg.find("=") + 1)))
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	map_code = manifest.get("startup", {}).get("target", {}).get("map", "")
	for filename in DirAccess.get_files_at("res://maps"):
		var data = JSON.parse_string(FileAccess.get_file_as_string("res://maps/" + filename))
		if data is Dictionary and data.meta.code == map_code:
			for node in data.objects:
				nodes[node.code] = node
			break
	var source := ""
	for code in nodes:
		if nodes[code].asset == "works":
			source = code
			break
	if source == "":
		finish("The chosen map has no factory")
		return
	var error := dispatch(source)
	finish(error)

func dispatch(source: String) -> String:
	var recipe: Dictionary = nodes[source].props
	var goods := int(recipe.get("batch", 0))
	var resource: String = recipe.get("resource", "")
	for link in recipe.get("routes", []):
		if link.is_empty():
			continue
		if link.map != map_code or link.port != "freight" or not nodes.has(link.inst):
			return "Missing delivery address"
		var order: Dictionary = nodes[link.inst].props
		if order.get("resource") != resource:
			return "Wrong goods for this order"
		var quantity := mini(goods, int(order.demand))
		goods -= quantity
		arrivals.append({"depot": link.inst, "resource": resource, "delivered": quantity,
			"complete": quantity == int(order.demand)})
	return ""

func finish(error: String) -> void:
	var complete := not arrivals.is_empty() and arrivals.all(func(row): return row.complete)
	print("Freight dispatched: ", arrivals)
	if not request.is_empty():
		var report := {"version": 1, "token": request.token, "status": "ready" if error == "" else "error",
			"message": error, "mapDigest": "", "manifestDigest": FileAccess.get_sha256(manifest_path),
			"result": {"map": map_code, "arrivals": arrivals, "won": complete}}
		var file := FileAccess.open(request.path + ".tmp", FileAccess.WRITE)
		file.store_string(JSON.stringify(report))
		file.close()
		DirAccess.rename_absolute(request.path + ".tmp", request.path)
	quit(0 if error == "" else 1)
