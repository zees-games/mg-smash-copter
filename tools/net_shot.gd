extends Node

const ScClient := preload("../game/sc_client.gd")
const ScConfig := preload("../game/sc_config.gd")
const ScGame := preload("../game/sc_game.gd")
const ScNetBridge := preload("../game/net/sc_net_bridge.gd")
const ScPlayer := preload("../game/sc_player.gd")

## Renders a CONNECTED client running its own player, and measures what a player feels.
##
## [codeblock]
## tools/shot.sh --view=walk                 # four consecutive frames, walk_0..walk_3.png
## tools/shot.sh --view=walk --seconds=10    # longer, for steadier numbers
## [/codeblock]
##
## `tools/shot.gd` renders the OFFLINE client, where the world simulates the local player
## itself and prediction does not exist. This is the other shape: a server and a client in
## one process, joined by the same loopback `headless_net` uses. The server's world is in a
## SubViewport with its own physics space that is never drawn; the client's is on screen,
## and every frame calls `ScClient.present_frame`, the function the real client's
## `_process` calls, and puts the eye where `ScClient._process` puts it — the controller's
## `render_state` plus the eye height.
##
## [b]The walk.[/b] The local player is put on the middle of a standing deck, stands for
## half a second, strafes east, stands, strafes back, through the same `client_tick` the
## real client calls, and three numbers are reported:
##
## - how many ticks after a key is pressed the player is drawn moving (0 is the tick it was
##   pressed in, which is what prediction means);
## - the predictor's corrections, replays and snaps over the walk;
## - the eye's apparent speed per rendered frame while the SERVER has the player at full
##   speed. A player running in a straight line at a constant speed should have the same
##   apparent speed every frame, and the spread of it is the judder.
##
## Until 2026-09-25 the client predicted nothing (see `ScNetBridge._mirror_owner`), and this
## is where that showed as a number rather than as a feeling.
##
## xvfb-run, never --headless: headless gives a null renderer and saves a frame of nothing.

const SESSION := 42
const CLIENT_PEER := 7
const INPUT_LEAD := 3

## A screen faster than the tick, as nearly every screen is.
const RENDER_FPS := 144

## Idle, then running, per half-cycle, in ticks. Forty ticks at 6.4 m/s is about four
## metres with the acceleration, which keeps a player who starts 2 m west of a deck's middle
## on the deck either way.
const WALK_IDLE := 32
const WALK_RUN := 40

var _server_game: ScGame = null
var _client_game: ScGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: ScNetBridge = null
var _client_bridge: ScNetBridge = null
var _to_client: Array = []
var _to_server: Array = []
var _tick := 0

var _camera: Camera3D = null
var _placed := false
var _settle := 0

var _walk_tick := 0
var _pressed_at := -1
var _pressed_from := Vector3.ZERO
var _latencies: Array[int] = []
var _eye_speeds: Array[float] = []
var _last_eye := Vector3.INF
var _predictor_from: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.max_fps = RENDER_FPS
	_run.call_deferred()


func _run() -> void:
	var seconds := 6.0
	var out := "res://screenshots/walk.png"

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			seconds = float(arg.substr(10))
		elif arg.begins_with("--out="):
			out = arg.substr(6)

	_build()

	var elapsed := 0.0
	while elapsed < seconds:
		elapsed += get_process_delta_time()
		await get_tree().process_frame

	var base := out.get_basename()
	for i in range(4):
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var path := "%s_%d.png" % [base, i]
		var _saved := image.save_png(ProjectSettings.globalize_path(path))
		print("saved %s" % path)

	_report()
	get_tree().quit()


