extends DotConfig

## Every number this game has, layered like every other [DotConfig]: defaults < JSON < environment < command line.
##
## Lengths are converted from the source map's units once, here, so no second set of units can drift. `ScModule` exposes the operator-facing ones as cvars that write through to this object.


@export_group("The round")

## Seconds the survival phase runs before the survivors are sent to the corners.
@export_range(10.0, 900.0, 5.0) var survival_seconds: float = 120.0

## Seconds the showdown runs before the round is called on the clock; a draw if nobody has won.
@export_range(10.0, 900.0, 5.0) var showdown_seconds: float = 90.0

## Seconds between the survival phase ending and the showdown starting.
##
## Not zero: players are teleported and armed in the same instant, and landing already under fire is an undodgeable death.
@export_range(0.0, 30.0, 0.5) var showdown_warmup_seconds: float = 4.0

## Seconds between rounds, for the platforms to be rebuilt.
@export_range(0.0, 60.0, 1.0) var intermission_seconds: float = 8.0

## Seconds of the round's final killcam, added to the intermission (`mp_killcam_time`); 0 is off. Not added when the intermission is 0.
@export_range(0.0, 30.0, 0.5) var killcam_seconds: float = 7.0

## Seconds of warmup before the first round. 0 starts immediately.
@export_range(0.0, 300.0, 1.0) var warmup_seconds: float = 12.0


@export_group("Sides")

## How many teams the server plays with. Two is red against blue.
##
## Up to six, a design ceiling: past the map's six corners the showdown becomes a free-for-all. [ScConfig.validate] refuses more.
@export_range(2, 6, 1) var team_count: int = 2

## Whether players may pick their own side.
@export var allow_team_choice: bool = true

## Whether shots, blasts and falls hurt the shooter's own side.
@export var friendly_fire: bool = false

## Whether the server evens the sides up between rounds.
@export var autobalance: bool = true


@export_group("The players")

@export_range(1.0, 400.0, 1.0) var player_health: float = 100.0

## How fast a player RUNS, in m/s. Running is the default; shift is the slow walk.
##
## Running is what destabilises a platform; see [member walk_speed_scale].
@export_range(1.0, 20.0, 0.1) var run_speed: float = 6.4

## What fraction of [member run_speed] holding the walk key gives.
##
## Shift is a brake, not a sprint: platform lean grows with how hard its occupants move ([member platform_motion_gain]), so walking is the only way across an occupied platform.
@export_range(0.1, 1.0, 0.01) var walk_speed_scale: float = 0.42

@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.15

## A player's mass in kilograms, which is what a platform feels them as.
@export_range(20.0, 200.0, 1.0) var player_mass: float = 80.0

## Metres per second squared, for everything: players, props and the chopper.
##
## Here rather than in `project.godot`, because a project setting does not travel with a delivered game and nothing reports the difference. Applied to the world's own physics space by [ScGame], since a server and client in one process are two worlds.
@export_range(1.0, 60.0, 0.5) var gravity: float = 20.0

## Metres below the deck at which a player is dead. The floor of the map.
@export_range(-500.0, 100.0, 1.0) var kill_height: float = 1.5


@export_group("The platforms")

## How far above the floor the platforms sit, in metres.
@export_range(5.0, 200.0, 0.5) var deck_height: float = 40.0

## One platform's side, in metres. They are square.
@export_range(2.0, 40.0, 0.25) var platform_size: float = 10.5

@export_range(0.1, 3.0, 0.05) var platform_thickness: float = 0.6

## Metres between the centres of two platforms along the rows.
##
## A little more than [member platform_size], so there is a gap a player can fall down.
@export_range(2.0, 60.0, 0.1) var column_pitch: float = 11.4

## Metres between the two rows of platforms.
##
## Far enough that no jump crosses it, so the bridges are worth fighting over.
@export_range(4.0, 120.0, 0.5) var row_pitch: float = 24.0

## The radius of the single pillar under each platform, in metres.
##
## One central pillar is what makes a platform tip when the load moves off centre.
@export_range(0.2, 8.0, 0.05) var pillar_radius: float = 1.35

## How hard a platform pushes itself back level, in radians per second squared per radian.
##
## Lower is a wobblier map. [member ScSpecials] turns this down for a whole round.
@export_range(0.1, 200.0, 0.1) var platform_stiffness: float = 7.0

