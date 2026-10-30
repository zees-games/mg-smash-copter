extends "sc_module_base.gd"


## This game, as a module a dedicated server loads.
##
## No `class_name`, a requirement: [method DotModuleHost.load_module] constructs it from a PATH, and a module in a dot-cloud pack cannot register globals in the host. [DotGameModule] holds the netcode, bridge, seal, identity, roster and tick; this adds the operator cvars, two console commands and the rule that keeps enough people in a round. Usage: `server.modules.load_module("res://game/sc_module.gd")`.

# No `const CHANNEL`: [DotGameModule] declares one and GDScript refuses a redeclaration, rightly, since a module logs through [method DotModule.log_info] under its own name and a second channel would split its records.

## Where the services keep punishments. Empty is [DotGameServices]'s default, `user://smash-copter_punishments.json`, the store a real server enforces.
##
## Static, because dot-server constructs the module from a path so no instance exists to set a field on; `examples/dedicated.tscn` points it at its own directory so runs do not append to the real store.
static var punishments_file: String = ""


func _module_name() -> String:
	return "smash"


func _map_config_game() -> String:
	return ScMapConfig.GAME_ID


func _map_config_keys() -> Dictionary:
	return ScMapConfig.KEYS


func _game_service() -> StringName:
	return ScGame.SERVICE


func _game_missing_hint() -> String:
	return (
		"create an ScGame, add it to the tree and let its _ready() register it under "
		+ "'%s' — a module cannot build the world, because the world outlives it"
		% String(ScGame.SERVICE)
	)


## The netcode's numbers, which are the game's and not the addon's.
##
## Tick rate comes from the world so `sv_tickrate` reaches it (the world is built after the server and reads the engine rate); a number written here would run the netcode at a rate the operator did not choose.
func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as ScGame).tick_rate
	config.snapshot_rate = ScGame.NET_SNAPSHOT_RATE
	config.world_extent = ScGame.NET_WORLD_EXTENT
	config.enable_prediction = true
		# On, with both callables wired by the bridge ([method ScNetBridge._wire_lag_compensation]); a flag reported enabled with nothing behind it misleads. Hitboxes stand on a floor that was elsewhere 100 ms ago, so rewinding a player rewinds where the platform had carried them.
	config.enable_lag_compensation = true
	# A dozen platforms, up to a hundred and ten props, a couple of choppers and everybody
	# playing — all of it always relevant, because the map is open air and a player can see
	# the whole of it.
	config.max_entities_per_snapshot = 192
	return config


func _make_bridge() -> Node:
	return ScNetBridge.new()


## Chat, voice and moderation, over [DotGameServices].
##
## The bridge is handed over as the link: chat goes through `send_chat`, voice through `send_voice`, and [DotGameModule] assigns `voice_relay_fn`, checks `check_admission` before seating and tells the roster to follow this layer so a leaver is forgotten by the limiter and voice router together.
func _make_services() -> Node:
	var services := ScServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's one-slot schema.
##
## [DotGameModule] builds it before the services. Authentication is the host's `dot_auth_server`, not this game's; this layer is the scoped profile, name and face after it. With authentication off everybody is a guest.
func _make_identity() -> Node:
	var identity_layer := DotPlatformIdentity.new()
	identity_layer.avatar_schema = ScAvatars.schema()
	identity_layer.stock_avatar_fn = ScAvatars.stock_avatar
	identity_layer.avatar_translate_fn = ScAvatars.from_site
	return identity_layer


