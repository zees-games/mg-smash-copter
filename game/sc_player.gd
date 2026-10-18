extends CharacterBody3D

const ScConfig := preload("sc_config.gd")
const ScFigure := preload("sc_figure.gd")
const ScAvatars := preload("sc_avatars.gd")
const ScPlatforms := preload("sc_platforms.gd")
const ScSpecials := preload("sc_specials.gd")

## One person: how they move, what carries them, what they are holding and whether they
## are still up.
##
## [b]This file is a bridge, and this family's own record says bridges are where the bugs
## are.[/b] Every addon it touches is complete and tested on its own; what has never run
## before is the joins. The three this game adds are all orderings:
##
## - a player standing on a platform has to be carried by it [i]after[/i] the motor has
##   moved them, because the motor writes an absolute position and anything applied before
##   it is simply overwritten;
## - the weight they press into that platform is reported on the same tick they were
##   standing there, not the next one, or a platform leans toward where somebody was;
## - a pilot's movement is turned OFF rather than ignored while they are flying, because
##   two authorities over one transform reads as the machine shaking itself apart.

const CHANNEL := "sc.player"

## Set on a body a player can stand on and be carried by (the chopper), on both ends.
const META_CARRIER := &"sc_carrier"

## Metres above a player's feet that their eyes are.
##
## [b]Here rather than on the client, because it is not a camera height.[/b] It is where a
## shot leaves from and where a platform is judged from. The client puts its camera at it
## and the server resolves every shot from it, and the two being one number is what stops
## a player hitting what they are not looking at.
const EYE_HEIGHT := 1.6

## The action a slow walk is bound to, on top of whatever dot-player-controller registered.
const WALK_ACTION := &"dot_fps_walk"

## This player was run over, blown up, shot, or simply missed.
signal died(by: StringName)

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## What this player looks like, as a dot-user-avatar document; null is the stock person.
##
## Set on a server from the platform — see `sc_module._avatar_for` — and carried to every
## client in JOIN, so a person who chose a face is that face on every screen. Null means
## nobody resolved one, and [method _atlas] falls back to the same hash [ScAvatars] calls
## stock, so a server with no identity layer draws everybody exactly as it always did.
var avatar: DotAvatar = null

## Whether a command is sampled from the input devices each tick.
##
## True for the person at the keyboard, false for a bot and every remote player. A
## property of the PLAYER rather than of the build, because one client holds both.
@export var samples_input: bool = false

## Whether this player is driven by the game rather than by a person.
##
## [b]Separate from [member samples_input], and conflating the two is a bug waiting for
## netcode.[/b] Every remote player also samples nothing; what makes a bot a bot is that
## something here decides for them. A game that drove "everybody who is not sampling"
## would drive every other human on the server the moment a bridge arrived.
@export var is_bot: bool = false

## The world's configuration, so the tunables below come from the same file as the rest of
## the game's numbers. Set by [ScGame] before this enters the tree.
var config: ScConfig = null

var controller: DotFpsController = null
var sampler: DotFpsSampler = null
var health: DotHealth = null

## The weapons, once the showdown has started. Null for the whole survival phase.
##
## [b]Built on the handover rather than at spawn, and that is the round's shape.[/b] There
## is nothing to shoot at on the platforms and nothing that could be shot; a rig that
## existed for the first two minutes would be two minutes of a state machine nobody can
## reach, replicated to every client.
var weapons: ZeeWeaponRig = null

## The field of platforms, so this player can be carried by one. Set by [ScGame].
var platforms: ScPlatforms = null

## Their mass in kilograms, which is what a platform feels them as.
var mass_kg: float = 80.0

## Which side they are on. Read off [ScGame], which owns it.
var team: int = 0

## Whether this player is flying, and so is not walking.
##
## Read-only from outside; [method set_riding] is the switch.
var riding: bool = false

## The entity id dot-combat and dot-entity know them by.
var entity_id: int = 0

## How many times [method place_at] has put them somewhere, rather than moved them there.
## Replicated (`ScPlayerNet.net_warp`), so a watcher's interpolator draws a teleport as one
## instead of as a flight across the map.
var warps: int = 0

