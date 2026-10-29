extends CharacterBody3D

const ScConfig := preload("sc_config.gd")
const ScFigure := preload("sc_figure.gd")
const ScAvatars := preload("sc_avatars.gd")
const ScPlatforms := preload("sc_platforms.gd")
const ScSpecials := preload("sc_specials.gd")

## One person: how they move, what carries them, what they are holding and whether they are still up.
##
## This file is a bridge, so its risks are orderings: a platform carries the player after the motor moves them (the motor writes an absolute position), their weight is reported the same tick, and a pilot's movement is turned off rather than ignored (two authorities over one transform shake it apart).

const CHANNEL := "sc.player"

## Set on a body a player can stand on and be carried by (the chopper), on both ends.
const META_CARRIER := &"sc_carrier"

## Metres above a player's feet that their eyes are.
##
## Not a camera height: shots leave from it and platforms are judged from it, so client camera and server shot resolution must share one number.
const EYE_HEIGHT := 1.6

## The action a slow walk is bound to, on top of whatever dot-player-controller registered.
const WALK_ACTION := &"dot_fps_walk"

## This player was run over, blown up, shot, or simply missed.
signal died(by: StringName)

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## What this player looks like, as a dot-user-avatar document; null is the stock person.
##
## Set on a server from the platform (`sc_module._avatar_for`) and carried to every client in JOIN; [method _atlas] falls back to the stock hash when null.
var avatar: DotAvatar = null

## Whether a command is sampled from the input devices each tick.
##
## True for the person at the keyboard, false for a bot and every remote player; per player, not per build, because one client holds both.
@export var samples_input: bool = false

## Whether this player is driven by the game rather than by a person.
##
## Separate from [member samples_input]: remote players also sample nothing, and driving "everybody not sampling" would drive every other human.
@export var is_bot: bool = false

## The world's configuration, so the tunables below come from the same file as the rest of
## the game's numbers. Set by [ScGame] before this enters the tree.
var config: ScConfig = null

var controller: DotFpsController = null
var sampler: DotFpsSampler = null
var health: DotHealth = null

## The weapons, once the showdown has started. Null for the whole survival phase.
##
## Built on the handover rather than at spawn: there is nothing to shoot on the platforms, so an earlier rig would be a replicated state machine nobody can reach.
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
## Here, not in [DotFpsCommand]: widening it would break every game for a field only this one's second half has. [ScNetCommand] carries it.
var wanted_slot: int = 0

## Metres this player has been carried by a platform this round.
var carried_metres: float = 0.0

## What the world's specials are doing to them right now. Written by [ScGame] each tick.
var active: ScSpecials.Active = null

## An administrator's `blind`: this player's own screen is blacked out.
##
## Set on the server and replicated to the OWNER ONLY (`ScPlayerNet.net_blind`); an opponent who could read it would know when someone cannot see. `ScHud` draws it.
var blinded: bool = false

## An administrator's `beacon`: a pulsing ring, a column and a ping every client draws and hears, until it is turned off.
##
## Replicated to everybody (`ScPlayerNet.net_beacon`); drawn by [method present_beacon], which only a client calls.
var beacon: bool = false

## The marker [member beacon] draws, while it does. Client side.
var beacon_marker: DotFxBeacon = null

## What other people see this player as. Client side: built and shown by
## [method present_body], never on a server, which draws nothing.
var figure: ScFigure = null

## How this player's body falls on their death: the server's pick ([method ScGame.decide_death]),
## carried on DEATH and set here before anybody hears of it. Null before a first death.
var death: DotPlayerDeath = null

# What a watcher draws in their hand. Client side.
# A player this process simulates is read off its own rig; one it only mirrors has no rig here, so it is drawn from the weapons the server ANNOUNCED (`ScEvents.Kind.ARMED`) and the slot the snapshot says is in hand. Neither alone names the weapon.

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
## Exactly this name, because the bridge is duck-typed (`player.get("player_key")`) to avoid naming a player class; spelled otherwise, every showdown shot comes from entity zero, which dot-combat reads as "the world".
var player_key: String:
	get:
		return String(player_id)


func _ready() -> void:
	controller = DotFpsController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate

		# EXTERNAL even offline: the game owns the tick, so "sample, move, then ride what you stand on" is explicit, and a dedicated server and net bridge need that shape anyway.
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
## Static and given the config because a connected client builds a sampler before it has a player (the JOIN arrives frames after the keyboard); a sampler with different tunables than its controller clamps input differently from the simulation. [param active] is the round's specials; null is an ordinary round.
static func tunables_for(config: ScConfig, active: ScSpecials.Active) -> DotFpsTunables:
	# The platforms and gaps are tuned against the legacy movement profile, not the classic default.
	var t := DotFpsTunables.with_profile("legacy")
	var run := config.run_speed if config != null else 6.4
	var gravity := config.gravity if config != null else 20.0
	var grip := 1.0

	if active != null:
		run *= active.run_speed_scale
		gravity *= active.gravity_scale
		grip = active.grip_scale

		# No bunny hopping: this game turns on top speed deciding how hard you lean the floor, and chained hops would outrun the walk key.
	t.auto_hop = false
	t.max_speed = run

		# Shift is a brake, not a sprint: running destabilises a platform ([member ScConfig.platform_motion_gain]), so crossing an occupied one means slowing down.
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

		# Below the angle a platform collapses at (about 16 degrees; a player slides off at 14), so the floor throws people before it goes and a collapse is survivable.
	t.max_slope_angle = 14.0
	# Enough to step onto a crate that has landed flat, which is what makes a prop cover
	# rather than an obstacle.
	t.step_height = 0.45

	return t


