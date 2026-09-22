class_name BiomeProvider
extends Resource

## A biome: one coherent look for the endlessly recycled track.
##
## The track never changes shape - what changes is the provider, which answers
## "what does the road look like here, and what stands beside it?". Chunk logic
## (straights, turns, obstacle patterns) stays in [TrackManager] and
## [TrackLevel]/[InfiniteTrackLevel]; the biome is only a theme on top of it,
## which is the split proposed in `worlds/scrolling_track/doc/BIOMES.md`.
##
## A provider is a plain [Resource], so a biome is authored as data: the exported
## fields below and the `.tres` files they point at are enough for a re-skin, and
## [BiomePlaylist] can switch between any number of them. Subclass it and override
## the virtual methods only for biomes that need behaviour - a road skin chosen
## per element, scripted decoration, a computed sky.
##
## Layers follow `worlds/scrolling_track/doc/LAYERS.md`:
## [codeblock]
## ROAD - layer 0, the playfield itself. Skinned through road_material() and
##        road_mesh(), never decorated: `decoration(ROAD)` is not asked and
##        `decorate_layer()` is not called with it. Props can still be *placed*
##        inside the playfield by a NEAR/MID layer whose distance band is small
##        enough - they are visual then, like any other decoration. The only layer
##        that affects gameplay.
## NEAR - layer 1, full 3D dressing right beside the track.
## MID  - layer 2, low-poly silhouettes or flat cards, roughly 60-200 m out.
## FAR  - layer 3, the horizon: camera-locked content that only changes when the
##        biome changes, plus environment_override() for the atmosphere.
## [/codeblock]
##
## [b]Biomes must not assume a turn direction.[/b] The same provider is used on
## the left- and right-hand turns of a level, so placement is expressed relative
## to the travelling direction (+X is "right of the runner"), not to world axes;
## [BiomePlacement] exists for exactly that.


## Decoration layers, in the order and with the names of LAYERS.md.
## [constant Layer.ROAD] is not a decoration layer: it is the road itself.
enum Layer { ROAD, NEAR, MID, FAR }

## Gameplay obstacle skins from `doc/BIOMES.md` ("Obstacle skins" table).
## [b]Declared but not consumed yet[/b]: there is no obstacle system to dress, so
## implementing this changes nothing today. It is here so biomes can be authored
## before the obstacles land.
enum ObstacleSkin { BARRIER, DIRT_PATH, WEIGHT, STAIRS, SLOW_ZONE }

## Unique-feature ids from `doc/BIOMES.md` ("Unique feature idea" per biome),
## used with [method feature]. Also declared but not consumed yet.
const FEATURE_FINAL_STRETCH_GATES := &"final_stretch_gates"
const FEATURE_CROSSWALK_ZONE := &"crosswalk_zone"
const FEATURE_PARK_STRETCH := &"park_stretch"

## Stable identifier of the biome (`&"rural"`, `&"city"`...). Used in logs, debug
## overlays and any save data that has to remember which biome the player saw.
@export var biome_id: StringName = &""
## Human-readable name for debug UI and tooling.
@export var display_name: String = ""

@export_group("Road skin (layer 0)")
## Road material. `null` keeps the material authored inside the segment's mesh.
@export var road_material_override: Material
## Skirt material. The mesh that extends the road sideways.
@export var skirt_material_override: Material
## Extra skins cycled along the biome. When this is not empty it is used instead
## of [member road_material_override], one element after the other, which is how a
## biome varies its surface - worn patches, dirt spilling onto the track, a
## crosswalk - without needing a second provider.
@export var road_skins: Array[Material] = []
## Mesh that replaces the authored segment mesh, for biomes that need different
## geometry (a raised curb, a wider shoulder). Must keep the segment's size and
## origin so chaining, colliders and decoration stay valid.
@export var road_mesh_override: Mesh
## Move layer 0 - the road and the ground under it - to [member road_render_priority].
##
## Layer 0 is a group in the frame like any other, so it has a priority like any other;
## left alone it is whatever the road and floor materials were authored with. The rural
## biome turns this on and puts the floor at 2, after the trees standing on it: the
## canopies and trunks then shade first and the ground behind them is depth-rejected.
##
## The road and the floor move together whatever this says, because in a biome that
## skins its road with the material its floor is made of, splitting them would leave the
## road's own tiles in two different groups. Both are moved on copies of their material,
## so a shared asset is never retouched.
@export var override_road_priority: bool = false
## Draw priority of the road and the floor, in the same scale as
## [member BiomeLayer.render_priority]: higher draws later.
@export_range(-128, 127) var road_render_priority: int = 0

@export_group("Decoration layers (1-3)")
## Layers 1-3 of LAYERS.md, as authored [BiomeLayer] resources. A layer left
## empty simply is not built.
@export var near_layer: BiomeLayer
@export var mid_layer: BiomeLayer
@export var far_layer: BiomeLayer

@export_group("Atmosphere (layer 3)")
## Sky, fog and light of this biome, cross-faded by [BiomeDirector] when the
## player enters it. `null` keeps the level's own environment.
@export var atmosphere: Environment

@export_group("Gameplay (declared, not consumed yet)")
## Which prop each gameplay obstacle is dressed as in this biome, indexed by
## [enum ObstacleSkin]. See the obstacle skin table of `doc/BIOMES.md`.
## [b]Nothing reads this yet[/b]: it is the contract the obstacle system is
## expected to use, so a biome does not have to be re-authored when it lands.
@export var obstacle_skins: Array[PackedScene] = []


