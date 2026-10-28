extends "headless_net_base.gd"


## mg-smash-copter over the wire: a real server, a real client, and a lossy loopback.
##
## [codeblock]
## godot --headless --path . res://examples/headless_net.tscn
## [/codeblock]
##
## [b]Everything here is the real path minus the socket.[/b] Two [ScGame]s, two
## [DotNetManager]s, two [ScNetBridge]s and two links, with `ScNetLink.loopback` standing in
## for the RPC — so the encoders, the schema seal, the snapshot build, the prediction and
## the reconciliation all run. What it cannot test is Godot's own RPC routing, and that is
## what `dedicated.gd` and a real client are for.
##
## [b]The client world lives in its own [World3D], and that is a finding rather than
## tidiness.[/b] Both halves are in one scene tree, so without it they share one physics
## space: the client's frozen mirrors sit exactly where the server's real bodies are, and
## every server body spends the round being pushed out of a copy of itself. Nothing errors —
## the positions simply stop agreeing, which reads as the replication being wrong when it is
## the harness that is.
##
## [b]And the client is deliberately on a different tick rate and a different field than the
## server.[/b] One process has one engine rate and one default configuration, so two halves
## agree by construction and a check asserting they agree passes for the wrong reason. A
## real client is a separate program with its own export. Make them disagree, and let HELLO
## and LAYOUT correct it.

const SECTIONS := 25
const CHECKS := 254


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
		await _test_what_is_heard_arrives()
		await _test_somebody_out_watches()
		await _test_free_roam_crosses()
		await _test_the_toys_reach_the_client()
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


# --- The wire ---------------------------------------------------------------

## Every encoder against its own decoder, and nothing else.
##
## [b]Nothing checks that a pair are inverses for you.[/b] This family has already shipped a
## serialisation whose two ends never met: dot-moderation wrote `"voice muted"` and read back
## a warning, and the one thing that addon existed for silently did nothing. Every pair in
## `ScEvents` is round-tripped here, and a new one without a line in this section is a new
## one nothing has ever decoded.
func _test_the_wire() -> void:
	_section("every message survives the trip")

	var hello := ScEvents.read_hello(_reader(
		ScEvents.write_hello(SESSION, 128, 9001, 5, 150.0, 75.0, 3.5)
	))
	_check(bool(hello["ok"]), "hello decodes")
	_check(int(hello["player_id"]) == SESSION, "with the session id")
	_check(int(hello["tick_rate"]) == 128, "the server's tick rate")
	_check(int(hello["server_tick"]) == 9001, "and the tick it was sent on")
	_check(int(hello["team_count"]) == 5, "how many sides are playing")
	_check(absf(float(hello["survival_seconds"]) - 150.0) < 0.2, "and both halves of a round")

	var cells: Array[Vector3i] = [
		Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(1, 1, 0), Vector3i(1, 0, 1),
	]
	var layout := ScEvents.read_layout(_reader(ScEvents.write_layout(
		&"gauntlet", 5, 2, 11.4, 24.0, 10.5, 40.0, 0.82, 0.66, cells, 0.525, -0.5
	)))
	_check(bool(layout["ok"]), "a layout decodes")
	_check(StringName(layout["layout_id"]) == &"gauntlet", "with its id")
	_check(int(layout["columns"]) == 5 and int(layout["rows"]) == 2, "its shape")
	_check(absf(float(layout["deck_height"]) - 40.0) < 0.05, "how high the field is")
	_check(absf(float(layout["pitch_scale"]) - 0.82) < 0.01, "and the scales it is played at")
	# The row scale, which the chequerboard pulls in to 0.525. A client that dropped it would
	# build that field's second row 11.4 m from where the server's is.
	_check(absf(float(layout.get("row_pitch_scale", 1.0)) - 0.525) < 0.001
			and absf(float(layout.get("row_shift", 0.0)) + 0.5) < 0.001,
		"and how close its rows are, and where")

	var came_back: Array[Vector3i] = layout["cells"]
	_check(came_back.size() == cells.size(), "every cell comes back", "%d" % came_back.size())
	_check(
		came_back.size() == cells.size() and came_back[2] == cells[2] and came_back[3] == cells[3],
		"in the same order, bridges and all"
	)

	var platform := ScEvents.read_platform(_reader(ScEvents.write_platform(88, 11)))
	_check(
		bool(platform["ok"]) and int(platform["net_id"]) == 88 and int(platform["index"]) == 11,
		"a platform's net id and index decode"
	)

	var fell := ScEvents.read_collapse(_reader(
		ScEvents.write_collapse(6, ScPlatforms.WHY_SHATTERED)
	))
	_check(
		bool(fell["ok"]) and int(fell["index"]) == 6
			and StringName(fell["why"]) == ScPlatforms.WHY_SHATTERED,
		"and so does a collapse, with its reason"
	)

	var join := ScEvents.read_join(_reader(ScEvents.write_join(SESSION, 5, "Ada", 4)))
	_check(
		bool(join["ok"]) and int(join["player_id"]) == SESSION and str(join["name"]) == "Ada"
			and int(join["team"]) == 4,
		"a join carries a name and a side"
	)
	var face := ScAvatars.stock_avatar(&"u1")
	face.set_part(ScAvatars.SLOT_SKIN, &"skin_k")
	var faced := ScEvents.read_join(_reader(ScEvents.write_join(SESSION, 5, "Ada", 4, face)))
	_check(
		bool(faced["ok"]) and faced["avatar"] is DotAvatar
			and (faced["avatar"] as DotAvatar).digest() == face.digest()
			and int(faced["team"]) == 4,
		"and a face, after the side rather than in front of it"
	)
	var bare := ScEvents.write_join(SESSION, 5, "Ada", 4)
	var plain := ScEvents.read_join(_reader(bare))
	_check(
		bool(plain["ok"]) and plain["avatar"] == null,
		"and no face is the stock person, not a refused join"
	)
	_check(ScEvents.read_player(_reader(ScEvents.write_player(SESSION))) == SESSION,
		"a leave carries who left")

	var team := ScEvents.read_team(_reader(ScEvents.write_team(SESSION, 6)))
	_check(bool(team["ok"]) and int(team["team"]) == 6, "a side change carries six sides")

	var death := ScEvents.read_death(_reader(
		ScEvents.write_death(SESSION, 9, ScGame.DIED_CRUSHED)
	))
	_check(
		bool(death["ok"]) and int(death["by"]) == 9
			and StringName(death["why"]) == ScGame.DIED_CRUSHED,
		"a death carries who and what"
	)

	var armed := ScEvents.read_armed(_reader(ScEvents.write_armed(SESSION, &"drum_shotgun")))
	_check(
		bool(armed["ok"]) and StringName(armed["weapon_id"]) == &"drum_shotgun",
		"and a survivor's weapon is named"
	)

	var at := Vector3(-41.25, 46.5, 17.75)
	var prop := ScEvents.read_prop(_reader(
		ScEvents.write_prop(3, ScContent.MONOLITH, at, false)
	))
	_check(bool(prop["ok"]) and StringName(prop["kind_id"]) == ScContent.MONOLITH,
		"a prop names its catalogue entry")
	_check(
		(prop["position"] as Vector3).distance_to(at) < 0.01,
		"and arrives where it was put",
		"%.4f m out" % (prop["position"] as Vector3).distance_to(at)
	)
	_check(not bool(prop["vehicle"]), "and says it is not a vehicle")

	var copter := ScEvents.read_prop(_reader(
		ScEvents.write_prop(4, ScContent.COPTER, at, true)
	))
	_check(bool(copter["ok"]) and bool(copter["vehicle"]), "and a chopper says it is one")

	var gone := ScEvents.read_prop_gone(_reader(
		ScEvents.write_prop_gone(3, DotPropSpawner.REASON_CLEANUP)
	))
	_check(bool(gone["ok"]) and int(gone["net_id"]) == 3, "a removal names what went")

	var seat := ScEvents.read_seat(_reader(ScEvents.write_seat(SESSION, 12, true)))
	_check(bool(seat["ok"]) and bool(seat["seated"]), "a seat change decodes")

	var clock := ScEvents.read_clock(_reader(
		ScEvents.write_clock(3, 61.5, ScGame.Phase.SHOWDOWN, 9, 5, 2, true)
	))
	_check(bool(clock["ok"]) and int(clock["round"]) == 3, "the clock carries the round")
	_check(absf(float(clock["elapsed"]) - 61.5) < 0.1, "how far into it we are")
	_check(int(clock["phase"]) == ScGame.Phase.SHOWDOWN, "which half it is")
	_check(
		int(clock["standing"]) == 9 and int(clock["alive"]) == 5 and int(clock["teams_alive"]) == 2,
		"and the three numbers a client cannot count for itself"
	)

	var round_info := ScEvents.read_round(_reader(ScEvents.write_round(7, false, 3)))
	_check(
		bool(round_info["ok"]) and int(round_info["round"]) == 7
			and not bool(round_info["began"]) and int(round_info["winner"]) == 3,
		"a round ending names its winner"
	)

	var phase := ScEvents.read_phase(_reader(ScEvents.write_phase(ScGame.Phase.HANDOVER)))
	_check(bool(phase["ok"]) and int(phase["phase"]) == ScGame.Phase.HANDOVER,
		"a phase change decodes")

	var special := ScEvents.read_special(_reader(
		ScEvents.write_special(&"feather", true, "LOW GRAVITY — mind the landing")
	))
	_check(bool(special["ok"]) and StringName(special["special_id"]) == &"feather",
		"a special names itself")
	_check(
		str(special["blurb"]).begins_with("LOW GRAVITY"),
		"and carries what to shout, so an older client can still say something"
	)

	var blast := ScEvents.read_blast(_reader(ScEvents.write_blast(at, 6.5)))
	_check(
		bool(blast["ok"]) and (blast["position"] as Vector3).distance_to(at) < 0.01
			and absf(float(blast["radius"]) - 6.5) < 0.05,
		"a blast decodes where and how far"
	)

	var said := ScEvents.read_say(_reader(ScEvents.write_say(&"team", "north bridge")))
	_check(
		bool(said["ok"]) and str(said["channel"]) == "team" and str(said["text"]) == "north bridge",
		"what a client types decodes"
	)

	var notice := ScEvents.read_notice(_reader(ScEvents.write_notice("you are talking too fast")))
	_check(bool(notice["ok"]) and str(notice["text"]).begins_with("you are"),
		"and a notice to one person")

	var wire := {
		"n": 12, "t": 1700000000, "c": "near", "k": "say",
		"s": "u42", "d": "Ada", "w": "", "m": "watch the gap", "x": {"p": SESSION},
	}
	var chat := ScEvents.read_chat(_reader(ScEvents.write_chat(wire)))
	_check(bool(chat["ok"]) and str(chat["m"]) == "watch the gap", "a routed line decodes")
	_check(str(chat["d"]) == "Ada" and str(chat["c"]) == "near", "with its speaker and channel")
	_check(
		typeof(chat.get("x")) == TYPE_DICTIONARY and int((chat["x"] as Dictionary)["p"]) == SESSION,
		"and the one meta field this game carries"
	)

	var asked := ScEvents.read_ask_team(_reader(ScEvents.write_ask_team(5)))
	_check(bool(asked["ok"]) and int(asked["team"]) == 5, "and a request for a side")

	# The death position is the field dot-spectate's own wire leaves out; see
	# `ScEvents.write_spectate`. A mirror without it puts the death camera in the cannon.
	var drop := Vector3(-12.25, 44.0, 30.5)
	var view := ScEvents.read_spectate(_reader(ScEvents.write_spectate(
		SESSION, DotSpectatorView.Mode.DEATH_CAM, OTHER_SESSION, 0, drop
	)))
	_check(
		bool(view["ok"]) and int(view["viewer"]) == SESSION
			and int(view["mode"]) == DotSpectatorView.Mode.DEATH_CAM
			and int(view["target"]) == OTHER_SESSION and int(view["killer"]) == 0
			and (view["death_at"] as Vector3).distance_to(drop) < 0.01,
		"a spectator's view decodes, with where they went down"
	)

	var roaming := ScEvents.read_spectate(_reader(ScEvents.write_spectate(
		SESSION, DotSpectatorView.Mode.ROAMING, 0, 0, drop
	)))
	_check(bool(roaming["ok"]) and int(roaming["mode"]) == DotSpectatorView.Mode.ROAMING
		and int(roaming["target"]) == 0, "a roaming view decodes with no target")
	var ask := _reader(ScEvents.write_ask_roam())
	_check(ask.read_uint(8) == 0 and ask.ok(), "and the roam request is a one-byte ask")

	var steps: Array[int] = []
	for direction in [-1, 0, 1]:
		var step := ScEvents.read_ask_spectate(_reader(ScEvents.write_ask_spectate(direction)))
		steps.append(int(step["direction"]) if bool(step["ok"]) else 99)
	_check(str(steps) == "[-1, 0, 1]", "and a request for the previous, the camera and the next",
		str(steps))

	var landed := ScEvents.read_impact(_reader(ScEvents.write_impact(at, 2, 3150.0)))
	_check(
		bool(landed["ok"]) and (landed["position"] as Vector3).distance_to(at) < 0.01
			and int(landed["outcome"]) == 2 and absf(float(landed["impulse"]) - 3150.0) < 10.0,
		"an impact decodes where, what it did and how hard"
	)

	_check_wire_limits()

	_finished()