## How much of a platform's lean speed is bled off per second.
##
## Under-damped on purpose: at critical damping a platform reads as a ramp, not as something balanced.
@export_range(0.0, 50.0, 0.05) var platform_damping: float = 1.55

## The rotational inertia of a platform, in arbitrary but consistent units.
##
## Loads are divided by this, so it trades "a person can tip it" against "cannot tip it alone".
@export_range(1.0, 100000.0, 10.0) var platform_inertia: float = 2600.0

## How much a load standing off centre leans the platform, per kilogram per metre.
##
## Tuned to the equilibrium `lean = offset * kilos * gain / (inertia * stiffness)`: at 1.0 nobody can tip anything (3.3 degrees running against a 16 degree collapse), at 1.8 three people on one edge take it over and shift matters.
@export_range(0.0, 100.0, 0.05) var platform_load_gain: float = 1.8

## How much harder a running load pushes than a still one.
##
## This is the walk key: at zero shift does nothing; at 2.0 a sprinter is three times a standing load.
@export_range(0.0, 10.0, 0.05) var platform_motion_gain: float = 2.0

## Radians of lean past which a platform comes off its pillar and falls.
##
## About sixteen degrees, a little past what a player can stand on.
@export_range(0.05, 1.2, 0.005) var platform_collapse_lean: float = 0.28

## How much punishment a platform takes before it collapses, in kilogram metres per second.
##
## Impacts add up, and only the lean shows it on the HUD.
@export_range(1.0, 1000000.0, 50.0) var platform_toughness: float = 5200.0

## A single impact this big collapses a platform outright, whatever its health.
##
## The tier-four prop case; below it an impact only tilts and wobbles.
@export_range(1.0, 1000000.0, 50.0) var platform_shatter_impulse: float = 4200.0

## How much of an impact becomes lean rather than damage.
@export_range(0.0, 100.0, 0.01) var platform_impact_gain: float = 0.55

## Seconds a collapsing platform takes to fall out of the world.
@export_range(0.5, 30.0, 0.1) var platform_fall_seconds: float = 6.0

## Whether the pillar goes down with the platform it was holding up.
##
## Off: the bare pillar is a marker, readable across the map, that this one is gone.
@export var pillar_falls_with_platform: bool = false

## How slippery a platform is, as a multiplier on the ground friction.
##
## One is ordinary footing. [member ScSpecials] takes it down for the ice round.
@export_range(0.02, 4.0, 0.01) var platform_grip: float = 1.0


@export_group("The layout")

## How many platforms there are along each row.
@export_range(2, 12, 1) var columns: int = 5

## How many rows of platforms there are.
@export_range(1, 6, 1) var rows: int = 2

## Whether the layout is re-rolled at the start of every round.
##
## On: most of this game's variety (see [ScLayouts]).
@export var vary_layout: bool = true

## Which layouts this server may draw, by id. Empty means all of them.
##
## Same shape as [member special_ids]: the catalogue is data. `--sc-layout-ids=checker` is how `tools/shot.sh` looks at one.
@export var layout_ids: PackedStringArray = PackedStringArray()

## Seed the layouts, the cannon and the special rounds are all drawn from.
##
## Reproducible on purpose: the same seed plays the same round, which makes bug reports and suite assertions meaningful. [DotRandom] rather than `randi()`, whose global generator is shared with the process.
@export var seed_value: int = 20260916


@export_group("The cannon")

## Whether the thing in the middle of the map fires at all.
@export var cannon_enabled: bool = true

## Seconds between shots at the start of a round.
@export_range(0.05, 60.0, 0.05) var cannon_interval: float = 1.9

## What that interval is multiplied by by the end of the survival phase.
##
## Below one, so the cannon speeds up as a smooth ramp over the survival clock; a constant threat makes the last thirty seconds the first.
@export_range(0.05, 4.0, 0.01) var cannon_interval_ramp: float = 0.42

## How many props one shot puts in the air.
@export_range(1, 24, 1) var cannon_volley: int = 1

## What that count is multiplied by by the end of the survival phase, rounded down.
@export_range(1.0, 12.0, 0.1) var cannon_volley_ramp: float = 2.6

## Metres above the deck a launched prop is aimed to reach at the top of its arc.
##
## The flight is solved from this and the target, so a taller arc is a longer warning.
@export_range(2.0, 200.0, 0.5) var cannon_apex: float = 26.0

