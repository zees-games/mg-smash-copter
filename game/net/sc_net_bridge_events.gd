extends "sc_net_bridge_repl.gd"

## Part of [code]sc_net_bridge.gd[/code] (split for size): the server half: reactions to the world, chat, requests and the tick. Never used on its own.


## Somebody the world drives itself: a stand-in, or a test's player. [b]The same entity a peer gets, with a
## peer id of zero.[/b] A bot is replicated, scored and crushed exactly like a person — what it does not have
## is a socket — and that is the whole of the difference.
func add_bot(display_name: String, team: int = 0) -> ScPlayer:
	if net == null or not net.is_server or game == null:
		return null

	var session_id := _next_bot_session
	_next_bot_session += 1

	var player := game.add_player(player_key(session_id), display_name, team)

	if player == null:
		return null

	player.is_bot = true
	return player


func _on_player_added(id: StringName) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_of(id)

	if _behaviours.has(session_id):
		return

	# Every id on the wire is `u<session>`, and anything else parses back to zero: a player called `bot` would
	# replicate under session 0, which is also dot-net's broadcast address, and a second would replace the first
	# here. Refused with a line, else one stand-in plays and the other stands still for ever.
	if player_key(session_id) != id:
		DotLog.warn(CHANNEL, "a player whose id is not a session key is not replicated", {
			"id": String(id), "hint": "use add_bot() or ScNetBridge.player_key()",
		})
		return

	var player: ScPlayer = game.players.get(id)

	if player == null:
		return

	var identity := _build_entity(player, peer_for_player(session_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})
		return

	# Before the JOIN, so the first thing anybody hears about this person is their face.
	if player.avatar == null and avatar_fn.is_valid():
		var avatar: Variant = avatar_fn.call(session_id)
		player.avatar = avatar as DotAvatar if avatar is DotAvatar else null

	_broadcast(ScEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)

	if _behaviours.has(session_id):
		# The game removed them itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(ScEvents.Kind.LEAVE, ScEvents.write_player(session_id))
		roster_changed.emit(session_id)


## A whole new field of platforms, announced then replicated one entity each; the description goes first, since a
## client builds its field from the cell list and then learns which net id moves which index. Lets go of every
## platform before the field they live on is freed, or `_bodies` keeps freed instances.
func _on_world_clearing() -> void:
	if net == null or not net.is_server:
		return

	for key: String in _net_of.keys():
		if key.begins_with("d"):
			_forget_body(key, ScPlatforms.WHY_ROUND)


func _on_world_rebuilt() -> void:
	if net == null or not net.is_server or game.platforms == null:
		return

	_layout_body = _describe_layout()
	_broadcast(ScEvents.Kind.LAYOUT, _layout_body)
	_register_toys()

	for index in range(game.platforms.count()):
		_replicate_platform(index)


## Every prop the world puts out becomes a replicated entity, announced reliably AND replicated by snapshot: the
## snapshot moves it, the event says what it IS. Content is named by PATH so a dot-cloud pack can deliver it (a
## mounted pack's `class_name` globals are not registered in the host).
func _on_prop_spawned(prop: DotPropInstance) -> void:
	if net == null or not net.is_server or prop == null or prop.node == null:
		return

	var body := prop.node as Node3D

	if body == null:
		return

	var behaviour := ScPropNet.new()
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var net_id := _replicate_body(behaviour, body)

	if net_id == 0:
		return

	_net_of["p%d" % prop.instance_id] = net_id
	behaviour.pull()

	_broadcast(ScEvents.Kind.PROP, ScEvents.write_prop(
		net_id, prop.def.id, body.global_position, false
	))


func _on_prop_removed(prop: DotPropInstance, reason: StringName) -> void:
	_forget_body("p%d" % prop.instance_id, reason)


func _on_vehicle_spawned(vehicle: DotVehicleInstance) -> void:
	if net == null or not net.is_server or vehicle == null:
		return

	var body := vehicle.body()

	if body == null:
		return

	var behaviour := ScCopterNet.new()
	behaviour.name = "Net"
	behaviour.prop = body
	behaviour.vehicle = vehicle
	body.add_child(behaviour)

	var net_id := _replicate_body(behaviour, body)

	if net_id == 0:
		return

	_net_of["v%d" % vehicle.instance_id] = net_id
	behaviour.pull()

	_broadcast(ScEvents.Kind.PROP, ScEvents.write_prop(
		net_id, vehicle.def.id, body.global_position, true
	))


func _on_vehicle_removed(vehicle: DotVehicleInstance, reason: StringName) -> void:
	_forget_body("v%d" % vehicle.instance_id, reason)


func _on_ride_entered(
	vehicle: DotVehicleInstance, rider_id: StringName, _seat: DotVehicleSeat
) -> void:
	_announce_seat(vehicle, rider_id, true)


func _on_ride_exited(
	vehicle: DotVehicleInstance, rider_id: StringName, _seat: DotVehicleSeat, _at: Vector3
) -> void:
	_announce_seat(vehicle, rider_id, false)


