extends DotConfig

## Every number this game has, layered like every other [DotConfig] in the family.
##
## [code]exported defaults < JSON file < environment < command line[/code], identically to
## dot-server, dot-cloud and the other six games. Nothing here reads
## [code]OS.get_cmdline_args[/code] itself.
##
## [b]Metres and seconds.[/b] The map this game is built from is authored in a
## twenty-year-old community's units and every length below was converted once, here, at
## the boundary — a platform is 10.5 m because 564 of that engine's units is 10.74 m. A
## second set of units inside the game would be a second place a ratio can drift, and
## unlike game-g2gfast nothing here has to be comparable with anybody else's numbers.
##
## [b]Nearly all of it is live.[/b] `ScModule` turns the two dozen an operator actually
## wants between rounds into cvars, and each of those writes through to this object rather
## than keeping a second copy of the number.

# --- The round -------------------------------------------------------------

@export_group("The round")

## Seconds the survival phase runs before the survivors are sent to the corners.
##
## [b]The first objective, and the longer half of the round.[/b] Everybody is on the
## platforms and the only thing to do is stay on one.
@export_range(10.0, 900.0, 5.0) var survival_seconds: float = 120.0

## Seconds the showdown runs before the round is called on the clock.
##
## A showdown that ran for ever would be two people hiding in opposite corners of a map
## that is mostly air, so it ends — as a draw if nobody has won.
@export_range(10.0, 900.0, 5.0) var showdown_seconds: float = 90.0

## Seconds between the survival phase ending and the showdown starting.
##
## [b]Not zero, and the reason is the teleport.[/b] Everybody is moved across the map and
## handed a weapon in the same instant; landing in a corner already being shot at is a
## death nobody could have done anything about.
@export_range(0.0, 30.0, 0.5) var showdown_warmup_seconds: float = 4.0

## Seconds between rounds, for the platforms to be rebuilt.
@export_range(0.0, 60.0, 1.0) var intermission_seconds: float = 8.0

## Seconds of the round's final killcam, added to the intermission (`mp_killcam_time`); 0 is off. Not added when the intermission is 0.
@export_range(0.0, 30.0, 0.5) var killcam_seconds: float = 7.0

## Seconds of warmup before the first round. 0 starts immediately.
@export_range(0.0, 300.0, 1.0) var warmup_seconds: float = 12.0

# --- Sides -----------------------------------------------------------------

@export_group("Sides")

## How many teams the server plays with. Two is red against blue.
##
## [b]Up to six, and the ceiling is a decision rather than a limit of anything.[/b] Six
## teams is six corners, and the map has four proper corners and two ends; beyond that
## the showdown stops being a fight between sides and becomes a free-for-all with
## bookkeeping. [ScConfig.validate] refuses more.
@export_range(2, 6, 1) var team_count: int = 2

## Whether players may pick their own side.
@export var allow_team_choice: bool = true

## Whether the server evens the sides up between rounds.
@export var autobalance: bool = true

# --- The players -----------------------------------------------------------

@export_group("The players")

@export_range(1.0, 400.0, 1.0) var player_health: float = 100.0

## How fast a player RUNS, in m/s. Running is the default; shift is the slow walk.
##
## [b]Running is what destabilises a platform, and that is the whole of this game's
## movement decision.[/b] See [member walk_speed_scale].
@export_range(1.0, 20.0, 0.1) var run_speed: float = 6.4

## What fraction of [member run_speed] holding the walk key gives.
##
## [b]Shift is a brake here, not a sprint, which is the opposite of every other game in
## this family.[/b] A platform is destabilised in proportion to how hard the people on it
## are moving — see [member platform_motion_gain] — so walking is the only way to cross a
## platform somebody else is already standing on the far side of. Binding that to the key
## every player already holds down to go faster is the joke the map is built on.
@export_range(0.1, 1.0, 0.01) var walk_speed_scale: float = 0.42

@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.15

## A player's mass in kilograms, which is what a platform feels them as.
@export_range(20.0, 200.0, 1.0) var player_mass: float = 80.0

## Metres per second squared, for everything: players, props and the chopper.
##
## [b]Here rather than in `project.godot`, because a project setting does not travel with
## a delivered game.[/b] A pack mounted into the server tool's project runs at ITS
## setting, and nothing reports the difference: what it looks like is a game that plays
## correctly on a developer's machine and floats everywhere it is deployed. Applied to the
## world's own physics space by [ScGame], because a server and a client in one process are
## two worlds and a global would be one of them deciding for the other.
@export_range(1.0, 60.0, 0.5) var gravity: float = 20.0

