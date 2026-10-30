extends RefCounted

const ScPaths := preload("sc_paths.gd")

## The prototype textures every surface in this map is drawn with, and the grid that stands in when they are missing.
## A pattern of a known size is the only thing that tells a player a platform is tilting (a flat colour under a lean and under none is the same picture), and a role, not a colour, is what the map passes, so a re-skin is not an edit of every box.
## The grid is Kenney's Prototype Textures 1.0, CC0, one light grid file vendored and tinted per role ([constant ROLE_COLOURS]); `textures/prototype/LICENSE.txt` is Kenney's own, unchanged.

const CHANNEL := "sc.textures"

## What a surface is FOR, which is what decides how it is drawn.
enum Role {
	## The top and sides of a platform. The thing a player stands on and reads a lean off.
	DECK,
	## The single column under a platform. Dark, so a deck reads against it.
	PILLAR,
	## The cannon in the middle. The one colour nothing else in the map wears.
	CANNON,
	## A corner arena, where the round is finished.
	ARENA,
	## Anything that kills: the floor of the map, and the rim of the tube.
	HAZARD,
	## A spawn pad and the chopper's landing square.
	SAFE,
	## The floor forty metres down. Appended, so no role's number moves.
	FLOOR,
}

## The file each role loads. Dropping a different PNG in is the whole of a re-skin.
## Every role draws Kenney's light grid (`texture_02` of the Light folder) tinted by [constant ROLE_COLOURS]: coloured folders under a sun read as a neon test level and a tint over one is mud.
## Not `texture_13`, the same grid with `WALL / 1 x 1 meter` painted in a corner.
const ROLE_FILES := {
	Role.DECK: "grid.png",
	Role.PILLAR: "grid.png",
	Role.CANNON: "grid.png",
	Role.ARENA: "grid.png",
	Role.HAZARD: "grid.png",
	Role.SAFE: "grid.png",
	Role.FLOOR: "grid.png",
}

## What each role is tinted, over the installed grid or the generated one.
## Pastels, the deck the lightest thing in the sky because a player reads a lean off it; the pillar is a mid lavender that a deck reads against; the cannon and cover are the one saturated colour; the floor is a muted sky blue, plainly not somewhere to land.
const ROLE_COLOURS := {
	Role.DECK: Color(0.97, 0.97, 1.00),
	Role.PILLAR: Color(0.70, 0.64, 0.92),
	Role.CANNON: Color(1.00, 0.78, 0.30),
	Role.ARENA: Color(0.80, 0.70, 1.00),
	Role.HAZARD: Color(1.00, 0.55, 0.60),
	Role.SAFE: Color(0.58, 0.96, 0.78),
	Role.FLOOR: Color(0.56, 0.74, 0.90),
}

## How many squares are across one tile of the installed set.
## Eight, measured rather than assumed: the lines alternate STRONG and FAINT (97 luma steps every 256 pixels, ten every 128), so a threshold that ignores compression noise finds four and draws every surface at half scale.
const INSTALLED_SQUARES_PER_TILE := 8

## How many squares are across one tile of the generated grid.
const GENERATED_SQUARES_PER_TILE := 4

## How big one square is in the world, in metres.
## One metre, the unit this map is judged in: a platform is 10.5 squares across, the gap is one, and a player deciding whether a jump is on counts them.
const METRES_PER_SQUARE := 1.0

## Pixels per square in the generated tile.
const GENERATED_PIXELS_PER_SQUARE := 128

## How much darker an alternate square is in the composited checker.
## Ink is the only thing that survives a mipmap, and Kenney's tile has almost none (1.4% to 3.5% is not the field colour), so seen from the far end of a 24 m gap the grid is gone.
## Alternate squares darkened by six percent survive being averaged, since a checker is half the image.
const CHECKER := 0.93

## How much darker a grid line is in the generated tile.
const LINE := 0.70

## Where a texture set is looked for. A missing directory is a supported state.
static var TEXTURE_DIR := ScPaths.rebase("res://textures/prototype")

## Built materials, by role. One per role for the whole map — a map is a few hundred
## boxes and a material each would be a few hundred shader compilations for one texture.
static var _materials: Dictionary = {}

## Composited installed textures, by role. Null means "looked for it and it is not here".
static var _installed: Dictionary = {}

## Composited installed textures, by file, which several roles share.
static var _by_path: Dictionary = {}

## The one generated tile, shared by every role and tinted per role.
static var _grid: ImageTexture = null


