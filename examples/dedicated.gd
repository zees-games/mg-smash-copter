extends "dedicated_part2.gd"


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DotLog.signals().record.connect(_on_log_record)
	_run.call_deferred()


func _run() -> void:
	print("smash-copter as a dedicated server")
	print("")

	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

	# A member's site avatar, translated into this game's schema. The site's document is the
	# Kenney skins filed as `top.skin-c` (the site's slot.option part id); without a translation every member is stock here.
	var site_avatars = preload("res://game/sc_avatars.gd")
	var site_doc := DotAvatar.make(&"builtin")
	site_doc.set_part(&"top", &"top.skin-c")
	site_doc.set_part(&"face", &"face.skin-k")
	var as_ours: DotAvatar = site_avatars.from_site(site_doc)
	_check(
		as_ours != null and site_avatars.schema().validate(as_ours).ok and as_ours.part_in(&"skin") == &"skin_c",
		"a member's site avatar becomes this game's, and its schema accepts it",
		str(as_ours.to_dict()) if as_ours != null else "null"
	)
	var unknown_skin := DotAvatar.make(&"builtin")
	unknown_skin.set_part(&"top", &"top.skin-r")
	unknown_skin.set_part(&"face", &"face.skin-r")
	var not_site := DotAvatar.make(&"elsewhere")
	not_site.set_part(&"top", &"top.skin-c")
	_check(
		site_avatars.from_site(unknown_skin) == null and site_avatars.from_site(not_site) == null,
		"a skin this game does not draw, or a document that is not the site's, is stock"
	)

	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()

	if server != null and server.state == DotServer.State.RUNNING:
		await _test_the_module_loads()
		await _test_a_module_reload()
		_test_the_commands()
		_test_the_tunables()
		await _test_a_round_runs()
		await _test_the_stand_ins()
		await _test_the_live_tools()
		await _test_who_they_are()
		await _test_a_covered_seat_is_not_harmed()
		_test_the_layout_vote()
		_test_map_rotation_file()
		_test_finish_round_waits_for_a_live_round()
		await _test_ambient_cvars_reach_the_client()
		await _test_it_unloads_cleanly()
		_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	# Against the declared number too: SECTIONS once said 6 while eight ran.
	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)
	_report_sections(_sections_entered, _sections_finished, sections, checks)


## dot-moderation's live tools, built by dot-game's services layer with this game's verbs, driven through the console against a player who joined as a client does.
## The body is looked at when each command returns: a round can start or end under this section.
func _test_the_live_tools() -> void:
	_section("the moderator's live tools")

	var module := _module()
	var services: Object = module.get("services") if module != null else null
	var tools: Object = services.get("mod_tools") if services != null else null

	_check(tools != null, "dot-game built dot-moderation's live tools, by path")
	_check(
		server.console.find_command("noclip") != null and server.console.find_command("slay") != null,
		"and put their commands on the console"
	)

	if tools == null:
		for what in [
			"joins", "noclip", "freeze", "marks", "timed blind", "timed blind lifts", "persist",
			"off", "modtools", "slay", "respawn refused", "give refused",
		]:
			_check(false, what)
		_finished()
		return

	var net: DotNetManager = module.get("net")
	var previous_send := net.send_fn
	# An adopted session has no peer; the netcode's sends to it would be an engine RPC error
	# per tick.
	net.send_fn = func(_peer: int, _payload: PackedByteArray, _delivery: int) -> void:
		pass

	var session := DotClientSession.new()
	session.peer_id = 6161
	session.userid = 616
	session.display_name = "Pilot"
	var _adopted := server.adopt_session(session)
	server.events.fire("client_spawn", {"userid": 616, "name": "Pilot"})

	var player: ScPlayer = game.players.get(&"u616")
	_check(player != null, "a player joins through the roster")

	if player == null:
		for what in [
			"noclip", "freeze", "marks", "timed blind", "timed blind lifts", "persist",
			"off", "modtools", "slay", "respawn refused", "give refused",
		]:
			_check(false, what)
		net.send_fn = previous_send
		_finished()
		return

	_run_command("noclip Pilot")
	_check(DotFpsAdminModifiers.is_noclipped(player.controller), "`noclip Pilot` puts them in noclip")
	_run_command("noclip Pilot off")

	_run_command("freeze Pilot")
	_check(DotFpsAdminModifiers.is_frozen(player.controller), "`freeze Pilot` holds them on their slab")
	_run_command("unfreeze Pilot")

	await _live_tools_blind_and_beacon(player, services)
	await _live_tools_return_and_refusals(player, tools, services)

	module.get("roster").call("remove", session)
	var _released := server.release_session(session.peer_id)
	net.send_fn = previous_send
	_finished()