func _announce_seat(vehicle: DotVehicleInstance, rider_id: StringName, seated: bool) -> void:
	if net == null or not net.is_server:
		return

	_broadcast(ScEvents.Kind.SEAT, ScEvents.write_seat(
		session_of(rider_id), net_id_of_node(vehicle.body()), seated
	))


func _on_round_began(number: int, _layout_id: StringName) -> void:
	_broadcast(ScEvents.Kind.ROUND, ScEvents.write_round(number, true, 0))


func _on_round_over(number: int, winner: int) -> void:
	_broadcast(ScEvents.Kind.ROUND, ScEvents.write_round(number, false, winner))


func _on_phase_changed(phase: int) -> void:
	_broadcast(ScEvents.Kind.PHASE, ScEvents.write_phase(phase))


func _on_special_changed(id: StringName, starting: bool, blurb: String) -> void:
	_broadcast(ScEvents.Kind.SPECIAL, ScEvents.write_special(id, starting, blurb))


func _on_player_died(player_id: StringName, by: StringName, why: StringName, weapon_id: StringName) -> void:
	var who: ScPlayer = game.players.get(player_id) if game != null else null
	_broadcast(ScEvents.Kind.DEATH, ScEvents.write_death(
		session_of(player_id), session_of(by) if by != &"" else 0, why,
		who.death if who != null else null, weapon_id
	))


func _on_platform_collapsed(index: int, why: StringName) -> void:
	_broadcast(ScEvents.Kind.COLLAPSE, ScEvents.write_collapse(index, why))


func _on_blast(at: Vector3, radius: float) -> void:
	_broadcast(ScEvents.Kind.BLAST, ScEvents.write_blast(at, radius))


## Everybody hears a landing; nobody is told one that did nothing. An event because a client cannot see one (it runs
## no platform model and its props are frozen mirrors), and the sound is the warning a player on another edge gets
## before the lean arrives.
func _on_platform_struck(_index: int, at: Vector3, impulse: float, outcome: int) -> void:
	if outcome == ScPlatforms.Impact.NONE:
		return

	_broadcast(ScEvents.Kind.IMPACT, ScEvents.write_impact(at, outcome, impulse))


## A view changed on the server. Told to its owner and to nobody else. [b]To the one peer, because a camera is
## private.[/b] Who somebody is watching is a fact about them that nobody else has any business knowing — and
## a stand-in, whose peer is zero, is told nothing, which `_tell` guarantees rather than this.
func _on_spectate_changed(player_id: StringName) -> void:
	if game == null or game.spectate == null or game.spectate.manager == null:
		return

	var session_id := session_of(player_id)
	var peer_id := peer_for_player(session_id)

	if peer_id <= 0 or not _ready_peers.has(peer_id):
		return

	var view := game.spectate.manager.view(String(player_id))
	var target := session_of(StringName(view.target)) if view.target != "" else 0
	var killer := session_of(StringName(view.killer)) if view.killer != "" else 0

	_tell(peer_id, ScEvents.Kind.SPECTATE, ScEvents.write_spectate(
		session_id, int(view.mode), target, killer, view.death_position
	))


## Says what a survivor was handed. Called by the game through the module.
func announce_armed(player_id: StringName, weapon_id: StringName) -> void:
	_broadcast(ScEvents.Kind.ARMED, ScEvents.write_armed(session_of(player_id), weapon_id))


func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1

	if net != null:
		_in_server_tick = true
		net.server_tick(tick)
		_in_server_tick = false

		for net_id in _unregistered_in_tick:
			if not net.registry.has(net_id):
				net.history.forget(net_id)

		_unregistered_in_tick.clear()

	# Belt and braces: `net.server_tick` drives the entities and the first behaviour through calls
	# `ensure_game_ticked`; a server with nobody on it has no behaviours, and a world that ticked only when somebody
	# was connected would stop its round clock between players.
	ensure_game_ticked(tick)

	if tick % CLOCK_EVERY == 0:
		_broadcast(ScEvents.Kind.CLOCK, _clock_body())


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: ScPlayerNet = _behaviours[session_id]

		# Only what a peer sent. A bot has no peer and is driven by the game itself, and an
		# empty command applied over the top of that would stand it still.
		if behaviour.player != null and behaviour.identity != null \
				and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())
			behaviour.player.wanted_slot = behaviour.last_slot

	game.tick_once(tick)

	# The toys where the physics left them, before the snapshot.
	for behaviour: ScToyNet in _toy_nets:
		behaviour.pull()

	# After the world moved everything, before the snapshot is built: a body pulled earlier replicates last tick's
	# place, with no error. Checked, not assumed: a behaviour lives on its body, so freeing one frees the other
	# without telling dot-net's registry, which then logs a freed instance every tick.
	for net_id in _bodies.keys():
		var behaviour: Variant = _bodies[net_id]

		if not is_instance_valid(behaviour):
			_bodies.erase(net_id)
			continue

		# Out of the tree but not yet freed is the ordinary state for the rest of a frame in
		# which a round was re-laid, and a behaviour in it has nothing to say.
		if not (behaviour as Node).is_inside_tree():
			continue

		(behaviour as DotNetBehaviour).call(&"pull")


