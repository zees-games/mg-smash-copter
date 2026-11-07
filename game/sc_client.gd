extends "sc_client_flashlight.gd"

## One local player, a camera and a HUD over an [ScGame], offline or against a server.
##
## One client for both: offline is the same world class with `authoritative` true, and the whole difference is [ScNetBridge], so there is no second game to keep in step. Which half runs depends on a [DotClientLink] published under `dot_client_link` before the scene loads (`--offline` forces offline). First or third person is camera only, since the simulation is first-person and predictable in both.


func _ready() -> void:
	# First, before anything is drawn: the platform raises the loading cover (held until the
	# player exists and the camera is current) and finds the link.
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	# Offline the project is the content; the lock pins this game's own pack and would hold the cover on a fetch of itself.
	platform.use_locked_content = not force_offline
	platform.spawned_fn = func() -> bool: return player != null
	platform.scoreboard_action = ScBindings.SCOREBOARD
	add_child(platform)
	gate = platform.gate

	# [b]zee-dot-weapons' art is this game's copy of it, wherever this game is mounted.[/b]
	# `ZeeWeaponArtTable` names `res://assets/…`, which a delivered pack lacks: guns and arms
	# would load invisible.
	ZeeModelCache.set_asset_root(ScPaths.root())

	var config := ScConfig.new()

	# `load_layered` on the client too: otherwise flags work on a dedicated server and do
	# nothing offline.
	var binder := ScConfig.make_binder(config, config_file)
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotLog.warn(CHANNEL, "falling back to defaults", {"why": loaded.error.message})

	link = platform.link as Node
	_offline = platform.offline

	_build_world(config, binder)

	# The sampler lives HERE and not on the player, because on a connected client the local
	# player does not exist yet: they arrive in a JOIN, several frames after the keyboard
	# does.
	_sampler = DotFpsSampler.new(ScPlayer.tunables_for(config, ScSpecials.Active.new()))
	ScPlayer.register_actions(_sampler)

	_build_hud()
	_build_chat()
	_build_audio()
	_build_fx()
	_build_settings()
	_build_killcam()

	if _offline:
		_start_offline()
	else:
				# In `_ready`, which runs INSIDE `DotClientLink._load_scene`: the link tells the server it has loaded on the next line, so the netcode must already be up.
		var netted := _build_netcode()
		DotLog.result(CHANNEL, "the netcode", netted)
		if netted.ok:
			_start_remote_workbench()


## The world: the field, its toys heard, held under the cover, with the dead's bodies.
func _build_world(config: ScConfig, binder: DotGameConfigBinder) -> void:
	game = ScGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	game.authoritative = _offline
	# A connected client's world is not what a module looks up, and registering it would mean
	# a client and a server sharing a process fighting over the name — which is what every
	# section of this game's own suite does.
	game.register_service = _offline
	game.tick_rate = int(
		ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 64)
	)
	# The field's toys are heard: a ball's bounce off a deck or a crate.
	var _toys_heard := game.toy_sound.connect(func(id: StringName, at: Vector3, strength: float) -> void:
		if audio != null:
			var _played := audio.on_toy(id, at, strength))
	# Before the world is added: a server-less world lays its first field out in its own _ready.
	_hold_for_fields()
	add_child(game)
	_build_ragdolls()


## The load gate is [member DotGameClient.gate].
##
## Covered also means the round does not run: `ScGame.hold_clock` stops the phase clock, lean, cannon and falls and steps only the bodies. Connected, the server owns the round, and what is left to hold is this end's sampling and keys ([method _covered]).


## A field is built: held from the moment the old one starts to go, released once the new one
## stands ([signal ScGame.world_clearing], [signal ScGame.world_rebuilt]).
func _hold_for_fields() -> void:
	game.world_clearing.connect(func() -> void: gate.hold(&"map", "Loading the field"))
	game.world_rebuilt.connect(func() -> void: gate.release(&"map"))
	game.hold_clock = _covered


func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	ragdolls.sound_fn = _ragdoll_sound
	add_child(ragdolls)


func _ragdoll_sound(id: StringName, at: Vector3, volume: float) -> void:
	if audio != null:
		var _played := audio.on_body(id, at, volume)


