extends Node3D

const ScArena := preload("sc_arena.gd")
const ScCannon := preload("sc_cannon.gd")
const ScConfig := preload("sc_config.gd")
const ScContent := preload("sc_content.gd")
const ScCopter := preload("sc_copter.gd")
const ScLayouts := preload("sc_layouts.gd")
const ScPlatforms := preload("sc_platforms.gd")
const ScPlayer := preload("sc_player.gd")
const ScProgress := preload("sc_progress.gd")
const ScSpecials := preload("sc_specials.gd")
const ScSpectate := preload("sc_spectate.gd")

## The simulation. Headless, authoritative, and the only thing that decides anything.
##
## [b]A round is two games and the join between them is the whole design.[/b] For two
## minutes nobody can hurt anybody: the only threat is the floor, and the only skill is
## deciding where to stand on something that leans toward you. Then the clock runs out, the
## survivors are thrown into the corners with weapons they did not choose, and it becomes a
## fight — between exactly the people who were good at the first half. Neither half would
## be much on its own. What makes the second one work is that the people in it earned their
## place by not falling over.
##
## [b]What it owns and what it borrows.[/b] The round, the sides and the scoreboard are
## dot-match's; health and damage are dot-combat's; the props are dot-props'; the chopper is
## dot-vehicle's; the weapons are dot-weapon's through zee-dot-weapons; the platforms are
## [ScPlatforms] and are this game's own, because nothing in the family models a floor that
## tips. The joins are the part that is new, and they are the part worth reading.

const CHANNEL := "sc.game"

## Where this world publishes itself, so a module can find it.
##
## [b]A registry name and not an autoload, which is the family rule and here also a
## requirement.[/b] A server and a client in one editor session is two of these, and the
## suite builds two worlds in one process on purpose.
const SERVICE := &"sc_game"

## Snapshots a second, against the simulation tick.
##
## [b]Higher than game-buses-from-hell's twenty, and the platforms are why.[/b] Almost
## nothing here is predicted and the one thing a player has to read continuously is the
## lean of the floor they are standing on — which arrives only in a snapshot. At twenty a
## platform's tilt updates in visible steps, and a step in the surface under your feet
## reads as the game stuttering.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire.
##
## [b]A quantised position is decoded against this range.[/b] Two ends that disagree about
## it do not lose precision, they land somewhere else entirely: game-arena had 256 against
## 128 in two files that each looked right on its own, and drew sky in every direction. It
## is written here, once, and both ends read it from here.
const NET_WORLD_EXTENT := 256.0

## The four teams-plus-two this game can play with, in id order. `DotTeam` ids start at 1.
const TEAM_COLOURS: Array[Color] = [
	Color(0.85, 0.27, 0.26),
	Color(0.29, 0.53, 0.86),
	Color(0.35, 0.72, 0.38),
	Color(0.92, 0.78, 0.22),
	Color(0.66, 0.42, 0.82),
	Color(0.91, 0.55, 0.20),
]

const TEAM_NAMES: Array[String] = [
	"Red", "Blue", "Green", "Yellow", "Violet", "Orange",
]

## Which half of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people to start one.
	IDLE,
	## On the platforms. Nobody can hurt anybody; the floor does all of it.
	SURVIVAL,
	## Everybody has been thrown into a corner and is holding a weapon they cannot fire yet.
	HANDOVER,
	## The fight.
	SHOWDOWN,
}

## How far a falling prop has to be going down before a landing counts as an impact.
##
## [b]Above one tick of gravity, and this is the trap dot-props wrote down twice.[/b] A
## physics assertion that does not say what it is excluding is measuring gravity: at 20
## m/s² and 64 Hz a body that is merely resting reads 0.31 m/s downward every step, so a
## threshold near zero turns every crate sitting on a platform into a continuous impact.
const IMPACT_MIN_SPEED := 3.5

## How much of its downward speed a body has to lose in one step to count as having landed.
const IMPACT_LOSS := 0.45

## Metres from an impact within which a player is hurt by it.
const IMPACT_HURT_RADIUS := 2.4

## Damage a landing does to a player, per kilogram metre per second of impulse.
const IMPACT_HURT_PER_IMPULSE := 0.055

## Metres above the kill height at which a chopper counts as having reached the floor.
##
## A parked machine's origin rests 0.9 m above the surface it is on, measured, so a check at
## the kill height itself never fires for one sitting on the floor. Two metres is that plus
## a margin for a machine still bouncing, and is thirty-eight metres below any deck.
const COPTER_FLOOR_CLEARANCE := 2.0

## Metres above the kill height at which a person on foot has reached the floor.
##
## [b]The floor's top IS the kill height, so nobody standing on it is below it.[/b] Until
## 2026-09-25 the fall check was `y <= kill_height`, and a person who fell forty metres landed
## on the floor with their feet a centimetre above it — the motor rests a capsule a skin width
## off whatever it stands on — and stood there, alive, for the rest of the round. Every fall
## check in the suites put a player five metres UNDER the floor with `place_at` and stepped
## once, which a real fall never does; the first check that let somebody actually fall off a
## collapsed platform found nobody had ever died of it. Half a metre is a step height with a
## margin, and nothing in the world a person can stand on is within thirty-eight metres of it.
const FLOOR_REACH := 0.5

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)

## A round began. The platforms have been re-laid by the time this fires.
signal round_began(number: int, layout_id: StringName)

## The field is about to be taken down and rebuilt.
##
## [b]Before, and a bridge that only listened for the rebuild was holding freed nodes.[/b]
## Every platform is a replicated entity whose behaviour is a CHILD of the platform's own
## body, so clearing the field frees the behaviours with it — and the bridge's table of
## replicated bodies then holds a dozen freed instances, which Godot reports as "Trying to
## assign invalid previously freed instance" once per entry per tick, for ever. The
## dedicated run printed it twenty-three times before anybody noticed what it was.
signal world_clearing()

## Asked every tick of a world that ticks itself: true while a cover is up (the client's load
## gate). Only the bodies are stepped then, so they settle onto the decks, and the phase, the
## platforms, the cannon, the falls and the round clock wait. Unset, never held.
var hold_clock: Callable = Callable()

## The field has just been rebuilt, by a round starting or by the world opening.
##
## [b]Separate from [signal round_began] because it fires once more than that does.[/b] The
## world lays itself out when it opens, before dot-match has run a warmup, so a bridge that
## only replicated platforms on a round start would leave everybody who joined during the
## warmup standing on a field the server knows about and no client has been told about.
signal world_rebuilt()

## A round ended. [param winner] is a team id, or 0 for a draw.
signal round_over(number: int, winner: int)

## The round moved from one half to the other.
signal phase_changed(phase: int)

## A special started or stopped. [param starting] says which.
signal special_changed(id: StringName, starting: bool, blurb: String)

## Somebody fell, was crushed, or was shot.
signal player_died(player_id: StringName, by: StringName, why: StringName)

## A platform came off its pillar. The client draws it; this decides it.
signal platform_collapsed(index: int, why: StringName)

## Something landed hard enough to matter.
signal platform_struck(index: int, at: Vector3, impulse: float, outcome: int)

## A barrel went off.
signal blast(at: Vector3, radius: float)

## Somebody earned an achievement. What a module turns into a notice to that one player.
signal achievement_earned(player_id: StringName, title: String, points: int)

## A survivor was handed a weapon at the handover.
##
## [b]A signal rather than something the bridge could watch for itself.[/b] A weapon is not a
## replicated entity in this game — it is a fact about a player that a watcher's HUD wants to
## name — so there is no spawner emitting anything and nothing for a behaviour to hang off.
signal player_armed(player_id: StringName, weapon_id: StringName)

## A weapon's shot took health off somebody: to [param player_id], the shooter, for the hit
## marker and the hit drawn on the body. The server's word, never a client's prediction.
signal hit_landed(player_id: StringName, point: Vector3, killed: bool, headshot: bool)

const DIED_FELL := &"fell"
const DIED_CRUSHED := &"crushed"
const DIED_SHOT := &"shot"
const DIED_BLAST := &"blast"

@export var config: ScConfig = null

## Whether this instance decides anything. A client sets this false.
@export var authoritative: bool = true

@export_range(1, 240, 1) var tick_rate: int = 64

## Whether something else drives the tick.
##
## [b]Set by the bridge on both ends, and it has to be both.[/b] A game's tick has to
## happen INSIDE the netcode's — between applying each peer's inputs and building the
## snapshot — so a world still running its own `_physics_process` moves every player twice
## a tick, and what that looks like is a server running at double speed only while
## somebody is connected.
@export var external_tick: bool = false

## Whether this world publishes itself under [constant SERVICE].
@export var register_service: bool = true

var arena: ScArena = null
var platforms: ScPlatforms = null
var cannon: ScCannon = null
var props: DotPropSpawner = null
var prop_damage: DotPropDamage = null

## `func(player_id: StringName) -> bool`: whether a player may be hurt now, assigned by the
## module from dot-game's `can_peer_be_harmed`. Unset offline, and a bot is never loading.
var harm_gate: Callable = Callable()
var vehicles: DotVehicleSpawner = null
var ride: DotVehicleRide = null
var combat: DotCombatManager = null
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies. The game's, not the map's.
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## dot-props' `sv_toys*`, bound by the module (REPLICATED) and followed by a client.
var toy_rules: DotPropToyRules = DotPropToyRules.new()

## The field's toys (dot-props' [DotPropToyBox]): a beach ball on every platform, which rides a
## leaning deck, rolls off it at the edge, and is knocked flying by what the cannon throws.
## Placed from the layout on both ends, in deck order (see [method build_toys]). Null between
## fields.
var toys: DotPropToyBox = null

## The field's toys are about to go, on both ends: what the bridge releases their entities on.
signal toys_clearing()

## dot-player-controller's `mp_forceview` (may a player switch to third person) and
## `mp_solidplayers` (do players and stand-ins block each other). Bound by the module
## (REPLICATED) and followed by a client through its link: the client places its camera
## under the first and predicts its own player under the second.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()


func _init() -> void:
	# This game's pick: players pass through each other (see `_build_physics`). An owner who
	# wants bodies sets `mp_solidplayers 1`.
	body_rules.solid = false

## The weapon definitions by id, for the death reaction a weapon asks for. Built on first use.
var _weapon_defs: Dictionary = {}
var effects: DotFxManager = null

## Where somebody who is out looks. See [ScSpectate].
var spectate: ScSpectate = null
## Who a spectator may watch and whether they may fly a free camera: dot-spectate's
## `mp_forcecamera`, `mp_freeroam` and `mp_freeroam_speed`. One object for the life of the
## game, shared with [ScSpectate]'s manager, so a cvar change reaches the rules in use. Bound
## by the module (REPLICATED) and followed by a client, which is the end that flies the camera.
var spectate_rules: DotSpectatorRules = DotSpectatorRules.new()

## The numbers a player keeps and what they earn. Null on a client and when
## [member ScConfig.keep_progress] is off. See [ScProgress].
var progress: ScProgress = null

## player id -> ScPlayer.
var players: Dictionary = {}

## player id -> team id, for sides that outlive a round.
var sides: Dictionary = {}

var round_number: int = 0

## Simulated seconds since the round began. Never a wall clock.
var round_elapsed: float = 0.0

var phase: int = Phase.IDLE

## The layout the next round plays, set by the players' vote ([code]game/sc_vote.gd[/code]) and
## used once. Empty lets the weighted draw choose.
var next_layout_id: StringName = &""

## `(id: StringName) -> bool`: whether maps.yml's active rotation plays this layout. Set by the
## module; unset, every layout rotates. The weighted draw and the map menu's marks read it, and
## an admin's change (`change_layout_now`) does not: a layout outside the rotation stays installed.
var layout_in_rotation_fn: Callable = Callable()

## Which arrangement of platforms this round is being played on.
var layout: ScLayouts.Layout = null

## Everything in force right now, folded into one set of multipliers.
var active := ScSpecials.Active.new()

## Every world object this game has an id for.
##
## [b]One allocator, and the four schemes it replaces are in dot-entity's own notes.[/b]
## An id carries the kind it names, so a range check answers "is this a player" — which
## matters here more than in most games, because a falling prop is also registered with
## dot-combat and a kill handler that could not tell them apart would file a scoreboard row
## against a crate.
var entities := DotEntityTable.new()

## What the server last said about numbers a client cannot count for itself.
##
## [b]Negative means "count it yourself".[/b] A client runs no cannon and no platform
## model, so `standing_platforms()` there would count whatever its mirrors happen to say —
## and on the HUD that number is the one telling a player whether there is anywhere left to
## go. See `ScEvents.Kind.CLOCK`.
var remote_standing: int = -1
var remote_playable: bool = false
var remote_alive: int = -1

var _tick: int = 0
var _layout_seed: int = 0

## Instance id -> the velocity that prop had at the end of the previous tick.
var _prop_velocity: Dictionary = {}

## Instance ids of the choppers this round put out.
var _copter_ids: Array[int] = []

## Instance id -> seconds since that chopper last dropped something.
var _copter_drop: Dictionary = {}

## Ticks a mid-round special last fired on, for [DotRandomSchedule].
var _last_special_tick: int = -100000

## id -> seconds left. A start-of-round special is not in here; it lasts the round.
var _special_until: Dictionary = {}

## The special this whole round is being played under, or an empty name.
var _round_special: StringName = &""

## Seconds since the last quake shake.
var _since_quake: float = 0.0

## Which way the wind is blowing this round, as a unit vector on the XZ plane.
var _wind_heading := Vector3.ZERO


