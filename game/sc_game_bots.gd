extends "sc_game_state.gd"

## Part of [code]sc_game.gd[/code] (split for size): the stand-ins: aim, walk, shoot and the showdown goals. Never used on its own.


## What a stand-in does, the least that makes a round look like a round: it plays the actual game (toward a leaning
## platform's high side, off one going over; in the showdown it shoots through dot-bot's [DotBotAim]). View,
## reaction and aim are dot-bot's `bot_*`; what is true only here is `sc_bot_*` ([ScConfig]).

## What the stand-ins are called, solo and on a server; past the end dot-bot numbers them.
const BOT_NAMES := ["Wobble", "Teeter", "Lurch", "Tilt", "Keel", "Sway", "Pitch", "Yaw"]

## Each stand-in's eyes and trigger finger for this round, player id -> [DotBotAim]. Cleared
## when the next round is laid out, and the round is in the seed (see [method _bot_aim_of]).
var _bot_aims: Dictionary = {}

## Whether each stand-in's trigger was down last tick, and when it started a charge: see
## [method _bot_trigger].
var _bot_triggers: Dictionary = {}
var _bot_charges: Dictionary = {}


func _drive_bots(_delta: float) -> void:
	for id: StringName in players:
		var player: ScPlayer = players[id]

		if not player.is_bot or not player.is_alive() or player.riding:
			continue

		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch
		_bot_aim_of(player).view_from(command.yaw, command.pitch)

		# Where it wants to walk, in the world: turned into stick movement once the view is
		# decided, so turning at a person's speed never walks it the wrong way.
		var walk := Vector3.ZERO
		var deck := platforms.deck_at(player.standing_on)

		if deck != null:
			var at := player.controller.state.position
			var wanted := deck.centre

			# Uphill, which on a leaning platform is the opposite of the lean — and is also
			# the way back toward the pillar, so one target serves both reasons. A lean under
			# `sc_bot_lean_notice` degrees goes unnoticed, as it does by a person.
			if deck.tilt() > deg_to_rad(config.bot_lean_notice_degrees):
				wanted = deck.centre - Vector3(deck.lean.x, 0.0, deck.lean.y).normalized() \
					* deck.half * 0.4

			var toward := wanted - at
			toward.y = 0.0

			if toward.length() > 0.6:
				walk = toward

				# Walking rather than running when it is nearly there, which is the control
				# this whole game is about and the one thing a bot should be seen using.
				if toward.length() < 3.0 or deck.tilt() > 0.1:
					command.set_button(DotFpsCommand.BUTTON_WALK, true)

			if not deck.is_standing():
				command.set_button(DotFpsCommand.BUTTON_JUMP, true)

		var aimed := false

		if phase == Phase.SHOWDOWN and player.weapons != null:
			var advance := _aim_bot(player, command)
			aimed = advance != Vector3.INF

			if aimed and advance != Vector3.ZERO:
				walk = advance

		if not aimed and walk != Vector3.ZERO:
			var eye := player.eye_position()
			_bot_look(player, command, Vector3(eye.x + walk.x, eye.y, eye.z + walk.z))

		command.move = _bot_walk(command.yaw, walk)
		player.controller.apply_command(command)


## The living enemy of [param player] nearest it by the body's position, or null.
func _nearest_enemy(player: ScPlayer) -> ScPlayer:
	var best: ScPlayer = null
	var closest := INF

	for id: StringName in players:
		var other: ScPlayer = players[id]

		if other == player or not other.is_alive():
			continue

		if int(sides.get(id, 0)) == player.team:
			continue

		var distance := other.controller.state.position.distance_to(
			player.controller.state.position
		)

		if distance < closest:
			closest = distance
			best = other

	return best