## The clear air a running player crosses in one jump, landing [param rise] metres higher than they left, in metres.
##
## Read off [method tunables_for] via [method DotFpsTunables.jump_reach] so a cvar that shortens the jump shortens this. [param rise] matters because a runner leans the platform toward the edge, so the lip they leave from is below the one they aim for; the suite measures it from [ScPlatforms]. Returns 0.0 for a rise no jump clears.
static func jump_reach(config: ScConfig, rise: float, p_active: ScSpecials.Active = null) -> float:
	return tunables_for(config, p_active).jump_reach(rise)


## Registers the movement actions, and binds the slow walk to shift.
##
## dot-player-controller puts walk on alt and sprint on shift; this game has no sprint and its walk is the central control. The existing binding is left alone, so a project's own input map wins.
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
## Offline only: puts the client's buttons (fire, reload...) on the command [member sampler] has just made.
## Stamped after sampling, or the fresh sample overwrites them and no shot of the player's reaches the rig.
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

		# `ground_id` is deliberately not simulation state: [DotFpsState] documents it as a per-machine physics handle, and being carried is resolved per frame from it, not predicted (a platform's collider is moved by whichever end is authoritative).
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

		# Written back into the state too: the controller starts the next tick from `state.position`, so a node-only displacement is undone and the player stands still overall.
	state.position = global_position
	carried_metres += absf(lift)


## The body this player was standing on last tick, and where it was, so that a machine that
## has moved since takes them with it.
var _ride_id: int = 0
var _ride_was := Transform3D.IDENTITY


## Carries a player standing on a body that moves: a helicopter.
##
## By the body's own motion over the tick: the motor sweeps against a world that stood still, so a moving floor is slid off. Platforms only move vertically ([method ScPlatforms.lift_at]); a machine flies and turns, so this is the whole transform. The first tick only remembers where the body is, or a transform against identity throws the rider to the origin.
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
## From the simulated state, not the node: on an interpolating client the node is between two ticks, and a shot from there comes from a position no tick had.
func eye_position() -> Vector3:
	return controller.state.position + Vector3(0.0, EYE_HEIGHT, 0.0)


## The duck-typed component lookup dot-weapon's player bridge asks a carrier for.
##
## Without it the bridge falls back to the body transform: right position, identity basis (yaw lives in the controller's state), so every shot goes due north and nothing looks broken. Matches `DotFpsController` as well as `DotPlayerController`, because the bridge asks for the base and a name is not a hierarchy.
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
## Built from yaw and pitch, not read off a camera: servers, bots and headless tests have none.
func aim_direction() -> Vector3:
	var view := Basis.from_euler(Vector3(
		deg_to_rad(controller.state.pitch), deg_to_rad(controller.state.yaw), 0.0
	))
	return -view.z


## Gets into or out of a chopper.
##
## A pilot put back on their feet must lose the machine's velocity, or the first step throws them off the map.
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
## State and node together, velocity cleared: the showdown teleport moves everybody 60 m and a carried fall would arrive already dying.
func place_at(at: Vector3, yaw_degrees: float) -> void:
	warps += 1
	global_position = at

		# Through `teleport`, which also resets the tick the client draws FROM; a hand-written state would sweep the view across the map for a frame.
	controller.teleport(at, yaw_degrees, 0.0)

	if sampler != null:
		sampler.look_at_angles(yaw_degrees, 0.0)

		# And into the pending COMMAND, which the next tick reads: the motor repeats the last command when given none, so a state-only teleport is undone by an empty command with yaw zero.
	var facing := DotFpsCommand.new()
	facing.yaw = yaw_degrees
	facing.pitch = 0.0
	controller.apply_command(facing)


## Puts the movement back on numbers the current round is being played with.
##
## Called when a special starts or ends. The tunables object is replaced, not edited, because the controller keeps a fingerprint of it; a differing client diverges every tick and looks like packet loss.
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
## Called by the client once a frame for every player it knows, never by the world (a server draws nothing). Only while alive: a ring round somebody who is out marks nothing. [param at] is the DRAWN position; [param local_view] hides the column on the beaconed player's own screen.
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


## Draws this player's body for one frame at [param at]; client side, from `ScClient.present_frame`. Returns whether it is shown.
##
## Hidden for the camera's owner in first person ([param own_view]; in third person it shows where they stand), a pilot (drawn AS the chopper; `ride.carry_rider_nodes` is off so a body would stay frozen on the pad) and somebody who is out. [param team_colour] is their side's, on the torso; see [ScFigure].
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


## The rig this process simulates them with: the server's, an offline stand-in's, or the one a networked client builds for its own hands (`ScClient._arm_locally`, which does not set [member weapons]).
func _rig() -> ZeeWeaponRig:
	if weapons != null:
		return weapons

	return get_node_or_null(^"Weapons") as ZeeWeaponRig


## Which atlas this player wears: their avatar's skin, or the one their id hashes to.
##
## From the id, so every client dresses the same person the same way; [ScAvatars.SKINS] is the atlas order, which `headless_run` holds it to.
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