## Which platform they were last standing on, or -1. Reported rather than kept, because it
## is the one number that says the carry actually happened.
var standing_on: int = -1

## Which weapon slot they have asked for, from this game's own input message.
##
## [b]Here rather than in [DotFpsCommand], which has no room for it.[/b] A movement command
## is eight buttons and two angles and widening it would be a breaking change across every
## game in the family for a field only this one's second half has. What carries it is
## [ScNetCommand], which is this game's wire type and is free to say whatever this game
## needs — and the arsenal is handed it once a tick like every other intent.
var wanted_slot: int = 0

## Metres this player has been carried by a platform this round.
var carried_metres: float = 0.0

## What the world's specials are doing to them right now. Written by [ScGame] each tick.
var active: ScSpecials.Active = null

## An administrator's `blind`: this player's own screen is blacked out.
##
## [b]Set on the server and replicated to the OWNER ONLY[/b] (`ScPlayerNet.net_blind`).
## Nobody else's screen changes, so nobody else needs to know — and an opponent who could
## read it would know exactly when somebody could not see the cannon's next shot coming, or
## them. `ScHud` draws it.
var blinded: bool = false

## An administrator's `beacon`: a pulsing ring, a column and a ping every client draws and
## hears, until it is turned off.
##
## Set on the server and replicated to everybody (`ScPlayerNet.net_beacon`). Drawn by
## [method present_beacon], which only a client calls.
var beacon: bool = false

## The marker [member beacon] draws, while it does. Client side.
var beacon_marker: DotFxBeacon = null

## What other people see this player as. Client side: built and shown by
## [method present_body], never on a server, which draws nothing.
var figure: ScFigure = null

## How this player's body falls on their death: the server's pick ([method ScGame.decide_death]),
## carried on DEATH and set here before anybody hears of it. Null before a first death.
var death: DotPlayerDeath = null

# --- What a watcher draws in their hand. Client side --------------------------
#
# A player this process SIMULATES (an offline stand-in, or yourself in third person) is read
# off their own rig. One it only MIRRORS has no rig here at all — the server owns it — so it
# is drawn from two things the wire already carries: the weapons the server ANNOUNCED it
# dealt them (`ScEvents.Kind.ARMED`, one per weapon) and the slot the snapshot says is in
# hand. A slot alone names no weapon, because the pack puts several weapons in each slot;
# the dealt list alone does not say which of two is out.

## Whether [member mirror_slot] and the rest are written from a snapshot (`ScPlayerNet`).
var mirrored: bool = false

## The weapons the server said it dealt them, in the order it dealt them.
var dealt: Array[StringName] = []

## The round [member dealt] belongs to: a deal for a new round starts a new list.
var dealt_round: int = -1

var mirror_slot: int = 0
var mirror_switching: bool = false

## Uses the snapshot reported since the figure last drew them, and their kind.
var mirror_fired: int = 0
var mirror_fire_kind: int = 0

## The rig's own counter as the figure last saw it, for a simulated player.
var _seen_fire_seq: int = -1

## Every pack weapon's slot, by id. Built once per process; a slot does not depend on the
## damage table a game passes the pack.
static var _slots: Dictionary = {}

var tick_rate: int = 64:
	set(value):
		tick_rate = value
		if controller != null:
			controller.tick_rate = value


## The key [DotWeaponPlayerBridge] identifies this carrier by.
##
## [b]A property with this exact name, because that bridge is duck-typed.[/b] dot-weapon
## deliberately names no player class — a script that mentions a `class_name` the project
## does not have fails to parse and takes every script referencing it down with it — so
## what it asks for is `player.get("player_key")`. Spelled anything else, every shot in
## the showdown comes from entity zero, which dot-combat reads as "the world".
var player_key: String:
	get:
		return String(player_id)


func _ready() -> void:
	controller = DotFpsController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate

	# EXTERNAL rather than LOCAL even offline: the game owns the tick, so the order
	# "sample, move, then ride whatever you are standing on" is explicit here rather than
	# happening inside somebody else's loop. It is also the shape a dedicated server and a
	# net bridge need, so nothing has to be rearranged when one arrives.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = tunables_for(config, active)
	# Every player, both ends: an admin's noclip or freeze is a modifier whose index
	# travels on the wire. See dot-player-controller's DotFpsAdminModifiers.
	controller.admin_abilities = true
	add_child(controller)

	controller.simulated.connect(_on_simulated)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		register_actions(sampler)


