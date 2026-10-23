extends Node

const ScConfig := preload("../game/sc_config.gd")
const ScGame := preload("../game/sc_game.gd")
const ScPlayer := preload("../game/sc_player.gd")
const ScNetBridge := preload("../game/net/sc_net_bridge.gd")
const ScNetLink := preload("../game/net/sc_net_link.gd")
const ScLayouts := preload("../game/sc_layouts.gd")
const ScMapSession := preload("../game/sc_map_session.gd")
const ScAvatars := preload("../game/sc_avatars.gd")
const ScProgress := preload("../game/sc_progress.gd")

## Boots a real [DotServer], loads this game into it as a module, and runs the commands an
## operator would actually type.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]
##
## [b]This is the seam the family's own notes say is never run.[/b] `headless_run` tests the
## joins between the gameplay addons; this tests the join between the game and the SERVER —
## the module lifecycle, the console, the cvars, and `sv_tickrate` travelling from a line in
## a config file all the way into the netcode's own configuration.
##
## Nothing here opens a socket to a client, except the one section that checks still-loading. A dedicated server that never accepts one is
## still a dedicated server as far as its console, its cvars and its modules are concerned,
## and those are what this is about.

const SECTIONS := 16
const CHECKS := 152

## Everything this run writes, and it is deleted on the way in and on the way out.
##
## [b]A suite that writes to `user://` is a suite whose result depends on the last run.[/b]
## This one used to write the real punishment store, the server's ban and admin files and
## its audit log, all at their defaults — so every run appended to all four, and the live
## tools' warnings alone had reached 106 records in a store a real server enforces. Nothing
## failed yet; `docs/testing.md` has the two suites that did, on their ninth run.
const SERVER_DIR := "user://sc_dedicated"

## The port this test listens on. Nothing else on a developer's machine is likely to be
## holding it, and a boot that failed on a busy 27015 would look like the module being
## broken.
const PORT := 28891
const QUERY_PORT := 28892

## What the config file asks for. Deliberately not the project's own default: the point of
## the chain below is that the SERVER decides, so a test using the same number on both sides
## would pass with the chain disconnected.
const TICK_RATE := 48

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var server: DotServer = null
var game: ScGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
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
		await _test_it_unloads_cleanly()
		_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	# Against the declared number too. SECTIONS was declared and read by nothing — it said
	# 6 while eight sections ran — which is the detector for "a name that occurs once"
	# finding its own suite.
	#
	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	if _sections_entered != _sections_finished or _sections_entered != sections:
		print("ERROR: %d of %d sections finished, %d declared." % [
			_sections_finished, _sections_entered, sections
		])
		code = 1

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, checks
		])
		code = 1

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)
	get_tree().quit(code)


## Takes the server down before quitting, and this run does not end without it.
##
## [b]`get_tree().quit()` on a booted [DotServer] does not end the process.[/b] The listener
## is open and the transport is holding the main loop, so the run prints its results, reports
## success, and hangs — which in a CI job is a timeout on a suite that passed.
func _shut_down() -> void:
	if server == null:
		return

	# The modules first. A module unloaded by the server going away is one whose teardown
	# runs during `_exit_tree`, where there is no frame left to resume a coroutine in.
	if server.modules != null:
		server.modules.unload_all()

	server.shutdown("the dedicated test is finished")

	for _i in range(10):
		await get_tree().process_frame

	# And both nodes taken down rather than left for the engine to tear out from under
	# itself. Godot reports whatever is still alive at that point as leaked, which reads as
	# a reference cycle in the game and is a test that stopped one line early.
	if is_instance_valid(game):
		remove_child(game)
		game.free()
		game = null

	if is_instance_valid(server):
		remove_child(server)
		server.free()
		server = null

	await get_tree().process_frame


# --- Booting ----------------------------------------------------------------