func _build() -> void:
	var server_view := SubViewport.new()
	server_view.name = "ServerView"
	server_view.own_world_3d = true
	server_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(server_view)

	var server_side := Node.new()
	server_side.name = "ServerSide"
	server_view.add_child(server_side)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)

	_server_net = _make_manager(true, 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(false, CLIENT_PEER, client_side, _client_game.tick_rate)
	# This harness stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them (only dot-net's cap
	# holds it). By the constant map, so this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = ScNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = ScNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var _a := _server_bridge.attach(_server_game, _server_net)
	var _b := _client_bridge.attach(_client_game, _client_net)
	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_server_bridge.link.loopback = func(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
		if peer_id == 0 or peer_id == CLIENT_PEER:
			_to_client.append([method, payload])
	_client_bridge.link.loopback = func(method: StringName, _peer: int, payload: PackedByteArray) -> void:
		_to_server.append([method, payload])
	_client_bridge.rtt_source = func() -> float: return 40.0
	var _s := _server_net.start()
	var _c := _client_net.start()

	# A round needs two sides, as in `headless_net`.
	var _stand_in := _server_bridge.add_bot("Stand-in", 1)
	_server_game.start()

	var _added := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_client_bridge.ask_ready()

	_camera = Camera3D.new()
	_camera.fov = 80.0
	_camera.current = true
	add_child(_camera)


func _make_game(server: bool, parent: Node) -> ScGame:
	var config := ScConfig.new()
	config.survival_seconds = 600.0
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.cannon_enabled = false
	config.specials_enabled = false
	config.vary_layout = false
	config.chopper_enabled = false

	var game := ScGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = server
	game.tick_rate = 64
	game.register_service = false
	parent.add_child(game)
	game.set_physics_process(false)
	return game


func _make_manager(server: bool, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = &"server" if server else &"client"
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = ScGame.NET_SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	config.world_extent = ScGame.NET_WORLD_EXTENT
	manager.config = config

	parent.add_child(manager)
	var _ready_now := manager.setup()
	return manager


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry[0], 1, entry[1])
	for entry in to_server:
		_server_bridge.link.deliver(entry[0], CLIENT_PEER, entry[1])


## One tick per physics frame, which is what a client on the server's rate does — the
## bridge puts the engine there on HELLO.
func _physics_process(delta: float) -> void:
	if _server_bridge == null:
		return

	_place_once()

	_tick += 1
	var _ticks := _client_net.clock.advance(delta)
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, _local_command())
	_flush()
	_watch_the_press()

	if _settle > 0:
		_settle -= 1


## On the middle of a standing deck, once the round has laid the field out: a round start
## puts everybody somewhere, and that would otherwise move them after the walk began.
func _place_once() -> void:
	if _placed or _server_game.phase != ScGame.Phase.SURVIVAL:
		return

	var mine: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))
	if mine == null:
		return

	# The standing deck farthest from anybody else, so the frame is of the floor and not of
	# a stand-in's back.
	var best: Variant = null
	var best_distance := -1.0

	for index in range(_server_game.platforms.count()):
		var deck = _server_game.platforms.deck_at(index)
		if deck == null or not deck.is_standing():
			continue

		var nearest := INF
		for key: StringName in _server_game.players:
			var other: ScPlayer = _server_game.players[key]
			if other != mine:
				nearest = minf(nearest, other.controller.state.position.distance_to(deck.centre))

		if nearest > best_distance:
			best_distance = nearest
			best = deck

	if best != null:
		mine.place_at(best.centre + Vector3(-2.0, 1.2, 0.0), 0.0)
		_placed = true
		_settle = 30


func _local_command() -> DotFpsCommand:
	var command := DotFpsCommand.new()

	if not _placed or _settle > 0:
		return command

	var half := WALK_IDLE + WALK_RUN
	var at := _walk_tick % half
	var east := (_walk_tick / half) % 2 == 0
	_walk_tick += 1

	# Facing north and strafing: the view never turns, so what moves on screen is the player
	# and nothing else.
	command.yaw = 0.0
	if at >= WALK_IDLE:
		command.move = Vector2(1.0 if east else -1.0, 0.0)

		if at == WALK_IDLE:
			var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
			if mine != null:
				_pressed_at = _tick
				_pressed_from = mine.global_position

	if _predictor_from.is_empty() and _client_net.predictor != null:
		_predictor_from = _client_net.predictor.describe()

	return command


## The first tick after a press on which this client DRAWS its player somewhere else. Read
## off the node, which is what the tick writes and the predictor reads.
func _watch_the_press() -> void:
	if _pressed_at < 0:
		return

	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	if mine == null:
		return

	if mine.global_position.distance_to(_pressed_from) > 0.01:
		_latencies.append(_tick - _pressed_at)
		_pressed_at = -1


func _process(delta: float) -> void:
	if _client_game == null:
		return

	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var _shown := ScClient.present_frame(_client_net, _client_game, mine, true, delta)

	if mine == null:
		return

	# Where `ScClient._process` puts the rig: the controller's render state, every frame.
	var eye := mine.controller.render_state().position + Vector3(0.0, ScPlayer.EYE_HEIGHT, 0.0)
	_camera.global_position = eye
	_camera.look_at(eye + Vector3(0.0, -0.35, -1.0), Vector3.UP)

	if delta <= 0.0 or not _placed or _settle > 0:
		_last_eye = Vector3.INF
		return

	var server_mine: ScPlayer = _server_game.players.get(mine.player_id)
	var flat := 0.0
	if server_mine != null:
		flat = Vector2(
			server_mine.controller.state.velocity.x, server_mine.controller.state.velocity.z
		).length()

	if _last_eye != Vector3.INF and flat > 6.0:
		_eye_speeds.append(eye.distance_to(_last_eye) / delta)
	_last_eye = eye


func _report() -> void:
	print("key to motion, in ticks (0 = the tick it was pressed): %s" % str(_latencies))

	var now := _client_net.predictor.describe() if _client_net.predictor != null else {}
	if not now.is_empty() and not _predictor_from.is_empty():
		print("predictor over the walk: %d replays, %d corrections, %d snaps, worst %s" % [
			int(now["replays"]) - int(_predictor_from["replays"]),
			int(now["corrections"]) - int(_predictor_from["corrections"]),
			int(now["snaps"]) - int(_predictor_from["snaps"]),
			str(now["worst_error"]),
		])

	if _eye_speeds.is_empty():
		print("eye speed: no frame sampled at full speed")
		return

	var sorted := _eye_speeds.duplicate()
	sorted.sort()
	var n := sorted.size()
	print("eye speed per frame at full speed (server 6.4 m/s): median %.1f m/s, p10 %.1f, p90 %.1f, max %.1f, over %d frames" % [
		float(sorted[n / 2]), float(sorted[n / 10]), float(sorted[(n * 9) / 10]),
		float(sorted[n - 1]), n,
	])