## A truncated message says so, and every kind fits its field.
func _check_wire_limits() -> void:
	# [b]A reader past its end returns plausible zeros rather than failing.[/b] dot-net
	# shipped with exhaustion that was not sticky, so a decoder that skipped the `ok` check
	# got a believable value for the field AFTER the overrun — and a truncated packet decodes
	# as a valid message about nothing.
	var truncated := ScEvents.read_hello(DotNetReader.new(PackedByteArray([1, 2])))
	_check(not bool(truncated["ok"]), "and a truncated message says so rather than guessing")

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	_check(ScEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [ScEvents.Kind.size(), ScEvent.KIND_BITS])
	_check(ScRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [ScEvents.Ask.size(), ScRequest.KIND_BITS])
	_check(ScEvents.chat_kinds_fit(), "every chat kind fits the chat line's kind field",
		"%d kinds in %d bits" % [DotChatMessage.KIND_NAMES.size(), ScEvents.CHAT_KIND_BITS])


# --- Building both halves ---------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space. See the class note: without it the client's frozen
	# mirrors and the server's real bodies are in one world, in the same cubic metres, and
	# the server's field is quietly pushed apart by a copy of itself.
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

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(
		false, &"client", CLIENT_PEER, client_side, _client_game.tick_rate
	)
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

	var attached := _server_bridge.attach(_server_game, _server_net)
	_check(attached.ok, "the server bridge attaches",
		str(attached.error) if not attached.ok else "")

	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(client_attached.ok, "the client bridge attaches",
		str(client_attached.error) if not client_attached.ok else "")

	# The one mistake this check exists for: a client world handed a server manager. Both
	# halves are the same class, so nothing but this comparison can tell them apart.
	var wrong := ScNetBridge.new()
	add_child(wrong)
	var refused := wrong.attach(_client_game, _server_net)
	_check(
		not refused.ok and refused.error.code == DotError.CODE_STATE,
		"a client world on a server manager is refused"
	)
	wrong.queue_free()

	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_check(_server_bridge.link != null and _client_bridge.link != null, "both links open")
	_check(
		_server_bridge.link.name == _client_bridge.link.name,
		"and are named the same on both ends, because the name is the routing",
		String(_server_bridge.link.name)
	)

	# [b]Two builds, not one.[/b] Each end registers an OPTIONAL message type the other has
	# never heard of -- a server one release ahead, a client one release ahead -- and the
	# whole of the rest of this suite plays over that. They must still agree on what has
	# to match, and every section after this one is the proof that they can play.
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

	# What a real client wires to `DotClientLink.ping_ms()`. Nothing in dot-net writes an RTT
	# sample, and a client that feeds none has a clock that believes the link is instant — so
	# every command it stamps arrives after its tick has passed.
	_client_bridge.rtt_source = func() -> float:
		return 40.0

	_check(_server_game.external_tick, "the server world hands its tick to the bridge")
	_check(
		_client_game.external_tick,
		"and so does the client's, which predicts and interpolates instead"
	)

	var _server_started := _server_net.start()
	var _client_started := _client_net.start()

	# A stand-in on the other side, before anybody joins. A round needs two sides to exist
	# at all, and `_side_for_new_player` puts a joiner on the smallest — so seating one first
	# is also what decides which side the client under test ends up on.
	var stand_in := _server_bridge.add_bot("Stand-in", 1)
	_stand_in = stand_in
	_check(stand_in != null and stand_in.is_bot, "a stand-in is seated before anybody joins")
	_check(
		int(_server_bridge.describe()["players"]) == 1,
		"and is replicated exactly like a person, minus the socket"
	)

	# The world is started AFTER the bridge is attached, which is what the module does and
	# for the reason written there: a field laid out before anything was listening to
	# `world_rebuilt` is a field no client is ever told about.
	_server_game.start()
	await get_tree().physics_frame

	_check(
		int(_server_bridge.describe()["bodies"]) > 0,
		"and the server's field is replicated from the moment it is laid out",
		"%d bodies" % int(_server_bridge.describe()["bodies"])
	)

	# [b]The flag and the callable together, because either alone is a lie.[/b] dot-combat
	# defaults lag compensation ON and resolves every shot against the present when nothing
	# is wired to it, so a server can report the feature as enabled and not have it — this
	# family's second most repeated bug, and one a delivered boot log caught here saying so
	# twice. The world builds with it off and the bridge turns it on in the same breath as
	# the two callables, so these three checks are one fact asserted from three sides.
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

	_finished()
	return _failed == 0


# --- Joining ----------------------------------------------------------------

func _test_a_client_joins() -> void:
	_section("a client joins")

	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. Kept,
	# and answered by the seat; a bridge that drops it never tells this client who it is.
	_client_bridge.ask_ready()
	_exchange()
	_check(_client_bridge.local_player_id != SESSION, "a READY before the seat is told nothing yet")

	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them", str(seated.error) if not seated.ok else "")

	_exchange()
	_exchange()

	# [b]And then let the round actually begin, which re-lays the field from inside the
	# netcode's own loop.[/b] dot-match runs a warmup before the first round and nothing has
	# ticked yet, so without this every section below would be asserting about a world that
	# had not started — and the round would begin in the middle of whichever one ticked
	# first. It is also what a real client joining a live server sees: the field is rebuilt
	# under them at the top of every round.
	await _steps(12)

	_check(_client_bridge.local_player_id == SESSION, "and the client is told who it is",
		"%d" % _client_bridge.local_player_id)

	# [b]The server's tick rate, and another game in this family shipped with HELLO carrying
	# it and nothing reading it.[/b] A browser client counted at the 60 its export declared
	# against a server on 128, so every replicated time was out by 128/60 — produced
	# correctly and consumed by nothing.
	_check(
		_client_game.tick_rate == SERVER_TICK_RATE,
		"it adopts the server's tick rate",
		"%d" % _client_game.tick_rate
	)
	_check(
		Engine.physics_ticks_per_second == SERVER_TICK_RATE,
		"and so does the engine it is drawing with",
		"%d" % Engine.physics_ticks_per_second
	)
	_check(
		Engine.max_physics_steps_per_frame >= ceili(0.25 * float(SERVER_TICK_RATE)),
		"the engine's step cap covers a quarter second at the adopted rate",
		"%d steps for %d Hz" % [Engine.max_physics_steps_per_frame, SERVER_TICK_RATE]
	)
	_check(
		_client_net.clock.tick_rate == SERVER_TICK_RATE,
		"and the live clock, not only the config it was built from"
	)

	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	_check(mine != null, "the client has a body for itself")
	_check(
		_client_game.players.size() == 2,
		"and one for everybody already on the server",
		"%d" % _client_game.players.size()
	)
	_check(
		mine != null and not mine.samples_input,
		"which does not sample a keyboard, because the client loop hands it commands"
	)
	_check(
		_client_game.config.team_count == _server_game.config.team_count,
		"the client took the server's number of sides"
	)
	_check(
		absf(_client_game.config.survival_seconds - _server_game.config.survival_seconds) < 0.5,
		"and both halves of its round"
	)

	_finished()


# --- The field --------------------------------------------------------------

func _test_the_field_arrives() -> void:
	_section("the field arrives")

	_check(
		_client_game.platforms.count() == _server_game.platforms.count(),
		"the client rebuilt the server's field",
		"%d vs %d" % [_client_game.platforms.count(), _server_game.platforms.count()]
	)

	# [b]In the same ORDER, which is what the wire addresses a platform by.[/b] A client that
	# derived the field from a catalogue of its own would build the right field right up
	# until its build was one layout behind — and then its platform seven would be somewhere
	# else and every snapshot after that would move the wrong floor, silently.
	var same_places := true
	var worst := 0.0

	for i in range(_server_game.platforms.count()):
		var here := _server_game.platforms.deck_at(i)
		var there := _client_game.platforms.deck_at(i)

		if there == null:
			same_places = false
			break

		worst = maxf(worst, here.centre.distance_to(there.centre))

		if here.centre.distance_to(there.centre) > 0.01:
			same_places = false

	_check(same_places, "platform by platform, in the same order", "%.4f m worst" % worst)

	var bridges_here := 0
	var bridges_there := 0

	for i in range(_server_game.platforms.count()):
		if _server_game.platforms.deck_at(i).is_bridge:
			bridges_here += 1

		if _client_game.platforms.deck_at(i).is_bridge:
			bridges_there += 1

	_check(bridges_here == bridges_there, "and the bridges are bridges on both ends",
		"%d vs %d" % [bridges_here, bridges_there])

	_check(
		_client_game.platforms.count() > 0
			and _client_game.platforms.deck_at(0).body != null,
		"every mirrored platform has a body a player can stand on"
	)

	# The client runs no model at all. This is the check that says so: its platforms are
	# moved by snapshots and by nothing else.
	_check(not _client_game.platforms.authoritative, "and the client runs no platform model")

	var mapped := 0

	for i in range(_client_game.platforms.count()):
		var deck := _client_game.platforms.deck_at(i)

		if deck.body != null and deck.body.get_node_or_null(^"Net") != null:
			mapped += 1

	_check(
		mapped == _client_game.platforms.count(),
		"and every one of them is bound to a net id",
		"%d of %d" % [mapped, _client_game.platforms.count()]
	)

	_finished()


# --- A platform, over the wire ----------------------------------------------