## How a player moves, and the two decisions in it.
##
## [b]Static, and it takes the config, and neither was true in the game this was copied
## from until it cost something.[/b] Static because a connected client has to build a
## sampler before it has a player — the local player arrives in a JOIN, several frames
## after the keyboard does — and a sampler built from different tunables than the
## controller it feeds is a client whose own input is clamped differently from the
## simulation that consumes it.
##
## [param active] is what the round's specials are doing. Null is an ordinary round.
static func tunables_for(config: ScConfig, active: ScSpecials.Active) -> DotFpsTunables:
	var t := DotFpsTunables.new()
	var run := config.run_speed if config != null else 6.4
	var gravity := config.gravity if config != null else 20.0
	var grip := 1.0

	if active != null:
		run *= active.run_speed_scale
		gravity *= active.gravity_scale
		grip = active.grip_scale

	# [b]No bunny hopping.[/b] Every other 3D game in this family turns auto-hop on because
	# their genres are about carrying speed. This one is about a top speed that decides how
	# hard you lean the floor: a player who could chain hops would cross a platform faster
	# than the walk key can save them and the one control this game is built around would
	# stop mattering.
	t.auto_hop = false
	t.max_speed = run

	# [b]Shift is a brake, not a sprint, and it is the opposite of every other game
	# here.[/b] Running is the default and it is what destabilises a platform — see
	# [member ScConfig.platform_motion_gain] — so the only way across a platform somebody
	# else is already standing on is to slow down. Binding that to the key every player
	# holds down to go faster is the joke the map this game is built from is made of.
	t.walk_speed_scale = config.walk_speed_scale if config != null else 0.42
	t.can_walk = true
	# Off, so shift cannot be a sprint by another name and the fastest anybody moves is
	# the speed the platforms were tuned against.
	t.can_sprint = false
	t.can_crouch = true
	t.crouch_speed_scale = 0.38

	# Ice is a special round, and it is the ground friction that makes it one. At 0.2 grip
	# a player who stops pressing forward keeps going, which on a ten-metre platform with a
	# lean on it is most of the way to the edge.
	t.accelerate = 11.0 * clampf(grip, 0.05, 4.0)
	t.friction = 7.5 * clampf(grip, 0.05, 4.0)
	t.stop_speed = 3.0

	t.air_accelerate = 44.0
	t.max_air_wish_speed = 1.8
	t.gravity = gravity
	t.jump_height = config.jump_height if config != null else 1.15

	t.coyote_time = 0.09
	t.jump_buffer_time = 0.1

	# [b]Below the angle a platform collapses at, and that ordering is the design.[/b] A
	# platform comes off its pillar at about sixteen degrees and a player slides off at
	# fourteen, so the floor is already throwing people before it goes — which is the
	# warning that makes a collapse survivable for somebody who was paying attention.
	t.max_slope_angle = 14.0
	# Enough to step onto a crate that has landed flat, which is what makes a prop cover
	# rather than an obstacle.
	t.step_height = 0.45

	return t


## The clear air a running player crosses in one jump, landing [param rise] metres
## higher than they left, in metres.
##
## [b]Read off [method tunables_for] rather than off three copied constants, and worked
## out by [method DotFpsTunables.jump_reach] rather than by a copy of its arithmetic.[/b]
## The run speed, the gravity and the apex come from the one function the controller
## itself is built from, so a cvar that shortens the jump shortens this too.
##
## [b]The landing height is the whole point.[/b] The airtime everybody writes down is the
## time to fall back to the height you jumped FROM, and on this map the height you jump from
## is never the deck height: a runner leans the platform toward the edge they are running
## at, so the lip they leave from is lower than the one they are aiming for. That dip is
## [param rise], and it is measured by the suite from [ScPlatforms]' own model rather than
## guessed. Returns 0.0 for a rise no jump clears at all.
static func jump_reach(config: ScConfig, rise: float, p_active: ScSpecials.Active = null) -> float:
	return tunables_for(config, p_active).jump_reach(rise)


