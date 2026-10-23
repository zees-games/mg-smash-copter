extends Node

const ScGame := preload("../game/sc_game.gd")
const ScPlatforms := preload("../game/sc_platforms.gd")
const ScLayouts := preload("../game/sc_layouts.gd")
const ScVote := preload("../game/sc_vote.gd")

## Renders the game and exits. The check no assertion in this repository makes.
##
## [b]Everything about this map that can be wrong is invisible to every check in the
## suite.[/b] The suite proves a platform leans toward a load, collapses at an angle and
## carries what is on it. Not one of its ninety-five checks can tell you that the lean is
## the wrong way round on screen, that a pillar is drawn through its own platform, that the
## prototype grid came out one metre or eight, that the chopper is a pile of boxes, or that
## a player forty metres up cannot see the floor they are standing on. Four bugs in this
## family were each found by a picture, and one of them — the sign of a platform's normal —
## was found in this game by an assertion only because the assertion was written to measure
## the surface rather than the state.
##
## xvfb-run, never `--headless`: the headless display driver does no rendering at all, so a
## capture under it is a black PNG — which is worse than no screenshot, because it looks
## like one.
##
## [codeblock]
## tools/shot.sh                  # the field from a player's eyes
## tools/shot.sh --view=cover     # the loading cover, before it lifts
## tools/shot.sh --view=field     # the whole map from above and to one side
## tools/shot.sh --view=lean      # a platform that has been leant on, from its own level
## tools/shot.sh --view=copter    # the chopper, close
## tools/shot.sh --view=showdown  # the corners the round is finished in
## tools/shot.sh --view=dais      # the ring's dais, low, from where a catwalk meets the ring
## tools/shot.sh --view=jump      # the first jump the layout means, from behind the runner
## tools/shot.sh --view=bridge    # a bridge leant on at one end, from beside it
## tools/shot.sh --view=beacon    # an admin's beacon on a stand-in, from across the field
## tools/shot.sh --view=killcam --seconds=2   # the round's last moment replayed; --seconds=8 for the podium
## tools/shot.sh --view=blind     # the local player's own eyes, blinded, through the real HUD
## tools/shot.sh --view=spectate  # the local player, out, through the camera the server gave them
## tools/shot.sh --ballot          # the layout vote's ballot over any view, mid-vote
## [/codeblock]

# No `const CHANNEL`: this is a command-line tool, and what it says is its output (`print`),
# not a record for an operator's log.


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var seconds := 4.0
	var out := "res://screenshots/smash.png"
	var view := "eyes"
	var ballot := false
	var workshop := false

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			seconds = float(arg.substr(10))
		elif arg.begins_with("--out="):
			out = arg.substr(6)
		elif arg.begins_with("--view="):
			view = arg.substr(7)
		elif arg == "--ballot":
			ballot = true
		elif arg == "--workshop":
			workshop = true

	# A subscribed pack map, standing in for the Workshop's: a fixture document registered in
	# the shared index as solo, before the client follows it.
	if workshop:
		_register_fixture_pack()

	var client: Node = load("res://game/sc.tscn").instantiate()
	add_child(client)

	# --view=cover: the loading cover dot-game's DotGameClient puts up first, before it lifts.
	if view == "cover":
		for _i in 2:
			await RenderingServer.frame_post_draw
		var platform: DotGameClient = client.get("platform")
		print("cover %s" % ("lifted" if platform.is_shown() else "up"))
		var cover_path := ProjectSettings.globalize_path(out)
		DirAccess.make_dir_recursive_absolute(cover_path.get_base_dir())
		print("saved %s: %s" % [out, error_string(get_viewport().get_texture().get_image().save_png(cover_path))])
		get_tree().quit(0)
		return

	var elapsed := 0.0

	if workshop:
		while client.get("game") == null:
			await get_tree().process_frame
		var chosen: DotResult = (client.get("game") as ScGame).change_layout_now(&"workshop:crown")
		print("workshop map chosen: ", chosen.ok)

	# --view=killcam spends --seconds after the round ends, not before.
	var lead := 4.0 if view == "killcam" else seconds
	while elapsed < lead:
		elapsed += get_process_delta_time()
		await get_tree().process_frame

	var game: ScGame = client.get("game")

	# The two admin marks go on through the flags the server would have set — offline, the
	# client IS the server — and are then drawn by the client's own `_process`, which is the
	# whole path a connected client takes after a snapshot has delivered them.
	if game != null and view == "blind":
		var me: Node = client.get("player")
		if me != null:
			me.set("blinded", true)
		for _i in range(40):
			await get_tree().process_frame
	elif game != null and view == "spectate":
		# Off the edge, through the same fall check a real one goes through, and then long
		# enough for the death camera to hand over. What is drawn is the client's own
		# `_process` putting its camera where `ScSpectate` says — nothing here places one.
		var out_of_it: Node = client.get("player")
		if out_of_it != null:
			var at: Vector3 = (out_of_it.get("controller") as DotFpsController).state.position
			out_of_it.call("place_at", Vector3(at.x, game.config.kill_height - 5.0, at.z), 0.0)
		var waited := 0.0
		while waited < 2.4:
			waited += get_process_delta_time()
			await get_tree().process_frame
	elif game != null and view == "killcam":
		# Everybody else goes over the edge through the fall check, so the round ends on the
		# last of them; ~2 s later is the replay, ~8 the podium.
		var me_k: Node = client.get("player")
		for who: Node in game.players.values():
			if who != me_k:
				var at_k: Vector3 = (who.get("controller") as DotFpsController).state.position
				who.call("place_at", Vector3(at_k.x, game.config.kill_height - 5.0, at_k.z), 0.0)
		var waited_k := 0.0
		while waited_k < seconds:
			waited_k += get_process_delta_time()
			await get_tree().process_frame
	elif game != null and view == "hands":
		# The local player's own eyes once the showdown is on: the gun the handover dealt, in
		# their hands, and its counter. Offline the hands were never armed (ScClient._start_offline).
		var waited_hands := 0.0
		while waited_hands < 60.0 and game.phase != ScGame.Phase.SHOWDOWN:
			waited_hands += get_process_delta_time()
			await get_tree().process_frame
		for _i in range(60):
			await get_tree().process_frame
	elif game != null and view != "eyes":
		await _place_camera(game, view)

	if game != null and ballot:
		var list: Array = []
		for layout in ScLayouts.allowed(game.config):
			list.append([layout.id, layout.display_name])
		await _show_ballot(list, game.layout.id if game.layout != null else &"")

	await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	var _saved := image.save_png(ProjectSettings.globalize_path(out))

	print("wrote ", out, " after %.1f s, view=%s" % [elapsed, view])

	if game != null:
		for line in game.describe_lines():
			print(line)

	get_tree().quit(0)