## Metres the aim is scattered by, so a shot at a platform is not a shot at its centre.
@export_range(0.0, 40.0, 0.1) var cannon_spread: float = 4.2

## The largest prop tier the cannon may fire. 1 is crates only, 4 is everything.
##
## A ceiling for a gentler server; a different feel changes the tier weights below.
@export_range(1, 4, 1) var cannon_max_tier: int = 4

## How likely each tier is, relative to the others. Four numbers, smallest prop first.
##
## Weighted heavily to the small end: the platform-deleting props only read as terrifying if they are rare.
@export var cannon_tier_weights: PackedFloat32Array = PackedFloat32Array([54.0, 28.0, 13.0, 5.0])

## The tier the cannon may not fire until this many seconds into the survival phase.
##
## Four entries, one per tier. It is what makes the first twenty seconds survivable.
@export var cannon_tier_unlock: PackedFloat32Array = PackedFloat32Array([0.0, 12.0, 30.0, 55.0])

## How many props may be in the air and on the platforms at once.
##
## A cap on physics cost: past a few dozen rigid bodies the server's step time decides the round.
@export_range(4, 400, 1) var prop_budget: int = 110

## Seconds a launched prop lives before it is taken away, however it landed.
##
## Not forever (the deck would become a pile of crates) and not on landing (cover a player just earned would vanish).
@export_range(2.0, 300.0, 1.0) var prop_life_seconds: float = 45.0


@export_group("Special rounds")

## Whether special rounds happen at all.
@export var specials_enabled: bool = true

## The chance in a hundred that a round is given a special at the moment it begins.
@export_range(0.0, 100.0, 1.0) var special_round_chance: float = 34.0

## Whether a special may also arrive part way through an ordinary round.
##
## The unpredictable half: a round that declared itself at the start is one a player plans for.
@export var specials_mid_round: bool = true

## The mean number of seconds between mid-round specials.
@export_range(5.0, 900.0, 1.0) var special_mean_gap: float = 46.0

## The least number of seconds between two mid-round specials.
@export_range(1.0, 900.0, 1.0) var special_min_gap: float = 22.0

## How long a mid-round special lasts, in seconds. A start-of-round one lasts the round.
@export_range(2.0, 600.0, 1.0) var special_seconds: float = 24.0

## Which specials this server may draw, by id. Empty means all of them.
##
## A list of ids, not a flag each, because the catalogue is data (see [ScSpecials]).
@export var special_ids: PackedStringArray = PackedStringArray()


@export_group("The chopper")

## Whether any layout may carry a chopper.
@export var chopper_enabled: bool = true

## How many choppers a layout that has one gets.
@export_range(1, 6, 1) var chopper_count: int = 1

## Metres above the deck a chopper is parked at when the round begins.
@export_range(0.0, 200.0, 0.5) var chopper_pad_height: float = 6.0

## How hard the rotor pulls, as a multiple of the weight it is holding up.
##
## Above one, or it cannot climb: at exactly one it hovers and never rises.
@export_range(1.0, 6.0, 0.05) var chopper_lift: float = 1.9

## How fast a chopper moves over the ground at full tilt, in m/s.
@export_range(1.0, 120.0, 0.5) var chopper_speed: float = 19.0

## How fast it turns, in degrees per second.
@export_range(5.0, 360.0, 1.0) var chopper_yaw_rate: float = 72.0

## Metres above the deck a chopper may not climb past.
##
## A ceiling, so a player cannot remove themselves from the round by leaving.
@export_range(2.0, 400.0, 1.0) var chopper_ceiling: float = 52.0

## Whether the pilot may drop props out of it.
##
## Without it the chopper is a sightseeing tour; with it, a second cannon with a person aiming.
@export var chopper_may_drop: bool = true

## Seconds between drops.
@export_range(0.1, 60.0, 0.1) var chopper_drop_interval: float = 2.4

## The largest tier a chopper may drop.
@export_range(1, 4, 1) var chopper_drop_tier: int = 2


@export_group("The showdown")

## Metres from the middle of the map to a corner arena.
@export_range(10.0, 400.0, 1.0) var corner_distance: float = 62.0

## One corner arena's side, in metres.
@export_range(4.0, 80.0, 0.5) var corner_size: float = 17.0