func _exit_tree() -> void:
	# A static outlives the game: the next one the shell loads must not look for its art here.
	ZeeModelCache.set_asset_root("res://")


func _start_offline() -> void:
	# Subscribed map packs are solo's alone: the layouts they add are listed in M ("Name [Pack]")
	# and played through the world's ordinary path. A server never calls this.
	workshop = ScWorkshop.new()
	workshop.follow()

	# Enough stand-ins for a round to exist at all: two sides with somebody on each, or the
	# elimination rule ends every round on its first tick.
	for i in range(offline_bots):
		var bot := game.add_player(
			StringName("bot%d" % i), _bot_name(i), (i % (game.config.team_count - 1)) + 2
		)
		bot.is_bot = true

	_adopt(game.add_player(&"local", "You", 1, true))
	_hear_the_world()
	game.round_began.connect(func(n: int, _layout: StringName) -> void: _round_presentation(n, true, 0))
	game.round_over.connect(func(n: int, winner: int) -> void: _round_presentation(n, false, winner))
	game.player_died.connect(_note_death)

	# Offline the world counts for the player at this keyboard, so it is the world that says
	# what they earned. Connected, the same line arrives as a notice from the server.
	game.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		if player != null and id == player.player_id and chat != null:
			chat.say_locally("Achievement: %s (+%d)" % [title, points], Color(0.98, 0.84, 0.40))
	)
	# Offline the world's handover is what arms the hands: `_on_phase` hears it only from the
	# bridge, and without these the offline player went into the showdown with nothing drawn.
	game.phase_changed.connect(func(to: int) -> void:
		if to == ScGame.Phase.HANDOVER:
			_arm_locally()
		elif to == ScGame.Phase.SURVIVAL:
			_disarm_locally()
	)
	game.player_armed.connect(func(id: StringName, _weapon: StringName) -> void:
		if id == &"local":
			_give_dealt())
	# Offline the world is the authority, so its own word on a hit is the confirmation.
	game.hit_landed.connect(func(id: StringName, point: Vector3, killed: bool, headshot: bool) -> void:
		if id == &"local":
			_on_hit(point, killed, headshot))
	game.start()

	# No bridge: the box still opens and still echoes, because a chat box that does nothing
	# at all reads as broken rather than as absent.
	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))


## A solo stand-in's name: the server's list through dot-bot's pick, so solo and a server name
## them alike and never twice.
static func _bot_name(index: int) -> String:
	var taken: Array = []

	for i in range(index):
		taken.append(DotBotNames.pick(taken, i, ScGame.BOT_NAMES))

	return DotBotNames.pick(taken, index, ScGame.BOT_NAMES)


## Solo, `bot_difficulty` and every `bot_*` setting at the console, the names a server has, and
## `-- --bot_difficulty hard` at launch. Connected, the server's console holds them and a local
## copy would shadow it.
func _bind_bot_console() -> void:
	if console != null:
		var local: Array = console.sources()
		if not local.is_empty() and local[0] is DotConsoleLocal:
			var _icons := ScWeaponIcons.shared.bind_console(local[0])
	if not _offline or console == null or game == null:
		return

	var sources: Array = console.sources()

	if sources.is_empty() or not (sources[0] is DotConsoleLocal):
		return

	var _bound := DotBotSettings.of(game).bind_console(sources[0])
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bot_difficulty")

	if index >= 0 and index + 1 < args.size():
		DotLog.result(CHANNEL, "bot difficulty from the command line",
			DotBotSettings.of(game).set_difficulty(args[index + 1]))


