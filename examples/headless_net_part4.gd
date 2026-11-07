extends "headless_net_part3.gd"

## Sections of [code]headless_net.gd[/code], part 4: shared state and helpers are in the base.


## What a watcher can see of somebody else's weapon.
##
## A counter, never an event per shot: an RPC per shot needs a reliable channel for something worthless late, costs a packet per watcher, and desynchronises from the state, so a watcher would see a muzzle flash on a holstered weapon.
func _test_a_weapon_crosses() -> void:
	_section("a weapon crosses")

	var theirs: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))

	if theirs == null or theirs.weapons == null:
		for what in [
			"the carrier is holding something on the server",
			"and the client is told which slot",
			"a watcher draws the weapon the server has in their hand",
			"at the end of the figure's right arm",
			"a use crosses as a counter",
			"which a watcher reads as a number of uses",
			"and the magazine is owner-only",
		]:
			_check(false, what)

		_finished()
		return

	_check(theirs.weapons.arsenal.current_slot() > 0,
		"the carrier is holding something on the server",
		"slot %d" % theirs.weapons.arsenal.current_slot())

	await _steps(6)

	var watcher: Variant = _client_bridge._behaviours.get(SESSION)
	_check(watcher != null, "the client has a behaviour watching them")

	if watcher == null:
		_check(false, "and the client is told which slot")
		_check(false, "a watcher draws the weapon the server has in their hand")
		_check(false, "at the end of the figure's right arm")
		_check(false, "a use crosses as a counter")
		_check(false, "which a watcher reads as a number of uses")
		_check(false, "and the magazine is owner-only")
		_finished()
		return

	_check(
		int(watcher.get(&"net_slot")) == theirs.weapons.arsenal.current_slot(),
		"and the client is told which slot",
		"%d vs %d" % [int(watcher.get(&"net_slot")), theirs.weapons.arsenal.current_slot()]
	)

		# The gun in their hand, as somebody else draws it: dealt as the module announces (every weapon, selected first) and drawn from the snapshot's slot, since a slot alone names no weapon.
	var current := theirs.weapons.arsenal.current_def()
	_server_bridge.announce_armed(theirs.player_id, current.id)
	for slot in theirs.weapons.arsenal.slots():
		var other_def := theirs.weapons.arsenal.slot_at(slot).def
		if other_def.id != current.id:
			_server_bridge.announce_armed(theirs.player_id, other_def.id)
	_exchange()
	await _steps(2)

	var copy: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var _shown := copy.present_body(false, copy.global_position, Color.WHITE)
	var hand := copy.figure.attachment(&"right_hand") if copy.figure != null else null
	_check(
		copy.figure != null and copy.figure.holding == current.id and copy.figure.held != null
			and copy.figure.held.equipped() == current.id,
		"a watcher draws the weapon the server has in their hand",
		"%s drawn, %s held, dealt %s" % [
			String(copy.figure.holding) if copy.figure != null else "-", String(current.id),
			str(copy.dealt)
		]
	)
	_check(
		hand != null and copy.figure.held.get_parent() == hand
			and hand.get_parent() is BoneAttachment3D,
		"in the person's gun hand (a bone attachment)",
		str(hand.get_parent().name) if hand != null else "no hand"
	)

	var uses: Array[int] = []
	(watcher as Object).connect("weapon_used", func(times: int, _kind: int) -> void:
		uses.append(times)
	)

	var before := int(watcher.get(&"net_fire_seq"))

	# Fired on the server the way a player fires: the button rides in the movement command,
	# because it is held and has to be ordered against the movement it was aimed with.
	var firing := DotFpsCommand.new()
	firing.set_button(ScNetCommand.BUTTON_FIRE, true)
	await _steps(24, firing)

	var after := int(watcher.get(&"net_fire_seq"))
	_check(
		after != before or theirs.weapons.fire_seq > 0,
		"a use crosses as a counter",
		"%d -> %d, rig at %d" % [before, after, theirs.weapons.fire_seq]
	)
	_check(not uses.is_empty(), "which a watcher reads as a number of uses",
		"%d reports" % uses.size())

		# Owner-only, as information: opponents should not know exact ammunition (dot-combat decides the same for the same two numbers). This client IS the owner, so the check is that the field is declared so at all.
	var owner_only := false

	for spec in ZeeWeaponNet.all_specs():
		if spec["property"] == &"net_magazine":
			owner_only = bool(spec["owner_only"])

	_check(owner_only, "and the magazine is owner-only")

		# Lag compensation, wired rather than declared: unset, dot-combat says so once at boot and resolves against the present. This checks the two ends of that seam are joined.
	var combat := _server_game.combat.describe()
	_check(bool(combat["lagcomp"]), "lag compensation is wired to the netcode's history")
	_check(
		_server_game.combat.rewind_fn.is_valid() and _server_game.combat.restore_fn.is_valid(),
		"with BOTH callables, because a rewind that is never restored leaves the whole level in the past"
	)
	_check(int(combat["entities"]) >= 2, "and there are hitboxes to rewind",
		"%d" % int(combat["entities"]))

	_finished()