func _boot() -> void:
	_section("booting")

	# The tick rate is set the way an operator actually sets it: a line in a config file the
	# server execs at boot.
	#
	# [b]`startup_config`, not `autoexec_config`.[/b] `sv_tickrate` is FLAG_STARTUP_ONLY — a
	# live server cannot re-negotiate its tick rate — and dot-server execs `server.cfg`
	# BEFORE the listener for exactly that reason, while `autoexec.cfg` runs after and would
	# have it refused.
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)

	if cfg == null:
		_check(false, "the test config file could be written", cfg_path)
		_check(false, "the server boots")
		_check(false, "and has a console")
		_check(false, "and sv_tickrate reached the engine's physics rate")
		_finished()
		return

	cfg.store_line("// written by examples/dedicated.gd")
	cfg.store_line("sv_tickrate %d" % TICK_RATE)
	cfg.store_line("hostname \"smash test\"")
	cfg.close()

	_check(true, "the test config file could be written")

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	# And nothing in the after-the-listener file, so the test is unambiguous about which one
	# set it.
	config.autoexec_config = ""
	config.hostname = "smash test"
	config.max_players = 24
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.port = PORT
	config.query_port = QUERY_PORT
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	# [b]Off, or this run never ends.[/b] The stdin console reads on its own thread, and a
	# thread blocked in a read is a thread Godot will not exit without — so the suite prints
	# its results, calls `quit()`, and hangs.
	# Kept after dot-server 5f46687, which no longer reads a pipe unless `stdin_console_pipes`
	# is on: a terminal is still read, and a suite takes no commands from either.
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)

	# `auto_boot` makes `_ready` await `boot()`, which opens a listener and reads the
	# config's environment and command-line layers — so this takes several frames and a
	# single `process_frame` catches it half-built.
	for _i in range(120):
		await get_tree().process_frame

		if server.state == DotServer.State.RUNNING:
			break

	_check(
		server.state == DotServer.State.RUNNING,
		"the server boots",
		DotServer.State.keys()[server.state]
	)
	_check(server.console != null, "and has a console")
	_check(
		Engine.physics_ticks_per_second == TICK_RATE,
		"and sv_tickrate reached the engine's physics rate",
		"%d" % Engine.physics_ticks_per_second
	)

	_finished()


# --- The module -------------------------------------------------------------

