extends "headless_net_part4.gd"

## Sections of [code]headless_net.gd[/code], part 5: shared state and helpers are in the base.


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


## A crate the server breaks throws one burst of splinters on the client, and nothing with effects off.
func _test_a_crate_breaks_in_splinters() -> void:
	_section("a crate the server breaks throws splinters on the client, none with effects off")

	var client_side := _client_game.get_parent()
	var fx := ScFx.new()
	client_side.add_child(fx)
	var built := fx.setup(null)
	_check(built.ok and fx.break_fx != null, "the client has the break effect")
	fx.break_fx.config.headless = true
	_client_bridge.shatter_received.connect(fx.on_shatter)
	var spot := Vector3(0.0, 40.0, 0.0)
	var crate := _server_game.props.spawn(ScContent.CRATE, &"world", spot)
	await _steps(4)
	var _b := _server_game.prop_damage.break_now(crate.instance_id, &"")
	_exchange()
	await _steps(3)
	_check(fx.break_fx.spawned == 1, "one broken crate is one burst", "spawned %d" % fx.break_fx.spawned)
	var root := fx.break_fx.get_child(fx.break_fx.get_child_count() - 1) as Node3D
	_check(root != null and root.name.begins_with("Break_wood") and root.get_node_or_null("Pieces") != null,
		"wood pieces are drawn")
	_check(root != null and root.global_position.distance_to(spot) < 2.0, "where the crate was")

	fx.break_fx.config.enabled = false
	var crate2 := _server_game.props.spawn(ScContent.CRATE, &"world", spot + Vector3(2.0, 0.0, 0.0))
	await _steps(4)
	_b = _server_game.prop_damage.break_now(crate2.instance_id, &"")
	_exchange()
	await _steps(3)
	_check(fx.break_fx.spawned == 1 and fx.break_fx.last_refusal == "disabled",
		"with effects off nothing is drawn", "spawned %d, %s" % [fx.break_fx.spawned, fx.break_fx.last_refusal])
	client_side.remove_child(fx)
	fx.free()
	_finished()


func _test_leaving() -> void:
	_section("leaving")

	var left: Array[int] = []
	_client_bridge.roster_changed.connect(func(id: int) -> void: left.append(id))

	var before := _client_game.players.size()

		# The stand-in, not the client under test: `remove_player` takes a leaver out of the ready set before announcing LEAVE, so the one departure a single-client suite observes is somebody else's.
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
