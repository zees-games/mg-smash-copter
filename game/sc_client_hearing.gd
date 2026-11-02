extends "sc_client_spectate.gd"

## The client's sounds, offline from the world's own signals and online from the wire.


## Offline: the world IS the authority, so its own signals are what happened.
##
## Both this and [method _hear_the_wire] call the same [ScAudio] method, so offline and online differ only in where a fact came from, never in what it sounds like.
func _hear_the_world() -> void:
	if audio == null or game == null:
		return

	game.round_began.connect(func(_n: int, _layout: StringName) -> void:
		var _heard := audio.on_round(true))
	game.round_over.connect(func(_n: int, _winner: int) -> void:
		var _heard := audio.on_round(false))
	game.phase_changed.connect(_hear_phase)
	game.special_changed.connect(func(_id: StringName, starting: bool, _blurb: String) -> void:
		if starting:
			var _heard := audio.on_special())
	game.player_died.connect(func(id: StringName, _by: StringName, why: StringName, _weapon_id: StringName) -> void:
		_hear_death(game.players.get(id), why))
	game.platform_collapsed.connect(func(index: int, _why: StringName) -> void:
		_hear_collapse(index))
	game.blast.connect(func(at: Vector3, _radius: float) -> void:
		var _heard := audio.on_blast(at))
	game.platform_struck.connect(
		func(_index: int, at: Vector3, impulse: float, outcome: int) -> void:
			var _heard := audio.on_impact(at, outcome, impulse))
	game.props.spawned.connect(func(prop: DotPropInstance) -> void:
		var body := prop.body()
		if body != null:
			var _heard := audio.on_prop_appeared(body.global_position))
	# Everybody else's weapons. A rig is built at every handover and freed at the next
	# round, so this connects to each new one rather than once.
	game.player_armed.connect(func(id: StringName, _weapon: StringName) -> void:
		var armed: ScPlayer = game.players.get(id)
		if armed == null or armed == player or armed.weapons == null:
			return
		armed.weapons.used.connect(func(outcome: DotWeaponOutcome) -> void:
			if audio != null and is_instance_valid(armed):
				var _heard := audio.on_weapon(
					armed.global_position, ZeeWeaponNet.kind_number(outcome.kind)
				)
		)
	)


## Connected: the same sounds, from what the server said.
func _hear_the_wire() -> void:
	if audio == null or bridge == null:
		return

	bridge.impact_received.connect(func(at: Vector3, outcome: int, impulse: float) -> void:
		var _heard := audio.on_impact(at, outcome, impulse))
	bridge.blast_received.connect(func(at: Vector3, _radius: float) -> void:
		var _heard := audio.on_blast(at))
	bridge.prop_arrived.connect(func(at: Vector3, vehicle: bool) -> void:
		if not vehicle:
			var _heard := audio.on_prop_appeared(at))
	bridge.weapon_used_by.connect(func(session_id: int, _times: int, kind: int) -> void:
		# Your own is heard from your own rig, a round trip sooner. See `_arm_locally`.
		if session_id == _watch_id:
			return
		var who: ScPlayer = game.players.get(ScNetBridge.player_key(session_id))
		if who != null:
			var _heard := audio.on_weapon(who.global_position, kind))
	bridge.notice_received.connect(func(_text: String) -> void:
		var _heard := audio.deny())


func _hear_phase(phase: int) -> void:
	if audio == null:
		return

	match phase:
		ScGame.Phase.HANDOVER:
			var _heard := audio.on_handover()
		ScGame.Phase.SHOWDOWN:
			var _heard := audio.on_showdown()


func _hear_death(who: ScPlayer, why: StringName) -> void:
	_fall(who)

	if audio == null or who == null:
		return

	var _heard := audio.on_death(who.global_position, why == ScGame.DIED_FELL, who == player)


func _hear_collapse(index: int) -> void:
	if audio == null or game.platforms == null:
		return

	var deck = game.platforms.deck_at(index)

	if deck != null:
		var _heard := audio.on_collapse(deck.centre)


## [param who]'s body falls the way the server picked ([member ScPlayer.death]), copied from the figure this client draws.
##
## The figure stays hidden while they are dead ([method ScPlayer.present_body]); nobody's figure, nothing.
func _fall(who: ScPlayer) -> void:
	if who == null or ragdolls == null or who.figure == null or not who.figure.is_inside_tree():
		return
	if game.physics != null:
		# The level is on `world`; a body lands on it and on nothing else.
		game.ragdoll_rules.collision_mask = game.physics.layer_mask(&"world")
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var _body := ragdolls.spawn(who.figure, who.death if who.death != null else DotPlayerDeath.new(), velocity)
