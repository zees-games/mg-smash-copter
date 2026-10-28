extends DotGameCheckSuite

## The constants, state and wiring helpers every section of [code]headless_net.gd[/code] shares: the two halves and the loopback between them.

const ScEvents := preload("../game/net/sc_events.gd")
const ScNetBridge := preload("../game/net/sc_net_bridge.gd")
const ScNetCommand := preload("../game/net/sc_net_command.gd")
const ScPlatformNet := preload("../game/net/sc_platform_net.gd")

const ScAudio := preload("../game/sc_audio.gd")
const ScAvatars := preload("../game/sc_avatars.gd")
const ScFigure := preload("../game/sc_figure.gd")
const ScClient := preload("../game/sc_client.gd")
const ScConfig := preload("../game/sc_config.gd")
const ScContent := preload("../game/sc_content.gd")
const ScGame := preload("../game/sc_game.gd")
const ScLayouts := preload("../game/sc_layouts.gd")
const ScPlatforms := preload("../game/sc_platforms.gd")
const ScPlayer := preload("../game/sc_player.gd")
const ScServices := preload("../game/sc_services.gd")
const ScSpecials := preload("../game/sc_specials.gd")
const ScEvent := preload("../game/net/sc_event.gd")
const ScRequest := preload("../game/net/sc_request.gd")

## Who the client is, on both ends.
const CLIENT_PEER := 7
const SESSION := 42

## Somebody else, on their own peer. See `_test_somebody_else_is_drawn`.
const OTHER_PEER := 8
const OTHER_SESSION := 43

## A third person, seated with a face of their own. See `_test_who_somebody_is_crosses`.
const FACE_PEER := 9
## A connected player who must hear nothing of somebody else's hit.
const BYSTANDER_PEER := 10
const BYSTANDER_SESSION := 45
const FACE_SESSION := 44

## Frames the client draws between two ticks: a screen faster than the tick, as nearly every
## screen is. The interpolation fraction only matters between ticks.
const FRAMES_PER_TICK := 4

const SNAPSHOT_RATE := 30

## What the client's own export would have been built at.
const CLIENT_ENGINE_TICK_RATE := 30

const SERVER_TICK_RATE := 64

## Ticks a client stamps ahead of the server, so its command arrives before its tick.
const INPUT_LEAD := 3

## What the client's own configuration says the field is, which is not what the server runs.
const CLIENT_COLUMNS := 3
const SERVER_COLUMNS := 5

## A platform's lean is eleven bits over one radian, so about half a milliradian. Compare across
## the wire against this, not zero: a quantised value is not the value, and demanding equality
## would assert that the compression does not work.
const LEAN_EPSILON := 0.004

var _sections_entered := 0
var _sections_finished := 0

var _server_game: ScGame = null
var _client_game: ScGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: ScNetBridge = null
var _client_bridge: ScNetBridge = null

## The stand-in seated before the client joins: a player this client does NOT own, which is
## what an owner-only field has to be checked against.
var _stand_in: ScPlayer = null

var _to_client: Array = []
var _to_server: Array = []

var _tick: int = 0
## Every event the server sent: `[peer_id, kind]`, decoded with the client's own registry.
var _sent_events: Array = []
var _listening := false
var _snapshot_count: int = 0

## Drop one snapshot in this many. Zero for a perfect link.
var _drop_every: int = 0


## How many events of [param kind] the server sent to [param peer_id] (0: broadcast).
func _events_of(kind: int, peer_id: int) -> int:
	var count := 0
	for sent: Array in _sent_events:
		if int(sent[0]) == peer_id and int(sent[1]) == kind:
			count += 1
	return count


func _behaviour_of(body: ScPlayer) -> DotNetBehaviour:
	if body == null:
		return null

	for child in body.get_children():
		if child is DotNetBehaviour:
			return child as DotNetBehaviour

	return null


func _identity_of(body: ScPlayer) -> DotNetIdentity:
	if body == null:
		return null

	for child in body.get_children():
		if child is DotNetIdentity:
			return child as DotNetIdentity

	return null


func _make_game(server: bool, parent: Node) -> ScGame:
	var config := ScConfig.new()
	config.columns = SERVER_COLUMNS if server else CLIENT_COLUMNS
	config.rows = 2
	config.survival_seconds = 30.0
	config.showdown_warmup_seconds = 1.0
	config.showdown_seconds = 20.0
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.cannon_enabled = false
	config.specials_enabled = false
	config.vary_layout = false
	config.chopper_enabled = false
	# The showdown must not clear the field in this suite: several sections assert about
	# platforms on both sides of the handover, and a field that vanished at the phase change
	# would make them assert about nothing.
	config.clear_platforms_for_showdown = false

	var game := ScGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = server
	game.tick_rate = SERVER_TICK_RATE if server else CLIENT_ENGINE_TICK_RATE
	# Neither registers: a registry name is global to the process and the last one to
	# register wins, which is precisely the situation a server and a client in one process
	# is.
	game.register_service = false
	parent.add_child(game)
	game.set_physics_process(false)
	return game


func _make_manager(
	server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int
) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	config.world_extent = ScGame.NET_WORLD_EXTENT
	manager.config = config

	parent.add_child(manager)
	var _ready_now := manager.setup()
	return manager


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	# Only while a section listens: a decode on the client's registry counts what it skips.
	if method == &"event" and _listening:
		var decoded := _client_net.messages.decode(DotNetReader.new(payload), 1, false)
		if decoded.ok and decoded.value is ScEvent:
			_sent_events.append([peer_id, (decoded.value as ScEvent).kind])

	if method == &"snapshot":
		_snapshot_count += 1

		if _drop_every > 0 and _snapshot_count % _drop_every == 0:
			return

	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


## A request and its answer: the answer is queued during the first flush and delivered by
## the second.
func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them: rigid bodies move only on
## it, so a tight loop would move no prop and every replication assertion would pass with
## nothing replicated.
func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _ticks := _client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(
		_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new()
	)
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


## How many times the predictor has had to correct this client: off the predictor, not
## [DotNetStats], which counts packets.
func _corrections() -> int:
	if _client_net == null or _client_net.predictor == null:
		return 0

	# [b]The published rate, not a private counter.[/b] `_corrections` is the predictor's own
	# book-keeping; `correction_rate()` is what the addon offers and says whether the two ends
	# compute the same thing.
	return int(round(_client_net.predictor.correction_rate() * 1000.0))


static func _reader(bytes: PackedByteArray) -> DotNetReader:
	return DotNetReader.new(bytes)


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1