func _register_fixture_pack() -> void:
	DirAccess.make_dir_recursive_absolute("user://ws_shot/")
	var cells: Array = []
	for row in range(3):
		for column in range(7):
			if column == 3 and row == 1:
				continue
			cells.append([column, row, 0, (column + row) % 4])
	var f := FileAccess.open("user://ws_shot/crown.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"id": "crown", "name": "Crown", "columns": 7, "rows": 3,
		"row_pitch_scale": 0.51, "cells": cells}))
	f.close()
	var index := DotContentIndex.shared()
	index.set_session(DotContentIndex.SESSION_SOLO)
	var added := index.add_pack({
		"content_id": "fixture/shot", "version": "1.0.0", "prefix": "user://ws_shot/",
		"session": DotContentIndex.SESSION_SOLO, "source": &"subscription",
		"provides": {"schema": 1, "title": "Fixture Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": "crown", "name": "Crown", "scene": "crown.json", "map_kind": "arena"}]},
	})
	print("fixture pack: ", added.ok)


## A real ballot from this game's vote: every layout this server plays there is, four voters, three of whom
## have voted, drawn the way the client shell's notice overlay draws a `map_ballot` — a
## [DotBallotPanel] down the right-hand side. Waits a second for the voters' discs to slide
## to the row they chose; a frame too soon catches one between rows.
func _show_ballot(list: Array, current: StringName) -> void:
	var names := {&"1": "you", &"2": "bo", &"3": "quiet_one", &"4": "ana"}
	var states: Array = []
	var vote: Node = ScVote.new()
	vote.set("config_path", "")
	vote.set("layouts_fn", func() -> Array: return list)
	vote.set("voters_fn", func() -> Array: return names.keys())
	vote.set("people_fn", func(voter: StringName) -> Dictionary: return {"name": names.get(voter, "?"), "avatar": ""})
	vote.set("ballot_fn", func(state: Dictionary) -> void: states.append(state))
	add_child(vote)
	var _set: DotResult = vote.call("setup")
	vote.call("note_layout", current)
	var director: DotVoteDirector = vote.get("director")
	var _opened := director.open_vote(DotVoteClock.REASON_MANUAL)
	var options := director.ballot.option_ids()
	var _a := director.cast_one(&"1", options[0])
	var _b := director.cast_one(&"2", options[1 % options.size()])
	var _c := director.cast_one(&"3", options[0])
	(vote.get("feed") as DotVoteBallotFeed).poll()

	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var box := VBoxContainer.new()
	box.anchor_left = 1.0
	box.anchor_right = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = -376.0
	box.offset_right = -16.0
	box.offset_top = 110.0
	box.offset_bottom = -16.0
	layer.add_child(box)
	var panel := DotBallotPanel.new()
	panel.ui_theme = DotUiTheme.space()
	panel.local_voter = "1"
	box.add_child(panel)
	panel.show_state(states.back() if not states.is_empty() else {})

	var waited := 0.0
	while waited < 1.0:
		waited += get_process_delta_time()
		await get_tree().process_frame


