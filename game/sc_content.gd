extends RefCounted

const ScConfig := preload("sc_config.gd")
const ScPaths := preload("sc_paths.gd")

## The two catalogues: what the cannon throws, and what a player can fly.
##
## [b]Eight props in four tiers, and the tiers are the whole of the cannon's design.[/b]
## A crate wobbles a platform, a boulder tips it, a container takes a corner off it and a
## monolith deletes it with everybody standing on it. Every one of those outcomes comes out
## of two numbers on a definition — the mass and the size — through one model in
## [ScPlatforms], rather than out of a rule per prop. That is what lets a server retune the
## whole feel of the round by editing a document, and what lets the suite assert the design
## instead of the code.

## Where the bodies live, as this game was authored.
##
## [b]Rebased where they are defined, so no use of them can forget to.[/b] A delivered pack
## mounts at `res://dot_cloud/<id>/<version>/`, so an absolute path to this game's OWN files
## resolves against the host project root — which holds another game's props, or nothing.
## They were `const`s rebased at every call site, which was correct and was also one new
## call site away from not being: `static var` is the only spelling that can hold the
## rebased value, because a `const` cannot call.
static var CRATE_SCENE := ScPaths.rebase("res://props/sc_crate.tscn")
static var TYRE_SCENE := ScPaths.rebase("res://props/sc_tyre.tscn")
static var CONE_SCENE := ScPaths.rebase("res://props/sc_cone.tscn")
static var BARREL_SCENE := ScPaths.rebase("res://props/sc_barrel.tscn")
static var BOULDER_SCENE := ScPaths.rebase("res://props/sc_boulder.tscn")
static var CONTAINER_SCENE := ScPaths.rebase("res://props/sc_container.tscn")
static var SLAB_SCENE := ScPaths.rebase("res://props/sc_slab.tscn")
static var MONOLITH_SCENE := ScPaths.rebase("res://props/sc_monolith.tscn")
static var COPTER_SCENE := ScPaths.rebase("res://props/sc_copter.tscn")

const CRATE := &"crate"
const TYRE := &"tyre"
const CONE := &"cone"
const BARREL := &"barrel"
const BOULDER := &"boulder"
const CONTAINER := &"container"
const SLAB := &"slab"
const MONOLITH := &"monolith"
const COPTER := &"copter"

## The meta key every prop here carries. See [method tier_of].
const META_TIER := &"tier"

## How many tiers there are. Four, and [ScConfig]'s two weight tables are this long.
const TIERS := 4

## Who owns anything the world puts out itself.
##
## [b]Not the empty string, which dot-props reads as a player.[/b] `may_spawn` charges the
## owner's budget, and an owner of `&""` is one account holding every prop in the round —
## so the world's own furniture would run into a per-player limit that exists to stop
## somebody leaning on a spawn key.
const WORLD_OWNER := &"world"