var _client_peak := 0.0


## The claim: the aim bit a client sends is the server body's `aiming`, the rig's `BUTTON_AIM` and the pace of the motor on both ends.
## Armed: with `ensure_game_ticked` not copying `last_aim` onto the body, the aimed checks fail.
func _test_the_aim_bit_crosses() -> void:
	_section("the aim bit crosses the wire, slows the player and the prediction agrees")
	var key := ScNetBridge.player_key(SESSION)
	var server_me: ScPlayer = _server_game.players.get(key)
	var mine: ScPlayer = _client_game.players.get(key)
	var rig: ZeeWeaponRig = server_me.weapons if server_me != null else null
	var armed := rig != null and rig.current_def() != null and mine != null
	_check(armed, "the server's player holds a gun (from the section before)")
	if not armed:
		_finished()
		return

	var paced := _server_game.ads_rules.move_speed_for(rig.current_def().id)
	# The client's own drawn gun, as the client builds it when the player is armed (`_arm_locally`): a rig under the predicted player, no authority,
	# driven with the aim button every tick, which is what the prediction's pace reads (`step_controller`).
	var drawn := ZeeWeaponRig.new()
	drawn.name = "Weapons"
	drawn.role = ZeeWeaponRig.Role.SERVER
	drawn.authority = false
	drawn.tick_rate = _client_game.tick_rate
	drawn.player_ref = DotNodeRef.of_path(mine.get_path())
	drawn.ads_rules = _client_game.ads_rules
	mine.add_child(drawn)
	var drawn_ready := drawn.setup()
	var _drawn_given := drawn.give(rig.current_def().id)
	_check(drawn_ready.ok, "the client's drawn rig sets up", "" if drawn_ready.ok else drawn_ready.error.message)
	var drawn_tick := 500000
	var aim_step := func(command: DotFpsCommand, aim: bool) -> void:
		drawn_tick += 1
		var weapon_command := DotWeaponCommand.new()
		weapon_command.set_button(DotWeaponCommand.BUTTON_AIM, aim)
		var _o := drawn.simulate_tick(weapon_command, drawn_tick)
		await _step(command, aim)
	var start := server_me.global_position

	var run := func(direction: Vector2, aim: bool) -> float:
		var walk := DotFpsCommand.new()
		walk.move = direction
		server_me.place_at(start, 0.0)
		for _i in range(INPUT_LEAD + 8):
			await aim_step.call(null, false)
		var peak := 0.0
		var client_peak := 0.0
		for _i in range(SERVER_TICK_RATE / 2):
			await aim_step.call(walk, aim)
			var v := server_me.controller.state.velocity
			peak = maxf(peak, Vector2(v.x, v.z).length())
			var cv := mine.controller.state.velocity
			client_peak = maxf(client_peak, Vector2(cv.x, cv.z).length())
		_client_peak = client_peak
		return peak
	var best := Vector2.ZERO
	var hip_run := 0.0
	for direction: Vector2 in [Vector2(0.0, 1.0), Vector2(1.0, 0.0), Vector2(-1.0, 0.0), Vector2(0.0, -1.0)]:
		var reach: float = await run.call(direction, false)
		if reach > hip_run:
			hip_run = reach
			best = direction
	_check(not server_me.aiming and rig.ads_move_scale() == 1.0, "unaimed, the server's body is not aiming and not slowed")

	var aimed_run: float = await run.call(best, true)
	var forward := DotFpsCommand.new()
	forward.move = best
	_check(server_me.aiming and mine.aiming and absf(rig.ads_move_scale() - paced) < 0.001,
		"aimed, the server's body and the client's both are, and the rig is at the rules' pace",
		"server %s client %s scale %.2f of %.2f" % [server_me.aiming, mine.aiming, rig.ads_move_scale(), paced])
	_check(hip_run > 0.5 and absf(aimed_run / hip_run - paced) < 0.1,
		"and the server's body walks at that pace", "hip %.2f m/s aimed %.2f m/s, ratio %.2f of %.2f" % [hip_run, aimed_run, aimed_run / maxf(hip_run, 0.001), paced])
	_check(absf(_client_peak - aimed_run) < 0.3, "the prediction, slowed alike, tops out where the server does",
		"client %.2f m/s, server %.2f m/s" % [_client_peak, aimed_run])

	for _i in range(INPUT_LEAD + 8):
		await aim_step.call(forward, false)
	_check(not server_me.aiming and rig.ads_move_scale() == 1.0, "let go, the pace comes back")
	mine.remove_child(drawn)
	drawn.queue_free()
	server_me.place_at(start, 0.0)
	await _steps(INPUT_LEAD + 8)
	_finished()



