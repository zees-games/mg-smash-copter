extends GSAudioSceneProbe

const ScAudio := preload("../game/sc_audio.gd")

## Asks whether this game actually makes a noise, on a machine that has a sound card: a headless run builds a null sink, so the suite proves the catalogue and the culling and cannot prove a speaker moves. The loop is GSAudioSceneProbe; this names the cues. Run through `tools/audio_probe.sh`, not `--headless`.


func _make_node() -> Node:
	return ScAudio.new()


func _audio_of(node: Node) -> Object:
	return node.get("manager")


## The warning from the middle of the map, the creak under your feet, a flat sound about you rather than a place, and a shot.
func _probe_ids() -> Array[StringName]:
	return [ScAudio.CANNON_FIRE, ScAudio.PLATFORM_CREAK, ScAudio.YOU_ARE_OUT, ScAudio.WEAPON_SHOT]


func _id_width() -> int:
	return 18


## Quitting with a voice still sounding leaves its stream held by the audio server, reported as leaked.
func _free_before_quit() -> bool:
	return true