## Turns a stand-in on the nearest enemy and fires when dot-bot allows. Returns the flat world-space way it walks
## (ZERO to hold), or [constant Vector3.INF] with nobody to fight. It sees through dot-bot's eyes (`bot_fov`,
## `bot_sight`); an unseen enemy is only turned toward, so the first shot waits `bot_reaction`.
func _aim_bot(player: ScPlayer, command: DotFpsCommand) -> Vector3:
	var best := _nearest_enemy(player)
	var aim := _bot_aim_of(player)

	if best == null:
		aim.release()
		return Vector3.INF

	var closest := best.controller.state.position.distance_to(player.controller.state.position)
	var eye := player.eye_position()
	# The chest, not the eyes: a person aims at the middle of what they can see.
	var at := best.eye_position() - Vector3(0.0, 0.35, 0.0)

	if eye.distance_to(at) < 0.01:
		return Vector3.ZERO

	var profile := _bot_settings_of(player).profile
	var distance := eye.distance_to(at)
	var reach_standing := _bot_weapon_reach(player, false)
	# Where it would rather fight from: `bot_range`, or arm's length with a hatchet or a mallet.
	var hold_at := minf(profile.range, reach_standing * 0.6)
	var sees := _bot_sees(player, eye, at)
	var wants := false

	if sees:
		wants = _bot_shoot(player, command, best.entity_id, at, best.controller.state.velocity)
	else:
		aim.release()
		_bot_look(player, command, at)

	# Standing still to shoot from range, as often as `bot_stop_to_shoot` says, decided once per engagement so it
	# does not stutter and only where it may open fire at all: two stand-ins that stopped where neither would fire
	# stood fifty metres apart until the clock ran out. See [method _bot_weapon_reach].
	var holds := closest <= hold_at or closest >= config.bot_advance_metres \
		or (sees and distance <= minf(reach_standing, profile.max_range) \
			and _bot_stops_to_shoot(player, profile))
	# Walking by what the body is doing, which is what the gun's spread follows: a stand-in
	# that means to walk but is stopped against something is standing.
	var velocity := player.controller.state.velocity
	var walking := Vector2(velocity.x, velocity.z).length() > 1.0
	var reach := _bot_weapon_reach(player, walking and not holds)
	command.set_button(DotFpsCommand.BUTTON_USER_0, _bot_trigger(player, wants and distance <= reach))

	if holds:
		return Vector3.ZERO

	# Close, but not from the far side of the map: advancing whenever the nearest enemy is further than six metres
	# marched every stand-in off its pad toward somebody sixty metres away, and two thirds of bot showdown deaths
	# were falls. Past the walk limit a bot holds its corner and shoots from it.
	var from := player.controller.state.position
	var goal := _showdown_goal(from, best.controller.state.position)

	if _showdown_zone(from).where == &"ring":
		goal = _bot_round_cover(player, from, goal)

	return Vector3(goal.x - from.x, 0.0, goal.z - from.z)


## On the ring, [param goal] or a step aside from whatever stands between it and [param from]: the blocks facing
## each pad and the dais sit on every catwalk's line, so walking it straight stopped against the first block for the
## rest of the round. Measured at knee height; each stand-in prefers its own side.
func _bot_round_cover(player: ScPlayer, from: Vector3, goal: Vector3) -> Vector3:
	if combat == null or combat.trace == null:
		return goal

	var knee := Vector3.UP * 0.5

	if combat.trace.line_of_sight(from + knee, goal + knee):
		return goal

	var flat := Vector3(goal.x - from.x, 0.0, goal.z - from.z)

	if flat.length() < 0.5:
		return goal

	var ahead := flat.normalized()
	var aside := Vector3(-ahead.z, 0.0, ahead.x)
	var side := 1.0 if hash(String(player.player_id)) % 2 == 0 else -1.0
	var middle := arena.showdown_centre()
	var inside := arena.ring_half() - 0.8

	for offset: float in [3.5 * side, -3.5 * side, 6.0 * side, -6.0 * side]:
		var step := from + ahead * minf(flat.length(), 5.0) + aside * offset
		if absf(step.x - middle.x) > inside or absf(step.z - middle.z) > inside:
			continue
		if combat.trace.line_of_sight(from + knee, step + knee):
			return step

	return goal


## Where a stand-in walking from [param from] toward [param to] heads next in the showdown: down its own catwalk,
## across the ring to the mouth of theirs, up that one. Never a straight pad-to-pad line, which leaves a 3.4 m
## catwalk on the diagonal and was a fall about thirty metres out for every stand-in at once.
func _showdown_goal(from: Vector3, to: Vector3) -> Vector3:
	if arena == null:
		return to

	var here := _showdown_zone(from)
	var there := _showdown_zone(to)
	var middle := arena.showdown_centre()
	var ring := arena.ring_half()

	# On the same arm (or both on the ring): straight at them, except along a catwalk, where
	# it keeps to the middle line toward them.
	if here.arm == there.arm:
		if here.where != &"catwalk":
			return to
		var ahead := (here.s as float) + (3.0 if (there.s as float) > (here.s as float) else -3.0)
		return _on_arm(middle, here.out, ahead, from.y)

	# Off the ring on its own arm: inward along the middle of its catwalk (or across its pad
	# to the catwalk's mouth).
	if here.where == &"pad":
		return _on_arm(middle, here.out, arena.config.corner_distance - arena.config.corner_size * 0.5 - 1.0, from.y)
	if here.where == &"catwalk":
		return _on_arm(middle, here.out, (here.s as float) - 3.0, from.y)

	# On the ring, they are out along another arm: to its mouth, then up its middle.
	var lateral: float = absf(Vector2(from.x - middle.x, from.z - middle.z).dot(there.across))
	if lateral < 0.8:
		return _on_arm(middle, there.out, Vector2(from.x - middle.x, from.z - middle.z).dot(there.out) + 3.0, from.y)

	return _on_arm(middle, there.out, ring - 1.5, from.y)


