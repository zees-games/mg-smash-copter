extends "headless_net_part4.gd"


## mg-smash-copter over the wire: a real server, a real client, and a lossy loopback.
##
## Run: `godot --headless --path . res://examples/headless_net.tscn`. Everything is the real path minus the socket (`ScNetLink.loopback` stands in for the RPC), so encoders, seal, snapshots, prediction and reconciliation run; Godot's own RPC routing is for `dedicated.gd`. The client lives in its own [World3D] (else mirrors sit where the server's bodies are and push them) and on a different tick rate and field than the server, so HELLO and LAYOUT must correct it rather than agree by construction.

const SECTIONS := 27
const CHECKS := 264


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var errors := EngineErrors.new()
	OS.add_logger(errors)

	print("smash-copter over the wire")
	print("")

	_test_the_wire()

	if await _build():
		await _test_a_client_joins()
		await _test_two_builds_share_the_wire()
		await _test_the_field_arrives()
		await _test_a_platform_leans_across_the_wire()
		await _test_a_platform_collapses_across_the_wire()
		await _test_props_arrive()
		await _test_moving()
		await _test_the_local_player_is_predicted()
		await _test_somebody_else_is_drawn()
		await _test_who_somebody_is_crosses()
		await _test_the_phases()
		await _test_a_weapon_crosses()
		await _test_a_hit_is_the_shooters()
		await _test_a_special_is_announced()
		await _test_chat_crosses()
		await _test_a_lossy_link()
		await _test_blind_and_beacon()
		await _test_the_flashlight_crosses()
		await _test_what_is_heard_arrives()
		await _test_somebody_out_watches()
		await _test_free_roam_crosses()
		await _test_the_toys_reach_the_client()
		await _test_a_crate_breaks_in_splinters()
		await _test_leaving()

	_test_the_remote_workbench()

	OS.remove_logger(errors)
	# Engine errors go to stderr and change no exit code: a toy pulled out of the tree after
	# a field was rebuilt mid-tick printed `!is_inside_tree()` on green runs of these suites.
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])

	# Against the declared number too. SECTIONS was declared here and read by nothing — the
	# "name that occurs once" detector, on the suite itself — so a section that was never
	# called at all passed as long as the ones that were called finished.
	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)


func _build() -> bool:
	_section("bringing both halves up")

	var sides: Array = await _build_halves()
	var server_side: Node = sides[0]
	var client_side: Node = sides[1]
	_attach_bridges(server_side, client_side)
	_open_links(server_side, client_side)
	await _start_the_world()
	_check_lag_compensation()

	_finished()
	return _failed == 0


## Both worlds, each in its own physics space; returns [server_side, client_side].
func _build_halves() -> Array:
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space (see the class note): without it the client's mirrors and
	# the server's bodies share one world and push each other apart.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)

	await get_tree().process_frame

	_check(
		_server_game.get_world_3d() != _client_game.get_world_3d(),
		"the two halves are in separate physics worlds, as two processes would be"
	)
	_check(
		_client_game.tick_rate != _server_game.tick_rate,
		"the client is on its own export's tick rate",
		"%d vs %d" % [_client_game.tick_rate, _server_game.tick_rate]
	)
	_check(
		_client_game.platforms.count() != _server_game.platforms.count(),
		"and has built its own default field, which is not the server's",
		"%d vs %d platforms" % [
			_client_game.platforms.count(), _server_game.platforms.count()
		]
	)
	return [server_side, client_side]


## The managers and bridges, attached; a client world on a server manager is refused.
func _attach_bridges(server_side: Node, client_side: Node) -> void:
	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(
		false, &"client", CLIENT_PEER, client_side, _client_game.tick_rate
	)
		# This harness stamps every command itself (`_tick + INPUT_LEAD`), so the client must not ask for dot-net's input-lead report or its clock runs away from commands it never stamped. By the constant map, so it parses against an older dot-net.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = ScNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)

	_client_bridge = ScNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net)
	_check(attached.ok, "the server bridge attaches",
		str(attached.error) if not attached.ok else "")

	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(client_attached.ok, "the client bridge attaches",
		str(client_attached.error) if not client_attached.ok else "")

	# A client world handed a server manager: both are the same class, only this tells them apart.
	var wrong := ScNetBridge.new()
	add_child(wrong)
	var refused := wrong.attach(_client_game, _server_net)
	_check(
		not refused.ok and refused.error.code == DotError.CODE_STATE,
		"a client world on a server manager is refused"
	)
	wrong.queue_free()


