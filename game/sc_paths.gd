extends RefCounted

## Where this game's own files are, wherever this copy of it happens to live. The logic is gs-game's [GSGamePaths]; this keeps the game's name for it. Hold paths in a `static var`, not a `const`: [method root] is not knowable at parse time.

const _SELF := preload("sc_paths.gd")


static func root() -> String: return GSGamePaths.root_of(_SELF)


static func rebase(path: String) -> String: return GSGamePaths.rebase_onto(path, root())


static func rebase_onto(path: String, here: String) -> String: return GSGamePaths.rebase_onto(path, here)
