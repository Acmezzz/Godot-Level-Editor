extends Node
## Local, stateless MCP HTTP transport. All editor calls run on the scene thread.

const API := preload("res://src/mcp/workbench.gd")
const MAX_HEADER := 16384
const MAX_BODY := 16 * 1024 * 1024
const PROTOCOLS := ["2025-11-25", "2025-06-18", "2025-03-26"]

var _listener := TCPServer.new()
var _clients: Array[Dictionary] = []
var _workbench: RefCounted
var _busy := false
var _port: int
var _token := ""

func start(app: Control, port: int) -> Error:
	_port = port
	_token = OS.get_environment("BIRD_MCP_TOKEN")
	var error := _listener.listen(port, "127.0.0.1")
	if error == OK:
		_workbench = API.new(app)
		app.get_tree().root.add_child.call_deferred(self)
	return error

func _exit_tree() -> void:
	_listener.stop()
	for client in _clients:
		client.peer.disconnect_from_host()

func _process(_delta: float) -> void:
	while _listener.is_connection_available():
		var peer := _listener.take_connection()
		if _clients.size() >= 16:
			peer.disconnect_from_host()
		else:
			_clients.append({"peer": peer, "bytes": PackedByteArray(), "offset": -1,
				"deadline": Time.get_ticks_msec() + 10000})
	for client in _clients.duplicate():
		_poll(client)

func _poll(client: Dictionary) -> void:
	var peer: StreamPeerTCP = client.peer
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() >= client.deadline:
		_close(client)
		return
	if client.has("response"):
		var packet: PackedByteArray = client.response
		var result := peer.put_partial_data(packet.slice(client.sent, client.sent + 65536))
		if result[0] != OK:
			_close(client)
		else:
			client.sent += result[1]
			if client.sent >= packet.size():
				_close(client)
		return
	if client.get("running", false) or peer.get_available_bytes() == 0:
		return
	var chunk := peer.get_partial_data(mini(peer.get_available_bytes(), 65536))
	if chunk[0] != OK:
		_close(client)
		return
	client.bytes.append_array(chunk[1])
	if client.offset < 0:
		var bytes: PackedByteArray = client.bytes
		var end := -1
		for i in range(maxi(0, bytes.size() - chunk[1].size() - 3), mini(bytes.size(), MAX_HEADER) - 3):
			if bytes[i] == 13 and bytes[i + 1] == 10 and bytes[i + 2] == 13 and bytes[i + 3] == 10:
				end = i
				break
		if end < 0:
			if client.bytes.size() >= MAX_HEADER:
				_reply(client, 431)
			return
		if not _headers(client, bytes.slice(0, end).get_string_from_ascii()):
			return
		client.offset = end + 4
	if client.bytes.size() < client.offset + client.length:
		return
	var message: Variant = JSON.parse_string(client.bytes.slice(client.offset,
		client.offset + client.length).get_string_from_utf8())
	client.erase("bytes")
	client.running = true
	client.deadline = Time.get_ticks_msec() + 240000
	_dispatch(client, message)

func _headers(client: Dictionary, header: String) -> bool:
	var lines := header.split("\r\n")
	var request := lines[0].split(" ")
	if request.size() != 3:
		_reply(client, 400, {"error": "Malformed request line"})
		return false
	var headers := {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon > 0:
			headers[lines[i].left(colon).to_lower()] = lines[i].substr(colon + 1).strip_edges()
	var hosts := ["127.0.0.1:%d" % _port, "localhost:%d" % _port]
	if headers.get("host") not in hosts or (headers.has("origin") and
			headers.origin not in ["http://" + hosts[0], "http://" + hosts[1]]):
		_reply(client, 403)
		return false
	if _token != "" and headers.get("authorization", "") != "Bearer " + _token:
		_reply(client, 401)
		return false
	if request[1] != "/mcp":
		_reply(client, 404)
		return false
	if request[0] != "POST":
		_reply(client, 405)
		return false
	var raw: String = headers.get("content-length", "")
	if not raw.is_valid_int() or int(raw) <= 0 or headers.has("transfer-encoding"):
		_reply(client, 400, {"error": "Expected a positive Content-Length"})
		return false
	if int(raw) > MAX_BODY:
		_reply(client, 413)
		return false
	if headers.get("content-type", "").get_slice(";", 0).strip_edges().to_lower() != "application/json":
		_reply(client, 415)
		return false
	if headers.has("mcp-protocol-version") and headers["mcp-protocol-version"] not in PROTOCOLS:
		_reply(client, 400, {"error": "Unsupported MCP protocol version"})
		return false
	client.length = int(raw)
	return true

func _dispatch(client: Dictionary, message: Variant) -> void:
	if not message is Dictionary or message.get("jsonrpc") != "2.0" or not message.get("method") is String:
		_reply(client, 400, {"jsonrpc": "2.0", "id": null,
			"error": {"code": -32600, "message": "Invalid JSON-RPC request"}})
		return
	if not message.has("id"):
		_reply(client, 202)
		return
	var response := {"jsonrpc": "2.0", "id": message.id}
	var params = message.get("params", {})
	if not params is Dictionary:
		response.error = {"code": -32602, "message": "params must be an object"}
	else:
		match message.method:
			"initialize":
				var version = params.get("protocolVersion")
				response.result = {"protocolVersion": version if version in PROTOCOLS else PROTOCOLS[0],
					"capabilities": {"tools": {}},
					"serverInfo": {"name": "bird-editor", "title": str(ProjectSettings.get_setting("application/config/name")), "version": "1.0.0"},
					"instructions": "Start with describe_project. Edit an isolated draft; publish only its reviewed revision. Capture editor UI or render a game frame to see results. This server only edits game content data."}
			"ping":
				response.result = {}
			"tools/list":
				response.result = {"tools": API.catalog()}
			"tools/call":
				var tool_name = params.get("name")
				var args = params.get("arguments", {})
				if not tool_name is String or not args is Dictionary or not API.known_tool(tool_name):
					response.error = {"code": -32602, "message": "Unknown tool or invalid arguments"}
				elif _busy:
					response.result = API.tool_result({"error": "编辑器正在处理另一个 MCP 操作，请稍后重试。"})
				else:
					_busy = true
					var result: Dictionary = await _workbench.invoke(tool_name, args)
					_busy = false
					response.result = API.tool_result(result)
			_:
				response.error = {"code": -32601, "message": "Method not found"}
	_reply(client, 200, response)

func _reply(client: Dictionary, status: int, payload := {}) -> void:
	if not _clients.has(client):
		return
	var reasons := {200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
		404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large", 415: "Unsupported Media Type",
		431: "Request Header Fields Too Large"}
	var body := JSON.stringify(payload).to_utf8_buffer() if not payload.is_empty() else PackedByteArray()
	var header := "HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Length: %d\r\n" % [status, reasons[status], body.size()]
	if not body.is_empty():
		header += "Content-Type: application/json\r\n"
	if status == 405:
		header += "Allow: POST\r\n"
	if status == 401:
		header += "WWW-Authenticate: Bearer\r\n"
	client.response = (header + "\r\n").to_utf8_buffer()
	client.response.append_array(body)
	client.sent = 0
	client.deadline = Time.get_ticks_msec() + 30000

func _close(client: Dictionary) -> void:
	client.peer.disconnect_from_host()
	_clients.erase(client)
