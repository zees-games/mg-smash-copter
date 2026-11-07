extends "dedicated_part1.gd"

## Sections of [code]dedicated.gd[/code], part 2: shared state and helpers are in the base.


func _test_a_round_runs() -> void:
	_section("a round, on a real server")

	var module := _module()
	var errors := EngineErrors.new()
	OS.add_logger(errors)

	if module == null:
		for what in [
			"the round starts", "and the server lists its layout as the map, not the game",
			"it reaches the corners", "and the showdown",
			"the cannon threw something", "and the field took damage",
			"and lag compensation keeps nothing for what the server let go",
			"and a round of stand-ins counted nothing for anybody",
			"and the engine reported no error",
		]:
			_check(false, what)

		OS.remove_logger(errors)

		_finished()
		return

	# The module started it on the last line of its own load. Give it the survival clock
	# plus the handover, in real frames, because a dedicated server ticks on frames.
	var reached_handover := false
	var reached_showdown := false
	var threw := 0

	# Longer than the two phases add up to: the round cannot start until there are two sides (stand-ins join on a two-second interval, dot-match holds warmup below `min_players`).
	# Timing a test to the exact sum of its phases passes on a fast machine and fails on a slow one.
	for _i in range(int(14.0 * TICK_RATE)):
		await get_tree().physics_frame
		threw = maxi(threw, game.cannon.props_launched)

		if game.phase == ScGame.Phase.HANDOVER:
			reached_handover = true

		if game.phase == ScGame.Phase.SHOWDOWN:
			reached_showdown = true
			break

	_check(game.round_number > 0, "the round starts", "%d" % game.round_number)
	_check(
		game.layout != null and server.games.reported_map() == String(game.layout.id),
		"and the server lists its layout as the map, not the game",
		server.games.reported_map()
	)
	_check(reached_handover, "it reaches the corners")
	_check(reached_showdown, "and the showdown", ScGame.Phase.keys()[game.phase])
	_check(threw > 0, "the cannon threw something", "%d props" % threw)

	# The field is not what it was. Either something collapsed or something is leaning,
	# and on a three-second round with four stand-ins on it, at least one is true.
	var worst := 0.0

	for i in range(game.platforms.count()):
		var deck := game.platforms.deck_at(i)

		if deck != null:
			worst = maxf(worst, deck.tilt())

	_check(
		worst > 0.0 or game.platforms.standing_count() < game.platforms.count(),
		"and the field took damage",
		"worst lean %.3f rad, %d of %d up" % [
			worst, game.platforms.standing_count(), game.platforms.count()
		]
	)

	# The round began inside the netcode's own tick, which is the case this is for: the boot field is replaced from inside `DotNetManager.server_tick`, which then re-created lag-compensation tracks for ids the registry had just forgotten (twelve leaked per round).
	# `history._tracks` is read directly because no public accessor would report a leak.
	var net: DotNetManager = module.net
	var orphans: Array[int] = []

	for net_id: int in net.history._tracks.keys():
		if not net.registry.has(net_id):
			orphans.append(net_id)

	# Everybody in this round is a stand-in, and stand-ins are nobody's numbers: a server
	# left to itself all night must not be filing figures against bots.
	_check(
		game.progress != null and game.progress.stats.players().is_empty(),
		"and a round of stand-ins counted nothing for anybody",
		"%d tracked" % (game.progress.stats.players().size() if game.progress != null else -1)
	)

	_check(orphans.is_empty(), "and lag compensation keeps nothing for what the server let go",
		"%d tracks, %d orphaned %s" % [net.history._tracks.size(), orphans.size(), str(orphans)])

	# The same moment in the log: the old decks are out of the tree but still registered for one tick.
	# Fixed in dot-net (DotNetHistory skips an entity not in the world), because taking a node out between ticks is something the netcode agreed a game may do.
	OS.remove_logger(errors)
	var seen := errors.seen()
	_check(seen.is_empty(), "and the engine reported no error",
		"%d: %s" % [seen.size(), " | ".join(seen.slice(0, 3))])

	_finished()