func _game_load() -> DotResult:
	var world := game as ScGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not an ScGame.")

	add_command("sc_status", _cmd_status, "Show the round, the field and the cannon")
	add_command("sc_net", _cmd_net, "Show what the netcode is doing")
	add_command("sc_layouts", _cmd_layouts, "List the platform layouts this server plays")
	add_command("sc_specials", _cmd_specials, "List the special rounds, and what is in force")
	add_command("sc_say", _cmd_say, "Say something to everybody, as the server")

	# dot-game's "still loading": a seat behind its client's cover is neither hurt nor eliminated
	# (see ScGame.harm_gate). Asked by player id, resolved to a peer through the bridge.
	world.harm_gate = func(player_id: StringName) -> bool:
		if bridge == null:
			return true
		var peer := int((bridge as ScNetBridge).peer_for_player(ScNetBridge.session_of(player_id)))
		return peer <= 0 or can_peer_be_harmed(peer)

	_wire_chat()
	_wire_identity()
	_wire_armed(world)
	_wire_map(world)
	_wire_progress(world)
	_add_tunables(world)

	_bind_family_cvars(world)

	# REPLICATED: the clients play the killcam, the server only lengthens the intermission for it.
	var killcam := add_cvar("mp_killcam_time", _number(world.config.killcam_seconds),
		"Seconds the killcam of a round's last moment plays, added to the intermission (0 for none)",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)
	if killcam != null:
		killcam.changed.connect(func(_old: String, new_value: String) -> void:
			world.config.killcam_seconds = clampf(new_value.to_float(), 0.0, 30.0)
			world.apply_intermission())

	var configured := _bind_config(world)
	if not configured.ok:
		return configured

	_build_maps(world)
	_build_vote(world)

	_bots = add_cvar(
		"sc_bots", "1",
		"Automatic stand-ins: 1 keeps as many as bot_quota and bot_quota_mode say, 0 none at all."
	)

		# The count is dot-server's [DotBotQuota], so `bot_quota` and `bot_quota_mode` mean the same on every server. The default is `minimum_players` in fill mode: stand-ins top the round up, a joiner takes one's place. `sc_bots` stays the switch.
	_quota = DotBotQuota.install(self, world.config.minimum_players)

		# Started here, not in the world's `_ready`: `start()` lays the field out, and before the bridge existed nothing would hear `world_rebuilt`, leaving invisible floors the server knows and no client does.
	world.start()

	log_info("the field is up", world.describe())
	return DotResult.success(null)


## The addons' rule sets as cvars, REPLICATED where a client predicts or draws under them.
func _bind_family_cvars(world: ScGame) -> void:
	var flags := DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED

	# `mp_teammate_passthrough` 0 never, 1 a team-mate holding the muzzle, 2 every team-mate.
	if world.combat != null:
		var _passthrough := world.combat.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	var _ragdolls := world.ragdoll_rules.bind_cvars(add_cvar, flags)
	var _toys := world.toy_rules.bind_cvars(add_cvar, flags)

	# mp_forcecamera, mp_freeroam: each client flies its own spectator camera under them.
	for made: Object in world.spectate_rules.bind_cvars(add_cvar, flags):
		if str(made.get(&"name")) == DotSpectatorRules.CVAR_FORCE_CAMERA:
			_force_camera_cvar = made

	# mp_forceview and mp_solidplayers: the client places its camera and predicts its player under them.
	var _views := world.view_rules.bind_cvars(add_cvar, flags)
	var _bodies := world.body_rules.bind_cvars(add_cvar, flags)
	# sc_ambient*: each client plays its own ambience under the server's intent; the directory cvar stays local.
	var _ambient := world.ambient_rules.bind_cvars(add_cvar, flags, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY)


## Who somebody is reaches the world: a face as they are seated, and the real name and face once dot-platform has them.
##
## Admission finishes AFTER seating, so the seated name and face are a guest's whenever the profile store is slow; `player_admitted`, a wardrobe change and an operator's `platform_name` all end in [method ScNetBridge.refresh_player], a JOIN everybody can apply.
func _wire_identity() -> void:
	var link := bridge as ScNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved for them, or the stock person.
##
## Through the platform module's `player_for`, never the hub by a key made here: the hub keys by scoped profile key, so `u<session>` finds nobody and silently reads as "no avatar". Duck-typed, since a server without dot-platform is a configuration.
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session != null and platform != null and platform.has_method("player_for"):
		var player: Variant = platform.call("player_for", session)

		if player is Object and (player as Object).get("avatar") is DotAvatar:
			return (player as Object).get("avatar") as DotAvatar

	if identity != null and identity.has_method("avatar_for"):
		return identity.call("avatar_for", String(ScNetBridge.player_key(session_id)))

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null
	var link := bridge as ScNetBridge

	if session == null or link == null:
		return

	link.refresh_player(session_id, session.display_name, _avatar_for(session_id))