func _ready() -> void:
	if config == null:
		config = ScConfig.new()

	var valid := config.validate()

	if not valid.ok:
		# FATAL is reserved in this family for "the process cannot continue", and a
		# configuration that contradicts itself is not that: the right answer is to say so
		# loudly and refuse to run a round, not to take the server down.
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_layout_seed = config.seed_value

	_build_physics()
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)
	_apply_gravity()
	_build_random()
	_build_arena()
	_build_platforms()
	_build_props()
	_build_vehicles()
	_build_cannon()
	_build_combat()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()

	# [b]Laid out now, not when a round begins.[/b] dot-match runs a warmup before the first
	# round, so a world that only furnished itself on `round_started` would sit through the
	# whole warmup as a floor, a tube and nothing else — which is what somebody joining an
	# empty server sees, and is indistinguishable from the map having failed to load. It is
	# also what a suite gets when it builds a world and asserts about it without starting a
	# round, which is how this was found.
	_lay_out_round()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


func _exit_tree() -> void:
	# By instance, never by name. Unregistering the NAME from a world that lost the race to
	# register it takes the other world's entry out with it, and the symptom is a module
	# that cannot find a game sitting in the tree.
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## The player's motor mask under `mp_solidplayers`, and the standing hull the others stop at
## (a player's body has no shape of its own). Through `apply_to`: `set_collision_mask`, which
## a style does not undo, and the players' layer as one a player may walk out of. With the rule
## on, a stand-in stops at your shoulder instead of walking through your face (the first
## play test).
func _apply_body_mask(player: ScPlayer) -> void:
	if physics == null or player == null or player.controller == null:
		return
	body_rules.apply_to(player.controller, physics.collision_mask(&"player"), physics.layer_mask(&"player"))
	var tunables := player.controller.tunables
	body_rules.apply_hull(player, tunables.stand_height, tunables.radius)


## `mp_solidplayers` changed: every player's mask and hull now.
func _on_body_rules_changed() -> void:
	for id in players:
		_apply_body_mask(players[id] as ScPlayer)


## The named collision layers everything in this world is put on.
##
## [b]Built rather than taken from a preset, and applied rather than merely assigned.[/b]
## Five games in this family set a layout and put it on no bodies at all — everything
## stayed on layer one masking layer one — so two props dropped in the same place passed
## through each other. The four names here are the four kinds of thing in this map, and
## every `add_child` in this file goes through an `apply_to` whose result is checked.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"smash_copter", [
		&"world", &"player", &"prop", &"vehicle", &"pillar", &"toy", &"footprint",
	])

	for layer in physics.layers:
		match layer.id:
			&"player":
				# Not other players. Two capsules that push each other on a platform that
				# leans toward the heavier side is a game decided by who walked into whom,
				# and the shove would be a load the model never saw. So `mp_solidplayers` is 0
				# by default here (see `body_rules`); the camera fade keeps a player who walks
				# through you out of the lens.
				#
				# [b]And not a pillar.[/b] See `pillar` below.
				layer.collides_with = [&"world", &"prop", &"vehicle"]
			&"prop":
				layer.collides_with = [&"world", &"player", &"prop", &"vehicle", &"pillar"]
			&"vehicle":
				layer.collides_with = [&"world", &"player", &"prop", &"pillar"]
			&"pillar":
				# [b]Solid to what is thrown and flown, and never to a person.[/b] A pillar's
				# top is 2.7 m across and 0.57 m under its deck, and the only way a person
				# ever reaches it is the deck going: until 2026-09-25 everybody standing
				# within about a metre and a half of a platform's middle when it came off its
				# pillar dropped half a metre onto the top and stood there for the rest of the
				# round, alive, out of the cannon's reach (it aims at STANDING platforms) —
				# and was handed a weapon at the showdown. So the middle of every platform was
				# collapse-proof, and "stand in the middle" beat the whole first half of the
				# game. A collapse takes the floor away with whoever is on it; the bare pillar
				# stays, as the marker ScConfig.pillar_falls_with_platform keeps it for, and a
				# prop or a chopper still strikes it.
				layer.collides_with = [&"prop", &"vehicle"]
			# A beach ball on a platform (dot-props'): the decks, what the cannon throws, a
			# chopper, the pillars and the other balls; never a person, who walks through it
			# and pushes it (`_advance_toys`). It rides a leaning deck and rolls off it.
			&"toy":
				layer.collides_with = [&"world", &"prop", &"vehicle", &"pillar", &"toy"]
			# A toy's footprint, for a walkable mesh's bake only: nothing collides with it.
			&"footprint":
				layer.collides_with = []
			_:
				layer.collides_with = [&"player", &"prop", &"vehicle", &"pillar"]

	var built := physics.build()

	if not built.ok:
		DotLog.error(CHANNEL, "the collision layout would not build", {
			"why": built.error.message,
		})
		physics = null


## Puts this world's physics space on the gravity the round is being played at.
##
## [b]On the SPACE, not on `ProjectSettings`.[/b] Two worlds in one process is the normal
## case here — a server and a client in one editor session, and every section of the suite
## — and a global would be one of them deciding for the other. It is also what makes the
## low-gravity special one line: the same call with a different number.
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		DotLog.warn(CHANNEL, "no world to set gravity on", {})
		return

	PhysicsServer3D.area_set_param(
		world.space,
		PhysicsServer3D.AREA_PARAM_GRAVITY,
		config.gravity * maxf(active.gravity_scale, 0.05)
	)


func _build_random() -> void:
	random = DotRandomManager.new()
	random.name = "Random"
	# [b]Off, and the addon's own comment says why.[/b] A registry name is global to the
	# process, so the last manager to register wins — and two worlds in one process is not
	# exotic here: it is a server and a client in one editor session, and it is what every
	# section of the suite does. With it on, two worlds built from the same seed laid out
	# different maps, which is the one thing a seed exists to prevent.
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_layout_seed)


func _build_arena() -> void:
	arena = ScArena.new()
	arena.name = "Arena"
	arena.config = config
	arena.physics = physics
	add_child(arena)
	arena.build()


func _build_platforms() -> void:
	platforms = ScPlatforms.new()
	platforms.name = "Platforms"
	platforms.config = config
	platforms.authoritative = authoritative
	platforms.gravity = config.gravity
	add_child(platforms)

	platforms.collapsed.connect(_on_platform_collapsed)
	platforms.struck.connect(_on_platform_struck)


func _build_props() -> void:
	props = DotPropSpawner.new()
	props.name = "Props"
	props.catalogue = ScContent.props(config)
	props.limits = DotPropLimits.new()
	# The map's own furniture is put out by the world rather than requested by a player, so
	# the per-player budget and the cooldown are the wrong shape: the world cap is what is
	# being defended and it has to be above what a round throws, or the last few props
	# silently never appear.
	props.limits.spawn_interval = 0.0
	props.limits.per_player_budget = config.prop_budget + 40
	props.limits.world_budget = config.prop_budget + 40
	props.limits.clean_up_on_leave = false
	props.authoritative = authoritative
	add_child(props)

	prop_damage = DotPropDamage.new()
	prop_damage.name = "PropDamage"
	prop_damage.authoritative = authoritative
	props.add_child(prop_damage)
	prop_damage.exploded.connect(_on_prop_exploded)

	props.spawned.connect(_on_prop_spawned)
	props.removed.connect(_on_prop_removed)


func _build_vehicles() -> void:
	vehicles = DotVehicleSpawner.new()
	vehicles.name = "Vehicles"
	vehicles.catalogue = ScContent.vehicles(config)
	vehicles.authoritative = authoritative
	# Every chopper is placed in the same instant at the top of a round, and at the shipped
	# one-second interval only the first would appear — silently, because a refused spawn is
	# a refusal rather than an error. game-buses-from-hell found the same thing with buses.
	vehicles.spawn_interval = 0.0
	vehicles.per_player_budget = 12
	vehicles.world_budget = 12
	add_child(vehicles)

	# [b]The SPAWNER's ride, not a second one.[/b] `DotVehicleSpawner` builds one in its own
	# `_init` and uses it for three things: evacuating a vehicle that is destroyed with
	# people in it, answering `vehicle_of_rider`, and reporting how many riders there are. A
	# game that constructed its own beside it leaves those three reading an index that is
	# always empty.
	ride = vehicles.ride
	ride.carry_rider_nodes = false
	ride.on_seated = func(rider_id: StringName, _v: DotVehicleInstance, _s: DotVehicleSeat) -> void:
		_set_riding(rider_id, true)
	ride.on_unseated = func(
		rider_id: StringName, _v: DotVehicleInstance, _s: DotVehicleSeat, at: Vector3
	) -> void:
		_set_riding(rider_id, false, at)


func _build_cannon() -> void:
	cannon = ScCannon.new()
	cannon.name = "Cannon"
	cannon.config = config
	cannon.props = props
	cannon.platforms = platforms
	cannon.arena = arena
	add_child(cannon)


func _build_combat() -> void:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var rules := DotDamageRules.new()
	rules.friendly_fire = false
	rules.self_damage = true
	rules.hit_groups = true
	combat.rules = rules

	# [b]Lag compensation is OFF here and turned on by the bridge, in the same breath as the
	# callables that make it real.[/b] dot-combat defaults it on, checks for a rewind
	# function as it comes up, and says "lag compensation is enabled but no rewind function
	# is wired; shots resolve against the present" when it finds none — which is exactly true
	# of a world with no netcode, and exactly false of this one thirty lines later, when
	# [ScNetBridge] hands over dot-net's history. Leaving the default meant a delivered server
	# logged that line at every boot about a server where lag compensation works.
	#
	# It is also the honest answer for the world a client builds when it is playing alone:
	# there is no history to rewind, so there is no compensation, and the log should say so.
	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings

	# [b]A trace, or every shot in the showdown goes through the arena.[/b] dot-combat
	# resolves hitboxes analytically and asks a [DotTrace] where the WORLD is — and left
	# unset it quietly reports that nothing was in the way, so two players on opposite sides
	# of a catwalk shoot each other through it.
	#
	# [b]Before `setup()`, not after.[/b] The manager checks for one as it comes up and warns
	# when it finds none, so assigning it on the next line leaves a server log saying "no
	# trace backend; every shot will pass through world geometry" about a server where every
	# shot does not. A warning that is answered a line later is a warning an operator learns
	# to skim.
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world")

	combat.trace = trace

	# [b]Which side an entity is on, or friendly fire is ON in a game whose rules say it is
	# off.[/b] [DotDamageResolver._same_team] takes a `team_of` [Callable] and returns false
	# when it has none — which is the right default for a free-for-all and is silently wrong
	# for every team game that forgets it. Nothing reports the gap: the rule is evaluated,
	# the answer is "not team mates", and the shot lands. What a player sees is a team mate
	# they can kill in a game that says friendly fire is off, and there is no number anywhere
	# that is wrong.
	#
	# By entity id rather than by key, because that is what a damage carries; dot-entity's
	# reverse index is what makes it one line.
	combat.resolver = DotDamageResolver.with_rules(rules)
	combat.resolver.hit_groups = DotHitGroup.defaults()
	combat.resolver.team_of = func(entity_id: int) -> int:
		return team_of(entities.key_for_id(entity_id))

	# dot-game's "still loading": the one place every hurt passes (a shot, a blast, a crush, the
	# floor), and a round counts the living from health, so refusing here keeps a covered seat
	# alive in the count too. An admin's slay or slap is the operator's word and passes.
	combat.resolver.adjust = func(damage: DotDamage) -> void:
		if damage.context.get("admin", false):
			return

		if not can_be_harmed(entities.key_for_id(damage.victim)):
			damage.refuse("still loading")

	# [b]`add_child` IS the setup.[/b] [DotCombatManager._ready] calls `setup()` itself, so the
	# explicit call this used to make ran the whole of it a second time — and the tell was in
	# the delivered server's log, where every message `setup()` emits appeared twice in a row.
	# `setup()` is documented safe to call twice and it is; what it is not is free, and a
	# doubled boot line is how a reader finds out there are two of something.
	add_child(combat)


## The effects layer, which in this game is a shake and a flash and nothing else.
##
## [b]It ships no scenes, and that is a supported state rather than a gap.[/b] dot-fx's own
## invariant is that an effect is safe to drop, so a catalogue of two entries that need no
## art is the honest amount of presentation this game has: the screen shakes when the floor
## you are standing on is hit, and flashes when the round turns strange. Both of those are
## information, which is the only kind of effect worth replicating.
func _build_effects() -> void:
	if authoritative:
		# A server draws nothing. Building one would be a frame budget and a viewer
		# position on a process with no viewer.
		return

	var catalogue := DotFxCatalogue.new()

	var knock := DotFxDef.new()
	knock.id = &"impact"
	knock.kind = DotFxDef.Kind.SHAKE
	knock.shake_trauma = 0.34
	knock.max_distance = 70.0
	catalogue.add(knock)

	var fall := DotFxDef.new()
	fall.id = &"collapse"
	fall.kind = DotFxDef.Kind.SHAKE
	fall.shake_trauma = 0.62
	fall.max_distance = 90.0
	catalogue.add(fall)

	var strange := DotFxDef.new()
	strange.id = &"special"
	strange.kind = DotFxDef.Kind.SCREEN
	strange.flash_peak = 0.28
	strange.flash_colour = Color(0.95, 0.80, 0.35, 1.0)
	strange.flash_decay_ms = 420
	catalogue.add(strange)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = catalogue
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)

	DotLog.result(CHANNEL, "the effects layer", effects.setup())