## --- Road skin (layer 0) -----------------------------------------------------

## Number of distinct road skins this biome can produce (at least 1). More than
## one lets a single biome vary its surface along its length - worn patches, dirt
## spilling onto the track, a crosswalk - without an extra provider.
func road_variant_count() -> int:
	return maxi(road_skins.size(), 1)


## Which skin the given track element gets. The default cycles through the
## variants, so `road_variant_count() == 4` repeats the four skins in turn.
func road_variant(element_index: int) -> int:
	return posmod(element_index, maxi(road_variant_count(), 1))


## Road material of this biome. `null` keeps the material authored inside the
## segment's mesh; the default implementation returns [member road_material_override]
## or cycles [member road_skins].
func road_material(_segment: TrackSegment, _variant: int) -> Material:
	if road_skins.is_empty():
		return road_material_override
	return road_skins[posmod(_variant, road_skins.size())]

func skirt_material() -> Material:
	return skirt_material_override

## Replacement mesh for the road of `segment`, or `null` to keep the authored
## one. A replacement must keep the segment's width, length and origin so that
## chaining, colliders and decoration stay valid.
func road_mesh(_segment: TrackSegment, _variant: int) -> Mesh:
	return road_mesh_override


## --- Decoration layers (1-3) -------------------------------------------------

## Descriptor of what this biome puts in `layer` (one of NEAR, MID, FAR), or
## `null` for "nothing here". The default reads the authored layer resources, so
## a biome that is a pure re-skin needs no code at all; override it when the
## decoration depends on more than the layer's own data.
func decoration(layer: Layer) -> BiomeLayer:
	match layer:
		Layer.NEAR:
			return near_layer
		Layer.MID:
			return mid_layer
		Layer.FAR:
			return far_layer
	return null


## Escape hatch for decoration that a [BiomeLayer] cannot express (content that
## reacts to the player, a painted decal, a scripted prop).
##
## Called once per recycled segment and decoration layer, after the descriptor's
## instances were added to `host`. `host` is an empty [Node3D] parented to the
## segment body at its entry point, so its local -Z points forward along the
## track (+X is right of the runner) and anything added under it follows the
## track and is cleared when the segment is recycled. Keep it deterministic:
## rebuilding must reproduce the same world-space result, otherwise recycling
## will look like it pops.
##
## Horizon layers ([constant BiomeLayer.Mode.RING]) are not built per segment,
## so they never reach this hook.
func decorate_layer(
	_layer: Layer, _host: Node3D, _element_index: int, _segment: TrackSegment
) -> void:
	pass


## --- Atmosphere (layer 3) ----------------------------------------------------

## Environment this biome wants, or `null` to keep the level's own; the default
## implementation returns [member atmosphere]. The [BiomeDirector] duplicates the
## resource before using it - the authored `.tres` is never modified - and
## cross-fades the numeric fields it knows about (fog, ambient, background and
## tonemap) when the player enters the biome, so the "sky changes only on biome
## transition" rule of LAYERS.md holds.
func environment_override() -> Environment:
	return atmosphere


## --- Gameplay hooks (declared, not consumed yet) -----------------------------

## Which prop a gameplay obstacle is dressed as in this biome; see the obstacle
## skin table of `doc/BIOMES.md`. [b]Nothing calls this yet[/b] - it is the
## contract the obstacle system is expected to use, so a biome does not have to
## be rewritten when obstacles land. Reads [member obstacle_skins].
func obstacle_skin(kind: ObstacleSkin) -> PackedScene:
	if kind < 0 or kind >= obstacle_skins.size():
		return null
	return obstacle_skins[kind]


## Description of this biome's unique feature (a [PackedScene] to spawn, a
## [Resource] of tunables, `null` when the biome has none), keyed by one of the
## FEATURE_* constants. [b]Nothing calls this yet[/b], same reason as above.
func feature(_feature_id: StringName) -> Variant:
	return null


## --- Helpers -----------------------------------------------------------------

## True when this biome decorates `layer`.
func has_decoration(layer: Layer) -> bool:
	var descriptor := decoration(layer)
	return descriptor != null and descriptor.is_usable()


## Problems reported by [BiomeDirector] at startup, so a half-authored biome
## fails loudly instead of rendering nothing.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if biome_id.is_empty():
		problems.append("`biome_id` is empty; it identifies the biome in logs and save data")
	if road_variant_count() <= 0:
		problems.append("`road_variant_count()` must be at least 1")
	if road_render_priority != 0 and not override_road_priority:
		problems.append(
			"`road_render_priority` (%d) is set but `override_road_priority` is off, "
			% road_render_priority
			+ "so the road and the floor keep their own priority and this biome ignores it"
		)
	for i in road_skins.size():
		if road_skins[i] == null:
			problems.append("`road_skins[%d]` is empty, so that element is unpainted" % i)
	for i in obstacle_skins.size():
		if obstacle_skins[i] == null:
			problems.append("`obstacle_skins[%d]` is empty" % i)
	for layer in [Layer.NEAR, Layer.MID, Layer.FAR]:
		var descriptor := decoration(layer)
		if descriptor == null:
			continue
		for problem in descriptor.validate():
			problems.append("%s layer %s" % [Layer.keys()[layer], problem])
	return problems