## The numbers an operator is actually going to want to change, as cvars.
##
## Live, each writing through to the configuration the world reads, so an operator can tune the cannon, stiffness and round length between rounds with people watching. Nothing already built is here: `sc_columns` shapes the NEXT round, and a cvar pretending otherwise would be reported broken.
func _add_tunables(world: ScGame) -> void:
	var config := world.config

	_tunable("sc_survival_seconds", config.survival_seconds,
		"Seconds on the platforms before the corners",
		func(value: float) -> void: config.survival_seconds = value)
	_tunable("sc_showdown_seconds", config.showdown_seconds,
		"Seconds the fight in the corners lasts",
		func(value: float) -> void: config.showdown_seconds = value)
		# How stand-ins aim and shoot is dot-bot's (`bot_difficulty` and the `bot_*` bundle). Set on the world as metadata, never the registry, since two servers in one process must not share it. `sc_bot_spread` stays a deprecated name for `bot_aim_error`.
	var bot_settings := DotBotSettings.of(world)
	var _bot_cvars := bot_settings.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY, add_command)
	_tunable("sc_bot_spread", bot_settings.profile.aim_error,
		"Deprecated, sets bot_aim_error. Degrees off a stand-in's aim when it opens fire",
		func(value: float) -> void:
			var _set := bot_settings.set_value("aim_error", str(value)))
	# What only this game's stand-ins do: how far they walk to a fight in the showdown, how
	# much lean they feel before they walk uphill, and how wide a miss they fire at.
	_tunable("sc_bot_advance", config.bot_advance_metres,
		"How far a stand-in walks toward an enemy in the showdown, in metres",
		func(value: float) -> void: config.bot_advance_metres = clampf(value, 5.0, 400.0))
	_tunable("sc_bot_lean_notice", config.bot_lean_notice_degrees,
		"Degrees of lean a stand-in feels before it walks uphill. Higher is clumsier",
		func(value: float) -> void: config.bot_lean_notice_degrees = clampf(value, 0.0, 15.0))
	_tunable("sc_bot_spray", config.bot_spray_metres,
		"Metres of miss a stand-in accepts when it fires. Higher sprays from further",
		func(value: float) -> void: config.bot_spray_metres = clampf(value, 0.1, 5.0))
	_tunable("sc_teams", float(config.team_count), "How many sides play, two to six",
		func(value: float) -> void: config.team_count = clampi(int(value), 2, 6))
	_tunable("sc_columns", float(config.columns), "Platforms along each row, next round",
		func(value: float) -> void: config.columns = clampi(int(value), 2, 12))
	_tunable("sc_rows", float(config.rows), "Rows of platforms, next round",
		func(value: float) -> void: config.rows = clampi(int(value), 1, 6))
	_tunable("sc_stiffness", config.platform_stiffness,
		"How hard a platform pushes itself level. Lower is wobblier",
		func(value: float) -> void: config.platform_stiffness = value)
	_tunable("sc_motion_gain", config.platform_motion_gain,
		"How much harder a running player leans a platform than a walking one",
		func(value: float) -> void: config.platform_motion_gain = value)
	_tunable("sc_collapse_lean", config.platform_collapse_lean,
		"Radians of lean a platform comes off its pillar at",
		func(value: float) -> void: config.platform_collapse_lean = value)
	_tunable("sc_cannon_interval", config.cannon_interval,
		"Seconds between shots at the start of a round",
		func(value: float) -> void: config.cannon_interval = value)
	_tunable("sc_cannon_ramp", config.cannon_interval_ramp,
		"What that gap is multiplied by by the end of the survival phase",
		func(value: float) -> void: config.cannon_interval_ramp = value)
	_tunable("sc_cannon_max_tier", float(config.cannon_max_tier),
		"The biggest prop the cannon may fire, 1 to 4",
		func(value: float) -> void: config.cannon_max_tier = clampi(int(value), 1, 4))
	_tunable("sc_special_chance", config.special_round_chance,
		"Chance in a hundred that a round is a special one",
		func(value: float) -> void: config.special_round_chance = value)
	_tunable("sc_chopper", 1.0 if config.chopper_enabled else 0.0,
		"Whether a layout may carry a chopper",
		func(value: float) -> void: config.chopper_enabled = value > 0.5)
	_tunable("sc_weapons", float(config.weapons_granted),
		"How many weapons a survivor is handed",
		func(value: float) -> void: config.weapons_granted = clampi(int(value), 1, 8))
	_tunable("sc_gravity", config.gravity, "Metres per second squared, for everything",
		func(value: float) -> void: config.gravity = value)
	_tunable("sc_spectate_camera", float(config.spectate_camera),
		"Deprecated, sets mp_forcecamera. Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody",
		func(value: float) -> void:
			config.spectate_camera = clampi(int(value), 0, 2)
			# Through the cvar, so what `mp_forcecamera` reports is what is in force.
			if _force_camera_cvar != null:
				var _set: Variant = _force_camera_cvar.set_value(str(config.spectate_camera))
			elif world.spectate != null:
				world.spectate.set_force_camera(config.spectate_camera))
	# [b]Deprecated: the count is `bot_quota` now[/b], and this forwards to it. Kept rather than
	# removed because every shipped server config sets it; left as its own number it would be
	# a second cvar deciding the same count, and whichever was read last would win.
	_tunable("sc_min_players", float(config.minimum_players),
		"Deprecated, sets bot_quota. How many players the server keeps in a round with stand-ins",
		func(value: float) -> void:
			config.minimum_players = clampi(int(value), 0, 24)
			if _quota != null and _quota.quota_cvar != null:
				var _set := _quota.quota_cvar.set_value(str(config.minimum_players)))