## The material for a role. Cached; call it per box.
static func surface(role: Role) -> StandardMaterial3D:
	if _materials.has(role):
		return _materials[role]

	var material := StandardMaterial3D.new()
	var texture := installed(role)
	var squares := INSTALLED_SQUARES_PER_TILE

	if texture == null:
		texture = grid_texture()
		squares = GENERATED_SQUARES_PER_TILE

	# Both tiles are light grey and white, so the role's colour is the colour.
	material.albedo_color = ROLE_COLOURS.get(role, Color.WHITE)

	material.albedo_texture = texture

	# World-space triplanar, without which none of the numbers above mean anything: a [BoxMesh] maps every face to the same 0..1 square, so a 10.5 m platform and a 1 m crate would show the same number of squares and the pattern would stop carrying scale.
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true

	var metres_per_tile := METRES_PER_SQUARE * float(squares)
	var scale := 1.0 / maxf(metres_per_tile, 0.001)
	material.uv1_scale = Vector3(scale, scale, scale)

	material.roughness = 0.94
	material.metallic = 0.0

	# Nearest, which is a decision rather than a default: a prototype grid is meant to be
	# read as discrete squares at distance, and filtering blurs the lines out at exactly
	# the range a player is judging a platform's lean from.
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS

	_materials[role] = material
	return material


## The installed texture for a role, checkered, or null if no set is installed.
static func installed(role: Role) -> Texture2D:
	if _installed.has(role):
		return _installed[role]

	var path := "%s/%s" % [TEXTURE_DIR, ROLE_FILES.get(role, "grid.png")]

	# [method ResourceLoader.exists] rather than [method FileAccess.file_exists]: an imported texture in an exported build is a `.ctex` beside a `.png` that is not shipped, so the filesystem answers "no" in exactly the build that matters.
	if not ResourceLoader.exists(path, "Texture2D"):
		DotLog.debug(CHANNEL, "no texture installed for a role", {
			"role": Role.keys()[role], "looked_at": path,
		})
		_installed[role] = null
		return null

	var loaded: Resource = ResourceLoader.load(path, "Texture2D")

	if not (loaded is Texture2D):
		_installed[role] = null
		return null

	# Every role shares one file, so the checker is composited once per file, not per role:
	# it is a million-pixel loop in GDScript.
	if not _by_path.has(path):
		var checkered := _with_checker(loaded as Texture2D)
		_by_path[path] = checkered if checkered != null else loaded as Texture2D
	_installed[role] = _by_path[path]
	return _installed[role]


## The installed tile with a checker composited onto it. See [constant CHECKER].
## Null when the pixels could not be read, which is not an error; the caller falls back to the tile as it came.
static func _with_checker(source: Texture2D) -> ImageTexture:
	var image := source.get_image()

	if image == null or image.is_empty():
		return null

	image = image.duplicate() as Image

	if image.is_compressed():
		# A compressed import cannot be written into. Decompressing is cheap for one
		# 1024-pixel tiles and happens once for the life of the process.
		if image.decompress() != OK:
			return null

	var width := image.get_width()
	var height := image.get_height()

	if width <= 0 or height <= 0:
		return null

	var square_w := maxi(width / INSTALLED_SQUARES_PER_TILE, 1)
	var square_h := maxi(height / INSTALLED_SQUARES_PER_TILE, 1)

	for y in range(height):
		for x in range(width):
			# Alternate squares, which is `(column + row) & 1`. Half the image, which is
			# the point — see [constant CHECKER].
			if ((x / square_w) + (y / square_h)) % 2 == 0:
				continue

			var pixel := image.get_pixel(x, y)
			image.set_pixel(x, y, Color(
				pixel.r * CHECKER, pixel.g * CHECKER, pixel.b * CHECKER, pixel.a
			))

	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## The generated one-metre grid: a line every square, a checker underneath.
## What is drawn when no texture set is installed, a supported state: the map is playable with an empty `textures/` directory, so the repository clones without the art.
static func grid_texture() -> ImageTexture:
	if _grid != null:
		return _grid

	var side := GENERATED_PIXELS_PER_SQUARE * GENERATED_SQUARES_PER_TILE
	var image := Image.create_empty(side, side, true, Image.FORMAT_RGB8)

	for y in range(side):
		for x in range(side):
			var shade := 1.0
			var column := x / GENERATED_PIXELS_PER_SQUARE
			var row := y / GENERATED_PIXELS_PER_SQUARE

			if (column + row) % 2 == 1:
				shade *= CHECKER

			# Three pixels, because one pixel of ink on a 128-pixel square is 0.8% of the
			# image and a mipmap has eaten it by the second level.
			if x % GENERATED_PIXELS_PER_SQUARE < 3 or y % GENERATED_PIXELS_PER_SQUARE < 3:
				shade *= LINE

			image.set_pixel(x, y, Color(shade, shade, shade))

	image.generate_mipmaps()
	_grid = ImageTexture.create_from_image(image)
	return _grid


## Forgets every cached material and texture. For a test that changes the install.
## Not called `reset_state`: `Resource` already has one and GDScript takes the redefinition without a warning, so every call would silently bind to the engine's.
static func forget_cache() -> void:
	_materials.clear()
	_installed.clear()
	_by_path.clear()
	_grid = null


static func describe() -> Dictionary:
	var installed_count := 0

	for role in ROLE_FILES:
		if installed(role) != null:
			installed_count += 1

	return {
		"directory": TEXTURE_DIR,
		"installed": "%d of %d roles" % [installed_count, ROLE_FILES.size()],
		"metres_per_square": METRES_PER_SQUARE,
	}