## The weapon-feel pass's wire half (`ScGame.hit_landed` -> HIT -> `hit_received`, and the owner-only magazine `ScClient.correct_drawn` adopts).
## `headless_run` proves only the offline half. Armed: without the bridge's HIT send the first check fails; sent with `_broadcast` the second does.
func _test_a_hit_is_the_shooters() -> void:
	_section("a shot that lands is told to the shooter alone, and the drawn gun takes the server's count")
	var key := ScNetBridge.player_key(SESSION)
	var server_me: ScPlayer = _server_game.players.get(key)
	var mine: ScPlayer = _client_game.players.get(key)
	var hits: Array = []
	var heard := func(point: Vector3, killed: bool, headshot: bool) -> void:
		hits.append([point, killed, headshot])
	_client_bridge.hit_received.connect(heard)

	# A second connected player, READY, so a HIT that went to everybody would reach somebody.
	var _seated := _server_bridge.add_player(BYSTANDER_PEER, BYSTANDER_SESSION, "Dov")
	_server_bridge._admit(BYSTANDER_PEER)
	# Two seconds still: the last section's trigger lets go, and a bolt-action gun (the handover
	# deals a sniper rifle) is ready again, so one press here is one shot.
	var still := DotFpsCommand.new()
	await _steps(SERVER_TICK_RATE * 2, still)
	var full := server_me.weapons.arsenal.current().magazine if server_me.weapons != null else -1

	# Point-blank, straight down the aim: the stand-in (the other side) three metres ahead.
	var aim := DotWeaponCommand.new()
	var ahead := aim.aim_direction()
	_stand_in.place_at(server_me.global_position + ahead * 3.0, 180.0)
	# Hit but never killed: a kill could end the showdown and take the gun this section counts.
	var target_health := _server_game.combat.health_of(_stand_in.entity_id)
	target_health.cannot_die = true
	_sent_events.clear()
	_listening = true

	var fire := DotFpsCommand.new()
	fire.set_button(ScNetCommand.BUTTON_FIRE, true)
	await _steps(2, fire)
	await _steps(INPUT_LEAD + 6, still)

	var to_shooter := _events_of(ScEvents.Kind.HIT, CLIENT_PEER)
	_check(not hits.is_empty() and to_shooter > 0, "the shooter's bridge is told the shot landed",
		"%d heard, %d sent to the shooter, stand-in alive %s" % [hits.size(), to_shooter, str(_stand_in.is_alive())])
	var elsewhere := _events_of(ScEvents.Kind.HIT, BYSTANDER_PEER) + _events_of(ScEvents.Kind.HIT, 0)
	_check(elsewhere == 0, "and nobody else is: no HIT to the other player, none broadcast", "%d" % elsewhere)
	_check(not hits.is_empty() and (hits[0][0] as Vector3).distance_to(_stand_in.global_position) < 2.5,
		"at the server's point, on the body that was hit",
		"%s, body at %s" % [str(hits[0][0]) if not hits.is_empty() else "-", str(_stand_in.global_position)])

	# Shot back: this player the victim, and a victim is told nothing.
	hits.clear()
	_sent_events.clear()
	var shot_back := DotShot.new()
	shot_back.attacker = _stand_in.entity_id
	var wound := DotDamage.make(_stand_in.entity_id, server_me.entity_id, 1.0, null)
	wound.health_lost = 1.0
	wound.point = server_me.global_position + Vector3.UP
	shot_back.damages.append(wound)
	_server_game._note_hits(_stand_in, shot_back)
	await _steps(4, still)
	_check(hits.is_empty() and _events_of(ScEvents.Kind.HIT, CLIENT_PEER) == 0,
		"a hit somebody else landed on this player is not this player's marker", "%d" % hits.size())

	# The count: the magazine the server spent arrives in the owner's snapshot fields, and a drawn
	# gun that predicted wrong adopts it once quiet, through the client's own correct_drawn.
	var server_mag := server_me.weapons.arsenal.current().magazine
	var behaviour: Variant = _client_bridge._behaviours.get(SESSION)
	var net_mag := int(behaviour.get(&"net_magazine")) if behaviour != null else -1
	_check(server_mag < full and net_mag == server_mag,
		"the server's magazine, spent, crosses to the owner", "full %d, server %d, client told %d" % [full, server_mag, net_mag])

	var client: Node = (load("res://game/sc_client.gd") as GDScript).new()
	var rig := ZeeWeaponRig.new()
	rig.name = "DrawnForTest"
	rig.role = ZeeWeaponRig.Role.SERVER
	rig.authority = false
	rig.tick_rate = _client_game.tick_rate
	mine.add_child(rig)
	var _set := rig.setup()
	var _given := rig.give(server_me.weapons.current_def().id)
	if rig.arsenal.current() == null or rig.arsenal.current_slot() != server_me.weapons.arsenal.current_slot():
		var _picked := rig.arsenal.select(server_me.weapons.arsenal.current_slot(), 0)
	rig.arsenal.current().magazine = rig.arsenal.current().def.magazine
	client.set(&"weapons", rig)
	client.set(&"player", mine)
	client.set(&"bridge", _client_bridge)
	client.set(&"_offline", false)
	client.set(&"_watch_id", SESSION)
	client.set(&"_drawn_quiet", 0.0)
	var early: bool = client.call(&"correct_drawn")
	var drawn_early := rig.arsenal.current().magazine
	client.set(&"_drawn_quiet", 1.0)
	var corrected: bool = client.call(&"correct_drawn")
	_check(not early and drawn_early != server_mag and corrected and rig.arsenal.current().magazine == server_mag,
		"the drawn gun takes the server's count once quiet, and not before",
		"before %d, after %d, server %d" % [drawn_early, rig.arsenal.current().magazine, server_mag])
	client.free()
	mine.remove_child(rig)
	rig.free()

	target_health.cannot_die = false
	_listening = false
	_client_bridge.hit_received.disconnect(heard)
	_server_bridge.remove_peer(BYSTANDER_PEER)
	await _steps(2)
	_finished()