## Follows the server's replicated cvars: this end traces, places its camera and predicts under them.
func _follow_server_cvars() -> void:
		# The server's `mp_teammate_passthrough`, through the link: this end traces its own shots, and a differing default would end them in a team-mate where the server's did not. An older shell's link cannot say; the manager keeps its default.
	if game.combat != null and link != null:
		var _following := game.combat.follow_cvars(link)
	# The server's sv_ragdoll* set: this end draws the bodies.
	if link != null:
		var _bodies := game.ragdoll_rules.follow_cvars(link)
		# And sv_toys*: a client hides the toys a server took away.
		var _toys := game.toy_rules.follow_cvars(link)
		# And zee_ads_rules: this end predicts the server's aimed pace and spread.
		var _ads := game.ads_rules.follow_cvars(link)
		# The server's mp_forceview and mp_solidplayers: this end places its own camera and
		# predicts its own player.
		var _view := game.view_rules.follow_cvars(link)
		var _solid := game.body_rules.follow_cvars(link)
		var _ambient := game.ambient_rules.follow_cvars(link)
		if link.has_method(&"replicated_cvar"):
			_on_killcam_cvar("mp_killcam_time", String(link.call(&"replicated_cvar", "mp_killcam_time", "")))
			if link.has_signal(&"replicated_cvar_changed"):
				link.connect(&"replicated_cvar_changed", _on_killcam_cvar)
		# And mp_forcecamera / mp_freeroam*: this end flies the spectator's free camera.
		var _spectate := game.spectate_rules.follow_cvars(link)


func _build_netcode() -> DotResult:
	_follow_server_cvars()

	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	# Empty: by default a stale `user://dot_net.json` silently overrides the game's tick rate.
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = ScGame.NET_SNAPSHOT_RATE
	config.enable_prediction = true
	# Rewinding resolves shots, which only the server does.
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	# From the game: two copies of this number drift apart.
	config.world_extent = ScGame.NET_WORLD_EXTENT
	net.config = config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = ScNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	# Under the link, and NAMED the same as the server's — the name is the routing.
	bridge.open_link(link)
	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	DotLog.result(CHANNEL, "avatar action message", DotGameAvatarActionMessage.register(net))
	# The server's order again (after the avatar frame): the remote workbench's frame.
	workbench_remote = DotGameWorkbenchRemoteClient.attach(net)
	net.messages.seal()

	_connect_bridge()

	# The only RTT source (dot-net owns no transport); without it commands arrive late past ~30 ms.
	if link != null and link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))

	# READY only once the scene exists: anything sent before landed on a missing node.
	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


## The client's end of every bridge signal.
func _connect_bridge() -> void:
	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.seat_changed.connect(_on_seat_changed)
	bridge.phase_received.connect(_on_phase)
	bridge.special_received.connect(_on_special)
	bridge.round_changed.connect(_on_round)
	bridge.death_received.connect(_on_death)
	bridge.collapse_received.connect(_on_collapse)
	bridge.armed_received.connect(_on_armed)
	bridge.hit_received.connect(_on_hit)
	_hear_the_wire()
	bridge.shatter_received.connect(fx.on_shatter)
	# Where a gagged or too-fast line's refusal is drawn; undrawn, chat looks broken.
	bridge.notice_received.connect(func(text: String) -> void:
		if chat != null:
			chat.notice(text)
	)


func _say_ready() -> void:
	if workbench_remote != null:
		workbench_remote.ask()
	if bridge != null:
		bridge.ask_ready()


func _on_hello(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.players.get(ScNetBridge.player_key(session_id)))


## A player arrived or changed. The one we are waiting for might be us.
##
## Connected before anything can create a player, not only checked on HELLO: HELLO and JOIN are ordered, but depending on that ordering is what caused this bug in another game.
func _on_roster_changed(session_id: int) -> void:
	if session_id == _watch_id and player == null:
		_adopt(game.players.get(ScNetBridge.player_key(session_id)))


## The figure an avatar action plays on: that peer's player, or the local one offline.
func _avatar_figure(peer_id: int) -> Object:
	var who: ScPlayer = null
	if bridge != null and peer_id != 0:
		who = game.players.get(ScNetBridge.player_key(bridge.player_for_peer(peer_id)), null)
	if who == null and player != null and (net == null or peer_id == net.local_peer_id):
		who = player
	return who.figure.person if who != null and who.figure != null else null