## Config fields whose hand-written cvar is not `sc_<field>`; the binder makes no second cvar for them and a workbench edit is pushed through the hand one.
const HAND_RENAMES := {
	"killcam_seconds": "mp_killcam_time", "bot_advance_metres": "sc_bot_advance",
	"bot_lean_notice_degrees": "sc_bot_lean_notice", "bot_spray_metres": "sc_bot_spray",
	"team_count": "sc_teams", "platform_stiffness": "sc_stiffness",
	"platform_motion_gain": "sc_motion_gain", "platform_collapse_lean": "sc_collapse_lean",
	"cannon_interval_ramp": "sc_cannon_ramp", "special_round_chance": "sc_special_chance",
	"chopper_enabled": "sc_chopper", "weapons_granted": "sc_weapons", "minimum_players": "sc_min_players",
}


## The hand-written cvar of a config field, or "" when the binder makes its own.
func _hand_cvar(key: String) -> String:
	var name: String = HAND_RENAMES.get(key, "sc_%s" % key)
	return name if console.has_name(name) else ""


## Every config field as an `sc_<field>` cvar (the hand-written ones keep their handlers and follow workbench edits), the cfg/ diff commands, the workbench and dot-team's block rules.
func _bind_config(world: ScGame) -> DotResult:
	var binder := world.config_binder
	if binder == null:
		return DotResult.success(null)
	workbench = DotGameWorkbench.new()
	workbench.name = "Workbench"
	workbench.dedicated = DisplayServer.get_name() == "headless"
	workbench.listen_host_fn = func() -> bool: return DisplayServer.get_name() != "headless"
	workbench.permit_fn = func(actor: Variant, flag: String) -> bool:
		return server != null and server.admins != null and actor is String \
			and bool(server.admins.uid_has_permission(actor, flag))
	for set: DotProfileSet in binder.profile_sets():
		workbench.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var ambient_set := DotGameWorkbench.cvar_set(console, ScAmbience.cvar_types(), AMBIENT_KIND)
	if ambient_set != null:
		workbench.add_set(ambient_set, "Ambience (sc_ambient*)")
	add_child(workbench)
	var started := workbench.start(world.ensure_runtime())
	# Off until the owner sets sv_workbench_remote 1; then flagged admins edit from a client.
	if started.ok and net != null:
		var _served := workbench.serve_remote(net)
	var runtime: DotProfileRuntime = workbench.api.runtime if started.ok and workbench.api != null else null
	if not started.ok:
		log_warn("the workbench did not start", {"why": started.error.message})

	var renamed := {}
	for key: String in HAND_RENAMES:
		if console.has_name(HAND_RENAMES[key]):
			renamed["sc_%s" % key] = true
	binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE,
		func(name: String) -> bool: return console.has_name(name) or renamed.has(name))
	binder.bind_commands(add_command)
	binder.field_changed.connect(_on_config_field)
	if runtime != null:
		binder.attach(runtime)
		if ambient_set != null:
			var _applied := DotGameWorkbench.bind_cvar_set(ambient_set, runtime, console)
	return DotResult.success(null)


