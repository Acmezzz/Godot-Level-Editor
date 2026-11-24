extends RefCounted
## Discover assets in the agreed directories. Existing declarations own their IDs and paths.

const Ids := preload("res://src/content/content_id.gd")
const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]
const SOURCES := {
	"assets/tiles": "atlas",
	"assets/images": "texture",
	"assets/entities": "prefab",
}

static func sync(manifest: Dictionary) -> bool:
	var root := str(manifest.get("_dir", ""))
	if root.is_empty():
		return false
	var assets: Array = manifest.get("assets", [])
	var paths := {}
	var codes := {}
	for asset in assets:
		for key in SOURCES.values():
			paths[str(asset.get(key, "")).replace("\\", "/").simplify_path()] = true
		for key in ["id", "code"]:
			codes[str(asset.get(key, "")).to_upper()] = true
	var count := assets.size()
	for folder in SOURCES:
		_discover(root, folder, SOURCES[folder], assets, paths, codes)
	if assets.size() == count:
		return false
	manifest["assets"] = assets
	return true

static func _discover(root: String, folder: String, key: String, assets: Array,
		paths: Dictionary, codes: Dictionary) -> void:
	var directory := DirAccess.open(root.path_join(folder))
	if directory == null:
		return
	for file in directory.get_files():
		if not _matches_kind(file, key):
			continue
		var path := folder.path_join(file)
		if paths.has(path):
			continue
		var id := Ids.new_asset_code()
		while codes.has(id):
			id = Ids.new_asset_code()
		codes[id] = true
		var asset := {"id": id, "name": file.get_basename()}
		asset[key] = path
		if key == "prefab":
			asset["kind"] = "entity"
			asset["code"] = id
		else:
			asset["kind"] = "scene"
			asset["shape"] = "tile" if key == "atlas" else "image"
		assets.append(asset)
	for child in directory.get_directories():
		if not child.begins_with("."):
			_discover(root, folder.path_join(child), key, assets, paths, codes)

## Removing the declaration while the file is discoverable would give it a new ID on reopen.
static func will_rediscover(manifest: Dictionary, asset: Dictionary) -> bool:
	for folder in SOURCES:
		var key: String = SOURCES[folder]
		var path := str(asset.get(key, "")).replace("\\", "/").simplify_path()
		if path.begins_with(folder + "/") and _matches_kind(path, key):
			return FileAccess.file_exists(str(manifest.get("_dir", "")).path_join(path))
	return false

static func _matches_kind(path: String, key: String) -> bool:
	var extension := path.get_extension().to_lower()
	return extension == "tscn" if key == "prefab" else extension in IMAGE_EXTENSIONS
