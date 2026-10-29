extends "sc_net_bridge_apply.gd"


## Joins an [ScGame] to a [DotNetManager]. The netcode seam, and the only file in this
## project that names both.
##
## [codeblock]
## # server
## bridge.attach(game, net)          # dot-game's DotGameNetcode does this
## bridge.open_link(server)          # and this
## bridge.add_player(peer_id, userid, "Ada")
## bridge.server_tick(tick)          # instead of the game's own loop
##
## # client
## bridge.attach(game, net)
## bridge.open_link(client_link)
## bridge.ask_ready()
## bridge.client_tick(tick, command, slot)
## [/codeblock]
##
## [b]What is predicted, and in this game the answer is one thing.[/b] A player's own
## movement is predicted, like every other first-person game in this family. The platforms,
## the props and the choppers are all server-authoritative and NOT predicted — and the
## platforms are the interesting case, because they are the FLOOR. dot-props refuses to
## predict a crate because two solvers diverge; a floor that diverged would be a player
## falling through a platform their own machine says is holding them up, which is the worst
## possible version of that bug. So the server decides every lean and every client is told.
##
## [b]The ordering is the other half of the file.[/b] dot-net drives simulation per entity;
## this game's tick is a whole-world property — every player moves, then the platforms are
## loaded and stepped, then what landed on what is decided. [method ensure_game_ticked]
## reconciles the two: the first behaviour through on a tick runs the whole world and the
## rest find it done.

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
##
## [b]Two lines, and without them the setting is a lie.[/b] dot-combat names no dot-net type
## — the whole point of the seam — so it takes a rewind and a restore as [Callable]s and,
## unset, says so once at boot and then resolves every shot against the present anyway. A
## game that left the flag on and the callables unset would report lag compensation as
## enabled, do nothing, and cost the next reader an afternoon; this family calls that
## "produced correctly and consumed by nothing" and it is its second most repeated bug.
##
## dot-net already records the history: `DotNetManager.server_tick` calls
## `history.record(identities, tick)` once a snapshot. There is nothing to build.
##
## [b]The shooter is not excluded, and that is safe here rather than an oversight.[/b]
## `DotNetHistory.rewind` can leave one entity alone so that rewinding does not move the
## shooter's own muzzle — but `resolve_shot` fixes `shot.origin` before it rewinds anything,
## so the muzzle has already been decided, and the resolver refuses self damage separately.
## What excluding would buy is one fewer entity moved and put back.
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
##
## A [DotServer] on one end and a [DotClientLink] on the other, both called `Server`, with
## this node under each: Godot routes an RPC by the receiver's node path, so a link opened
## anywhere else is addressed by a path the other end does not have and every message lands
## nowhere, with no error on either side.
func open_link(parent: Node) -> void:
	if parent == null or link != null:
		return

	link = ScNetLink.attached_to(parent, self, net != null and net.is_server)
	# Not parent.add_child: the link sits under the server (RPCs route by path) but must die
	# with this bridge. A bare add_child left a second link after a module reload and Godot
	# renamed the live one `@Node@n`, so RPCs to clients were lost. DotGameLink frees it with
	# the bridge without remove_child, which errors on a busy parent.
	DotGameLink.attach(link, parent, self, ScNetLink.NODE_NAME)


## How every dot-net message reaches a peer.
##
## [b]Routed by DELIVERY, not by kind.[/b] Snapshots are unreliable and go on the snapshot
## call; everything else is reliable, and which reliable call it is depends on which end is
## sending — the server has events, the client has requests. Sending them all as events
## works on a server and silently drops every client request, which is a client that
## connects, draws, and can never ask for anything.
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

	# Released BEFORE the game is told: `game.remove_player` emits `player_removed`, which
	# `_on_player_removed` answers by releasing the entity and broadcasting the LEAVE.
	# Releasing first empties `_behaviours`, so that handler finds nothing and this stays
	# the one place a leaving player is announced.
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
##
## [b]On READY and not on connect, and the difference is a whole join's worth of
## messages.[/b] dot-server's signon finishes and THEN the client builds its scene; a server
## that started talking at connect is one whose JOIN, LAYOUT and PLATFORM land on a node
## that does not exist yet and are lost, one "Node not found" per call.
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
					int(death["player_id"]), int(death["by"]), death["why"]
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

	# [b]The server's tick rate, before anything is derived from it.[/b] Another game in
	# this family shipped with HELLO carrying this and nothing reading it: a browser client
	# counted at the 60 its export declared against a server on 128, so the correction rate
	# was 0.96 and every replicated time was out by 128/60. Produced correctly and consumed
	# by nothing, and invisible to a one-process suite because one process has one engine
	# rate and both ends agree whatever the wire says.
	#
	# Before `sync_from_server`, because the clock converts its error and its lead through
	# `tick_rate` and would otherwise do that arithmetic at the old rate.
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

		# [b]This client's own player is owned by this client, and nobody else's is.[/b]
		# Until 2026-09-25 every mirror was built with owner 0, this client's own included,
		# so `is_owner` was false for the local player, `registry.predicted()` was empty and
		# `client_tick` simulated nobody: the player moved only when a snapshot came back, a
		# round trip behind the keys, and the camera — drawn from `render_state`, a blend
		# against a previous tick the controller never recorded — lurched between where the
		# player was last teleported and where the server had them. Every check passed
		# anyway, because a client adopting the server's answer also agrees with the server.
		#
		# By session and not by a peer id on the wire: JOIN does not carry one, and what
		# `is_owner` compares is the owner against THIS registry's local peer — so the local
		# peer id is the only right value whatever the server calls the connection, and the
		# wire (and therefore a published pack's server half) is unchanged. HELLO, which sets
		# `local_player_id`, is sent before every JOIN in `_admit` on the same reliable
		# channel; [method _apply_hello] still claims a player that got here first, because
		# an order is a property of the server, not of this file.
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


## Who owns a mirrored player on this client: this client, if it is this client's own
## player, and the server's 0 otherwise.
##
## [b]Never the local peer for anybody else[/b], or this client would predict a person whose
## keys it never had. And a client whose local peer is 0 claims nothing: 0 is the server's
## owner id, and on such a registry dot-net's `is_owner` (owner == local peer) is already true
## of every owner-0 mirror — which this function cannot undo, and which no client here runs
## into, because `ScClient` takes its id from the multiplayer API and that never answers 0.
func _mirror_owner(session_id: int) -> int:
	if net == null or net.local_peer_id <= 0:
		return 0

	if local_player_id != 0 and session_id == local_player_id:
		return net.local_peer_id

	return 0


## The local player's mirror, claimed if it arrived before HELLO said whose it was.
##
## Not the order `_admit` sends in, and that is why it is belt and braces rather than a path
## this game takes: a JOIN that reached this peer before its HELLO would otherwise leave the
## local player unpredicted for the rest of the session, with every check still passing —
## which is the bug [method _apply_join] documents.
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