## Everybody's side for the block rules: the team, none for a spectator.
func _noblock_side(id: Variant) -> Variant:
	return game.call(&"team_of_side", id) if game != null else ""


## The workbench's runtime, so its "noblock" kind is listed beside the config.
func _noblock_runtime() -> Object:
	return workbench.api.runtime if workbench != null and workbench.api != null else null


## The block commands are keyed by the player ids the world uses (`u<userid>`), not the bare userid.
func _build_noblock() -> DotResult:
	var built := super()
	if built.ok and noblock != null and noblock.commands != null:
		noblock.commands.set(&"key_fn", func(ctx: Object) -> Variant:
			var session: Variant = ctx.get("session")
			return ScNetBridge.player_key(int(session.get("userid"))) if session is Object else null)
	return built


## A workbench or file edit of a field: pushed through its hand-written cvar so the handler runs.
func _on_config_field(key: String, _value: Variant, source: String) -> void:
	if source == "cvar":
		return
	var hand := _hand_cvar(key)
	if hand == "":
		return
	var text: Variant = game.get("config").get(key)
	if text is bool:
		text = "1" if text else "0"
	console.set_cvar(hand, str(text))


## Registers one live numeric cvar that writes through to the world's configuration.
##
## The default is the value the world was built with: a literal default would be a second copy of what `defaults < JSON < environment < argv` decided, and would reset an operator's `SC_SURVIVAL_SECONDS=240` when written back.
func _tunable(
	cvar_name: String, current: float, description: String, apply: Callable
) -> void:
	var cvar := add_cvar(cvar_name, _number(current), description)

	if cvar == null:
		return

	# The handler must not capture `cvar`: it would be a reference cycle the engine never frees.
	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		apply.call(new_value.to_float())
		log_info("a tunable changed", {"cvar": cvar_name, "now": new_value})
	)


## Nothing to undo: [DotModule] removes the commands and [DotGameModule] tears down netcode, bridge and roster in reverse. The world is not this module's to free, since `module reload` must not make the map go away.
func _game_unload() -> void:
	if workbench != null:
		workbench.queue_free()
		workbench = null

	if game != null and "block_rules" in game:
		game.set(&"block_rules", null)

	noblock = null

	_bot_ids.clear()

	if vote != null:
		vote.queue_free()
		vote = null


## The server slept or woke. The vote's director follows it on its own (DotGameModule finds
## it); the layout ballot's timer is this game's, so it starts again here on waking.
func _game_hibernation(hibernating: bool) -> void:
	if not hibernating and vote != null:
		vote.note_woke()


## Keeps enough people in the round for there to be one.
##
## Two sides with somebody on each, or an elimination round ends the instant a side has nobody and restarts several times a second, each correctly decided so nothing errors. A stand-in leaves the moment a person takes their place.
func _game_tick(_tick: int, delta: float) -> void:
	if vote != null:
		vote.advance(delta)

	_since_roster_check += delta

	if _since_roster_check < ROSTER_INTERVAL:
		return

	_since_roster_check = 0.0
	_keep_the_round_full()