func _test_the_module_loads() -> void:
	_section("the module")

	# [b]The world is built AFTER the server and BEFORE the module, and both halves of that
	# order matter.[/b] After the server, because the server is what set the engine's tick
	# rate and the world reads it — which is the ordering a real deployment has. Before the
	# module, because a module refuses to load without a world to run: it cannot build one,
	# since the world outlives it across a `module reload`.
	var config := ScConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.survival_seconds = 3.0
	config.showdown_warmup_seconds = 1.0
	config.showdown_seconds = 6.0
	config.columns = 4
	config.minimum_players = 4

	game = ScGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)

	await get_tree().process_frame

	_check(
		DotRegistry.get_node_service(ScGame.SERVICE) == game,
		"the world publishes itself where a module will look for it"
	)
	_check(game.platforms.count() > 0, "and it already has a field",
		"%d platforms" % game.platforms.count())

	# Into this run's own directory. See [constant SERVER_DIR].
	#
	# Through the script, loaded here, rather than a `preload` at the top of this file:
	# a preload would load the module when this scene loads, long before the host does,
	# and the order scripts load in is what decides whether Godot 4.7.2 leaks them at
	# exit. See [method _run_exit_probe]. This is the order a deployed server has.
	(load("res://game/sc_module.gd") as GDScript).set(
		"punishments_file", "%s/punishments.json" % SERVER_DIR
	)

	var loaded: DotResult = await server.modules.load_module("res://game/sc_module.gd")
	_check(
		loaded.ok, "the module loads into the server",
		loaded.error.message if not loaded.ok else ""
	)

	var module := _module()
	_check(module != null, "and the host has it under its name")

	if module == null:
		_check(false, "the netcode is up")
		_check(false, "with the game's bridge attached to it")
		_check(false, "and a roster waiting for players")
		_check(false, "and the netcode runs at the rate the config file asked for")
		_check(false, "at the game's own snapshot rate")
		_check(false, "and the world extent both ends decode positions against")
		_check(false, "the manager does not tick itself: the module drives it")
		_check(false, "punishments go to this run's own store")
		_check(false, "and it starts empty")
		_finished()
		return

	# Through `get()`, because this module has no `class_name` — the shape a module
	# delivered in a dot-cloud pack must have.
	_check(module.get("net") != null, "the netcode is up")
	_check(module.get("bridge") != null, "with the game's bridge attached to it")
	_check(module.get("roster") != null, "and a roster waiting for players")

	var net: DotNetManager = module.get("net")
	_check(
		net.config.tick_rate == TICK_RATE,
		"and the netcode runs at the rate the config file asked for",
		"netcode %d, cfg %d" % [net.config.tick_rate, TICK_RATE]
	)
	_check(
		net.config.snapshot_rate == ScGame.NET_SNAPSHOT_RATE,
		"at the game's own snapshot rate"
	)
	_check(
		absf(net.config.world_extent - ScGame.NET_WORLD_EXTENT) < 0.01,
		"and the world extent both ends decode positions against"
	)
	_check(not net.auto_tick, "the manager does not tick itself: the module drives it")

	# [b]The store, and that it is empty.[/b] The second is what says the first worked on
	# THIS run: a path that is right and a directory that was not wiped is a suite carrying
	# the last run's punishments into this one, which is how two suites here began failing
	# on an unchanged tree.
	var services: Object = module.get("services")
	var moderation: Object = services.get("moderation") if services != null else null
	var store: Object = moderation.get("store") if moderation != null else null
	var store_path := str(store.get("path")) if store != null else ""
	_check(store_path.begins_with(SERVER_DIR),
		"punishments go to this run's own store, not the one a real server enforces", store_path)
	_check(moderation != null and int(moderation.call("count")) == 0,
		"and it starts empty, so nothing a previous run did is in it",
		"%d records" % int(moderation.call("count")) if moderation != null else "no moderation")

	_finished()


## A module reload must leave ONE link under the server, still named for the client's route.
## Two used to be left, the live one renamed `@Node@n`, and every RPC to a real client was lost
## without an error. The proof is a real client over the socket: signing on is server events.
func _test_a_module_reload() -> void:
	_section("a module reload leaves one live link")

	for _i in range(2):
		_check(server.modules.unload_module("smash").ok, "the module unloads")
		var back: DotResult = await server.modules.load_module("res://game/sc_module.gd")
		_check(back.ok, "and loads again", back.error.message if not back.ok else "")
	for _i in range(5):
		await get_tree().process_frame

	var links := 0
	for child in server.get_children():
		if child.get_script() == ScNetLink:
			links += 1
	_check(links == 1 and server.has_node(NodePath(String(ScNetLink.NODE_NAME))),
		"exactly one link, under the name the client routes to", "%d" % links)

	var side := Node.new()
	side.name = "ReloadClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Reloaded"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	var mirror := Node.new()
	mirror.name = "Dedicated"
	side.add_child(mirror)
	mirror.add_child(link)
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
	_check(joined and spawned[0], "a real client still hears the server's events after two reloads")
	link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	side.queue_free()
	_finished()


func _test_the_commands() -> void:
	_section("the console")

	var status := _run_command("sc_status")
	_check(_said(status, "smash-copter"), "sc_status says what the round is doing")
	_check(_said(status, "platforms"), "and how much of the field is left")

	var net := _run_command("sc_net")
	_check(_said(net, "bridge"), "sc_net says what the netcode is doing")

	var layouts := _run_command("sc_layouts")
	_check(_said(layouts, "full"), "sc_layouts lists the layouts")
	_check(_said(layouts, "playing"), "and says which one is up")

	var specials := _run_command("sc_specials")
	_check(_said(specials, "barrage"), "sc_specials lists the specials")
	_check(_said(specials, "in force"), "and says what is in force")

	var said := _run_command("sc_say hello from the server")
	_check(_said(said, "hello"), "sc_say says something")

	# And it is REPLICATED: dot-server sends it to every client before its scene loads and on
	# every change, so a client's own combat manager (following its link) predicts tracers
	# under the server's level rather than its default.
	var shared := server.console.find_cvar("mp_teammate_passthrough")
	var _two := _run_command("mp_teammate_passthrough 2")
	_check(shared != null and shared.has_flag(DotConVar.FLAG_REPLICATED)
			and server.console.replicated_values().get("mp_teammate_passthrough", "") == "2",
		"mp_teammate_passthrough is replicated: a client is sent the server's level",
		str(server.console.replicated_values()))
	var _one := _run_command("mp_teammate_passthrough 1")
	_finished()