## The intermission is the pause plus the killcam the clients play inside it, so the server never waits on one.
func apply_intermission(rules: DotMatchRules = null) -> void:
	var target: DotMatchRules = rules if rules != null else (match_node.rules if match_node != null else null)
	if target == null:
		return
	var pause := config.intermission_seconds
	target.intermission_sec = pause + (config.killcam_seconds if pause > 0.0 else 0.0)


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	match_node.config = match_config

	var rules := DotRulesElimination.make(config.round_seconds())
	apply_intermission(rules)
	rules.warmup_sec = config.warmup_seconds
	rules.countdown_sec = 0.0
	rules.rounds_to_win = 999
	rules.team_based = true
	# [b]Two, and it is the one number that keeps an empty server from spinning.[/b] An
	# elimination round ends the moment a side has nobody alive, and a side with nobody AT
	# ALL satisfies that on the first tick — so a server holding one team would start a
	# round, end it and start another several times a second for as long as nobody joined.
	# game-buses-from-hell shipped exactly that. `sides_are_playable` is the other half.
	rules.min_players = 2
	# [b]Nobody comes back, and it is the whole shape of the round.[/b] dot-match enqueues a
	# respawn on every kill it is told about, so a game that left this on would put a player
	# who fell off a platform back in the world three seconds later — which makes surviving
	# the first half worth nothing and the second half unwinnable. Death is final until the
	# next round, in both halves.
	rules.respawn_disabled = true
	# [b]The rule asks the game who is alive, and that is the seam dot-match is built
	# around.[/b] Being alive is a `DotHealth`, which lives in dot-combat, which dot-match
	# deliberately does not depend on. Left unset it falls back to a score and a clock, and
	# the tell is visible in the first round played: the round runs to the full clock
	# instead of ending on the last person standing.
	rules.alive_fn = _is_alive
	match_node.rules = rules

	# [b]Scoped to the match node itself, which finds nothing, and that is the point.[/b]
	# This game places its own players: a spawn point is a fixed place in the world and every
	# place in this world is on something that tips, collapses or is not there this round. So
	# there are no [DotSpawnPoint]s to find — but an unset `spawns_ref` makes dot-match walk
	# the WHOLE current scene looking for them, which in a process holding a server and a
	# client picks up the other world's, and after a round change picks up the outgoing map's
	# for the frame before it is freed. Both are in this family's own bug list.
	match_node.spawns_ref = DotNodeRef.of_path(^".")

	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = []

	for index in range(config.team_count):
		teams.append(DotTeam.make(
			index + 1, TEAM_NAMES[index], TEAM_COLOURS[index]
		))

	match_node.teams.teams = teams
	match_node.teams.force_balance = config.autobalance
	match_node.teams.allow_choice = config.allow_team_choice
	# [b]Off, because `sides` is what decides a team and dot-match is only told.[/b]
	# `max_difference` defaults to 1 and REFUSES a join that puts a side more than one
	# ahead, which `force_balance` does not reach. Offline, every stand-in is put on team 2
	# before the local player joins team 1, so dot-match took the first and left the other
	# two on no team at all — and the elimination rule counts survivors off dot-match's
	# teams, so a round ended when the one stand-in it knew about fell, with two still
	# standing. The same line was wrong in mg-buses-from-hell.
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


## Somewhere for a player who is out to look, and the server's rules about where.
##
## [b]Built on both ends and authoritative on one.[/b] A connected client's world runs a
## mirror that is told each decision in a `SPECTATE` event; see [ScSpectate]. A world whose
## spectating would not set up still plays — being out simply leaves the camera where the
## body is, which is how this game shipped — so a refusal is a WARN rather than the world
## failing to open.
func _build_spectate() -> void:
	spectate = ScSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	spectate.in_showdown_fn = func(p: int) -> bool:
		return p == Phase.HANDOVER or p == Phase.SHOWDOWN
	add_child(spectate)

	# The config's number is only the starting point: from here `mp_forcecamera` is the rule.
	spectate_rules.force_camera = clampi(config.spectate_camera, 0, 2)
	var ready_now := spectate.setup(authoritative, tick_rate, spectate_rules)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


## Statistics and achievements, where the world decides things.
##
## [b]Off on a client, because a client decides nothing[/b] — a connected client's world
## would count what its mirrors happen to say. A tracker that will not start is a WARN and
## a world that plays on without it, the same bargain as spectating.
func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = ScProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	progress.hurt_radius = IMPACT_HURT_RADIUS
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


## The two overview cameras, from the field this round was actually laid out as.
##
## [b]From the decks, not from the configuration.[/b] The chequerboard pulls its rows in and
## moves the whole field half a row over, so a camera aimed at where the configuration says
## the middle is looks at the hole the tube stands in with half the field out of frame.
func _refresh_overviews() -> void:
	if spectate == null or platforms == null or arena == null:
		return

	var centre := Vector3.ZERO
	var counted := 0

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck != null:
			centre += deck.centre
			counted += 1

	if counted > 0:
		centre /= float(counted)
	else:
		centre = Vector3(0.0, config.deck_height, 0.0)

	var reach := 0.0

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck != null:
			reach = maxf(reach, Vector2(
				deck.centre.x - centre.x, deck.centre.z - centre.z
			).length() + deck.half)

	# From the side away from the showdown, which is along -Z, so the corners are in the
	# back of the same shot.
	var eye := centre + Vector3(0.0, reach * 0.8 + 12.0, reach * 1.25 + 10.0)
	var field := Transform3D(Basis.IDENTITY, eye).looking_at(centre, Vector3.UP)

	var middle := arena.showdown_centre()
	var over := middle + Vector3(0.0, 26.0, config.corner_distance * 0.9 + 18.0)
	var showdown := Transform3D(Basis.IDENTITY, over).looking_at(middle, Vector3.UP)

	spectate.set_overviews(field, showdown)


# --- Players ----------------------------------------------------------------

## Puts somebody in the world. [param wanted_team] is a team id, or 0 to be placed.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_team: int = 0,
	samples_input: bool = false
) -> ScPlayer:
	if players.has(player_id):
		return players[player_id]

	var team := wanted_team if wanted_team != 0 else _side_for_new_player()

	var player := ScPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	# Before `add_child`, because `_ready` is what builds the controller and its tunables.
	player.config = config
	player.active = active
	player.mass_kg = config.player_mass
	player.platforms = platforms
	player.team = team
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {
				"why": applied.error.message,
			})

		# And the motor's own mask, which is a separate number and defaults to 1. A
		# controller left on the default sweeps against layer one only — which after a
		# layout has moved the world off bit zero is a player who falls through the map.
		_apply_body_mask(player)

	var opened := entities.open(
		DotEntity.KIND_PLAYER,
		player,
		&"",
		player_id,
		float(_tick) / float(maxi(tick_rate, 1))
	)

	if not opened.ok:
		# A refusal here means this player id is already an entity, which cannot happen —
		# `add_player` returns early on a duplicate. Logged rather than ignored, because
		# arming them anyway would register a second health record against one body and the
		# symptom of that is a player taking half damage.
		DotLog.error(CHANNEL, "could not open an entity for a player", {
			"id": String(player_id), "why": opened.error.message,
		})

	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.player_health
	health.health = config.player_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)
		_give_hitboxes(player)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = team

	if match_node != null:
		var seated := match_node.add_player(String(player_id), display_name, _tick, team)

		# ERROR, because a refusal here leaves the round rule counting a side short, and the
		# last time one was refused nothing said so.
		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player's side", {
				"id": String(player_id), "team": team, "why": seated.error.message,
			})

	# [b]Placed NOW, and not only at the top of a round.[/b] `_place_players` runs when a
	# round is laid out, so a player who joins in the middle of one was left wherever a
	# `CharacterBody3D` starts — the origin, which in this map is forty metres below the
	# platforms and inside the floor that kills you. They died on their first tick, every
	# time, and on a two-team server that also ended the round: a side with nobody alive is
	# an elimination, so the round ended, re-laid the field and freed every platform body
	# INSIDE the netcode's own identity loop. The loopback suite found it as a flood of
	# "previously freed instance", three layers from the cause.
	place_one(player)

	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id), "team": team})

	# Last, after the health and the side: the bridge answers this by building the
	# replicated entity and announcing the join, and an entity built over a half-made
	# player replicates the half.
	player_added.emit(player_id)
	return player


## Somewhere on a player that a shot can land.
##
## [b]Without this nobody in the showdown can be shot, and nothing says so.[/b]
## [DotCombatManager] traces against registered [DotHitboxSet]s; a player who has a
## `DotHealth` and no hitboxes is one every bullet passes through, and the only symptom is
## a firefight nobody wins. The dedicated run is what surfaced it, by warning about the
## trace backend beside it.
##
## Two boxes, because the pack has a sniper in it. A head worth more than a chest is the
## difference between a marksman rifle and a slower assault rifle, and dot-combat breaks a
## tie between two overlapping boxes by `precedence` — which is set here rather than left
## to child order, because floating-point equality on an entry distance is common enough
## that leaving it to luck gives a game where headshots land about half the time.
func _give_hitboxes(player: ScPlayer) -> void:
	var boxes := DotHitboxSet.new()
	boxes.name = "Hitboxes"
	boxes.owner_ref = DotNodeRef.of_path(^"..")
	player.add_child(boxes)

	var body := DotHitbox.new()
	body.name = "Chest"
	body.group = DotHitGroup.CHEST
	body.shape = DotHitbox.Shape.CAPSULE
	body.radius = 0.34
	body.height = 1.25
	body.position = Vector3(0.0, 0.78, 0.0)
	body.damage_scale = 1.0
	body.precedence = 0
	boxes.add_child(body)

	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.19
	head.position = Vector3(0.0, ScPlayer.EYE_HEIGHT + 0.06, 0.0)
	head.damage_scale = 2.2
	head.precedence = 10
	boxes.add_child(head)

	boxes.refresh()
	boxes.register_with(combat, player.entity_id)


## Puts one player somewhere they can stand, without disturbing anybody else.
##
## Their own side's platform if it is still up, and any standing platform otherwise. A
## joiner who arrives when the whole field has gone is put where the field WAS, which is a
## fall — and that is the honest answer: there is nowhere to stand, and the next round is a
## few seconds away.
func place_one(player: ScPlayer) -> void:
	if platforms == null:
		return

	var standing: Array[int] = []

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		# Never a tower: it is a small deck three steps up, the prize and not the start.
		if deck != null and deck.is_standing() and not deck.is_tower:
			standing.append(i)

	if standing.is_empty():
		player.place_at(
			Vector3(0.0, config.deck_height + 2.0, 0.0),
			0.0
		)
		return

	# The same arithmetic `_place_players` uses, so a joiner lands with their own side
	# rather than somewhere a second rule chose.
	var slot := maxi(player.team - 1, 0) * maxi(standing.size() / maxi(config.team_count, 1), 1)
	var index: int = standing[clampi(slot, 0, standing.size() - 1)]
	var deck := platforms.deck_at(index)

	# Off centre by a little and away from the middle, so two people joining in the same
	# second are not put inside each other — which the solver resolves by flinging one of
	# them off the platform.
	var angle := float(players.size()) * 1.7
	var reach := minf(deck.half * 0.5, 2.6)
	var at := deck.centre + Vector3(cos(angle) * reach, 1.2, sin(angle) * reach)
	var inward := deck.centre - at

	player.place_at(at, rad_to_deg(atan2(-inward.x, -inward.z)))

	if spectate != null:
		spectate.on_spawned(player.player_id)


## Which side somebody new goes on: the smallest one, ties to the lower id.
##
## [b]Explicitly, rather than left to a dictionary's order.[/b] A server and a client that
## disagree about somebody's side disagree about friendly fire, which is a player who
## cannot damage the enemy and can damage their own.
func _side_for_new_player() -> int:
	var counts: Array[int] = []
	counts.resize(config.team_count)
	counts.fill(0)

	for id: StringName in sides:
		var team := int(sides[id])

		if team >= 1 and team <= config.team_count:
			counts[team - 1] += 1

	var smallest := 0

	for index in range(config.team_count):
		if counts[index] < counts[smallest]:
			smallest = index

	return smallest + 1


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: ScPlayer = players[player_id]

	if ride != null and ride.is_riding(player_id):
		var aboard := vehicles.get_vehicle(ride.vehicle_id_of(player_id))

		if aboard != null:
			var _left := ride.exit(aboard, player_id, true)

	# Before the node goes. dot-combat keyed a `DotHealth` on this entity and nothing would
	# otherwise tell it to let go — so every player who had ever joined would leave a health
	# record behind, pointing at a node freed with them. What makes that invisible is that a
	# stale entity is never asked about, so the leak has no symptom at all until the process
	# runs out of memory.
	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	player.queue_free()

	# After the roster has dropped them: dot-spectate picks a watcher's replacement target
	# from the roster, and one still holding the leaver picks the leaver.
	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)


## Flips a player between walking and flying. Called by the ride, never directly.
func _set_riding(player_id: StringName, value: bool, at: Vector3 = Vector3.ZERO) -> void:
	var player: ScPlayer = players.get(player_id)

	if player == null:
		return

	player.set_riding(value)

	if not value and at != Vector3.ZERO:
		player.global_position = at
		player.controller.state.position = at


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


