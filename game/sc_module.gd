extends DotGameModule

const ScNetBridge := preload("net/sc_net_bridge.gd")
const ScServices := preload("sc_services.gd")

const ScGame := preload("sc_game.gd")
const ScLayouts := preload("sc_layouts.gd")
const ScPlayer := preload("sc_player.gd")
const ScSpecials := preload("sc_specials.gd")
const ScAvatars := preload("sc_avatars.gd")
const ScVote := preload("sc_vote.gd")
const ScMapSession := preload("sc_map_session.gd")

## This game, as a module a dedicated server loads.
##
## [b]A hundred and forty lines, against the five hand-written modules' 837 to 1,816.[/b]
## [DotGameModule] holds the netcode and its four load-bearing constants, the bridge, the
## message seal, the identity layer, the roster, the authoritative tick and a teardown in
## the reverse order. Two of those five hand-written copies had the same line wrong and
## nobody could ever join those servers. What is left here is what is actually this game's:
## the cvars an operator turns between rounds, the two console commands, and the rule that
## keeps enough people in a round for one to happen.
##
## [b]No `class_name`, and that is a requirement rather than a style.[/b]
## [method DotModuleHost.load_module] takes a PATH and constructs the module itself — it
## must, because that is the shape that lets an operator name one in a config file — and a
## module delivered inside a dot-cloud pack cannot have a `class_name` at all: a mounted
## pack's globals are not registered in the host.
##
## [codeblock]
## server.modules.load_module("res://game/sc_module.gd")
## [/codeblock]

# [b]No `const CHANNEL` here, and its absence is the point.[/b] [DotGameModule] already
# declares one and GDScript refuses to let a subclass redeclare it — which is the right
# refusal: a module logs through [method DotModule.log_info], which stamps the module's own
# name, so a second channel would split one module's records across two places an operator
# has to know to turn up separately.

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0

## Where the services keep punishments. Empty is [DotGameServices]'s own default,
## `user://smash-copter_punishments.json` — the store a real server enforces.
##
## [b]Static, because nothing holds this module before it exists[/b]: dot-server constructs
## it from a path inside `load_module`, so there is no instance for a host to set a field on
## first. `examples/dedicated.tscn` points it at a directory of its own; before it could,
## every run appended the live tools' audit warnings to the real store, 106 of them by the
## time anybody counted.
static var punishments_file: String = ""

## The `sc_bots` cvar, held so the tick does not look it up sixty times a second.
var _bots: DotConVar = null

## `mp_forcecamera`, kept so the deprecated `sc_spectate_camera` writes through it.
var _force_camera_cvar: Object = null

## How many stand-ins, from how many people: dot-server's one rule for every game. See
## [method _keep_the_round_full].
var _quota: DotBotQuota = null

var _since_roster_check: float = 0.0

## How many stand-ins this module has put in, so it can take them out again.
var _bot_ids: Array[StringName] = []

## The players' vote for the next layout; null when it could not be built.
var vote: ScVote = null

## dot-map's session over the layouts: the catalogue `map`, `maps`, `mapinfo` and the ballot list.
var maps: ScMapSession = null

## The drawn ballot's notice topic. The client shell draws one menu per topic.
const LAYOUT_BALLOT_TOPIC := &"map_ballot"


func _module_name() -> String:
	return "smash"


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
## Tick rate from the world, so `sv_tickrate` reaches it: the server sets the engine's
## physics rate from that cvar at boot, the world is built after the server and reads it,
## and this reads the world. A number written here instead would be a netcode running at a
## rate the operator did not choose, silently.
func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as ScGame).tick_rate
	config.snapshot_rate = ScGame.NET_SNAPSHOT_RATE
	config.world_extent = ScGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	# [b]On, and the two callables that make it real are wired by the bridge.[/b] It was off
	# for as long as they were not: a flag reported as enabled with nothing behind it is
	# worse than one that is off, because the first reader to trust it loses an afternoon.
	# See [method ScNetBridge._wire_lag_compensation].
	#
	# The showdown is a fight at range with rifles, which is the ordinary reason to want it.
	# The less obvious one is that this game's hitboxes stand on a floor that was in a
	# different place a hundred milliseconds ago — so rewinding a player rewinds where the
	# platform had carried them to, which nothing else could reconstruct.
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
## [b]The bridge is handed over as the link, and that is the whole of the wiring.[/b] A chat
## line goes out through `send_chat` and a voice frame through `send_voice`, both on this
## game's own wire. [DotGameModule] does the rest: it assigns the bridge's `voice_relay_fn`,
## checks `check_admission` before seating anybody, and tells the roster to follow this layer
## so a leaver is forgotten by the rate limiter and the voice router together.
func _make_services() -> Node:
	var services := ScServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's