## The cvars an operator turns between rounds, and the thing they must not be.
func _test_the_tunables() -> void:
	_section("the cvars")

	var config := game.config

	# [b]The default is the value the world was built with, not a literal.[/b] A cvar
	# declared with its own default is a second copy of a number the layered configuration
	# has already decided — so an operator who set it in a file would have it reported back
	# wrong and reset the moment anything wrote it.
	var declared := _run_command("sc_survival_seconds")
	_check(
		_said(declared, "3"),
		"a cvar reports the value the world was actually built with",
		", ".join(declared)
	)

	var before := config.cannon_interval
	_run_command("sc_cannon_interval 0.75")
	_check(
		absf(config.cannon_interval - 0.75) < 0.001,
		"and setting one writes through to the world's own configuration",
		"%.2f from %.2f" % [config.cannon_interval, before]
	)

	_run_command("sc_teams 4")
	_check(config.team_count == 4, "the number of sides can be changed between rounds",
		"%d" % config.team_count)

	# Clamped in the cvar's own handler rather than left to `validate()`, because an
	# operator typing a number at a live console should get the nearest legal one rather
	# than a server that refuses to start its next round.
	_run_command("sc_teams 99")
	_check(config.team_count == 6, "and is clamped to what this game can play",
		"%d" % config.team_count)
	_run_command("sc_teams 2")

	_run_command("sc_cannon_max_tier 2")
	_check(config.cannon_max_tier == 2, "the biggest prop the cannon may throw is a cvar")

	# Who somebody out may watch, which reaches the spectator manager's rules as well as the
	# configuration: a cvar that wrote only the configuration would change the NEXT world's
	# policy and leave this one's alone.
	_run_command("sc_spectate_camera 0")
	_check(
		config.spectate_camera == 0 and game.spectate != null
			and game.spectate.manager.rules.force_camera == 0,
		"who somebody out may watch is a cvar, and it reaches the running policy"
	)
	_run_command("sc_spectate_camera 9")
	_check(game.spectate.manager.rules.force_camera == 2, "and is clamped to the three it has")
	_run_command("sc_spectate_camera 1")

	# The module binds dot-spectate's rules on the world's own object, so a console change
	# reaches the rules in use; free roam is on until an operator turns it off.
	_run_command("sc_spectate_camera 0")
	var rules: DotSpectatorRules = game.spectate_rules
	_check(
		server.console.find_cvar("mp_freeroam") != null and server.console.find_cvar("mp_forcecamera") != null
			and server.console.find_cvar("mp_freeroam_speed") != null and rules.roaming_permitted(),
		"the module binds mp_forcecamera, mp_freeroam and mp_freeroam_speed, and free roam is on"
	)
	_run_command("mp_freeroam 0")
	_check(not rules.allow_roaming and not rules.roaming_permitted(), "mp_freeroam 0 reaches the running rules")
	_run_command("mp_freeroam 1")
	_run_command("sc_spectate_camera 1")
	_check(server.console.find_cvar("mp_forcecamera").get_int() == 1 and rules.force_camera == 1
		and not rules.roaming_permitted(),
		"the deprecated sc_spectate_camera writes through mp_forcecamera, and a restriction wins over roaming")
	_run_command("sc_spectate_camera 0")

	_finished()