## Registers the movement actions, and binds the slow walk to shift.
##
## [b]dot-player-controller puts walk on alt and sprint on shift, which is the sensible
## default and the wrong one here.[/b] This game has no sprint and its walk is the control
## the whole first objective turns on, so shift is added to the walk action rather than a
## player being asked to learn a new finger. The existing binding is left alone: a project
## with its own input map keeps it, which is the addon's own rule.
static func register_actions(sampler: DotFpsSampler = null) -> void:
	var _added := DotFpsSampler.register_default_actions(sampler)

	if not InputMap.has_action(WALK_ACTION):
		return

	for event in InputMap.action_get_events(WALK_ACTION):
		var key := event as InputEventKey

		if key != null and key.physical_keycode == KEY_SHIFT:
			return

	var shift := InputEventKey.new()
	shift.physical_keycode = KEY_SHIFT
	InputMap.action_add_event(WALK_ACTION, shift)


## Called once per simulated tick by the world.
## Offline only: puts the client's buttons (fire, reload...) on the command [member sampler] has
## just made. Stamped here, after sampling: the client used to stamp
## `controller.current_command` from its own physics frame, and this function then applied a
## fresh sample over it, so offline no trigger ever reached the world's rig and no shot of the
## player's landed (game-zombie-zone's play test found it; its docs/history.md has the story).
var command_stamp: Callable = Callable()


func simulate(tick: int, delta: float) -> void:
	# The world calls this by name, so a body the load gate froze is skipped here.
	if is_inside_tree() and not can_process():
		return

	if sampler != null:
		# Settling under the cover runs the body with its input off (falls, lands, no keys).
		var gate := DotLoadGate.of(self) if is_inside_tree() else null
		var sampled := sampler.sample(delta) if gate == null or gate.is_open() else DotFpsCommand.new()

		if command_stamp.is_valid():
			command_stamp.call(sampled)

		controller.apply_command(sampled)

	# Sampled above and then dropped: those same keys are what a chopper is flown with,
	# and the world reads the pending command out for that. Not simulating is what stops
	# the controller writing its own answer into a transform the vehicle owns.
	if riding:
		return

	controller.simulate_tick(tick, delta)


## After the move, which is the only place the carry can go.
func _on_simulated(_tick: int, state: DotFpsState) -> void:
	global_position = state.position

	standing_on = -1

	if platforms == null:
		return

	# [b]`ground_id` is the whole mechanism, and it is deliberately not simulation
	# state.[/b] [DotFpsState] documents it as a local physics handle whose value differs
	# between machines — which is exactly right for this: being carried is resolved per
	# frame from a handle each machine has, rather than becoming another predicted field
	# two machines would have to agree about. They could not: a platform's collider is
	# moved by whichever end is authoritative.
	var index := platforms.index_of_body(state.ground_id)

	if index < 0:
		_carry_on_body(state)
		return

	_ride_id = 0

	standing_on = index

	var lift := platforms.lift_at(index, state.position.x, state.position.z)

	if is_zero_approx(lift):
		return

	global_position.y += lift

	# Written back into the state as well as onto the node. The controller starts the next
	# tick from `state.position`, so a displacement applied only to the node is undone by
	# the very next move — the player would ride the platform for exactly one frame each
	# tick and stand still overall, which looks like the platform sliding out from under
	# them rather than like anything being wrong.
	state.position = global_position
	carried_metres += absf(lift)


## The body this player was standing on last tick, and where it was, so that a machine that
## has moved since takes them with it.
var _ride_id: int = 0
var _ride_was := Transform3D.IDENTITY


