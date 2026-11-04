extends "headless_net_part2.gd"

## Sections of [code]headless_net.gd[/code], part 3: shared state and helpers are in the base.


## [b]This client's own player is predicted, and nobody else is.[/b]
##
## Asserts the MECHANISM, not agreement: a client adopting every snapshot also agrees with the server, while the owner, the registry's `predicted()`, a key moving the player in its own tick and the correction of an unknowable move are what show the predictor runs.
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

	await _predicted_key_moves(client_player, server_player)
	await _predicted_run_and_stop(client_player, server_player)
	await _predicted_correction(client_player, server_player)
	_finished()


## A key moves the client's player in its own tick, before the server has seen it.
func _predicted_key_moves(client_player: ScPlayer, server_player: ScPlayer) -> void:
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


## A straight run then a stop leaves the client where the server has the player.
func _predicted_run_and_stop(client_player: ScPlayer, server_player: ScPlayer) -> void:
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	forward.yaw = 0.0

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


## A move the client cannot know about is corrected, and then nothing more is.
func _predicted_correction(client_player: ScPlayer, server_player: ScPlayer) -> void:
		# A disagreement the client cannot know about (an admin moves the player): the next snapshot is a correction, and its count moving proves the predictor RUNS rather than adopting what it is sent.
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

		# Once the floor has settled: moving a player across a platform swings its lean over a couple of seconds, and the client runs INPUT_LEAD ticks ahead of the snapshots it draws that lean from, so a one-centimetre correction is the floor being the server's. Two seconds takes the damped swing down to a twentieth.
	await _steps(128)
	var settled := int(_client_net.predictor.describe()["corrections"])
	await _steps(30)
	_check(
		int(_client_net.predictor.describe()["corrections"]) == settled,
		"and then stays converged: no correction while nothing disagrees",
		"%d more" % (int(_client_net.predictor.describe()["corrections"]) - settled)
	)


## A second person on their own peer, as this client draws them.
##
## Every check goes through `ScClient.present_frame`, the real client's `_process` function, at FRAMES_PER_TICK frames a tick. Who somebody is (the seated face, then the new name and face from admission, a wardrobe change or a rename) is asserted on the drawn figure: the atlas it was BUILT with is what a player sees.
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

	await _else_runs_across_a_deck(theirs, server_theirs, mine)

	await _else_rides_then_teleports(key, theirs, server_theirs, mine)

	_server_bridge.remove_player(OTHER_SESSION)
	_exchange()
	await _steps(2)
	_check(not _client_game.players.has(key), "and they leave again, so nothing after this sees them")
	_finished()


## A pilot is drawn as the machine, then a showdown teleport arrives through the ordinary snapshot path.


## Bea runs across a standing deck and every frame is drawn on the server's path.
func _else_runs_across_a_deck(theirs: ScPlayer, server_theirs: ScPlayer, mine: ScPlayer) -> void:
		# Running along -X (yaw -90) from near one edge to past the middle, a second at full speed, put on a STANDING deck first (an earlier section collapsed one).
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

	_else_runs_evenly(theirs, drawn, server_track, clips)


## The drawn body moves by an even step, faces the way it runs, and plays a running clip.
func _else_runs_evenly(theirs: ScPlayer, drawn: Array[Vector3], server_track: Array[Vector3], clips: Array[StringName]) -> void:
		# Smoothness: each frame should move the body by about what the frame before did; a client drawing only on snapshots moves one frame in several. Measured against the server's own run, whose per-tick step halves once as the deck leans: a drawn body may change pace as sharply as the server's did, no more.
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
		clips[clips.size() - 1] in [&"run", DotHumanoidClips.SPRINT],
		"and running, rather than sliding across in a standing pose",
		String(clips[clips.size() - 1])
	)
func _else_rides_then_teleports(key: StringName, theirs: ScPlayer, server_theirs: ScPlayer, mine: ScPlayer) -> void:
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