## Blind, beacon and `modtools`, through the console an admin types at.
func _live_tools_blind_and_beacon(player: ScPlayer, services: Object) -> void:
	# Blind and beacon, through the console an admin types at. What is asserted is the flag
	# and the field the netcode sends, which is the whole of what the server decides; the
	# audience is `headless_net`'s, and the picture is `tools/shot.sh --view=blind`'s.
	var _blinded := _run_command("blind Pilot")
	var _lit := _run_command("beacon Pilot")
	for _i in range(2):
		await get_tree().process_frame
	_check(player.blinded and player.beacon, "`blind Pilot` and `beacon Pilot` mark them")

	# A blind is a spell. dot-moderation lifts it through the same handler when the time is
	# up, so what is checked is the flag, not the timer.
	var _dark_off := _run_command("blind Pilot off")
	var _spell := _run_command("blind Pilot 0.2")
	for _i in range(2):
		await get_tree().process_frame
	_check(player.blinded, "`blind Pilot 0.2` blinds them for a fifth of a second")
	await get_tree().create_timer(0.4).timeout
	_check(not player.blinded, "and it lifts on its own when the time is up")

	# A round start is everybody's new body, and it is `mod_player_respawned` that says so.
	# Both marks are about the person, where noclip ends with the body.
	var _again := _run_command("blind Pilot")
	var _flying := _run_command("noclip Pilot")
	for _i in range(2):
		await get_tree().process_frame
	services.call("mod_player_respawned", &"616")
	_check(
		player.blinded and player.beacon and not DotFpsAdminModifiers.is_noclipped(player.controller),
		"a new body keeps the blind and the beacon, and ends the noclip"
	)
	var _unblind := _run_command("blind Pilot off")
	var _unlit := _run_command("beacon Pilot off")
	for _i in range(2):
		await get_tree().process_frame
	_check(not player.blinded and not player.beacon, "and `off` lifts both")

	var listed := _run_command("modtools")
	for _i in range(2):
		await get_tree().process_frame
	_check(
		_said(listed, "blind") and _said(listed, "beacon") and not _said(listed, "draws no"),
		"`modtools` lists both as supported", " | ".join(listed)
	)


## The return point across rounds, and what `slay`, `respawn` and `give` say.
func _live_tools_return_and_refusals(player: ScPlayer, tools: Object, services: Object) -> void:
	# `[modtools-return-1]`: a return point survives a round on the same layout and not
	# one on another, because a point above a platform is only a place while the platform
	# is there. The handler is called as the round's signal calls it.
	var _moved := _run_command("send Pilot Pilot")
	for _i in range(2):
		await get_tree().process_frame
	var had_return: bool = tools.call("can_return", &"616")
	var here: StringName = services.get("_tools_layout")
	services.call("_on_round_began_for_tools", 90, here)
	var kept: bool = tools.call("can_return", &"616")
	services.call("_on_round_began_for_tools", 91, &"a_layout_that_is_not_this_one")
	var cleared: bool = not tools.call("can_return", &"616")
	services.call("_on_round_began_for_tools", 92, here)
	_check(had_return and kept and cleared,
		"a return point survives a round on the same layout and not one on another",
		"had %s, kept %s, cleared %s" % [had_return, kept, cleared])

	var slain := _run_command("slay Pilot")
	_check(not player.is_alive(), "`slay Pilot` puts them out, as ordinary damage", " | ".join(slain))

	for _i in range(2):
		await get_tree().process_frame

	var respawned := _run_command("respawn Pilot")
	for _i in range(2):
		await get_tree().process_frame
	_check(_said(respawned, "faller") or _said(PackedStringArray(respawned), "decides"),
		"`respawn` is refused with this game's reason", " | ".join(respawned))

	var given := _run_command("give Pilot rifle")
	for _i in range(2):
		await get_tree().process_frame
	_check(_said(given, "handover"), "`give` says why weapons are not given here", " | ".join(given))