func _test_a_special_is_announced() -> void:
	_section("something strange is announced")

	var told: Array[StringName] = []
	var blurbs: Array[String] = []

	_client_bridge.special_received.connect(
		func(id: StringName, starting: bool, blurb: String) -> void:
			if starting:
				told.append(id)
				blurbs.append(blurb)
	)

	var special := ScSpecials.by_id(&"feather")
	_server_game.special_changed.emit(special.id, true, special.blurb)
	_exchange()

	_check(told.has(&"feather"), "the client hears about it")
	_check(
		not blurbs.is_empty() and blurbs[0] == special.blurb,
		"and is handed what to shout, rather than looking it up in a catalogue it may not have"
	)

	# The folding itself is the server's, and the client never runs it — it is told the
	# consequences through the ordinary state.
	var both := ScSpecials.Active.new()
	both.fold(special)
	both.fold(ScSpecials.by_id(&"barrage"))
	_check(both.ids.size() == 2 and both.gravity_scale < 1.0, "two at once still multiply")

	_finished()


func _test_chat_crosses() -> void:
	_section("a line crosses")

	var asked: Array[String] = []
	var channels: Array[StringName] = []

	_server_bridge.say_requested.connect(
		func(peer_id: int, channel_id: StringName, text: String) -> void:
			asked.append("%d:%s" % [peer_id, text])
			channels.append(channel_id)
	)

	_client_bridge.ask_say(&"team", "bridge is going")
	_exchange()

	_check(asked.size() == 1, "the server is asked once", "%d" % asked.size())
	_check(
		not asked.is_empty() and asked[0] == "%d:bridge is going" % CLIENT_PEER,
		"with the peer the TRANSPORT reported, not one the body claimed",
		asked[0] if not asked.is_empty() else ""
	)
	_check(not channels.is_empty() and channels[0] == &"team", "and the channel asked for")

	# An empty line never leaves the client, which is the cheapest rate limit there is.
	_client_bridge.ask_say(&"team", "   ")
	_exchange()
	_check(asked.size() == 1, "an empty line is not sent at all")

	# And the other direction: a routed line the server hands back.
	var drawn: Array[String] = []
	_client_bridge.chat_received.connect(
		func(wire: Dictionary) -> void: drawn.append(str(wire.get("m", "")))
	)

	_server_bridge.send_chat(CLIENT_PEER, {
		"n": 1, "t": 0, "c": "team", "k": "say", "s": "u42", "d": "Ada", "w": "",
		"m": "on my way", "x": {"p": SESSION},
	})
	_exchange()

	_check(drawn.has("on my way"), "and a routed line comes back to be drawn")

	# A notice reaches one person. "You are talking too fast" is nobody else's business.
	var notices: Array[String] = []
	_client_bridge.notice_received.connect(func(text: String) -> void: notices.append(text))

	_server_bridge.notice(CLIENT_PEER, "you are gagged")
	_exchange()

	_check(notices.has("you are gagged"), "and a refusal reaches the one person who asked")

	_finished()


