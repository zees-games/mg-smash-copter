extends DotNetBehaviour

const ScNetCommand := preload("sc_net_command.gd")
const ScPlayer := preload("../sc_player.gd")

## What a networked player replicates: the movement state, their health, and whether they are flying.
## The movement half is dot-player-controller's own [DotFpsNetSync.state_specs] (type names are STRINGS so the addon describes a dot-net layout without naming dot-net); listing the fields here would be a second copy to drift.
## Health and riding are not derivable from movement. Team is deliberately NOT here: it changes once a round at most and arrives reliably in JOIN and TEAM; per-tick property for what changes per tick, an event for a decision.

## Somebody this client is watching used their weapon, [param times] times since the last
## snapshot. What a game draws a muzzle flash from.
signal weapon_used(times: int, kind: int)

var player: ScPlayer = null
var bridge: Node = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

## Hit points, and the one field with a hard cap on the wire.
## Sent against 0..1000 rather than the player's own maximum: raising `player_health` mid-round would otherwise change what every number sent earlier MEANT.
var net_health: float = 100.0

## Whether they are in a chopper.
var net_riding: bool = false

# Seven fields, and the pack's own `ZeeWeaponNet.all_specs()` names all of them; concatenating by hand is a second place to forget the pack's half, which presents as weapons silent for everybody but the holder.
# The magazine and the reserve are `owner_only`: exact ammunition is information an opponent should not have, as dot-combat decides.

var net_slot: int = 0
var net_magazine: int = 0
var net_reserve: int = 0
var net_fire_seq: int = 0
var net_fire_kind: int = 0
var net_reloading: bool = false
var net_switching: bool = false


## `ScPlayer.blinded`. Owner only: see [method _register_net_vars].
var net_blind: bool = false

## `ScPlayer.beacon`. Everybody's.
var net_beacon: bool = false

## `ScPlayer.warps`, four bits of it: how many times the server has put this player
## somewhere rather than moved them there. See [method _forget_the_path].
var net_warp: int = 0

## The last [member net_warp] this mirror acted on.
var _seen_warp: int = -1

## What this watcher last saw of that counter, so a wrap is read as uses rather than as a
## negative. One integer per watched player, which is what lets `ZeeWeaponNet` keep none.
var _seen_fire_seq: int = 0

## Retained, not cleared: a player whose packet was lost keeps moving in a straight line
## rather than stopping dead. The controller says the same of its own command.
var last_move: DotFpsCommand = DotFpsCommand.new()

## And the slot they last asked for, which is simulation state on the showdown's side of
## the round: the arsenal is edge-triggered against it.
var last_slot: int = 0