func _adopt(candidate: ScPlayer) -> void:
	if candidate == null or player == candidate:
		return

	player = candidate
	if gate != null:
		gate.freeze(player)
	_build_camera()
	if platform != null:
		_suspend_input(platform.is_input_blocked())

	# Offline the world samples this player's movement itself, so the buttons go onto that
	# sample (`command_stamp`); stamping `current_command` below only reaches the drawn gun.
	if _offline:
		player.command_stamp = _stamp

	if settings != null:
		settings.bind_camera(self, &"base_fov")
		# Offline the player samples for themselves, from their controller's own tunables.
		_follow_look()

	if hud != null:
		hud.bind(game, player)


func _on_seat_changed(session_id: int, seated: bool) -> void:
	if player == null or session_id != _watch_id:
		return

		# The camera goes up into the cab: a pilot's eyes are above the instruments, and standing height while the machine carries the body is flying with your chin on the floor.
	_place_camera(seated)


func _on_phase(phase: int) -> void:
	_hear_phase(phase)

	match phase:
		ScGame.Phase.HANDOVER:
			hud.shout("CORNERS — hold your fire", 3.0)
			_arm_locally()
		ScGame.Phase.SHOWDOWN:
			hud.shout("GO", 1.6)
		ScGame.Phase.SURVIVAL:
			hud.shout("STAY UP", 2.2)
			_disarm_locally()


func _on_special(_id: StringName, starting: bool, blurb: String) -> void:
	if not starting:
		return

	if audio != null:
		var _heard := audio.on_special()

	hud.shout(blurb, 4.0)

	if chat != null:
		chat.say_locally(blurb, Color(0.98, 0.78, 0.33))

	if game.effects != null:
		var _flashed := game.effects.flash(&"special")


## The player's settings, applied to everything that reads them. See [ScSettings].
##
## After the audio and the sampler, because both are bound here and a binding applies at once; the camera is bound in [method _adopt].
func _build_settings() -> void:
	settings = ScSettings.new()
	settings.name = "Settings"
	add_child(settings)
	platform.settings = settings
	# Not handed over: ScHud is not the platform's Control to theme, so it follows the menu
	# itself, below.
	platform.chat = chat
	platform.look_position_fn = _look_position
	platform.board_snapshot_fn = board_snapshot
	# M: the layout list. Solo a choice changes the layout here at once; connected the server
	# decides, by the owner's `sv_map_menu_flag`, and anybody without it gets a vote instead
	# (dot-vote's map menu, wired in [ScModule]).
	platform.maps_rows_fn = func() -> Array: return game.layout_rows() if game != null else []
	platform.maps_change_fn = func(id: StringName) -> DotResult: return game.change_layout_now(id)
	platform.maps_title = "Change layout"
	platform.maps_noun = "layouts"
	DotLog.result(CHANNEL, "the platform", platform.setup())
	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	DotLog.result(CHANNEL, "avatar actions", platform.add_avatar_actions(net, _avatar_figure))
	# Walking is off while the cover is up, a menu is open or a line is typed: the sampler
	# polls the keyboard, and a player dragging a volume slider with the arrow keys would
	# otherwise walk off whatever they had stopped on.
	platform.input_blocked_changed.connect(_suspend_input)
	_suspend_input(platform.is_input_blocked())

	settings = platform.settings as ScSettings
	_add_noblock_and_workbench()
	console = platform.console as DotConsoleController
	if settings == null:
		return

	if _sampler != null:
		settings.bind_look(_sampler.tunables)

	if fx != null and fx.break_fx != null:
		fx.break_fx.follow(settings.settings)

	if audio != null:
		settings.bind_audio(audio.manager)
		# The server's sc_ambient* drive the quiet layer; the player's sliders multiply on top.
		if audio.ambient != null:
			audio.ambient.follow_settings(settings.settings, game.ambient_rules)

	if settings.menu != null:
		_bind_bot_console()
		# The HUD in the menu's theme and at the player's HUD size, live.
		if hud != null:
			hud.follow_menu(settings.menu)
		board = platform.board as DotMenuScoreboard
		_dress_board()


## Offline the world's own `shattered` drives it; connected, the bridge does (the mirror world never breaks anything).
func _build_fx() -> void:
	fx = ScFx.new()
	fx.name = "Fx"
	add_child(fx)
	var _built := fx.setup(game if _offline else null)