## The rule that keeps a round possible on a server nobody is on.
## An elimination round with one side in it ends on its first tick, so a server holding one person would start and end rounds several times a second.
func _test_the_stand_ins() -> void:
	_section("the stand-ins")

	_check(game.players.size() >= 2, "the server filled the round",
		"%d players" % game.players.size())

	var sides: Dictionary = {}

	for id: StringName in game.players:
		sides[game.team_of(id)] = true

	_check(sides.size() >= 2, "onto at least two sides", "%d sides" % sides.size())
	_check(game.sides_are_playable(), "so a round can actually run")

	var bots := 0

	for id: StringName in game.players:
		if (game.players[id] as ScPlayer).is_bot:
			bots += 1

	_check(bots == game.players.size(), "and all of them are stand-ins on an empty server",
		"%d of %d" % [bots, game.players.size()])

	# A person takes a stand-in's place, and leaving gives it back (DotBotQuota's fill mode).
	# Driven by calling the roster check, not waiting for its interval, with a person added through the bridge (peer zero) so the count is exact.
	var quota_module := _module()
	var quota_bridge: Object = quota_module.get("bridge") if quota_module != null else null
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota_mode") != null,
		"the shared bot_quota cvars are registered")
	var _alias := _run_command("sc_min_players 3")
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota").get_int() == 3,
		"and the old sc_min_players sets bot_quota",
		server.console.find_cvar("bot_quota").get_string() if server.console.find_cvar("bot_quota") != null else "missing")

	if quota_module != null and quota_bridge != null:
		quota_module.call("_keep_the_round_full")
		var bots_before: int = (quota_module.get("_bot_ids") as Array).size()
		var joined: DotResult = quota_bridge.call("add_player", 0, 9001, "Person")
		quota_module.call("_keep_the_round_full")
		var bots_with: int = (quota_module.get("_bot_ids") as Array).size()
		_check(joined.ok and bots_before == 3 and bots_with == bots_before - 1,
			"a person joining takes a stand-in's place", "%d -> %d" % [bots_before, bots_with])
		quota_bridge.call("remove_player", 9001)
		quota_module.call("_keep_the_round_full")
		var bots_after: int = (quota_module.get("_bot_ids") as Array).size()
		_check(bots_after == bots_before, "and a stand-in comes back when they leave",
			"%d -> %d" % [bots_with, bots_after])
	else:
		_check(false, "a person joining takes a stand-in's place", "no module")
		_check(false, "and a stand-in comes back when they leave", "no module")

	var _restored := _run_command("sc_min_players 4")

	# How the stand-ins aim and shoot is dot-bot's, the family's names: bot_difficulty sets the
	# bundle, a single setting overrides it, and the old sc_bot_spread still means bot_aim_error.
	var bot_settings := DotBotSettings.of(game)
	_check(server.console.get_string("bot_difficulty", "") == "medium" and bot_settings.difficulty() == "medium",
		"bot_difficulty is the module's and medium is the default")
	var _hard := _run_command("bot_difficulty hard")
	_check(bot_settings.difficulty() == "hard" and is_equal_approx(server.console.get_float("bot_reaction"), DotBotProfile.preset_value("hard", "reaction")),
		"bot_difficulty hard writes every bot_* setting", server.console.get_string("bot_reaction"))
	var _old := _run_command("sc_bot_spread 9")
	_check(is_equal_approx(bot_settings.profile.aim_error, 9.0) and server.console.get_string("bot_aim_error") == "9",
		"the old sc_bot_spread sets bot_aim_error", server.console.get_string("bot_aim_error"))
	var _reset := _run_command("bot_settings_reset")
	var _medium := _run_command("bot_difficulty medium")
	_check(is_equal_approx(bot_settings.profile.aim_error, DotBotProfile.preset_value("medium", "aim_error")),
		"and bot_settings_reset puts the preset back", "%.2f" % bot_settings.profile.aim_error)
	var _lean := _run_command("sc_bot_lean_notice 4")
	_check(is_equal_approx(game.config.bot_lean_notice_degrees, 4.0), "sc_bot_lean_notice is this game's own",
		"%.2f" % game.config.bot_lean_notice_degrees)
	var _lean_back := _run_command("sc_bot_lean_notice 1.15")

	# Named from this game's list through DotBotNames: never twice.
	var names := {}
	var named := true
	for id: StringName in game.players:
		var who := (game.players[id] as ScPlayer).display_name
		named = named and not names.has(who) and (ScGame.BOT_NAMES.has(who) or who.contains(" "))
		names[who] = true
	_check(named, "every stand-in has its own name from the list", ", ".join(PackedStringArray(names.keys())))

	# Turned off, they go away. A stand-in that could not be removed would be an operator
	# with no way to run an empty server.
	_run_command("sc_bots 0")

	for _i in range(int(3.0 * TICK_RATE)):
		await get_tree().physics_frame

	var off_module := _module()
	_check(off_module != null and (off_module.get("_bot_ids") as Array).is_empty(),
		"and turned off, the stand-ins are taken out")

	_run_command("sc_bots 1")

	_finished()


