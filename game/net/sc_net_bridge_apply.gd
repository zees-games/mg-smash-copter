extends "sc_net_bridge_events.gd"

## Part of [code]sc_net_bridge.gd[/code] (split for size): the client half: applying layouts, platforms, seats and the clock. Never used on its own.


func client_tick(tick: int, command: DotFpsCommand, slot: int = 0) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := ScNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()
	packet.slot = slot

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from `last_move` on a fresh tick and on a replayed one alike —
	# the predictor's replay sets it through `_net_apply_input`, and this is the fresh tick's
	# equivalent.
	var mine: ScPlayerNet = _behaviours.get(local_player_id)

	if mine != null:
		mine.last_move = packet.move
		mine.last_slot = slot

		if mine.player != null:
			mine.player.wanted_slot = slot

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		DotNetInput.write_batch(writer, _input_copies(packet))
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# One predicted player, and nothing else: the platforms, the props and the choppers are
	# all drawn from snapshots and are never simulated here.
	if _client_ticked_for != tick:
		_client_ticked_for = tick

		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())

		# The clock a client shows, advanced between the twice-a-second messages that
		# correct it. Without this the round timer ticks in half-second steps.
		game.round_elapsed += net.clock.tick_duration()


func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)


## [param packet] and the commands before it from the local replay history, oldest first,
## for one input packet. See [constant INPUT_COPIES].
func _input_copies(packet: DotNetInput) -> Array:
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, packet.tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(packet)
	return batch


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


## Puts the whole client (world, every controller and the ENGINE) on the server's rate. The engine matters: at 60
## against 128 the clock ran correct ticks in bursts of two and three and the camera's apparent speed swung 47%,
## eight times a second. A server never calls this: its rate is `sv_tickrate`.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	# The LIVE one, which is built from the config back at `setup()` and is therefore not
	# updated by writing the config alone.
	net.clock.tick_rate = game.tick_rate
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap to
	# a quarter second of ticks, so a slow-frame client keeps up with the server. A shell built
	# before it gets the same rule here; remove this branch when the oldest shell is API 7.
	if DotAddonApi.build_level("dot_net") >= 7:
		DotNetClock.adopt_tick_rate(game.tick_rate)
	else:
		Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, ceili(0.25 * float(game.tick_rate)))
		Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


## Client, on TOYS: a mirror for every id at once, under the holder, whether this end's toys for the field exist yet
## or not. A client must know every entity a snapshot carries, since dot-net stops reading at the first it does not
## know, which froze every player after a missing toy mirror. Paired with its toy by index once both exist.
func _apply_toys(told: Dictionary) -> void:
	if net == null or net.is_server:
		return
	_release_toys()
	if _toy_holder == null:
		_toy_holder = Node3D.new()
		_toy_holder.name = "ToyMirrors"
		add_child(_toy_holder)
	_toys_map = told["map_id"]
	for id in (told["ids"] as PackedInt64Array):
		var _mirror := _toy_entity(null, _toy_holder, int(id))
	_pair_pending_toys()


func _apply_layout(reader: DotNetReader) -> void:
	var described := ScEvents.read_layout(reader)

	if not bool(described["ok"]) or game.platforms == null:
		return

	game.config.columns = maxi(int(described["columns"]), 1)
	game.config.rows = maxi(int(described["rows"]), 1)
	game.config.column_pitch = float(described["column_pitch"])
	game.config.row_pitch = float(described["row_pitch"])
	game.config.platform_size = float(described["platform_size"])
	game.config.deck_height = float(described["deck_height"])

	# Let go of the old field BEFORE building the new one: a client's platform behaviour and identity are CHILDREN
	# of its body, so rebuilding frees them and a leftover registry entry makes dot-net read a freed node every
	# snapshot. The server has `world_clearing`; a client is told, so it happens here.
	_forget_platforms()

	game.platforms.build_cells(
		described["cells"],
		float(described["pitch_scale"]),
		float(described["stiffness_scale"]),
		game.physics,
		float(described.get("row_pitch_scale", 1.0)),
		float(described.get("row_shift", 0.0))
	)

	# The arena is derived from the same numbers, so it is rebuilt with them. A client whose floor, tube and
	# corners were laid out for a different platform field would have a cannon that fires out of the side of a
	# tube and corners that are not where the survivors arrive.
	if game.arena != null:
		game.arena.build()

	# The field's toys, placed from the decks just built, and handed to their mirrors.
	game.build_toys()
	_pair_pending_toys()