func _test_a_lossy_link() -> void:
	_section("a link that loses things")

	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var theirs: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))

	# One snapshot in three on the floor. Snapshots are unreliable by design: a newer one
	# supersedes a lost one and resending a hundred-millisecond-old position is worse than
	# useless.
	_drop_every = 3

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	await _steps(50, forward)

	var apart := mine.controller.state.position.distance_to(theirs.controller.state.position)
	_check(apart < 3.0, "the two ends still agree about where the player is",
		"%.2f m apart" % apart)

	var dropped := _snapshot_count / maxi(_drop_every, 1)
	_check(dropped > 0, "with snapshots genuinely on the floor", "%d dropped" % dropped)

	# A platform's lean is in the snapshot, so a lossy link is exactly where a floor would
	# drift. It does not: the next snapshot carries the whole state rather than a delta
	# against one that never arrived.
	_drop_every = 0
	await _steps(8)

		# The STANDING ones: a falling platform's lean grows without bound while the wire carries half a radian, so it saturates by design.
	var worst := 0.0
	var compared := 0

	for i in range(_server_game.platforms.count()):
		var here := _server_game.platforms.deck_at(i)
		var there := _client_game.platforms.deck_at(i)

		if here == null or there == null or not here.is_standing():
			continue

		compared += 1
		worst = maxf(worst, (here.lean - there.lean).length())

	_check(compared > 0, "there are platforms left to compare", "%d" % compared)
	_check(worst < LEAN_EPSILON * 3.0, "and every standing platform's lean has caught up",
		"%.5f rad worst" % worst)

	_finished()


## An administrator's blind and beacon, through the real handlers, over a link that drops one snapshot in three.
##
## The audience is the point: a blind reaches its owner only (the stand-in's must NOT reach this client), a beacon everybody. Asserted on the client's own copy of each player. Armed: with `to_owner_only()` dropped from `ScPlayerNet`, "never told about somebody else's" fails.
func _test_blind_and_beacon() -> void:
	_section("an admin's blind and beacon: who is told")

	# The handlers exactly as the server's services layer builds them, over the server's
	# world. Never set up: nothing here needs chat, voice or a store.
	var services := ScServices.new()
	services.game = _server_game
	var handlers := services._mod_abilities()
	var blind: Callable = handlers.get("blind", Callable())
	var beacon: Callable = handlers.get("beacon", Callable())
	_check(
		blind.is_valid() and beacon.is_valid() and not services._mod_unsupported().has("blind")
		and not services._mod_unsupported().has("beacon"),
		"the game supports both, and refuses neither"
	)

	var mine: ScPlayer = _client_game.players.get(ScNetBridge.player_key(SESSION))
	var bot_key := _stand_in.player_id if _stand_in != null else &""
	var theirs: ScPlayer = _client_game.players.get(bot_key)
	var mine_net := _behaviour_of(mine)
	var theirs_net := _behaviour_of(theirs)

	_check(
		mine_net != null and mine_net.find_var(&"net_blind").audience == DotNetVar.Audience.OWNER
		and mine_net.find_var(&"net_beacon").audience == DotNetVar.Audience.EVERYONE,
		"the blind is declared owner-only and the beacon for everybody"
	)

	var ada := String.num_int64(SESSION)
	var bot := String.num_int64(ScNetBridge.session_of(bot_key))
	var results: Array[DotResult] = [
		blind.call(StringName(ada), {"on": true, "actor": "1"}),
		blind.call(StringName(bot), {"on": true, "actor": "1"}),
		beacon.call(StringName(ada), {"on": true, "actor": "1"}),
		beacon.call(StringName(bot), {"on": true, "actor": "1"}),
	]
	_check(
		results.all(func(r: DotResult) -> bool: return r.ok),
		"the server blinds and beacons both players"
	)

	_drop_every = 3
	await _steps(24)

	_check(mine != null and mine.blinded, "the owner's client blacks its own screen out")
	_check(
		theirs != null and not theirs.blinded and theirs_net != null and not theirs_net.net_blind,
		"and the client is never told about somebody else's",
		"received net_blind = %s" % (str(theirs_net.net_blind) if theirs_net != null else "?")
	)
	_check(
		mine != null and mine.beacon and theirs != null and theirs.beacon,
		"while the client draws a beacon on both"
	)

	var server_identity := _identity_of(_server_game.players.get(ScNetBridge.player_key(SESSION)))
	_check(
		server_identity != null and server_identity.always_relevant,
		"a beaconed player is relevant to every peer — as every player here already is"
	)

	var _off: Array[DotResult] = [
		blind.call(StringName(ada), {"on": false, "actor": "1"}),
		blind.call(StringName(bot), {"on": false, "actor": "1"}),
		beacon.call(StringName(ada), {"on": false, "actor": "1"}),
		beacon.call(StringName(bot), {"on": false, "actor": "1"}),
	]
	await _steps(24)
	_drop_every = 0

	_check(
		not mine.blinded and not mine.beacon and not theirs.beacon,
		"and turning both off reaches the client"
	)
	# game-arena turns relevance off with the beacon. Here that would take the player out of
	# everybody's snapshot — see `ScPlayerNet._register_net_vars`.
	_check(
		server_identity != null and server_identity.always_relevant,
		"and a beacon turned off leaves the player relevant, which on this map is everybody"
	)

	var absent: DotResult = blind.call(&"9999", {"on": true, "actor": "1"})
	_check(not absent.ok, "a blind on nobody is refused rather than ignored")

	services.free()
	_finished()


