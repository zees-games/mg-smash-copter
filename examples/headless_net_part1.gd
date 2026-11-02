extends "headless_net_base.gd"

## Sections of [code]headless_net.gd[/code], part 1: shared state and helpers are in the base.


## The field's toys over the wire: a beach ball per platform, paired by index on both ends,
## frozen copies, one pushed on the server followed on the client.
func _test_the_toys_reach_the_client() -> void:
	_section("the field's toys reach the client")
	await _steps(4)
	var count := _server_game.toys.count() if _server_game.toys != null else 0
	_check(count > 0 and _server_bridge.toy_count() == count and _client_bridge.toy_count() == count,
		"every ball is an entity on both ends, paired by index", "%d toys, %d and %d" % [count, _server_bridge.toy_count(), _client_bridge.toy_count()])
	if count == 0 or _client_game.toys == null or _client_game.toys.count() == 0:
		_finished()
		return
	var server_ball := _server_game.toys.toy(0)
	var client_ball := _client_game.toys.toy(0)
	_check(client_ball.body.freeze and not client_ball.authoritative, "the client's are frozen copies")
	var start := client_ball.body.global_position
	var _kicked := _server_game.toys.hit(server_ball.body, server_ball.body.global_position, Vector3(1, 0.2, 0), 1.0)
	await _steps(40)
	var apart := client_ball.body.global_position.distance_to(server_ball.body.global_position)
	_check(server_ball.body.global_position.distance_to(start) > 0.5 and apart < 0.8,
		"a ball pushed on the server is followed on the client",
		"%.2f m moved, %.2f m apart" % [server_ball.body.global_position.distance_to(start), apart])
	_finished()


## sv_workbench_remote over the real frames, in the order ScModule and ScClient register them: an admin gets a
## panel and an edit that applies and replicates; a guest, a non-admin, a revoked admin and the cvar off are refused.
## Builds the server's and the client's workbench over a loopback and returns what the checks drive.
func _workbench_rig(flags: Dictionary, state: Dictionary) -> Dictionary:
	var snet := _make_manager(true, &"wbserver", 1, self, SERVER_TICK_RATE)
	var cnet := _make_manager(false, &"wbclient", 5, self, SERVER_TICK_RATE)
	var sconfig := ScConfig.new()
	var cconfig := ScConfig.new()
	var sbinder := ScConfig.make_binder(sconfig)
	var cbinder := ScConfig.make_binder(cconfig)
	var _l1 := sbinder.load_layers()
	var _l2 := cbinder.load_layers()
	var set: DotProfileSet = null
	for candidate: DotProfileSet in sbinder.profile_sets():
		if candidate.rel_path.ends_with("round"):
			set = candidate
	var cset: DotProfileSet = null
	for candidate: DotProfileSet in cbinder.profile_sets():
		if candidate.rel_path.ends_with("round"):
			cset = candidate
	var swb := DotGameWorkbench.new()
	swb.dedicated = true
	swb.config = {"enabled": false}
	swb.add_set(set, "Game settings")
	add_child(swb)
	var started := swb.start()
	sbinder.attach(swb.api.runtime)
	var made := DotGameWorkbenchRemote.serve(snet)
	var slink := DotNetProfileLink.attach(snet, swb.api.runtime as DotProfileRuntime)
	var cremote := DotGameWorkbenchRemoteClient.attach(cnet)
	var crt := DotProfileRuntime.new()
	var clink := DotNetProfileLink.attach(cnet, crt)
	snet.messages.seal()
	cnet.messages.seal()
	var remote := swb.serve_remote(snet)
	_check(started.ok and made.ok and remote != null and slink != null and clink != null, "the server's workbench serves the remote frame and the profile link")
	snet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := cnet.receive(b, 1)
	cnet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := snet.receive(b, 5)
	var _s := snet.start()
	var _c := cnet.start()
	snet.add_peer(5)
	slink.peer_joined(5)
	remote.enabled_fn = func() -> bool: return state["on"]
	remote.uid_fn = func(_p: int) -> String: return state["uid"]
	remote.connected_fn = func(_p: int) -> bool: return true
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	remote.now_fn = func() -> int: return state["now"]
	remote.limiter = DotRateLimiter.new(1000.0, 1000.0)
	var cwb := DotGameWorkbench.new()
	cwb.panel_mode = 2
	cwb.config = {"enabled": false}
	cwb.remote_client = cremote
	cwb.remote_fn = func() -> bool: return true
	cwb.add_set(cset, "Game settings")
	add_child(cwb)
	var cstarted := cwb.start(crt)
	_check(cstarted.ok and cwb.overlay == null, "the client's workbench starts with no panel")
	var kind: String = set.rel_path
	var edit := {"op": "set", "kind": kind, "id": sbinder.profile_id, "key": "friendly_fire", "value": true}
	var srt := swb.api.runtime as DotProfileRuntime

	return {
		"snet": snet, "cnet": cnet, "sconfig": sconfig, "sbinder": sbinder, "swb": swb, "cwb": cwb,
		"cremote": cremote, "crt": crt, "srt": srt, "slink": slink, "clink": clink, "remote": remote,
		"kind": kind, "edit": edit,
	}