var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	replicate(&"net_health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1000.0).bits(12)
	replicate(&"net_riding", DotNetVar.Type.BOOL)

	for spec in ZeeWeaponNet.all_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if bool(spec["owner_only"]):
			var _owner := declaration.to_owner_only()

	# Per-player state rather than an event, so both survive what an event does not: a client joining after `beacon`, a lost snapshot, a field re-laid at round top are baselines the next snapshot corrects.
	# The blind goes to its owner alone (an opponent receiving it would learn the moment somebody could not see).
	# No relevance change for a beacon: every player here is already always relevant (`ScNetBridge`), and turning it OFF by setting `always_relevant` false would take the player out of everybody's snapshot.
	var _blind := replicate(&"net_blind", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_beacon", DotNetVar.Type.BOOL)
	replicate(&"net_warp", DotNetVar.Type.UINT).bits(4)


func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as ScNetCommand

	if command != null:
		last_move = command.move
		last_slot = command.slot

		if player != null:
			player.wanted_slot = command.slot


## On the authority the whole game ticks as one, so the first behaviour through drives the whole world and the rest find it done.
## On a predicting client the one predicted player is the whole of what it may compute; props, platforms and choppers are the server's answer.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	elif player.riding:
		# A rider is not predicted, because a rider is not walking: the machine's position comes from the server and is not reproducible, so a controller simulating on top of it fights every snapshot.
		# The command is still applied, because those keys ARE the collective and the pedals and must reach the server.
		player.controller.apply_command(last_move.duplicate_command())
	else:
		player.controller.apply_command(last_move.duplicate_command())
		player.controller.simulate_tick(tick, delta)

	pull()


## Authority only: what the simulation left this player as.
func pull() -> void:
	if player == null:
		return

	DotFpsNetSync.pull(player.controller.state, self)

	if player.health != null:
		net_health = player.health.health

	net_riding = player.riding
	net_blind = player.blinded
	net_beacon = player.beacon
	net_warp = player.warps & 0xF

	# After the arsenal has simulated, which on this end it has: the whole world ticks before anything is pulled.
	# A rig that does not exist yet leaves these at zero, a carrier holding nothing, which is true.
	if player.weapons != null:
		ZeeWeaponNet.pull(player.weapons, self)


## The server's answer, adopted wholesale. On the owner it is the rewind half of
## reconciliation and the predictor replays every unacknowledged command on top.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return

	last_state_tick = tick
	_forget_the_path()
	DotFpsNetSync.push(self, player.controller.state)
	_adopt()

	# NOT the node, on a predicted entity: `receive_snapshot` calls this BEFORE the predictor reconciles, which reads the node as "what the client is showing"; moving it here makes the measured error the whole replay distance.
	# Unless they are riding: nothing is predicted to spoil, and the server's answer IS what should be shown, else the pilot watches the chopper fly away from inside their own head.
	if identity == null or not identity.is_predicted() or player.riding:
		player.global_position = player.controller.state.position


## A teleport is not a movement, so the interpolator must not draw one: the showdown moves every survivor sixty metres in one tick, and the blend would sweep a body across the map (as would every round start).
## The server counts the times it PUT this player somewhere (`ScPlayer.place_at`); a mirror that sees the count change drops the interpolator's track before the new snapshot is added, so the body appears in place one render delay early. Here, before the push, because the manager adds the values just after this hook.
## Not on the predicted entity: nothing interpolates it, and its camera is moved by the prediction's rewind.
func _forget_the_path() -> void:
	if identity == null or identity.is_authoritative or identity.is_predicted():
		_seen_warp = net_warp
		return

	if _seen_warp >= 0 and net_warp != _seen_warp and bridge != null:
		var manager: Variant = bridge.get(&"net")
		if manager is DotNetManager and (manager as DotNetManager).interpolator != null:
			(manager as DotNetManager).interpolator.forget(identity.net_id)

	_seen_warp = net_warp


## Every frame on a remote player. Without this the interpolator's work sits in a property
## nothing reads and a remote player moves in snapshot-sized steps.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return

	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position


## The game half of a snapshot, on a mirror.
## `set_riding` and not the flag, because getting out of a chopper also clears the controller's velocity and puts its mode back to AIR, or the pilot is thrown off the map carrying the machine's speed.
func _adopt() -> void:
	if player == null or identity == null or identity.is_authoritative:
		return

	if player.health != null:
		player.health.health = net_health
		player.health.alive = net_health > 0.0

	if player.riding != net_riding:
		player.set_riding(net_riding)

	player.blinded = net_blind
	player.beacon = net_beacon

	_apply_weapons()


## What a watcher does with somebody else's weapon state.
## A counter, never an event per shot: an RPC per shot needs a reliable channel for something worthless late and desynchronises from the state it belongs with; a missed snapshot just plays one flash instead of two.
## No world model is handed to `ZeeWeaponNet.apply`, because the hand belongs to the lazily built figure; the answer is written onto the player (slot, switch, uses) and `ScPlayer.present_body` hands it to the figure when drawn.
func _apply_weapons() -> void:
	var answer := ZeeWeaponNet.apply(self, null, _seen_fire_seq)
	_seen_fire_seq = int(answer["seq"])

	player.mirrored = true
	player.mirror_slot = net_slot
	player.mirror_switching = net_switching
	player.mirror_fired += int(answer["fired"])
	if int(answer["fired"]) > 0:
		player.mirror_fire_kind = int(answer["kind"])

	if int(answer["fired"]) > 0:
		weapon_used.emit(int(answer["fired"]), int(answer["kind"]))