## Counts the engine's own errors while installed. Those go to stderr and change no exit
## code, so without this a green run can print ten of them — which this section did, one
## `Condition "!is_inside_tree()"` per deck of the boot field, every round.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		_function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append(code)
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out


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

	# [b]Longer than the two phases add up to, because the round cannot start until there
	# are two sides.[/b] The module puts stand-ins in on a two-second interval and dot-match
	# refuses to leave warmup below `min_players`, so the clock this section is waiting on
	# does not begin at the moment the module loaded. Timing a test to the exact sum of its
	# phases is how a suite ends up failing on a slow machine and passing on a fast one.
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

	# [b]The round began inside the netcode's own tick, and that is the case this is for.[/b]
	# The boot field is replaced by round one's from inside `DotNetManager.server_tick`,
	# which then records lag-compensation history for the identity list it took before the
	# platforms were let go of — re-creating a track for every id the registry had just told
	# it to forget. Nothing reads them and nothing frees them: twelve per round, for the
	# life of the server. `history._tracks` is read directly because a leak is exactly what
	# no public accessor of the history would report.
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

	# The same moment, seen from the log: the old decks are out of the tree and still
	# registered for that one tick, and dot-net's history read their global basis. Fixed in
	# dot-net (DotNetHistory skips an entity that is not in the world, as
	# DotNetIdentity.world_position already did), because taking a node out between ticks
	# is something the netcode has already agreed a game may do.
	OS.remove_logger(errors)
	var seen := errors.seen()
	_check(seen.is_empty(), "and the engine reported no error",
		"%d: %s" % [seen.size(), " | ".join(seen.slice(0, 3))])

	_finished()


## The rule that keeps a round possible on a server nobody is on.
##
## [b]An elimination round with one side in it ends on its first tick.[/b] A server holding
## one person would start a round, end it, start another and end that, several times a
## second, with every decision correct — which is the bug game-buses-from-hell shipped and
## which is why this rule exists at all.
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

	# [b]A person takes a stand-in's place, and leaving gives it back[/b]: DotBotQuota's fill
	# mode, the family's default. Driven by calling the roster check rather than waiting for
	# its interval, with a person added through the bridge the way a test's player is (peer
	# zero, not a stand-in), so the count is exact and nothing else moves under it.
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


## dot-moderation's live tools, built by dot-game's services layer by path with this
## game's verbs in them, driven through the console against a player who joined the way a
## client does. The body is looked at the moment each command returns: a round can start
## or end under this section, and a new round is a new body here.
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

	module.get("roster").call("remove", session)
	var _released := server.release_session(session.peer_id)
	net.send_fn = previous_send
	_finished()


## Profiles, names and faces on a real server: dot-platform's identity layer, its module, and
## the three events this game redraws a player on.
##
## [b]Admitted AFTER they are seated, on purpose.[/b] That is the order a real join has
## whenever the profile store is slower than the content download — dot-server has no stage
## to hold a player in between — and it is the order in which a game that only read the
## name and face at seating shows a guest for the whole session. The session is seated with
## no identity, then given one and announced, exactly as dot-server announces it.
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

	# A guest first — a server with authentication off, where everybody is one. dot-user
	# keeps no profile for a guest by default (a guest id is a random per-device string, and
	# a file per device is a disk filling up), so they get the name they gave and keep the
	# stock look.
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

	# What they keep is filed under the key that outlives this connection, and is still
	# found by the world's own id.
	if game.progress != null:
		game.progress.record(&"u717", ScProgress.DEATHS)
	_check(
		game.progress != null and key != ""
			and game.progress.filed_under(&"u717") == StringName(key)
			and game.progress.stats.has_player(StringName(key))
			and game.progress.session_values(&"u717").get_value(ScProgress.DEATHS, 0.0) == 1.0,
		"and what they keep is filed under that key, found again by their seat",
		str(game.progress.filed_under(&"u717")) if game.progress != null else "no progress"
	)

	# An account's name is the site's, and dot-user refuses to change it here — so an
	# operator's `platform_name` on a signed-in player is a refusal they can read, and the
	# world keeps the name. The rename that IS allowed (a guest profile, on a server that
	# keeps them) reaching the session is dot-platform's sandbox's to check.
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