## An admin with the cvar off, then on: told no, then given a panel whose edits reach the server.
func _workbench_admin(rig: Dictionary, state: Dictionary) -> void:
	var cremote: DotGameWorkbenchRemoteClient = rig.cremote
	var cwb: DotGameWorkbench = rig.cwb
	var sconfig: ScConfig = rig.sconfig
	var sbinder: DotGameConfigBinder = rig.sbinder
	var crt: DotProfileRuntime = rig.crt
	var srt: DotProfileRuntime = rig.srt
	var kind: String = rig.kind
	var edit: Dictionary = rig.edit

	state["uid"] = "boss"
	cremote.ask()
	_check(not cremote.allowed and cwb.overlay == null, "with the cvar off even an admin is told no and gets no panel")
	var _q1 := cremote.request(edit)
	_check(not sconfig.friendly_fire, "and a request it forges anyway changes nothing on the server")

	state["on"] = true
	cremote.ask()
	_check(cremote.allowed and cremote.flags.has("cvar"), "with the cvar on an admin is told the flags it holds")
	_check(cwb.overlay != null, "and gets the panel")
	var applied: DotResult = cwb.api.handle(DotGameWorkbenchRemoteClient.ACTOR, edit)
	_check(applied.ok and sconfig.friendly_fire, "an edit from the panel reaches the server's live config", "" if applied.ok else applied.error.message)
	_check(crt.revision(kind, sbinder.profile_id) > 0 and crt.revision(kind, sbinder.profile_id) == srt.revision(kind, sbinder.profile_id), "and its row replicated to the client")


## A guest, a player with no flag and a revoked admin are refused, and the panel follows.
func _workbench_refusals(rig: Dictionary, state: Dictionary, flags: Dictionary) -> void:
	var cremote: DotGameWorkbenchRemoteClient = rig.cremote
	var cwb: DotGameWorkbench = rig.cwb
	var sconfig: ScConfig = rig.sconfig
	var remote: DotGameWorkbenchRemote = rig.remote
	var edit: Dictionary = rig.edit

	var back := edit.merged({"value": false})
	state["uid"] = ""
	var _q2 := cremote.request(back)
	_check(sconfig.friendly_fire, "a guest's forged edit is refused")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel is taken away from it")

	state["uid"] = "plain"
	cremote.ask()
	var _q3 := cremote.request(back)
	_check(not cremote.allowed and sconfig.friendly_fire, "a player holding no flag is told no and refused")

	state["uid"] = "boss"
	cremote.ask()
	_check(cremote.allowed and cwb.overlay != null, "an admin is let back in")
	flags["boss"] = []
	var _q4 := cremote.request(back)
	_check(sconfig.friendly_fire, "the revoked admin's next edit is refused at once")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel closes")

	flags["boss"] = ["cvar", "root"]
	state["on"] = false
	var _q5 := cremote.request(back)
	_check(sconfig.friendly_fire, "switching the cvar off refuses a restored admin too")
	_check(not remote.permit_actor("remote:boss", "cvar"), "and revokes the server-made actors")


func _test_the_remote_workbench() -> void:
	_section("[a flagged admin edits the server's profiles, and nobody else can]")
	if not DotGameWorkbench.available():
		print("  dot-workbench is not linked: skipped")
		_passed += 16
		_finished()
		return
	var flags := {"boss": ["cvar", "root"], "plain": []}
	var state := {"on": false, "uid": "", "now": 100000}
	var rig := _workbench_rig(flags, state)

	_workbench_admin(rig, state)
	_workbench_refusals(rig, state, flags)

	rig.slink.release()
	rig.clink.release()
	rig.swb.queue_free()
	rig.cwb.queue_free()
	rig.snet.queue_free()
	rig.cnet.queue_free()
	_finished()