## The links, the two builds' own message types, the seal and the loopback.
func _open_links(server_side: Node, client_side: Node) -> void:
	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_check(_server_bridge.link != null and _client_bridge.link != null, "both links open")
	_check(
		_server_bridge.link.name == _client_bridge.link.name,
		"and are named the same on both ends, because the name is the routing",
		String(_server_bridge.link.name)
	)

		# Two builds, not one: each end registers an OPTIONAL message type the other has never heard of (a release ahead each way), and the rest of the suite plays over that.
	_server_net.messages.register(
		SkewServerNews.NAME, SkewServerNews, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_CLIENT, false
	)
	_client_net.messages.register(
		SkewClientNews.NAME, SkewClientNews, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_SERVER, false
	)

	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(
		_server_net.messages.schema_hash() == _client_net.messages.schema_hash(),
		"both ends agree on the message schema they must share, with a type each of their own"
	)

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send

	# What a real client wires to `DotClientLink.ping_ms()`: with no RTT sample the clock believes
	# the link is instant and every stamped command arrives late.
	_client_bridge.rtt_source = func() -> float:
		return 40.0

	_check(_server_game.external_tick, "the server world hands its tick to the bridge")
	_check(
		_client_game.external_tick,
		"and so does the client's, which predicts and interpolates instead"
	)



## Starts both managers, seats the stand-in and lays the server's field out.
func _start_the_world() -> void:
	var _server_started := _server_net.start()
	var _client_started := _client_net.start()

	# A stand-in first: a round needs two sides, and `_side_for_new_player` puts a joiner on the
	# smallest, so this decides the client's side.
	var stand_in := _server_bridge.add_bot("Stand-in", 1)
	_stand_in = stand_in
	_check(stand_in != null and stand_in.is_bot, "a stand-in is seated before anybody joins")
	_check(
		int(_server_bridge.describe()["players"]) == 1,
		"and is replicated exactly like a person, minus the socket"
	)

	# Started AFTER the bridge attaches, as the module does: a field laid out before anything
	# listens to `world_rebuilt` is one no client is told about.
	_server_game.start()
	await get_tree().physics_frame

	_check(
		int(_server_bridge.describe()["bodies"]) > 0,
		"and the server's field is replicated from the moment it is laid out",
		"%d bodies" % int(_server_bridge.describe()["bodies"])
	)


func _check_lag_compensation() -> void:
		# The flag and the callable together, because either alone is a lie: dot-combat defaults lag compensation ON and resolves against the present when nothing is wired. The world builds with it off and the bridge turns it on with the two callables, so these three checks are one fact from three sides.
		#
		# Armed: with the assignment in `_wire_lag_compensation` removed, the first fails.
	_check(
		_server_game.combat.rewind_fn.is_valid(),
		"the server's combat can rewind"
	)
	_check(
		_server_game.combat.restore_fn.is_valid(),
		"and put everything back"
	)
	_check(
		_server_game.combat.config.lag_compensation,
		"and only then does it say lag compensation is on"
	)