func _test_a_platform_leans_across_the_wire() -> void:
	_section("a lean crosses the wire")

	var here := _server_game.platforms.deck_at(0)
	var there := _client_game.platforms.deck_at(0)
	var at := here.centre + Vector3(here.half * 0.8, 0.0, 0.0)

	_check(there.tilt() < 0.01, "the client's copy starts level", "%.4f rad" % there.tilt())

	# [b]An impact rather than a load, and the difference is the game's own tick.[/b]
	# `ScGame._load_platforms` calls `begin_loads()` every tick and re-gathers what is
	# standing on each platform, so a load added by hand from outside is wiped before it is
	# ever integrated — the first version of this section did that and measured the lean of
	# the one player who happened to be standing there. An impact is not a load: it is a
	# push on the lean velocity, which is exactly what a prop landing does, and it survives
	# the next `begin_loads`.
	var _hit := _server_game.platforms.report_impact(0, 260.0, 12.0, at)

	for _i in range(20):
		await _step()

	_check(here.tilt() > 0.02, "the server's platform leaned", "%.4f rad" % here.tilt())
	_check(
		absf(there.lean.x - here.lean.x) < LEAN_EPSILON,
		"and the client's copy leans the same way, to the bit",
		"%.5f vs %.5f" % [there.lean.x, here.lean.x]
	)
	_check(
		absf(there.lean.y - here.lean.y) < LEAN_EPSILON,
		"on both axes"
	)

	# [b]The SURFACE, which is what a player actually stands on.[/b] Two leans that agree
	# and two surfaces that do not would be a client drawing the right angle about the wrong
	# pivot — and the thing a player falls through is the surface.
	var surface_here := _server_game.platforms.surface_y(0, at.x, at.z)
	var surface_there := _client_game.platforms.surface_y(0, at.x, at.z)
	_check(
		absf(surface_here - surface_there) < 0.05,
		"and the surface under one point is at the same height on both ends",
		"%.4f m apart" % absf(surface_here - surface_there)
	)

	# And the body a motor sweeps against actually moved, rather than the number alone.
	_check(
		there.body != null and absf(there.body.global_basis.y.y - 1.0) > 0.0001,
		"the mirrored body is genuinely tilted, not just the number"
	)

	_finished()


func _test_a_platform_collapses_across_the_wire() -> void:
	_section("a collapse takes the client's floor away")

	var index := 1
	var here := _server_game.platforms.deck_at(index)
	var there := _client_game.platforms.deck_at(index)

	var told: Array[int] = []
	_client_bridge.collapse_received.connect(
		func(i: int, _why: StringName) -> void: told.append(i)
	)

	_check(there.is_standing(), "it is standing on both ends to begin with")

	var _fell := _server_game.platforms.collapse(index, ScPlatforms.WHY_SHATTERED)
	await _steps(6)

	_check(not here.is_standing(), "the server takes it off its pillar")
	# An Array, never a captured counter: a GDScript lambda captures locals BY VALUE, so an
	# `int` incremented in a handler stays zero outside it and the check reports a failure
	# for a signal that fired perfectly.
	_check(told.has(index), "the client is told, reliably, which one and why")
	_check(not there.is_standing(), "and its own copy stops standing",
		ScPlatforms.State.keys()[there.state])

	# [b]The collider goes with it, and this is the check that matters.[/b] A client that
	# knew a platform had gone and left the floor there is a player standing on something
	# that does not exist anywhere else — which is the worst version of the bug the whole
	# platform model exists to avoid.
	var collider := there.body.get_node_or_null(^"Collision") as CollisionShape3D \
		if there.body != null else null
	_check(collider == null or collider.disabled, "and the floor under it is gone")

	_check(
		_client_game.platforms.index_of_body(
			there.body.get_instance_id() if there.body != null else 0
		) == -1,
		"so nothing on the client can be standing on it"
	)

	_finished()


# --- Props ------------------------------------------------------------------

func _test_props_arrive() -> void:
	_section("what the cannon throws arrives")

	var before := int(_client_bridge.describe()["bodies"])

	var sent := _server_game.cannon.fire(0.0, ScSpecials.Active.new())
	_check(sent > 0, "the server fires", "%d props" % sent)

	await _steps(10)

	var after := int(_client_bridge.describe()["bodies"])
	_check(after > before, "and the client is told about them",
		"%d bodies, was %d" % [after, before])

	# The client builds the body from the catalogue id it was sent, not from a script name —
	# which is the whole reason a prop is addressed that way. A mounted pack's `class_name`
	# globals are not registered in the host.
	var mirrored := 0
	var frozen := 0

	for child in _client_game.get_children():
		var body := child as RigidBody3D

		if body == null:
			continue

		mirrored += 1

		if body.freeze:
			frozen += 1

	_check(mirrored > 0, "it built real bodies for them", "%d" % mirrored)
	_check(
		mirrored == frozen,
		"and froze every one, because a mirror must not be simulated twice",
		"%d of %d" % [frozen, mirrored]
	)

	# And they are where the server has them, within the quantisation the wire uses.
	var worst := INF

	for prop in _server_game.props.all_props():
		var at := prop.body().global_position
		var closest := INF

		for child in _client_game.get_children():
			var body := child as RigidBody3D

			if body != null:
				closest = minf(closest, body.global_position.distance_to(at))

		worst = minf(worst, closest)

	_check(worst < 1.0, "in about the right place", "%.3f m" % worst)

	_finished()


# --- Moving -----------------------------------------------------------------

func _test_moving() -> void:
	_section("a client moves itself and the server agrees")

	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var theirs: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))

	if mine == null or theirs == null:
		for what in [
			"the client predicts its own movement",
			"the server moved them the same way",
			"and the two agree about where they are",
			"with the predictor barely correcting",
			"a button the client holds reaches the server",
		]:
			_check(false, what)

		_finished()
		return

	var started := mine.controller.state.position

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	forward.yaw = 0.0

	await _steps(40, forward)

	var moved := mine.controller.state.position.distance_to(started)
	_check(moved > 1.0, "the client predicts its own movement", "%.2f m" % moved)

	var server_moved := theirs.controller.state.position.distance_to(started)
	_check(server_moved > 1.0, "the server moved them the same way", "%.2f m" % server_moved)

	var apart := mine.controller.state.position.distance_to(theirs.controller.state.position)
	_check(apart < 1.5, "and the two agree about where they are", "%.3f m apart" % apart)

	# [b]Corrections, not packets.[/b] A correction is the number that says whether the two
	# ends are computing the same thing; a packet count says only that they are talking.
	var rate := _client_net.predictor.correction_rate()
	_check(rate < 0.5, "with the predictor correcting on a minority of snapshots",
		"%.2f" % rate)

	# A game button, all the way across. The fire button is what the showdown is played with
	# and it rides in the movement command rather than in a request, because it is held.
	var firing := DotFpsCommand.new()
	firing.set_button(ScNetCommand.BUTTON_FIRE, true)
	await _steps(4, firing)

	var behaviour: Variant = null

	for session_id in [SESSION]:
		behaviour = _server_bridge._behaviours.get(session_id)

	_check(
		behaviour != null and (behaviour as Node).get("last_move") != null
			and (behaviour.get("last_move") as DotFpsCommand).is_pressed(ScNetCommand.BUTTON_FIRE),
		"a button the client holds reaches the server"
	)

	_finished()


# --- The local player is predicted -------------------------------------------

## [b]This client's own player is predicted, and nobody else is.[/b]
##
## Until 2026-09-25 `ScNetBridge._apply_join` mirrored every player with owner 0, this
## client's own included, so `is_owner` was false for the local player, `predicted()` was
## empty, and `client_tick` simulated nobody: the player moved only when a snapshot came
## back, a round trip behind the keys, and the camera — drawn from `render_state`, a blend
## against a previous tick the controller never recorded — lurched between wherever the
## player last teleported and wherever the server had them. "A client moves itself and the
## server agrees" passed throughout, because a client adopting every snapshot also agrees
## with the server, and its correction rate was zero because the predictor never ran.
##
## So these assert the MECHANISM rather than the agreement: who owns the entity, what the
## registry predicts, that a key moves the player in the tick it is pressed with no snapshot
## in between, and that a move the client could not know about is corrected and converges.
## mg-buses-from-hell had the same line and found it first.
func _test_the_local_player_is_predicted() -> void:
	_section("the local player is predicted, and nobody else is")

	var client_player: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var server_player: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))
	var mine := _identity_of(client_player)

	if mine == null or server_player == null:
		_check(false, "the client has an identity for its own player")
		for _i in range(9):
			_check(false, "(skipped: no local identity)")
		_finished()
		return

	_check(true, "the client has an identity for its own player")
	_check(
		mine.owner_peer_id == _client_net.local_peer_id and mine.is_owner,
		"which this client owns",
		"owner %d, local peer %d, is_owner %s" % [
			mine.owner_peer_id, _client_net.local_peer_id, mine.is_owner
		]
	)

	var predicted := _client_net.registry.predicted()
	_check(
		mine.is_predicted() and predicted.has(mine),
		"and predicts: the registry's predicted set holds it",
		"%d predicted" % predicted.size()
	)

	# The stand-in is somebody else's, and a client predicting it would be simulating a
	# person whose keys it never had.
	var theirs := _identity_of(
		_client_game.players.get(_stand_in.player_id) if _stand_in != null else null
	)
	_check(
		theirs != null and not theirs.is_owner and not theirs.is_predicted()
			and not predicted.has(theirs) and predicted.size() == 1,
		"and nobody else is: one predicted, and not the stand-in",
		"%d predicted of %d players" % [predicted.size(), _client_game.players.size()]
	)

	# On a standing deck's middle, facing along +X, and still: the next tick starts from
	# agreement. An earlier section ran this player a long way and collapsed a deck.
	var deck = null
	for index in range(_server_game.platforms.count()):
		var candidate = _server_game.platforms.deck_at(index)
		if candidate != null and candidate.is_standing():
			deck = candidate
			break
	server_player.place_at(deck.centre + Vector3(0.0, 1.2, 0.0), 0.0)
	await _steps(40)

	# [b]One tick by hand, measured between the client's tick and the flush that would
	# carry anything back.[/b] The server has already simulated this tick without the
	# command — it is stamped INPUT_LEAD ahead — so any movement here is the client's own.
	_tick += 1
	var _t := _client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	forward.yaw = 0.0

	var shown_before := client_player.global_position
	var server_before := server_player.controller.state.position
	_client_bridge.client_tick(_tick + INPUT_LEAD, forward)
	var shown_after := client_player.global_position

	_check(
		shown_after.distance_to(shown_before) > 0.005,
		"a key moves the player on the client in the tick it is pressed",
		"%.4f m" % shown_after.distance_to(shown_before)
	)
	_check(
		server_player.controller.state.position.distance_to(server_before) < 0.0001,
		"before the server has simulated it, and before any snapshot",
		"server moved %.4f m" % server_player.controller.state.position.distance_to(server_before)
	)

	_flush()
	await get_tree().physics_frame

	# A short straight run, then stop. Printed rather than asserted: it is the number to
	# watch, and positive is the client drawing the player AHEAD of the server along the run,
	# which is what prediction with an input lead looks like.
	var before := _client_net.predictor.describe()
	await _steps(30, forward)
	var lead := (client_player.controller.state.position - server_player.controller.state.position).dot(Vector3.FORWARD)
	var after := _client_net.predictor.describe()
	print("        running: %d replays, %d corrections; client %+.2f m from the server along the run" % [
		int(after["replays"]) - int(before["replays"]),
		int(after["corrections"]) - int(before["corrections"]),
		lead,
	])

	await _steps(30)
	_check(
		client_player.global_position.distance_to(server_player.controller.state.position) < 0.05,
		"stopped, the client shows the player where the server has them",
		"%.3f m apart" % client_player.global_position.distance_to(
			server_player.controller.state.position
		)
	)

	# [b]A disagreement the client cannot know about[/b]: an admin puts the player somewhere
	# on the server. The client predicted standing still, so the next snapshot is a
	# correction — and the proof that the predictor RUNS, rather than the client simply
	# adopting what it is sent, is that its correction count moves.
	var corrected_before := int(_client_net.predictor.describe()["corrections"])
	var moved_to := server_player.controller.state.position + Vector3(1.5, 0.0, 0.0)
	server_player.place_at(moved_to, server_player.controller.state.yaw)
	await _steps(30)

	var corrected := int(_client_net.predictor.describe()["corrections"]) - corrected_before
	_check(
		corrected > 0,
		"a move the client did not predict is corrected",
		"%d corrections" % corrected
	)
	_check(
		client_player.global_position.distance_to(server_player.controller.state.position) < 0.05
			and client_player.controller.state.position.distance_to(moved_to) < 0.2,
		"and converges on where the server put them",
		"%.3f m apart, %.3f m from the teleport" % [
			client_player.global_position.distance_to(server_player.controller.state.position),
			client_player.controller.state.position.distance_to(moved_to),
		]
	)

	# [b]Once the floor has settled, and not before.[/b] Moving somebody a metre and a half
	# across a platform moves its load, so the platform swings to a new lean over the next
	# couple of seconds — and a client draws that lean from snapshots it runs INPUT_LEAD
	# ticks ahead of, so a player standing on a floor that is still moving is corrected by a
	# centimetre now and then (the epsilon is one). That is the floor being the server's, as
	# it must be; the first version of this check measured the thirty ticks straight after the
	# move and failed one run in two on exactly that. Two seconds is the spring's damping
	# taking the swing down to a twentieth.
	await _steps(128)
	var settled := int(_client_net.predictor.describe()["corrections"])
	await _steps(30)
	_check(
		int(_client_net.predictor.describe()["corrections"]) == settled,
		"and then stays converged: no correction while nothing disagrees",
		"%d more" % (int(_client_net.predictor.describe()["corrections"]) - settled)
	)

	_finished()