## one-slot schema. [DotGameModule] builds it before the services and loads dot-platform's
## own module beside it.
##
## [b]Authentication is not here and was never this game's.[/b] Whether a player is proven
## to be somebody is the host's `dot_auth_server`, the same for every game it runs; what
## this layer does is everything after — a scoped profile, the name on it, and a face.
## With authentication off everybody is a guest with a profile of their own, which is what
## a LAN server is.
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

	# Whether shots pass through team-mates: `mp_teammate_passthrough` 0 never, 1 a team-mate
	# holding the muzzle (the default), 2 every team-mate in the line. dot-combat's cvar,
	# defined there once for every game; live from the next shot, and a value the operator set
	# first (argv, content.yml) is read back. NOTIFY, because players should know; REPLICATED,
	# because every client's own manager predicts its tracers under it (the client follows it
	# through its link, see the client's _build_netcode).
	if world.combat != null:
		var _passthrough := world.combat.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	# Dead bodies: dot-player-char's sv_ragdoll* set. The server only picks each death's reaction
	# from them; REPLICATED, because the clients draw the bodies (see the client's _build_netcode).
	var _ragdolls := world.ragdoll_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	# The field's toys: dot-props' sv_toys* set. REPLICATED, because a client hides the toys the
	# server took away.
	var _toys := world.toy_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	# mp_forcecamera, mp_freeroam, mp_freeroam_speed: dot-spectate's rules, so spectators
	# free-roam unless an operator says otherwise. REPLICATED, because each client flies its
	# own spectator camera under them (ScClient.toggle_roam).
	for made: Object in world.spectate_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	):
		if str(made.get(&"name")) == DotSpectatorRules.CVAR_FORCE_CAMERA:
			_force_camera_cvar = made

	# dot-player-controller's mp_forceview (first or third person: the player's choice, or one
	# held) and mp_solidplayers (players and stand-ins block each other, 1 by default).
	# REPLICATED: the client places its own camera under the first and predicts its own
	# player under the second.
	var _views := world.view_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	var _bodies := world.body_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	# REPLICATED: the clients play the killcam, the server only lengthens the intermission for it.
	var killcam := add_cvar("mp_killcam_time", _number(world.config.killcam_seconds),
		"Seconds the killcam of a round's last moment plays, added to the intermission (0 for none)",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)
	if killcam != null:
		killcam.changed.connect(func(_old: String, new_value: String) -> void:
			world.config.killcam_seconds = clampf(new_value.to_float(), 0.0, 30.0)
			world.apply_intermission())

	_build_maps(world)
	_build_vote(world)

	_bots = add_cvar(
		"sc_bots", "1",
		"Automatic stand-ins: 1 keeps as many as bot_quota and bot_quota_mode say, 0 none at all."
	)

	# [b]How many is dot-server's [DotBotQuota], so `bot_quota` and `bot_quota_mode` mean the
	# same thing on every server in the family.[/b] The default is this game's own minimum
	# (`minimum_players`, from the config file) in fill mode, which is the rule it ran before
	# the policy was shared: stand-ins top the round up to that many players, a person who
	# joins takes a stand-in's place, and the stand-in comes back when they leave. `sc_bots`
	# stays the switch it always was, so a server config that sets it means what it meant.
	_quota = DotBotQuota.install(self, world.config.minimum_players)

	# [b]Started here and not in the world's own `_ready`.[/b] `start()` lays the field out
	# and puts everybody on it, and a world that did that before the bridge existed would
	# have built a dozen platforms with nothing listening to `world_rebuilt` — a field the
	# server knows about and no client is ever told about. They would be invisible floors:
	# a player stands on nothing and the server says they are fine.
	world.start()

	log_info("the field is up", world.describe())
	return DotResult.success(null)