## Metres above the deck the corner arenas sit at.
##
## Above the platforms, so falling out of a corner is still falling.
@export_range(-50.0, 200.0, 0.5) var corner_rise: float = 9.0

## How many weapons each survivor is given.
@export_range(1, 8, 1) var weapons_granted: int = 2

## Which weapons may be drawn, by id from the pack. Empty means a sensible default set.
##
## Ids, never models: zee-dot-weapons names weapons by role so a server's rules survive the art being replaced.
@export var weapon_pool: PackedStringArray = PackedStringArray()

## Whether both survivors of a team get the same draw.
##
## Off, deliberately: two different weapons give a team a plan to make, two identical ones a formation.
@export var weapons_match_within_team: bool = false

## Whether the platforms are cleared away when the showdown starts.
@export var clear_platforms_for_showdown: bool = true


@export_group("Bots")

## How many players the server keeps in the round by adding stand-ins.
##
## Zero on a busy server, four on an empty one: a lone player has no opponent, so the round would end instantly for ever.
@export_range(0, 24, 1) var minimum_players: int = 4

## How far a stand-in will walk toward the nearest enemy in the showdown, in metres.
##
## Two hundred does not bind: the corners are about 120 m apart, and a bot that will not leave its pad turns the showdown into two groups shooting past each other. Lower it so stand-ins hold a position; two thirds of bot-showdown deaths are falls.
@export_range(5.0, 400.0, 1.0) var bot_advance_metres: float = 200.0

## Degrees of lean a stand-in has to feel before it walks uphill (`sc_bot_lean_notice`).
##
## This game's own mistake on top of dot-bot's: raised, a platform tips further before the stand-in moves, as a person's would.
@export_range(0.0, 15.0, 0.05) var bot_lean_notice_degrees: float = 1.15

## How wide a miss, in metres, a stand-in accepts when it decides to fire (`sc_bot_spray`).
##
## A gun is worth firing out to where its spread lands within this of the aim point (see `ScGame._bot_weapon_reach`); raised, stand-ins spray from further and run dry sooner.
@export_range(0.1, 5.0, 0.05) var bot_spray_metres: float = 0.6

@export_group("Impacts")

## How far a falling prop has to be going down (m/s) before a landing counts as an impact. Keep above one tick of gravity or resting crates read as impacts.
@export_range(0.5, 40.0, 0.1) var impact_min_speed: float = 3.5

## Fraction of its downward speed a prop must lose in one step to count as landed.
@export_range(0.05, 1.0, 0.01) var impact_loss: float = 0.45

## Metres from an impact within which a player is hurt by it.
@export_range(0.1, 20.0, 0.1) var impact_hurt_radius: float = 2.4

## Damage a landing does to a player, per kilogram metre per second of impulse.
@export_range(0.0, 2.0, 0.005) var impact_hurt_per_impulse: float = 0.055

## Fraction of the world's gravity a falling platform accelerates at.
@export_range(0.05, 2.0, 0.01) var fall_gravity_scale: float = 0.62

## Radians per second a falling platform tips over as it goes.
@export_range(0.0, 5.0, 0.05) var fall_tip_rate: float = 0.85

# How far a stand-in's aim is off is dot-bot's `bot_aim_error` (and its settling, reaction and
# turn rate): the old per-round fixed offset, `bot_aim_spread_degrees`, is gone, and its cvar
# `sc_bot_spread` is a deprecated name for `bot_aim_error`.


@export_group("Watching")

## Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody.
##
## Own side by default: a dead player watching another corner is a free scout on voice, and dot-spectate then forces first person. `sc_spectate_camera` is the cvar.
@export_enum("anybody", "own side", "nobody") var spectate_camera: int = 0

## Seconds the death camera holds on the spot a person fell from, then the freeze camera. Both ends read it; client-side only (no replicated state).
@export_range(0.0, 10.0, 0.1) var death_cam_seconds: float = 1.5

## Seconds the freeze camera holds before the free one.
@export_range(0.0, 10.0, 0.1) var freeze_cam_seconds: float = 1.5


@export_group("Progress")

## Whether the server counts per-player numbers and awards achievements at all.
@export var keep_progress: bool = true

## Where lifetime achievement progress is written. Empty keeps it in memory.
##
## Memory by default, as dot-achievements does: a server silently writing a file per player under `user://` fills the disk unnoticed.
@export var progress_directory: String = ""

