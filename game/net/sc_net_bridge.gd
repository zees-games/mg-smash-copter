extends "sc_net_bridge_apply.gd"


## Joins an [ScGame] to a [DotNetManager]. The netcode seam, and the only file in this project that names both. Server: attach, open_link, add_player, server_tick; client: attach, open_link, ask_ready, client_tick.
## Only a player's own movement is predicted; platforms, props and choppers are server-authoritative, since a diverged floor would drop a player through a platform their own machine says holds them up.
## This game's tick is whole-world (players move, platforms load and step, landings decided), so [method ensure_game_ticked] runs it on the first behaviour through a tick and the rest find it done.

func _exit_tree() -> void:
	# The link and the runtime hold each other through broadcast.
	if profile_link != null:
		profile_link.release()
		profile_link = null


## [param p_game] and [param p_net], in the shape [DotGameNetcode] calls it.
func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	var world := p_game as ScGame

	if world == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs a world and a manager.")

	if world.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The world and the manager disagree about who is authoritative.",
			"world=%s net.is_server=%s" % [world.authoritative, p_net.is_server]
		)

	game = world
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	net.send_fn = _send
	profile_link = DotNetProfileLink.attach(net, world.ensure_runtime())

	var event := net.messages.register(
		ScEvent.NAME, ScEvent,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		ScRequest.NAME, ScRequest,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(ScEvent.NAME, _on_event)
	net.messages.on(ScRequest.NAME, _on_request)

	# Both ends: the bridge ticks the world (`server_tick`, `client_tick`); its own
	# `_physics_process` would move every player twice.
	game.external_tick = true

	# The field's toys: the server's leave the registry before their nodes go and the new ones
	# are named after LAYOUT; a client's mirrors stay registered and are handed this end's
	# toys when its field is laid out (`_apply_layout`).
	if net.is_server:
		game.toys_clearing.connect(_release_toys)
	else:
		game.toys_clearing.connect(_unpair_toys)

	if net.is_server:
		game.player_added.connect(_on_player_added)
		game.player_removed.connect(_on_player_removed)
		game.world_clearing.connect(_on_world_clearing)
		game.world_rebuilt.connect(_on_world_rebuilt)
		game.props.spawned.connect(_on_prop_spawned)
		game.props.removed.connect(_on_prop_removed)
		game.vehicles.spawned.connect(_on_vehicle_spawned)
		game.vehicles.removed.connect(_on_vehicle_removed)
		game.ride.entered.connect(_on_ride_entered)
		game.ride.exited.connect(_on_ride_exited)
		game.round_began.connect(_on_round_began)
		game.round_over.connect(_on_round_over)
		game.phase_changed.connect(_on_phase_changed)
		game.special_changed.connect(_on_special_changed)
		game.player_died.connect(_on_player_died)
		# To the shooter alone: a hit marker is that player's business.
		game.hit_landed.connect(func(id: StringName, point: Vector3, killed: bool, headshot: bool) -> void:
			var hit_peer := peer_for_player(session_of(id))
			if hit_peer > 0:
				_tell(hit_peer, ScEvents.Kind.HIT, ScEvents.write_hit(point, killed, headshot)))
		game.platform_collapsed.connect(_on_platform_collapsed)
		game.platform_struck.connect(_on_platform_struck)
		game.blast.connect(_on_blast)

		if game.spectate != null:
			game.spectate.view_changed.connect(_on_spectate_changed)

		_wire_lag_compensation()

	return DotResult.success(true)


## Hands dot-combat the two callables that make lag compensation real.
## dot-combat names no dot-net type, so it takes a rewind and a restore as [Callable]s; unset, it says so once and resolves every shot against the present while the flag claims lag compensation is on. dot-net already records the history.
## The shooter is not excluded, and that is safe: `resolve_shot` fixes `shot.origin` before it rewinds anything and refuses self damage separately.
func _wire_lag_compensation() -> void:
	if game.combat == null or net == null:
		return

	if game.combat.config != null:
		game.combat.config.lag_compensation = true

	game.combat.rewind_fn = func(target_tick: float) -> void:
		var _rewound := net.history.rewind(
			net.registry.all(), int(target_tick), net.clock.tick
		)

	game.combat.restore_fn = func() -> int:
		return net.history.restore()

	DotLog.debug(CHANNEL, "lag compensation is wired to the netcode's history", {
		"max_rewind_ms": game.combat.config.max_rewind_ms if game.combat.config != null else 0.0,
	})


## Opens the link under [param parent], whose NAME is half the RPC routing.
## A [DotServer] and a [DotClientLink] both call theirs `Server`, with this node under each: Godot routes an RPC by node path, so a link opened elsewhere lands every message nowhere, with no error.
func open_link(parent: Node) -> void:
	if parent == null or link != null:
		return

	link = ScNetLink.attached_to(parent, self, net != null and net.is_server)
	# Not parent.add_child: the link sits under the server (RPCs route by path) but must die with this bridge, or a module reload leaves a second link and Godot renames the live one `@Node@n`.
	# DotGameLink frees it with the bridge without remove_child, which errors on a busy parent.
	DotGameLink.attach(link, parent, self, ScNetLink.NODE_NAME)


## How every dot-net message reaches a peer.
## Routed by DELIVERY, not by kind: snapshots are unreliable and go on the snapshot call; everything else is reliable, and which call depends on the sender (the server has events, the client has requests). Events from a client are silently dropped.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


## Puts a connected peer into the game. What [DotGameRoster] calls.
func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	if peer_id > 0:
		# FIRST, because `game.add_player` emits `player_added` and the handler has to be
		# able to find which peer this player belongs to.
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	var player := game.add_player(player_key(session_id), display_name)

	if player == null:
		_player_of_peer.erase(peer_id)
		_peer_of_player.erase(session_id)
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(player)


func remove_peer(peer_id: int) -> void:
	_ready_unseated.erase(peer_id)

	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)

	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)

	# Released BEFORE the game is told: `game.remove_player` emits `player_removed`, whose handler releases the entity and broadcasts the LEAVE.
	# Releasing first empties `_behaviours`, so the handler finds nothing and this stays the one place a leaving player is announced.
	_release_entity(session_id)
	game.remove_player(player_key(session_id))

	if net != null and peer_id > 0:
		if was_ready:
			net.remove_peer(peer_id)

		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(ScEvents.Kind.LEAVE, ScEvents.write_player(session_id))
	roster_changed.emit(session_id)


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	# A batch: this tick's command and the ones before it (see [constant INPUT_COPIES]).
	# Copies of ticks already simulated are skipped rather than pushed, or each would count
	# as a late input; the packet's own tick is always pushed, so a late one still counts.
	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return ScNetCommand.new()
	)
	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")
	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)
	for input in batch:
		if input != newest and input.tick <= buffer.last_consumed_tick():
			continue
		pushed = buffer.push(input)
	return pushed


