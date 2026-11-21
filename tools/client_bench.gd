extends GSGameClientBench

## Client prediction bench (gs-game's GSGameClientBench): see that class for the flags.
## The world is the server scene and module a dedicated server loads; `--bots` is ignored.


func _configure() -> void:
	client_scene = "res://game/sc.tscn"
	forward_action = &"gs_fps_forward"


func _boot_server(_bots_wanted: int, data_dir: String) -> GSNetManager:
	var config := make_server_config(data_dir)
	config.max_players = 16
	var server := GSServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == GSServer.State.RUNNING:
			break
	var scene: Node = (load("res://scenes/sc_server.tscn") as PackedScene).instantiate()
	add_child(scene)
	await get_tree().process_frame
	var loaded: GSResult = await server.modules.load_module("res://game/sc_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		return null
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			return m.get("net")
	return null