## Carries a player standing on a body that moves: a helicopter.
##
## [b]By the body's own motion over the tick, applied to the player's position.[/b] The
## motor sweeps a capsule against a world that stood still, so a floor that moves is a floor
## the player slides off the back of: a chopper's rotor wash would leave everybody on its
## skids behind in the sky. The platforms carry vertically ([method ScPlatforms.lift_at])
## because they only ever move vertically; a machine flies every way and turns, so this is
## the whole transform, which also swings a rider round with its yaw.
##
## The first tick on a body only remembers where it is: there is nothing to have moved yet,
## and a transform taken against the identity would throw them to the world's origin.
func _carry_on_body(state: DotFpsState) -> void:
	var body := instance_from_id(state.ground_id) as Node3D if state.ground_id != 0 else null

	if body == null or not body.has_meta(META_CARRIER):
		_ride_id = 0
		return

	var now := body.global_transform

	if _ride_id != state.ground_id:
		_ride_id = state.ground_id
		_ride_was = now
		return

	var moved := now * _ride_was.affine_inverse()
	_ride_was = now
	var carried := moved * state.position
	var shift := carried - state.position

	# A body that is only settling, or a frame where nothing moved, is not worth writing back.
	if shift.length_squared() < 0.0000001:
		return

	global_position = carried
	state.position = carried


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## How fast they are moving over the ground, which is what a platform charges them for.
func ground_speed() -> float:
	var velocity := controller.state.velocity
	return Vector2(velocity.x, velocity.z).length()


## Where this player's eyes are, in the world.
##
## [b]From the simulated state and not from the node.[/b] The node is where the last frame
## drew them, which on an interpolating client is between two ticks; the state is where
## the tick being resolved put them. A shot aimed from the node is a shot aimed from a
## position no tick ever had.
func eye_position() -> Vector3:
	return controller.state.position + Vector3(0.0, EYE_HEIGHT, 0.0)


## The duck-typed component lookup dot-weapon's player bridge asks a carrier for.
##
## [b]Without this, every shot in the showdown left the player's FEET pointing due
## north.[/b] [DotWeaponPlayerBridge] takes a shot's origin and aim from an eye transform,
## and it looks for one in three places in order: a controller switch, a
## `DotPlayerController`, then a `DotPlayerChar`. Each of those is reached through
## `player.component(name)` — and a player with no `component` method fails all three and
## falls back to the BODY transform, which in this game is the right position and an
## identity basis, because the yaw lives in the controller's state and never in the node.
##
## A shot with the right origin and a fixed direction is the worst of the three outcomes: it
## is not obviously broken from any single number, it survives every check that a weapon
## fires, and what a player sees is a gun that works and never hits anything.
##
## [b]`DotFpsController` as well as `DotPlayerController`, because a name is not a
## hierarchy.[/b] The bridge asks for the base and this game holds the first-person
## subclass; matching only the exact string is how a seam like this quietly stops working
## when somebody swaps a controller for a more specific one.
func component(type_name: StringName) -> Object:
	match String(type_name):
		"DotPlayerController", "DotFpsController":
			return controller
		"DotHealth":
			return health
		"ZeeWeaponRig":
			return weapons
		_:
			return null


## Which way they are looking, as a unit vector.
##
## Built from yaw and pitch rather than read off a camera, because a server has no camera,
## a bot has no camera and a headless test has no camera, and all three have to aim.
func aim_direction() -> Vector3:
	var view := Basis.from_euler(Vector3(
		deg_to_rad(controller.state.pitch), deg_to_rad(controller.state.yaw), 0.0
	))
	return -view.z


## Gets into or out of a chopper.
##
## Both halves matter and the second is the one that is easy to leave out: a pilot put
## back on their feet still carrying the machine's velocity is thrown across the map on
## their first step — and off it, which in this game is fatal.
func set_riding(value: bool) -> void:
	if riding == value:
		return

	riding = value
	controller.state.velocity = Vector3.ZERO

	# DEBUG: a state transition. Who boards is decided (and would be refused) in [ScGame];
	# this is where the movement actually hands over, which is what a report of a pilot
	# who "fell out" needs lined up against.
	DotLog.debug(CHANNEL, "took a chopper's controls" if riding else "left a chopper's controls", {
		"id": String(player_id),
	})

	if not riding:
		controller.state.mode = DotFpsState.Mode.AIR


