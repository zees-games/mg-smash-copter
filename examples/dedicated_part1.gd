extends "dedicated_base.gd"

const ScAmbience := preload("../game/sc_ambience.gd")
const ScAudio := preload("../game/sc_audio.gd")
const ScConfig := preload("../game/sc_config.gd")
const ScGame := preload("../game/sc_game.gd")
const ScPlayer := preload("../game/sc_player.gd")
const ScNetBridge := preload("../game/net/sc_net_bridge.gd")
const ScNetLink := preload("../game/net/sc_net_link.gd")
const ScLayouts := preload("../game/sc_layouts.gd")
const ScMapSession := preload("../game/sc_map_session.gd")
const ScAvatars := preload("../game/sc_avatars.gd")
const ScProgress := preload("../game/sc_progress.gd")

## Boots a real [DotServer], loads this game into it as a module, and runs the commands an operator would type.
## Tests the join between the game and the SERVER (module lifecycle, console, cvars, `sv_tickrate` from a config file into the netcode); `headless_run` covers the gameplay joins.
## No socket opens to a client except the still-loading section.

const SECTIONS := 17
const CHECKS := 175

## Everything this run writes, deleted on the way in and out: a suite that writes to `user://` makes its result depend on the last run (`docs/testing.md`).
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

var server: DotServer = null
var game: ScGame = null
var _stats_errors: PackedStringArray = []



## Sections of [code]dedicated.gd[/code], part 1: shared state and helpers are in the base.


## An ERROR from the stats layer would otherwise scroll past and leave a stat dead with every check green.
func _on_log_record(rec: Dictionary) -> void:
	if int(rec.get("level", 0)) >= DotLog.Level.ERROR and String(rec.get("channel", "")).begins_with("stats"):
		_stats_errors.append(str(rec.get("message", rec)))


## Takes the server down before quitting: `get_tree().quit()` on a booted [DotServer] does not end the process (the listener holds the main loop), so a passed suite would hang in CI.
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


func _boot() -> void:
	_section("booting")

	# The tick rate is set as an operator sets it, a line in a config file the server execs at boot.
	# `startup_config`, not `autoexec_config`: `sv_tickrate` is FLAG_STARTUP_ONLY and dot-server execs `server.cfg` before the listener, while `autoexec.cfg` runs after and would be refused.
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
	# Off, or this run never ends: the stdin console reads on a thread Godot will not exit without.
	# Kept after dot-server 5f46687 (no pipe reads unless `stdin_console_pipes`): a terminal is still read.
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


func _test_the_module_loads() -> void:
	_section("the module")

	# After the server (it sets the engine's tick rate the world reads), before the module (a
	# module cannot build a world: the world outlives it across a `module reload`).
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
	game.config_binder = ScConfig.make_binder(config)
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)

	await get_tree().process_frame

	_check(
		DotRegistry.get_node_service(ScGame.SERVICE) == game,
		"the world publishes itself where a module will look for it"
	)
	_check(game.platforms.count() > 0, "and it already has a field",
		"%d platforms" % game.platforms.count())

	# Into this run's own directory ([constant SERVER_DIR]). Loaded here, not preloaded: load
	# order decides whether Godot 4.7.2 leaks scripts at exit ([method _run_exit_probe]).
	(load("res://game/sc_module.gd") as GDScript).set(
		"punishments_file", "%s/punishments.json" % SERVER_DIR
	)

	var loaded: DotResult = await server.modules.load_module("res://game/sc_module.gd")
	_check(
		loaded.ok, "the module loads into the server",
		loaded.error.message if not loaded.ok else ""
	)

	var module := _module()
	_check(game != null and game.progress != null and game.progress.durable_key_fn.is_valid(),
		"progress is filed under dot-game's stable stats key")
	_check(module != null, "and the host has it under its name")

	if module == null:
		_fail_without_module()
		return

	# Through `get()`, because this module has no `class_name` — the shape a module
	# delivered in a dot-cloud pack must have.
	_check(module.get("net") != null, "the netcode is up")
	_check(module.get("bridge") != null, "with the game's bridge attached to it")
	_check(module.get("roster") != null, "and a roster waiting for players")

	_check_module_net(module)
	_check_module_store(module)

	_noblock_and_config(module)
	_test_stats_report()
	_finished()


func _fail_without_module() -> void:
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


func _check_module_net(module: Object) -> void:
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


func _check_module_store(module: Object) -> void:
	# The store must also be empty: that says the path worked on THIS run, not on a directory
	# still holding the last run's punishments.
	var services: Object = module.get("services")
	var moderation: Object = services.get("moderation") if services != null else null
	var store: Object = moderation.get("store") if moderation != null else null
	var store_path := str(store.get("path")) if store != null else ""
	_check(store_path.begins_with(SERVER_DIR),
		"punishments go to this run's own store, not the one a real server enforces", store_path)
	_check(moderation != null and int(moderation.call("count")) == 0,
		"and it starts empty, so nothing a previous run did is in it",
		"%d records" % int(moderation.call("count")) if moderation != null else "no moderation")