func _build_audio() -> void:
	audio = ScAudio.new()
	audio.name = "Sound"
	add_child(audio)

	var ready_now := audio.setup()

	if not ready_now.ok:
		# A game that cannot make a noise still plays; it is the state this one shipped in.
		DotLog.warn(CHANNEL, "no sound", {"why": ready_now.error.message})
		remove_child(audio)
		audio.queue_free()
		audio = null
		return

	if game != null and game.arena != null:
		audio.muzzle = game.arena.muzzle()


func _build_hud() -> void:
	hud = ScHud.new()
	# The counter reads the gun this player sees (corrected from the server's by correct_drawn).
	hud.weapons_fn = func() -> ZeeWeaponRig: return weapons
	hud.name = "Hud"
	add_child(hud)


## The chat box, before the netcode and before any player exists.
##
## Built in both halves and attached to the bridge afterwards: the backlog a joining player is sent is the first thing the server says.
func _build_chat() -> void:
	chat = new_chat()
	add_child(chat)


## Walking off and on: typing, or the settings screen up. Both samplers, because offline the
## player samples for themselves and connected the client does.
## dot-team's block rules followed from the server, and the F9 tuning panel where this process hosts the game.
func _add_noblock_and_workbench() -> void:
	if link != null:
		DotLog.result(CHANNEL, "noblock", platform.add_noblock(game, Callable(game, "team_of_side")))
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.listen_host_fn = func() -> bool: return true
	wb.config = {"enabled": false}
	if game.config_binder != null:
		for set: DotProfileSet in game.config_binder.profile_sets():
			wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var _fl := game.flashlight_conf()
	if game.flashlight_binder != null:
		for set: DotProfileSet in game.flashlight_binder.profile_sets():
			wb.add_set(set, "Flashlight")
	add_child(wb)
	var started := wb.start()
	DotLog.result(CHANNEL, "the workbench", started)
	if started.ok and game.config_binder != null:
		game.config_binder.attach(wb.api.runtime)
	if started.ok and game.flashlight_binder != null and wb.api != null:
		game.flashlight_binder.attach(wb.api.runtime as DotProfileRuntime)
	platform.add_workbench(wb)


## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote). The rows are the server's, through the bridge's profile link.
func _start_remote_workbench() -> void:
	if workbench_remote == null:
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = workbench_remote
	wb.remote_fn = func() -> bool: return true
	wb.config = {"enabled": false}
	if game.config_binder != null:
		for set: DotProfileSet in game.config_binder.profile_sets():
			wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var _fl := game.flashlight_conf()
	if game.flashlight_binder != null:
		for set: DotProfileSet in game.flashlight_binder.profile_sets():
			wb.add_set(set, "Flashlight")
	add_child(wb)
	var started := wb.start(game.ensure_runtime())
	DotLog.result(CHANNEL, "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	workbench = wb
	platform.add_workbench(wb)


func _suspend_input(suspended: bool) -> void:
	if suspended:
		# The button's release goes to the menu, so the aim is let go here or it sticks up.
		_aiming = false

	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


## The sampled command, on a connected client, once per tick the clock says has passed.
##
## Offline this does nothing and the world ticks itself. Connected, the local player is simulated by the PREDICTOR from the command that was sent, and a second sample would predict something the server was not told.
func _physics_process(delta: float) -> void:
	if _offline:
		_drive_offline(delta)
		return

	if net == null or not net.is_running() or bridge == null:
		return

	# The clock says how many ticks this frame is worth, which on a client whose engine runs
	# at the server's rate is almost always exactly one.
	var ticks := net.clock.advance(delta)

	# The clock has advanced; only the sampling waits, so the mouse does not pile up a turn
	# behind the cover and the server sees an idle body until it lifts.
	if _covered():
		return

	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	_stamp(move)

		# Each pass is its own tick: `advance` has moved the clock by all of them, so `input_tick()` is the LAST one every pass, and a two-tick frame would send the second twice and the first never, leaving the predictor's replay stopped at the hole. Arithmetic here, not a new dot-net call, so a pack runs on whatever shell the player has.
	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move, _slot, _aim_sent())

	_drive_view_model(move)