func _on_request(message: DotNetMessage) -> void:
	var ask := message as ScRequest

	if ask == null or net == null or not net.is_server:
		return

	# [b]From the message, which dot-net stamped from the TRANSPORT.[/b] A peer id inside a
	# body is a claim; `sender_peer_id` is what the socket said, which is the only version
	# of it a server may act on.
	var peer_id := ask.sender_peer_id

	match ask.kind:
		ScEvents.Ask.READY:
			_admit(peer_id)
		ScEvents.Ask.SAY:
			var said := ScEvents.read_say(ask.reader())

			if bool(said["ok"]):
				# Emitted rather than acted on: everything about what a line means is
				# [DotChatRouter]'s, and the router is the module's.
				say_requested.emit(
					peer_id, StringName(str(said["channel"])), str(said["text"])
				)
		ScEvents.Ask.BOARD:
			_board(peer_id)
		ScEvents.Ask.TEAM:
			var wanted := ScEvents.read_ask_team(ask.reader())

			if bool(wanted["ok"]):
				_switch_team(peer_id, int(wanted["team"]))
		ScEvents.Ask.SPECTATE:
			var step := ScEvents.read_ask_spectate(ask.reader())

			if bool(step["ok"]):
				_spectate_step(peer_id, int(step["direction"]))
		ScEvents.Ask.ROAM:
			_spectate_roam(peer_id)


