extends "sc_client_view.gd"

## The client's round half: deaths, the kill camera, the reveal and the round board. [ScClient] wires it to the world.


## The round's last moment, a death. A shot puts the victim in the shooter's eyes, anything
## else (a fall, a crush, a blast) in the victim's own.
func _note_death(victim: StringName, by: StringName, why: StringName, weapon_id: StringName = &"") -> void:
	if killcam == null:
		return
	var who: ScPlayer = game.players.get(victim)
	var name_of := who.display_name if who != null else String(victim)
	if by != &"" and game.players.has(by) and by != victim:
		killcam.note_moment(by, "put down", name_of, weapon_id)
		return
	var what := "was shot"
	match why:
		ScGame.DIED_FELL:
			what = "ran out of map"
		ScGame.DIED_CRUSHED:
			what = "was under it"
		ScGame.DIED_BLAST:
			what = "stood next to a barrel"
	killcam.note_moment(victim, what)


func _build_killcam() -> void:
	killcam = ScKillcam.new()
	killcam.name = "RoundKillcam"
	killcam.players_fn = func() -> Array: return game.players.values() if game != null else []
	killcam.player_for_fn = func(key: StringName) -> Variant: return game.players.get(key) if game != null else null
	killcam.feet_fn = func(p: ScPlayer) -> Vector3: return drawn_position(p, net != null and net.is_running() and p != player)
	killcam.colour_fn = func(p: ScPlayer) -> Color: return _team_colour(game.team_of(p.player_id))
	killcam.seconds_fn = func() -> float: return _killcam_sec if _killcam_sec >= 0.0 else game.config.killcam_seconds
	killcam.hide_while_playing = [hud, chat.window if chat != null else null]
	killcam.over.connect(func(_skipped: bool) -> void: _reveal_round())
	add_child(killcam)
	winner_reveal = DotWinnerReveal.new()
	winner_reveal.name = "WinnerReveal"
	winner_reveal.skip_actions = ScKillcam.SKIP_ACTIONS
	winner_reveal.hold_seconds = 4.0
	winner_reveal.finished.connect(_on_reveal_finished)
	add_child(winner_reveal)


func _team_colour(team: int) -> Color:
	return ScGame.TEAM_COLOURS[team - 1] if team >= 1 and team <= ScGame.TEAM_COLOURS.size() else Color(0.7, 0.7, 0.72)


## `mp_killcam_time`, from the server's replicated cvar.
func _on_killcam_cvar(cvar_name: String, value: String) -> void:
	if cvar_name == "mp_killcam_time" and value.strip_edges().is_valid_float():
		_killcam_sec = clampf(value.to_float(), 0.0, 30.0)


func _begin_round_end(number: int, winner: int) -> void:
	_round_end_number = number
	_round_end_winner = winner
	_round_ending = true
	if killcam != null:
		var _playing := killcam.round_ended()


## The winning side's players on a podium, after the killcam and before the board.
func _reveal_round() -> void:
	if not _round_ending:
		return
	var winner := _round_end_winner
	var rows: Array = []
	for key: StringName in game.players:
		var who: ScPlayer = game.players[key]
		if winner >= 1 and game.team_of(key) == winner:
			rows.append(who)
	rows.sort_custom(func(a: ScPlayer, b: ScPlayer) -> bool:
		if a.is_alive() != b.is_alive():
			return a.is_alive()
		return a.warps > b.warps)
	var entries: Array = []
	for who: ScPlayer in rows.slice(0, 3):
		entries.append({"name": who.display_name, "score": "up" if who.is_alive() else "out",
			"colour": _team_colour(winner)})
	if entries.is_empty():
		_open_round_board()
		return
	winner_reveal.reduced_motion = settings != null and settings.settings != null and settings.settings.get_bool(&"reduce_motion", false)
	var shown := winner_reveal.present(entries, {"title": "ROUND %d" % _round_end_number,
		"subtitle": "%s wins" % ScGame.TEAM_NAMES[winner - 1], "hint": "Jump to skip"})
	if not shown.ok:
		_open_round_board()
		return
	if hud != null:
		_hud_was_visible = hud.visible
		hud.visible = false


func _on_reveal_finished(_skipped: bool) -> void:
	if hud != null and not killcam.is_playing():
		hud.visible = _hud_was_visible
	if _round_ending:
		_open_round_board()