# --- Somebody else, drawn ---------------------------------------------------

## A second person on their own peer, as this client draws them.
##
## [b]Nothing drew another player on a connected client until 2026-09-24,[/b] and nothing
## called `DotNetManager.interpolate_frame` either, so what a remote player's node did was
## step at the snapshot rate towards a body that did not exist. Every check here goes
## through `ScClient.present_frame`, the function the real client's `_process` calls, at
## FRAMES_PER_TICK frames a tick with the fraction a renderer would pass.
## Who somebody is reaches every client: the face they were seated with, and a new name and
## face when the server learns them — which is what dot-platform's admission, a wardrobe
## change and an operator's rename all end in.
##
## [b]Asserted on the drawn figure, not on the field.[/b] A client that stored the avatar
## and drew the hash anyway would pass every check about the document; the atlas the
## figure was BUILT with is the thing a player sees.
func _test_who_somebody_is_crosses() -> void:
	_section("who somebody is crosses, and is what is drawn")

	_check(
		ScAvatars.SKINS.size() == ScFigure.ATLASES.size(),
		"there is one skin per atlas, so a skin index is an atlas index",
		"%d skins, %d atlases" % [ScAvatars.SKINS.size(), ScFigure.ATLASES.size()]
	)

	# What the module hands the bridge: the platform's answer. A fixed face here, chosen to
	# be one this session's id does NOT hash to, or a figure built from the hash would pass.
	var face_key := ScNetBridge.player_key(FACE_SESSION)
	var chosen := (ScAvatars.stock_index(face_key) + 3) % ScAvatars.SKINS.size()
	var face := ScAvatars.stock_avatar(face_key)
	face.set_part(ScAvatars.SLOT_SKIN, ScAvatars.SKINS[chosen])
	_server_bridge.avatar_fn = func(session_id: int) -> DotAvatar:
		return face if session_id == FACE_SESSION else null

	var seated := _server_bridge.add_player(FACE_PEER, FACE_SESSION, "Cyd")
	_server_bridge.avatar_fn = Callable()
	await _steps(6)

	var theirs: ScPlayer = _client_game.players.get(face_key)
	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))

	if not seated.ok or theirs == null or mine == null:
		_check(false, "a player seated with a face reaches the client",
			str(seated.error) if not seated.ok else "not on the client")
		_finished()
		return

	var _shown := ScClient.present_frame(_client_net, _client_game, mine, true, 1.0 / 60.0, 0.0)
	# Your own player is drawn at the clock's render alpha (dot-player-controller's
	# `render_clock`), so a clock slip does not stall or double the eye.
	_check(
		mine.controller != null and mine.controller.get(&"render_clock") == _client_net.clock,
		"your own player is drawn on the client clock's render alpha"
	)
	_check(
		theirs.avatar != null and theirs.avatar.digest() == face.digest(),
		"a player seated with a face arrives wearing it"
	)
	_check(
		theirs.figure != null and theirs.figure.atlas == str(ScFigure.ATLASES[chosen]),
		"and is drawn in it, not in the one their id hashes to",
		theirs.figure.atlas.get_file() if theirs.figure != null else "no figure"
	)

	# Later: the profile arrives, or they change their face, or an operator renames them.
	# The same person, because the section before this one has already let Bea go.
	var other_key := face_key
	var other: ScPlayer = theirs
	# Neither the face they have nor the one their id hashes to.
	var later := (chosen + 1) % ScAvatars.SKINS.size()
	if later == ScAvatars.stock_index(other_key):
		later = (later + 1) % ScAvatars.SKINS.size()
	var changed := ScAvatars.stock_avatar(other_key)
	changed.set_part(ScAvatars.SLOT_SKIN, ScAvatars.SKINS[later])

	var told := _server_bridge.refresh_player(FACE_SESSION, "Beatrix", changed)
	await _steps(4)
	_shown = ScClient.present_frame(_client_net, _client_game, mine, true, 1.0 / 60.0, 0.0)

	_check(
		told and other != null and other.display_name == "Beatrix"
			and _server_game.players.get(other_key).display_name == "Beatrix",
		"a new name reaches the server's world and the client's",
		other.display_name if other != null else "gone"
	)
	_check(
		other != null and other.figure != null
			and other.figure.atlas == str(ScFigure.ATLASES[later]),
		"and a new face is drawn the frame after, without them rejoining",
		other.figure.atlas.get_file() if other != null and other.figure != null else "-"
	)

	# A document for another game's schema is nobody this game can draw.
	var foreign := DotAvatar.make(&"some_other_game")
	foreign.set_part(ScAvatars.SLOT_SKIN, ScAvatars.SKINS[later])
	_server_bridge.refresh_player(FACE_SESSION, "", foreign)
	await _steps(4)
	_shown = ScClient.present_frame(_client_net, _client_game, mine, true, 1.0 / 60.0, 0.0)

	_check(
		other != null and other.display_name == "Beatrix" and other.figure != null
			and other.figure.atlas
				== str(ScFigure.ATLASES[ScAvatars.stock_index(other_key)]),
		"a face from another game's schema is the stock person, and the name is kept",
		other.figure.atlas.get_file() if other != null and other.figure != null else "-"
	)

	_server_bridge.remove_peer(FACE_PEER)
	await _steps(4)
	_check(
		not _client_game.players.has(face_key),
		"and the third person leaves again, so the sections after count as before"
	)

	_finished()


func _test_somebody_else_is_drawn() -> void:
	_section("somebody else is drawn, where they are, every frame")

	var seated := _server_bridge.add_player(OTHER_PEER, OTHER_SESSION, "Bea")
	_check(seated.ok, "a second player joins on their own peer")
	await _steps(8)

	var key := ScNetBridge.player_key(OTHER_SESSION)
	var theirs: ScPlayer = _client_game.players.get(key)
	var server_theirs: ScPlayer = _server_game.players.get(key)
	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))

	if theirs == null or server_theirs == null or mine == null:
		_check(false, "the client knows them", "theirs %s, server %s, mine %s" % [
			str(theirs != null), str(server_theirs != null), str(mine != null)
		])
		_finished()
		return

	var shown := ScClient.present_frame(_client_net, _client_game, mine, true, 1.0 / 60.0, 0.0)
	_check(
		theirs.figure != null and theirs.figure.visible and theirs.figure.from_art,
		"the client draws a body for them, from the Kenney art",
		str(theirs.describe().get("figure", {}))
	)
	_check(
		mine.figure == null or not mine.figure.visible,
		"and none round its own first-person camera"
	)
	# The stand-in is the third: a bot on the server is somebody else here like anybody.
	_check(shown == _client_game.players.size() - 1, "so everybody but this client is drawn",
		"%d of %d" % [shown, _client_game.players.size()])

	var _tp := ScClient.present_frame(_client_net, _client_game, mine, false, 1.0 / 60.0, 0.0)
	var mine_in_tp := mine.figure != null and mine.figure.visible
	var _fp := ScClient.present_frame(_client_net, _client_game, mine, true, 1.0 / 60.0, 0.0)
	_check(
		mine_in_tp and not mine.figure.visible,
		"in third person its own body is drawn, and back in first it is gone again"
	)

	# Running across a platform along -X (a yaw of -90 in this controller), from near one
	# edge to past the middle — a second at full speed, which on a 10.5 m deck is most of the
	# way across. Put there first, the way the game puts anybody, so the run stays on it.
	# A STANDING deck: an earlier section collapsed one, and a player put on that is a
	# player falling forty metres with a slightly different start.
	var deck = null
	for index in range(_server_game.platforms.count()):
		var candidate = _server_game.platforms.deck_at(index)
		if candidate != null and candidate.is_standing():
			deck = candidate
			break
	server_theirs.place_at(deck.centre + Vector3(4.5, 1.2, 0.0), -90.0)
	await _steps(16)

	var bea_net: Variant = _server_bridge._behaviours.get(OTHER_SESSION)
	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	run.yaw = -90.0
	(bea_net as Object).set(&"last_move", run)

	var server_track: Array[Vector3] = []
	var drawn: Array[Vector3] = []
	var clips: Array[StringName] = []

	for i in range(64):
		await _step()
		server_track.append(server_theirs.controller.state.position)

		for f in range(FRAMES_PER_TICK):
			var _n := ScClient.present_frame(
				_client_net, _client_game, mine, true, 1.0 / 60.0,
				float(f) / float(FRAMES_PER_TICK)
			)
			if i >= 20:
				drawn.append(theirs.figure.global_position)
		clips.append(theirs.figure.clip)

	(bea_net as Object).set(&"last_move", DotFpsCommand.new())

	var ran := server_track[server_track.size() - 1].distance_to(server_track[0])
	_check(
		ran > 3.0 and server_theirs.is_alive() and server_track[server_track.size() - 1].y > 30.0,
		"the server runs them across the deck, and they stay on it",
		"%.2f m, ending at %s" % [ran, str(server_track[server_track.size() - 1].snapped(Vector3.ONE * 0.01))]
	)

	# On the path: every frame within a hand of SOME position the server really had them at.
	# Not the latest, because a remote player is drawn an interpolation delay in the past on
	# purpose; the nearest point on the server's own track is the fair test.
	var worst := 0.0
	for at in drawn:
		var nearest := INF
		for p in server_track:
			nearest = minf(nearest, at.distance_to(p))
		worst = maxf(worst, nearest)

	_check(
		not drawn.is_empty() and worst < 0.25,
		"every frame draws the body on the path the server ran them along",
		"worst %.3f m off it, over %d frames" % [worst, drawn.size()]
	)

	var last: Vector3 = drawn[drawn.size() - 1] if not drawn.is_empty() else Vector3.ZERO
	_check(
		last.distance_to(Vector3.ZERO) > 10.0,
		"up on the field rather than at the world origin, forty metres below it",
		"last drawn %s" % str(last.snapped(Vector3.ONE * 0.01))
	)

	# Smoothness: each frame should move the body by about what the frame before it did. A
	# client that draws only when a snapshot lands moves it on one frame in several and not
	# at all on the rest. [b]Measured against the server's own run[/b], because the run is
	# not steady here: a platform leans toward whoever is on it and the deck's surface moves
	# under them, and the server's per-tick step halves in a single tick at one point of this
	# run. A drawn body may change its pace as sharply as the server's did, and no more.
	var mean := 0.0
	var steps: Array[float] = []
	for j in range(1, drawn.size()):
		var d := drawn[j].distance_to(drawn[j - 1])
		steps.append(d)
		mean += d
	mean /= float(maxi(steps.size(), 1))

	var jerk := 0.0
	for j in range(1, steps.size()):
		jerk = maxf(jerk, absf(steps[j] - steps[j - 1]))

	var server_jerk := 0.0
	for t in range(2, server_track.size()):
		var now := server_track[t].distance_to(server_track[t - 1])
		var before := server_track[t - 1].distance_to(server_track[t - 2])
		server_jerk = maxf(server_jerk, absf(now - before) / float(FRAMES_PER_TICK))

	_check(
		mean > 0.001 and jerk <= server_jerk + mean * 0.25,
		"and it moves by an even step on every frame, not in snapshot-sized jumps",
		"per frame %.4f m mean; largest change between two frames %.4f, the server's own %.4f"
			% [mean, jerk, server_jerk]
	)
	_check(
		absf(wrapf(theirs.figure.rotation.y - deg_to_rad(-90.0), -PI, PI)) < 0.05,
		"facing the way the server says they are looking",
		"%.1f deg" % rad_to_deg(theirs.figure.rotation.y)
	)
	_check(
		clips[clips.size() - 1] == &"run",
		"and running, rather than sliding across in a standing pose",
		String(clips[clips.size() - 1])
	)

	# In the chopper: the server seats them, and the client draws the machine, not a person
	# frozen on the pad they climbed in from.
	_server_game._set_riding(key, true)
	await _steps(8)
	var _seat := ScClient.present_frame(_client_net, _client_game, mine, true, 1.0 / 60.0, 0.0)
	_check(
		theirs.riding and not theirs.figure.visible,
		"a pilot is drawn as the chopper, not as a body left on the pad",
		"riding %s, visible %s" % [str(theirs.riding), str(theirs.figure.visible)]
	)
	_server_game._set_riding(key, false, server_theirs.controller.state.position)
	await _steps(8)

	# The showdown's teleport: the handover's own call, with the handover's own corner. Sixty
	# metres in one tick, arriving through the ordinary snapshot path.
	var team_index := _server_game.team_of(key) - 1
	var teams := _server_game.config.team_count
	var corner := _server_game.arena.showdown_spawn(team_index, teams, 0, 1)
	var corner_yaw := _server_game.arena.showdown_yaw(team_index, teams)
	var left_from := server_theirs.controller.state.position
	server_theirs.place_at(corner, corner_yaw)

	var strays := 0
	for _i in range(24):
		await _step()
		for f in range(FRAMES_PER_TICK):
			var _n := ScClient.present_frame(
				_client_net, _client_game, mine, true, 1.0 / 60.0,
				float(f) / float(FRAMES_PER_TICK)
			)
			var at := theirs.figure.global_position
			if at.distance_to(left_from) > 2.0 and at.distance_to(corner) > 2.0:
				strays += 1

	# Against where the SERVER has them, which is the corner plus whatever settling onto the
	# pad did, and the way the server has them facing — which after the teleport is the yaw
	# their own next command carried, as it would be for any peer.
	var landed := server_theirs.controller.state.position
	var arrived := theirs.figure.global_position.distance_to(landed)
	_check(
		theirs.figure.visible and arrived < 0.5 and landed.distance_to(corner) < 2.0,
		"after the showdown teleport the body is drawn in their corner",
		"%.2f m from where the server has them, %.2f m from the corner" % [
			arrived, landed.distance_to(corner)
		]
	)
	_check(
		absf(wrapf(theirs.figure.rotation.y - deg_to_rad(server_theirs.controller.state.yaw), -PI, PI)) < 0.05,
		"facing the way the server has them facing",
		"%.1f vs %.1f deg" % [
			rad_to_deg(theirs.figure.rotation.y), server_theirs.controller.state.yaw
		]
	)
	_check(
		strays == 0,
		"and never drawn in the sky between, sweeping sixty metres",
		"%d frames between the two" % strays
	)

	_server_bridge.remove_player(OTHER_SESSION)
	_exchange()
	await _steps(2)
	_check(not _client_game.players.has(key), "and they leave again, so nothing after this sees them")
	_finished()