## Puts a player somewhere, facing somewhere, with nothing carried over.
##
## [b]The state and the node together, and the velocity cleared.[/b] The showdown teleport
## moves everybody sixty metres in one tick; a player who arrived still carrying the fall
## they were in the middle of would arrive already dying.
func place_at(at: Vector3, yaw_degrees: float) -> void:
	warps += 1
	global_position = at

	# Through `teleport` rather than by writing the state, because it also resets the tick
	# the client draws FROM. The camera is drawn between the last two ticks, and a state
	# written by hand leaves the previous one where the player was — so the handover to the
	# corners would sweep the view across the map for a frame.
	controller.teleport(at, yaw_degrees, 0.0)

	if sampler != null:
		sampler.look_at_angles(yaw_degrees, 0.0)

	# [b]And into the pending COMMAND, which is what the next tick actually reads.[/b] The
	# motor takes its view from the command rather than from the state, and repeats the last
	# command when it is handed none — so a teleport that wrote only the state is undone on
	# the very next tick by an empty command carrying a yaw of zero. The suite found this as
	# survivors arriving in their corner facing due north whatever corner it was: every
	# position correct, every facing wrong, and nothing anywhere to say so.
	var facing := DotFpsCommand.new()
	facing.yaw = yaw_degrees
	facing.pitch = 0.0
	controller.apply_command(facing)


## Puts the movement back on numbers the current round is being played with.
##
## Called when a special starts or ends. [b]The tunables object is replaced rather than
## edited, because the controller keeps a fingerprint of it[/b] and a client whose
## tunables differ from the server's diverges every tick — with a symptom, constant small
## corrections, that looks exactly like ordinary packet loss.
func retune(p_active: ScSpecials.Active) -> void:
	active = p_active

	if controller == null:
		return

	controller.tunables = tunables_for(config, active)

	if sampler != null:
		sampler.tunables = controller.tunables


## Whether they are up.
func is_alive() -> bool:
	return health == null or health.alive


## Draws [member beacon] at [param at], and says whether it pinged this frame.
##
## [b]Called by the client, once a frame, for every player it knows.[/b] Never by the world:
## a dedicated server draws nothing, and a marker built there would be three meshes and a
## sound player per beaconed player that nobody will ever see.
##
## [b]Only while alive.[/b] The flag outlives a fall — the tools re-apply it on the next
## round — but a ring round somebody who is out marks nothing, and a column over the last
## place a faller was points everybody at empty air.
##
## [param at] is the DRAWN position: the render state for the local player and the
## interpolated one for anybody else, for the reason the marker is top level.
## [param local_view] hides the column on the beaconed player's own screen.
func present_beacon(delta: float, at: Vector3, local_view: bool) -> bool:
	if not beacon or not is_alive():
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return false

	if beacon_marker == null:
		beacon_marker = DotFxBeacon.new()
		beacon_marker.name = "Beacon"
		add_child(beacon_marker)

	beacon_marker.local_view = local_view
	beacon_marker.global_position = at
	return beacon_marker.advance(delta)


## Draws this player's body for one frame at [param at], the position this frame draws them.
## Client side, once a frame, from `ScClient.present_frame`. Returns whether it is shown.
##
## [b]Shown for everybody except three people[/b], and each is a rule rather than a saving:
##
## - [b]the one the camera belongs to, in first person[/b] ([param own_view]) — a body drawn
##   round a camera is the inside of somebody's head. In third person it is the one body the
##   player most needs, because it is what tells them where on the platform they are;
## - [b]a pilot[/b], who is drawn AS the chopper. `ride.carry_rider_nodes` is off, so nothing
##   moves a rider's node or state while they fly — see [method set_riding] — and a body
##   left standing would be somebody frozen on the pad they climbed in from for the rest of
##   the round, while the machine they are actually flying goes somewhere else;
## - [b]somebody who is out[/b]. A faller is out until the next round, and a body standing
##   where they went over the edge would be a player nobody can shoot.
##
## [param team_colour] is their side's, on the torso; see [ScFigure].
func present_body(own_view: bool, at: Vector3, team_colour: Color) -> bool:
	var shown := not own_view and not riding and is_alive()

	if figure == null:
		# Built lazily and only once there is something to show, so a client never builds a
		# figure for its own first-person player.
		if not shown:
			return false

		figure = ScFigure.new()
		figure.name = "Figure"
		add_child(figure)

	var atlas := _atlas()

	if figure.atlas != atlas or not figure.team_colour.is_equal_approx(team_colour):
		# Rebuilt on a side change, which a moderator's `team` does between rounds, and on
		# a new face — which a profile arriving after the player was seated is.
		var height := controller.tunables.stand_height \
			if controller != null and controller.tunables != null else 1.8
		figure.build(height, atlas, team_colour)

	figure.visible = shown

	if shown:
		_present_held()

	if shown and controller != null:
		var velocity := controller.state.velocity
		figure.set_motion({
			"on_floor": controller.state.mode == DotFpsState.Mode.GROUND,
			"vertical": velocity.y,
			"crouched": controller.state.crouch_fraction > 0.5,
			# The view's pitch: the upper body, the arms and the weapon follow it.
			"aim": deg_to_rad(controller.state.pitch),
		})
		figure.pose(
			at,
			deg_to_rad(controller.state.yaw),
			Vector2(velocity.x, velocity.z).length()
		)

	return shown