func _keep_the_round_full() -> void:
	var world := game as ScGame

	if world == null or bridge == null or _quota == null:
		return

		# People only: a stand-in is not one, nor is a bot added by hand (a test, an admin); those are not in `_bot_ids`. A leaver is gone from `players` as soon as the bridge removes them.
	var humans := 0

	for id: StringName in world.players:
		if not (world.players[id] as ScPlayer).is_bot:
			humans += 1

	# Forget any that have gone for some other reason — a round reset, an admin — so the
	# count below is of stand-ins that actually exist.
	for index in range(_bot_ids.size() - 1, -1, -1):
		if not world.players.has(_bot_ids[index]):
			_bot_ids.remove_at(index)

	# `sc_bots 0` takes the stand-ins out as well as not adding more: a switch that left the
	# ones already in until a map change would be an operator with no way to empty a server.
	var wanted := 0

	if _bots == null or _bots.get_bool():
		var slots: int = server.config.max_players if server != null and server.config != null else -1
		wanted = _quota.wanted(humans, slots)

	for _i in range(maxi(wanted - _bot_ids.size(), 0)):
		var bot: ScPlayer = bridge.call("add_bot", _bot_name(world))

		if bot == null:
			break

		_bot_ids.append(bot.player_id)

	# Newest first, so the stand-in a person replaces is the one that arrived last and the
	# ones that have been playing longest keep playing.
	while _bot_ids.size() > wanted:
		var leaving: StringName = _bot_ids.pop_back()
		bridge.call("remove_player", ScNetBridge.session_of(leaving))


## Names for the stand-ins, so a scoreboard of four of them is readable: this game's own names
## through dot-bot's [DotBotNames], never one already in [param world] (drawn at random they
## could double up), and the same from run to run.
static func _bot_name(world: ScGame) -> String:
	var taken: Array = []

	for id: StringName in world.players:
		taken.append((world.players[id] as ScPlayer).display_name)

	return DotBotNames.pick(taken, world.players.size(), ScGame.BOT_NAMES)


## Joins the bridge's chat seam to the services layer's router.
##
## Here because this is the only object holding both: the bridge knows the wire, the services layer the rules, so a client cannot send a line under somebody else's name.
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)


## The layouts and the players' vote for the next one (dot-vote: `!vote`, `!rtv`, `!nominate`); a layout is a round's map.
##
## The vote opens [member ScVote.open_after_sec] into each layout and applies when the round ends (`game/sc_vote.gd`); an owner tunes it in `user://cfg/smash_vote.json` or `game.yml`'s `metadata: layout_vote:`. A vote that cannot be built is a WARN and the weighted draw alone.
func _build_maps(world: ScGame) -> void:
	maps = ScMapSession.new()
	maps.name = "Maps"
	maps.catalogue = ScLayouts.catalogue(world.config)
	maps.apply_fn = world.change_layout_now
	add_child(maps)

	# `map`, `maps` and `mapinfo`, dot-map's, over the layouts. The change goes through the
	# game's own `change_layout_now` rather than a scene swap: see `ScMapSession`.
	var map_commands := DotMapCommands.new()
	map_commands.session = maps
	map_commands.change_fn = world.change_layout_now
	map_commands.player_count_fn = func() -> int:
		return world.players.size()
	map_commands.rotation_file_fn = func() -> DotMapRotationFile:
		return maps.rotation_file if maps != null else null
	map_commands.spec_fn = _rotation_commands
	DotLog.result(CHANNEL, "the map commands", map_commands.bind(self))

	world.world_rebuilt.connect(func() -> void:
		if maps != null and world.layout != null:
			maps.note_current(maps.catalogue.get_map(world.layout.id))
	)

	# maps.yml: which layouts the draw, the ballot and nominations may choose. Read now, and
	# again when the cvar is set; a `sv_map_rotation <name>` switch re-applies on its own and
	# the ballot is refreshed with every layout built (ScVote.note_layout).
	world.layout_in_rotation_fn = func(id: StringName) -> bool:
		return maps == null or maps.in_rotation(id)
	add_cvar(
		"sv_map_rotation_file", maps.rotation_file_name,
		"maps.yml: the layouts that rotate, in named rotations. Unlisted layouts stay installed.",
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			maps.rotation_file_name = new_value.strip_edges()
			var _read := maps.load_rotation()
			if vote != null:
				vote.refresh_layouts()
	)
	var _loaded := maps.load_rotation()


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func _rotation_commands() -> Dictionary:
	return maps.commands_spec() if maps != null else {}


