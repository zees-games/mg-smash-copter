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