## Whether the numbers and the unlocks are reported to the backbone.
##
## Off: it needs an integration token this game does not configure, and a reporter without one queues rows nobody sends.
@export var report_progress: bool = false


## `@export_group` -> the cfg file it lives in: `cfg/game/mg-smash-copter/config_<file>/game.yml`.
const CFG_FILES := {
	"The round": "round", "Sides": "round", "The players": "round", "Impacts": "round", "Watching": "round", "Bots": "round", "Progress": "round",
	"The platforms": "floor", "The layout": "floor", "The showdown": "floor",
	"The cannon": "cannon", "Special rounds": "cannon", "The chopper": "cannon",
}


## The binder every entry point uses: [param config] layered, one cfg file per [constant CFG_FILES] entry.
static func make_binder(config: DotConfig, json_path := "") -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(config, "mg-smash-copter", "sc", json_path)
	b.grouped = true
	b.group_files = CFG_FILES
	return b


func env_prefix() -> String:
	return "SC_"


func cli_prefix() -> String:
	return "--sc-"


## Seconds the whole round runs, both phases and the pause between them.
func round_seconds() -> float:
	return survival_seconds + showdown_warmup_seconds + showdown_seconds


## Where the survival phase ends and the handover begins.
func showdown_starts_at() -> float:
	return survival_seconds + showdown_warmup_seconds


func validate() -> DotResult:
	if survival_seconds <= 0.0 or showdown_seconds <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "Both phases of a round have to last some time."
		)

	if team_count < 2 or team_count > 6:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"team_count is %d; this game plays with two to six sides." % team_count,
		)

	# A platform wider than the gap between two of them is two platforms sharing a volume,
	# which the physics resolves by flinging whatever is standing there across the map.
	if column_pitch <= platform_size:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"column_pitch (%.2f m) is not past platform_size (%.2f m), so neighbours overlap."
				% [column_pitch, platform_size],
		)

	# A pillar as wide as its platform is a plinth. Everything this game is about needs the
	# platform to be able to tip off the thing holding it up.
	if pillar_radius * 2.0 >= platform_size * 0.8:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"pillar_radius (%.2f m) is most of platform_size (%.2f m); nothing would tip."
				% [pillar_radius, platform_size],
		)

	if deck_height <= kill_height + 2.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"deck_height (%.1f m) is not above kill_height (%.1f m) by enough to fall."
				% [deck_height, kill_height],
		)

	# A shatter threshold below the toughness would make every platform explosive, which
	# reads as the accumulating-damage model being broken rather than as two numbers that
	# disagree.
	if platform_shatter_impulse <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "platform_shatter_impulse has to be positive."
		)

	if cannon_tier_weights.size() != 4 or cannon_tier_unlock.size() != 4:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"cannon_tier_weights and cannon_tier_unlock are one entry per tier, so four each.",
			"weights=%d unlock=%d" % [cannon_tier_weights.size(), cannon_tier_unlock.size()],
		)

	var total := 0.0
	for weight in cannon_tier_weights:
		if weight < 0.0:
			return DotResult.fail(
				DotError.CODE_INVALID, "A tier weight cannot be negative."
			)
		total += weight

	if total <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Every cannon tier weight is zero, so the cannon could never choose anything.",
		)

	if spectate_camera < 0 or spectate_camera > 2:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"spectate_camera is %d; it is 0 (anybody), 1 (own side) or 2 (nobody)."
				% spectate_camera,
		)

	if chopper_lift <= 1.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"chopper_lift is %.2f; at or below 1.0 a chopper cannot leave the pad."
				% chopper_lift,
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"teams": team_count,
		"survival": "%.0f s" % survival_seconds,
		"showdown": "%.0f s" % showdown_seconds,
		"platforms": "%d x %d" % [columns, rows],
		"deck": "%.0f m" % deck_height,
		"cannon": "every %.2f s" % cannon_interval if cannon_enabled else "off",
		"specials": "%.0f%%" % special_round_chance if specials_enabled else "off",
		"chopper": chopper_enabled,
		"gravity": "%.1f m/s2" % gravity,
	}


## Overridden to print what this game is tuned to rather than every field.
##
## Keeps the parent's `redact_sensitive` parameter: a narrowed override is silently the parent's at call sites that pass it.
func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("smash-copter configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-14s %s" % [key, facts[key]])
	return lines