## The two things a client makes a noise about that it could not have seen for itself.
##
## A landing exists only on the server (a client's props are frozen mirrors), so the IMPACT event is the only way it hears one; and the cannon's bang is true only if the position is where the prop was fired from.
func _test_what_is_heard_arrives() -> void:
	_section("what a client hears about arrives")

	var arrived: Array[Vector3] = []
	_client_bridge.prop_arrived.connect(func(at: Vector3, vehicle: bool) -> void:
		if not vehicle:
			arrived.append(at)
	)
	var landed: Array[Vector3] = []
	_client_bridge.impact_received.connect(
		func(at: Vector3, _outcome: int, _impulse: float) -> void: landed.append(at)
	)

	var _fired := _server_game.cannon.fire(_server_game.round_elapsed, _server_game.active)
	await _steps(2)

	var muzzle := _client_game.arena.muzzle()
	_check(
		not arrived.is_empty() and arrived[0].distance_to(muzzle) < ScAudio.MUZZLE_REACH,
		"a prop the cannon fires reaches the client at the mouth of the client's own tube",
		"%.2f m from it" % (arrived[0].distance_to(muzzle) if not arrived.is_empty() else INF)
	)

	# A platform still standing: an earlier section took one down on purpose, and a landing
	# on a platform that has gone is a landing on nothing, which is rightly not sent.
	var index := -1
	for i in range(_server_game.platforms.count()):
		if _server_game.platforms.deck_at(i).is_standing():
			index = i
			break

	var deck := _server_game.platforms.deck_at(maxi(index, 0))
	var hit := deck.centre + Vector3(2.0, 0.0, 1.0)
	var outcome := _server_game.platforms.report_impact(maxi(index, 0), 30.0, 10.0, hit)
	_exchange()
	_check(
		outcome == ScPlatforms.Impact.WOBBLE and not landed.is_empty()
			and landed[0].distance_to(hit) < 0.05,
		"and a landing on a platform is told to the client, where it landed",
		"%s, %d heard" % [ScPlatforms.Impact.keys()[outcome], landed.size()]
	)

	_finished()


## Somebody who is out is told where to look, by the server, and nobody else is.
##
## The policy is the server's and the camera the client's: one `SPECTATE` event per decision, to the one peer. Asserts the end state: the death camera over the drop, a team-mate drawn from the client's OWN copy, and a refusal that comes back as words.
func _test_somebody_out_watches() -> void:
	_section("somebody who is out is told where to look")

	var views: Array[int] = []
	_client_bridge.spectate_received.connect(
		func(_viewer: int, mode: int, _target: int) -> void: views.append(mode)
	)
	var notices: Array[String] = []
	_client_bridge.notice_received.connect(func(text: String) -> void: notices.append(text))

	# This section is about the own-side policy, which is an operator's choice (the default
	# lets anybody watch anybody and roam); the next section puts it back.
	_server_game.spectate_rules.force_camera = 1

	# A team-mate for the client under test, so that being out leaves somebody on their own
	# side to watch — and so that the round does not simply end, which a side with nobody
	# alive does.
	var theirs: ScPlayer = _server_game.players.get(ScNetBridge.player_key(SESSION))
	var mate := _server_bridge.add_bot("Mate", theirs.team if theirs != null else 2)
	_check(mate != null and mate.team == theirs.team, "a team-mate is seated beside them")
	await _steps(6)

	var me := ScNetBridge.player_key(SESSION)
	_check(not _client_game.spectate.is_spectating(me), "nobody playing is watching anything")

	var went := theirs.controller.state.position
	theirs.place_at(Vector3(went.x, _server_game.config.kill_height - 5.0, went.z), 0.0)
	await _steps(3)

	_check(not theirs.is_alive(), "the client's player fell and is out on the server")
	_check(
		views.has(DotSpectatorView.Mode.DEATH_CAM) and _client_game.spectate.is_spectating(me),
		"the client is told, and its own mirror now says it is watching"
	)

	var drop := _client_game.spectate.camera_for(me)
	_check(
		_client_game.spectate.mode_of(me) == DotSpectatorView.Mode.DEATH_CAM
			and drop.origin.y > _server_game.config.deck_height,
		"the death camera is up over the drop, not at the floor they hit",
		"y = %.1f" % drop.origin.y
	)

	await _steps(int(ceilf(1.6 * float(_server_game.tick_rate))))

	var mate_key := mate.player_id
	_check(
		_client_game.spectate.mode_of(me) == DotSpectatorView.Mode.FIRST_PERSON
			and _client_game.spectate.watching(me) == mate_key,
		"and then hands over to the team-mate's eyes",
		"%s on %s" % [
			DotSpectatorView.Mode.keys()[_client_game.spectate.mode_of(me)],
			String(_client_game.spectate.watching(me)),
		]
	)

	_check_watch_policy(me, mate_key, notices)

	_server_bridge.remove_player(ScNetBridge.session_of(mate_key))
	_exchange()
	_server_game.spectate_rules.force_camera = 0
	_finished()