func players_on(team: int) -> Array[ScPlayer]:
	var out: Array[ScPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == team:
			out.append(players[id])

	return out


func _is_alive(key: String) -> bool:
	var player: ScPlayer = players.get(StringName(key))
	return player != null and player.is_alive()


## Whether [param player_id] may be damaged or eliminated now: false while their client is behind
## its loading cover. True for anybody the gate does not know (bots, offline).
func can_be_harmed(player_id: StringName) -> bool:
	return not harm_gate.is_valid() or bool(harm_gate.call(player_id))


## How many people are still up, across every side.
func alive_count() -> int:
	if not authoritative and remote_alive >= 0:
		return remote_alive

	var total := 0

	for id: StringName in players:
		if (players[id] as ScPlayer).is_alive():
			total += 1

	return total


## How many sides still have somebody up.
func teams_alive() -> int:
	var seen: Dictionary = {}

	for id: StringName in players:
		if (players[id] as ScPlayer).is_alive():
			seen[int(sides.get(id, 0))] = true

	return seen.size()


## Whether there is somebody on at least two sides.
##
## [b]A round with one side in it is an infinite loop with a scoreboard.[/b] The
## elimination rule ends a round the moment a side has nobody alive, and a side with nobody
## at all satisfies that on the first tick — so the round starts, ends, starts and ends
## again, several times a second, with every decision correct.
func sides_are_playable() -> bool:
	if not authoritative:
		# A client knows the sides from JOIN and TEAM but not whether the server has decided
		# a round can run — and that is the whole of the HUD's "waiting for players" line,
		# which is the only thing telling somebody on an empty server that nothing is broken.
		return remote_playable

	var seen: Dictionary = {}

	for id: StringName in sides:
		seen[int(sides[id])] = true

	return seen.size() >= 2


# --- The round --------------------------------------------------------------

func start() -> void:
	if not authoritative:
		return

	# [b]Laid out here and not only on `round_started`.[/b] dot-match runs a warmup before
	# the first round, so a world that only furnished itself when a round began would sit
	# through the whole warmup as a bare floor with a tube on it — which is what somebody
	# joining an empty server sees, and is indistinguishable from the map having failed to
	# load.
	_lay_out_round()
	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	round_elapsed = 0.0

	if config.vary_layout:
		# Derived from the configured seed and the round number rather than from a clock,
		# so a server and a replay of it play the same round. `hash` would do; this is one
		# multiply and is stable across engine versions, which `hash` on a built-in is not
		# promised to be.
		_layout_seed = config.seed_value + number * 7919
		random.reseed(_layout_seed)

	_lay_out_round()
	_roll_round_special()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.SURVIVAL)

	round_began.emit(number, layout.id if layout != null else &"")
	DotLog.info(CHANNEL, "round began", {
		"number": number,
		"layout": String(layout.id) if layout != null else "?",
		"special": String(_round_special),
		"seed": _layout_seed,
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)
	_clear_specials()

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": winner})


## Every layout this server plays, as the map menu (M) lists them: `{id, name, detail,
## current}`, the blurb under the name. Solo the client's list, online the server's (the module
## hands it to dot-vote's map menu), so both say the same.
func layout_rows() -> Array:
	var out: Array = []
	for l in ScLayouts.allowed(config):
		var listed := not layout_in_rotation_fn.is_valid() or bool(layout_in_rotation_fn.call(l.id))
		out.append({"id": String(l.id), "name": l.display_name,
			"detail": l.blurb if listed else ("%s (not in rotation)" % l.blurb).strip_edges(),
			"current": layout != null and l.id == layout.id})
	return out


## The map menu's change: [param id] now, not after this round. The next layout is set and a
## fresh round begins on it (dot-match's `begin_round_now`: the round called off has no
## winner); with no match running the field is simply laid out again. Authority only.
func change_layout_now(id: StringName) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "Only the server changes the layout.")
	if not ScLayouts.allowed(config).any(func(l: ScLayouts.Layout) -> bool: return l.id == id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no layout called '%s' here." % id)
	next_layout_id = id
	if match_node == null or not match_node.begin_round_now(_tick):
		_lay_out_round()
	DotLog.info(CHANNEL, "layout changed from the map menu", {"layout": String(id)})
	return DotResult.success(id)


## Everything that happens between one round and the next.
func _lay_out_round() -> void:
	world_clearing.emit()
	_clear_world()

	# A new round is a new aim for every stand-in, seeded with the round, so the next fight
	# between stand-ins is a different one (see [method _bot_aim_of]).
	_bot_aims.clear()
	_bot_triggers.clear()
	_bot_charges.clear()

	var stream := random.stream(&"layout")
	var voted: ScLayouts.Layout = null

	# What the players voted for, once, if this server still plays it (an operator can narrow
	# `layout_ids` between the vote and the round). The draw otherwise.
	if next_layout_id != &"":
		for allowed in ScLayouts.allowed(config):
			if allowed.id == next_layout_id:
				voted = allowed

	next_layout_id = &""
	layout = voted if voted != null else ScLayouts.pick(config, stream, layout_in_rotation_fn)

	platforms.gravity = config.gravity * maxf(active.gravity_scale, 0.05)
	platforms.build(layout, physics)
	_refresh_overviews()
	build_toys()

	cannon.stream = random.stream(&"cannon")
	cannon.begin_round()

	_wind_heading = _draw_wind_heading()

	_place_players()
	_place_choppers()

	# Last, after everything is standing. A bridge answers this by replicating every
	# platform and announcing the layout, and a field announced half way through being built
	# is a client drawing a floor the server has already replaced.
	world_rebuilt.emit()


func _clear_world() -> void:
	clear_toys()

	for prop in props.all_props():
		cannon.forget(prop.instance_id)
		var _gone := props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)

	_prop_velocity.clear()

	for instance_id in _copter_ids:
		var copter := vehicles.get_vehicle(instance_id)

		if copter == null:
			continue

		# [b]Riders out before the machine goes, and nothing else does this.[/b]
		# `DotVehicleRide` is a RefCounted holding its own index and it does not watch the
		# spawner — so a chopper removed underneath somebody leaves the ride still believing
		# they are aboard, and every later `enter` is refused with "You are already in a
		# vehicle". Permanently: there is no machine left to get out of.
		#
		# `occupants` is keyed by SEAT and valued by RIDER, which is the direction
		# `seat_of()` reads it in. Iterating the keys hands `exit` a seat name where it
		# wants a rider, and it answers truthfully about a rider called "pilot" who does not
		# exist.
		for rider_id: StringName in copter.occupants.values():
			var _out := ride.exit(copter, rider_id, true)

		var _removed := vehicles.remove(instance_id)

	_copter_ids.clear()
	_copter_drop.clear()


## Puts everybody on a platform, by side.
##
## [b]A side to a column block, so a team starts together.[/b] Six people scattered at
## random across a field of platforms is six separate games; a team that starts on one
## platform has an immediate problem, which is that all of them standing on it is exactly
## what tips it over.
func _place_players() -> void:
	var stream := random.stream(&"spawns")
	var standing: Array[int] = []

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		# Never a tower: it is a small deck three steps up, the prize and not the start.
		if deck != null and deck.is_standing() and not deck.is_tower:
			standing.append(i)

	if standing.is_empty():
		return

	var island := ScLayouts.islands(platforms.cells(), layout.jumps if layout != null else 0)
	var claimed: Dictionary = {}

	for team in range(1, config.team_count + 1):
		var roster := players_on(team)

		if roster.is_empty():
			continue

		# Teams are spread across the field rather than placed adjacently: which platform a
		# side gets is decided by its id so that two servers on one seed agree, and by the
		# number of sides so that six teams do not all start in the middle.
		var slot := (team - 1) * maxi(standing.size() / maxi(config.team_count, 1), 1)
		var index: int = standing[clampi(slot, 0, standing.size() - 1)]

		# [b]And not onto ground another side can already get to while there is ground no
		# side has been given.[/b] The field is in row order, so the spread above puts two
		# sides at the two ends of the first column — which on a field that is one piece is
		# the length of a bridge apart, and on Two Islands was both sides on one island and
		# nobody on the other. A layout that is all one island never takes this branch.
		if claimed.has(island[index]):
			for other: int in standing:
				if not claimed.has(island[other]):
					index = other
					break

		claimed[island[index]] = true
		var deck := platforms.deck_at(index)

		for seat in range(roster.size()):
			var player: ScPlayer = roster[seat]

			if player.health != null:
				player.health.health = config.player_health
				player.health.alive = true
				player.health.invulnerable = false

			_disarm(player)

			var angle := TAU * float(seat) / float(maxi(roster.size(), 1))
			var reach := minf(deck.half * 0.5, 2.6)
			var at := deck.centre + Vector3(cos(angle) * reach, 1.2, sin(angle) * reach)

			# Facing the middle of their own platform, which is the one direction that is
			# never immediately fatal.
			var inward := deck.centre - at
			player.place_at(at, rad_to_deg(atan2(-inward.x, -inward.z)))
			player.carried_metres = 0.0
			player.retune(active)

			# Everybody is back in the world, so nobody is watching any more.
			if spectate != null:
				spectate.on_spawned(player.player_id)

	# Anybody on no side at all — a spectator, a test's stand-in — goes somewhere valid
	# rather than at the origin, which in this map is inside the cannon.
	for id: StringName in players:
		var team := int(sides.get(id, 0))

		if team >= 1 and team <= config.team_count:
			continue

		var deck := platforms.deck_at(standing[stream.next_range_i(0, standing.size() - 1)])
		(players[id] as ScPlayer).place_at(deck.centre + Vector3.UP * 1.2, 0.0)


## Where chopper [param index] is parked on [param on_layout], whose field [member platforms]
## has to be built as: the middle of the platform the layout names for the first one
## ([member ScLayouts.Layout.chopper_cell], a bridge's middle when
## [member ScLayouts.Layout.chopper_on_bridge]), and the arena's ordinary pads for the rest.
func chopper_pad_on(on_layout: ScLayouts.Layout, index: int) -> Vector3:
	if on_layout != null and index == 0 and on_layout.chopper_cell.x >= 0:
		for i in range(platforms.count()):
			var deck := platforms.deck_at(i)

			if deck.is_bridge == on_layout.chopper_on_bridge \
					and deck.column == on_layout.chopper_cell.x \
					and deck.row == on_layout.chopper_cell.y:
				return Vector3(deck.centre.x, config.deck_height + config.chopper_pad_height,
					deck.centre.z)

	return arena.chopper_pad(index, config.chopper_count)


func _place_choppers() -> void:
	if not config.chopper_enabled or layout == null or not layout.with_chopper:
		return

	for index in range(config.chopper_count):
		var at := chopper_pad_on(layout, index)
		var copter := vehicles.spawn(ScContent.COPTER, at, ScContent.WORLD_OWNER)

		if copter == null:
			DotLog.warn(CHANNEL, "a chopper could not be spawned", {"index": index})
			continue

		_copter_ids.append(copter.instance_id)
		_copter_drop[copter.instance_id] = 0.0

		copter.meta[ScCopter.META_CEILING] = config.deck_height + config.chopper_ceiling
		copter.meta[ScCopter.META_CYCLIC] = Vector2.ZERO

		var chassis := copter.chassis as ScCopter

		if chassis != null:
			chassis.lift_ratio = config.chopper_lift
			chassis.gravity = config.gravity * maxf(active.gravity_scale, 0.05)

		var body := copter.body()

		if body != null:
			body.set_meta(ScPlayer.META_CARRIER, true)

		if body != null and physics != null:
			var applied := physics.apply_to(body, &"vehicle")

			if not applied.ok:
				DotLog.warn(CHANNEL, "a chopper could not be put on its layer", {
					"why": applied.error.message,
				})


# --- Phases -----------------------------------------------------------------

func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


## The clock, and the one handover it decides.
func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	round_elapsed += delta

	match phase:
		Phase.SURVIVAL:
			if round_elapsed >= config.survival_seconds:
				_begin_handover()
		Phase.HANDOVER:
			if round_elapsed >= config.showdown_starts_at():
				_begin_showdown()
		Phase.SHOWDOWN:
			pass


## The teleport, the weapons, and the few seconds nobody can fire.
##
## [b]Everything at once, and then a pause.[/b] A player is moved sixty metres, handed a
## weapon they have never seen and put beside two people who want to shoot them, all in one
## tick. The pause is what turns that from a death into a decision, and it is spent
## invulnerable rather than merely unarmed — because a chopper is still flying and a prop
## is still falling, and neither of those knows the round has changed.
func _begin_handover() -> void:
	_set_phase(Phase.HANDOVER)

	if config.clear_platforms_for_showdown:
		for i in range(platforms.count()):
			var _fell := platforms.collapse(i, ScPlatforms.WHY_ROUND)

	for team in range(1, config.team_count + 1):
		var roster: Array[ScPlayer] = []

		for player in players_on(team):
			if player.is_alive():
				roster.append(player)

		for seat in range(roster.size()):
			var player: ScPlayer = roster[seat]

			if player.riding:
				var aboard := vehicles.get_vehicle(ride.vehicle_id_of(player.player_id))

				if aboard != null:
					var _out := ride.exit(aboard, player.player_id, true)

			player.place_at(
				arena.showdown_spawn(team - 1, config.team_count, seat, roster.size()),
				arena.showdown_yaw(team - 1, config.team_count)
			)

			if player.health != null:
				player.health.invulnerable = true

			_arm(player, team, seat)

	if progress != null:
		progress.on_handover()

	DotLog.info(CHANNEL, "the survivors are in the corners", {
		"alive": alive_count(), "teams": teams_alive(),
	})


func _begin_showdown() -> void:
	_set_phase(Phase.SHOWDOWN)

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.health != null:
			player.health.invulnerable = false


# --- Weapons ----------------------------------------------------------------

