extends "sc_module_base.gd"

## The layout vote's hooks into the world and the server (who votes, what is on the ballot, who sees it), split from `sc_module.gd`, which extends this and builds the vote in `_build_vote`.


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func _rotation_commands() -> Dictionary:
	return maps.commands_spec() if maps != null else {}


func _bind_vote_hooks(world: ScGame) -> void:
	# Nothing to vote on when the operator turned the per-round draw off: they asked for one
	# layout all evening.
	vote.maps_fn = func() -> Array:
		var out: Array = []

		if not world.config.vary_layout:
			return out

		# From the catalogue gs-map lists, so the ballot and `maps` can never disagree.
		for def in maps.catalogue.available() if maps != null else []:
			out.append([def.id, def.display_name])

		return out
	vote.apply_fn = func(id: StringName) -> GSResult:
		world.next_layout_id = id
		return GSResult.success(id)
	# People only: a stand-in is not a voter, and a ballot it could swing is not the players'.
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: ScPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := ScNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, ScServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(GSAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, GSNotice.make(
				&"", "", float(state.get("seconds", -1.0)), LAYOUT_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	# Whether a round is live, for `time_up: finish_round`: warmup and the gap between rounds
	# have nothing to play out, so a limit that runs out there changes at once. No match is
	# "cannot tell", which holds as before.
	vote.round_in_progress_fn = func() -> bool:
		return world.match_node == null or world.match_node.is_live()