## A point [param along] metres out from the ring's middle along [param out], at height [param y].
static func _on_arm(middle: Vector3, out: Vector2, along: float, y: float) -> Vector3:
	return Vector3(middle.x + out.x * along, y, middle.z + out.y * along)


## Which part of the showdown [param at] is on: `where` is `ring`, `catwalk` or `pad`, `arm`
## the catwalk's index (-1 on the ring), `out` and `across` its directions, `s` how far out.
func _showdown_zone(at: Vector3) -> Dictionary:
	var middle := arena.showdown_centre()
	var flat := Vector2(at.x - middle.x, at.z - middle.z)
	var ring := arena.ring_half()

	if absf(flat.x) <= ring and absf(flat.y) <= ring:
		return {"where": &"ring", "arm": -1, "out": Vector2.ZERO, "across": Vector2.ZERO, "s": 0.0}

	var count := maxi(config.team_count, 1)
	var best := 0
	var best_dot := -INF

	for index in range(count):
		var corner := arena.corner_point(index, count)
		var out := Vector2(corner.x - middle.x, corner.z - middle.z).normalized()
		var along := flat.normalized().dot(out)
		if along > best_dot:
			best_dot = along
			best = index

	var corner_at := arena.corner_point(best, count)
	var out_dir := Vector2(corner_at.x - middle.x, corner_at.z - middle.z).normalized()
	var s := flat.dot(out_dir)
	var pad_inner := config.corner_distance - config.corner_size * 0.5
	return {
		"where": &"pad" if s >= pad_inner else &"catwalk",
		"arm": best,
		"out": out_dir,
		"across": Vector2(out_dir.y, -out_dir.x),
		"s": s,
	}


## Whether this engagement is one [param player] stands still for: `bot_stop_to_shoot` is a
## chance per engagement, drawn from the engagement itself so it is the same answer every tick.
func _bot_stops_to_shoot(player: ScPlayer, profile: DotBotProfile) -> bool:
	var aim := _bot_aim_of(player)
	var roll := float(hash("%s#%d#%.4f" % [String(player.player_id), aim.target_id, aim.engaged_at]) & 0xffff) / 65535.0
	return roll < profile.stop_to_shoot


## How far the weapon in [param player]'s hands is worth firing, metres, standing or [param moving]: where its
## spread still lands within `sc_bot_spray` of the aim and never past its `max_range`. Walking is far less accurate,
## so a mover holds fire until close or stops ([method _bot_stops_to_shoot]).
func _bot_weapon_reach(player: ScPlayer, moving: bool) -> float:
	var def := _bot_weapon(player)
	var ballistics := def.tuning as DotWeaponBallistics if def != null else null

	if ballistics == null:
		return INF

	var reach := ballistics.max_range if ballistics.max_range > 0.0 else INF
	var spread := ballistics.spread_moving if moving else ballistics.spread

	if spread > 0.01 and ballistics.pellets <= 1:
		reach = minf(reach, config.bot_spray_metres / tan(deg_to_rad(spread)))

	return reach


func _bot_weapon(player: ScPlayer) -> DotWeaponDef:
	if player.weapons == null or player.weapons.arsenal == null:
		return null

	return player.weapons.arsenal.current_def()


## The trigger a stand-in presses this tick when it [param wants] to fire. Held down, most weapons here fire once
## (SEMI, a burst per press, a charge rifle on RELEASE), so: held for an automatic, tapped on alternate ticks for
## one a press, held then released for the charge.
func _bot_trigger(player: ScPlayer, wants: bool) -> bool:
	var def := _bot_weapon(player)
	var was_down: bool = _bot_triggers.get(player.player_id, false)
	var down := wants

	if def != null:
		match def.fire_mode:
			DotWeaponDef.Fire.SEMI, DotWeaponDef.Fire.BURST:
				down = wants and not was_down
			DotWeaponDef.Fire.CHARGE:
				var since: int = _bot_charges.get(player.player_id, -1)

				if wants and not was_down:
					_bot_charges[player.player_id] = _tick
				elif was_down and since >= 0 \
						and _tick - since >= player.weapons.arsenal.ticks_for(def, def.charge_ticks):
					down = false

	_bot_triggers[player.player_id] = down
	return down


