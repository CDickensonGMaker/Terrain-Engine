# Terrain Engine

A standalone Godot 4.5+ terrain generation testing lab for developing Vietnam-style terrain systems at **Steel Division 2 scale (3km x 3km maps)**. Features chunked streaming, procedural generation, and support for hundreds of RTS units.

## Map Scale
- **Map Size**: 3074m x 3074m (configurable)
- **Chunk Size**: 256m x 256m (12x12 grid = 144 chunks)
- **Cell Resolution**: 2m per heightmap cell
- **Heightmap**: 1537 x 1537 cells (~9 MB)
- **Vertices per Chunk**: 16,641 (129x129 grid)

## Key Features

1. **Domain Warping** - Organic, twisted terrain patterns (used in No Man's Sky)
2. **Ridged Multifractal Noise** - Sharp mountain ridges by inverting valleys
3. **Particle-Based Hydraulic Erosion** - Realistic river valleys and rounded hills
4. **Jungle Clearing System** - Progressive vegetation removal with terrain flattening
5. **Physical Damage Markers** - Craters, scars, and deformation

## Vietnam Terrain Reference

Based on real Vietnam topography from [topographic-map.com](https://en-us.topographic-map.com/map-71gz4/Vietnam/):
- **Elevation range**: -3m to 2,809m (Fansipan peak)
- **Average elevation**: 173m (~568 ft)
- **Key regions**:
  - Mekong Delta: flat, 0-10m
  - Central Highlands: rolling hills, 400-800m
  - Northern Mountains: peaks up to 2,800m

## Project Structure

```
TerrainEngine/
├── core/                    # Core terrain generation
│   ├── terrain_engine.gd    # Advanced heightmap generator (AUTOLOAD)
│   └── terrain_mesh.gd      # 3D mesh from heightmap
├── systems/                 # Terrain modification systems
│   ├── damage_system.gd     # Craters, scars, deformation (AUTOLOAD)
│   └── clearing_system.gd   # Jungle clearing stages (AUTOLOAD)
├── shaders/                 # Visual rendering
│   └── terrain.gdshader     # Main terrain shader
├── scenes/                  # Test scenes
│   ├── terrain_lab.tscn     # Main testing scene
│   └── terrain_lab.gd       # Scene controller
├── ui/                      # Testing UI
│   └── terrain_lab_ui.gd    # Parameter controls
└── textures/                # Terrain textures
```

## Generation Techniques

### 1. Domain Warping
Warps sampling coordinates using secondary noise before reading the base heightmap. Creates organic, twisted patterns similar to tectonic deformation.

```gdscript
# Offset coordinates by warping noise
var warp_x = warp_noise_x.get_noise_2d(x, y) * warp_strength
var warp_y = warp_noise_y.get_noise_2d(x, y) * warp_strength
var height = base_noise.get_noise_2d(x + warp_x, y + warp_y)
```

**Reference**: [3DWorld Blog](http://3dworldgen.blogspot.com/2017/05/domain-warping-noise.html)

### 2. Ridged Multifractal
Creates sharp mountain ridges by transforming smooth noise:
1. Take absolute value (valleys become peaks)
2. Invert (1.0 - x)
3. Square for sharpening

```gdscript
ridge = abs(ridge)
ridge = 1.0 - ridge
ridge = pow(ridge, sharpness)
```

**Reference**: [The Book of Shaders](https://thebookofshaders.com/13/)

### 3. Particle-Based Hydraulic Erosion
Simulates water droplets carving valleys. Based on Nick McDonald's implementation:

1. Spawn droplet at random position
2. Calculate gradient at current position
3. Move droplet downhill with inertia
4. Erode or deposit sediment based on capacity
5. Evaporate water over time
6. Repeat ~50,000 times

**Reference**: [Nick McDonald's Blog](https://nickmcd.me/2020/04/10/simple-particle-based-hydraulic-erosion/)

### 4. Height-Dependent Detail
Areas that are already ridges get more detail added from subsequent octaves, while flat areas get less. This creates realistic variation where mountains have complex features but valleys stay smooth.

## Terrain Presets

| Preset | Warp | Ridges | Erosion | Best For |
|--------|------|--------|---------|----------|
| Rolling Hills | 30 | 0.3 | 40k | Central Highlands |
| Steep Mountains | 50 | 0.6 | 60k | Northern peaks |
| River Valley | 25 | 0.35 | 80k | Valley carving |
| Coastal Hills | 20 | Off | 30k | Delta edges |
| Plateau | Off | Off | 20k | Firebase sites |

## Key Parameters

### Base Terrain
| Parameter | Description | Range |
|-----------|-------------|-------|
| `height_scale` | Max terrain height in meters | 50-500m |
| `base_frequency` | Large-scale features | 0.001-0.01 |
| `base_octaves` | Noise layers | 3-6 |

### Domain Warping
| Parameter | Description | Range |
|-----------|-------------|-------|
| `warp_enabled` | Enable/disable warping | bool |
| `warp_strength` | Warp intensity | 0-100 |
| `warp_frequency` | Warp pattern scale | 0.001-0.01 |

### Ridged Multifractal
| Parameter | Description | Range |
|-----------|-------------|-------|
| `ridge_enabled` | Enable/disable ridges | bool |
| `ridge_blend` | Ridge influence | 0-1 |
| `ridge_threshold` | Min height for ridges | 0-1 |
| `ridge_sharpness` | Ridge peak sharpness | 1-4 |

### Erosion
| Parameter | Description | Range |
|-----------|-------------|-------|
| `erosion_enabled` | Enable/disable erosion | bool |
| `erosion_iterations` | Droplet count | 10k-100k |
| `erosion_inertia` | Direction momentum | 0-1 |
| `erosion_capacity` | Sediment capacity | 1-16 |

## Damage System

| Type | Radius | Depth | Use Case |
|------|--------|-------|----------|
| Small Explosion | 3 cells | 1.5% | Grenades, mortars |
| Medium Explosion | 6 cells | 3.5% | Artillery shells |
| Large Explosion | 12 cells | 6% | Bombs |
| Napalm | 15 cells | 1% | Burns |
| Vehicle Tracks | 1 cell | 0.8% | Linear deformation |
| Bunker Collapse | 8 cells | 5% | Structure destruction |

## Clearing System

Progressive jungle clearing stages:

| Stage | Vegetation | Flattening | Color |
|-------|------------|------------|-------|
| JUNGLE | 100% | 0% | Dark green |
| PARTIALLY_CLEARED | 25% | 20% | Brown-green |
| CLEARED | 5% | 70% | Exposed dirt |
| FORTIFIED | 0% | 100% | Packed earth |

## Controls

- **WASD** - Move camera
- **Mouse Wheel** - Zoom in/out
- **R** - Regenerate terrain
- **T** - Toggle wireframe view
- **Left Click** - Place damage at cursor
- **Right Click** - Create clearing zone

## Research Sources

- [Red Blob Games: Making maps with noise](https://www.redblobgames.com/maps/terrain-from-noise/)
- [The Mountains of Madness: Interactive Terrain Generation](https://amanpriyanshu.github.io/The-Mountains-of-Madness/)
- [Nick McDonald: Simple Particle-Based Hydraulic Erosion](https://nickmcd.me/2020/04/10/simple-particle-based-hydraulic-erosion/)
- [Job Talle: Simulating Hydraulic Erosion](https://jobtalle.com/simulating_hydraulic_erosion.html)
- [Terrain3D for Godot](https://github.com/TokisanGames/Terrain3D)
- [HTerrain Plugin](https://hterrain-plugin.readthedocs.io/)

## Integration with RealVietnamRTS

This terrain engine can be integrated back into RealVietnamRTS by:
1. Copying `core/` and `systems/` folders
2. Registering autoloads in project.godot
3. Adapting the cell streaming system to use TerrainEngine

Key improvements over original Daggerfall approach:
- Domain warping for organic terrain
- Ridged multifractal for realistic mountains
- Hydraulic erosion for natural valleys
- Height-dependent detail weighting
- Unified damage/clearing systems


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