func _check_hit_zone(player: ScPlayer) -> void:
	if game.progress != null and player != null:
		var zoned := DotDamage.make(player.entity_id, 9999, 5.0, game.combat.damage_type(&"kinetic"))
		zoned.hit_group = DotHitGroup.NECK
		zoned.weapon_id = &"probe"
		game.progress.report_damage(zoned)
		_check(game.progress.session_values(&"u717").get_cell(DotStatsHitzones.HITS, "zone:neck") >= 1.0,
			"a hit with a hit_group is filed by body zone through the dot-stats hitzone hook")
		_check(game.progress.stats.schema.validate().ok, "the stats schema, hitzones included, validates")
	else:
		_check(false, "a hit is filed by body zone", "no progress or player")
		_check(false, "the stats schema validates")


## A seat whose client has not lifted its loading cover cannot be harmed, and can once it does (dot-game's "still loading"), over a real ENet socket.
## A client joins and says nothing; crush, shoot and drop must be refused, an admin's slay still passes, and after `game.cover` on the wire the same hit lands.
func _test_a_covered_seat_is_not_harmed() -> void:
	_section("a client behind its loading cover is not harmed, and is once it lifts")

	var module := _module()
	var bridge := module.get("bridge") as ScNetBridge if module != null else null
	var side := Node.new()
	side.name = "CoverClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Covered"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	# RPC paths are relative to the multiplayer root, so the link must sit at the path the
	# server's does: "Dedicated/Server" under the root.
	var mirror := Node.new()
	mirror.name = "Dedicated"
	side.add_child(mirror)
	mirror.add_child(link)
	# The server's snapshots and events are RPCs to a node of this name under the link; with none each is an engine error, and it drops what arrives.
	# The link retires whatever the game left under it when it signs on, so it is put back at each phase change (a real client's scene does this from _ready).
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(ScNetLink.NODE_NAME)) == null:
			var sink := ScNetLink.attached_to(link, null, false)
			sink.name = ScNetLink.NODE_NAME
			link.add_child(sink)
	attach.call()
	link.phase_changed.connect(attach)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var joined := await _until(func() -> bool:
		return spawned[0] or link.phase == DotClientLink.Phase.FAILED, 30.0)
	joined = joined and spawned[0]
	var peer := side.multiplayer.get_unique_id() if joined else 0
	var session := 0
	if bridge != null and joined:
		var _seated := await _until(func() -> bool: return bridge.player_for_peer(peer) != 0, 10.0)
		session = bridge.player_for_peer(peer)
	var victim: ScPlayer = null
	if session != 0:
		victim = await _until_player(session)
	_check(victim != null, "a client joins over the socket and is seated", "peer %d session %d" % [peer, session])

	if victim == null:
		for what in [
			"the server holds it as loading", "a lethal hit three ways does nothing to it",
			"and the floor's own kill leaves it up", "an admin's slay still passes",
			"its cover report crosses the wire", "and the same hit now lands",
		]:
			_check(false, what)
		link.disconnect_from_server("done")
		side.queue_free()
		_finished()
		return

	var key := ScNetBridge.player_key(session)
	_check(bool(module.call("is_peer_loading", peer)) and not game.can_be_harmed(key),
		"the server holds it as loading from its spawn")

	var before := victim.health.health
	var tick: int = game._tick
	for why: StringName in [&"shot", &"crushed", &"fell"]:
		var hit := DotDamage.make(0, victim.entity_id, victim.health.max_health * 10.0, null)
		hit.tick = tick
		hit.context = {"why": why}
		var _applied: Variant = game.combat.apply_damage(hit)
	_check(victim.is_alive() and is_equal_approx(victim.health.health, before),
		"a lethal hit three ways does nothing to it", "%s -> %s" % [before, victim.health.health])

	var lifted_at := victim.global_position
	game._kill_by_fall(victim, lifted_at)
	_check(victim.is_alive(), "and the floor's own kill leaves it up")

	var slain: Variant = (module.get("services") as Object).call("_mod_hurt", StringName(str(session)), -1.0)
	_check(slain is DotResult and (slain as DotResult).ok and not victim.is_alive(),
		"an admin's slay still passes", str(slain))
	victim.health.alive = true
	victim.health.health = before

	DotGameClient.report_cover(link, false)
	var lifted := await _until(func() -> bool: return not bool(module.call("is_peer_loading", peer)), 10.0)
	_check(lifted and game.can_be_harmed(key), "its cover report crosses the wire and ends the loading state")
	var after_lift := victim.health.health
	var late := DotDamage.make(0, victim.entity_id, 1.0, null)
	late.tick = game._tick
	late.context = {"why": &"late"}
	var _late_applied: Variant = game.combat.apply_damage(late)
	_check(victim.health.health < after_lift, "and the same kind of hit now lands",
		"%s -> %s" % [after_lift, victim.health.health])

	link.disconnect_from_server("done")
	var gone := await _until(func() -> bool: return not game.players.has(key), 10.0)
	_check(gone, "and when it leaves the world forgets it")
	side.queue_free()
	_finished()