## A module reload must leave ONE link under the server, still named for the client's route; a second one lost every RPC to a real client without an error.
## The proof is a real client over the socket: signing on is server events.
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


## The family cvar `stats_report` is registered, off, and turning it on makes the tracker report.
func _test_stats_report() -> void:
	var cv: DotConVar = server.console.find_cvar("stats_report")
	var progress = game.progress if game != null else null
	_check(cv != null and cv.get_string() == "0", "stats_report is registered and off by default")
	_check(progress != null and progress.stats != null and not progress.stats.report_to_backbone,
		"and the tracker does not report at boot")
	if cv == null or progress == null:
		return
	var _on := cv.set_value("1")
	_check(not progress.stats.report_to_backbone, "on with no backbone client stays off, not a crash")

	var client := Node.new()
	var script := GDScript.new()
	script.source_code = "extends Node\nfunc post_integration(_a = null, _b = null, _c = null): return null\n"
	var _reloaded := script.reload()
	client.set_script(script)
	DotRegistry.register(&"dot_backbone_client", client)
	var _r0 := cv.set_value("0")
	var _r1 := cv.set_value("1")
	_check(progress.stats.report_to_backbone, "on with a backbone client makes the tracker report")
	var _r2 := cv.set_value("0")
	_check(not progress.stats.report_to_backbone, "off stops it again")
	DotRegistry.unregister_instance(&"dot_backbone_client", client)
	client.free()


## Config cvars, the workbench's sync into a hand-written cvar, and dot-team's block rules through dot-game's DotGameNoblock.
func _noblock_and_config(module: DotModule) -> void:
	var teamblock := server.console.find_cvar("mp_teamblock")
	var enemyblock := server.console.find_cvar("mp_enemyblock")
	_check(teamblock != null and teamblock.get_string() == "0" and enemyblock != null and enemyblock.get_string() == "1",
		"mp_teamblock is 0 and mp_enemyblock is 1 by default")
	_check(server.console.has_name("sc_impact_min_speed") and server.console.has_name("sc_fall_gravity_scale") and server.console.has_name("sc_friendly_fire"),
		"config fields with no hand-written cvar are sc_ cvars")
	_check(not server.console.has_name("sc_platform_stiffness"), "a field with a hand-written cvar gets no second one")
	_check(module.get("workbench") != null, "the module hosts the workbench")
	var wb: DotGameWorkbench = module.get("workbench")
	var amb: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "ambience", "id": DotGameWorkbench.CVAR_SET_ID, "key": "sc_ambient_volume", "value": 0.2})
	_check(amb.ok and is_equal_approx(server.console.get_float("sc_ambient_volume"), 0.2), "the sc_ambient* cvars are a workbench set and an edit moves the cvar", "" if amb.ok else amb.error.message)
	var _restore := server.console.set_cvar("sc_ambient_volume", "0.3")
	game.config.platform_stiffness = 4.5
	module.call("_on_config_field", "platform_stiffness", 4.5, "workbench")
	_check(server.console.find_cvar("sc_stiffness").get_string().to_float() == 4.5, "a workbench edit reaches the hand-written cvar",
		server.console.find_cvar("sc_stiffness").get_string())
	game.sides[&"u91"] = 1
	game.sides[&"u92"] = 1
	game.sides[&"u93"] = 2
	game.body_rules.solid = true
	_check(not game.body_rules.blocks(&"u91", &"u92"), "team-mates pass with mp_teamblock 0")
	_check(game.body_rules.blocks(&"u91", &"u93"), "enemies block with mp_enemyblock 1")
	teamblock.set_value("1")
	_check(game.body_rules.blocks(&"u91", &"u92"), "mp_teamblock 1 makes team-mates block")
	teamblock.set_value("0")
	game.body_rules.solid = false
	game.sides.clear()


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

	# The default is the value the world was built with, not a literal: a cvar with its own default is a second copy of a number the layered configuration already decided, reported back wrong and reset on the first write.
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


## The loaded module, looked up every time because the last section unloads it.
## Typed [DotModule], not its own class: `sc_module.gd` has NO `class_name`, the shape a module delivered in a dot-cloud pack must have.
func _module() -> DotModule:
	return server.modules.get_module("smash") if server != null else null


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true

	return false


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


## Runs a line the way the console does and captures what came back.
## Through `reply_sink`, not `output` on a hand-built context: a reply goes wherever its context sends it, and a poked-at `new()` is not what a real command is handed.
func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []

	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)

	server.console.execute(line, context)

	return PackedStringArray(captured)