## The players' vote decides the next layout, end to end through what a player types: nomination, the ballot opening on its own clock, a vote by number, the round's end laying the winner, rock-the-vote.
## Commands run at the console, where a chat `!vote` lands; its voter is "console" and stand-ins are not voters.
func _test_the_layout_vote() -> void:
	_section("the layout vote")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(vote != null, "the module built a layout vote")

	if vote == null:
		_finished()
		return

	var commands_there: bool = ["vote", "rtv", "nominate"].all(
		func(name: String) -> bool: return server.console.find_command(name) != null)

	_check(commands_there, "and registered dot-vote's vote, rtv and nominate")

	# Hibernation: DotGameModule hands the director the server, the ballot's timer waits with
	# it, and waking starts both again from the top.
	var director: DotVoteDirector = vote.get("director")
	_check(server.hibernation_changed.is_connected(director.set_hibernating),
		"the vote follows the server's hibernation without a line of this game's")
	vote.set("_opened_this_layout", true)
	server.console.execute("sv_hibernate_when_empty 1")
	_check(server.is_hibernating() and director.hibernating, "an empty server sleeps, and the vote with it",
		server.state_name())
	var on_layout: float = vote.get("_on_layout_sec")
	vote.call("advance", 600.0)
	_check(is_equal_approx(vote.get("_on_layout_sec"), on_layout), "ten minutes asleep do not count towards the ballot")
	server.console.execute("sv_hibernate_when_empty 0")
	_check(is_zero_approx(vote.get("_on_layout_sec")) and not vote.get("_opened_this_layout") and not director.hibernating,
		"waking wakes the vote, and the layout ballot is owed again from the top")

	var ids: Array = []

	for choice: DotVoteChoice in (vote.get("source") as DotVoteListSource).entries:
		ids.append(String(choice.id))

	_check(ids.size() == ScLayouts.ids(game.config).size() and ids.has("checker"),
		"it offers every layout this server plays", str(ids))

	# The map menu's server half (M): the owner's flag changes the layout now, anybody else
	# gets a nomination and a rock-the-vote. Contexts as dot-server makes them for a chat line.
	var menu_half: Object = vote.get("commands").get("map_menu")
	_check(menu_half != null and server.console.find_command("mapmenu") != null
		and server.console.find_cvar("sv_map_menu_flag").get_string() == "generic"
		and (menu_half.get("change_fn") as Callable).is_valid(),
		"the map menu is there, staff-only by default, changing the layout now")
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var player := DotCmdContext.new()
	player.source = DotCmdContext.Source.CHAT
	var offered: Dictionary = menu_half.call("offer", player)
	_check((offered["maps"] as Array).size() > 1 and not bool(offered["allowed"]) and bool(offered["vote"]),
		"a player is offered every layout, as a vote")
	var target: StringName = &""
	for row: Dictionary in offered["maps"]:
		if not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var changed: Dictionary = await menu_half.call("choose", staff, target)
	_check(bool(changed["ok"]) and game.layout.id == target, "staff choosing one changes the layout on the spot",
		"%s: %s" % [target, changed.get("text", "")])

	# A layout that is not the one being played, so it can be nominated.
	var playing := String(game.layout.id)
	director.begin(StringName(playing))
	var wanted := "checker" if playing != "checker" else "full"
	var captured: Array = []
	vote.set("voters_fn", func() -> Array: return [&"console"])
	vote.set("ballot_fn", func(state: Dictionary) -> void: captured.append(state))

	_check(_said(_run_command("nominate %s" % wanted), "Nominated"), "a player nominates a layout", wanted)

	vote.set("_on_layout_sec", 0.0)
	vote.set("_opened_this_layout", false)
	vote.call("advance", float(vote.get("open_after_sec")) + 0.1)
	var options: Array[StringName] = director.ballot.option_ids() if director.is_voting() else ([] as Array[StringName])
	_check(director.is_voting() and options.has(StringName(wanted)),
		"the ballot opens on its own clock, with the nomination on it", str(options))
	# The feed is polled each tick before the ballot timer opens one, so it sees it next tick.
	(vote.get("feed") as DotVoteBallotFeed).poll()
	var drawn: Dictionary = captured.back() if not captured.is_empty() else {}
	_check(bool(drawn.get("open", false)) and str(drawn.get("command", "")) == "vote" \
			and (drawn.get("options", []) as Array).size() == options.size(),
		"and the ballot a client draws says so, with the command that votes", str(drawn.keys()))

	_check(_said(_run_command("vote %d" % (options.find(StringName(wanted)) + 1)), "Voted"),
		"a vote by the number on the ballot counts")
	# Everybody has voted; the director closes on its next advance, which is the server's tick.
	vote.call("advance", 0.05)
	_check(director.pending_id() == StringName(wanted), "and decides it, waiting for the round's end",
		str(director.pending_id()))

	vote.call("note_round_end")
	_check(game.next_layout_id == StringName(wanted), "the round's end hands it to the world", str(game.next_layout_id))
	game.call("_lay_out_round")
	_check(game.layout.id == StringName(wanted) and game.next_layout_id == &"",
		"and the next layout laid is the one voted for, once", "%s / %s" % [game.layout.id, game.next_layout_id])

	# A laid layout is a world_rebuilt, which restarts the director; rtv then brings the ballot forward.
	_check(director.current_id() == StringName(wanted) and not director.is_voting(),
		"the new layout starts the vote over", str(director.current_id()))
	# Past the cooldown between ballots, on the director alone (a round outlasts it in play).
	director.rules.rtv_delay_sec = 0.0
	director.rules.min_players_to_vote = 1
	director.rules.rtv_min_players = 1
	director.rules.allow_single_voter_auto = true
	director.advance(director.rules.vote_cooldown_sec + 0.1)
	var ballots: Array = []
	director.vote_opened.connect(func(_options: Array, _seconds: float) -> void: ballots.append(1))
	var rocked := _run_command("rtv")
	vote.call("advance", 0.05)
	_check(director.is_voting(), "and rock-the-vote opens a ballot before its time", str(rocked))
	# Under MANUAL the director opens a rocked ballot itself (dot-vote API 2); this game no longer
	# does, so exactly one ballot opens, not one from each.
	_check(ballots.size() == 1, "and exactly one ballot, the director's alone", str(ballots.size()))
	_finished()