## Everything in the world, to one peer, once its own copy exists.
## On READY and not on connect: dot-server's signon finishes and THEN the client builds its scene, so earlier JOIN, LAYOUT and PLATFORM land on a node that does not exist yet.
func _admit(peer_id: int) -> void:
	if peer_id <= 0:
		return

	if not _player_of_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	if profile_link != null:
		profile_link.peer_joined(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, ScEvents.Kind.HELLO, ScEvents.write_hello(
		session_id,
		game.tick_rate,
		net.clock.tick,
		game.config.team_count,
		game.config.survival_seconds,
		game.config.showdown_seconds,
		game.config.showdown_warmup_seconds
	))

	# The map, before anything that refers to a part of it.
	if not _layout_body.is_empty():
		_tell(peer_id, ScEvents.Kind.LAYOUT, _layout_body)
		# The field's toys by net id in deck order, which the joiner's own are paired with.
		if not _toys_body.is_empty():
			_tell(peer_id, ScEvents.Kind.TOYS, _toys_body)

	for key: String in _net_of:
		if not key.begins_with("d"):
			continue

		_tell(peer_id, ScEvents.Kind.PLATFORM, ScEvents.write_platform(
			int(_net_of[key]), key.substr(1).to_int()
		))

	for other in _behaviours.keys():
		_tell(peer_id, ScEvents.Kind.JOIN, _join_body(int(other)))

	# And everything standing in the world. A player who joins halfway through a round has
	# to be told about every prop that is still up, or they walk into cover they cannot see.
	for net_id in _bodies:
		var behaviour: ScPropNet = _bodies[net_id] as ScPropNet

		if behaviour == null or behaviour.prop == null or not is_instance_valid(behaviour.prop):
			continue

		_tell(peer_id, ScEvents.Kind.PROP, ScEvents.write_prop(
			int(net_id),
			_kind_of(behaviour),
			behaviour.replicated_position(),
			behaviour is ScCopterNet
		))

	_tell(peer_id, ScEvents.Kind.PHASE, ScEvents.write_phase(game.phase))
	_tell(peer_id, ScEvents.Kind.CLOCK, _clock_body())


func _on_event(message: DotNetMessage) -> void:
	var event := message as ScEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		ScEvents.Kind.HELLO:
			_apply_hello(reader)
		ScEvents.Kind.LAYOUT:
			_apply_layout(reader)
		ScEvents.Kind.TOYS:
			var told := ScEvents.read_toys(reader)
			if bool(told["ok"]):
				_apply_toys(told)
		ScEvents.Kind.PLATFORM:
			_apply_platform(reader)
		ScEvents.Kind.JOIN:
			_apply_join(reader)
		ScEvents.Kind.LEAVE:
			var session_id := ScEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(player_key(session_id))
			roster_changed.emit(session_id)
		ScEvents.Kind.TEAM:
			var side := ScEvents.read_team(reader)

			if bool(side["ok"]):
				var id := player_key(int(side["player_id"]))
				game.sides[id] = int(side["team"])

				if game.players.has(id):
					(game.players[id] as ScPlayer).team = int(side["team"])

				roster_changed.emit(int(side["player_id"]))
		ScEvents.Kind.PROP:
			_apply_prop(reader)
		ScEvents.Kind.PROP_GONE:
			_apply_prop_gone(reader)
		ScEvents.Kind.SEAT:
			_apply_seat(reader)
		ScEvents.Kind.CLOCK:
			_apply_clock(reader)
		ScEvents.Kind.ROUND:
			var round_info := ScEvents.read_round(reader)

			if bool(round_info["ok"]):
				game.round_number = int(round_info["round"])

				if bool(round_info["began"]):
					game.round_elapsed = 0.0

				round_changed.emit(
					int(round_info["round"]),
					bool(round_info["began"]),
					int(round_info["winner"])
				)
		ScEvents.Kind.PHASE:
			var moved := ScEvents.read_phase(reader)

			if bool(moved["ok"]):
				game.phase = int(moved["phase"])
				phase_received.emit(int(moved["phase"]))
		ScEvents.Kind.SPECIAL:
			var strange := ScEvents.read_special(reader)

			if bool(strange["ok"]):
				special_received.emit(
					strange["special_id"],
					bool(strange["starting"]),
					str(strange["blurb"])
				)
		ScEvents.Kind.DEATH:
			var death := ScEvents.read_death(reader)

			if bool(death["ok"]):
				# The fall goes on the player before anybody hears of the death, so the client
				# that draws it reads the server's pick.
				var fell: ScPlayer = game.players.get(player_key(int(death["player_id"]))) \
					if game != null else null
				if fell != null and death.has("death"):
					fell.death = death["death"]
				death_received.emit(
					int(death["player_id"]), int(death["by"]), death["why"], death["weapon_id"]
				)
		ScEvents.Kind.COLLAPSE:
			var fell := ScEvents.read_collapse(reader)

			if bool(fell["ok"]):
				collapse_received.emit(int(fell["index"]), fell["why"])
		ScEvents.Kind.BLAST:
			var went_off := ScEvents.read_blast(reader)

			if bool(went_off["ok"]):
				blast_received.emit(went_off["position"], float(went_off["radius"]))
		ScEvents.Kind.HIT:
			var hit := ScEvents.read_hit(reader)

			if bool(hit["ok"]):
				hit_received.emit(hit["point"], bool(hit["killed"]), bool(hit["headshot"]))
		ScEvents.Kind.ARMED:
			var armed := ScEvents.read_armed(reader)

			if bool(armed["ok"]):
				# Noted on the player here rather than by whoever listens, so every client
				# draws the gun in a watched player's hand: see `ScPlayer.dealt`.
				var dealt_to: ScPlayer = game.players.get(player_key(int(armed["player_id"]))) \
					if game != null else null
				if dealt_to != null:
					dealt_to.note_dealt(armed["weapon_id"], game.round_number)
				armed_received.emit(int(armed["player_id"]), armed["weapon_id"])
		ScEvents.Kind.CHAT:
			var wire := ScEvents.read_chat(reader)

			if bool(wire["ok"]):
				chat_received.emit(wire)
		ScEvents.Kind.NOTICE:
			var text := ScEvents.read_notice(reader)

			if bool(text["ok"]):
				notice_received.emit(str(text["text"]))
		ScEvents.Kind.SPECTATE:
			var view := ScEvents.read_spectate(reader)

			if bool(view["ok"]) and game.spectate != null:
				game.spectate.apply_view(
					player_key(int(view["viewer"])),
					int(view["mode"]),
					player_key(int(view["target"])) if int(view["target"]) != 0 else &"",
					player_key(int(view["killer"])) if int(view["killer"]) != 0 else &"",
					view["death_at"]
				)
				spectate_received.emit(
					int(view["viewer"]), int(view["mode"]), int(view["target"])
				)
		ScEvents.Kind.IMPACT:
			var landed := ScEvents.read_impact(reader)

			if bool(landed["ok"]):
				impact_received.emit(
					landed["position"], int(landed["outcome"]), float(landed["impulse"])
				)