## Everything the cannon and the chopper can throw.
static func props(_config: ScConfig) -> DotPropCatalogue:
	var catalogue := DotPropCatalogue.new()

	# --- Tier one: it wobbles ------------------------------------------------
	#
	# [b]Survivable by standing still, and that is what it teaches.[/b] The first twenty
	# seconds of a round are only crates, so a player learns the one rule — a platform
	# leans toward the load on it — while the cost of learning it is a stumble.

	var crate := DotPropDef.make(CRATE, CRATE_SCENE)
	crate.display_name = "Crate"
	crate.category = &"debris"
	crate.size = DotPropDef.Size.SMALL
	crate.mass = 35.0
	crate.rideable = true
	crate.max_health = 60.0
	# Below what a tier-three prop arrives at, so a big one lands on a crate and through
	# it rather than balancing on it. A crate that stopped a container would be a crate
	# that saved a platform, which is the wrong lesson entirely.
	crate.break_impact_speed = 16.0
	crate.meta = {META_TIER: 1}
	catalogue.add(crate)

	var tyre := DotPropDef.make(TYRE, TYRE_SCENE)
	tyre.display_name = "Tyre"
	tyre.category = &"debris"
	tyre.size = DotPropDef.Size.SMALL
	tyre.mass = 28.0
	tyre.rideable = true
	# Indestructible, and it is the only tier-one prop that is. A tyre ROLLS: it lands,
	# it keeps going, and where it ends up is decided by the lean of the platform it
	# landed on — which makes it the one prop that tells a player which way the floor is
	# going before they can feel it.
	tyre.max_health = 0.0
	tyre.meta = {META_TIER: 1}
	catalogue.add(tyre)

	var cone := DotPropDef.make(CONE, CONE_SCENE)
	cone.display_name = "Cone"
	cone.category = &"debris"
	cone.size = DotPropDef.Size.SMALL
	cone.mass = 15.0
	cone.rideable = false
	cone.max_health = 25.0
	cone.break_impact_speed = 12.0
	cone.meta = {META_TIER: 1}
	catalogue.add(cone)

	# --- Tier two: it tips ---------------------------------------------------

	var barrel := DotPropDef.make(BARREL, BARREL_SCENE)
	barrel.display_name = "Barrel"
	barrel.category = &"hazard"
	barrel.size = DotPropDef.Size.SMALL
	barrel.mass = 60.0
	barrel.rideable = true
	# A third of a crate's health, because the point of a barrel is that everything sets
	# it off — a landing, a fall, and another barrel.
	barrel.max_health = 22.0
	barrel.break_impact_speed = 7.0
	barrel.explode_radius = 6.0
	barrel.explode_damage = 85.0
	barrel.explode_force = 1100.0
	barrel.meta = {META_TIER: 2}
	catalogue.add(barrel)

	var boulder := DotPropDef.make(BOULDER, BOULDER_SCENE)
	boulder.display_name = "Boulder"
	boulder.category = &"debris"
	boulder.size = DotPropDef.Size.MEDIUM
	boulder.mass = 110.0
	boulder.rideable = true
	boulder.max_health = 0.0
	boulder.meta = {META_TIER: 2}
	catalogue.add(boulder)

	# --- Tier three: it takes a corner off -----------------------------------

	var container := DotPropDef.make(CONTAINER, CONTAINER_SCENE)
	container.display_name = "Container"
	container.category = &"debris"
	container.size = DotPropDef.Size.LARGE
	container.mass = 260.0
	container.rideable = true
	container.max_health = 0.0
	container.meta = {META_TIER: 3}
	catalogue.add(container)

	var slab := DotPropDef.make(SLAB, SLAB_SCENE)
	slab.display_name = "Slab"
	slab.category = &"debris"
	slab.size = DotPropDef.Size.LARGE
	slab.mass = 340.0
	slab.rideable = true
	slab.max_health = 0.0
	slab.meta = {META_TIER: 3}
	catalogue.add(slab)

	# --- Tier four: it deletes the platform ----------------------------------
	#
	# [b]Rare, and it has to be rare to work.[/b] A map where every fourth shot removes a
	# platform outright is a map nobody survives a minute of; at one shot in twenty it is
	# the thing a round is remembered for. See [member ScConfig.cannon_tier_weights].

	var monolith := DotPropDef.make(MONOLITH, MONOLITH_SCENE)
	monolith.display_name = "Monolith"
	monolith.category = &"debris"
	monolith.size = DotPropDef.Size.HUGE
	monolith.mass = 900.0
	# Not rideable, and that is a mercy rather than a detail: a slab that lands flat and
	# can be stood on would be the safest place on a map it has just destroyed.
	monolith.rideable = false
	monolith.max_health = 0.0
	monolith.meta = {META_TIER: 4}
	catalogue.add(monolith)

	return catalogue


## Which tier a definition belongs to, or zero for anything that is not a cannon prop.
##
## [b]Read out of the meta rather than off a parallel list.[/b] This family has shipped the
## same list twice and watched the copies drift; a tier that lives on the definition
## travels with it into a JSON file an operator edits.
static func tier_of(def: DotPropDef) -> int:
	if def == null:
		return 0

	return int(def.meta.get(META_TIER, 0))


## Every prop id in a tier, in catalogue order.
static func ids_in_tier(catalogue: DotPropCatalogue, tier: int) -> Array[StringName]:
	var out: Array[StringName] = []

	if catalogue == null:
		return out

	for def in catalogue.props:
		if tier_of(def) == tier:
			out.append(def.id)

	return out


