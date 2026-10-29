extends Node3D

const ScAmbience := preload("sc_ambience.gd")
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

## The simulation. Headless, authoritative, the only thing that decides anything. A round is two games and the join
## between them is the design: a survival half where only the floor is a threat, then a fight between exactly the
## people who earned it by not falling. [ScPlatforms] is ours; the rest are other addons'.

const CHANNEL := "sc.game"

## Where this world publishes itself, so a module can find it: a registry name, not an autoload,
## because a server and a client in one process are two of these.
const SERVICE := &"sc_game"

## Snapshots a second. Higher than twenty because the lean of the floor underfoot arrives only in
## a snapshot, and at twenty its tilt updates in visible steps that read as stutter.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire. Both ends decode against
## this one value: ends that disagree land somewhere else entirely, not just imprecisely.
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

## Metres above the kill height at which a chopper counts as on the floor: a parked machine's
## origin rests 0.9 m above it, so the kill height itself never fires; two metres adds a bounce margin.
const COPTER_FLOOR_CLEARANCE := 2.0

## Metres above the kill height at which a person on foot has reached the floor.
## The floor's top IS the kill height and the motor rests a capsule a skin width above it, so
## `y <= kill_height` never fired for someone who really fell; half a metre is a step with a margin.
const FLOOR_REACH := 0.5

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)

## A round began. The platforms have been re-laid by the time this fires.
signal round_began(number: int, layout_id: StringName)

## The field is about to be taken down and rebuilt. Before, because clearing frees the
## behaviours (children of each platform) and a bridge that waited for the rebuild would hold
## freed instances in its table.
signal world_clearing()

## Asked every tick of a world that ticks itself: true while a cover is up (the client's load
## gate). Only the bodies are stepped then, so they settle onto the decks, and the phase, the
## platforms, the cannon, the falls and the round clock wait. Unset, never held.
var hold_clock: Callable = Callable()

## The field has just been rebuilt, by a round starting or by the world opening. Separate from
## [signal round_began] because the world lays itself out before the warmup, and players who joined
## then would otherwise stand on a field no client was told about.
signal world_rebuilt()

## A round ended. [param winner] is a team id, or 0 for a draw.
signal round_over(number: int, winner: int)

## The round moved from one half to the other.
signal phase_changed(phase: int)

## A special started or stopped. [param starting] says which.
signal special_changed(id: StringName, starting: bool, blurb: String)

## Somebody fell, was crushed, or was shot.
signal player_died(player_id: StringName, by: StringName, why: StringName, weapon_id: StringName)

## A platform came off its pillar. The client draws it; this decides it.
signal platform_collapsed(index: int, why: StringName)

## Something landed hard enough to matter.
signal platform_struck(index: int, at: Vector3, impulse: float, outcome: int)

## A barrel went off.
signal blast(at: Vector3, radius: float)

## Somebody earned an achievement. What a module turns into a notice to that one player.
signal achievement_earned(player_id: StringName, title: String, points: int)

## A survivor was handed a weapon at the handover. A signal because a weapon is not a replicated entity here, only a
## fact about a player that a watcher's HUD names, so there is no spawner or behaviour for the bridge to watch
## instead.
signal player_armed(player_id: StringName, weapon_id: StringName)

## A weapon's shot took health off somebody: to [param player_id], the shooter, for the hit
## marker and the hit drawn on the body. The server's word, never a client's prediction.
signal hit_landed(player_id: StringName, point: Vector3, killed: bool, headshot: bool)

const DIED_FELL := &"fell"
const DIED_CRUSHED := &"crushed"
const DIED_SHOT := &"shot"
const DIED_BLAST := &"blast"

@export var config: ScConfig = null

## The binder that layered [member config] (cfg/ yml, env, argv); null in a suite that built the config by hand.
var config_binder: DotGameConfigBinder = null

## The workbench's profile rows, made on first ask: the bridge's profile link must exist before the netcode seals, the workbench after.
var profile_runtime: DotProfileRuntime = null


func ensure_runtime() -> DotProfileRuntime:
	if profile_runtime == null:
		profile_runtime = DotProfileRuntime.new()
		profile_runtime.permit = func(actor: Variant, _flag: String) -> bool:
			return typeof(actor) == TYPE_STRING_NAME and actor == &"local"
	return profile_runtime