func _apply_hello(reader: DotNetReader) -> void:
	var hello := ScEvents.read_hello(reader)

	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# The server's tick rate, before anything is derived from it: a client counting at its export's 60 against a server on 128 gets every replicated time out by 128/60, invisible to a one-process suite.
	# Before `sync_from_server`, because the clock converts its error and lead through `tick_rate`.
	_adopt_tick_rate(int(hello["tick_rate"]))

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	game.config.team_count = clampi(int(hello["team_count"]), 2, 6)
	game.config.survival_seconds = float(hello["survival_seconds"])
	game.config.showdown_seconds = float(hello["showdown_seconds"])
	game.config.showdown_warmup_seconds = float(hello["handover_seconds"])

	_claim_local_player()

	hello_received.emit(local_player_id)


func _apply_join(reader: DotNetReader) -> void:
	var join := ScEvents.read_join(reader)

	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var id := player_key(session_id)
	var player: ScPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]), int(join["team"]))

		if player == null:
			return

		# A client never samples: the client loop hands it commands, and the local player is
		# the only one whose commands exist at all.
		player.sampler = null
		player.samples_input = false

		# This client's own player is owned by this client, and nobody else's is. With owner 0 on every mirror `is_owner` was false for the local player, `registry.predicted()` was empty and nobody was simulated; checks still passed because a client adopting the server's answer agrees with it.
		# By session, not a peer id on the wire (JOIN carries none): `is_owner` compares against THIS registry's local peer, so the wire is unchanged.
		# HELLO precedes every JOIN in `_admit` on the same reliable channel; [method _apply_hello] still claims a player that got here first, because an order is the server's property.
		var identity := _build_entity(player, _mirror_owner(session_id))
		var registered := net.registry.register(
			identity, int(join["net_id"]), net.clock.tick, net.config
		)

		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			return
	else:
		player.display_name = str(join["name"])

	# Both branches: a JOIN for somebody this client already has is the server saying who
	# they are NOW — see [method refresh_player].
	player.avatar = join["avatar"]
	game.sides[id] = int(join["team"])
	player.team = int(join["team"])
	roster_changed.emit(session_id)