## maps.yml on the live module: a layout outside the active rotation stays installed and is never
## drawn, balloted or nominated; a rotation switch takes effect; a renamed command answers; no
## file means every layout.
func _test_map_rotation_file() -> void:
	_section("maps.yml")
	var module := _module()
	var maps: ScMapSession = module.get("maps") if module != null else null
	var vote: Node = module.get("vote") if module != null else null

	var wired := maps != null and vote != null and vote.get("director") != null
	_check(wired, "the module has maps and a vote")
	if not wired:
		_finished()
		return

	var catalogue := maps.catalogue
	var director: DotVoteDirector = vote.get("director")
	var built := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "one",
		"rotations": {
			"one": {"mode": "random", "cooldown": 0, "maps": ["checker"]},
			"two": {"maps": ["full"]},
		},
		"commands": {"names": {"rtv": "rockthevote"}},
	}}], "mg-smash-copter")
	_check(built.ok, "a maps.yml with two rotations and a renamed rtv parses",
		"" if built.ok else built.error.message)
	if not built.ok:
		_finished()
		return

	maps.rotation_file = built.value
	maps.apply_rotation()
	var checker := catalogue.get_map(&"checker")
	var full := catalogue.get_map(&"full")
	_check(checker.in_rotation and not full.in_rotation, "the active rotation puts full out and checker in")
	_check(ScLayouts.by_id(game.config, &"full") != null and catalogue.get_map(&"full") != null,
		"and full stays installed")
	_check(not catalogue.available().has(full) and catalogue.available().has(checker), "available() leaves it out")
	var listed := false
	for row: Dictionary in game.layout_rows():
		listed = listed or (String(row["id"]) == "full" and String(row["detail"]).contains("not in rotation"))
	_check(listed, "and the map list marks it")

	var drew_full := false
	for i in 100:
		if ScLayouts.pick(game.config, game.random.stream(&"layout"), game.layout_in_rotation_fn).id == &"full":
			drew_full = true
	_check(not drew_full, "100 draws never choose a layout outside the rotation")

	vote.call("refresh_maps")
	var ids: Array = []
	for choice: DotVoteChoice in (vote.get("source") as DotVoteListSource).entries:
		ids.append(String(choice.id))
	_check(not ids.has("full") and ids.has("checker"), "a layout outside it is not on the ballot", str(ids))
	var nominated := director.nominate(&"console", &"full")
	_check(not nominated.ok, "nominate refuses it")
	_check(not director.nominated_ids().has(&"full"), "and nothing was recorded")

	var switched := maps.rotation_file.switch(maps.rotation, "two")
	_check(switched.ok and full.in_rotation and not checker.in_rotation, "switching to the other rotation takes effect")
	var drew_checker := false
	for i in 50:
		if ScLayouts.pick(game.config, game.random.stream(&"layout"), game.layout_in_rotation_fn).id == &"checker":
			drew_checker = true
	_check(not drew_checker, "and the draw follows it")
	vote.call("advance", 1.1)
	ids.clear()
	for choice: DotVoteChoice in (vote.get("source") as DotVoteListSource).entries:
		ids.append(String(choice.id))
	_check(not ids.has("checker") and ids.has("full"), "and the ballot follows it, unprompted", str(ids))
	_check(not maps.rotation_file.switch(maps.rotation, "nope").ok, "an unknown rotation is refused")

	var rtv := DotVoteCommands.new()
	rtv.director = director
	rtv.spec_fn = module._rotation_commands
	var bound := rtv.bind(server.console)
	_check(bound.ok and rtv.command_name("rtv") == "rockthevote" and server.console.find_command("rockthevote") != null,
		"a renamed rtv is registered from maps.yml's commands")
	var replies := _run_command("rockthevote")
	_check(not replies.is_empty(), "and answers", " ".join(replies))

	maps.rotation_file = null
	maps.apply_rotation()
	var all_in := true
	for def in catalogue.maps:
		all_in = all_in and def.in_rotation
	_check(all_in, "with no file every layout is in rotation again")
	_check(module._rotation_commands().is_empty(), "and no command is renamed")
	vote.call("refresh_maps")
	_finished()


