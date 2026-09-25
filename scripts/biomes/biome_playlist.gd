class_name BiomePlaylist
extends Resource

## The running order of biomes for one level, answering one question for the
## [BiomeDirector]: [i]which biome is track element `i`?[/i]
##
## [b]Auto order[/b] ([member biomes] + [member segments_per_biome]) suits the
## endless track: a biome lasts [member segments_per_biome] elements and the next
## one follows, so a long run keeps changing theme. 12 elements of 100 m is
## 1.2 km, i.e. a couple of minutes per biome at running speed. A single biome in
## the list - or `segments_per_biome = 0` - pins the whole track to it, which is
## the "one biome for now" case.
##
## [b]Sections[/b] ([member sections]) suit a closed level: an explicit running
## order that repeats around the lap, so a place on the track can be authored to
## look a certain way.
##
## The answer is a pure function of the element index, never of the player's
## position nor of the order in which the track happened to be built, so every
## pooled body reports the same biome for the same piece of track, and
## re-centring the endless track's window - or reloading the level - cannot
## shuffle biomes around.

enum Order {
	## Biomes are used in the listed order, over and over.
	SEQUENTIAL,
	## Like SEQUENTIAL, but each pass through the list is shuffled, so a long run
	## keeps mixing biomes instead of repeating one sequence.
	SHUFFLE,
}

## Biomes to cycle through in auto order.
@export var biomes: Array[BiomeProvider] = []
## Length of one biome, in track elements, for the endless track. 0 (or a single
## biome in the list) means "this biome for the whole track".
@export var segments_per_biome: int = 12
@export var order: Order = Order.SEQUENTIAL
## Explicit running order for a closed level; when it is not empty it is used
## instead of [member biomes]. Sections repeat around the loop.
@export var sections: Array[BiomeSection] = []:
	set(value):
		sections = value
		_rebuild_section_layout()
## Seed of the shuffled orders of [constant Order.SHUFFLE].
@export var seed: int = 0

# Sections flattened into "element -> provider" ranges, rebuilt when they change.
var _section_starts: PackedInt32Array = PackedInt32Array()
var _section_providers: Array[BiomeProvider] = []
var _section_total: int = 0
# The shuffled order of the round the last query fell into.
var _shuffle_round: int = -1
var _shuffle_order: PackedInt32Array = PackedInt32Array()


## Biome of `element_index`, or `null` for "leave the track as authored". Safe to
## call for every pooled body every frame: the answer is cached and the work is a
## division.
func provider_at(element_index: int) -> BiomeProvider:
	if not _section_providers.is_empty():
		return _provider_from_sections(element_index)
	if biomes.is_empty():
		return null
	if biomes.size() == 1 or segments_per_biome <= 0:
		return biomes[0]
	var round_index := int(floor(float(element_index) / float(segments_per_biome)))
	var index := posmod(round_index, biomes.size())
	if order == Order.SHUFFLE:
		index = _shuffled_index(round_index, index)
	return biomes[index]


## True when the whole track is served by one provider: no transition will ever
## happen, however far the runner goes. Lets a debug overlay (and anything else)
## tell "one biome for now" from "the next change is still far away".
func is_single_biome() -> bool:
	if uses_sections():
		for provider in _section_providers:
			if provider != _section_providers[0]:
				return false
		return true
	return biomes.size() <= 1 or segments_per_biome <= 0


## The stretch of elements served by one provider that covers `element_index`, as
## `(first element, length in elements)`. A run is maximal: when the order happens
## to place the same biome in two neighbouring rounds - which shuffling can do - the
## run covers both, so it is measured instead of derived from `segments_per_biome`.
func run_range_at(element_index: int) -> Vector2i:
	var provider := provider_at(element_index)
	var bound := _run_scan_bound()
	if provider == null or bound <= 0:
		return Vector2i(element_index, 1)
	var first := element_index
	while element_index - first < bound and provider_at(first - 1) == provider:
		first -= 1
	var last := element_index
	while last - element_index < bound and provider_at(last + 1) == provider:
		last += 1
	return Vector2i(first, last - first + 1)


## Index of the [BiomeSection] that covers `element_index`, or -1 when the playlist
## runs in auto order. Handy for debug overlays and lap-split logic.
func section_index_at(element_index: int) -> int:
	if _section_providers.is_empty():
		return -1
	return _section_index_from_local(posmod(element_index, _section_total))