## Who somebody is reaches the world: a face as they are seated, and the real name and
## face once dot-platform has them.
##
## [b]Three events and one path.[/b] Admission finishes AFTER a player is seated — dot-server
## has no stage between authentication and content to hold them in — so the name and face
## a player is seated with are a guest's whenever the profile store is slower than the
## join; `player_admitted` is the moment the real ones exist. A wardrobe change and an
## operator's `platform_name` are the same thing later. All three end in
## [method ScNetBridge.refresh_player], a JOIN everybody already knows how to apply.
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
## [b]Through the platform module's `player_for`, and never the hub by a key made here.[/b]
## The hub keys a player by their scoped profile key, which only admission knows; a lookup
## by `u<session>` finds nobody, every time, and falls through to stock — which reads as
## "this player has no avatar" rather than as a wrong key. Duck-typed, because a server
## without dot-platform is a configuration.
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
## [b]Live, and each one writes through to the configuration the world already reads.[/b]
## The alternative is what most of this family's games still do — a JSON file and a restart
## — and the reason to do better here is the shape of this game: the whole thing is a
## balance between how fast the cannon fires, how stiff the platforms are and how long a
## round lasts, and an operator finds their server's numbers by moving one of them between
## rounds with people watching.
##
## [b]What is NOT here is anything the world has already built.[/b] `sc_columns` changes how
## many platforms the NEXT round is laid out with; it does not put a platform in the air
## now. A cvar that pretended otherwise would be one an admin sets in the middle of a round
## and then reports as broken.
func _add_tunables(world: ScGame) -> void:
	var config := world.config

	_tunable("sc_survival_seconds", config.survival_seconds,
		"Seconds on the platforms before the corners",
		func(value: float) -> void: config.survival_seconds = value)
	_tunable("sc_showdown_seconds", config.showdown_seconds,
		"Seconds the fight in the corners lasts",
		func(value: float) -> void: config.showdown_seconds = value)
	# [b]How the stand-ins aim and shoot is dot-bot's[/b]: `bot_difficulty` (easy, medium, hard,
	# nightmare; medium by default) and every `bot_*` setting it bundles, the names every game in
	# the family uses. On the world as metadata, where its bots read it; never the registry,
	# since two servers in one process must not share it. `sc_bot_spread` (the old fixed aim
	# offset, per bot per round) stays as a deprecated name for `bot_aim_error`, so a server
	# config that set it still sharpens or loosens the stand-ins.
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


## A number as an operator would type it: `34`, not `34.000000`.
##
## [b]Not `%g`, which GDScript's format strings do not have.[/b] It is accepted by the parser
## and fails at RUNTIME with "unsupported format character" — inside `_game_load`, which is
## the one place in the module sequence that unwinds everything above it. The symptom in
## game-buses-from-hell was a server whose netcode came up, logged that it was ready, and
## then reported that the game would not load.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## One cvar, its default taken from the configuration rather than written twice.
##
## [b]The default is the value the world was built with, and that is the whole point.[/b] A
## cvar declared with a literal default is a second copy of a number that
## `defaults < JSON < environment < argv` has already decided — so an operator who set
## `SC_SURVIVAL_SECONDS=240` would see `sc_survival_seconds` report 120 and, worse, would
## reset their own setting the moment anything wrote the value back.
func _tunable(
	cvar_name: String, current: float, description: String, apply: Callable
) -> void:
	var cvar := add_cvar(cvar_name, _number(current), description)

	if cvar == null:
		return

	cvar.changed.connect(func(_old: String, _new: String) -> void:
		apply.call(cvar.get_float())
		log_info("a tunable changed", {"cvar": cvar_name, "now": cvar.get_string()})
	)