## Metres below the deck at which a player is dead. The floor of the map.
@export_range(-500.0, 100.0, 1.0) var kill_height: float = 1.5

# --- The platforms ---------------------------------------------------------

@export_group("The platforms")

## How far above the floor the platforms sit, in metres.
@export_range(5.0, 200.0, 0.5) var deck_height: float = 40.0

## One platform's side, in metres. They are square.
@export_range(2.0, 40.0, 0.25) var platform_size: float = 10.5

@export_range(0.1, 3.0, 0.05) var platform_thickness: float = 0.6

## Metres between the centres of two platforms along the rows.
##
## Deliberately a little more than [member platform_size], so there is a gap a player can
## fall down and a jump they have to mean.
@export_range(2.0, 60.0, 0.1) var column_pitch: float = 11.4

## Metres between the two rows of platforms.
##
## [b]Far enough apart that no jump crosses it.[/b] The rows are joined by the bridges and
## by nothing else, which is what makes a bridge worth fighting over.
@export_range(4.0, 120.0, 0.5) var row_pitch: float = 24.0

## The radius of the single pillar under each platform, in metres.
##
## [b]One pillar, in the middle, and everything about this game comes out of it.[/b] A
## platform resting on a column narrower than itself is a platform that tips when the load
## on it moves off centre, and that is the entire first objective.
@export_range(0.2, 8.0, 0.05) var pillar_radius: float = 1.35

## How hard a platform pushes itself back level, in radians per second squared per radian.
##
## Lower is a wobblier map. [member ScSpecials] turns this down for a whole round.
@export_range(0.1, 200.0, 0.1) var platform_stiffness: float = 7.0

## How much of a platform's lean speed is bled off per second.
##
## [b]Under-damped on purpose.[/b] At critical damping a platform leans and stops, which
## reads as a ramp rather than as something balanced; a platform that overshoots and comes
## back is one a player can feel moving under them.
@export_range(0.0, 50.0, 0.05) var platform_damping: float = 1.55

## The rotational inertia of a platform, in arbitrary but consistent units.
##
## Everything a load does to a platform is divided by this, so it is the one number that
## trades "a person can tip it" against "a person cannot tip it alone".
@export_range(1.0, 100000.0, 10.0) var platform_inertia: float = 2600.0

## How much a load standing off centre leans the platform, per kilogram per metre.
##
## [b]Measured against the equilibrium a real player reaches, not chosen.[/b] A platform
## settles where the spring balances the load, which is
## `lean = offset * kilos * gain / (inertia * stiffness)` — so at a gain of 1.0 one person
## standing on the very edge of a 10.5 m platform leans it by 1.1 degrees and one RUNNING
## across it by 3.3, against a collapse angle of sixteen. At those numbers nobody can tip
## anything, the walk key does nothing a player could feel, and the first objective is
## standing still for two minutes. At 1.8 a lone runner leans it six degrees, three of them
## on one edge take it over, and shift is the difference.
@export_range(0.0, 100.0, 0.05) var platform_load_gain: float = 1.8

## How much harder a running load pushes than a still one.
##
## [b]This is the walk key.[/b] At zero a platform does not care how fast anybody on it is
## moving and shift does nothing; at 2.0 a sprinting player is three times the load of a
## standing one and crossing a platform at speed throws it. See [member walk_speed_scale].
@export_range(0.0, 10.0, 0.05) var platform_motion_gain: float = 2.0

## Radians of lean past which a platform comes off its pillar and falls.
##
## About sixteen degrees by default, which is a little past what a player can stand on:
## the platform is already sliding people off before it goes.
@export_range(0.05, 1.2, 0.005) var platform_collapse_lean: float = 0.28

## How much punishment a platform takes before it collapses, in kilogram metres per second.
##
## Impacts add up. A platform that has been hit twice is one more hit from gone, and
## nothing on the HUD says so — the lean does.
@export_range(1.0, 1000000.0, 50.0) var platform_toughness: float = 5200.0

## A single impact this big collapses a platform outright, whatever its health.
##
## [b]The explosive case, and it is what a tier-four prop is for.[/b] Below it an impact
## tilts and wobbles; at it the platform is simply gone, with whoever was on it.
@export_range(1.0, 1000000.0, 50.0) var platform_shatter_impulse: float = 4200.0

## How much of an impact becomes lean rather than damage.
@export_range(0.0, 100.0, 0.01) var platform_impact_gain: float = 0.55

## Seconds a collapsing platform takes to fall out of the world.
@export_range(0.5, 30.0, 0.1) var platform_fall_seconds: float = 6.0