## What the client draws and is told once somebody out is watching the team-mate under an own-side policy.
func _check_watch_policy(me: StringName, mate_key: StringName, notices: Array[String]) -> void:
	# From the CLIENT's copy of the team-mate: nothing about the camera crossed the wire but
	# who it is on, so it has to be where this client draws them.
	var copy: ScPlayer = _client_game.players.get(mate_key)
	var eye := _client_game.spectate.camera_for(me).origin
	var drawn := copy.global_position + Vector3(0.0, ScPlayer.EYE_HEIGHT, 0.0) \
		if copy != null else Vector3.INF
	_check(eye.distance_to(drawn) < 0.05, "at the eyes this client draws them with",
		"%.3f m" % eye.distance_to(drawn))

	# The other side is somebody the policy forbids, so the camera key is answered in words.
	_client_bridge.ask_spectate(0)
	_exchange()
	_exchange()
	_check(
		notices.any(func(t: String) -> bool: return t.contains("through their eyes")),
		"a camera the server's policy refuses comes back as a notice",
		" | ".join(notices)
	)
	_check(
		_client_game.spectate.mode_of(me) == DotSpectatorView.Mode.FIRST_PERSON,
		"and the camera stays where the server put it"
	)

	# And the server's own view of it, which is the one that decided.
	_check(
		not _server_game.spectate.manager.may_watch(String(me), String(_stand_in.player_id)).ok,
		"the other side's stand-in is somebody this server will not let them watch"
	)


func _test_free_roam_crosses() -> void:
	_section("free roam is asked for, the server decides, and the mode crosses the wire")
	var spectate := _server_game.spectate
	var rules := _server_game.spectate_rules
	var me := ScNetBridge.player_key(SESSION)
	# Out by a real fall (a round may have put them back in since the section before), then
	# the death camera hands over to whoever the open policy allows.
	var body: ScPlayer = _server_game.players[me]
	# A team-mate to keep the round going, or the fall ends it and everybody is back in.
	var mate := _server_bridge.add_bot("Mate", body.team)
	await _steps(6)
	if body.is_alive():
		var went := body.controller.state.position
		body.place_at(Vector3(went.x, _server_game.config.kill_height - 5.0, went.z), 0.0)
	await _steps(int(ceilf(2.5 * float(_server_game.tick_rate))))
	_check(spectate.is_spectating(me) and not spectate.is_roaming(me),
		"a watcher starts on a player, not in a free camera",
		"mode %s alive %s phase %s y %.1f" % [spectate.mode_of(me), body.is_alive(), _server_game.phase, body.global_position.y])
	_check(_client_game.spectate.is_spectating(me), "and the client's mirror is watching too")

	# The ask reaches the bridge's handler and the game's toggle_roam, not the manager direct.
	_client_bridge.ask_roam()
	await _steps(6)
	_check(spectate.is_roaming(me), "the server puts a watcher who asks into the free camera")
	_check(_client_game.spectate.is_roaming(me), "and the client's mirror is told ROAMING")
	_check(_client_game.spectate.line_for(me).contains("free camera"), "and its line names the free camera")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(me) and not _client_game.spectate.is_roaming(me),
		"the same key hands the camera back to a player on both ends")
	_check(_client_game.spectate.is_spectating(me), "and an empty target on the wire did not stop the watching")

	var notices: Array[String] = []
	_client_bridge.notice_received.connect(func(text: String) -> void: notices.append(text))
	rules.allow_roaming = false
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(me) and not _client_game.spectate.is_roaming(me),
		"mp_freeroam 0 refuses the request")
	_check(notices.any(func(t: String) -> bool: return t.contains("Free roam is off")),
		"and the refusal comes back as a notice", " | ".join(notices))
	rules.allow_roaming = true

	rules.force_camera = 1
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(me), "mp_forcecamera 1 refuses it too")
	rules.force_camera = 0

	_client_bridge.ask_roam()
	await _steps(6)
	_check(spectate.is_roaming(me), "asked again with the policy open, it roams")
	rules.allow_roaming = false
	await _steps(6)
	_check(not spectate.is_roaming(me) and not _client_game.spectate.is_roaming(me),
		"switching mp_freeroam off mid-roam puts the roamer back on a player on both ends")
	rules.allow_roaming = true
	_server_bridge.remove_player(ScNetBridge.session_of(mate.player_id))
	_exchange()
	_finished()