## [b]Nothing to undo.[/b] The commands are the module's own and [DotModule] removes them;
## the netcode, the bridge and the roster are [DotGameModule]'s and it tears them down in
## the reverse order it built them. The world is NOT this module's to free: it was in the
## tree before the module loaded, and a server can unload and reload a game module without
## the map going away, which is what `module reload` is for.
func _game_unload() -> void:
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
## [b]Two sides with somebody on each, or nothing happens at all.[/b] An elimination round
## ends the moment a side has nobody alive, and a side with nobody AT ALL satisfies that on
## the first tick — so a server with one person on it would start a round, end it, start
## another and end that, several times a second, for as long as nobody else joined. Every
## one of those rounds is decided correctly, which is why nothing errors.
##
## A stand-in is removed the moment a person takes their place. They are here to make the
## game exist, not to take the fun half from the people who came to play it.
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

	# People only. A stand-in is not one, and neither is a bot somebody put in by hand through
	# the bridge (a test, an admin): those are never in `_bot_ids` either, so they are left
	# alone and outside the count. A leaver is gone from `players` the moment the bridge
	# removes them, so nobody half-disconnected is counted.
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
## [b]Here rather than in either of them, because this is the only object that holds
## both.[/b] The bridge knows what arrived on the wire and nothing about what a line means;
## the services layer knows the rules and nothing about the wire. That separation is why a
## client cannot send a line with somebody else's name on it: what crosses is a channel id
## and a string, and everything else is decided on this side.
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)


## A round's layout is what a server listing prints as the map.
##
## The layout is this game's map: the field the round is played on, picked per round. Said
## on every round rather than once, because dot-server forgets the map whenever a game
## unloads and a layout changes between rounds.
## The players' vote for the next layout, over dot-vote: `!vote`, `!rtv`, `!nominate`.
##
## [b]Opened [member ScVote.open_after_sec] into every layout and applied when the round
## ends[/b], because a round here is a layout (one is drawn per round); see
## [code]game/sc_vote.gd[/code]. A server owner turns it off or reshapes it in
## `user://cfg/smash_vote.json` or `game.yml`'s `metadata: layout_vote:`, keyed as dot-vote's
## [DotVoteRules]. A vote that cannot be built is a WARN and the weighted draw alone, never a
## server that will not start.
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
## `_arm` happens inside the world and the bridge is not listening to the world's weapons,
## because a weapon is not a replicated entity here — it is a fact about a player that a
## watcher's HUD wants to name. One signal is cheaper than a behaviour.
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
## [b]As a notice, which a client already draws in its chat box[/b], rather than a new event
## kind: an unlock is text for one player, which is exactly what a notice is — and a stand-in
## never earns one, because [ScProgress] does not count them.
func _wire_progress(world: ScGame) -> void:
	if bridge == null:
		return

	# What a player keeps is filed under their scoped profile key, so it outlives the
	# connection; see [ScProgress]. Nothing for a stand-in or a guest, who keep their seat's.
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(ScNetBridge.session_of(id)) \
				if server != null else null
			var platform: Object = server.modules.get_module("platform") \
				if server != null and server.modules != null else null

			if session == null or platform == null or not platform.has_method("player_for"):
				return ""

			var held: Variant = platform.call("player_for", session)
			return str((held as Object).call("key")) if held is Object else ""

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", ScNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat. Run through the console as the person who typed it.
##
## [b]As THEM, not as the server.[/b] `run_command_as_uid` builds a context with that
## player's own flags, so `!kick` from somebody without the flag is refused by the same file
## that refuses it at the console — rather than by this function having an opinion.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, ScServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as ScGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


func _cmd_layouts(ctx: DotCmdContext) -> void:
	var world := game as ScGame

	if world == null:
		ctx.reply("No world.")
		return

	var lines := PackedStringArray(["the layouts this server plays"])

	for layout in ScLayouts.all(world.config):
		lines.append("  %-11s w=%-5s %s" % [
			String(layout.id), _number(layout.weight), layout.blurb,
		])

	lines.append("playing: %s" % (String(world.layout.id) if world.layout != null else "-"))
	ctx.reply_lines(lines)


func _cmd_specials(ctx: DotCmdContext) -> void:
	var world := game as ScGame

	if world == null:
		ctx.reply("No world.")
		return

	var lines := PackedStringArray(["the specials this server may draw"])
	var allowed: Dictionary = {}

	for special in ScSpecials.available(world.config):
		allowed[special.id] = true

	for special in ScSpecials.all():
		lines.append("  %-9s %-14s %s%s" % [
			String(special.id),
			special.display_name,
			"" if allowed.has(special.id) else "(excluded) ",
			special.blurb,
		])

	lines.append("in force: %s" % (world.special_line() if not world.active.is_plain() else "-"))
	ctx.reply_lines(lines)


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as ScGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out
