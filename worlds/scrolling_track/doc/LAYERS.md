[//]: # (By Qwen3.8-Max)
# Recommended layer structure

## Layer 0: Playfield / Gameplay Layer

This is your active running surface.

```text
~30m wide ground plane/chunks
barriers
coins
weights
dirt zones
stairs
colliders
spawn sockets
```

This layer:

```text
spawns in front of the player
recycles behind the player
needs collision
needs gameplay logic
needs high visual clarity
```

This is the only layer that should strongly affect gameplay.

Example:

```text
Playfield width: 30m
Chunk length: 60m / 80m / 100m
Player corridor: maybe 18–24m of the 30m
Outer 3–6m on each side: decorative margin
```

Even if the plane is 30m wide, you do not need to place critical obstacles across all 30m. Keep the main playable corridor clean and readable.

---

## Layer 1: Near Dressing Layer

This is the 3D decoration close to the track.

```text
fences
trees
mailboxes
lamps
bushes
small houses
benches
flower beds
```

This layer:

```text
sits beside the playfield
can be full 3D
should recycle with chunks
usually has no gameplay collision
should not block the player’s view of obstacles
```

Distance from track center:

```text
roughly 15m to 60m outward
```

This layer helps the world feel physical and lived-in, but it should not fight for attention.

---

## Layer 2: Mid Parallax Layer

This is where the world starts feeling large.

```text
house silhouettes
tree lines
distant fences
hills
power poles
small buildings
water tower
```

This layer:

```text
moves slower than the playfield
can be low-poly or flat cards
does not need collision
can update less frequently
can be reused for a long time
```

Distance:

```text
roughly 60m to 200m away
```

This layer is very important for the “vast but simple” look.

---

## Layer 3: Far Background / Sky Layer

This is your horizon.

```text
sky
clouds
far hills
far town silhouette
large landmarks
atmospheric haze
```

This layer:

```text
is basically camera-locked or very slow parallax
does not need collision
does not need detailed geometry
can be a texture, panorama card, cylinder, or skybox
changes only on biome transition
```

Distance:

```text
visually 200m to infinity
```

This layer sells the scale.

---
