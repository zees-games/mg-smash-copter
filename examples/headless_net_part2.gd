extends "headless_net_part1.gd"

## Sections of [code]headless_net.gd[/code], part 2: shared state and helpers are in the base.


## Every encoder against its own decoder, and nothing else.
##
## Nothing else checks a pair are inverses (dot-moderation once wrote `"voice muted"` and read back a warning). Every pair in `ScEvents` is round-tripped here, so a new one needs a line.
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

	_wire_join_and_deaths()
	_wire_props_and_seats()
	_wire_clock_and_phases()
	_wire_blast_and_chat()
	_wire_spectate_and_impact()


## A truncated message says so, and every kind fits its field.


## Join, leave, side, death and armed messages.
func _wire_join_and_deaths() -> void:
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


## Props, removals and seats.
func _wire_props_and_seats() -> void:
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


## Clock, round, phase and special.
func _wire_clock_and_phases() -> void:
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


## Blast, say, notice, chat and a side request.
func _wire_blast_and_chat() -> void:
	var at := Vector3(-41.25, 46.5, 17.75)
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


## Spectator views and impacts.
func _wire_spectate_and_impact() -> void:
	var at := Vector3(-41.25, 46.5, 17.75)
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
func _check_wire_limits() -> void:
		# A reader past its end returns plausible zeros: exhaustion was not sticky in dot-net, so a decoder skipping the `ok` check read a believable value after the overrun.
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

		# Then let the round actually begin, which re-lays the field from inside the netcode's loop: dot-match runs a warmup first, and every section below would otherwise assert about a world not started. A real client joining sees the same rebuild each round.
	await _steps(12)

	_check(_client_bridge.local_player_id == SESSION, "and the client is told who it is",
		"%d" % _client_bridge.local_player_id)

		# The server's tick rate: another game shipped HELLO carrying it with nothing reading it, so a browser client counted at its export's 60 against a server on 128.
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


func _test_the_field_arrives() -> void:
	_section("the field arrives")

	_check(
		_client_game.platforms.count() == _server_game.platforms.count(),
		"the client rebuilt the server's field",
		"%d vs %d" % [_client_game.platforms.count(), _server_game.platforms.count()]
	)

		# In the same ORDER, which is what the wire addresses a platform by; a client deriving the field from its own catalogue would move the wrong floor once a layout behind.
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


func _test_a_platform_leans_across_the_wire() -> void:
	_section("a lean crosses the wire")

	var here := _server_game.platforms.deck_at(0)
	var there := _client_game.platforms.deck_at(0)
	var at := here.centre + Vector3(here.half * 0.8, 0.0, 0.0)

	_check(there.tilt() < 0.01, "the client's copy starts level", "%.4f rad" % there.tilt())

		# An impact, not a load: `ScGame._load_platforms` calls `begin_loads()` every tick, wiping a hand-added load before it is integrated. An impact pushes the lean velocity, as a landing prop does, and survives it.
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

		# The collider goes with it, and this is the check that matters: a client that left the floor of a gone platform has a player standing on something that exists nowhere else.
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