## Hands a survivor what they will finish the round with.
##
## [b]Drawn, not chosen, and the draw is seeded.[/b] Nobody earns a weapon here: the whole
## point of the handover is that the first half was decided by footing and the second half
## begins with everybody equally surprised. A seeded draw is what lets two servers on one
## seed deal the same hands, and what lets the suite assert that a survivor is armed at all.
func _arm(player: ScPlayer, team: int, seat: int) -> void:
	if player.weapons != null:
		return

	var rig := ZeeWeaponRig.new()
	rig.name = "Weapons"
	# SERVER on a server, and the role only decides what is DRAWN. A rig that thought it
	# was local on a headless process would try to build a view model out of art the server
	# does not have.
	rig.role = ZeeWeaponRig.Role.SERVER
	rig.authority = authoritative
	rig.tick_rate = tick_rate
	rig.player_ref = DotNodeRef.of_path(player.get_path())
	player.add_child(rig)

	var ready_now := rig.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "a weapon rig would not set up", {
			"player": String(player.player_id), "why": ready_now.error.message,
		})
		player.remove_child(rig)
		rig.queue_free()
		return

	player.weapons = rig

	# [b]One stream per team when the draws are shared, one per player when they are
	# not.[/b] `stream_for` mixes a subject into a named stream, which is exactly the
	# question being asked: two players on one side either get the same hand or they do not,
	# and the answer has to be the same on every machine.
	var subject := team if config.weapons_match_within_team else team * 64 + seat
	var draw := random.stream_for(&"weapons", subject)
	var pool := _weapon_pool()

	if pool.is_empty():
		return

	var given: Array[StringName] = []

	for _i in range(config.weapons_granted):
		var id: StringName = pool[draw.next_range_i(0, pool.size() - 1)]

		if given.has(id):
			continue

		if rig.give(id).ok:
			given.append(id)

	if not given.is_empty():
		var first := rig.arsenal.catalogue.get_def(given[0])

		if first != null:
			var _selected := rig.arsenal.select(first.slot, _tick)

		player_armed.emit(player.player_id, given[0])

	DotLog.debug(CHANNEL, "a survivor was armed", {
		"player": String(player.player_id),
		"weapons": ", ".join(Array(given).map(func(v: Variant) -> String: return String(v))),
	})


func _disarm(player: ScPlayer) -> void:
	if player.weapons == null:
		return

	player.remove_child(player.weapons)
	player.weapons.queue_free()
	player.weapons = null


## Which weapons this server deals.
##
## [b]A default list rather than the whole pack, and the omissions are the design.[/b]
## Twenty-seven weapons dealt at random includes the fists and the derringer, and a
## survivor who earned their place by two minutes of not falling over should not lose it to
## a coin toss about ammunition. What is here is the set where every entry can win a fight.
func _weapon_pool() -> Array[StringName]:
	var out: Array[StringName] = []

	if not config.weapon_pool.is_empty():
		for id in config.weapon_pool:
			out.append(StringName(id))

		return out

	out.append_array([
		ZeeWeaponIds.REVOLVER,
		ZeeWeaponIds.MACHINE_PISTOL,
		ZeeWeaponIds.SMG,
		ZeeWeaponIds.CARBINE,
		ZeeWeaponIds.RIFLE,
		ZeeWeaponIds.BULLPUP,
		ZeeWeaponIds.BATTLE_RIFLE,
		ZeeWeaponIds.BURST_RIFLE,
		ZeeWeaponIds.SHOTGUN,
		ZeeWeaponIds.DRUM_SHOTGUN,
		ZeeWeaponIds.MARKSMAN,
		ZeeWeaponIds.SNIPER,
		ZeeWeaponIds.MINIGUN,
		ZeeWeaponIds.LAUNCHER,
		ZeeWeaponIds.BEAMER,
		ZeeWeaponIds.CHARGE_RIFLE,
		ZeeWeaponIds.HATCHET,
		ZeeWeaponIds.MALLET,
	])

	return out


# --- The tick ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One simulated tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1

	if hold_clock.is_valid() and hold_clock.call():
		_step_bodies_only(delta)
		return

	_step(delta)


## A tick under a cover: the bodies move, nothing else happens. A dead body is left alone.
func _step_bodies_only(delta: float) -> void:
	for id: StringName in players:
		var body := players[id] as ScPlayer

		if body.is_alive():
			body.simulate(_tick, delta)


