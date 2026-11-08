extends DotGameNetchaosServer

## Smash Copter's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosServer): the world scene and the module, as a dedicated server loads them.

var _scene: Node = null


func _boot_world() -> void:
	if not (await boot_server()).ok:
		return
	_scene = (load("res://scenes/sc_server.tscn") as PackedScene).instantiate()
	add_child(_scene)
	await get_tree().process_frame
	var loaded: DotResult = await server.modules.load_module("res://game/sc_module.gd")
	if not loaded.ok:
		printerr("netchaos server: ", loaded.error)
		return
	module = server.modules.get_module("smash")
	if solid != "":
		var cv: DotConVar = server.console.find_cvar("mp_solidplayers")
		if cv != null:
			cv.force_set(solid)


func _players() -> Array:
	return _scene.game.players.values() if _scene != null and _scene.game != null else []
