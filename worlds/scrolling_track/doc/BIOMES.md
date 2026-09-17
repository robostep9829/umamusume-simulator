[//]: # (By Qwen3.8-Max)
# 3. Biome design: racetrack, city, suburbs

Since the biomes mostly change visuals, you should build them as **themes** applied to the same chunk logic.

Example:

```text
Chunk logic: obstacle pattern A
Biome theme: racetrack
Result: hurdles + turf + crowd

Chunk logic: obstacle pattern A
Biome theme: city
Result: construction barriers + road + buildings

Chunk logic: obstacle pattern A
Biome theme: suburbs
Result: fences + sidewalk + houses
```

This saves a huge amount of work.

---

## Biome 1: Racetrack

This should feel like the “pure running” biome.

Visual language:

```text
track surface
white lane markings
turf infield
starting gates
grandstands
crowd
flags
fences
scoreboards
stadium lights
```

Obstacle skins:

| Obstacle | Racetrack version |
|---|---|
| Barrier | hurdle / track barrier |
| Dirt path | infield dirt / loose turf |
| Weight | training weights / equipment cart |
| Stairs | small podium steps / track ramp |
| Slow zone | sandpit / wet turf |

Unique feature idea:

### “Final Stretch Gates”

Occasionally spawn glowing gates or track arches.

Effect:

```text
small stamina recovery
or slight speed boost
or score bonus if passed cleanly
```

This fits Uma Musume-style racing fantasy without changing the whole mode.

---

## Biome 2: City

This should feel structured and rhythmic.

Visual language:

```text
roads
crosswalks
sidewalks
buildings
traffic lights
buses
construction signs
cones
storefronts
bridges
```

Obstacle skins:

| Obstacle | City version |
|---|---|
| Barrier | construction barrier / roadblock |
| Dirt path | gravel construction patch |
| Weight | fallen crates / equipment |
| Stairs | plaza steps / subway entrance |
| Slow zone | wet paint / crowd area |

Unique feature idea:

### Crosswalk speed strips

Crosswalks could be safe visual zones with small bonuses.

Example:

```text
Crosswalk zone:
    no obstacles
    small score multiplier
    or stamina regen
```

Or:

```text
Construction zone:
    slightly more barriers
    but high coin/reward value
```

Keep it subtle.

---

## Biome 3: Suburbs

This should feel open, calm, and slightly rolling.

Visual language:

```text
houses
fences
gardens
trees
parks
sidewalks
hills
utility poles
small shops
river path
```

Obstacle skins:

| Obstacle | Suburbs version |
|---|---|
| Barrier | low fence / garden gate |
| Dirt path | park trail / gravel path |
| Weight | fallen branch / moving box |
| Stairs | porch steps / park steps |
| Slow zone | shallow puddle / grass |

Unique feature idea:

### Gentle hills or curbs

Suburbs could have small elevation visuals, even if gameplay remains mostly flat.

Or:

```text
Park stretch:
    more open space
    more coins/rewards
    fewer hard obstacles
```

This makes suburbs feel like a breather biome.