## [b]A seat whose client has not lifted its loading cover cannot be harmed, and can once it does[/b]
## (dot-game's "still loading"), over a real ENet socket. A client joins and says nothing, as one
## still loading its level; the world's damage path is then asked to crush it, shoot it and drop it
## through the floor, and must refuse all three. An admin's slay still passes. The client then
## sends `game.cover` on the wire and the same hit lands. Stand-ins never reach this: a bot is
## never loading.
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
	# The server's snapshots and events are RPCs to a node of this name under the link; with
	# none here each is an engine error. It drops what arrives (it has no bridge).
	# The link retires whatever the game left under it when it signs on, so it is put back at
	# each phase change (a real client's game scene does this from its _ready).
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


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _until_player(session: int) -> ScPlayer:
	await _until(func() -> bool: return game.players.has(ScNetBridge.player_key(session)), 10.0)
	return game.players.get(ScNetBridge.player_key(session))



## The players' vote decides the next layout, end to end through what a player types: a
## nomination, the ballot opening on its own clock with the nomination on it, a vote by
## number, the round's end putting the winner on the next round, and rock-the-vote opening a
## ballot early. Commands run at the console, which is where a `!vote` typed in chat lands
## (`_on_chat_command` runs it as the player); the console's voter is "console", so the
## voter list is that one name. Stand-ins are not voters, and a server of stand-ins never
## opens a ballot by itself.
##
## Synchronous from the round's end to the layout laid: the stand-ins' rounds are running,
## and one that started in a frame between would lay the voted layout itself and leave the
## check reading the draw's.
func _test_the_layout_vote() -> void:
	_section("the layout vote")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(vote != null, "the module built a layout vote")

	if vote == null:
		_finished()
		return

	var commands_there := true

	for name in ["vote", "rtv", "nominate"]:
		commands_there = commands_there and server.console.find_command(name) != null

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

	# The layout laid is a world_rebuilt, which starts the director over on it; rocking the
	# vote then brings the ballot forward instead of waiting for open_after_sec.
	_check(director.current_id() == StringName(wanted) and not director.is_voting(),
		"the new layout starts the vote over", str(director.current_id()))
	# Past dot-vote's cooldown between two ballots, on the director alone so the layout's own
	# ballot timer does not open one first. In play a round outlasts it.
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

	vote.call("refresh_layouts")
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
	vote.call("refresh_layouts")
	_finished()


## [b]`time_up: finish_round` waits for a round being played, never for warmup.[/b] The game
## hands dot-vote its match's answer (`round_in_progress_fn`); without it a limit that ran out
## in warmup held the change for `finish_round_max_sec` over a round that had not started.
## Run on a director of its own carrying the game's own hook, so the real vote's clock is
## untouched; the match's state is set by hand and put back.
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


# --- The harness ------------------------------------------------------------

func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


## The loaded module, looked up rather than kept.
##
## [b]Looked up every time, because the last section unloads it.[/b] A field would be a
## dangling reference the moment it did. Typed [DotModule] rather than as its own class,
## because `sc_module.gd` has NO `class_name` — it is loaded by path, which is the shape a
## module delivered in a dot-cloud pack must have.
func _module() -> DotModule:
	return server.modules.get_module("smash") if server != null else null


## Runs a line the way the console does and captures what came back.
##
## [b]Through `reply_sink`, not by reading `output` off a context built by hand.[/b] A
## command's reply goes wherever its context sends it — a socket, RCON, stdout — and the
## sink is that seam. A context constructed with `new()` and poked at is not the object a
## real command is handed.
func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []

	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)

	server.console.execute(line, context)

	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true

	return false