## Records a weapon the server dealt them. [param round_number] is the client's round.
func note_dealt(weapon_id: StringName, round_number: int) -> void:
	if round_number != dealt_round:
		dealt.clear()
		dealt_round = round_number

	if not dealt.has(weapon_id):
		dealt.append(weapon_id)


## Tells the figure what is in this player's hand this frame, and whether it went off.
func _present_held() -> void:
	var rig := _rig()
	var id := &""
	var switching := false
	var fired := 0
	var kind := 0

	if rig != null and rig.arsenal != null:
		var def := rig.arsenal.current_def()
		id = def.id if def != null else &""
		switching = rig.arsenal.is_switching()
		var seq := rig.fire_seq % ZeeWeaponNet.FIRE_SEQ_WRAP
		fired = ZeeWeaponNet.uses_between(_seen_fire_seq, seq) if _seen_fire_seq >= 0 else 0
		_seen_fire_seq = seq
		kind = rig.fire_kind
	elif mirrored:
		id = held_by_slot(dealt, mirror_slot)
		switching = mirror_switching
		fired = mirror_fired
		kind = mirror_fire_kind

	mirror_fired = 0
	figure.hold(id, switching)
	figure.fired(fired, kind)


## Which of [param ids] is in [param slot], or nothing. The first dealt wins a shared slot,
## which is the one the server selects at the handover.
static func held_by_slot(ids: Array[StringName], slot: int) -> StringName:
	if slot <= 0 or ids.is_empty():
		return &""

	if _slots.is_empty():
		for def in ZeeWeaponPack.weapons():
			_slots[def.id] = def.slot

	for id in ids:
		if int(_slots.get(id, -1)) == slot:
			return id

	return &""


## The rig this process simulates them with: the server's, an offline stand-in's, or the
## one a networked client builds for its own player's hands (`ScClient._arm_locally`, which
## hangs it on the player without setting [member weapons], because a client must not hand
## its rig to the simulation's lookups).
func _rig() -> ZeeWeaponRig:
	if weapons != null:
		return weapons

	return get_node_or_null(^"Weapons") as ZeeWeaponRig


## Which atlas this player wears: their avatar's skin, or the one their id hashes to.
##
## From the id rather than a random draw, so every client dresses the same person the same
## way; a document naming a skin this build lacks falls back to that rather than to a
## guess. [ScAvatars.SKINS] is the atlas list's order, which `headless_run` holds it to.
func _atlas() -> String:
	var index := ScAvatars.skin_index(avatar)

	if index < 0 or index >= ScFigure.ATLASES.size():
		index = ScAvatars.stock_index(player_id)

	return str(ScFigure.ATLASES[index])


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"team": team,
		"alive": is_alive(),
		"health": health.health if health != null else 0.0,
		"riding": riding,
		"on": standing_on,
		"carried": "%.1f m" % carried_metres,
		"armed": weapons != null,
		"blinded": blinded,
		"beacon": beacon,
		"avatar": avatar.digest() if avatar != null else "stock",
		"figure": figure.describe() if figure != null else {},
	}