## Whether the pillar goes down with the platform it was holding up.
##
## [b]Off, and a bare pillar is the point.[/b] What is left behind is a marker a player
## can read from across the map: that one is gone, do not run that way. A pillar that
## vanished with its platform would leave a hole in the sky nobody can judge.
@export var pillar_falls_with_platform: bool = false

## How slippery a platform is, as a multiplier on the ground friction.
##
## One is ordinary footing. [member ScSpecials] takes it down for the ice round.
@export_range(0.02, 4.0, 0.01) var platform_grip: float = 1.0

# --- The layout ------------------------------------------------------------

@export_group("The layout")

## How many platforms there are along each row.
@export_range(2, 12, 1) var columns: int = 5

## How many rows of platforms there are.
@export_range(1, 6, 1) var rows: int = 2

## Whether the layout is re-rolled at the start of every round.
##
## [b]On, and it is most of this game's variety.[/b] See [ScLayouts]: the same platform
## field with two columns knocked out, or the bridges taken away, or a chopper parked on
## it, is a different round to play.
@export var vary_layout: bool = true

## Which layouts this server may draw, by id. Empty means all of them.
##
## The same shape as [member special_ids], for the same reason: the catalogue is data, and
## an operator running one layout all evening — or a render of one — is a word on a line
## rather than a code change. `--sc-layout-ids=checker` is how `tools/shot.sh` looks at one.
@export var layout_ids: PackedStringArray = PackedStringArray()

## Seed the layouts, the cannon and the special rounds are all drawn from.
##
## [b]A seed rather than a fixed schedule, and it is reproducible on purpose.[/b] Two
## servers on the same seed play the same round, which is what makes a bug report about
## "the platform that went at forty seconds" mean anything — and what lets the suite
## assert against a round at all. [DotRandom] rather than [code]randi()[/code], for the
## family's reason: the global generator is shared with everything else in the process.
@export var seed_value: int = 20260916

# --- The cannon ------------------------------------------------------------

@export_group("The cannon")

## Whether the thing in the middle of the map fires at all.
@export var cannon_enabled: bool = true

## Seconds between shots at the start of a round.
@export_range(0.05, 60.0, 0.05) var cannon_interval: float = 1.9

## What that interval is multiplied by by the end of the survival phase.
##
## [b]Below one, so the cannon speeds up.[/b] A round whose threat is constant is a round
## whose last thirty seconds are its first thirty seconds; this is what makes surviving to
## the end mean something. Applied as a smooth ramp over the survival clock.
@export_range(0.05, 4.0, 0.01) var cannon_interval_ramp: float = 0.42

## How many props one shot puts in the air.
@export_range(1, 24, 1) var cannon_volley: int = 1

## What that count is multiplied by by the end of the survival phase, rounded down.
@export_range(1.0, 12.0, 0.1) var cannon_volley_ramp: float = 2.6

## Metres above the deck a launched prop is aimed to reach at the top of its arc.
##
## The whole flight is solved from this and the target: a prop leaves the tube fast enough
## to reach this height and lands where it was aimed, so a taller arc is a longer warning.
@export_range(2.0, 200.0, 0.5) var cannon_apex: float = 26.0

## Metres the aim is scattered by, so a shot at a platform is not a shot at its centre.
@export_range(0.0, 40.0, 0.1) var cannon_spread: float = 4.2

## The largest prop tier the cannon may fire. 1 is crates only, 4 is everything.
##
## [b]A ceiling rather than a weighting, because the two answer different questions.[/b]
## An operator who wants a gentler server lowers this; one who wants a different FEEL
## changes the tier weights below.
@export_range(1, 4, 1) var cannon_max_tier: int = 4

## How likely each tier is, relative to the others. Four numbers, smallest prop first.
##
## [b]Weighted, not uniform, and heavily toward the small end.[/b] A map where every
## fourth prop is the one that deletes a platform outright is a map nobody survives thirty
## seconds of, and the big ones only read as terrifying if they are rare.
@export var cannon_tier_weights: PackedFloat32Array = PackedFloat32Array([54.0, 28.0, 13.0, 5.0])

## The tier the cannon may not fire until this many seconds into the survival phase.
##
## Four entries, one per tier. It is what makes the first twenty seconds survivable.
@export var cannon_tier_unlock: PackedFloat32Array = PackedFloat32Array([0.0, 12.0, 30.0, 55.0])

## How many props may be in the air and on the platforms at once.
##
## A cap on the physics rather than on the design: past a few dozen rigid bodies the
## server's step cost is what decides the round.
@export_range(4, 400, 1) var prop_budget: int = 110