## Offline the world samples for itself; what is left is the buttons this file owns.
func _drive_offline(_delta: float) -> void:
	if player == null or player.sampler == null:
		return

	_follow_look()

	var pending := player.controller.current_command

	if pending != null:
		_stamp(pending)
		player.wanted_slot = _slot
		player.aiming = _aim_sent()

	_drive_view_model(pending)


## A hit the server confirmed for this player's shot: the marker, and zee's red burst on the body
## at the server's point (`ZeeShotFx.play_body_hit`, by `has_method` for an older shell's zee;
## it skips a burst its own presentation ray already drew).
func _on_hit(point: Vector3, killed: bool, headshot: bool) -> void:
	if hud != null:
		hud.confirm_hit(killed, headshot)
	if weapons == null or not is_instance_valid(weapons) or not weapons.has_method(&"shot_fx"):
		return
	var fx: Object = weapons.call(&"shot_fx")
	if fx == null or not fx.has_method(&"play_body_hit"):
		return
	var from: Vector3 = camera.global_position if camera != null else point + Vector3.UP
	fx.call(&"play_body_hit", point, point - from)


func _process(delta: float) -> void:
	var _shown := present_frame(
		net, game, player, not third_person, delta, -1.0, _watched_through_eyes()
	)
	if killcam != null and game != null:
		killcam.frame()

	if camera == null or player == null:
		return

	_present_aim()

	# [b]Before the rig, and instead of it.[/b] The rig below hangs the camera off the
	# player's own node, and a player who is out is a body at the kill height.
	if _drive_spectator_camera():
		_present_effects(delta)
		return

		# Drawn every FRAME from the controller's interpolated view, not per tick: a camera advanced in bursts is a 47% apparent-speed change several times a second, which reads as jitter with every number correct.
	var state := player.controller.state
	var pitch := deg_to_rad(state.pitch)
	var yaw := deg_to_rad(state.yaw)

	var rig: Node3D = camera

	if _arm != null and is_instance_valid(_arm):
		rig = _arm

	# The camera's half of the weapon's recoil. Added here rather than by the weapon,
	# because this line writes the angles from scratch every frame and would undo it; and
	# only here, never to the command — the shot already went where the command pointed.
	if weapons != null:
		var punch := weapons.view_punch()
		pitch += deg_to_rad(punch.x)
		yaw += deg_to_rad(punch.y)

	rig.rotation = Vector3(pitch, yaw, 0.0)

		# And the position from between the last two ticks: the rig hangs off the node, which only moves on a tick, so the camera advanced in steps (160 of 288 frames did not move at 64 ticks and 144 fps). `render_state` blends by the engine's physics fraction. Written globally, because the tick writes the node and prediction reads it back.
		#
		# Not while riding: the controller is not simulated, the machine carries the node, and a blend between ticks that never happened would drag the view backwards.
	if not player.riding:
		var drawn := player.controller.render_state()
		rig.global_position = drawn.position + Vector3(0.0, _rig_height, 0.0)
	else:
		rig.position = Vector3(0.0, _rig_height, 0.0)

	if weapons != null:
		var speed := Vector2(state.velocity.x, state.velocity.z).length()
		weapons.drive_view(
			Vector2(state.yaw, state.pitch),
			speed,
			state.mode != DotFpsState.Mode.AIR,
			state.crouch_fraction > 0.5
		)

	_present_effects(delta)


func _present_effects(delta: float) -> void:
	_present_flashlights(delta)

	# The ears are wherever the eyes are, which for somebody who is out is the spectator
	# camera — so a player watching a team-mate hears what that team-mate hears.
	if audio != null:
		audio.listen_from(camera.global_position)
		var _creaked := audio.present(game.platforms, game.config.platform_collapse_lean)
		audio.keep_walkers(game.players.values())

	if game.effects != null:
		game.effects.viewer_position = camera.global_position
		game.effects.advance(delta)


## Whether the camera is this player's own eye (first person, not watching anybody).
func _eye_is_ours() -> bool:
	return not third_person and not is_spectating()