func _build_vote(world: ScGame) -> void:
	vote = ScVote.new()
	vote.name = "LayoutVote"
	# Nothing to vote on when the operator turned the per-round draw off: they asked for one
	# layout all evening.
	vote.layouts_fn = func() -> Array:
		var out: Array = []

		if not world.config.vary_layout:
			return out

		# From the catalogue dot-map lists, so the ballot and `maps` can never disagree.
		for def in maps.catalogue.available() if maps != null else []:
			out.append([def.id, def.display_name])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		world.next_layout_id = id
		return DotResult.success(id)
	# People only: a stand-in is not a voter, and a ballot it could swing is not the players'.
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: ScPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := ScNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, ScServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), LAYOUT_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	# Whether a round is live, for `time_up: finish_round`: warmup and the gap between rounds
	# have nothing to play out, so a limit that runs out there changes at once. No match is
	# "cannot tell", which holds as before.
	vote.round_in_progress_fn = func() -> bool:
		return world.match_node == null or world.match_node.is_live()

	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the layout vote; the draw alone chooses", ready)
		vote.queue_free()
		vote = null
		return

	vote.commands_spec_fn = _rotation_commands
	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the layout vote's commands", commanded)

	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` changes the
	# layout now, not next round, and sees the same rows a solo player does. Read by name,
	# because a server on a dot-vote older than the menu has no `map_menu` and runs without it.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", world.change_layout_now)
		(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return world.layout_rows())

	_tunable("sc_vote_after", vote.open_after_sec,
		"Seconds into a round before the vote for the next layout opens",
		func(value: float) -> void:
			if vote != null:
				vote.open_after_sec = maxf(value, 0.0))

	# Every layout laid is a world_rebuilt, the warmup's included, and each is one play.
	world.world_rebuilt.connect(func() -> void:
		if vote != null and world.layout != null:
			vote.note_layout(world.layout.id)
	)
	world.match_node.round_ended.connect(func(_number: int, _winner: int, _outcome: int) -> void:
		if vote != null:
			vote.note_round_end()
	)

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid)))
		)


func _wire_map(world: ScGame) -> void:
	if world.layout != null:
		report_map(String(world.layout.id))

	world.round_began.connect(func(_number: int, layout_id: StringName) -> void:
		report_map(String(layout_id))
	)


## And the one game event the bridge cannot see for itself.
##
## `_arm` happens inside the world and a weapon is not a replicated entity, so one signal is cheaper than a behaviour.
func _wire_armed(world: ScGame) -> void:
	if bridge == null:
		return

	# [b]Every weapon dealt, the selected one first[/b], rather than only the one the game's
	# signal names: a watcher draws the gun in somebody's hand from the slot the snapshot
	# says is out, and a slot names a weapon only among the ones that player was dealt.
	world.player_armed.connect(func(player_id: StringName, weapon_id: StringName) -> void:
		bridge.call("announce_armed", player_id, weapon_id)
		var armed: Variant = world.players.get(player_id)
		if armed == null or armed.weapons == null or armed.weapons.arsenal == null:
			return
		for slot in armed.weapons.arsenal.slots():
			var held = armed.weapons.arsenal.slot_at(slot)
			if held != null and held.def != null and held.def.id != weapon_id:
				bridge.call("announce_armed", player_id, held.def.id)
	)


## An achievement is told to the one person who earned it.
##
## As a notice, which a client already draws in chat, rather than a new event kind; stand-ins never earn one ([ScProgress] does not count them).
func _wire_progress(world: ScGame) -> void:
	if bridge == null:
		return

	# Filed under dot-game's stable per-server key (guests too), so it outlives the connection
	# and a restart; see [ScProgress].
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(ScNetBridge.session_of(id)) \
				if server != null else null
			return String(stats_feed.key_for(session)) if session != null and stats_feed != null else ""

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", ScNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as ScGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out