# --- Phases, specials, chat -------------------------------------------------

func _test_the_phases() -> void:
	_section("the round's halves reach the client")

	var seen: Array[int] = []
	_client_bridge.phase_received.connect(func(p: int) -> void: seen.append(p))

	_check(_server_game.phase == ScGame.Phase.SURVIVAL, "the server is on the platforms",
		ScGame.Phase.keys()[_server_game.phase])

	# Wind the survival clock on rather than waiting two minutes of simulated time.
	_server_game.round_elapsed = _server_game.config.survival_seconds - 0.05
	await _steps(10)

	_check(_server_game.phase == ScGame.Phase.HANDOVER, "the clock sends it to the corners",
		ScGame.Phase.keys()[_server_game.phase])
	_check(seen.has(ScGame.Phase.HANDOVER), "and the client is told")
	_check(_client_game.phase == ScGame.Phase.HANDOVER, "and adopts it",
		ScGame.Phase.keys()[_client_game.phase])

	var theirs: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))
	_check(theirs != null and theirs.weapons != null, "the survivor was armed on the server")

	var corner := _server_game.arena.corner_point(
		theirs.team - 1, _server_game.config.team_count
	)
	var apart := Vector2(
		theirs.controller.state.position.x - corner.x,
		theirs.controller.state.position.z - corner.z
	).length()
	_check(apart < _server_game.config.corner_size, "and moved to their corner",
		"%.1f m from the middle of it" % apart)

	# And the client's copy follows them there, which is a sixty-metre teleport arriving
	# through the ordinary snapshot path.
	await _steps(8)

	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var followed := mine.controller.state.position.distance_to(theirs.controller.state.position)
	_check(followed < 3.0, "and the client's copy went with them", "%.2f m apart" % followed)

	_server_game.round_elapsed = _server_game.config.showdown_starts_at() + 0.05
	await _steps(10)

	_check(seen.has(ScGame.Phase.SHOWDOWN), "the showdown is announced too")

	_finished()


## What a watcher can see of somebody else's weapon.
##
## [b]A counter, never an event per shot.[/b] An RPC per shot needs a reliable channel for
## something worthless if it arrives late, costs a packet per shot per watcher, and
## desynchronises from the state it belongs with — so a watcher sees the muzzle flash of a
## weapon the same snapshot says has been holstered. game-playground shipped weapons that
## were free and that nobody could see anybody else holding, from a `write_weapon` whose
## `read_weapon` was never called.
func _test_a_weapon_crosses() -> void:
	_section("a weapon crosses")

	var theirs: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))

	if theirs == null or theirs.weapons == null:
		for what in [
			"the carrier is holding something on the server",
			"and the client is told which slot",
			"a watcher draws the weapon the server has in their hand",
			"at the end of the figure's right arm",
			"a use crosses as a counter",
			"which a watcher reads as a number of uses",
			"and the magazine is owner-only",
		]:
			_check(false, what)

		_finished()
		return

	_check(theirs.weapons.arsenal.current_slot() > 0,
		"the carrier is holding something on the server",
		"slot %d" % theirs.weapons.arsenal.current_slot())

	await _steps(6)

	var watcher: Variant = _client_bridge._behaviours.get(SESSION)
	_check(watcher != null, "the client has a behaviour watching them")

	if watcher == null:
		_check(false, "and the client is told which slot")
		_check(false, "a watcher draws the weapon the server has in their hand")
		_check(false, "at the end of the figure's right arm")
		_check(false, "a use crosses as a counter")
		_check(false, "which a watcher reads as a number of uses")
		_check(false, "and the magazine is owner-only")
		_finished()
		return

	_check(
		int(watcher.get(&"net_slot")) == theirs.weapons.arsenal.current_slot(),
		"and the client is told which slot",
		"%d vs %d" % [int(watcher.get(&"net_slot")), theirs.weapons.arsenal.current_slot()]
	)

	# [b]The gun in their hand, as somebody else draws it.[/b] Dealt the way the module
	# announces a deal — every weapon, the selected one first — and drawn from the slot the
	# snapshot carries, because a slot alone names no weapon. The client's copy of this player
	# is drawn as a watcher would draw it (not its own first-person view).
	var current := theirs.weapons.arsenal.current_def()
	_server_bridge.announce_armed(theirs.player_id, current.id)
	for slot in theirs.weapons.arsenal.slots():
		var other_def := theirs.weapons.arsenal.slot_at(slot).def
		if other_def.id != current.id:
			_server_bridge.announce_armed(theirs.player_id, other_def.id)
	_exchange()
	await _steps(2)

	var copy: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var _shown := copy.present_body(false, copy.global_position, Color.WHITE)
	var hand := copy.figure.attachment(&"right_hand") if copy.figure != null else null
	_check(
		copy.figure != null and copy.figure.holding == current.id and copy.figure.held != null
			and copy.figure.held.equipped() == current.id,
		"a watcher draws the weapon the server has in their hand",
		"%s drawn, %s held, dealt %s" % [
			String(copy.figure.holding) if copy.figure != null else "-", String(current.id),
			str(copy.dealt)
		]
	)
	_check(
		hand != null and copy.figure.held.get_parent() == hand
			and hand.get_parent() is BoneAttachment3D,
		"in the person's gun hand (a bone attachment)",
		str(hand.get_parent().name) if hand != null else "no hand"
	)

	var uses: Array[int] = []
	(watcher as Object).connect("weapon_used", func(times: int, _kind: int) -> void:
		uses.append(times)
	)

	var before := int(watcher.get(&"net_fire_seq"))

	# Fired on the server the way a player fires: the button rides in the movement command,
	# because it is held and has to be ordered against the movement it was aimed with.
	var firing := DotFpsCommand.new()
	firing.set_button(ScNetCommand.BUTTON_FIRE, true)
	await _steps(24, firing)

	var after := int(watcher.get(&"net_fire_seq"))
	_check(
		after != before or theirs.weapons.fire_seq > 0,
		"a use crosses as a counter",
		"%d -> %d, rig at %d" % [before, after, theirs.weapons.fire_seq]
	)
	_check(not uses.is_empty(), "which a watcher reads as a number of uses",
		"%d reports" % uses.size())

	# [b]Owner-only, and it is information rather than bandwidth.[/b] Exact ammunition is
	# something an opponent should not have; dot-combat makes the same decision about the
	# same two numbers. This client IS the owner, so it does get them — what the check can
	# say is that the field is declared that way at all.
	var owner_only := false

	for spec in ZeeWeaponNet.all_specs():
		if spec["property"] == &"net_magazine":
			owner_only = bool(spec["owner_only"])

	_check(owner_only, "and the magazine is owner-only")

	# [b]Lag compensation, wired rather than declared.[/b] dot-combat takes a rewind and a
	# restore as callables and, unset, says so once at boot and resolves every shot against
	# the present anyway — a flag reported as enabled with nothing behind it. This is the
	# check that says the two ends of that seam are actually joined.
	var combat := _server_game.combat.describe()
	_check(bool(combat["lagcomp"]), "lag compensation is wired to the netcode's history")
	_check(
		_server_game.combat.rewind_fn.is_valid() and _server_game.combat.restore_fn.is_valid(),
		"with BOTH callables, because a rewind that is never restored leaves the whole level in the past"
	)
	_check(int(combat["entities"]) >= 2, "and there are hitboxes to rewind",
		"%d" % int(combat["entities"]))

	_finished()