## `time_up: finish_round` waits for a round being played, never for warmup: the game hands dot-vote `round_in_progress_fn`, else a limit that ran out in warmup held the change for `finish_round_max_sec`.
## Run on a director of its own carrying the game's hook, so the real vote's clock is untouched; the match's state is set by hand and put back.
func _test_finish_round_waits_for_a_live_round() -> void:
	_section("finish_round waits for a live round, not warmup")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var director: DotVoteDirector = vote.get("director") if vote != null else null
	var hook: Variant = director.get("round_in_progress_fn") if director != null else null
	_check(hook is Callable and (hook as Callable).is_valid(), "the game tells its vote whether a round is live")

	if not (hook is Callable and (hook as Callable).is_valid()) or game == null or game.match_node == null:
		_finished()
		return

	var match_node: DotMatch = game.match_node
	var was := match_node.state
	match_node.state = DotMatch.State.WARMUP
	var warm_applied := []
	var warm := _finish_round_probe(hook, warm_applied)
	_check(warm_applied == [&"b"] and not warm.is_finishing_round(),
		"in warmup a time limit with finish_round changes at once", str(warm_applied))

	match_node.state = DotMatch.State.LIVE
	var live_applied := []
	var live := _finish_round_probe(hook, live_applied)
	_check(live_applied.is_empty() and live.is_finishing_round(),
		"during a live round it waits for the round", str(live_applied))

	match_node.state = DotMatch.State.INTERMISSION
	live.advance(0.1)
	_check(live_applied == [&"b"], "and the round ending is the change", str(live_applied))

	match_node.state = was
	warm.queue_free()
	live.queue_free()
	_finished()


## A director under `time_up: finish_round` carrying [param hook], its clock run out with a
## winner already decided: what dot-vote's own suite builds, with the game's answer in it.
func _finish_round_probe(hook: Callable, applied: Array) -> DotVoteDirector:
	var source := DotVoteListSource.new()
	var _a := source.add(DotVoteChoice.of(&"a", "A"))
	var _b := source.add(DotVoteChoice.of(&"b", "B"))
	source.apply_fn = func(id: StringName) -> DotResult:
		applied.append(id)
		return DotResult.success(id)

	var rules := DotVoteRules.new()
	rules.apply_delay_sec = 0.0
	rules.duration_sec = 100.0
	rules.vote_lead_sec = 40.0
	rules.vote_duration_sec = 5.0
	rules.include_extend = false
	rules.apply = DotVoteRules.Apply.END_OF_TIME
	rules.cooldown = 0
	rules.time_up = DotVoteRules.TimeUp.FINISH_ROUND
	# For ever: only the hook may release it.
	rules.finish_round_max_sec = 0.0

	var probe := DotVoteDirector.new()
	probe.rules = rules
	probe.source = source
	probe.register_service = false
	probe.self_advance = false
	probe.round_based = true
	probe.player_count_fn = func() -> int: return 4
	probe.set(&"round_in_progress_fn", hook)
	add_child(probe)
	probe.begin(&"a")
	source.current = &"a"

	for i in range(61):
		probe.advance(1.0)

	probe.cast_one(&"p1", &"b")

	# The ballot closes, then the limit (100 s) runs out with the winner decided.
	for i in range(46):
		probe.advance(1.0)

	return probe