## Puts a camera somewhere a first-person one can never be.
##
## [b]The one thing a player's own camera cannot show is the thing they are standing on.[/b]
## Every view below exists because a question about this map cannot be answered from eye
## height: whether the field reads as a field, whether a lean reads as a lean, and whether
## the machine in the sky reads as a helicopter.
func _place_camera(game: ScGame, view: String) -> void:
	var camera := Camera3D.new()
	camera.name = "Look"
	camera.fov = 70.0
	add_child(camera)

	match view:
		"field":
			# High and off one corner, which is the only angle that shows a grid of
			# platforms AS a grid — and the only one that shows how far apart they are,
			# which is the decision a player makes every few seconds.
			var reach := float(game.config.columns) * game.config.column_pitch
			camera.global_position = Vector3(
				reach * 0.78, game.config.deck_height + reach * 0.52, reach * 0.92
			)
			camera.look_at(Vector3(0.0, game.config.deck_height - 6.0, 0.0), Vector3.UP)
		"lean":
			await _lean_one(game)
			var deck := game.platforms.deck_at(0)

			if deck == null:
				camera.global_position = Vector3(0.0, game.config.deck_height + 10.0, 30.0)
				camera.look_at(Vector3(0.0, game.config.deck_height, 0.0), Vector3.UP)
				return

			# [b]Square on to the axis it is leaning about, and far enough back to see both
			# edges.[/b] A tilt photographed from above is a rhombus and a tilt photographed
			# from on top of it is nothing at all: what says which way a platform has gone is
			# one edge being lower than the other against the sky, which needs the camera at
			# about deck height and off to the side of the lean rather than along it.
			camera.global_position = deck.centre + Vector3(
				0.0, 3.4, deck.half * 4.2
			)
			camera.look_at(deck.centre, Vector3.UP)
		"copter":
			var copter := _a_copter(game)

			if copter == null:
				camera.global_position = Vector3(0.0, game.config.deck_height + 14.0, 26.0)
				camera.look_at(Vector3(0.0, game.config.deck_height, 0.0), Vector3.UP)
			else:
				var at := copter.position()
				camera.global_position = at + Vector3(9.0, 3.4, 9.0)
				camera.look_at(at, Vector3.UP)
		"rider":
			# [b]A person standing on the machine.[/b] They are put on the cab roof and the
			# camera sits beside it, which is the one picture of whether the carry reads as
			# riding and not as hovering beside it.
			var machine := _a_copter(game)
			var rider: Node3D = null

			for key: StringName in game.players:
				rider = game.players[key]
				break

			if machine == null:
				camera.global_position = Vector3(0.0, game.config.deck_height + 14.0, 26.0)
				camera.look_at(Vector3(0.0, game.config.deck_height, 0.0), Vector3.UP)
			else:
				var up := machine.position()

				if rider != null and rider.has_method("place_at"):
					rider.place_at(up + Vector3(0.0, 2.4, 0.0), 0.0)

				camera.global_position = up + Vector3(7.0, 2.6, 7.0)
				camera.look_at(up + Vector3(0.0, 1.2, 0.0), Vector3.UP)
		"jump":
			# [b]From where a runner stands before the jump the layout MEANS[/b], a little
			# above their eye, looking along the line they will run. A field from above says
			# where the platforms are and nothing about whether the gap between two of them
			# is a jump; this is the picture of the one question the reach section asks.
			var pair := _first_meant_jump(game)

			if pair == Vector2i(-1, -1):
				camera.global_position = Vector3(0.0, game.config.deck_height + 18.0, 42.0)
				camera.look_at(Vector3(0.0, game.config.deck_height, 0.0), Vector3.UP)
			else:
				var from := game.platforms.deck_at(pair.x).centre
				var to := game.platforms.deck_at(pair.y).centre
				var line := Vector3(to.x - from.x, 0.0, to.z - from.z).normalized()
				camera.global_position = from - line * 4.0 + Vector3.UP * 3.2
				camera.look_at(to + Vector3.UP * 0.5, Vector3.UP)
		"bridge":
			# [b]From beside the first bridge, at deck height, with one end weighed down.[/b]
			# What it answers is whether a bridge lies on its two lips: the loaded platform's
			# near edge dips, and the bridge has to run from that dipped lip to the level one
			# with no step at either end and no lean of its own.
			var span := await _lean_a_bridge(game)

			if span == null:
				camera.global_position = Vector3(0.0, game.config.deck_height + 18.0, 42.0)
				camera.look_at(Vector3(0.0, game.config.deck_height, 0.0), Vector3.UP)
			else:
				var outside := -1.0 if span.centre.x <= 0.0 else 1.0
				camera.global_position = span.centre + Vector3(outside * 11.0, 1.4, 0.0)
				camera.look_at(span.centre + Vector3(0.0, -0.8, 0.0), Vector3.UP)
		"beacon":
			var marked := _beacon_a_stand_in(game)

			if marked == null:
				camera.global_position = Vector3(0.0, game.config.deck_height + 18.0, 42.0)
				camera.look_at(Vector3(0.0, game.config.deck_height, 0.0), Vector3.UP)
			else:
				# Let the client draw it for a while, so the ripple is somewhere in its spread
				# rather than always at the frame it started.
				for _i in range(36):
					await get_tree().process_frame
				var at := marked.global_position
				# Across the field and a little above deck height, which is how a player on
				# another platform sees somebody — the column has to read from there.
				camera.global_position = at + Vector3(-16.0, 7.0, 20.0)
				camera.look_at(at + Vector3(0.0, 4.0, 0.0), Vector3.UP)
		"ring":
			# From team 0's pad at eye height, across the catwalk at the ring: its cover
			# block should stand square in the middle of the frame.
			var ring_middle := game.arena.showdown_centre()
			var pad := game.arena.corner_point(0, game.config.team_count)
			camera.global_position = pad + Vector3.UP * 1.7
			camera.look_at(ring_middle + Vector3.UP * 0.6, Vector3.UP)
		"junction":
			# Above the LAST team's catwalk where it meets the ring, looking down at the join:
			# with three sides that is an oblique one, where a slab that runs on into the ring
			# shows as kerb stubs standing on the ring's floor.
			var ring_middle := game.arena.showdown_centre()
			var count := game.config.team_count
			var pad := game.arena.corner_point(count - 1, count)
			var out := Vector3(pad.x - ring_middle.x, 0.0, pad.z - ring_middle.z).normalized()
			var join := ring_middle + out * game.arena.ring_half()
			camera.global_position = join + out * 9.0 + Vector3.UP * 11.0
			camera.look_at(join - out * 2.0, Vector3.UP)
		"flank":
			# From behind perch 0 and above it, at the ring: the perch in front, the two flank
			# catwalks running off to the pads either side, and the ring's blocks side-on.
			var ring_middle := game.arena.showdown_centre()
			var perch := game.arena.perch_point(0, game.config.team_count)
			var away := Vector3(perch.x - ring_middle.x, 0.0, perch.z - ring_middle.z).normalized()
			camera.global_position = perch + away * 14.0 + Vector3.UP * 9.0
			camera.look_at(ring_middle + Vector3.UP * 0.6, Vector3.UP)
		"armed":
			# [b]Somebody else holding a gun, close[/b]: the clock wound to the showdown, a
			# stand-in that was handed a weapon, and the camera a few metres in front of them
			# and to their left, at chest height — where the question "is the gun in the hand,
			# the right way round and the right size" has an answer.
			# Shorten the survival half with `--sc-survival-seconds=10 --seconds=16` rather than
			# winding the clock here: a wound clock skipped the handover's teleport and ended the
			# round. Waited out until somebody is armed, for up to ten seconds.
			var waited := 0.0
			while waited < 10.0 and game.phase != ScGame.Phase.SHOWDOWN:
				waited += get_process_delta_time()
				await get_tree().process_frame
			for _i in range(90):
				await get_tree().process_frame
			var carrier: Node3D = null
			for key: StringName in game.players:
				var body: Node3D = game.players[key]
				if body != null and bool(body.get("is_bot")) and body.call("is_alive") \
						and body.get("weapons") != null:
					carrier = body
					break
			if carrier == null:
				camera.global_position = game.arena.showdown_centre() + Vector3(0.0, 12.0, 18.0)
				camera.look_at(game.arena.showdown_centre(), Vector3.UP)
			else:
				var figure: Node3D = carrier.get("figure")
				var at: Vector3 = figure.global_position if figure != null else carrier.global_position
				var facing: Vector3 = -(figure.global_basis.z if figure != null else carrier.global_basis.z)
				facing.y = 0.0
				facing = facing.normalized()
				var left := facing.cross(Vector3.UP).normalized() * -1.0
				camera.global_position = at + facing * 3.2 + left * 1.6 + Vector3.UP * 1.5
				camera.look_at(at + Vector3.UP * 1.1, Vector3.UP)
				print("armed: %s holding %s" % [
					String(carrier.get("player_id")),
					str(figure.call("describe").get("holding", "")) if figure != null else "no figure",
				])
		"showdown":
			var middle := game.arena.showdown_centre()
			camera.global_position = middle + Vector3(
				0.0, game.config.corner_distance * 0.9, game.config.corner_distance * 1.5
			)
			camera.look_at(middle, Vector3.UP)
		"dais":
			# [b]Low, from about where a pad's catwalk reaches the ring[/b], because the
			# question is whether the dais reads as a step a person jumps onto and as cover
			# from that side, and from above a 0.9 m block is a square on the floor.
			var middle := game.arena.showdown_centre()
			camera.global_position = middle + Vector3(3.0, 2.4, 11.0)
			camera.look_at(middle + Vector3.UP * 0.5, Vector3.UP)
		_:
			camera.global_position = Vector3(0.0, game.config.deck_height + 18.0, 42.0)
			camera.look_at(Vector3(0.0, game.config.deck_height, 0.0), Vector3.UP)

	camera.current = true
	await get_tree().process_frame