## The weapon-feel pass's wire half (`ScGame.hit_landed` → HIT → `hit_received`, and the owner-only
## magazine that `ScClient.correct_drawn` adopts). `headless_run` only proves the offline half,
## where the world's own signal flashes the marker and nothing crosses. Armed: with the bridge's
## HIT send removed the first check fails; sent with `_broadcast` the second does.
func _test_a_hit_is_the_shooters() -> void:
	_section("a shot that lands is told to the shooter alone, and the drawn gun takes the server's count")
	var key := ScNetBridge.player_key(SESSION)
	var server_me: ScPlayer = _server_game.players.get(key)
	var mine: ScPlayer = _client_game.players.get(key)
	var hits: Array = []
	var heard := func(point: Vector3, killed: bool, headshot: bool) -> void:
		hits.append([point, killed, headshot])
	_client_bridge.hit_received.connect(heard)

	# A second connected player, READY, so a HIT that went to everybody would reach somebody.
	var _seated := _server_bridge.add_player(BYSTANDER_PEER, BYSTANDER_SESSION, "Dov")
	_server_bridge._admit(BYSTANDER_PEER)
	# Two seconds still: the last section's trigger lets go, and a bolt-action gun (the handover
	# deals a sniper rifle) is ready again, so one press here is one shot.
	var still := DotFpsCommand.new()
	await _steps(SERVER_TICK_RATE * 2, still)
	var full := server_me.weapons.arsenal.current().magazine if server_me.weapons != null else -1

	# Point-blank, straight down the aim: the stand-in (the other side) three metres ahead.
	var aim := DotWeaponCommand.new()
	var ahead := aim.aim_direction()
	_stand_in.place_at(server_me.global_position + ahead * 3.0, 180.0)
	# Hit but never killed: a kill could end the showdown and take the gun this section counts.
	var target_health := _server_game.combat.health_of(_stand_in.entity_id)
	target_health.cannot_die = true
	_sent_events.clear()
	_listening = true

	var fire := DotFpsCommand.new()
	fire.set_button(ScNetCommand.BUTTON_FIRE, true)
	await _steps(2, fire)
	await _steps(INPUT_LEAD + 6, still)

	var to_shooter := _events_of(ScEvents.Kind.HIT, CLIENT_PEER)
	_check(not hits.is_empty() and to_shooter > 0, "the shooter's bridge is told the shot landed",
		"%d heard, %d sent to the shooter, stand-in alive %s" % [hits.size(), to_shooter, str(_stand_in.is_alive())])
	var elsewhere := _events_of(ScEvents.Kind.HIT, BYSTANDER_PEER) + _events_of(ScEvents.Kind.HIT, 0)
	_check(elsewhere == 0, "and nobody else is: no HIT to the other player, none broadcast", "%d" % elsewhere)
	_check(not hits.is_empty() and (hits[0][0] as Vector3).distance_to(_stand_in.global_position) < 2.5,
		"at the server's point, on the body that was hit",
		"%s, body at %s" % [str(hits[0][0]) if not hits.is_empty() else "-", str(_stand_in.global_position)])

	# Shot back: this player the victim, and a victim is told nothing.
	hits.clear()
	_sent_events.clear()
	var shot_back := DotShot.new()
	shot_back.attacker = _stand_in.entity_id
	var wound := DotDamage.make(_stand_in.entity_id, server_me.entity_id, 1.0, null)
	wound.health_lost = 1.0
	wound.point = server_me.global_position + Vector3.UP
	shot_back.damages.append(wound)
	_server_game._note_hits(_stand_in, shot_back)
	await _steps(4, still)
	_check(hits.is_empty() and _events_of(ScEvents.Kind.HIT, CLIENT_PEER) == 0,
		"a hit somebody else landed on this player is not this player's marker", "%d" % hits.size())

	# The count: the magazine the server spent arrives in the owner's snapshot fields, and a drawn
	# gun that predicted wrong adopts it once quiet, through the client's own correct_drawn.
	var server_mag := server_me.weapons.arsenal.current().magazine
	var behaviour: Variant = _client_bridge._behaviours.get(SESSION)
	var net_mag := int(behaviour.get(&"net_magazine")) if behaviour != null else -1
	_check(server_mag < full and net_mag == server_mag,
		"the server's magazine, spent, crosses to the owner", "full %d, server %d, client told %d" % [full, server_mag, net_mag])

	var client: Node = (load("res://game/sc_client.gd") as GDScript).new()
	var rig := ZeeWeaponRig.new()
	rig.name = "DrawnForTest"
	rig.role = ZeeWeaponRig.Role.SERVER
	rig.authority = false
	rig.tick_rate = _client_game.tick_rate
	mine.add_child(rig)
	var _set := rig.setup()
	var _given := rig.give(server_me.weapons.current_def().id)
	if rig.arsenal.current() == null or rig.arsenal.current_slot() != server_me.weapons.arsenal.current_slot():
		var _picked := rig.arsenal.select(server_me.weapons.arsenal.current_slot(), 0)
	rig.arsenal.current().magazine = rig.arsenal.current().def.magazine
	client.set(&"weapons", rig)
	client.set(&"player", mine)
	client.set(&"bridge", _client_bridge)
	client.set(&"_offline", false)
	client.set(&"_watch_id", SESSION)
	client.set(&"_drawn_quiet", 0.0)
	var early: bool = client.call(&"correct_drawn")
	var drawn_early := rig.arsenal.current().magazine
	client.set(&"_drawn_quiet", 1.0)
	var corrected: bool = client.call(&"correct_drawn")
	_check(not early and drawn_early != server_mag and corrected and rig.arsenal.current().magazine == server_mag,
		"the drawn gun takes the server's count once quiet, and not before",
		"before %d, after %d, server %d" % [drawn_early, rig.arsenal.current().magazine, server_mag])
	client.free()
	mine.remove_child(rig)
	rig.free()

	target_health.cannot_die = false
	_listening = false
	_client_bridge.hit_received.disconnect(heard)
	_server_bridge.remove_peer(BYSTANDER_PEER)
	await _steps(2)
	_finished()


func _test_a_special_is_announced() -> void:
	_section("something strange is announced")

	var told: Array[StringName] = []
	var blurbs: Array[String] = []

	_client_bridge.special_received.connect(
		func(id: StringName, starting: bool, blurb: String) -> void:
			if starting:
				told.append(id)
				blurbs.append(blurb)
	)

	var special := ScSpecials.by_id(&"feather")
	_server_game.special_changed.emit(special.id, true, special.blurb)
	_exchange()

	_check(told.has(&"feather"), "the client hears about it")
	_check(
		not blurbs.is_empty() and blurbs[0] == special.blurb,
		"and is handed what to shout, rather than looking it up in a catalogue it may not have"
	)

	# The folding itself is the server's, and the client never runs it — it is told the
	# consequences through the ordinary state.
	var both := ScSpecials.Active.new()
	both.fold(special)
	both.fold(ScSpecials.by_id(&"barrage"))
	_check(both.ids.size() == 2 and both.gravity_scale < 1.0, "two at once still multiply")

	_finished()


func _test_chat_crosses() -> void:
	_section("a line crosses")

	var asked: Array[String] = []
	var channels: Array[StringName] = []

	_server_bridge.say_requested.connect(
		func(peer_id: int, channel_id: StringName, text: String) -> void:
			asked.append("%d:%s" % [peer_id, text])
			channels.append(channel_id)
	)

	_client_bridge.ask_say(&"team", "bridge is going")
	_exchange()

	_check(asked.size() == 1, "the server is asked once", "%d" % asked.size())
	_check(
		not asked.is_empty() and asked[0] == "%d:bridge is going" % CLIENT_PEER,
		"with the peer the TRANSPORT reported, not one the body claimed",
		asked[0] if not asked.is_empty() else ""
	)
	_check(not channels.is_empty() and channels[0] == &"team", "and the channel asked for")

	# An empty line never leaves the client, which is the cheapest rate limit there is.
	_client_bridge.ask_say(&"team", "   ")
	_exchange()
	_check(asked.size() == 1, "an empty line is not sent at all")

	# And the other direction: a routed line the server hands back.
	var drawn: Array[String] = []
	_client_bridge.chat_received.connect(
		func(wire: Dictionary) -> void: drawn.append(str(wire.get("m", "")))
	)

	_server_bridge.send_chat(CLIENT_PEER, {
		"n": 1, "t": 0, "c": "team", "k": "say", "s": "u42", "d": "Ada", "w": "",
		"m": "on my way", "x": {"p": SESSION},
	})
	_exchange()

	_check(drawn.has("on my way"), "and a routed line comes back to be drawn")

	# A notice reaches one person. "You are talking too fast" is nobody else's business.
	var notices: Array[String] = []
	_client_bridge.notice_received.connect(func(text: String) -> void: notices.append(text))

	_server_bridge.notice(CLIENT_PEER, "you are gagged")
	_exchange()

	_check(notices.has("you are gagged"), "and a refusal reaches the one person who asked")

	_finished()


# --- A bad link -------------------------------------------------------------

func _test_a_lossy_link() -> void:
	_section("a link that loses things")

	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var theirs: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))

	# One snapshot in three on the floor. Snapshots are unreliable by design: a newer one
	# supersedes a lost one and resending a hundred-millisecond-old position is worse than
	# useless.
	_drop_every = 3

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	await _steps(50, forward)

	var apart := mine.controller.state.position.distance_to(theirs.controller.state.position)
	_check(apart < 3.0, "the two ends still agree about where the player is",
		"%.2f m apart" % apart)

	var dropped := _snapshot_count / maxi(_drop_every, 1)
	_check(dropped > 0, "with snapshots genuinely on the floor", "%d dropped" % dropped)

	# A platform's lean is in the snapshot, so a lossy link is exactly where a floor would
	# drift. It does not: the next snapshot carries the whole state rather than a delta
	# against one that never arrived.
	_drop_every = 0
	await _steps(8)

	# [b]The STANDING ones, because a falling platform's lean is not a comparable
	# number.[/b] It grows without bound on the way down and the wire carries half a radian,
	# so a falling platform saturates by design — and a check that included one would be
	# asserting that a quantised field can hold a value outside its own range.
	var worst := 0.0
	var compared := 0

	for i in range(_server_game.platforms.count()):
		var here := _server_game.platforms.deck_at(i)
		var there := _client_game.platforms.deck_at(i)

		if here == null or there == null or not here.is_standing():
			continue

		compared += 1
		worst = maxf(worst, (here.lean - there.lean).length())

	_check(compared > 0, "there are platforms left to compare", "%d" % compared)
	_check(worst < LEAN_EPSILON * 3.0, "and every standing platform's lean has caught up",
		"%.5f rad worst" % worst)

	_finished()


# --- An admin's marks -------------------------------------------------------

