extends Node3D

const ScConfig := preload("sc_config.gd")
const ScLayouts := preload("sc_layouts.gd")
const ScTextures := preload("sc_textures.gd")
const ScPaths := preload("sc_paths.gd")

const CHANNEL := "sc.platforms"

## What a platform is doing.
enum State {
	## On its pillar. The ordinary case.
	STANDING,
	## Off its pillar and on the way down, with whoever was on it.
	FALLING,
	## Gone. The pillar may still be standing; see [member ScConfig.pillar_falls_with_platform].
	GONE,
}

## What an impact did, so a caller can decide what to draw and what to say.
enum Impact {
	## It missed, or the platform was already gone.
	NONE,
	## It leaned it. The ordinary case, and most of the round.
	WOBBLE,
	## It leaned it past its own collapse angle.
	TOPPLED,
	## It was big enough to take the platform out in one hit, whatever its health.
	SHATTERED,
}

## A platform came off its pillar. [param why] is one of the WHY_* constants.
signal collapsed(index: int, why: StringName)

## A platform finished falling and has been taken away.
signal removed(index: int)

## Something landed on a platform hard enough to matter.
signal struck(index: int, at: Vector3, impulse: float, outcome: Impact)

const WHY_LEAN := &"lean"        ## Somebody stood in the wrong place for too long.
const WHY_BROKEN := &"broken"    ## Enough impacts added up.
const WHY_SHATTERED := &"shattered"  ## One impact was simply too big.
const WHY_ROUND := &"round"      ## The round asked for the field to be cleared.
const WHY_UNSUPPORTED := &"unsupported"  ## A bridge lost a platform it was resting on.

## One platform: where it is, what it is doing, and the four numbers it is doing it with. An inner
## class rather than parallel arrays: they would be faster for a dozen entries, but one platform's
## whole state would no longer read in one place.
class Deck extends RefCounted:
	## Where the pillar's axis meets the deck plane. The platform pivots about this.
	var centre := Vector3.ZERO

	## Which cell of the layout grid this came from, for logs and for the HUD.
	var column: int = 0
	var row: int = 0

	## Whether this is a walkway between two rows rather than a platform on a pillar.
	var is_bridge: bool = false

	## A tower is a platform that is narrower and stands higher. See [constant ScLayouts.KIND_TOWER].
	var is_tower: bool = false

	## Steps above the ordinary deck height, [constant ScLayouts.LEVEL_RISE] metres each.
	var level: int = 0

	## For a bridge: the platforms it rests on, at its row's end and at the next row's, as
	## deck indices. `-1` where there is none, and a bridge missing either is a free spring.
	var supports := Vector2i(-1, -1)

	## And the world Z of the two lips it rests on, in the same order.
	var lips := Vector2.ZERO

	## Half the platform's side, in metres. Its footprint is a square about [member centre].
	var half: float = 5.25

	var state: int = State.STANDING

	## Radians of lean. `x` tips the +X edge down, `y` tips the +Z edge down.
	var lean := Vector2.ZERO

	## Radians per second.
	var lean_velocity := Vector2.ZERO

	## Metres the whole slab has been pressed down by, and how fast.
	var sink: float = 0.0
	var sink_velocity: float = 0.0

	## What is left of it, in kilogram metres per second of impact.
	var health: float = 1.0

	## Seconds it has been falling.
	var falling_for: float = 0.0

	## The torque the loads on it are applying this tick, in kilogram metres.
	var load_torque := Vector2.ZERO

	## And their total weight, which is what presses it down.
	var load_mass: float = 0.0

	## The body a player's motor actually sweeps against.
	var body: AnimatableBody3D = null

	## The column under it. Kept so it can be taken away with the platform, or not.
	var pillar: StaticBody3D = null

	## The plane normal last time [method ScPlatforms.step] ran, for the carry.
	var previous_normal := Vector3.UP

	## And the height of the pivot, which sink moves.
	var previous_sink: float = 0.0

	func is_standing() -> bool:
		return state == State.STANDING

	## Whether this is a bridge carried by two platforms rather than a spring of its own.
	func is_rested() -> bool:
		return is_bridge and supports.x >= 0 and supports.y >= 0

	## Whether this platform can still be stood on at all.
	func is_live() -> bool:
		return state != State.GONE

	## The surface's normal, from the lean. A lean of `+x` puts the +X edge DOWN, so the normal tips
	## toward +X, the opposite of how it looks: the plane `(sin t, cos t, 0)` through the pivot is lower
	## at `+x`. Writing `-sin` still tips and collapses, in the wrong direction, and nothing errors.
	func normal() -> Vector3:
		return Vector3(sin(lean.x), 1.0, sin(lean.y)).normalized()

	## How far this platform's surface is from level, in radians.
	func tilt() -> float:
		return lean.length()

	func describe() -> Dictionary:
		return {
			"cell": "%d,%d" % [column, row],
			"state": State.keys()[state],
			"lean": "%.1f deg" % rad_to_deg(tilt()),
			"health": "%.0f%%" % (health * 100.0),
		}


@export var config: ScConfig = null

## Whether this instance decides anything. A client runs no model: it is handed a lean and a sink
## twice a second and interpolates, because a floor that disagrees between two machines is a player
## falling through one.
@export var authoritative: bool = true

## Every platform, in layout order. The index is what the wire carries.
var decks: Array[Deck] = []

## The world's gravity, handed in by the game so this file reads one number rather than
## asking a physics space it does not own.
var gravity: float = 20.0

## How slippery the decks are this round. See [member ScConfig.platform_grip].
var grip: float = 1.0

## Multiplies [member ScConfig.platform_stiffness] for a whole round. A special turns it
## down; a layout can too.
var stiffness_scale: float = 1.0

## Node instance id -> deck index, so a motor's `ground_id` answers in one lookup: it is read once
## per player per tick, and walking every deck to match it is the scan dot-entity exists to remove.
var _by_body: Dictionary = {}

var _physics: DotPhysicsLayout = null

## What the configured column spacing was multiplied by for this field.
var _pitch_scale: float = 1.0

## What the configured row spacing is multiplied by. See [member ScLayouts.Layout.row_pitch_scale].
var _row_pitch_scale: float = 1.0

## How far the field is moved along the rows, in row pitches. See [member ScLayouts.Layout.row_shift].
var _row_shift: float = 0.0

## The grid this field was built on. Zero means the config's, which is every layout that
## does not carry a grid of its own.
var _columns: int = 0
var _rows: int = 0

## `(kind, level)` of every non-bridge cell, so a bridge can be sized and set at the height
## of the two pieces it joins.
var _cell_info: Dictionary = {}
