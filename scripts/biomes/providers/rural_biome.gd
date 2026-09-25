class_name RuralBiome
extends BiomeProvider

## The rural biome of `worlds/scrolling_track/doc/BIOMES.md`: grass either side of
## the road, trees beside it, a tree line behind them and hills on the horizon.
##
## Almost all of the look is data - [BiomeLayer] resources, materials and an
## [Environment] - so this script only adds the one thing a [BiomeLayer] cannot
## express: [code]road_surfaces[/code], a road that changes surface every few
## elements. A single biome therefore has variety along its length without needing
## a second provider, which is what `doc/BIOMES.md` asks of a biome's skin.
##
## It is also the template for the next biome: copy this script and one of the
## provider `.tres` files next to it, author the resources they point at, and put
## the copy in a [BiomePlaylist]. Nothing else in the system has to change.

## Road surfaces the biome groups elements into. Empty leaves the road to
## [member road_material_override] / [member road_skins] of the base class.
@export var road_surfaces: Array[Material] = []
## Elements one road surface covers before the next one is used. 1 changes surface
## on every element, i.e. every 100 m of road.
@export var road_surface_every: int = 6


## Road material of `variant`, as asked for by [method road_variant]. Falls back to
## the data-first behaviour of the base class when no surfaces are authored.
func road_material(segment: TrackSegment, variant: int) -> Material:
	if road_surfaces.is_empty():
		return super.road_material(segment, variant)
	return road_surfaces[posmod(variant, road_surfaces.size())]


## Which surface the given element gets: one variant per
## [member road_surface_every] elements, so the road changes every few hundred
## metres instead of on every segment.
func road_variant(element_index: int) -> int:
	if road_surfaces.is_empty():
		return super.road_variant(element_index)
	var group := floori(float(element_index) / float(maxi(road_surface_every, 1)))
	return posmod(group, road_surfaces.size())


## Number of distinct road skins, so authoring tools and [BiomeDirector] agree on
## how many variants the biome has.
func road_variant_count() -> int:
	if road_surfaces.is_empty():
		return super.road_variant_count()
	return road_surfaces.size()


## Problems reported at startup, on top of the base class's own checks, so a
## half-authored biome fails loudly instead of rendering a road with holes in it.
func validate() -> PackedStringArray:
	var problems := super.validate()
	for i in road_surfaces.size():
		if road_surfaces[i] == null:
			problems.append("`road_surfaces[%d]` is empty" % i)
	return problems