## dot-team's block rules (`mp_teamblock`, `!block`, `!noblock`), set by the module or the client's `add_noblock`; null without dot-team.
var block_rules: Object = null

## Whether this instance decides anything. A client sets this false.
@export var authoritative: bool = true

@export_range(1, 240, 1) var tick_rate: int = 64

## Whether something else drives the tick. Set by the bridge on both ends: a game's tick must happen INSIDE the
## netcode's, between applying inputs and building the snapshot, or a world still running its own `_physics_process`
## moves every player twice a tick (a server at double speed while somebody is connected).
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

## The field's toys (dot-props' [DotPropToyBox]): a beach ball on every platform, which rides a leaning deck,
## rolls off it at the edge, and is knocked flying by what the cannon throws. Placed from the layout on both
## ends, in deck order (see [method build_toys]). Null between fields.
var toys: DotPropToyBox = null

## The field's toys are about to go, on both ends: what the bridge releases their entities on.
signal toys_clearing()

## dot-player-controller's `mp_forceview` (may a player switch to third person) and `mp_solidplayers` (do
## players and stand-ins block each other). Bound by the module (REPLICATED) and followed by a client through
## its link: the client places its camera under the first and predicts its own player under the second.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()
## The ambience cvars (`sc_ambient*`): bound by the module (REPLICATED), followed by a client through its link.
var ambient_rules: DotAmbienceRules = ScAmbience.make_rules()


func _init() -> void:
	# This game's pick: players pass through each other (see `_build_physics`). An owner who
	# wants bodies sets `mp_solidplayers 1`.
	body_rules.solid = false

## The weapon definitions by id, for the death reaction a weapon asks for. Built on first use.
var _weapon_defs: Dictionary = {}
var effects: DotFxManager = null

## Where somebody who is out looks. See [ScSpectate].
var spectate: ScSpectate = null
## Who a spectator may watch and whether they may fly a free camera: dot-spectate's `mp_forcecamera`, `mp_freeroam`
## and `mp_freeroam_speed`. One object for the life of the game, shared with [ScSpectate]'s manager so a cvar change
## reaches the rules in use; bound by the module and followed by a client.
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

## Every world object this game has an id for, from one allocator. An id carries its kind, so a range check answers
## "is this a player": a falling prop is also registered with dot-combat, and a kill handler that could not tell
## them apart would file a scoreboard row against a crate.
var entities := DotEntityTable.new()

## What the server last said about numbers a client cannot count for itself; negative means "count it yourself". A
## client runs no cannon or platform model, so `standing_platforms()` there would count whatever its mirrors say.
## See `ScEvents.Kind.CLOCK`.
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


## The player's motor mask under `mp_solidplayers`, and the standing hull the others stop at (a body has no shape of
## its own). Through `apply_to`, since `set_collision_mask` is not undone by a style; with the rule on, a stand-in
## stops at your shoulder instead of walking through your face.
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


## Puts this world's physics space on the gravity the round is played at: on the SPACE, not `ProjectSettings`,
## because a server and a client in one process are two worlds and a global would let one decide for the other. It
## is also what makes the low-gravity special one call.
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


## Flips a player between walking and flying. Called by the ride, never directly.
func _set_riding(player_id: StringName, value: bool, at: Vector3 = Vector3.ZERO) -> void:
	var player: ScPlayer = players.get(player_id)

	if player == null:
		return

	player.set_riding(value)

	if not value and at != Vector3.ZERO:
		player.global_position = at
		player.controller.state.position = at


## The side a player stands on for the block rules: the team, "" for none.
func team_of_side(id: Variant) -> Variant:
	var side := int(sides.get(StringName(id), 0))
	return str(side) if side > 0 else ""


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


## Whether somebody is on at least two sides. A round with one side is an infinite loop with a scoreboard:
## elimination ends a round the moment a side has nobody alive, and an empty side satisfies that on the first tick,
## so it starts and ends several times a second.
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


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## Adopts a tick rate, on a client told what the server runs at: every player's controller as well as this world,
## since `tick_rate` on a player forwards to its controller and a world that changed only its own leaves everyone
## integrating at the old rate, corrected every snapshot.
func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	for id: StringName in players:
		(players[id] as ScPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	return true


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