## Who owns a mirrored player on this client: this client, if it is this client's own player, and the server's 0 otherwise.
## Never the local peer for anybody else, or this client would predict a person whose keys it never had.
## A client whose local peer is 0 claims nothing: 0 is the server's owner id and `is_owner` is already true of every owner-0 mirror there; `ScClient` takes its id from the multiplayer API, which never answers 0.
func _mirror_owner(session_id: int) -> int:
	if net == null or net.local_peer_id <= 0:
		return 0

	if local_player_id != 0 and session_id == local_player_id:
		return net.local_peer_id

	return 0


## The local player's mirror, claimed if it arrived before HELLO said whose it was.
## Belt and braces, since `_admit` sends HELLO first: a JOIN before its HELLO would otherwise leave the local player unpredicted all session with every check passing ([method _apply_join]).
func _claim_local_player() -> void:
	var mine: ScPlayerNet = _behaviours.get(local_player_id)

	if mine == null or mine.identity == null or not mine.identity.is_registered():
		return

	var claimed := _mirror_owner(local_player_id)

	if claimed == 0 or mine.identity.owner_peer_id == claimed:
		return

	DotLog.debug(CHANNEL, "claimed the local player after HELLO", {
		"session": local_player_id, "net_id": mine.identity.net_id,
	})
	var _changed := net.registry.change_owner(mine.identity.net_id, claimed)


## A prop or a chopper the server has put out.
func _apply_prop(reader: DotNetReader) -> void:
	var info := ScEvents.read_prop(reader)

	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])

	if _bodies.has(net_id):
		return

	var kind_id: StringName = info["kind_id"]
	var scene_path := _scene_for(kind_id, bool(info["vehicle"]))

	if scene_path == "":
		# Not an error: a server may run a catalogue this build does not have, and the
		# honest answer is to draw nothing rather than to guess.
		DotLog.debug(CHANNEL, "something this build does not have", {"id": String(kind_id)})
		return

	var scene: PackedScene = load(scene_path)

	if scene == null:
		DotLog.warn(CHANNEL, "a scene would not load", {"path": scene_path})
		return

	var body := scene.instantiate() as Node3D

	if body == null:
		return

	game.add_child(body)
	body.global_position = info["position"]

	# [b]Frozen before anything else touches it.[/b] A mirrored body must not be simulated
	# locally as well: an unfrozen [RigidBody3D] fights every position written into it and
	# the result is a crate jittering against gravity while the packets say it is falling.
	var rigid := body as RigidBody3D

	if rigid != null:
		rigid.freeze = true

		if bool(info["vehicle"]):
			# What a player standing on it is carried by: see `ScPlayer._carry_on_body`.
			rigid.set_meta(ScPlayer.META_CARRIER, true)

			if game.physics != null:
				var put := game.physics.apply_to(rigid, &"vehicle")

				if not put.ok:
					DotLog.warn(CHANNEL, "a mirrored chopper could not be put on its layer", {
						"why": put.error.message,
					})

	var behaviour: ScPropNet = ScCopterNet.new() if bool(info["vehicle"]) else ScPropNet.new()
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	identity.always_relevant = true
	body.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not mirror a body", {"error": str(registered.error)})
		body.queue_free()
		return

	_bodies[net_id] = behaviour
	prop_arrived.emit(body.global_position, bool(info["vehicle"]))


func describe() -> Dictionary:
	var out := {
		"server": net != null and net.is_server,
		"players": _behaviours.size(),
		"bodies": _bodies.size(),
		"ready_peers": _ready_peers.size(),
		"tick": _tick,
	}

	if not (net != null and net.is_server):
		out["local_player"] = local_player_id

	if link != null:
		out["link"] = link.describe()

	return out


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"bridge     %s" % ("server" if net != null and net.is_server else "client"),
		"players    %d" % _behaviours.size(),
		"bodies     %d replicated" % _bodies.size(),
		"peers      %d ready" % _ready_peers.size(),
		"tick       %d" % _tick,
	])

	if link != null:
		lines.append_array(link.describe_lines())

	return lines