## [b]`sc_ambient*` on a client.[/b] The server's ambience intent rides the replicated cvars over a real socket; the Ambience bus follows Effects.
func _test_ambient_cvars_reach_the_client() -> void:
	_section("the server's sc_ambient* reaches a client's ambience director, live")
	var side := Node.new()
	side.name = "AmbientClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var mirror := Node.new()
	mirror.name = "Dedicated"
	side.add_child(mirror)
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Ambient"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	mirror.add_child(link)
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(ScNetLink.NODE_NAME)) == null:
			var sink := ScNetLink.attached_to(link, null, false)
			sink.name = ScNetLink.NODE_NAME
			link.add_child(sink)
	attach.call()
	link.phase_changed.connect(attach)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var rules := ScAmbience.make_rules()
	var _followed := rules.follow_cvars(link)
	var director := DotAmbienceDirector.new()
	director.ambient = DotAmbience.new()
	director.follow_settings(null, rules)
	var joined := false
	for _i in 1800:
		await get_tree().physics_frame
		if link.replicated_cvar("sc_ambient_volume", "") != "":
			joined = true
			break
	_check(joined and link.replicated_cvar("sc_ambient_dir", "x") == "x",
		"the join carried sc_ambient_volume, and the machine-local sc_ambient_dir stayed home", str(link.replicated_cvars))
	var _vol := server.console.set_cvar("sc_ambient_volume", "0.8")
	var _mood := server.console.set_cvar("sc_ambient_mood", "swamp")
	var _off := server.console.set_cvar("sc_ambient", "0")
	var arrived := false
	for _i in 900:
		await get_tree().physics_frame
		if is_equal_approx(director.ambient.config.volume, 0.8) and director.ambient.config.mood == "swamp" \
				and not director.ambient.config.enabled:
			arrived = true
			break
	_check(arrived, "a change of volume, mood and the switch reaches the director live", str(rules.describe()))
	var _back_vol := server.console.set_cvar("sc_ambient_volume", "0.3")
	var _back_mood := server.console.set_cvar("sc_ambient_mood", "")
	var _back_on := server.console.set_cvar("sc_ambient", "1")
	var back := false
	for _i in 900:
		await get_tree().physics_frame
		if rules.is_on() and rules.mood == "":
			back = true
			break
	_check(back, "and back", str(rules.describe()))

	var audio := ScAudio.new()
	add_child(audio)
	var made := audio.setup()
	_check(made.ok and audio.ambient != null and audio.ambient.manager == audio.manager,
		"the client's audio builds a director on its manager", str(made.message if not made.ok else ""))
	var mixer := audio.manager.mixer
	mixer.sfx = 0.5
	mixer.ambience = 0.8
	var _applied := mixer.apply_to_buses()
	_check(is_equal_approx(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Ambience")), linear_to_db(0.4)),
		"the Effects slider reaches the Ambience bus the director plays on")

	audio.queue_free()
	director.ambient.free()
	director.free()
	link.disconnect_from_server("done")
	for _i in 120:
		await get_tree().physics_frame
	side.queue_free()
	_finished()


func _test_it_unloads_cleanly() -> void:
	_section("unloading")

	var module := _module()
	_check(module != null, "the module is still loaded")

	if module == null:
		_check(false, "it unloads")
		_check(false, "and the host forgets it")
		_check(false, "and its commands go with it")
		_check(false, "but the world is still standing")
		_finished()
		return

	server.modules.unload_all()

	for _i in range(6):
		await get_tree().process_frame

	_check(true, "it unloads")
	_check(_module() == null, "and the host forgets it")

	var gone := _run_command("sc_status")
	_check(
		gone.is_empty() or _said(gone, "Unknown") or _said(gone, "unknown"),
		"and its commands go with it",
		", ".join(gone)
	)

	# [b]The world is NOT the module's to free.[/b] It was in the tree before the module
	# loaded, and a server can unload and reload a game module without the map going away —
	# which is what `module reload` is for.
	_check(is_instance_valid(game) and game.platforms.count() > 0,
		"but the world is still standing", "%d platforms" % game.platforms.count())

	_finished()