## One simulated tick, numbered by the netcode. What the bridge uses.
##
## [b]The tick number comes from outside and the step does not.[/b] A snapshot is stamped
## with the netcode's tick and a client reconciles against that number, so a world counting
## its own would be replying about a different tick than the one it was asked about. The
## STEP stays a fixed `1 / tick_rate` either way: a simulation stepped by a frame's delta
## runs differently on a server having a bad second, and this family has paid for that
## twice.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func _step(delta: float) -> void:
	_advance_phase(delta)
	_advance_specials(delta)

	for id: StringName in players:
		(players[id] as ScPlayer).simulate(_tick, delta)

	if authoritative:
		_advance_toys(delta)

	_drive_bots(delta)
	_fly_choppers(delta)
	_apply_wind(delta)
	_load_platforms()

	platforms.step(delta)

	_watch_props(delta)
	_watch_falls()
	_advance_weapons()

	if phase == Phase.SURVIVAL:
		cannon.advance(delta, round_elapsed, active)
	else:
		# Aged even when it is not firing, so the map clears itself during the showdown
		# rather than holding whatever was in the air when the clock ran out.
		cannon.advance(delta, round_elapsed, ScSpecials.Active.new())

	if combat != null:
		combat.tick(_tick, delta)

	# After every death this tick has produced, so a death camera that runs out on this tick
	# hands over to somebody who is actually still up.
	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable():
		return

	match_node.tick(_tick)


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## Adopts a tick rate, on a client being told what the server runs at.
##
## [b]Every player's controller as well as this world.[/b] `tick_rate` is a plain property
## on a player with a setter that forwards to the controller, so a world that changed only
## its own leaves every player integrating at the old rate — which is a client that walks at
## 60/128 of the speed the server moves it at and is corrected on every snapshot for doing
## so.
func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	for id: StringName in players:
		(players[id] as ScPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	return true


# --- Specials ---------------------------------------------------------------

func _roll_round_special() -> void:
	_special_until.clear()
	_round_special = &""
	_last_special_tick = _tick

	if not config.specials_enabled:
		_refold()
		return

	var stream := random.stream(&"specials")

	if stream.next_range_f(0.0, 100.0) >= config.special_round_chance:
		_refold()
		return

	var special := ScSpecials.pick(config, stream)

	if special == null:
		_refold()
		return

	_round_special = special.id
	_refold()

	special_changed.emit(special.id, true, special.blurb)
	DotLog.info(CHANNEL, "this round is a special", {"special": String(special.id)})


## Mid-round specials: when one starts, and when the running ones stop.
func _advance_specials(delta: float) -> void:
	var changed := false

	for id: StringName in _special_until.keys():
		var left := float(_special_until[id]) - delta

		if left > 0.0:
			_special_until[id] = left
			continue

		_special_until.erase(id)
		changed = true

		var special := ScSpecials.by_id(id)
		special_changed.emit(id, false, special.display_name if special != null else "")

	if _may_roll_mid_round():
		var stream := random.stream(&"specials")
		var special := ScSpecials.pick(config, stream)

		if special != null and not _special_until.has(special.id) and special.id != _round_special:
			_special_until[special.id] = config.special_seconds
			_last_special_tick = _tick
			changed = true
			special_changed.emit(special.id, true, special.blurb)
			DotLog.info(CHANNEL, "something changed mid-round", {
				"special": String(special.id),
			})

	if changed:
		_refold()

	_advance_quake(delta)


func _may_roll_mid_round() -> bool:
	if not config.specials_enabled or not config.specials_mid_round:
		return false

	if phase != Phase.SURVIVAL:
		return false

	# [b]A pure function of the tick, which is the whole reason dot-core has a schedule.[/b]
	# A server and a replay of it agree about when the gravity went off without anybody
	# sending a message about it; a roll per tick from a stream would give a different
	# answer on a machine that had drawn a different number of times beforehand.
	var plan := ScSpecials.schedule(config, tick_rate)
	return plan.fires_at(random.stream(&"special_clock"), _tick, _last_special_tick)


## Recomputes what is in force and puts it on everything that reads it.
##
## [b]One place, and everything downstream is told rather than asking.[/b] The alternative
## is every consumer folding the list itself, which is five copies of the same loop and
## five chances for one of them to miss a special that started this tick.
func _refold() -> void:
	active = ScSpecials.Active.new()

	if _round_special != &"":
		var round_one := ScSpecials.by_id(_round_special)

		if round_one != null:
			active.fold(round_one)

	for id: StringName in _special_until:
		var special := ScSpecials.by_id(id)

		if special != null:
			active.fold(special)

	_apply_gravity()

	platforms.stiffness_scale = layout.stiffness_scale * active.stiffness_scale if layout != null \
		else active.stiffness_scale
	platforms.grip = config.platform_grip * active.grip_scale
	platforms.gravity = config.gravity * maxf(active.gravity_scale, 0.05)

	for id: StringName in players:
		(players[id] as ScPlayer).retune(active)

	for instance_id in _copter_ids:
		var copter := vehicles.get_vehicle(instance_id)
		var chassis := copter.chassis as ScCopter if copter != null else null

		if chassis != null:
			chassis.gravity = config.gravity * maxf(active.gravity_scale, 0.05)


func _clear_specials() -> void:
	_special_until.clear()
	_round_special = &""
	_refold()


## Which way the wind blows this round. Drawn once, so it is a fact about the round.
func _draw_wind_heading() -> Vector3:
	var angle := random.stream(&"weather").next_range_f(0.0, TAU)
	return Vector3(cos(angle), 0.0, sin(angle))


## Pushes everything loose the way the wind is going.
##
## [b]Props and players, and not the platforms.[/b] A platform is bolted to a pillar; what
## the wind does to it is arrive as the things it is pushing. Applied as an acceleration
## rather than a force so a crate and a monolith drift at the same rate, which is what wind
## looks like and is not what a force would give.
func _apply_wind(delta: float) -> void:
	if active.wind <= 0.0:
		return

	var push := _wind_heading * active.wind

	for prop in props.all_props():
		var body := prop.body()

		if body != null and not body.freeze:
			body.apply_central_force(push * body.mass)

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.riding or not player.is_alive():
			continue

		# Only in the air. A person leaning into a gale is still walking; a person who has
		# just jumped between two platforms is a sail, and that is the moment the wind is
		# supposed to be frightening.
		if player.controller.state.mode == DotFpsState.Mode.AIR:
			player.controller.state.velocity += push * delta


func _advance_quake(delta: float) -> void:
	if active.quake <= 0.0:
		_since_quake = 0.0
		return

	_since_quake += delta

	if _since_quake < active.quake_interval:
		return

	_since_quake = 0.0
	platforms.shake_all(random.stream(&"quake"), active.quake)


# --- Loads and impacts ------------------------------------------------------

## Tells every platform what is standing on it this tick.
##
## [b]Gathered here rather than pushed by each thing, because the model has to see one
## consistent set.[/b] A platform that was told about a player on Tuesday and a crate on
## Wednesday would lean toward whichever arrived last; what tips it is the sum, and the sum
## has to be taken between one step and the next.
func _load_platforms() -> void:
	platforms.begin_loads()

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.riding or not player.is_alive():
			continue

		var index := player.standing_on

		if index < 0:
			continue

		platforms.add_load(
			index,
			player.controller.state.position,
			player.mass_kg,
			player.ground_speed()
		)

	for prop in props.all_props():
		var body := prop.body()

		if body == null or not prop.is_alive():
			continue

		var at := body.global_position
		var index := platforms.index_at(at.x, at.z)

		if index < 0 or not platforms.is_on(index, at, 1.8):
			continue

		# A prop is a dead weight: it contributes its mass and no motion gain. A crate
		# sliding across a leaning platform is already making the lean worse by moving its
		# own offset, which is the honest amount of feedback and needs no second term.
		platforms.add_load(index, at, prop.def.mass, 0.0)


## Watches everything in the air for the moment it stops being in the air.
##
## [b]A velocity drop rather than a contact signal, and it is the assertable one.[/b] An
## impulse is not readable in `linear_velocity` until the step that consumed it has run —
## dot-props has paid for that lesson four times — so what this looks for is the step where
## a body that was falling fast stops falling fast. It needs no contact monitoring, it is a
## pure function of two ticks of state, and a headless suite can drive it by hand.
func _watch_props(delta: float) -> void:
	var seen: Dictionary = {}

	for prop in props.all_props():
		var body := prop.body()

		if body == null or not prop.is_alive():
			continue

		var instance_id := prop.instance_id
		seen[instance_id] = true

		var was: Vector3 = _prop_velocity.get(instance_id, Vector3.ZERO)
		var now := body.linear_velocity
		_prop_velocity[instance_id] = now

		if was.y > -IMPACT_MIN_SPEED:
			continue

		# It lost most of its downward speed in one step, so something stopped it.
		if now.y < was.y * (1.0 - IMPACT_LOSS):
			continue

		_land(prop, body.global_position, -was.y, delta)

	for key: int in _prop_velocity.keys():
		if not seen.has(key):
			_prop_velocity.erase(key)


## Something arrived. What it hit, and what that cost.
func _land(prop: DotPropInstance, at: Vector3, speed: float, _delta: float) -> void:
	var impulse := prop.def.mass * speed

	var index := platforms.index_at(at.x, at.z)

	if index >= 0 and platforms.is_on(index, at, 2.2):
		var outcome := platforms.report_impact(index, prop.def.mass, speed, at)

		if outcome == ScPlatforms.Impact.NONE:
			return

	# And the prop's own health, which is dot-props' half: a barrel that lands hard goes
	# off, a crate splits, a boulder does not notice. `impact` is a SPEED test rather than
	# a damage one for exactly this reason — what breaks a crate is how fast the floor
	# arrived, not how many times it has been leant on.
	if prop_damage != null:
		var _broke := prop_damage.impact(prop.instance_id, speed, ScContent.WORLD_OWNER)

	_crush_nearby(at, impulse)


## Who was standing where that landed.
##
## [b]Hurt in proportion to the momentum, and lethal well before a monolith.[/b] A crate at
## terminal velocity is a bruise and the tier-four prop is not survivable, which is the same
## ordering the platforms are hurt in and is the whole reason the tiers are worth reading off
## the sky.
func _crush_nearby(at: Vector3, impulse: float) -> void:
	if combat == null or impulse <= 0.0:
		return

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.riding or not player.is_alive():
			continue

		var offset := player.controller.state.position + Vector3.UP * 0.9 - at

		if offset.length() > IMPACT_HURT_RADIUS:
			continue

		var falloff := 1.0 - clampf(offset.length() / IMPACT_HURT_RADIUS, 0.0, 1.0)
		var amount := impulse * IMPACT_HURT_PER_IMPULSE * falloff

		if amount < 1.0:
			continue

		var damage := DotDamage.make(0, player.entity_id, amount, null)
		damage.point = player.controller.state.position
		damage.direction = Vector3.DOWN
		# [b]Stamped, and a damage event with no tick is refused for ever.[/b] Spawn
		# protection compares against `invulnerable_until_tick`, and a tick of zero is
		# always before it — so every crush in the handover would be silently discarded and
		# the ones after it would not, with nothing to say why.
		damage.tick = _tick
		damage.context = {"why": DIED_CRUSHED}

		var _applied := combat.apply_damage(damage)

		# Knocked sideways as well as hurt, because a landing that leaves somebody standing
		# exactly where they were is the one thing here that would look broken from every
		# angle — and on a platform that is already leaning, being shoved is most of the
		# danger.
		var shove := Vector3(offset.x, 0.0, offset.z)

		if shove.length() > 0.01:
			player.controller.state.velocity += shove.normalized() * minf(
				impulse * 0.004 * falloff, 9.0
			)


## Everybody who has run out of map.
##
## [b]Checked here rather than by a trigger volume, and that is a decision about this
## map.[/b] The floor is the only thing in the world nobody survives, and a kill plane a
## player steps over between two ticks is the bug dot-timer's own notes describe: at speed
## a falling body crosses a sixteen-unit trigger without ever being inside it. A height
## comparison cannot be stepped over.
func _watch_falls() -> void:
	if combat == null:
		return

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if not player.is_alive() or not can_be_harmed(id):
			continue

		if player.riding:
			_watch_rider_fall(player)
			continue

		# Reaching the floor, not passing through it: see FLOOR_REACH.
		if player.controller.state.position.y > config.kill_height + FLOOR_REACH:
			continue

		_kill_by_fall(player, player.controller.state.position)


## A rider falls with the machine, and that was the one way to survive the floor.
##
## [b]A rider's own position is not where they are.[/b] The controller stops moving while it
## is carried, so the height check above would read wherever they climbed aboard — which is
## why riders were skipped outright. And skipping them made the floor survivable: a pilot
## who put the chopper down on it sat there out of the cannon's reach until the clock ran
## out, and one who flew it off the edge of the map fell for the rest of the round, alive,
## and was handed a weapon in the corners like anybody who had earned it. So a rider is
## measured by the MACHINE, and a machine within [constant COPTER_FLOOR_CLEARANCE] of the
## floor has reached it — its origin rests that far above the surface on its skids, so a
## check at the kill height alone would never fire for one parked there.
##
## Out of the seat first: a player who died seated would stay in the ride's table, and the
## next round's [method _clear_world] would be exiting somebody who is not there.
func _watch_rider_fall(player: ScPlayer) -> void:
	var aboard := vehicles.get_vehicle(ride.vehicle_id_of(player.player_id))
	var body := aboard.body() if aboard != null else null

	if body == null or body.global_position.y > config.kill_height + COPTER_FLOOR_CLEARANCE:
		return

	var at := body.global_position
	var _out := ride.exit(aboard, player.player_id, true)

	_kill_by_fall(player, at)


func _kill_by_fall(player: ScPlayer, at: Vector3) -> void:
	var damage := DotDamage.make(0, player.entity_id, player.health.max_health * 4.0, null)
	damage.point = at
	damage.direction = Vector3.DOWN
	damage.tick = _tick
	damage.context = {"why": DIED_FELL}

	var _applied := combat.apply_damage(damage)


# --- Weapons, once there are any --------------------------------------------

## One tick of everybody's weapons, and everything they produced.
##
## [b]The shots are resolved HERE rather than by the rig.[/b] zee-dot-weapons hands back an
## outcome and applies nothing, which is dot-weapon's rule one level out: a behaviour that
## reached into a `DotHealth` would be a client deciding who dies. What the game does with
## an outcome is its own business, and what this game does is hand it to dot-combat.
func _advance_weapons() -> void:
	if phase != Phase.SHOWDOWN or combat == null:
		return

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.weapons == null or not player.is_alive():
			continue

		var command := weapon_command_for(player)
		var outcome := player.weapons.simulate_tick(command, _tick)

		for shot in outcome.shots:
			shot.attacker = player.entity_id
			shot.tick = _tick
			_shoot_toys(shot)
			var resolved := combat.resolve_shot(shot)
			_note_hits(player, resolved)


# --- Toys ----------------------------------------------------------------------

## The field's toys from its decks: a beach ball a little off the middle of every platform (not a
## bridge), on both ends in deck order, which is how a client pairs each with the server's
## entity. Called after the platforms are built: by the round on the server, by LAYOUT on a
## client.
func build_toys() -> void:
	clear_toys()
	var placements: Array = []
	for index in range(platforms.count()):
		var deck := platforms.deck_at(index)
		if deck == null or deck.is_bridge:
			continue
		# Toward the outer corner the platform leans to under nobody, never the middle: the
		# ball is the first thing to roll when somebody walks out to the edge.
		var off := Vector3(deck.half * 0.45, 0.0, -deck.half * 0.45).rotated(Vector3.UP, float(index) * PI * 0.5)
		var at := deck.centre + off
		placements.append({"toy": "beach_ball", "at": [at.x, at.y, at.z]})
	toys = DotPropToyBox.new()
	toys.name = "Toys"
	toys.authoritative = authoritative
	toys.rules = toy_rules
	toys.gravity = config.gravity
	toys.kill_y = -20.0
	if physics != null:
		toys.loose_layer = physics.layer_mask(&"toy")
		toys.loose_mask = physics.collision_mask(&"toy")
		toys.solid_layer = physics.layer_mask(&"prop")
		toys.solid_mask = physics.collision_mask(&"prop")
		toys.footprint_layer = physics.layer_mask(&"footprint")
		toys.aim_mask = physics.layer_mask(&"world") | physics.layer_mask(&"toy")
	add_child(toys)
	var built := toys.build(placements)
	if not built.ok:
		DotLog.warn(CHANNEL, "the field's toys would not build", {"why": built.error.message})
	var _sounds := toys.sound.connect(func(id: StringName, at: Vector3, strength: float) -> void: toy_sound.emit(id, at, strength))


func clear_toys() -> void:
	if toys == null:
		return
	toys_clearing.emit()
	remove_child(toys)
	toys.queue_free()
	toys = null


## A toy made a sound, on whichever end draws it.
signal toy_sound(id: StringName, at: Vector3, strength: float)


## Everybody against the toys, after they moved: a walk into a ball sends it on. Server side.
func _advance_toys(delta: float) -> void:
	if toys == null or toys.count() == 0:
		return
	for id: StringName in players:
		var player: ScPlayer = players[id]
		if not player.is_alive():
			continue
		var state := player.controller.state
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
		var _pushed := toys.push_from(state.position, state.velocity, radius, height)
	toys.advance(delta)


## A shot against the toys: the first one on its ray is pushed and the shot goes on to the
## combat, whose trace never sees a toy, so a ball is never cover in the showdown. Server side.
func _shoot_toys(shot: DotShot) -> void:
	if not authoritative or toys == null or toys.count() == 0:
		return
	var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
	for raw: Variant in directions:
		var _pushed := toys.shot_along(shot.origin, raw as Vector3, maxf(shot.max_range, 1.0), shot.damage, physics.layer_mask(&"world"))


## Turns a player's movement command into a weapon command.
##
## [b]One command, and the buttons are the game's to assign.[/b] dot-player-controller
## reserves three bits for a game and this one spends all three: fire, the alt-fire bash,
## and reload. The slot a player wants rides in this game's own input message rather than in
## the movement command, which has no room for it.
func weapon_command_for(player: ScPlayer) -> DotWeaponCommand:
	var command := DotWeaponCommand.new()
	var pending := player.controller.current_command

	if pending == null:
		return command

	command.set_button(
		DotWeaponCommand.BUTTON_ATTACK, pending.is_pressed(DotFpsCommand.BUTTON_USER_0)
	)
	command.set_button(
		DotWeaponCommand.BUTTON_ALT, pending.is_pressed(DotFpsCommand.BUTTON_USER_1)
	)
	command.set_button(
		DotWeaponCommand.BUTTON_RELOAD, pending.is_pressed(DotFpsCommand.BUTTON_USER_2)
	)
	command.yaw = pending.yaw
	command.pitch = pending.pitch
	command.slot = player.wanted_slot

	return command


# --- Choppers ---------------------------------------------------------------

## Turns each pilot's keys into a chopper's controls, and drops what they asked to drop.
func _fly_choppers(delta: float) -> void:
	for id: StringName in players:
		var player: ScPlayer = players[id]

		if not player.riding:
			continue

		var instance_id := ride.vehicle_id_of(player.player_id)

		if instance_id == 0:
			continue

		var copter := vehicles.get_vehicle(instance_id)

		if copter == null or not copter.is_alive():
			continue

		# Only the pilot flies it. A passenger in the other seat is holding a rifle.
		if copter.seat_of(player.player_id) != &"pilot":
			continue

		var pending := player.controller.current_command
		var command := DotVehicleCommand.new()

		if pending != null:
			# The collective, which is the one control that is not where a player expects
			# it: jump climbs and crouch descends, so the two keys that already mean up and
			# down keep meaning up and down.
			var up := 1.0 if pending.is_pressed(DotFpsCommand.BUTTON_JUMP) else 0.0
			var down := 1.0 if pending.is_pressed(DotFpsCommand.BUTTON_CROUCH) else 0.0
			command.throttle = up - down
			command.steer = clampf(pending.move.x, -1.0, 1.0)
			command.brake = 1.0 if pending.is_pressed(DotFpsCommand.BUTTON_WALK) else 0.0
			command.aim_yaw = pending.yaw
			command.aim_pitch = pending.pitch

			copter.meta[ScCopter.META_CYCLIC] = Vector2(0.0, clampf(pending.move.y, -1.0, 1.0))

		copter.command = command

		var chassis := copter.chassis as DotVehicleChassis

		if chassis != null:
			chassis.drive(command, delta)

		_advance_drop(copter, player, pending, delta)


## The pilot's trigger, which drops a prop rather than firing anything.
##
## [b]The best thing in the map this game is built from.[/b] A chopper that can only be
## flown is a sightseeing tour; one that can put a crate on a platform somebody is standing
## on is a second cannon with a person aiming it — and, because the machine has to be over
## the target to do it, one the people underneath can see coming and run from.
func _advance_drop(
	copter: DotVehicleInstance, player: ScPlayer, pending: DotFpsCommand, delta: float
) -> void:
	if not config.chopper_may_drop or pending == null or cannon == null:
		return

	var since := float(_copter_drop.get(copter.instance_id, 0.0)) + delta
	_copter_drop[copter.instance_id] = since

	if since < config.chopper_drop_interval:
		return

	if not pending.is_pressed(DotFpsCommand.BUTTON_USER_0):
		return

	var body := copter.body()

	if body == null:
		return

	var bay := body.get_node_or_null(^"DropBay") as Node3D
	var from := bay.global_position if bay != null else body.global_position - Vector3.UP * 2.2

	# It leaves with the machine's own velocity, which is what makes aiming one a skill
	# rather than a button: a crate dropped from a chopper doing fifteen metres a second
	# lands a long way in front of where it was let go.
	var tier := clampi(config.chopper_drop_tier, 1, ScContent.TIERS)
	var dropped := cannon.drop(from, body.linear_velocity, tier)

	if dropped != null:
		_copter_drop[copter.instance_id] = 0.0
		DotLog.debug(CHANNEL, "a chopper dropped something", {
			"pilot": String(player.player_id),
		})


## Whoever is nearest a chopper and asking to get in, gets in.
##
## Public because the bridge answers a client's request with it and the suite calls it
## directly. The reach is generous on purpose: a machine parked on a pad that is itself on
## a platform that is leaning is not going to be where anybody expects it.
func try_board(player_id: StringName) -> DotResult:
	var player: ScPlayer = players.get(player_id)

	if player == null:
		return DotResult.fail(DotError.CODE_INVALID, "Nobody by that name is here.")

	if player.riding:
		var aboard := vehicles.get_vehicle(ride.vehicle_id_of(player_id))

		if aboard != null:
			return ride.exit(aboard, player_id, false)

		return DotResult.fail(DotError.CODE_STATE, "You are aboard something that has gone.")

	var nearest := vehicles.nearest_free(player.controller.state.position, 6.0)

	if nearest == null:
		return DotResult.fail(DotError.CODE_STATE, "There is nothing here to get into.")

	var seat := nearest.first_free_seat()

	if seat == null:
		return DotResult.fail(DotError.CODE_STATE, "It is full.")

	return ride.enter(nearest, player_id, player, seat.id)


# --- Bots -------------------------------------------------------------------

## What a stand-in does, which is the least that makes a round look like a round.
##
## [b]They play the actual game rather than walking a route.[/b] A bot here has one
## decision to make and it is the same one a person has: the platform is leaning, so move
## toward the high side, and if it is going over, get off it. In the showdown it turns on the
## nearest enemy and shoots, through dot-bot's [DotBotAim] (see [method _aim_bot]).
##
## [b]How it aims is the family's, how it balances is this game's.[/b] The view, the reaction,
## the aim error and the trigger are dot-bot's `bot_difficulty` and `bot_*` settings, the
## names every game uses; what is only true here (how much lean a stand-in notices, how far it
## walks to a fight) is `sc_bot_*` ([ScConfig]).

## What the stand-ins are called, solo and on a server; past the end dot-bot numbers them.
const BOT_NAMES := ["Wobble", "Teeter", "Lurch", "Tilt", "Keel", "Sway", "Pitch", "Yaw"]

## Each stand-in's eyes and trigger finger for this round, player id -> [DotBotAim]. Cleared
## when the next round is laid out, and the round is in the seed (see [method _bot_aim_of]).
var _bot_aims: Dictionary = {}

## Whether each stand-in's trigger was down last tick, and when it started a charge: see
## [method _bot_trigger].
var _bot_triggers: Dictionary = {}
var _bot_charges: Dictionary = {}


func _drive_bots(_delta: float) -> void:
	for id: StringName in players:
		var player: ScPlayer = players[id]

		if not player.is_bot or not player.is_alive() or player.riding:
			continue

		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch
		_bot_aim_of(player).view_from(command.yaw, command.pitch)

		# Where it wants to walk, in the world: turned into stick movement once the view is
		# decided, so turning at a person's speed never walks it the wrong way.
		var walk := Vector3.ZERO
		var deck := platforms.deck_at(player.standing_on)

		if deck != null:
			var at := player.controller.state.position
			var wanted := deck.centre

			# Uphill, which on a leaning platform is the opposite of the lean — and is also
			# the way back toward the pillar, so one target serves both reasons. A lean under
			# `sc_bot_lean_notice` degrees goes unnoticed, as it does by a person.
			if deck.tilt() > deg_to_rad(config.bot_lean_notice_degrees):
				wanted = deck.centre - Vector3(deck.lean.x, 0.0, deck.lean.y).normalized() \
					* deck.half * 0.4

			var toward := wanted - at
			toward.y = 0.0

			if toward.length() > 0.6:
				walk = toward

				# Walking rather than running when it is nearly there, which is the control
				# this whole game is about and the one thing a bot should be seen using.
				if toward.length() < 3.0 or deck.tilt() > 0.1:
					command.set_button(DotFpsCommand.BUTTON_WALK, true)

			if not deck.is_standing():
				command.set_button(DotFpsCommand.BUTTON_JUMP, true)

		var aimed := false

		if phase == Phase.SHOWDOWN and player.weapons != null:
			var advance := _aim_bot(player, command)
			aimed = advance != Vector3.INF

			if aimed and advance != Vector3.ZERO:
				walk = advance

		if not aimed and walk != Vector3.ZERO:
			var eye := player.eye_position()
			_bot_look(player, command, Vector3(eye.x + walk.x, eye.y, eye.z + walk.z))

		command.move = _bot_walk(command.yaw, walk)
		player.controller.apply_command(command)


## Turns a stand-in on the nearest enemy and fires when dot-bot says it may. Returns the way
## it walks toward the fight (flat, world space; ZERO to hold), or [constant Vector3.INF] when
## there is nobody to fight.
##
## [b]It sees through dot-bot's eyes[/b]: inside `bot_fov` and `bot_sight`, with nothing in
## the way. An enemy it cannot see is one it turns toward (everybody knows where the corners
## are) without engaging, so the first shot still waits `bot_reaction` from first sight.
func _aim_bot(player: ScPlayer, command: DotFpsCommand) -> Vector3:
	var best: ScPlayer = null
	var closest := INF

	for id: StringName in players:
		var other: ScPlayer = players[id]

		if other == player or not other.is_alive():
			continue

		if int(sides.get(id, 0)) == player.team:
			continue

		var distance := other.controller.state.position.distance_to(
			player.controller.state.position
		)

		if distance < closest:
			closest = distance
			best = other

	var aim := _bot_aim_of(player)

	if best == null:
		aim.release()
		return Vector3.INF

	var eye := player.eye_position()
	# The chest, not the eyes: a person aims at the middle of what they can see.
	var at := best.eye_position() - Vector3(0.0, 0.35, 0.0)

	if eye.distance_to(at) < 0.01:
		return Vector3.ZERO

	var profile := _bot_settings_of(player).profile
	var distance := eye.distance_to(at)
	var reach_standing := _bot_weapon_reach(player, false)
	# Where it would rather fight from: `bot_range`, or arm's length with a hatchet or a mallet.
	var hold_at := minf(profile.range, reach_standing * 0.6)
	var sees := _bot_sees(player, eye, at)
	var wants := false

	if sees:
		wants = _bot_shoot(player, command, best.entity_id, at, best.controller.state.velocity)
	else:
		aim.release()
		_bot_look(player, command, at)

	# [b]Standing still to shoot from range, as often as `bot_stop_to_shoot` says[/b], decided
	# once an engagement so it does not stutter, and only where it may open fire at all (inside
	# `bot_max_range` and the gun's reach): two stand-ins that stopped where neither would
	# fire stood fifty metres apart until the clock ran out. See [method _bot_weapon_reach]
	# for why a stand-in that keeps walking holds its fire until it is much closer.
	var holds := closest <= hold_at or closest >= config.bot_advance_metres \
		or (sees and distance <= minf(reach_standing, profile.max_range) \
			and _bot_stops_to_shoot(player, profile))
	# Walking by what the body is doing, which is what the gun's spread follows: a stand-in
	# that means to walk but is stopped against something is standing.
	var velocity := player.controller.state.velocity
	var walking := Vector2(velocity.x, velocity.z).length() > 1.0
	var reach := _bot_weapon_reach(player, walking and not holds)
	command.set_button(DotFpsCommand.BUTTON_USER_0, _bot_trigger(player, wants and distance <= reach))

	if holds:
		return Vector3.ZERO

	# [b]Close, but not from the far side of the map.[/b] Advancing whenever the nearest
	# enemy is further than six metres marched every stand-in off its own pad and down a
	# catwalk 3.4 m wide toward somebody sixty metres away — which is why two thirds of the
	# deaths in a bot showdown were falls rather than shots. Past the walk limit a bot holds
	# its corner and shoots from it, which is also the right thing for a person to do.
	var from := player.controller.state.position
	var goal := _showdown_goal(from, best.controller.state.position)

	if _showdown_zone(from).where == &"ring":
		goal = _bot_round_cover(player, from, goal)

	return Vector3(goal.x - from.x, 0.0, goal.z - from.z)


## On the ring, [param goal] or a step to one side of whatever stands between it and
## [param from]: the blocks facing each pad and the dais in the middle are on every
## catwalk's line, so a stand-in walking that line straight stopped against the first block
## and stood there for the rest of the round. Measured at knee height, under which a kerb is
## nothing and over which every block is something. Each stand-in prefers its own side, so
## it does not dither between two.
func _bot_round_cover(player: ScPlayer, from: Vector3, goal: Vector3) -> Vector3:
	if combat == null or combat.trace == null:
		return goal

	var knee := Vector3.UP * 0.5

	if combat.trace.line_of_sight(from + knee, goal + knee):
		return goal

	var flat := Vector3(goal.x - from.x, 0.0, goal.z - from.z)

	if flat.length() < 0.5:
		return goal

	var ahead := flat.normalized()
	var aside := Vector3(-ahead.z, 0.0, ahead.x)
	var side := 1.0 if hash(String(player.player_id)) % 2 == 0 else -1.0
	var middle := arena.showdown_centre()
	var inside := arena.ring_half() - 0.8

	for offset: float in [3.5 * side, -3.5 * side, 6.0 * side, -6.0 * side]:
		var step := from + ahead * minf(flat.length(), 5.0) + aside * offset
		if absf(step.x - middle.x) > inside or absf(step.z - middle.z) > inside:
			continue
		if combat.trace.line_of_sight(from + knee, step + knee):
			return step

	return goal


## Where a stand-in walking from [param from] toward somebody at [param to] heads next in the
## showdown: down the middle of its own catwalk to the ring, across the ring to the mouth of
## theirs, and up the middle of that one. Only a pad or the ring is walked straight across.
##
## [b]A straight line from pad to pad is a fall.[/b] The slots are spread across each pad, so
## the line from one to another's mirror image leaves a 3.4 m catwalk on the diagonal: measured
## with the line, every stand-in in a showdown walked off its catwalk about thirty metres out,
## all four on the same tick, and not one shot was fired in twenty rounds.
func _showdown_goal(from: Vector3, to: Vector3) -> Vector3:
	if arena == null:
		return to

	var here := _showdown_zone(from)
	var there := _showdown_zone(to)
	var middle := arena.showdown_centre()
	var ring := arena.ring_half()

	# On the same arm (or both on the ring): straight at them, except along a catwalk, where
	# it keeps to the middle line toward them.
	if here.arm == there.arm:
		if here.where != &"catwalk":
			return to
		var ahead := (here.s as float) + (3.0 if (there.s as float) > (here.s as float) else -3.0)
		return _on_arm(middle, here.out, ahead, from.y)

	# Off the ring on its own arm: inward along the middle of its catwalk (or across its pad
	# to the catwalk's mouth).
	if here.where == &"pad":
		return _on_arm(middle, here.out, arena.config.corner_distance - arena.config.corner_size * 0.5 - 1.0, from.y)
	if here.where == &"catwalk":
		return _on_arm(middle, here.out, (here.s as float) - 3.0, from.y)

	# On the ring, they are out along another arm: to its mouth, then up its middle.
	var lateral: float = absf(Vector2(from.x - middle.x, from.z - middle.z).dot(there.across))
	if lateral < 0.8:
		return _on_arm(middle, there.out, Vector2(from.x - middle.x, from.z - middle.z).dot(there.out) + 3.0, from.y)

	return _on_arm(middle, there.out, ring - 1.5, from.y)


## A point [param along] metres out from the ring's middle along [param out], at height [param y].
static func _on_arm(middle: Vector3, out: Vector2, along: float, y: float) -> Vector3:
	return Vector3(middle.x + out.x * along, y, middle.z + out.y * along)


## Which part of the showdown [param at] is on: `where` is `ring`, `catwalk` or `pad`, `arm`
## the catwalk's index (-1 on the ring), `out` and `across` its directions, `s` how far out.
func _showdown_zone(at: Vector3) -> Dictionary:
	var middle := arena.showdown_centre()
	var flat := Vector2(at.x - middle.x, at.z - middle.z)
	var ring := arena.ring_half()

	if absf(flat.x) <= ring and absf(flat.y) <= ring:
		return {"where": &"ring", "arm": -1, "out": Vector2.ZERO, "across": Vector2.ZERO, "s": 0.0}

	var count := maxi(config.team_count, 1)
	var best := 0
	var best_dot := -INF

	for index in range(count):
		var corner := arena.corner_point(index, count)
		var out := Vector2(corner.x - middle.x, corner.z - middle.z).normalized()
		var along := flat.normalized().dot(out)
		if along > best_dot:
			best_dot = along
			best = index

	var corner_at := arena.corner_point(best, count)
	var out_dir := Vector2(corner_at.x - middle.x, corner_at.z - middle.z).normalized()
	var s := flat.dot(out_dir)
	var pad_inner := config.corner_distance - config.corner_size * 0.5
	return {
		"where": &"pad" if s >= pad_inner else &"catwalk",
		"arm": best,
		"out": out_dir,
		"across": Vector2(out_dir.y, -out_dir.x),
		"s": s,
	}


## Whether this engagement is one [param player] stands still for: `bot_stop_to_shoot` is a
## chance per engagement, drawn from the engagement itself so it is the same answer every tick.
func _bot_stops_to_shoot(player: ScPlayer, profile: DotBotProfile) -> bool:
	var aim := _bot_aim_of(player)
	var roll := float(hash("%s#%d#%.4f" % [String(player.player_id), aim.target_id, aim.engaged_at]) & 0xffff) / 65535.0
	return roll < profile.stop_to_shoot


## How far the weapon in [param player]'s hands is worth firing, metres, standing or
## [param moving]: where its spread still lands within `sc_bot_spray` metres of the aim
## point, and never past its ballistics' `max_range` (a melee weapon's is its arm's length).
## No limit for a weapon that says neither.
##
## [b]Every gun here is far less accurate walking[/b] (the rifle's spread is five times its
## standing spread), and the stand-ins opened fire wherever dot-bot's `bot_max_range` let them,
## walking. The presets that see and shoot from further emptied a magazine into the air from
## sixty metres, reloaded at the moment they arrived and lost: measured over twenty showdowns
## each, nightmare lost 18 of 20 to the reference player and medium 12. A person who is
## walking holds their fire until it can land, or stops to shoot ([method _bot_stops_to_shoot]).
func _bot_weapon_reach(player: ScPlayer, moving: bool) -> float:
	var def := _bot_weapon(player)
	var ballistics := def.tuning as DotWeaponBallistics if def != null else null

	if ballistics == null:
		return INF

	var reach := ballistics.max_range if ballistics.max_range > 0.0 else INF
	var spread := ballistics.spread_moving if moving else ballistics.spread

	if spread > 0.01 and ballistics.pellets <= 1:
		reach = minf(reach, config.bot_spray_metres / tan(deg_to_rad(spread)))

	return reach


func _bot_weapon(player: ScPlayer) -> DotWeaponDef:
	if player.weapons == null or player.weapons.arsenal == null:
		return null

	return player.weapons.arsenal.current_def()


## The trigger a stand-in actually presses this tick, when it [param wants] to fire, for the
## weapon in its hands.
##
## [b]Held down, most of this game's weapons fire once.[/b] A revolver, a marksman rifle, a
## shotgun and a hatchet are one use per PRESS (dot-weapon's `SEMI`), a burst rifle one burst
## per press, and a charge rifle fires on RELEASE. The stand-ins held the button for as long as
## they meant to shoot, so with any of those they fired once and then stood aiming at somebody
## for the rest of the showdown, and with the charge rifle never fired at all. So: held for an
## automatic, tapped on every other tick for one a press, and held for the charge and let go.
func _bot_trigger(player: ScPlayer, wants: bool) -> bool:
	var def := _bot_weapon(player)
	var was_down: bool = _bot_triggers.get(player.player_id, false)
	var down := wants

	if def != null:
		match def.fire_mode:
			DotWeaponDef.Fire.SEMI, DotWeaponDef.Fire.BURST:
				down = wants and not was_down
			DotWeaponDef.Fire.CHARGE:
				var since: int = _bot_charges.get(player.player_id, -1)

				if wants and not was_down:
					_bot_charges[player.player_id] = _tick
				elif was_down and since >= 0 \
						and _tick - since >= player.weapons.arsenal.ticks_for(def, def.charge_ticks):
					down = false

	_bot_triggers[player.player_id] = down
	return down


## Whether [param player] can see [param at] from [param eye]: inside its view cone and sight
## (`bot_fov`, `bot_sight`) and nothing of the world in the way.
func _bot_sees(player: ScPlayer, eye: Vector3, at: Vector3) -> bool:
	var profile := _bot_settings_of(player).profile
	var aim := _bot_aim_of(player)
	var toward := at - eye

	if toward.length() > profile.sight:
		return false

	# Already engaged, a target just behind the shoulder is still the target: the cone is
	# for noticing somebody, and a person tracking one does not lose them by turning.
	var engaged := aim.target_id >= 0 and _bot_now() - aim.last_seen_at <= DotBotAim.CONTINUE_WINDOW

	if not engaged and rad_to_deg(DotBotAim.direction(aim.yaw, aim.pitch).angle_to(toward)) > profile.fov * 0.5:
		return false

	if profile.through_walls > 0.5 or combat == null or combat.trace == null:
		return true

	return combat.trace.line_of_sight(eye, at)


## Aims a stand-in at [param at] (target [param id]) and says whether it fires this tick:
## dot-bot's [DotBotAim], so the view turns at `bot_turn_rate`, the first shots miss by
## `bot_aim_error` and settle, and the trigger waits `bot_reaction` after first sight.
func _bot_shoot(player: ScPlayer, command: DotFpsCommand, id: int, at: Vector3, velocity: Vector3) -> bool:
	var aim := _bot_aim_of(player)
	var eye := player.eye_position()
	var now := _bot_now()
	var _new := aim.engage(id, eye, at, now)
	var view := aim.track(eye, at, velocity, now, delta_for_tick())
	command.yaw = view.x
	command.pitch = clampf(view.y, -89.0, 89.0)
	var fire := aim.trigger(now, eye.distance_to(at))

	if fire:
		aim.note_shot(eye, at, now)

	return fire


## Turns a stand-in toward [param at] the way a person turns: at `bot_turn_rate`, never in one
## tick. Writes the view into [param command].
func _bot_look(player: ScPlayer, command: DotFpsCommand, at: Vector3) -> void:
	var view := _bot_aim_of(player).look_at_point(player.eye_position(), at, delta_for_tick())
	command.yaw = view.x
	command.pitch = clampf(view.y, -89.0, 89.0)


## Stick movement for walking along [param world_dir] (flat, world space) with the view at
## [param yaw] degrees.
static func _bot_walk(yaw: float, world_dir: Vector3) -> Vector2:
	var flat := Vector3(world_dir.x, 0.0, world_dir.z)

	if flat.length() < 0.01:
		return Vector2.ZERO

	flat = flat.normalized()
	var turned := deg_to_rad(yaw)
	var forward := Vector3(-sin(turned), 0.0, -cos(turned))
	var right := Vector3(cos(turned), 0.0, -sin(turned))
	return Vector2(flat.dot(right), flat.dot(forward)).limit_length(1.0)


## A stand-in's [DotBotAim] for this round, made on first use.
##
## [b]The round is in the seed, and leaving it out makes every round the same fight.[/b] The
## corners are symmetric, the arrival slots are symmetric, and a bot's randomness is its own
## stream seeded from what it is given: seeded from the id alone, an empty server's showdown
## is a pure function of an arrangement the round does not change. Measured with the old
## fixed aim offset drawn on the id alone: twelve rounds, twelve wins for the same side, the
## same bot taking the only kill in every one.
func _bot_aim_of(player: ScPlayer) -> DotBotAim:
	var found: Variant = _bot_aims.get(player.player_id)

	if found != null:
		return found as DotBotAim

	var aim := DotBotAim.new(
		hash("%s#%d" % [String(player.player_id), round_number]), _bot_settings_of(player)
	)
	aim.view_from(player.controller.state.yaw, player.controller.state.pitch)
	_bot_aims[player.player_id] = aim
	return aim


## The settings a stand-in plays by: the game's (`bot_difficulty` and the `bot_*` cvars), or
## its own when something attached one to the player ([method DotBotSettings.attach]), which is
## how a measurement pins a reference player whatever the server's preset is.
func _bot_settings_of(player: ScPlayer) -> DotBotSettings:
	if player.has_meta(DotBotSettings.META):
		return DotBotSettings.of(player)

	return DotBotSettings.of(self)


## The game clock in seconds, for the bots' aim.
func _bot_now() -> float:
	return float(_tick) * delta_for_tick()


# --- Reacting ---------------------------------------------------------------

func _on_platform_collapsed(index: int, why: StringName) -> void:
	if progress != null:
		progress.on_platform_collapsed(index, why)

	platform_collapsed.emit(index, why)


func _on_platform_struck(index: int, at: Vector3, impulse: float, outcome: int) -> void:
	if progress != null:
		progress.on_platform_struck(index, at, outcome)

	platform_struck.emit(index, at, impulse, outcome)


func _on_prop_spawned(_prop: DotPropInstance) -> void:
	pass


func _on_prop_removed(prop: DotPropInstance, _reason: StringName) -> void:
	_prop_velocity.erase(prop.instance_id)

	if cannon != null:
		cannon.forget(prop.instance_id)


## A barrel went off. dot-props described the blast; this is what it does to people.
##
## [b]The split is the addon boundary rather than an accident.[/b] dot-props knows what a
## prop is and nothing else — a player needs somebody else's id space and authority rules —
## so it shoves the other props itself and hands the rest over here.
func _on_prop_exploded(
	at: Vector3, radius: float, damage_amount: float, force: float, by: StringName
) -> void:
	blast.emit(at, radius)

	var attacker := 0

	if players.has(by):
		attacker = (players[by] as ScPlayer).entity_id

	# A blast under a platform lifts it, which is the one way a barrel can save somebody:
	# it throws the thing that was about to crush them off its own line.
	var index := platforms.index_at(at.x, at.z)

	if index >= 0:
		var _hit := platforms.report_impact(
			index, damage_amount, radius * 0.5, at + Vector3(0.0, 0.5, 0.0)
		)

	if combat == null:
		return

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if not player.is_alive() or player.riding:
			continue

		var offset := player.controller.state.position - at
		var distance := offset.length()

		if distance > radius:
			continue

		var falloff := 1.0 - (distance / radius)
		var damage := DotDamage.make(
			attacker, player.entity_id, damage_amount * falloff, null
		)
		damage.point = player.controller.state.position
		damage.direction = offset.normalized() if distance > 0.01 else Vector3.UP
		damage.tick = _tick
		damage.context = {"why": DIED_BLAST}

		var _applied := combat.apply_damage(damage)

		# Thrown, and a barrel is the only thing in the survival phase that throws a player
		# UPWARD. It is the one way back onto a platform you have already fallen off the
		# edge of, and it is why standing near one is worth doing as well as worth avoiding.
		var push := damage.direction * force * falloff * 0.0035
		player.controller.state.velocity += push + Vector3.UP * falloff * 4.5


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the player and the tick, with the killing weapon's def (zee's sniper and launcher always throw
## the body). A death with no sideways direction (a fall, a trap) pushes nothing.
func decide_death(player: ScPlayer, damage: DotDamage) -> DotPlayerDeath:
	if _weapon_defs.is_empty():
		_weapon_defs = ZeeWeaponPack.table()
	var direction := damage.direction
	var attacker: ScPlayer = players.get(entities.key_for_id(damage.attacker)) if damage.attacker != 0 else null
	if direction.length_squared() < 0.0001 and attacker != null and attacker != player:
		direction = player.controller.state.position - attacker.controller.state.position
	return DotPlayerDeath.decide(
		ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(player.entity_id, _tick), _weapon_defs.get(damage.weapon_id)
	)


func _on_player_died(player: ScPlayer, damage: DotDamage) -> void:
	# One dictionary read. The alternative walks every player on the server comparing ints,
	# which is the reverse index [DotEntityTable] keeps so nobody has to — and it runs on
	# every death, which in this game is all of them.
	#
	# An attacker of 0 is dot-combat's "the world": a fall, a crate, a barrel nobody set
	# off. The table returns an empty key for it, which means the same thing.
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SHOT)

	# [b]Before dot-match hears of it, and the order is the whole reason for this comment.[/b]
	# `report_kill` can END the round synchronously — the last person on a side going is an
	# elimination — and ending it drops the phase to IDLE and files the round's numbers. A
	# kill counted after that is counted in no phase and filed in no round: the winning shot
	# of every showdown was missing from its shooter's figures until the suite said so.
	if spectate != null and authoritative:
		spectate.on_died(
			player.player_id, by, why == DIED_FELL,
			damage.point if damage.point != Vector3.ZERO else player.global_position,
			config.deck_height, _tick
		)

	if progress != null:
		progress.on_died(
			player.player_id, by, why == DIED_FELL,
			phase == Phase.HANDOVER or phase == Phase.SHOWDOWN
		)

	# [b]Only a player is reported to dot-match.[/b] Anything registered with dot-combat
	# arrives at this handler looking the same, and a scoreboard row filed against a falling
	# crate is a row nobody can explain. The kind is in the id, which is what dot-entity's
	# whole layout is for.
	if match_node != null and DotEntity.is_kind(player.entity_id, DotEntity.KIND_PLAYER):
		match_node.report_kill(
			String(by), String(player.player_id), why, _tick
		)

	# How the body falls, picked once, here, and carried on DEATH to every client.
	if authoritative:
		player.death = decide_death(player, damage)

	player_died.emit(player.player_id, by, why)
	DotLog.debug(CHANNEL, "player died", {
		"id": String(player.player_id), "by": String(by), "why": String(why),
	})