## A crate the server breaks throws one burst of splinters on the client, and nothing with effects off.
func _test_a_crate_breaks_in_splinters() -> void:
	_section("a crate the server breaks throws splinters on the client, none with effects off")

	var client_side := _client_game.get_parent()
	var fx := ScFx.new()
	client_side.add_child(fx)
	var built := fx.setup(null)
	_check(built.ok and fx.break_fx != null, "the client has the break effect")
	fx.break_fx.config.headless = true
	_client_bridge.shatter_received.connect(fx.on_shatter)
	var spot := Vector3(0.0, 40.0, 0.0)
	var crate := _server_game.props.spawn(ScContent.CRATE, &"world", spot)
	await _steps(4)
	var _b := _server_game.prop_damage.break_now(crate.instance_id, &"")
	_exchange()
	await _steps(3)
	_check(fx.break_fx.spawned == 1, "one broken crate is one burst", "spawned %d" % fx.break_fx.spawned)
	var root := fx.break_fx.get_child(fx.break_fx.get_child_count() - 1) as Node3D
	_check(root != null and root.name.begins_with("Break_wood") and root.get_node_or_null("Pieces") != null,
		"wood pieces are drawn")
	_check(root != null and root.global_position.distance_to(spot) < 2.0, "where the crate was")

	fx.break_fx.config.enabled = false
	var crate2 := _server_game.props.spawn(ScContent.CRATE, &"world", spot + Vector3(2.0, 0.0, 0.0))
	await _steps(4)
	_b = _server_game.prop_damage.break_now(crate2.instance_id, &"")
	_exchange()
	await _steps(3)
	_check(fx.break_fx.spawned == 1 and fx.break_fx.last_refusal == "disabled",
		"with effects off nothing is drawn", "spawned %d, %s" % [fx.break_fx.spawned, fx.break_fx.last_refusal])
	client_side.remove_child(fx)
	fx.free()
	_finished()


func _test_leaving() -> void:
	_section("leaving")

	var left: Array[int] = []
	_client_bridge.roster_changed.connect(func(id: int) -> void: left.append(id))

	var before := _client_game.players.size()

		# The stand-in, not the client under test: `remove_player` takes a leaver out of the ready set before announcing LEAVE, so the one departure a single-client suite observes is somebody else's.
	var bot_session := 0

	for session_id in _server_bridge._behaviours.keys():
		if int(session_id) != SESSION:
			bot_session = int(session_id)

	_check(bot_session != 0, "there is somebody else on the server to lose")

	_server_bridge.remove_player(bot_session)
	_exchange()
	_exchange()

	_check(
		not _server_game.players.has(ScNetBridge.player_key(bot_session)),
		"the server forgets them"
	)
	_check(left.has(bot_session), "the client is told")
	_check(
		_client_game.players.size() < before,
		"and forgets them too",
		"%d, was %d" % [_client_game.players.size(), before]
	)

	# And now the client itself, which is the path that cleans up dot-combat.
	var entity := (_server_game.players[ScNetBridge.player_key(SESSION)] as ScPlayer).entity_id
	_server_bridge.remove_player(SESSION)
	_exchange()

	_check(
		not _server_game.players.has(ScNetBridge.player_key(SESSION)),
		"and the client itself when it goes"
	)

	# [b]dot-combat keeps a health record per entity and nothing else tells it to let
	# go.[/b] game-buses-from-hell leaked one per player who ever joined, pointing at a node
	# freed with them — invisible, because a stale entity is never asked about.
	_check(_server_game.combat.health_of(entity) == null, "the combat manager let go of them")
	_check(_server_game.entities.key_for_id(entity) == &"", "and so did the entity table")

	_finished()
