extends DotMapSession

## A [DotMapSession] whose maps are layouts.
##
## [b]dot-map assumes a map is a scene it loads and swaps, and here a map is the arrangement of
## platforms the same scene lays out each round.[/b] Loading one would replace the world a
## round is being played in, so [method change_to_map] is overridden to hand the choice to the
## game (`apply_fn`, which is `ScGame.change_layout_now` for an admin and the vote's
## "next round" for a ballot) and to keep the rest of dot-map as it is: the catalogue the
## commands and the ballot list, the rotation's history, `current`, and the `changed` signal.
## Nothing here opens a scene or announces to clients, because a client is told the layout by
## the game's own LAYOUT event every round, which is the thing a sync host would be for.

const LOG_CHANNEL := "smash.map.session"

## `func(id: StringName) -> DotResult`: play this layout. The host's.
var apply_fn: Callable = Callable()


func change_to_map(map: DotMapDef) -> DotResult:
	if map == null:
		return DotResult.fail(DotError.CODE_INVALID, "No map.")

	if not apply_fn.is_valid():
		return DotResult.fail(DotError.CODE_STATE, "This session has nobody to change the layout.")

	var applied: Variant = apply_fn.call(map.id)

	if applied is DotResult and not (applied as DotResult).ok:
		change_failed.emit(map, (applied as DotResult).error.message)
		return applied as DotResult

	var previous := current
	changing.emit(previous, map)
	note_current(map)
	changed.emit(map, null)
	return DotResult.success(map)


## Records the layout being played, which is what `mapinfo` and the rotation's cooldown read.
## Called by the host whenever a layout is laid, however it was chosen.
func note_current(map: DotMapDef) -> void:
	# Once per layout: the vote and the world both say so, and each would be a play.
	if map == null or (current != null and current.id == map.id):
		return

	current = map

	if rotation != null:
		rotation.note_played(map.id)


## The server's maps.yml, or null when there is none (every layout rotates, as it always did).
var rotation_file: DotMapRotationFile = null

## The file looked for, with or without an extension. `sv_map_rotation_file`.
var rotation_file_name: String = DEFAULT_ROTATION_FILE

const DEFAULT_ROTATION_FILE := "cfg/maps.yml"


## Reads maps.yml and applies it: which layouts the draw, the ballot and nominations may choose.
## The merge, wildcards and rules are dot-map's [DotMapRotationFile]; this supplies the paths.
## A file that is present and unreadable is an ERROR and changes nothing: rotating every layout
## is a better failure than rotating none.
func load_rotation() -> DotResult:
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(rotation_file_name, dir)

	if found == "" and rotation_file_name != "" and (dir != "" or rotation_file_name != DEFAULT_ROTATION_FILE):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(LOG_CHANNEL, "the map rotation file was not found; every layout rotates", {
			"file": rotation_file_name, "config_dir": dir,
		})

	var paths := PackedStringArray()

	if found != "":
		paths.append(found)

	var read := DotMapRotationFile.load_files(paths, "mg-smash-copter")

	if not read.ok:
		DotLog.error(LOG_CHANNEL, "the map rotation file could not be read; every layout rotates", {
			"why": read.error.message,
		})
		rotation_file = null
		apply_rotation()
		return read

	rotation_file = read.value

	if rotation_file.has_rotations():
		DotLog.info(LOG_CHANNEL, "the map rotation file", {
			"paths": ", ".join(rotation_file.sources), "active": rotation_file.active_name(),
		})

	apply_rotation()
	return read


## Marks every layout in or out of rotation ([member DotMapDef.in_rotation]) from the file. No
## file, or one with no rotations, keeps every layout in.
func apply_rotation() -> void:
	if catalogue == null or rotation == null:
		return

	if rotation_file != null and rotation_file.has_rotations():
		# An empty rotation leaves every layout in, which is what no file means here too.
		rotation_file.fallback_in = func(_map: DotMapDef) -> bool: return true
		var _applied := rotation_file.apply(rotation)
		return

	rotation.order = []

	for def in catalogue.maps:
		def.in_rotation = true


## Whether maps.yml's active rotation plays [param id]. A layout the catalogue lacks is not.
func in_rotation(id: StringName) -> bool:
	var def := catalogue.get_map(id) if catalogue != null else null

	return def != null and def.in_rotation


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func commands_spec() -> Dictionary:
	return rotation_file.commands() if rotation_file != null else {}