## Text for one player: a refusal, a rate limit, a command's reply. To the one person who asked, since "you are
## talking too fast" and "you are gagged" are nobody else's business and a broadcast refusal is a punishment
## announced to everybody.
func notice(peer_id: int, text: String) -> void:
	_tell(peer_id, ScEvents.Kind.NOTICE, ScEvents.write_notice(text))


## One routed line to one peer. What [DotGameServices] sends through, via the link.
func send_chat(peer_id: int, wire: Dictionary) -> void:
	_tell(peer_id, ScEvents.Kind.CHAT, ScEvents.write_chat(wire))


## A voice frame, in whichever direction. Not a [ScEvent]: voice is fifty packets a second and every event is
## reliable, which would queue retransmits ahead of a collapsing platform. Nor [DotNetManager]: the packet has its
## own header, sequence and validation in [DotVoicePacket].
func receive_voice(peer_id: int, payload: PackedByteArray) -> DotResult:
	if payload.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "An empty voice frame.")

	if net != null and net.is_server:
		if peer_id <= 0 or player_for_peer(peer_id) == 0:
			# A peer with nobody in the world. Refused rather than relayed: the router
			# stamps the speaker from this id, so relaying one that belongs to nobody puts
			# a voice in the game with no name on it.
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "That peer has nobody in the world."
			)

		# One path or the other, never both: [DotGameModule] assigns `voice_relay_fn` to the services layer's
		# `relay_voice`, and a game that ALSO connected `voice_requested` to the same router would relay every frame
		# twice (a doubled rate limit, a sequence number the jitter buffer sees go backwards).
		if voice_relay_fn.is_valid():
			voice_relay_fn.call(peer_id, payload)
		else:
			voice_requested.emit(peer_id, payload)

		return DotResult.success(null)

	voice_arrived.emit(payload)
	return DotResult.success(null)


## Somebody who is out asked to look at somebody else. The server's list, the server's rule. [b]A refusal goes
## back as a notice rather than being dropped.[/b] "This server only lets you watch your own side" is the
## answer to a key that did nothing, and a key that silently does nothing is reported as broken.
func _spectate_step(peer_id: int, direction: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var moved: DotResult = game.spectate.step(player_key(session_id), direction)

	if not moved.ok:
		notice(peer_id, moved.error.message)


## Somebody who is out pressed the free-roam key. The mode is the server's; the refusal
## ("Free roam is off on this server") goes back as a notice, like a refused step.
func _spectate_roam(peer_id: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var toggled: DotResult = game.spectate.toggle_roam(player_key(session_id))

	if not toggled.ok:
		notice(peer_id, toggled.error.message)


func _board(peer_id: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0:
		return

	var answer := game.try_board(player_key(session_id))

	if not answer.ok:
		notice(peer_id, answer.error.message)


func _switch_team(peer_id: int, team: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or team < 1 or team > game.config.team_count:
		return

	if not game.config.allow_team_choice:
		notice(peer_id, "This server picks the sides.")
		return

	var id := player_key(session_id)

	if not game.players.has(id):
		return

	# It lands on the next round, by rule: a player who changed sides in the middle of a survival phase would stand
	# on a platform of the team they left with their new team's win condition. dot-player-class documents the same
	# decision about changing class mid-fight.
	game.sides[id] = team
	(game.players[id] as ScPlayer).team = team

	var _moved := game.match_node.switch_team(String(id), team, _tick)
	_broadcast(ScEvents.Kind.TEAM, ScEvents.write_team(session_id, team))
	notice(peer_id, "You are on the other side from the next round.")


func ask_ready() -> void:
	_ask(ScEvents.Ask.READY, PackedByteArray([0]))


## Says something. The server decides what it means and who hears it.
func ask_say(channel_id: StringName, text: String) -> void:
	if text.strip_edges() == "":
		return

	_ask(ScEvents.Ask.SAY, ScEvents.write_say(channel_id, text))


## Asks to get into, or out of, whatever is nearest.
func ask_board() -> void:
	_ask(ScEvents.Ask.BOARD, ScEvents.write_board())


func ask_team(team: int) -> void:
	_ask(ScEvents.Ask.TEAM, ScEvents.write_ask_team(team))


## Out, and asking for the free camera, or to go back onto a player from it.
func ask_roam() -> void:
	_ask(ScEvents.Ask.ROAM, ScEvents.write_ask_roam())


## Out, and asking to watch somebody else: +1 next, -1 previous, 0 the other camera.
func ask_spectate(direction: int) -> void:
	_ask(ScEvents.Ask.SPECTATE, ScEvents.write_ask_spectate(direction))


## Sends one encoded voice packet to the server. Client side.
func send_voice(payload: PackedByteArray) -> void:
	if link != null and net != null and not net.is_server:
		link.send_voice(1, payload)


func _ask(kind: int, body: PackedByteArray) -> void:
	if net == null or net.is_server:
		return

	net.send(ScRequest.new(kind, body), 1)