## Whether [param player] can see [param at] from [param eye]: inside its view cone and sight
## (`bot_fov`, `bot_sight`) and nothing of the world in the way.
func _bot_sees(player: ScPlayer, eye: Vector3, at: Vector3) -> bool:
	var profile := _bot_settings_of(player).profile
	var aim := _bot_aim_of(player)
	var toward := at - eye

	if toward.length() > profile.sight:
		return false

	# Already engaged, a target just behind the shoulder is still the target: the cone is
	# for noticing somebody, and a person tracking one does not lose them by turning.
	var engaged := aim.target_id >= 0 and _bot_now() - aim.last_seen_at <= DotBotAim.CONTINUE_WINDOW

	if not engaged and rad_to_deg(DotBotAim.direction(aim.yaw, aim.pitch).angle_to(toward)) > profile.fov * 0.5:
		return false

	if profile.through_walls > 0.5 or combat == null or combat.trace == null:
		return true

	return combat.trace.line_of_sight(eye, at)


## Aims a stand-in at [param at] (target [param id]) and says whether it fires this tick:
## dot-bot's [DotBotAim], so the view turns at `bot_turn_rate`, the first shots miss by
## `bot_aim_error` and settle, and the trigger waits `bot_reaction` after first sight.
func _bot_shoot(player: ScPlayer, command: DotFpsCommand, id: int, at: Vector3, velocity: Vector3) -> bool:
	var aim := _bot_aim_of(player)
	var eye := player.eye_position()
	var now := _bot_now()
	var _new := aim.engage(id, eye, at, now)
	var view := aim.track(eye, at, velocity, now, delta_for_tick())
	command.yaw = view.x
	command.pitch = clampf(view.y, -89.0, 89.0)
	var fire := aim.trigger(now, eye.distance_to(at))

	if fire:
		aim.note_shot(eye, at, now)

	return fire


## Turns a stand-in toward [param at] the way a person turns: at `bot_turn_rate`, never in one
## tick. Writes the view into [param command].
func _bot_look(player: ScPlayer, command: DotFpsCommand, at: Vector3) -> void:
	var view := _bot_aim_of(player).look_at_point(player.eye_position(), at, delta_for_tick())
	command.yaw = view.x
	command.pitch = clampf(view.y, -89.0, 89.0)


## Stick movement for walking along [param world_dir] (flat, world space) with the view at
## [param yaw] degrees.
static func _bot_walk(yaw: float, world_dir: Vector3) -> Vector2:
	var flat := Vector3(world_dir.x, 0.0, world_dir.z)

	if flat.length() < 0.01:
		return Vector2.ZERO

	flat = flat.normalized()
	var turned := deg_to_rad(yaw)
	var forward := Vector3(-sin(turned), 0.0, -cos(turned))
	var right := Vector3(cos(turned), 0.0, -sin(turned))
	return Vector2(flat.dot(right), flat.dot(forward)).limit_length(1.0)


## A stand-in's [DotBotAim] for this round, made on first use. The round is in the seed: the corners and slots are
## symmetric, so seeded from the id alone an empty server's showdown is a pure function of an arrangement the round
## does not change (twelve rounds, twelve wins for one side).
func _bot_aim_of(player: ScPlayer) -> DotBotAim:
	var found: Variant = _bot_aims.get(player.player_id)

	if found != null:
		return found as DotBotAim

	var aim := DotBotAim.new(
		hash("%s#%d" % [String(player.player_id), round_number]), _bot_settings_of(player)
	)
	aim.view_from(player.controller.state.yaw, player.controller.state.pitch)
	_bot_aims[player.player_id] = aim
	return aim


## The settings a stand-in plays by: the game's (`bot_difficulty` and the `bot_*` cvars), or
## its own when something attached one to the player ([method DotBotSettings.attach]), which is
## how a measurement pins a reference player whatever the server's preset is.
func _bot_settings_of(player: ScPlayer) -> DotBotSettings:
	if player.has_meta(DotBotSettings.META):
		return DotBotSettings.of(player)

	return DotBotSettings.of(self)


## The game clock in seconds, for the bots' aim.
func _bot_now() -> float:
	return float(_tick) * delta_for_tick()