## First element of section `index` inside the loop, or -1 when there are no
## sections. Useful to preview the layout; the playlist itself never needs it.
func section_start(index: int) -> int:
	if index < 0 or index >= _section_starts.size():
		return -1
	return _section_starts[index]


## Length of one full pass through the sections, in elements (0 in auto order).
func section_loop_length() -> int:
	return _section_total


## True when the playlist uses [member sections] instead of [member biomes].
func uses_sections() -> bool:
	return not _section_providers.is_empty()


## One-line description of what the playlist does, for a debug overlay or a log.
func describe() -> String:
	if uses_sections():
		return "%d sections, %d elements per lap" % [_section_providers.size(), _section_total]
	if biomes.is_empty():
		return "no biomes"
	var name_of_first := biomes[0].biome_id if biomes[0] != null else &"<empty>"
	if biomes.size() == 1 or segments_per_biome <= 0:
		return "%s, whole track" % name_of_first
	if order == Order.SHUFFLE:
		return "%d biomes, %d elements each, shuffled" % [biomes.size(), segments_per_biome]
	return "%d biomes, %d elements each" % [biomes.size(), segments_per_biome]


## Problems the [BiomeDirector] reports at startup, so a half-authored playlist
## fails loudly instead of leaving the track bare.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if segments_per_biome < 0:
		problems.append("`segments_per_biome` cannot be negative")
	if not biomes.is_empty() and not sections.is_empty():
		problems.append(
			"both `biomes` and `sections` are set: the sections win, so the %d biome(s) "
			% biomes.size()
			+ "in `biomes` are never used"
		)
	if uses_sections():
		if _section_total <= 0:
			problems.append("`sections` cover 0 elements")
		for i in sections.size():
			var section := sections[i]
			if section == null:
				problems.append("sections[%d] is empty" % i)
				continue
			for problem in section.validate():
				problems.append("sections[%d] %s" % [i, problem])
	elif biomes.is_empty():
		problems.append("has neither `biomes` nor `sections`, so it applies nothing")
	elif order == Order.SHUFFLE and biomes.size() > 1 and segments_per_biome <= 0:
		problems.append("`order` is SHUFFLE but `segments_per_biome` is 0, so nothing ever changes")
	for i in biomes.size():
		var provider := biomes[i]
		if provider == null:
			problems.append("biomes[%d] is empty" % i)
			continue
		for problem in provider.validate():
			problems.append("%s: %s" % [biomes[i].biome_id, problem])
	return problems


# --- Sections ----------------------------------------------------------------

## Longest a run of one provider can be: a whole pass through the sections, or
## every round of the biome list. Seeds both walks of [method run_range_at].
func _run_scan_bound() -> int:
	if uses_sections():
		return _section_total
	if biomes.is_empty() or segments_per_biome <= 0:
		return 0
	return segments_per_biome * maxi(biomes.size(), 1)


func _rebuild_section_layout() -> void:
	_section_starts = PackedInt32Array()
	_section_providers = []
	_section_total = 0
	for section in sections:
		if section == null or section.segments <= 0:
			continue
		_section_starts.append(_section_total)
		_section_providers.append(section.provider)
		_section_total += section.segments


func _provider_from_sections(element_index: int) -> BiomeProvider:
	return _section_providers[_section_index_from_local(posmod(element_index, _section_total))]


func _section_index_from_local(local_index: int) -> int:
	for i in range(_section_starts.size() - 1, -1, -1):
		if _section_starts[i] <= local_index:
			return i
	return 0


# --- Shuffle -----------------------------------------------------------------

## Index into [member biomes] for one round, where a round is one pass through the
## list. The permutation is regenerated when the query moves to another round and
## is a pure function of [member seed] and the round number, so the same element
## always gets the same biome.
func _shuffled_index(round_index: int, index: int) -> int:
	if round_index != _shuffle_round or _shuffle_order.size() != biomes.size():
		var rng := RandomNumberGenerator.new()
		rng.seed = seed + round_index * 0x9e3779b9
		var permutation := PackedInt32Array()
		permutation.resize(biomes.size())
		for i in biomes.size():
			permutation[i] = i
		for i in range(permutation.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var swap := permutation[i]
			permutation[i] = permutation[j]
			permutation[j] = swap
		_shuffle_order = permutation
		_shuffle_round = round_index
	return _shuffle_order[index]
