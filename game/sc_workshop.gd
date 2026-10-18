extends RefCounted

const ScLayouts := preload("sc_layouts.gd")

const CHANNEL := "sc.workshop"

## Subscribed map packs in SOLO play (dot-cloud's Workshop; docs/workshop.md there).
##
## [b]A pack's `map` entry names a JSON document in `scene`[/b], because this game's levels are
## not scenes: a level is a [ScLayouts.Layout], a list of cells of the platform grid, laid out
## by the same scene every round. The document:
## [codeblock]
## {"id": "stairs", "name": "Stairs", "blurb": "Optional line for the HUD.",
##  "columns": 5, "rows": 2, "row_pitch_scale": 0.51,
##  "cells": [[0, 0, 0, 0], [1, 0, 0, 1], [2, 0, 0, 2], [1, 1, 0, 0]]}
## [/codeblock]
## A cell is `[column, row, kind, level]` (kind 0 platform, 1 bridge, 2 tower; level 0 to 7).
## `id` must equal the entry's id. Only the cells are the pack's: the pillars, the lean, the
## cannon and the rules are the game's, so a pack cannot change how a round is played.
##
## [b]Online lists none.[/b] The index answers for its session, and only a solo client calls
## [method follow]; the layouts it registers sit in [member ScLayouts.workshop], which a server
## never fills. They are never drawn at random (weight 0): somebody chose them in the M menu.

## The map kinds this game takes: provides.json's `accepts.map_kinds`, which a test compares.
## Layouts are the only kind of map here ("layout" is the game's own).
static func accepted() -> PackedStringArray:
	return PackedStringArray(["arena"])

const MAX_COLUMNS := 9
const MAX_ROWS := 5

## Entry id -> why it was refused.
var refused: Dictionary = {}

var catalogue: DotMapCatalogue = null


## Follows [param index] (the process's shared one by default).
func follow(index: DotContentIndex = null) -> void:
	catalogue = DotMapCatalogue.new()
	catalogue.follow_content(index if index != null else DotContentIndex.shared(), accepted())
	refresh()


## Re-reads the index and replaces the registered layouts with what is visible now. Returns
## the menu-less list of layout ids registered.
func refresh() -> PackedStringArray:
	ScLayouts.workshop.clear()
	var out := PackedStringArray()

	if catalogue == null:
		return out

	catalogue.refresh_content()
	var own := ScLayouts.own_ids()

	for map in catalogue.maps:
		if map.pack_title == "" or own.has(String(map.id)):
			continue

		var layout := _read(map)

		if layout != null:
			ScLayouts.workshop[layout.id] = layout
			out.append(String(layout.id))

	return out


## The id a pack map is played under.
static func layout_id(id: StringName) -> StringName:
	return StringName("workshop:%s" % id)


func _read(map: DotMapDef) -> ScLayouts.Layout:
	var text := FileAccess.get_file_as_string(map.scene_path) if map.scene_path != "" else ""
	var parsed: Variant = JSON.parse_string(text) if text != "" else null
	var why := ""
	var layout := ScLayouts.Layout.new()

	if not (parsed is Dictionary):
		why = "The map document is empty or not JSON: %s" % map.scene_path
	elif str((parsed as Dictionary).get("id", "")) != String(map.id):
		why = "The entry's id is %s but its document's id is %s." % [map.id, (parsed as Dictionary).get("id", "")]
	elif not ((parsed as Dictionary).get("cells", null) is Array) or ((parsed as Dictionary)["cells"] as Array).is_empty():
		why = "The map document has no cells list."
	else:
		why = _fill(layout, parsed as Dictionary)

	if why != "":
		refused[String(map.id)] = why
		DotLog.warn(CHANNEL, "a subscribed map was refused", {"id": String(map.id), "why": why})
		return null

	layout.id = layout_id(map.id)
	layout.display_name = map.label()
	layout.blurb = str((parsed as Dictionary).get("blurb", "A subscribed map."))
	layout.weight = 0.0
	return layout


## Reads the document's grid into [param layout]; the reason it is unusable, or "".
func _fill(layout: ScLayouts.Layout, doc: Dictionary) -> String:
	var columns := int(doc.get("columns", 0))
	var rows := int(doc.get("rows", 0))

	if columns < 1 or columns > MAX_COLUMNS or rows < 1 or rows > MAX_ROWS:
		return "columns must be 1 to %d and rows 1 to %d." % [MAX_COLUMNS, MAX_ROWS]

	var pitch := float(doc.get("row_pitch_scale", 1.0))

	if pitch < 0.4 or pitch > 1.0:
		return "row_pitch_scale must be 0.4 to 1."

	var seen := {}
	var platforms := 0

	for row: Variant in doc["cells"]:
		if not (row is Array) or (row as Array).size() != 4:
			return "A cell must be [column, row, kind, level]."

		var c := row as Array
		var col := int(c[0])
		var r := int(c[1])
		var kind := int(c[2])
		var level := int(c[3])

		if col < 0 or col >= columns or r < 0 or r >= rows:
			return "A cell lies outside the %dx%d grid." % [columns, rows]

		if kind < 0 or kind > ScLayouts.KIND_TOWER or level < 0 or level > ScLayouts.MAX_LEVEL:
			return "A cell has an unknown kind or level."

		if seen.has(Vector2i(col, r)) and kind != ScLayouts.KIND_BRIDGE:
			return "Two cells share (%d, %d)." % [col, r]

		seen[Vector2i(col, r)] = true
		platforms += 1 if kind != ScLayouts.KIND_BRIDGE else 0
		layout.custom.append(ScLayouts.make_cell(col, r, kind, level))

	if platforms < 2:
		return "A map needs at least two platforms."

	layout.columns = columns
	layout.rows = rows
	layout.row_pitch_scale = pitch
	return ""