## The first pair of platforms the round's layout means a player to jump between.
func _first_meant_jump(game: ScGame) -> Vector2i:
	if game.layout == null or game.layout.jumps == 0:
		return Vector2i(-1, -1)

	for pair: Vector3i in ScLayouts.pairs(game.platforms.cells()):
		if (game.layout.jumps & pair.z) != 0:
			return Vector2i(pair.x, pair.y)

	return Vector2i(-1, -1)


## Leans the first platform hard, so there is something to photograph.
##
## A platform in a fresh round is level, and a picture of a level platform says nothing
## about whether the lean is drawn the right way round — which is the bug this view exists
## to catch.
func _lean_one(game: ScGame) -> void:
	var platforms := game.platforms
	var deck := platforms.deck_at(0)

	if deck == null:
		return

	var at := deck.centre + Vector3(deck.half * 0.85, 0.0, 0.0)

	# [b]Heavy, because the spring is the point.[/b] A platform finds an equilibrium against
	# whatever is standing on it, so an ordinary player's eighty kilograms is three degrees —
	# which is exactly the amount a picture cannot settle. What is being checked here is which
	# WAY it goes, so the load is enough to take it near its own collapse angle.
	for _i in range(90):
		platforms.begin_loads()
		platforms.add_load(0, at, 520.0, 0.0)
		platforms.step(1.0 / 64.0)
		await get_tree().process_frame

	print("leaned platform 0 by %.1f degrees toward +X" % rad_to_deg(deck.tilt()))