## An administrator's blind and beacon, through the real handlers, over a link that drops one
## snapshot in three.
##
## [b]The audience is the whole point of both.[/b] The client owns Ada and does not own the
## stand-in. A blind is its owner's screen and nobody else's, so Ada's must reach this client
## and the stand-in's must NOT — an opponent who could read it would know the moment
## somebody could not see. A beacon is for everybody, so both must arrive. Asserted on the
## client's own copy of each player, which is what its HUD and its renderer read.
##
## Armed: with `to_owner_only()` dropped from `ScPlayerNet`, "the client is never told
## about somebody else's" fails.
func _test_blind_and_beacon() -> void:
	_section("an admin's blind and beacon: who is told")

	# The handlers exactly as the server's services layer builds them, over the server's
	# world. Never set up: nothing here needs chat, voice or a store.
	var services := ScServices.new()
	services.game = _server_game
	var handlers := services._mod_abilities()
	var blind: Callable = handlers.get("blind", Callable())
	var beacon: Callable = handlers.get("beacon", Callable())
	_check(
		blind.is_valid() and beacon.is_valid() and not services._mod_unsupported().has("blind")
		and not services._mod_unsupported().has("beacon"),
		"the game supports both, and refuses neither"
	)

	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var bot_key := _stand_in.player_id if _stand_in != null else &""
	var theirs: ScPlayer = _client_game.players.get(bot_key)
	var mine_net := _behaviour_of(mine)
	var theirs_net := _behaviour_of(theirs)

	_check(
		mine_net != null and mine_net.find_var(&"net_blind").audience == DotNetVar.Audience.OWNER
		and mine_net.find_var(&"net_beacon").audience == DotNetVar.Audience.EVERYONE,
		"the blind is declared owner-only and the beacon for everybody"
	)

	var ada := String.num_int64(SESSION)
	var bot := String.num_int64(ScNetBridge.session_of(bot_key))
	var results: Array[DotResult] = [
		blind.call(StringName(ada), {"on": true, "actor": "1"}),
		blind.call(StringName(bot), {"on": true, "actor": "1"}),
		beacon.call(StringName(ada), {"on": true, "actor": "1"}),
		beacon.call(StringName(bot), {"on": true, "actor": "1"}),
	]
	_check(
		results.all(func(r: DotResult) -> bool: return r.ok),
		"the server blinds and beacons both players"
	)

	_drop_every = 3
	await _steps(24)

	_check(mine != null and mine.blinded, "the owner's client blacks its own screen out")
	_check(
		theirs != null and not theirs.blinded and theirs_net != null and not theirs_net.net_blind,
		"and the client is never told about somebody else's",
		"received net_blind = %s" % (str(theirs_net.net_blind) if theirs_net != null else "?")
	)
	_check(
		mine != null and mine.beacon and theirs != null and theirs.beacon,
		"while the client draws a beacon on both"
	)

	var server_identity := _identity_of(_server_game.players.get(ScNetBridge.player_key(SESSION)))
	_check(
		server_identity != null and server_identity.always_relevant,
		"a beaconed player is relevant to every peer — as every player here already is"
	)

	var _off: Array[DotResult] = [
		blind.call(StringName(ada), {"on": false, "actor": "1"}),
		blind.call(StringName(bot), {"on": false, "actor": "1"}),
		beacon.call(StringName(ada), {"on": false, "actor": "1"}),
		beacon.call(StringName(bot), {"on": false, "actor": "1"}),
	]
	await _steps(24)
	_drop_every = 0

	_check(
		not mine.blinded and not mine.beacon and not theirs.beacon,
		"and turning both off reaches the client"
	)
	# game-arena turns relevance off with the beacon. Here that would take the player out of
	# everybody's snapshot — see `ScPlayerNet._register_net_vars`.
	_check(
		server_identity != null and server_identity.always_relevant,
		"and a beacon turned off leaves the player relevant, which on this map is everybody"
	)

	var absent: DotResult = blind.call(&"9999", {"on": true, "actor": "1"})
	_check(not absent.ok, "a blind on nobody is refused rather than ignored")

	services.free()
	_finished()


## The two things a client makes a noise about that it could not have seen for itself.
##
## [b]A landing exists only on the server[/b] — a client runs no platform model and its
## props are frozen mirrors — so the IMPACT event is the only way it hears one. And the
## cannon's bang is a prop that ARRIVED at the muzzle, which is only true if the position a
## client is told is the one the prop was fired from rather than where it had got to.
func _test_what_is_heard_arrives() -> void:
	_section("what a client hears about arrives")

	var arrived: Array[Vector3] = []
	_client_bridge.prop_arrived.connect(func(at: Vector3, vehicle: bool) -> void:
		if not vehicle:
			arrived.append(at)
	)
	var landed: Array[Vector3] = []
	_client_bridge.impact_received.connect(
		func(at: Vector3, _outcome: int, _impulse: float) -> void: landed.append(at)
	)

	var _fired := _server_game.cannon.fire(_server_game.round_elapsed, _server_game.active)
	await _steps(2)

	var muzzle := _client_game.arena.muzzle()
	_check(
		not arrived.is_empty() and arrived[0].distance_to(muzzle) < ScAudio.MUZZLE_REACH,
		"a prop the cannon fires reaches the client at the mouth of the client's own tube",
		"%.2f m from it" % (arrived[0].distance_to(muzzle) if not arrived.is_empty() else INF)
	)

	# A platform still standing: an earlier section took one down on purpose, and a landing
	# on a platform that has gone is a landing on nothing, which is rightly not sent.
	var index := -1
	for i in range(_server_game.platforms.count()):
		if _server_game.platforms.deck_at(i).is_standing():
			index = i
			break

	var deck := _server_game.platforms.deck_at(maxi(index, 0))
	var hit := deck.centre + Vector3(2.0, 0.0, 1.0)
	var outcome := _server_game.platforms.report_impact(maxi(index, 0), 30.0, 10.0, hit)
	_exchange()
	_check(
		outcome == ScPlatforms.Impact.WOBBLE and not landed.is_empty()
			and landed[0].distance_to(hit) < 0.05,
		"and a landing on a platform is told to the client, where it landed",
		"%s, %d heard" % [ScPlatforms.Impact.keys()[outcome], landed.size()]
	)

	_finished()


## Somebody who is out is told where to look, by the server, and nobody else is.
##
## [b]The policy is the server's and the camera is the client's.[/b] The client's world
## runs a mirror, and what crosses is one `SPECTATE` event per decision, to the one peer it
## belongs to. What this asserts is the end state a player would see: the death camera over
## the drop rather than in the floor, a team-mate's eyes afterwards drawn from the client's
## OWN copy of that team-mate, and a refusal that comes back as words.
func _test_somebody_out_watches() -> void:
	_section("somebody who is out is told where to look")

	var views: Array[int] = []
	_client_bridge.spectate_received.connect(
		func(_viewer: int, mode: int, _target: int) -> void: views.append(mode)
	)
	var notices: Array[String] = []
	_client_bridge.notice_received.connect(func(text: String) -> void: notices.append(text))

	# This section is about the own-side policy, which is an operator's choice (the default
	# lets anybody watch anybody and roam); the next section puts it back.
	_server_game.spectate_rules.force_camera = 1

	# A team-mate for the client under test, so that being out leaves somebody on their own
	# side to watch — and so that the round does not simply end, which a side with nobody
	# alive does.
	var theirs: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))
	var mate := _server_bridge.add_bot("Mate", theirs.team if theirs != null else 2)
	_check(mate != null and mate.team == theirs.team, "a team-mate is seated beside them")
	await _steps(6)

	var me := ScNetBridge.player_key(SESSION)
	_check(not _client_game.spectate.is_spectating(me), "nobody playing is watching anything")

	var went := theirs.controller.state.position
	theirs.place_at(Vector3(went.x, _server_game.config.kill_height - 5.0, went.z), 0.0)
	await _steps(3)

	_check(not theirs.is_alive(), "the client's player fell and is out on the server")
	_check(
		views.has(DotSpectatorView.Mode.DEATH_CAM) and _client_game.spectate.is_spectating(me),
		"the client is told, and its own mirror now says it is watching"
	)

	var drop := _client_game.spectate.camera_for(me)
	_check(
		_client_game.spectate.mode_of(me) == DotSpectatorView.Mode.DEATH_CAM
			and drop.origin.y > _server_game.config.deck_height,
		"the death camera is up over the drop, not at the floor they hit",
		"y = %.1f" % drop.origin.y
	)

	await _steps(int(ceilf(1.6 * float(_server_game.tick_rate))))

	var mate_key := mate.player_id
	_check(
		_client_game.spectate.mode_of(me) == DotSpectatorView.Mode.FIRST_PERSON
			and _client_game.spectate.watching(me) == mate_key,
		"and then hands over to the team-mate's eyes",
		"%s on %s" % [
			DotSpectatorView.Mode.keys()[_client_game.spectate.mode_of(me)],
			String(_client_game.spectate.watching(me)),
		]
	)

	_check_watch_policy(me, mate_key, notices)

	_server_bridge.remove_player(ScNetBridge.session_of(mate_key))
	_exchange()
	_server_game.spectate_rules.force_camera = 0
	_finished()


## What the client draws and is told once somebody out is watching the team-mate under an own-side policy.
func _check_watch_policy(me: StringName, mate_key: StringName, notices: Array[String]) -> void:
	# From the CLIENT's copy of the team-mate: nothing about the camera crossed the wire but
	# who it is on, so it has to be where this client draws them.
	var copy: ScPlayer = _client_game.players.get(mate_key)
	var eye := _client_game.spectate.camera_for(me).origin
	var drawn := copy.global_position + Vector3(0.0, ScPlayer.EYE_HEIGHT, 0.0) \
		if copy != null else Vector3.INF
	_check(eye.distance_to(drawn) < 0.05, "at the eyes this client draws them with",
		"%.3f m" % eye.distance_to(drawn))

	# The other side is somebody the policy forbids, so the camera key is answered in words.
	_client_bridge.ask_spectate(0)
	_exchange()
	_exchange()
	_check(
		notices.any(func(t: String) -> bool: return t.contains("through their eyes")),
		"a camera the server's policy refuses comes back as a notice",
		" | ".join(notices)
	)
	_check(
		_client_game.spectate.mode_of(me) == DotSpectatorView.Mode.FIRST_PERSON,
		"and the camera stays where the server put it"
	)

	# And the server's own view of it, which is the one that decided.
	_check(
		not _server_game.spectate.manager.may_watch(String(me), String(_stand_in.player_id)).ok,
		"the other side's stand-in is somebody this server will not let them watch"
	)


func _test_free_roam_crosses() -> void:
	_section("free roam is asked for, the server decides, and the mode crosses the wire")
	var spectate := _server_game.spectate
	var rules := _server_game.spectate_rules
	var me := ScNetBridge.player_key(SESSION)
	# Out by a real fall (a round may have put them back in since the section before), then
	# the death camera hands over to whoever the open policy allows.
	var body: ScPlayer = _server_game.players[me]
	# A team-mate to keep the round going, or the fall ends it and everybody is back in.
	var mate := _server_bridge.add_bot("Mate", body.team)
	await _steps(6)
	if body.is_alive():
		var went := body.controller.state.position
		body.place_at(Vector3(went.x, _server_game.config.kill_height - 5.0, went.z), 0.0)
	await _steps(int(ceilf(2.5 * float(_server_game.tick_rate))))
	_check(spectate.is_spectating(me) and not spectate.is_roaming(me),
		"a watcher starts on a player, not in a free camera",
		"mode %s alive %s phase %s y %.1f" % [spectate.mode_of(me), body.is_alive(), _server_game.phase, body.global_position.y])
	_check(_client_game.spectate.is_spectating(me), "and the client's mirror is watching too")

	# The ask reaches the bridge's handler and the game's toggle_roam, not the manager direct.
	_client_bridge.ask_roam()
	await _steps(6)
	_check(spectate.is_roaming(me), "the server puts a watcher who asks into the free camera")
	_check(_client_game.spectate.is_roaming(me), "and the client's mirror is told ROAMING")
	_check(_client_game.spectate.line_for(me).contains("free camera"), "and its line names the free camera")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(me) and not _client_game.spectate.is_roaming(me),
		"the same key hands the camera back to a player on both ends")
	_check(_client_game.spectate.is_spectating(me), "and an empty target on the wire did not stop the watching")

	var notices: Array[String] = []
	_client_bridge.notice_received.connect(func(text: String) -> void: notices.append(text))
	rules.allow_roaming = false
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(me) and not _client_game.spectate.is_roaming(me),
		"mp_freeroam 0 refuses the request")
	_check(notices.any(func(t: String) -> bool: return t.contains("Free roam is off")),
		"and the refusal comes back as a notice", " | ".join(notices))
	rules.allow_roaming = true

	rules.force_camera = 1
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(me), "mp_forcecamera 1 refuses it too")
	rules.force_camera = 0

	_client_bridge.ask_roam()
	await _steps(6)
	_check(spectate.is_roaming(me), "asked again with the policy open, it roams")
	rules.allow_roaming = false
	await _steps(6)
	_check(not spectate.is_roaming(me) and not _client_game.spectate.is_roaming(me),
		"switching mp_freeroam off mid-roam puts the roamer back on a player on both ends")
	rules.allow_roaming = true
	_server_bridge.remove_player(ScNetBridge.session_of(mate.player_id))
	_exchange()
	_finished()


