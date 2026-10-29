extends "sc_net_bridge_base.gd"

## Part of [code]sc_net_bridge.gd[/code] (split for size): what is replicated: ids, bodies, platforms and toys on the wire. Never used on its own.


static func player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


func _build_entity(player: ScPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: [DotNetIdentity] collects behaviours in
	# `_ready` by walking the subtree, and one added afterwards would never be found.
	var behaviour := ScPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's own
	# movement a round trip behind their keys, which in this game is the difference between
	# stepping off a platform and being told you already did.
	identity.authority = DotNetIdentity.Authority.SHARED
	# [b]Always, and the map is why.[/b] Interest management is a saving where most players are out of sight;
	# this one is a field of platforms in open air with nothing taller than a person on it, so everybody can
	# see everybody and culling would only ever produce a player who vanishes in mid-air.
	identity.always_relevant = true
	player.add_child(identity)

	var session_id := session_of(player.player_id)
	_behaviours[session_id] = behaviour

	# Only ever emitted on a mirror, where the snapshot is what says a weapon was used.
	behaviour.weapon_used.connect(func(times: int, kind: int) -> void:
		weapon_used_by.emit(session_id, times, kind)
	)
	return identity


## Server side. See [member _in_server_tick] for why an id let go of mid-tick is remembered.
func _unregister(net_id: int) -> void:
	net.registry.unregister(net_id)

	if _in_server_tick:
		_unregistered_in_tick.append(net_id)


func _release_entity(session_id: int) -> void:
	var behaviour: ScPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	_unregister(behaviour.identity.net_id)


func _describe_layout() -> PackedByteArray:
	var layout := game.layout

	return ScEvents.write_layout(
		layout.id if layout != null else &"full",
		game.platforms.field_columns(),
		game.platforms.field_rows(),
		game.config.column_pitch,
		game.config.row_pitch,
		game.config.platform_size,
		game.config.deck_height,
		layout.pitch_scale if layout != null else 1.0,
		layout.stiffness_scale if layout != null else 1.0,
		game.platforms.cells(),
		layout.row_pitch_scale if layout != null else 1.0,
		layout.row_shift if layout != null else 0.0
	)


func _replicate_platform(index: int) -> void:
	var deck := game.platforms.deck_at(index)

	if deck == null or deck.body == null:
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

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a platform", {
			"index": index, "error": str(registered.error),
		})
		return

	_bodies[identity.net_id] = behaviour
	_net_of["d%d" % index] = identity.net_id
	behaviour.pull()

	_broadcast(ScEvents.Kind.PLATFORM, ScEvents.write_platform(identity.net_id, index))


## The half a prop, a chopper and a platform do identically.
func _replicate_body(behaviour: DotNetBehaviour, body: Node3D) -> int:
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	# SERVER, not SHARED: nothing about a rigid body is predicted here, so there is no owner
	# to share with.
	identity.authority = DotNetIdentity.Authority.SERVER
	identity.always_relevant = true
	body.add_child(identity)

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a body", {"error": str(registered.error)})
		return 0

	_bodies[identity.net_id] = behaviour
	return identity.net_id


func _forget_body(key: String, reason: StringName) -> void:
	if net == null or not net.is_server or not _net_of.has(key):
		return

	var net_id := int(_net_of[key])
	_net_of.erase(key)
	_bodies.erase(net_id)

	_unregister(net_id)
	_broadcast(ScEvents.Kind.PROP_GONE, ScEvents.write_prop_gone(net_id, reason))


func net_id_of_node(node: Node) -> int:
	if node == null:
		return 0

	for net_id in _bodies:
		var behaviour: ScPropNet = _bodies[net_id] as ScPropNet

		if behaviour != null and behaviour.prop == node:
			return int(net_id)

	return 0


func _clock_body() -> PackedByteArray:
	return ScEvents.write_clock(
		game.round_number,
		game.round_elapsed,
		game.phase,
		game.platforms.standing_count() if game.platforms != null else 0,
		game.alive_count(),
		game.teams_alive(),
		game.sides_are_playable()
	)


## Which catalogue entry a replicated body came from. Read off the spawners rather than remembered beside the
## table: a second copy of "what this is" is a second thing that can disagree with the first, and this one is
## only asked for on a join.
func _kind_of(behaviour: ScPropNet) -> StringName:
	if behaviour is ScCopterNet:
		var copter: DotVehicleInstance = (behaviour as ScCopterNet).vehicle
		return copter.def.id if copter != null and copter.def != null else ScContent.COPTER

	var prop := game.props.prop_for_node(behaviour.prop) if game.props != null else null
	return prop.def.id if prop != null and prop.def != null else ScContent.CRATE


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: ScPlayerNet = _behaviours.get(session_id)

	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	return ScEvents.write_join(
		session_id,
		behaviour.identity.net_id,
		behaviour.player.display_name,
		game.team_of(behaviour.player.player_id),
		behaviour.player.avatar
	)


## Tells everybody who somebody is now: a late profile, a wardrobe change, a rename. Server only. Through JOIN,
## which a client already applies to a player it has and which is idempotent, where a second message would be a
## second order to race. An empty [param display_name] keeps the current one.
func refresh_player(session_id: int, display_name: String, avatar: DotAvatar) -> bool:
	if net == null or not net.is_server or game == null:
		return false

	var player: ScPlayer = game.players.get(player_key(session_id))

	if player == null or not _behaviours.has(session_id):
		return false

	if display_name != "":
		player.display_name = display_name

	player.avatar = avatar
	_broadcast(ScEvents.Kind.JOIN, _join_body(session_id))
	return true