func _open_round_board() -> void:
	if board != null and not board.is_open():
		board.open()
		_round_board_open = true


## A new round: whatever is still up goes, so it never covers the start.
func _end_round_presentation() -> void:
	_round_ending = false
	if killcam != null:
		killcam.skip()
	if winner_reveal != null:
		winner_reveal.skip()
	if _round_board_open and board != null:
		board.close()
	_round_board_open = false


func _on_round(number: int, began: bool, winner: int) -> void:
	_round_presentation(number, began, winner)
	if ragdolls != null:
		# A body from before would lie on a floor that has been rebuilt or reset.
		ragdolls.clear()
	if audio != null:
		var _heard := audio.on_round(began)

	if began:
		hud.shout("ROUND %d" % number, 2.4)
		return

	var team := "Nobody"

	if winner >= 1 and winner <= ScGame.TEAM_NAMES.size():
		team = ScGame.TEAM_NAMES[winner - 1]

	hud.shout("%s wins" % team, 4.0)


func _round_presentation(number: int, began: bool, winner: int) -> void:
	if began:
		_end_round_presentation()
	else:
		_begin_round_end(number, winner)


func _on_death(session_id: int, by: int, why: StringName, weapon_id: StringName = &"") -> void:
	var id := ScNetBridge.player_key(session_id)
	var who: ScPlayer = game.players.get(id)

	_note_death(id, ScNetBridge.player_key(by) if by > 0 else &"", why, weapon_id)

	_hear_death(who, why)

	if chat == null:
		return

	var name_of := who.display_name if who != null else String(id)

	var line := "%s was shot" % name_of

	match why:
		ScGame.DIED_FELL:
			line = "%s ran out of map" % name_of
		ScGame.DIED_CRUSHED:
			line = "%s was under it" % name_of
		ScGame.DIED_BLAST:
			line = "%s stood next to a barrel" % name_of

	chat.say_locally(line, Color(0.80, 0.82, 0.86))


## A platform went. The screen shakes if it was near enough to matter.
##
## Distance-scaled, so a far collapse is seen and one under your feet is felt.
func _on_collapse(index: int, _why: StringName) -> void:
	_hear_collapse(index)

	if game.effects == null or game.platforms == null:
		return

	var deck = game.platforms.deck_at(index)

	if deck == null:
		return

	game.effects.viewer_position = camera.global_position if camera != null else Vector3.ZERO
	game.effects.shake_at(&"collapse", deck.centre, 42.0)


## The Tab board: dot-menu's, with this game's columns.
##
## Online it is the server's roster (names, pings, time on) with the replicated side, alive and warp counts joined in by id; sides are the board's teams. Offline it is [method board_snapshot].
func _dress_board() -> void:
	if board == null:
		return
	board.title_text = "Smash Copter"
	board.columns = [
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"state", "title": "", "width": 1.2},
		{"key": &"warps", "title": "Warps", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_with = func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.get("alive", false)) != bool(b.get("alive", false)):
			return bool(a.get("alive", false))
		return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0
	board.decorate = _decorate_row
	board.prepare = _prepare_board


func _decorate_row(row: Dictionary) -> void:
	if game == null:
		return
	var id := ScNetBridge.player_key(int(row.get("id", 0)))
	if not game.players.has(id):
		id = StringName(str(row.get("id", "")))
	var who: ScPlayer = game.players.get(id)
	if who == null:
		return
	var up := who.is_alive()
	row["alive"] = up
	row["state"] = "up" if up else "out"
	row["warps"] = who.warps
	row["team"] = game.team_of(id)
	if who == player:
		row["you"] = true


## The layout in the header, and the sides in play as the teams.
func _prepare_board(snap: Dictionary) -> void:
	if game == null:
		return
	if game.layout != null:
		snap["header"] = {"Layout": game.layout.display_name}
	var sides: Array = []
	for index in range(game.config.team_count):
		sides.append({"id": index + 1, "name": ScGame.TEAM_NAMES[index], "color": ScGame.TEAM_COLOURS[index]})
	snap["teams"] = sides


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var players: Array = []
	if game != null:
		for id in game.players:
			var who: ScPlayer = game.players[id]
			players.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Smash Copter", "game": "offline"}, "players": players}


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)