func _test_leaving() -> void:
	_section("leaving")

	var left: Array[int] = []
	_client_bridge.roster_changed.connect(func(id: int) -> void: left.append(id))

	var before := _client_game.players.size()

	# [b]The stand-in, not the client under test.[/b] `remove_player` takes a leaver out of
	# the ready set before it announces the LEAVE, which is correct — a server has nothing to
	# tell somebody who has gone — and it means the one departure a single-client suite can
	# actually observe is somebody else's.
	var bot_session := 0

	for session_id in _server_bridge._behaviours.keys():
		if int(session_id) != SESSION:
			bot_session = int(session_id)

	_check(bot_session != 0, "there is somebody else on the server to lose")

	_server_bridge.remove_player(bot_session)
	_exchange()
	_exchange()

	_check(
		not _server_game.players.has(ScNetBridge.player_key(bot_session)),
		"the server forgets them"
	)
	_check(left.has(bot_session), "the client is told")
	_check(
		_client_game.players.size() < before,
		"and forgets them too",
		"%d, was %d" % [_client_game.players.size(), before]
	)

	# And now the client itself, which is the path that cleans up dot-combat.
	var entity := (_server_game.players[ScNetBridge.player_key(SESSION)] as ScPlayer).entity_id
	_server_bridge.remove_player(SESSION)
	_exchange()

	_check(
		not _server_game.players.has(ScNetBridge.player_key(SESSION)),
		"and the client itself when it goes"
	)

	# [b]dot-combat keeps a health record per entity and nothing else tells it to let
	# go.[/b] game-buses-from-hell leaked one per player who ever joined, pointing at a node
	# freed with them — invisible, because a stale entity is never asked about.
	_check(_server_game.combat.health_of(entity) == null, "the combat manager let go of them")
	_check(_server_game.entities.key_for_id(entity) == &"", "and so did the entity table")

	_finished()


# --- The harness ------------------------------------------------------------


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


# --- Two builds --------------------------------------------------------------

## [b]A server and a client built from different sources, on one wire.[/b]
##
## Each registered an optional type the other lacks (see `_build`). Their tables cross as
## the join happens; each sends the other its own type, and each skips what it does not
## know without disturbing anything after it -- which the seventeen sections after this one
## then play on top of. And a client that REQUIRES a type this server lacks, or lacks the
## types this game requires, is refused with a sentence rather than left to misread.
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


## The field's toys over the wire: a beach ball per platform, paired by index on both ends,
## frozen copies, one pushed on the server followed on the client.
func _test_the_toys_reach_the_client() -> void:
	_section("the field's toys reach the client")
	await _steps(4)
	var count := _server_game.toys.count() if _server_game.toys != null else 0
	_check(count > 0 and _server_bridge.toy_count() == count and _client_bridge.toy_count() == count,
		"every ball is an entity on both ends, paired by index", "%d toys, %d and %d" % [count, _server_bridge.toy_count(), _client_bridge.toy_count()])
	if count == 0 or _client_game.toys == null or _client_game.toys.count() == 0:
		_finished()
		return
	var server_ball := _server_game.toys.toy(0)
	var client_ball := _client_game.toys.toy(0)
	_check(client_ball.body.freeze and not client_ball.authoritative, "the client's are frozen copies")
	var start := client_ball.body.global_position
	var _kicked := _server_game.toys.hit(server_ball.body, server_ball.body.global_position, Vector3(1, 0.2, 0), 1.0)
	await _steps(40)
	var apart := client_ball.body.global_position.distance_to(server_ball.body.global_position)
	_check(server_ball.body.global_position.distance_to(start) > 0.5 and apart < 0.8,
		"a ball pushed on the server is followed on the client",
		"%.2f m moved, %.2f m apart" % [server_ball.body.global_position.distance_to(start), apart])
	_finished()


## sv_workbench_remote over the real frames, in the order ScModule and ScClient register them: an admin gets a
## panel and an edit that applies and replicates; a guest, a non-admin, a revoked admin and the cvar off are refused.
## Builds the server's and the client's workbench over a loopback and returns what the checks drive.
func _workbench_rig(flags: Dictionary, state: Dictionary) -> Dictionary:
	var snet := _make_manager(true, &"wbserver", 1, self, SERVER_TICK_RATE)
	var cnet := _make_manager(false, &"wbclient", 5, self, SERVER_TICK_RATE)
	var sconfig := ScConfig.new()
	var cconfig := ScConfig.new()
	var sbinder := ScConfig.make_binder(sconfig)
	var cbinder := ScConfig.make_binder(cconfig)
	var _l1 := sbinder.load_layers()
	var _l2 := cbinder.load_layers()
	var set: DotProfileSet = null
	for candidate: DotProfileSet in sbinder.profile_sets():
		if candidate.rel_path.ends_with("round"):
			set = candidate
	var cset: DotProfileSet = null
	for candidate: DotProfileSet in cbinder.profile_sets():
		if candidate.rel_path.ends_with("round"):
			cset = candidate
	var swb := DotGameWorkbench.new()
	swb.dedicated = true
	swb.config = {"enabled": false}
	swb.add_set(set, "Game settings")
	add_child(swb)
	var started := swb.start()
	sbinder.attach(swb.api.runtime)
	var made := DotGameWorkbenchRemote.serve(snet)
	var slink := DotNetProfileLink.attach(snet, swb.api.runtime as DotProfileRuntime)
	var cremote := DotGameWorkbenchRemoteClient.attach(cnet)
	var crt := DotProfileRuntime.new()
	var clink := DotNetProfileLink.attach(cnet, crt)
	snet.messages.seal()
	cnet.messages.seal()
	var remote := swb.serve_remote(snet)
	_check(started.ok and made.ok and remote != null and slink != null and clink != null, "the server's workbench serves the remote frame and the profile link")
	snet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := cnet.receive(b, 1)
	cnet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := snet.receive(b, 5)
	var _s := snet.start()
	var _c := cnet.start()
	snet.add_peer(5)
	slink.peer_joined(5)
	remote.enabled_fn = func() -> bool: return state["on"]
	remote.uid_fn = func(_p: int) -> String: return state["uid"]
	remote.connected_fn = func(_p: int) -> bool: return true
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	remote.now_fn = func() -> int: return state["now"]
	remote.limiter = DotRateLimiter.new(1000.0, 1000.0)
	var cwb := DotGameWorkbench.new()
	cwb.panel_mode = 2
	cwb.config = {"enabled": false}
	cwb.remote_client = cremote
	cwb.remote_fn = func() -> bool: return true
	cwb.add_set(cset, "Game settings")
	add_child(cwb)
	var cstarted := cwb.start(crt)
	_check(cstarted.ok and cwb.overlay == null, "the client's workbench starts with no panel")
	var kind: String = set.rel_path
	var edit := {"op": "set", "kind": kind, "id": sbinder.profile_id, "key": "friendly_fire", "value": true}
	var srt := swb.api.runtime as DotProfileRuntime

	return {
		"snet": snet, "cnet": cnet, "sconfig": sconfig, "sbinder": sbinder, "swb": swb, "cwb": cwb,
		"cremote": cremote, "crt": crt, "srt": srt, "slink": slink, "clink": clink, "remote": remote,
		"kind": kind, "edit": edit,
	}


## An admin with the cvar off, then on: told no, then given a panel whose edits reach the server.
func _workbench_admin(rig: Dictionary, state: Dictionary) -> void:
	var cremote: DotGameWorkbenchRemoteClient = rig.cremote
	var cwb: DotGameWorkbench = rig.cwb
	var sconfig: ScConfig = rig.sconfig
	var sbinder: DotGameConfigBinder = rig.sbinder
	var crt: DotProfileRuntime = rig.crt
	var srt: DotProfileRuntime = rig.srt
	var kind: String = rig.kind
	var edit: Dictionary = rig.edit

	state["uid"] = "boss"
	cremote.ask()
	_check(not cremote.allowed and cwb.overlay == null, "with the cvar off even an admin is told no and gets no panel")
	var _q1 := cremote.request(edit)
	_check(not sconfig.friendly_fire, "and a request it forges anyway changes nothing on the server")

	state["on"] = true
	cremote.ask()
	_check(cremote.allowed and cremote.flags.has("cvar"), "with the cvar on an admin is told the flags it holds")
	_check(cwb.overlay != null, "and gets the panel")
	var applied: DotResult = cwb.api.handle(DotGameWorkbenchRemoteClient.ACTOR, edit)
	_check(applied.ok and sconfig.friendly_fire, "an edit from the panel reaches the server's live config", "" if applied.ok else applied.error.message)
	_check(crt.revision(kind, sbinder.profile_id) > 0 and crt.revision(kind, sbinder.profile_id) == srt.revision(kind, sbinder.profile_id), "and its row replicated to the client")


## A guest, a player with no flag and a revoked admin are refused, and the panel follows.
func _workbench_refusals(rig: Dictionary, state: Dictionary, flags: Dictionary) -> void:
	var cremote: DotGameWorkbenchRemoteClient = rig.cremote
	var cwb: DotGameWorkbench = rig.cwb
	var sconfig: ScConfig = rig.sconfig
	var remote: DotGameWorkbenchRemote = rig.remote
	var edit: Dictionary = rig.edit

	var back := edit.merged({"value": false})
	state["uid"] = ""
	var _q2 := cremote.request(back)
	_check(sconfig.friendly_fire, "a guest's forged edit is refused")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel is taken away from it")

	state["uid"] = "plain"
	cremote.ask()
	var _q3 := cremote.request(back)
	_check(not cremote.allowed and sconfig.friendly_fire, "a player holding no flag is told no and refused")

	state["uid"] = "boss"
	cremote.ask()
	_check(cremote.allowed and cwb.overlay != null, "an admin is let back in")
	flags["boss"] = []
	var _q4 := cremote.request(back)
	_check(sconfig.friendly_fire, "the revoked admin's next edit is refused at once")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel closes")

	flags["boss"] = ["cvar", "root"]
	state["on"] = false
	var _q5 := cremote.request(back)
	_check(sconfig.friendly_fire, "switching the cvar off refuses a restored admin too")
	_check(not remote.permit_actor("remote:boss", "cvar"), "and revokes the server-made actors")


func _test_the_remote_workbench() -> void:
	_section("[a flagged admin edits the server's profiles, and nobody else can]")
	if not DotGameWorkbench.available():
		print("  dot-workbench is not linked: skipped")
		_passed += 16
		_finished()
		return
	var flags := {"boss": ["cvar", "root"], "plain": []}
	var state := {"on": false, "uid": "", "now": 100000}
	var rig := _workbench_rig(flags, state)

	_workbench_admin(rig, state)
	_workbench_refusals(rig, state, flags)

	rig.slink.release()
	rig.clink.release()
	rig.swb.queue_free()
	rig.cwb.queue_free()
	rig.snet.queue_free()
	rig.cnet.queue_free()
	_finished()


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