## To every peer that has said it is ready, and nobody else. An empty body is dropped rather than sent: it means an
## encoder was handed something already gone (a player released before the LEAVE was written), and a zero-length
## event decodes as a valid message about nothing.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or body.is_empty():
		return

	for peer_id in _ready_peers.keys():
		_tell(int(peer_id), kind, body)


## One peer, and never zero. `net.send(msg, 0)` is a BROADCAST in dot-net, so a helper that passed a missing
## peer id straight through would send one player's private message to everybody. game-hungario shipped
## exactly that.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if peer_id <= 0 or net == null or body.is_empty():
		return

	net.send(ScEvent.new(kind, body), peer_id)


## The map, which on a client is a list of cells and six numbers.

## The field's toys on the wire, one behaviour per toy in toy order, and the TOYS event that names
## their net ids (kept for a joiner).
var _toy_nets: Array = []
var _toys_body: PackedByteArray = PackedByteArray()

## The one id TOYS carries here: a field has no name of its own, and LAYOUT is what says which.
const FIELD := &"field"

## Client: which map the last TOYS was for. Its mirrors are registered at once and handed their
## toys when this end's toys for the field exist ([method _pair_pending_toys]).
var _toys_map: StringName = &""

## Client: where the mirrors live, which is not under the toys: a client registers them the
## moment TOYS arrives, before its own map may be built, and keeps them through a map change.
var _toy_holder: Node3D = null


## Server: an entity for each of the field's toys, and TOYS naming them.
func _register_toys() -> void:
	if net == null or not net.is_server or game == null:
		return
	_release_toys()
	var ids := PackedInt64Array()
	if game.toys != null:
		for toy in game.toys.toys:
			var behaviour := _toy_entity(toy, toy, 0)
			if behaviour == null:
				break
			ids.append(behaviour.identity.net_id)
	_toys_body = ScEvents.write_toys(FIELD, ids)
	_broadcast(ScEvents.Kind.TOYS, _toys_body)


## A toy's behaviour and identity under [param parent], registered under [param net_id] (0
## allocates: the server); null when the registry refused it. The behaviour before the
## identity, which collects behaviours in its `_ready`.
func _toy_entity(toy: DotPropToy, parent: Node, net_id: int) -> ScToyNet:
	var behaviour := ScToyNet.new()
	behaviour.name = "Net"
	behaviour.toy = toy
	var holder := Node3D.new() if parent != toy else null
	if holder != null:
		holder.name = "Toy%d" % _toy_nets.size()
		parent.add_child(holder)
	var at: Node = holder if holder != null else toy
	at.add_child(behaviour)
	if net.is_server:
		behaviour.pull()
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	at.add_child(identity)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a toy", {"toy": _toy_nets.size(), "error": str(registered.error)})
		at.remove_child(behaviour)
		at.remove_child(identity)
		behaviour.queue_free()
		identity.queue_free()
		if holder != null:
			parent.remove_child(holder)
			holder.queue_free()
		return null
	_toy_nets.append(behaviour)
	return behaviour


## Every toy entity out of the registry and out of the tree at once: a new identity on the same
## toy collects every behaviour under it in its `_ready`, and a freed one found there broke the
## next snapshot. The server's, on a map change or a new set.
func _release_toys() -> void:
	for behaviour: ScToyNet in _toy_nets:
		if not is_instance_valid(behaviour):
			continue
		if behaviour.identity != null and net != null and net.registry.has(behaviour.identity.net_id):
			if net.is_server:
				# Through the bridge's own, which also has lag compensation forget the id.
				_unregister(behaviour.identity.net_id)
				if not _in_server_tick:
					net.history.forget(behaviour.identity.net_id)
			else:
				net.registry.unregister(behaviour.identity.net_id)
		var at := behaviour.get_parent()
		for node: Node in [behaviour.identity, behaviour]:
			if node != null and is_instance_valid(node) and node.get_parent() != null:
				node.get_parent().remove_child(node)
				node.queue_free()
		if at != null and at.get_parent() == _toy_holder and _toy_holder != null:
			_toy_holder.remove_child(at)
			at.queue_free()
	_toy_nets.clear()


## Client: each mirror handed this end's toy at its index, once this end's toys are for the map
## TOYS named; none while they are not (a map change on the way, or another map).
func _pair_pending_toys() -> void:
	if net == null or net.is_server or game == null:
		return
	var box := game.toys if game.toys != null and _toys_map == FIELD else null
	if box != null and box.count() != _toy_nets.size():
		DotLog.warn(CHANNEL, "the server's map has a different number of toys", {"server": _toy_nets.size(), "here": box.count()})
	for i in range(_toy_nets.size()):
		var behaviour: ScToyNet = _toy_nets[i]
		behaviour.toy = box.toy(i) if box != null else null


## Client: the old field's toys are about to go; the mirrors stay registered, without them.
func _unpair_toys() -> void:
	for behaviour: ScToyNet in _toy_nets:
		if is_instance_valid(behaviour):
			behaviour.toy = null


## How many toys this end replicates (a client: mirrors paired with a toy). For a check.
func toy_count() -> int:
	var n := 0
	for behaviour: ScToyNet in _toy_nets:
		if is_instance_valid(behaviour) and (net.is_server or behaviour.toy != null):
			n += 1
	return n