## [b]The one line that leaked mg-buses-from-hell's whole script graph at exit.[/b]
##
## A script that `extends DotNetMessage` and preloads ITSELF, first loaded from a module a
## running [DotServer] loads — which is how every deployed server loads this game — leaves
## every loaded script alive at exit on Godot 4.7.2 (measured in mg-buses-from-hell,
## 8ed866c). This game's event and request both did it, for a typed `of()` factory.
##
## [b]Asserted on the source, because the symptom is where no check can reach.[/b] The
## leak is reported after `quit()`, by the engine, as warnings a CI filter already treats
## as noise; an assertion here runs before any of it exists. So this checks the cause
## instead: every message script in `game/`, read as text.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")

	var messages := PackedStringArray()
	var offenders := PackedStringArray()
	var pending: Array[String] = ["res://game"]

	while not pending.is_empty():
		var dir_path: String = pending.pop_back()

		for sub in DirAccess.get_directories_at(dir_path):
			pending.append(dir_path.path_join(sub))

		for file in DirAccess.get_files_at(dir_path):
			if not file.ends_with(".gd"):
				continue

			var path := dir_path.path_join(file)
			var source := FileAccess.get_file_as_string(path)

			if not _extends_message(source):
				continue

			messages.append(path)

			if source.contains('preload("%s")' % file) or source.contains('preload("%s")' % path):
				offenders.append(path)

	_check(
		messages.size() >= 2,
		"this game's message scripts are found, so the next check is about something",
		", ".join(messages)
	)
	_check(
		offenders.is_empty(),
		"and none of them preloads itself, which leaks every script at exit",
		", ".join(offenders)
	)

	_finished()


func _extends_message(source: String) -> bool:
	for line in source.split("\n"):
		if line.begins_with("extends "):
			return line.contains("DotNetMessage") or line.contains("dot_net_message.gd")
	return false


# --- Exiting clean ----------------------------------------------------------------

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


## How long the copy may run before it is killed and this probe fails. A copy that is still
## running this long after it started is hung, and the likeliest reason is the one that says
## nothing at all: a scene whose script failed to parse never reaches `quit()` and prints
## nothing. `-- --exit-probe-seconds N` lowers it, which is how the deadline itself is armed —
## any N shorter than the suite takes is a copy that is still running when it expires.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it.[/b] "N ObjectDB instances were leaked at exit" is printed once the
## scene tree is gone, so the only process that can check a run's exit is another one. On
## Godot 4.7.2 a script that names itself, loaded after its base, cuts the engine's exit
## teardown short and every script loaded before it is reported leaked — hundreds of lines
## a passing run printed for weeks, which is why this is a check now and not a warning.
##
## [b]First, before this run opens a port[/b], so the two never contend for a socket — and
## so this run is always the second one against the same `user://`, which is the other
## thing no single run can see.
##
## [b]Not `OS.execute`.[/b] That blocks until the copy exits, so a copy that hangs held this
## run for ever; and when the outer `timeout` then killed this run, the copy was left behind
## holding the suite's directory and port. So the copy is started, polled against a deadline
## and killed at it. Two deadlines, because Godot dies on SIGTERM without running a line of
## script — nothing in this process can clean up after it is killed:
##
## - coreutils `timeout` wraps the copy where it exists. It is an exec wrapper, not a shell,
##   and it outlives this process, so a copy orphaned by the outer `timeout` still dies on
##   time. Its exit status 124 is how its expiry is recognised.
## - this loop's own deadline, a little later, for a platform without it.
##
## `execute_with_pipe` rather than `create_process`, because the latter captures nothing and
## the whole point is reading what the copy printed. Non-blocking, and drained on every pass
## rather than once at the end: a pipe holds 64 KiB, and a copy that fills it blocks on its
## next print — a hang this probe would then report as the suite's own. The copy's stdin is
## the other end of a pipe this process holds open, which is why every suite turns the
## server's stdin console off: a reader blocked on it never lets the copy exit.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	_section("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Every leak line is the engine's, and the engine writes them to stderr; both are
	# searched so that stays a fact about the engine rather than an assumption here. Shown
	# apart, because a pipe each is two streams whose interleaving is lost, and where a hung
	# copy had got to is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	_finished()


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))