## Weighs the near end of the first bridge down, so there is a slope to photograph.
func _lean_a_bridge(game: ScGame) -> ScPlatforms.Deck:
	var platforms := game.platforms

	for i in range(platforms.count()):
		var span := platforms.deck_at(i)

		if not span.is_bridge:
			continue

		var at := Vector3(span.centre.x, span.centre.y, span.lips.x + 0.8)

		for _i in range(120):
			platforms.begin_loads()
			platforms.add_load(i, at, 420.0, 0.0)
			platforms.step(1.0 / 64.0)
			await get_tree().process_frame

		print("bridge %d: %.1f degrees; the loaded platform %.1f" % [
			i, rad_to_deg(span.tilt()), rad_to_deg(platforms.deck_at(span.supports.x).tilt())])
		return span

	return null


## Turns a beacon on over the first stand-in that is up, and returns them.
func _beacon_a_stand_in(game: ScGame) -> Node3D:
	for key: StringName in game.players:
		var body: Node3D = game.players[key]

		if body != null and bool(body.get("is_bot")) and body.call("is_alive"):
			body.set("beacon", true)
			print("beaconed %s at %s" % [String(key), body.global_position])
			return body

	return null


func _a_copter(game: ScGame) -> DotVehicleInstance:
	if game.vehicles == null:
		return null

	var all := game.vehicles.all_vehicles()

	if not all.is_empty():
		return all[0]

	# A layout without one still has to be photographable, or the only way to look at the
	# machine is to keep re-rolling until a layout with a pad comes up.
	return game.vehicles.spawn(
		&"copter",
		Vector3(0.0, game.config.deck_height + game.config.chopper_pad_height, 0.0),
		&"world"
	)
