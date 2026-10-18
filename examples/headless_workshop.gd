extends Node

const ScConfig := preload("../game/sc_config.gd")
const ScGame := preload("../game/sc_game.gd")
const ScLayouts := preload("../game/sc_layouts.gd")
const ScWorkshop := preload("../game/sc_workshop.gd")

## What a subscribed map pack does to this game's solo layout list, against a fixture
## [DotContentIndex] and never the process's shared one: a pack map is listed as Name [Pack]
## and plays, online lists none, a map kind the game does not accept is left out, the game's
## own ids win, and a bad document is refused with a reason.
##
## [codeblock]
## godot --headless --path . res://examples/headless_workshop.tscn
## [/codeblock]

const SECTIONS := 5
const DIR := "user://ws_fixture/"

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: Array[String] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-smash-copter — Workshop maps")
	_write_fixtures()
	_test_accepts()
	_test_solo()
	_test_online()
	_test_ids_and_refused()
	await _test_play()

	ScLayouts.workshop.clear()
	print("")
	_check(_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d, %d expected)" % [_completed, _entered, SECTIONS])
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 or _completed != SECTIONS else 0)


func _write_fixtures() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_write("stairs.json", '{"id": "stairs", "name": "Stairs", "columns": 3, "rows": 2, "row_pitch_scale": 0.51, "cells": [[0,0,0,0],[1,0,0,1],[2,0,0,2],[0,1,0,0],[2,1,0,1]]}')
	_write("bad.json", '{"id": "bad", "name": "Bad", "columns": 3, "rows": 2, "cells": [[9,9,0,0],[0,0,0,0]]}')
	_write("run.json", '{"id": "run", "name": "Run", "columns": 3, "rows": 1, "cells": [[0,0,0,0],[1,0,0,0]]}')
	_write("full.json", '{"id": "full", "name": "Not Full", "columns": 3, "rows": 1, "cells": [[0,0,0,0],[1,0,0,0]]}')


func _write(file: String, text: String) -> void:
	var f := FileAccess.open(DIR + file, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _index(session: StringName) -> DotContentIndex:
	var index := DotContentIndex.new()
	index.set_session(session)
	var added := index.add_pack({
		"content_id": "fixture/decks", "version": "1.0.0", "prefix": DIR,
		"session": session, "source": &"subscription",
		"provides": {"schema": 1, "title": "Fixture Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": "stairs", "name": "Stairs", "scene": "stairs.json", "map_kind": "arena"},
			{"kind": "map", "id": "bad", "name": "Bad", "scene": "bad.json", "map_kind": "arena"},
			{"kind": "map", "id": "run", "name": "Run", "scene": "run.json", "map_kind": "surf"},
			{"kind": "map", "id": "full", "name": "Not Full", "scene": "full.json", "map_kind": "arena"},
		]},
	})
	_check(added.ok, "the fixture pack registers for %s" % session)
	return index


func _names() -> PackedStringArray:
	var out := PackedStringArray()
	for layout in ScLayouts.all(ScConfig.new()):
		out.append(layout.display_name)
	return out


func _test_accepts() -> void:
	_entered += 1
	print("")
	print("what the game accepts")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://provides.json"))
	var accepts: Dictionary = (parsed as Dictionary).get("accepts", {})
	_check(accepts.get("kinds") == ["map"], "only maps (a weapon or prop pack has nothing to feed here)", str(accepts))
	_check(PackedStringArray(accepts.get("map_kinds", [])) == ScWorkshop.accepted(),
		"map kinds match ScWorkshop.accepted()", str(accepts))
	_completed += 1


func _test_solo() -> void:
	_entered += 1
	print("")
	print("solo")
	var shop := ScWorkshop.new()
	shop.follow(_index(DotContentIndex.SESSION_SOLO))
	var names := _names()
	_check(names.has("Stairs [Fixture Pack]"), "the accepted map is listed as Name [Pack]", str(names))
	_check(not names.has("Run [Fixture Pack]"), "a map kind the game does not accept is filtered out")
	_check(not names.has("Bad [Fixture Pack]"), "a bad document is listed nowhere")
	_check(ScLayouts.allowed(ScConfig.new()).size() == names.size(), "the M menu's list is the same list")
	_completed += 1


func _test_online() -> void:
	_entered += 1
	print("")
	print("online")
	var index := _index(DotContentIndex.SESSION_SOLO)
	var shop := ScWorkshop.new()
	shop.follow(index)
	_check(ScLayouts.workshop.size() == 1, "listed while the index is solo")
	index.set_session(DotContentIndex.SESSION_ONLINE)
	var _ids := shop.refresh()
	_check(ScLayouts.workshop.is_empty(), "gone when the session turns online")
	_check(ScLayouts.by_id(ScConfig.new(), &"workshop:stairs") == null, "and not playable")
	_completed += 1


func _test_ids_and_refused() -> void:
	_entered += 1
	print("")
	print("ids and refusals")
	var shop := ScWorkshop.new()
	shop.follow(_index(DotContentIndex.SESSION_SOLO))
	var names := _names()
	_check(not names.has("Not Full [Fixture Pack]"), "the game's own id wins", str(names))
	_check(shop.refused.has("bad"), "the bad document is refused with a reason", str(shop.refused))
	_completed += 1


func _test_play() -> void:
	_entered += 1
	print("")
	print("play")
	var shop := ScWorkshop.new()
	shop.follow(_index(DotContentIndex.SESSION_SOLO))
	var config := ScConfig.new()
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.vary_layout = true
	var game := ScGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = 30
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var res := game.change_layout_now(&"workshop:stairs")
	_check(res.ok, "the map menu's change accepts the pack map")
	await get_tree().physics_frame
	_check(game.layout != null and game.layout.id == &"workshop:stairs", "the world is laid out on it",
		str(game.layout.id) if game.layout != null else "null")
	var platforms := 0
	for i in range(game.platforms.count()):
		if not game.platforms.deck_at(i).is_bridge:
			platforms += 1
	_check(platforms == 5 and game.platforms.count() == 5, "the document's cells are the field",
		"%d platforms of %d" % [platforms, game.platforms.count()])
	_check(game.layout_rows().any(func(r: Dictionary) -> bool: return r["name"] == "Stairs [Fixture Pack]" and r["current"]),
		"the M menu lists it as the current map")
	var bogus := game.change_layout_now(&"workshop:nothing")
	_check(not bogus.ok, "an unknown pack map is refused cleanly")
	game.queue_free()
	await get_tree().process_frame
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what)
		print("  FAIL  %s %s" % [what, detail])
