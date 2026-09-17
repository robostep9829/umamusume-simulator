class_name BiomeSection
extends Resource

## One leg of a [BiomePlaylist]: "the next `segments` track elements are this
## biome".
##
## A closed level's point is the lap itself, so its biomes are authored as a
## running order instead of being derived from a section length. Sections repeat
## around the loop, so a lap is walked through them with a `posmod` and the same
## piece of track always lands in the same section.


## Biome of this leg. `null` gives the leg back to the track's own look.
@export var provider: BiomeProvider
## Number of track elements this leg covers; a straight element is 100 m.
@export var segments: int = 12
## Optional name for debug overlays and for error messages.
@export var label: String = ""


## Problems reported by [method BiomePlaylist.validate], without the "sections[i]"
## prefix, so the playlist can report them in place.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if segments <= 0:
		problems.append("`segments` must be at least 1")
	if provider == null:
		problems.append("has no `provider` (leave the section out instead)")
	return problems