## Unregisters every platform this end is mirroring. Client side; see [method _apply_layout].
func _forget_platforms() -> void:
	for net_id in _bodies.keys():
		var behaviour: Variant = _bodies[net_id]

		# Freed with the scene on a disconnect; see `_apply_prop_gone`.
		if not is_instance_valid(behaviour):
			_bodies.erase(net_id)
			continue

		if not (behaviour is ScPlatformNet):
			continue

		_bodies.erase(net_id)

		if net != null:
			net.registry.unregister(int(net_id))


func _apply_platform(reader: DotNetReader) -> void:
	var told := ScEvents.read_platform(reader)

	if not bool(told["ok"]) or game.platforms == null:
		return

	var net_id := int(told["net_id"])
	var index := int(told["index"])

	if _bodies.has(net_id):
		return

	var deck := game.platforms.deck_at(index)

	if deck == null or deck.body == null:
		# Not an error: a client that has not yet been told this round's layout is one that
		# will be, and the platform entity will be announced again on the next round. Drawn
		# nothing rather than guessed at.
		DotLog.debug(CHANNEL, "a platform arrived before the field it belongs to", {
			"index": index,
		})
		return

	var behaviour := ScPlatformNet.new()
	behaviour.name = "Net"
	behaviour.index = index
	behaviour.platforms = game.platforms
	deck.body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	identity.always_relevant = true
	deck.body.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not mirror a platform", {"error": str(registered.error)})
		return

	_bodies[net_id] = behaviour


## Where a client finds the scene for something the server named, in both catalogues: the event carries a catalogue
## id and each build turns it into its own path, which is the point of not sending a script name.
func _scene_for(kind_id: StringName, vehicle: bool) -> String:
	if vehicle:
		var def := game.vehicles.catalogue.get_vehicle(kind_id) if game.vehicles != null else null
		return def.scene_path if def != null else ""

	var prop := game.props.catalogue.get_prop(kind_id) if game.props != null else null
	return prop.scene_path if prop != null else ""


func _apply_prop_gone(reader: DotNetReader) -> void:
	var info := ScEvents.read_prop_gone(reader)

	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])
	# Checked for life before it is cast: a client being disconnected frees its scene with the bridge's entries
	# still in `_bodies`, and an event already queued then names a freed body, and casting a freed object is a
	# script error, not a null.
	var entry: Variant = _bodies.get(net_id)
	_bodies.erase(net_id)

	if entry == null or not is_instance_valid(entry):
		return

	var behaviour := entry as ScPropNet
	if behaviour == null:
		return

	if net != null:
		net.registry.unregister(net_id)

	if behaviour.prop != null and is_instance_valid(behaviour.prop):
		behaviour.prop.queue_free()


## A client's copy of "that player is flying". The client runs no ride (no vehicle spawner, seats or exit sweep: the
## server owns them), so what arrives is the answer, and what the client does with it is stop predicting somebody no
## longer walking.
func _apply_seat(reader: DotNetReader) -> void:
	var info := ScEvents.read_seat(reader)

	if not bool(info["ok"]):
		return

	var behaviour: ScPlayerNet = _behaviours.get(int(info["player_id"]))

	if behaviour == null or behaviour.player == null:
		return

	behaviour.player.set_riding(bool(info["seated"]))
	seat_changed.emit(int(info["player_id"]), bool(info["seated"]))


func _apply_clock(reader: DotNetReader) -> void:
	var clock := ScEvents.read_clock(reader)

	if not bool(clock["ok"]):
		return

	game.round_number = int(clock["round"])
	game.round_elapsed = float(clock["elapsed"])
	game.phase = int(clock["phase"])
	game.remote_standing = int(clock["standing"])
	game.remote_alive = int(clock["alive"])
	game.remote_playable = bool(clock["playable"])