## The chopper, and nothing else.
##
## [b]`CUSTOM` with a chassis script, because neither shipped chassis is a helicopter.[/b]
## [DotVehicleWheeled] needs wheels on the ground and [DotVehicleHover] refuses to thrust
## when its rays find nothing under them — which is correct for a hovercraft and is exactly
## the state a helicopter spends its life in. `chassis_script_path` is the extension point
## dot-vehicle documents for a fourth kind, and [ScCopter] is one.
static func vehicles(config: ScConfig) -> DotVehicleCatalogue:
	var catalogue := DotVehicleCatalogue.new()

	var copter := DotVehicleDef.new()
	copter.id = COPTER
	copter.display_name = "Chopper"
	copter.category = &"aircraft"
	copter.scene_path = COPTER_SCENE
	copter.chassis_script_path = ScPaths.rebase("res://game/sc_copter.gd")
	copter.kind = DotVehicleDef.Kind.CUSTOM
	# Indestructible. There is no weapon in the survival phase and the showdown happens
	# somewhere else, so the only thing that could destroy one is the cannon — and a
	# chopper deleted by a crate is two players out of the round for a reason they could
	# not see coming and could not have avoided.
	copter.max_health = 0.0

	var tunables := DotVehicleTunables.new()
	tunables.mass = 1400.0
	# Read off the configuration rather than written here. `chopper_speed` is a cvar an
	# operator turns between rounds and a tunable that ignored it would be a number
	# accepted, reported and never used — this family's most-repeated bug.
	tunables.top_speed = config.chopper_speed
	# The thrust that reaches that speed against the lateral damping [ScCopter] applies.
	tunables.engine_force = 26000.0
	tunables.brake_force = 18000.0
	tunables.handbrake_force = 30000.0
	tunables.steering_limit_deg = 60.0
	tunables.steering_rate_deg = config.chopper_yaw_rate
	tunables.steering_speed_falloff = 1.0
	# Unused by [ScCopter] — a helicopter has no suspension — but validated by
	# [DotVehicleTunables], so they are left at something that passes rather than at zero.
	tunables.suspension_travel = 0.25
	tunables.suspension_stiffness = 45.0
	tunables.centre_of_mass_drop = 1.2
	# The chopper's drag: dot-vehicle writes this onto the body in REPLACE mode at bind (since
	# 4f4afaf). 0.22 is what it flew with before: its own 0.12 COMBINED with the project's 0.1.
	tunables.linear_damp = 0.22
	# High, because getting out of a helicopter is jumping out of one. The refusal exists
	# so nobody leaves a car at 80 km/h; here the fall is the point.
	tunables.max_exit_speed = 40.0
	tunables.allow_exit_when_inverted = true
	copter.tunables = tunables

	var pilot := DotVehicleSeat.new()
	pilot.id = &"pilot"
	pilot.display_name = "Pilot"
	pilot.drives = true
	pilot.attach_path = ^"PilotSeat"
	pilot.may_aim = true
	# The pilot's trigger drops a prop rather than firing a weapon — see
	# [member ScConfig.chopper_may_drop] — and that is the game's rule, not the seat's.
	pilot.may_fire = false
	pilot.exit_offsets = [
		Vector3(-2.4, 0.0, 0.0),
		Vector3(2.4, 0.0, 0.0),
		Vector3(0.0, -2.6, 0.0),
	]
	pilot.exit_clearance = 0.5

	var gunner := DotVehicleSeat.new()
	gunner.id = &"rider"
	gunner.display_name = "Rider"
	gunner.drives = false
	gunner.attach_path = ^"RiderSeat"
	gunner.may_aim = true
	# [b]True, and it is what makes the second seat worth taking in the showdown.[/b] A
	# passenger who can lean out and shoot turns a chopper from a taxi into a gun platform
	# with somebody else's hands on the controls.
	gunner.may_fire = true
	gunner.exit_offsets = [
		Vector3(2.4, 0.0, 0.0),
		Vector3(-2.4, 0.0, 0.0),
		Vector3(0.0, -2.6, 0.0),
	]
	gunner.exit_clearance = 0.5

	copter.seats = [pilot, gunner]

	catalogue.add(copter)
	return catalogue
