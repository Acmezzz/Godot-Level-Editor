extends SceneTree
## Standalone game. All card values, deck slots, and settlement destinations come from editor output.

var project_manifest: Dictionary
var request := {}
var verify := false
var entry := {}
var entry_source := "manifest"
var rules := {}
var hand := VBoxContainer.new()
var settlements: Array[Dictionary] = []
var dealt: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--editor-playtest="):
			request = decode(arg)
		elif arg.begins_with("--editor-entry="):
			entry = decode(arg)
			entry_source = "argument"
		elif arg == "--verify":
			verify = true
	project_manifest = JSON.parse_string(FileAccess.get_file_as_string("res://editor/editor_manifest.json"))
	if entry.is_empty():
		entry = project_manifest.get("startup", {}).get("target", {})
	rules = fields(entry.get("function", ""), entry.get("content", ""))
	if rules.is_empty() or rules.get("DECK", []).is_empty():
		finish("No authored encounter or deck")
		return
	root.add_child(hand)
	hand.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	deal()
	if verify:
		await process_frame
		hand.get_child(1).pressed.emit()
		hand.get_child(1).pressed.emit() # Deal again
		hand.get_child(2).pressed.emit()
		finish("")

func decode(arg: String) -> Dictionary:
	return JSON.parse_string(Marshalls.base64_to_utf8(arg.substr(arg.find("=") + 1)))

func fields(kind: String, cid: String) -> Dictionary:
	var row = JSON.parse_string(FileAccess.get_file_as_string("res://content/%s/%s.json" % [kind, cid]))
	if not row is Dictionary or row.get("function") != project_manifest.functions.get(kind, {}).get("code"):
		return {}
	return row.fields

func clear_hand() -> void:
	for child in hand.get_children():
		hand.remove_child(child)
		child.queue_free()

func deal() -> void:
	clear_hand()
	var prompt := Label.new()
	prompt.text = "Pick a card · target %s" % rules.TARG
	hand.add_child(prompt)
	var copies := {}
	for slot in rules.DECK:
		copies[slot.CRDF] = slot.COPY
	dealt.assign(rules.get("ORDR", copies.keys()))
	for id in dealt:
		var card := fields("card", id)
		if card.is_empty():
			finish("Missing card: " + id)
			return
		var count := int(copies.get(id, 1))
		var button := Button.new()
		button.text = "%s × %s (+%s each)" % [card.CAPT, count, card.POWR]
		button.pressed.connect(resolve.bind(id, count * int(card.POWR)))
		hand.add_child(button)

func resolve(cid: String, score: int) -> void:
	var outlet := "PASS" if score >= int(rules.TARG) else "FAIL"
	var target: String = rules[outlet]
	var result := fields("settlement", target)
	if result.is_empty():
		finish("Missing settlement: " + target)
		return
	settlements.append({"card": cid, "score": score, "outlet": outlet, "target": target, "text": result.TEXT})
	clear_hand()
	var label := Label.new()
	label.text = str(result.TEXT) + " · " + str(score)
	hand.add_child(label)
	var retry := Button.new()
	retry.text = "Deal again"
	retry.pressed.connect(deal)
	hand.add_child(retry)

func finish(error: String) -> void:
	if not request.is_empty():
		var report := {"version": 1, "token": request.token, "status": "ready" if error == "" else "error",
			"message": error, "mapDigest": "", "manifestDigest": FileAccess.get_sha256("res://editor/editor_manifest.json"),
			"result": {"entry": entry, "entrySource": entry_source, "settlements": settlements, "dealt": dealt}}
		var file := FileAccess.open(request.path + ".tmp", FileAccess.WRITE)
		file.store_string(JSON.stringify(report))
		file.close()
		DirAccess.rename_absolute(request.path + ".tmp", request.path)
	quit(0 if error == "" else 1)