## Seconds a launched prop lives before it is taken away, however it landed.
##
## [b]Not forever, and not on landing.[/b] A prop that stayed would turn every platform
## into a pile of crates by the end of the round, and one that vanished the moment it
## stopped would take away the cover a player just earned. A minute is long enough to
## stand behind and short enough that the map clears itself.
@export_range(2.0, 300.0, 1.0) var prop_life_seconds: float = 45.0

# --- Special rounds --------------------------------------------------------

@export_group("Special rounds")

## Whether special rounds happen at all.
@export var specials_enabled: bool = true

## The chance in a hundred that a round is given a special at the moment it begins.
@export_range(0.0, 100.0, 1.0) var special_round_chance: float = 34.0

## Whether a special may also arrive part way through an ordinary round.
##
## [b]The unpredictable half.[/b] A round that declared itself at the start is one a
## player plans for; one that turns the gravity off at ninety seconds is not.
@export var specials_mid_round: bool = true

## The mean number of seconds between mid-round specials.
@export_range(5.0, 900.0, 1.0) var special_mean_gap: float = 46.0

## The least number of seconds between two mid-round specials.
@export_range(1.0, 900.0, 1.0) var special_min_gap: float = 22.0

## How long a mid-round special lasts, in seconds. A start-of-round one lasts the round.
@export_range(2.0, 600.0, 1.0) var special_seconds: float = 24.0

## Which specials this server may draw, by id. Empty means all of them.
##
## [b]A list of ids rather than a flag each, because the catalogue is data.[/b] See
## [ScSpecials]: adding one is a row in a table, and an operator excluding it is a word
## removed from this line.
@export var special_ids: PackedStringArray = PackedStringArray()

# --- The chopper -----------------------------------------------------------

@export_group("The chopper")

## Whether any layout may carry a chopper.
@export var chopper_enabled: bool = true

## How many choppers a layout that has one gets.
@export_range(1, 6, 1) var chopper_count: int = 1

## Metres above the deck a chopper is parked at when the round begins.
@export_range(0.0, 200.0, 0.5) var chopper_pad_height: float = 6.0

## How hard the rotor pulls, as a multiple of the weight it is holding up.
##
## [b]Above one, or it cannot climb.[/b] At exactly one it hovers and never rises, which
## is a helicopter nobody can tell from a broken one.
@export_range(1.0, 6.0, 0.05) var chopper_lift: float = 1.9

## How fast a chopper moves over the ground at full tilt, in m/s.
@export_range(1.0, 120.0, 0.5) var chopper_speed: float = 19.0

## How fast it turns, in degrees per second.
@export_range(5.0, 360.0, 1.0) var chopper_yaw_rate: float = 72.0

## Metres above the deck a chopper may not climb past.
##
## A ceiling, because the whole point of the machine is being above the platforms and a
## player who simply leaves is a player who has removed themselves from the round.
@export_range(2.0, 400.0, 1.0) var chopper_ceiling: float = 52.0

## Whether the pilot may drop props out of it.
##
## [b]The map this is built from has exactly this and it is the best thing in it.[/b] A
## chopper that can only be flown is a sightseeing tour; one that can drop a crate on
## somebody is a second cannon with a person aiming it.
@export var chopper_may_drop: bool = true

## Seconds between drops.
@export_range(0.1, 60.0, 0.1) var chopper_drop_interval: float = 2.4

## The largest tier a chopper may drop.
@export_range(1, 4, 1) var chopper_drop_tier: int = 2

# --- The showdown ----------------------------------------------------------

@export_group("The showdown")

## Metres from the middle of the map to a corner arena.
@export_range(10.0, 400.0, 1.0) var corner_distance: float = 62.0

## One corner arena's side, in metres.
@export_range(4.0, 80.0, 0.5) var corner_size: float = 17.0

## Metres above the deck the corner arenas sit at.
##
## [b]Above the platforms, so the survival phase is visibly below you.[/b] Falling out of
## a corner is still falling, which keeps the map's one rule true in both halves.
@export_range(-50.0, 200.0, 0.5) var corner_rise: float = 9.0

## How many weapons each survivor is given.
@export_range(1, 8, 1) var weapons_granted: int = 2

## Which weapons may be drawn, by id from the pack. Empty means a sensible default set.
##
## [b]Ids, never models.[/b] `zee-dot-weapons` names its weapons by the role they play —
## `sniper`, `drum_shotgun`, `beamer` — precisely so a server's rules survive the art
## being replaced.
@export var weapon_pool: PackedStringArray = PackedStringArray()

## Whether both survivors of a team get the same draw.
##
## [b]Off by default, and the asymmetry is deliberate.[/b] Two people from one team
## arriving in a corner with a sniper and a shotgun have a plan to make; two with the same
## rifle have a formation.
@export var weapons_match_within_team: bool = false