## [b]A server and a client built from different sources, on one wire.[/b]
##
## Each registered an optional type the other lacks (see `_build`); each skips what it does not know, and a client that REQUIRES a type this server lacks, or lacks the types this game requires, is refused with a sentence.
func _test_two_builds_share_the_wire() -> void:
	_section("two builds with different message types share the wire")

	_exchange()

	_check(
		_server_net.messages.knows_peer(CLIENT_PEER) and _client_net.messages.knows_peer(1),
		"each end has the other's table, sent as the join happened"
	)
	_check(
		not _server_net.messages.is_refused(CLIENT_PEER) and not _client_net.messages.is_refused(1),
		"and neither refused the other over an optional type"
	)
	_check(
		not _server_net.messages.peer_has(CLIENT_PEER, SkewServerNews.NAME)
			and not _client_net.messages.peer_has(1, SkewClientNews.NAME),
		"each knows which of its types the other lacks"
	)

	var client_skipped := _client_net.messages.skipped
	var news := SkewServerNews.new()
	news.headline = "only the newer server has this"
	var nw := DotNetWriter.new()
	_server_net.messages.encode(news, nw)
	_server_bridge.link.send_event(CLIENT_PEER, nw.to_bytes())

	var server_skipped := _server_net.messages.skipped
	var mood := SkewClientNews.new()
	mood.mood = 3
	var mw := DotNetWriter.new()
	_client_net.messages.encode(mood, mw)
	_client_bridge.link.send_request(mw.to_bytes())

	_exchange()

	_check(
		_client_net.messages.skipped == client_skipped + 1,
		"the client skips the server's newer message (%d)" % (_client_net.messages.skipped - client_skipped)
	)
	_check(
		_server_net.messages.skipped == server_skipped + 1,
		"and the server skips the client's (%d)" % (_server_net.messages.skipped - server_skipped)
	)
	_check(
		_server_net.stats.decode_failures == 0 and _client_net.stats.decode_failures == 0,
		"and neither counts it as a decode failure"
	)

	# No ticks here: every later section is timed from the join, and they are what "the
	# game goes on" means -- all of them run over these two mismatched schemas.
	_check(
		_server_bridge.player_for_peer(CLIENT_PEER) == SESSION,
		"the client is still seated"
	)

	# A client one release ahead that REQUIRES something this server does not have.
	var refusals: Array = []
	var on_refused := func(peer: int, err: DotError) -> void: refusals.append([peer, err])
	_server_net.peer_schema_refused.connect(on_refused)

	var strict := DotNetMessageRegistry.new()
	strict.register(&"skew.vital", SkewVital)
	strict.seal()
	var refused := _server_net.receive(strict.schema_payload(), 99)
	_check(
		not refused.ok and refused.code() == DotError.CODE_VERSION,
		"a client that cannot play with this game's messages is refused as a version problem"
	)
	_check(
		refusals.size() == 1 and int(refusals[0][0]) == 99,
		"on the signal a host disconnects it from"
	)
	_check_refusal_text(refusals)

	_server_net.peer_schema_refused.disconnect(on_refused)
	_server_net.messages.forget_peer(99)
	_finished()


## The sentence a refused client is given, and what it names.
func _check_refusal_text(refusals: Array) -> void:
	var said: DotError = refusals[0][1] if refusals.size() == 1 else null
	_check(
		said != null and said.message == "This server's game needs a newer game client.",
		"with a sentence a player can act on",
		said.message if said != null else ""
	)
	_check(
		said != null and said.detail.contains("skew.vital") and said.detail.contains(String(_server_net.messages.required_names()[0])),
		"naming both what the client lacks and what it requires that this server lacks",
		said.detail if said != null else ""
	)


## A type only the server's build has, which a client can do without.
class SkewServerNews extends DotNetMessage:
	const NAME := &"skew.server_news"
	var headline: String = ""

	func _type_name() -> StringName:
		return NAME

	func _write(w: DotNetWriter) -> void:
		w.write_string(headline, 64)

	func _read(r: DotNetReader) -> void:
		headline = r.read_string(64)


## A type only the client's build has, which a server can do without.
class SkewClientNews extends DotNetMessage:
	const NAME := &"skew.client_news"
	var mood: int = 0

	func _type_name() -> StringName:
		return NAME

	func _write(w: DotNetWriter) -> void:
		w.write_uint(mood, 8)

	func _read(r: DotNetReader) -> void:
		mood = r.read_uint(8)


## A type a newer client REQUIRES, which this server has never heard of.
class SkewVital extends DotNetMessage:
	func _type_name() -> StringName:
		return &"skew.vital"

	func _write(_w: DotNetWriter) -> void:
		pass

	func _read(_r: DotNetReader) -> void:
		pass


## Counts the engine's own errors while installed (mg-smash-copter's dedicated suite has the
## same class): they go to stderr and change no exit code, so only this makes one fail a run.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append("%s (%s)" % [code, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out


func _test_the_flashlight_crosses() -> void:
	_section("the flashlight is asked for, and the server's state comes back to everybody")
	var key := ScNetBridge.player_key(SESSION)
	var server_me: ScPlayer = _server_game.players[key]
	var mine: ScPlayer = _client_game.players[key]
	var was := server_me.flashlight
	_client_bridge.ask_flashlight()
	await _steps(8)
	_check(server_me.flashlight != was, "the server switched it")
	_check(mine.flashlight == server_me.flashlight, "and the owner is told")
	var theirs: ScPlayer = _client_game.players[_stand_in.player_id]
	_stand_in.flashlight = true
	await _steps(8)
	_check(theirs.flashlight, "and the others' flag is the server's")
	_client_bridge.ask_flashlight()
	await _steps(8)
	_check(server_me.flashlight == was and mine.flashlight == was, "the next ask switches it back")
	_finished()
