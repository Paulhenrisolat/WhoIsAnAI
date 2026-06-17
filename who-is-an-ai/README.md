# Who-Is-An-AI — Godot 4.6 web multiplayer prototype

3D social deduction game: a **detective** walks around a spaceship room full of
"subjects". Some are real players, some are AI bots (Ollama). The detective
interrogates them through text chat and votes **AI** or **Human**. +1 per correct
guess.

## What's new in this build

- **New art assets** (from `assets/models/`):
  - Characters use the **Spaceman** rig. Its Mixamo animations (Idle / Walk / Run)
    ship as separate FBX files; the game loads their clips and installs them on
    every spawned character, so the detective walks/runs and everyone idles.
    Each subject gets a solid per-character color (detective blue; resolved
    subjects red = AI, green = human).
  - The room is built from **Room.fbx**, decorated with ambience props
    (Barrel, Crate, Engine, Meeting Table, TaskStation, panels, ...).
  - Robust fallbacks: if the Spaceman/clips don't import, characters use a
    floating bob; if Room.fbx is missing, a primitive floor/walls is built;
    if no model loads at all, capsules are used (with an on-screen warning).
- **Single "Play" button** (no more Host / Join):
  - One press connects. Under the hood it **tries to JOIN** `127.0.0.1` first,
    and if no server answers within ~1.5 s it **becomes the HOST** automatically.
    The player never chooses; it's decided in the background.
  - Once connected, the same button becomes **Find match** to start the round.
  - Still works with Godot's **Run Multiple Instances**: the first instance
    finds no server and hosts, the others join it. Still fully multiplayer.
- **Audio** (from `assets/audio/`, via the `Sfx` autoload):
  - Looping spaceship **ambience** bed.
  - **UI clicks / hovers** on the Play button.
  - **Intro** sting on each of the 3 intro lines, **match found** sound,
    chat **open/close**, and **correct / wrong** stings on the verdict,
    plus a game-over sound.

## Intro sequence

When a match starts, every player sees a 3-step fade overlay before gaining
control: "there are people in a room." -> "some of them are AI, some of them are
real people" -> "find who is an AI !".

## Requirements

- **Godot 4.6**
- **Ollama** on the host machine: `ollama pull llama3.2` (model name must match
  `ollama list`). Warm it up once (`ollama run llama3.2 "hi"`, then `/bye`).

## Test in multiplayer locally

1. Open the project in Godot **once** so it imports all the FBX/audio.
2. Debug menu -> **Run Multiple Instances** -> 2 (or more) -> press F5.
3. Each window: optional nickname -> **Play** (instance 1 hosts, the rest join).
4. Any window -> **Find match**. 6 participants total (1 detective + 5 subjects);
   empty seats are filled by AI, so solo = 1 human vs 5 AI.
5. Detective moves with **WASD** (physical keys = ZQSD on AZERTY) / arrows,
   **E** near a subject to interrogate, then vote.

## Important editor notes

- **Mixamo animations**: Godot imports `Idle.fbx` / `Walk.fbx` / `Run.fbx` as
  scenes with an AnimationPlayer; the code pulls one clip from each. If the
  Spaceman appears T-posing or static, open those FBX in the Import dock and
  confirm they import **as animations** (default), then reload the project.
- If the Spaceman or Room imports too big / wrong orientation, tweak
  `MODEL_SCALE` / `MODEL_ROT_Y_DEG` / `ROOM_SCALE` at the top of `scripts/Main.gd`.

## Architecture

```
scripts/Net.gd   Authoritative WebSocket server + clients; play() = auto host/join
scripts/Main.gd  3D world (Room + props), Spaceman + Mixamo anims, UI, intro
scripts/Sfx.gd   Audio autoload (ambience + one-shot SFX pool)
assets/models/   Spaceman (+ animations), Room.fbx, props
assets/audio/    ambience + UI/verdict SFX
```

## Editing the environment in the Godot editor (EnvBuilder)

The whole environment can be turned into real, hand-editable nodes:

1. Open `scenes/Main.tscn`.
2. Select the **EnvBuilder** node, and in the Inspector tick **Build Now**.
   It creates an **Environment** node with everything as plain child nodes:
   WorldEnvironment (skybox), Sun, Starfield, Room (FBX), ShipHull (FBX, placed
   below the floor), Ship/ (primitive hull), Props/, CollisionWalls/, PlayArea.
3. **Save the scene** (Ctrl+S). Now move/scale/recolor anything by hand.
4. Optional: delete the EnvBuilder node. At runtime, `Main.gd` detects the
   prebuilt **Environment** node and skips all code generation, reading the
   walkable area from the **PlayArea** marker's `play_half` metadata.

Tunables for the build live on the EnvBuilder node's Inspector (room scale,
room_half, wall_inset, prop_ring, skybox, ship hull scale/Y, ship chassis...).
`room_scale`/`room_half` are fixed values here (no auto-measure) - adjust the
Room in the viewport, then set `room_half` to roughly its half-width and tick
Build Now again (note: rebuilding discards manual edits, so build first, edit after).

If you DON'T build an Environment node, the game still generates everything
procedurally at runtime as before (constants at the top of `scripts/Main.gd`).

## Walls & collisions (the detective is now a real physics body)

The locally-controlled detective is a **CharacterBody3D** with a capsule
collider and moves with `move_and_slide()`, so it physically collides with the
room walls and slides along them. The old invisible square clamp is gone.

IMPORTANT - for a wall to actually block the player:
- A `CollisionShape3D` ALONE does nothing. It must be a CHILD of a
  `StaticBody3D` (or other PhysicsBody). Structure must be:
      StaticBody3D
        └─ CollisionShape3D (BoxShape3D, etc.)
- If you duplicated bare CollisionShape3D nodes, wrap each one under a
  StaticBody3D (or duplicate an existing StaticBody3D wall instead).
- The EnvBuilder's "CollisionWalls" group already creates correct
  StaticBody3D + CollisionShape3D pairs - duplicate THOSE to add walls.
- Tune the detective collider with DET_COLLIDER_RADIUS / DET_COLLIDER_HEIGHT
  at the top of scripts/Main.gd if it clips or gets stuck.

Note: collision walls auto-generated by code only happen in the procedural
(no prebuilt Environment) path. When you use an EnvBuilder-made Environment,
ONLY your editor-placed StaticBody walls are used.
