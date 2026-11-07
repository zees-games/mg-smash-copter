extends DotVoteRoundGame

## The players choose the next layout: dot-vote's [DotVoteRoundGame] with Smash Copter's names. A round IS a layout, so a ballot opens
## [member open_after_sec] into every layout and applies at its end; the rest is dot-vote's settings (`user://cfg/smash_vote.json`,
## `game.yml` metadata `layout_vote:`, the weighted draw alone when the vote cannot be built). [member maps_fn] lists the layouts.

const CHANNEL := "smash.vote"

## The key in the running game's descriptor metadata an operator's overrides are read from, [code]metadata: layout_vote:[/code].
const METADATA_KEY := "layout_vote"

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}

var _watch_sec: float = 0.0
var _layouts_hash: int = 0


func _init() -> void:
	channel = CHANNEL
	metadata_key = METADATA_KEY
	command_names = COMMAND_NAMES
	noun = "layout"
	config_path = "user://cfg/smash_vote.json"


## Reads the layout list again and remembers its hash for [method _ticked].
func refresh_maps() -> void:
	if source != null and maps_fn.is_valid():
		_layouts_hash = (maps_fn.call() as Array).hash()

	super.refresh_maps()


## A layout was built: the list is read again first, because an operator's `layout_ids` or `vary_layout` changes which layouts a
## server plays between rounds and nothing else would tell the ballot.
func note_map(id: StringName) -> void:
	if director != null:
		refresh_maps()

	super.note_map(id)


## A `sv_map_rotation` switch changes which layouts rotate without telling the ballot (dot-map applies it straight to the catalogue), so
## the list is read again once a second and only replaced when it differs; a nomination in between would otherwise name a stale list.
func _ticked(delta: float) -> void:
	_watch_sec += delta

	if _watch_sec < 1.0:
		return

	_watch_sec = 0.0

	if not maps_fn.is_valid() or source == null:
		return

	var wanted: Array = maps_fn.call()

	if wanted.size() != source.entries.size() or wanted.hash() != _layouts_hash:
		refresh_maps()