## Whether the platforms are cleared away when the showdown starts.
@export var clear_platforms_for_showdown: bool = true

# --- Bots ------------------------------------------------------------------

@export_group("Bots")

## How many players the server keeps in the round by adding stand-ins.
##
## [b]Zero on a busy server and four on an empty one.[/b] Unlike a deathmatch, one person
## alone here is a person watching a cannon: the survival phase has nothing in it that
## needs an opponent, so the round ends the moment they are the only one left — which on
## an empty server is instantly, for ever.
@export_range(0, 24, 1) var minimum_players: int = 4

## How far a stand-in will walk toward the nearest enemy in the showdown, in metres.
##
## [b]Two hundred does not bind, and that is deliberate.[/b] The corners are about a hundred
## and twenty metres apart, so the default lets a stand-in cross — committing to the catwalk
## is what the showdown is for, and a bot that would not leave its pad turns the second half
## into two groups shooting past each other until the clock runs out. Measured at
## thirty-four: five of six alive at the end of every round.
##
## What it is for is the other direction. Two thirds of the deaths in a bot showdown are
## falls rather than shots, and a server that wants its empty-server stand-ins to look like
## people holding a position rather than a queue walking off a ledge can bring it down. It
## is a knob because the right answer depends on how many sides are playing and how far
## apart their corners are, and both of those are configurable too.
@export_range(5.0, 400.0, 1.0) var bot_advance_metres: float = 200.0

## Degrees of lean a stand-in has to feel before it walks uphill (`sc_bot_lean_notice`).
##
## [b]This game's own mistake, on top of dot-bot's.[/b] How a stand-in turns, aims and how soon
## it fires are dot-bot's `bot_difficulty` and `bot_*` settings, shared by every game; how it
## keeps its footing on a platform is only this game's. At about a degree it corrects a lean as
## soon as it starts, which is what it always did; raised, it lets a platform tip further before
## it moves, which is the mistake a person makes and the one that puts a crowded deck over.
@export_range(0.0, 15.0, 0.05) var bot_lean_notice_degrees: float = 1.15

## How wide a miss, in metres, a stand-in accepts when it decides to fire (`sc_bot_spray`).
##
## [b]This game's weapons, not dot-bot's aim.[/b] A gun is worth firing out to where its spread
## still lands within this of the aim point, standing or walking, and a stand-in that is
## walking holds its fire until then (see `ScGame._bot_weapon_reach`). At 0.6, about a body's
## half-width, the rifle reaches 76 m standing and 16 walking. Raised, stand-ins spray from
## further and run dry sooner.
@export_range(0.1, 5.0, 0.05) var bot_spray_metres: float = 0.6

# How far a stand-in's aim is off is dot-bot's `bot_aim_error` (and its settling, reaction and
# turn rate): the old per-round fixed offset, `bot_aim_spread_degrees`, is gone, and its cvar
# `sc_bot_spread` is a deprecated name for `bot_aim_error`.

# --- Watching --------------------------------------------------------------

@export_group("Watching")

## Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody.
##
## [b]Their own side by default, and the second half is why.[/b] Nobody can hurt anybody
## for the first two minutes, so a dead player watching another side on the platforms is
## harmless — but the showdown is a team fight in the open, and a dead player with a camera
## on the other side's corner is a free scout for their team-mates on voice. dot-spectate's
## own rule then forces first person, because a chase camera behind a team-mate sees round
## corners they cannot. `sc_spectate_camera` is the cvar.
@export_enum("anybody", "own side", "nobody") var spectate_camera: int = 0

# --- Progress --------------------------------------------------------------

@export_group("Progress")

## Whether the server counts per-player numbers and awards achievements at all.
@export var keep_progress: bool = true

## Where lifetime achievement progress is written. Empty keeps it in memory.
##
## [b]Memory by default, which is dot-achievements' own default and for its reason:[/b] a
## server that silently started writing a file per player under `user://` is one nobody
## notices until the disk is full. An operator who wants progress to outlive a restart
## names a directory.
@export var progress_directory: String = ""

## Whether the numbers and the unlocks are reported to the backbone.
##
## [b]Off, and it needs a credential this game does not configure.[/b] A reporter with no
## integration token queues rows nobody will send; the day an operator gives this server
## one, this is the switch.
@export var report_progress: bool = false


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
## The signature carries the parent's `redact_sensitive` even though nothing here is a
## secret: a subclass that quietly narrows an override is a method that is silently the
## parent's at every call site that passes the argument.
func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("smash-copter configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-14s %s" % [key, facts[key]])
	return lines