## Profiles, names and faces on a real server: dot-platform's identity layer, its module, and the three events this game redraws a player on.
## Admitted AFTER they are seated, on purpose: a real join does this whenever the profile store is slower than the content download, and a game reading name and face only at seating shows a guest all session.
func _test_who_they_are() -> void:
	_section("who somebody is")

	var module := _module()
	var identity: Object = module.get("identity") if module != null else null

	_check(identity is DotPlatformIdentity, "the module built dot-platform's identity layer")
	_check(server.modules.has_module("platform"), "and dot-game loaded the platform module")
	_check(
		identity is DotPlatformIdentity and (identity as DotPlatformIdentity).avatars != null
			and (identity as DotPlatformIdentity).avatars.schema.id == ScAvatars.SCHEMA_ID,
		"validating avatars against this game's schema"
	)

	var net: DotNetManager = module.get("net")
	var previous_send := net.send_fn
	net.send_fn = func(_peer: int, _payload: PackedByteArray, _delivery: int) -> void:
		pass

	var session := DotClientSession.new()
	session.peer_id = 7171
	session.userid = 717
	session.display_name = "guest-717"
	var _adopted := server.adopt_session(session)
	server.events.fire("client_spawn", {"userid": 717, "name": "guest-717"})

	var player: ScPlayer = game.players.get(&"u717")
	_check(
		player != null and player.avatar != null
			and player.avatar.digest() == ScAvatars.stock_avatar(&"u717").digest(),
		"seated before the platform knows them, they wear the stock look for their seat"
	)

	# A guest first, on a server with authentication off. dot-user keeps no profile for a guest by default (a guest id is a random per-device string), so they get the name they gave and the stock look.
	session.identity = DotAuthIdentity.guest("device-717", "Maggie")
	var platform := server.modules.get_module("platform")
	platform.call("_on_client_state_changed", session)

	var deadline := Time.get_ticks_msec() + 5000
	while (player == null or player.display_name != "Maggie") \
			and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	_check(
		player != null and player.display_name == "Maggie"
			and player.avatar.digest() == ScAvatars.stock_avatar(&"u717").digest(),
		"a guest, admitted late, is called what they asked and keeps the stock look",
		player.display_name if player != null else "-"
	)

	# Then the same seat signed in, which is the case profiles exist for. Re-announced the way
	# dot-server announces a state change: a guest admission stored no key, so it runs again.
	session.identity = DotAuthIdentity.from_dict({
		"uid": "backbone:acc-717", "provider": "backbone", "provider_id": "acc-717",
		"display_name": "Margaret", "authenticated_at": int(Time.get_unix_time_from_system()),
	})
	platform.call("_on_client_state_changed", session)

	deadline = Time.get_ticks_msec() + 5000
	while (player == null or player.display_name != "Margaret") \
			and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	var admitted: Object = platform.call("player_for", session)
	var key := str(admitted.call("key")) if admitted != null else ""
	_check(
		player != null and player.display_name == "Margaret",
		"once admitted, the world calls them by their profile's name",
		player.display_name if player != null else "-"
	)
	_check(
		player != null and admitted != null and player.avatar == admitted.get("avatar")
			and player.avatar.digest() == ScAvatars.stock_avatar(StringName(key)).digest(),
		"and draws what the platform resolved: this game's stock look, for their scoped key",
		key
	)

	# What they keep is filed under the key that outlives this connection, and is still looked up by the world's own id.
	if game.progress != null:
		game.progress.record(&"u717", ScProgress.DEATHS)
	_check(
		game.progress != null and key != ""
			and game.progress.filed_under(&"u717") == module.stats_feed.key_for(session)
			and game.progress.stats.has_player(module.stats_feed.key_for(session))
			and game.progress.session_values(&"u717").get_value(ScProgress.DEATHS, 0.0) == 1.0,
		"and what they keep is filed under that key, found again by their seat",
		str(game.progress.filed_under(&"u717")) if game.progress != null else "no progress"
	)

	_check_hit_zone(player)
	_check(_stats_errors.is_empty(), "the stats layer logged no error", str(_stats_errors))

	# An account's name is the site's and dot-user refuses to change it here, so an operator's `platform_name` is a refusal and the world keeps the name.
	# The rename that IS allowed (a guest profile on a server that keeps them) is dot-platform's sandbox's to check.
	var renamed := _run_command("platform_name 717 Grace")
	for _i in range(10):
		await get_tree().process_frame
	_check(
		player != null and player.display_name == "Margaret" and _said(renamed, "account"),
		"renaming a signed-in player is refused with the reason, and the world keeps the name",
		"%s | %s" % [player.display_name if player != null else "-", " | ".join(renamed)]
	)

	module.get("roster").call("remove", session)
	var _released := server.release_session(session.peer_id)
	net.send_fn = previous_send
	_finished()