# --- Reporting --------------------------------------------------------------

## How many platforms are still up, which is the number this game's HUD lives on.
func standing_platforms() -> int:
	if not authoritative and remote_standing >= 0:
		return remote_standing

	return platforms.standing_count() if platforms != null else 0


## Seconds left in whatever half of the round this is.
func seconds_left() -> float:
	match phase:
		Phase.SURVIVAL:
			return maxf(config.survival_seconds - round_elapsed, 0.0)
		Phase.HANDOVER:
			return maxf(config.showdown_starts_at() - round_elapsed, 0.0)
		Phase.SHOWDOWN:
			return maxf(config.round_seconds() - round_elapsed, 0.0)
		_:
			return 0.0


## The ids in force, as one line for the HUD.
func special_line() -> String:
	if active.ids.is_empty():
		return ""

	var names := PackedStringArray()

	for id in active.ids:
		var special := ScSpecials.by_id(id)
		names.append(special.display_name if special != null else String(id))

	return " + ".join(names)


func describe() -> Dictionary:
	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"elapsed": "%.0f s" % round_elapsed,
		"left": "%.0f s" % seconds_left(),
		"layout": String(layout.id) if layout != null else "-",
		"special": special_line() if not active.is_plain() else "-",
		"players": players.size(),
		"alive": alive_count(),
		"teams_alive": teams_alive(),
		"platforms": standing_platforms(),
		"props": props.world_count() if props != null else 0,
		"choppers": _copter_ids.size(),
		"gravity": "%.1f m/s2" % (config.gravity * active.gravity_scale),
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["smash-copter, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-13s %s" % [key, facts[key]])

	if platforms != null:
		lines.append_array(platforms.describe_lines())

	if cannon != null:
		var shots := cannon.describe()
		lines.append("cannon")

		for key: String in shots:
			lines.append("  %-13s %s" % [key, shots[key]])

	return lines


## Every damage a weapon's shot did to somebody else, as [signal hit_landed] for the shooter.
## Only what took health and only on the authority: a refused hit, a dead body or the
## shooter's own splash is no confirmation anybody wants a marker for.
func _note_hits(shooter: ScPlayer, shot: DotShot) -> void:
	if not authoritative or shot == null or shooter == null:
		return
	for damage: DotDamage in shot.damages:
		if damage == null or damage.refused or damage.health_lost <= 0.0 or damage.victim == shooter.entity_id:
			continue
		hit_landed.emit(shooter.player_id, damage.point, damage.lethal, damage.hit_group == DotHitGroup.HEAD)
