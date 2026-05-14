extends RefCounted
class_name GameplayGrid
## Grid-based metadata storage for efficient game logic queries
## Stores elevation, terrain type, movement cost, cover values per cell
## Designed for RTS gameplay - travel speed modifiers, combat bonuses, pathfinding

signal grid_updated(region: Rect2i)

# Grid dimensions
var grid_size: int = 256  # Cells per side
var cell_size_meters: float = 12.0  # Meters per cell (larger than heightmap for perf)
var world_size: float = 3072.0  # Total world size in meters

# Terrain type enum matching clearing_system
enum TerrainType {
	CLEAR = 0,       # Open ground, fastest movement
	RICE_PADDY = 1,  # Flooded field, slow movement, no cover
	GRASSLAND = 2,   # Light vegetation, normal speed
	LIGHT_JUNGLE = 3,  # Light cover, slight slow
	MEDIUM_JUNGLE = 4, # Good cover, moderate slow
	HEAVY_JUNGLE = 5,  # Excellent cover, very slow
	WATER = 6,       # Impassable for most units
	CLIFF = 7,       # Impassable, blocks LOS
}

# Movement cost multipliers (1.0 = normal, higher = slower)
const MOVEMENT_COSTS: Dictionary = {
	TerrainType.CLEAR: 1.0,
	TerrainType.RICE_PADDY: 1.8,
	TerrainType.GRASSLAND: 1.1,
	TerrainType.LIGHT_JUNGLE: 1.3,
	TerrainType.MEDIUM_JUNGLE: 1.6,
	TerrainType.HEAVY_JUNGLE: 2.2,
	TerrainType.WATER: 99.0,  # Effectively impassable
	TerrainType.CLIFF: 99.0,
}

# Cover values (0.0 = no cover, 1.0 = full concealment)
const COVER_VALUES: Dictionary = {
	TerrainType.CLEAR: 0.0,
	TerrainType.RICE_PADDY: 0.1,
	TerrainType.GRASSLAND: 0.15,
	TerrainType.LIGHT_JUNGLE: 0.35,
	TerrainType.MEDIUM_JUNGLE: 0.55,
	TerrainType.HEAVY_JUNGLE: 0.8,
	TerrainType.WATER: 0.0,
	TerrainType.CLIFF: 0.9,
}

# Defense bonus multipliers (damage reduction when in cover)
const DEFENSE_BONUS: Dictionary = {
	TerrainType.CLEAR: 1.0,
	TerrainType.RICE_PADDY: 0.95,
	TerrainType.GRASSLAND: 0.9,
	TerrainType.LIGHT_JUNGLE: 0.8,
	TerrainType.MEDIUM_JUNGLE: 0.65,
	TerrainType.HEAVY_JUNGLE: 0.5,
	TerrainType.WATER: 1.0,
	TerrainType.CLIFF: 0.4,
}

# Grid data arrays (packed for memory efficiency)
var elevation: PackedFloat32Array      # Height in meters
var slope: PackedFloat32Array          # Slope angle 0-1 (0=flat, 1=vertical)
var terrain_type: PackedByteArray     # TerrainType enum
var vegetation_density: PackedFloat32Array  # 0-1 vegetation coverage
var is_passable: PackedByteArray      # 0=blocked, 1=passable

# References
var heightmap_storage: RefCounted  # HeightmapStorage
var clearing_system: Node


func _init(world_size_meters: float = 3072.0, cells_per_side: int = 256) -> void:
	world_size = world_size_meters
	grid_size = cells_per_side
	cell_size_meters = world_size / grid_size

	# Initialize arrays
	var total_cells: int = grid_size * grid_size
	elevation.resize(total_cells)
	slope.resize(total_cells)
	terrain_type.resize(total_cells)
	vegetation_density.resize(total_cells)
	is_passable.resize(total_cells)

	# Default values
	elevation.fill(0.0)
	slope.fill(0.0)
	terrain_type.fill(TerrainType.GRASSLAND)
	vegetation_density.fill(0.5)
	is_passable.fill(1)

	print("[GameplayGrid] Initialized %dx%d grid (%.1fm cells, %.2f MB)" % [
		grid_size, grid_size, cell_size_meters,
		(total_cells * (4 + 4 + 1 + 4 + 1)) / 1048576.0
	])


## Set references
func set_heightmap(hm: RefCounted) -> void:
	heightmap_storage = hm


func set_clearing_system(cs: Node) -> void:
	clearing_system = cs


## Build grid from heightmap and vegetation data
func build_from_terrain() -> void:
	if not heightmap_storage:
		push_warning("[GameplayGrid] No heightmap set, using defaults")
		return

	print("[GameplayGrid] Building grid from terrain data...")
	var start_time := Time.get_ticks_msec()

	for gz in grid_size:
		for gx in grid_size:
			var idx: int = gz * grid_size + gx

			# Get world position for this cell center
			var world_x: float = (gx + 0.5) * cell_size_meters
			var world_z: float = (gz + 0.5) * cell_size_meters

			# Sample elevation
			var h: float = heightmap_storage.sample_world(world_x, world_z)
			elevation[idx] = h

			# Calculate slope from heightmap normal
			var normal: Vector3 = heightmap_storage.get_normal_world(world_x, world_z)
			var slope_val: float = 1.0 - normal.y  # 0=flat, 1=vertical
			slope[idx] = clampf(slope_val, 0.0, 1.0)

			# Determine terrain type from slope and elevation
			var ttype: int = _determine_terrain_type(h, slope_val, world_x, world_z)
			terrain_type[idx] = ttype

			# Set passability
			is_passable[idx] = 1 if ttype != TerrainType.WATER and ttype != TerrainType.CLIFF else 0

			# Get vegetation density from clearing system if available
			if clearing_system and clearing_system.has_method("get_density_at"):
				vegetation_density[idx] = clearing_system.get_density_at(world_x, world_z)
			else:
				# Estimate from terrain type
				vegetation_density[idx] = _estimate_vegetation(ttype)

	var elapsed: int = Time.get_ticks_msec() - start_time
	print("[GameplayGrid] Grid built in %dms" % elapsed)
	grid_updated.emit(Rect2i(0, 0, grid_size, grid_size))


## Determine terrain type from elevation and slope
func _determine_terrain_type(height: float, slope_val: float, _wx: float, _wz: float) -> int:
	# Cliff detection (steep slopes)
	if slope_val > 0.7:
		return TerrainType.CLIFF

	# Low elevation near water level
	if height < 5.0:
		if slope_val < 0.1:
			return TerrainType.RICE_PADDY  # Flat low areas = paddies
		return TerrainType.WATER

	# Very low = flooded
	if height < 2.0:
		return TerrainType.WATER

	# Medium slopes = lighter vegetation
	if slope_val > 0.4:
		return TerrainType.LIGHT_JUNGLE

	# Based on elevation zones (Vietnam terrain)
	if height < 50.0:
		return TerrainType.RICE_PADDY if randf() < 0.3 else TerrainType.GRASSLAND
	elif height < 150.0:
		return TerrainType.MEDIUM_JUNGLE
	elif height < 250.0:
		return TerrainType.HEAVY_JUNGLE
	else:
		return TerrainType.LIGHT_JUNGLE  # High altitude = sparser


## Estimate vegetation from terrain type
func _estimate_vegetation(ttype: int) -> float:
	match ttype:
		TerrainType.CLEAR: return 0.0
		TerrainType.RICE_PADDY: return 0.2
		TerrainType.GRASSLAND: return 0.3
		TerrainType.LIGHT_JUNGLE: return 0.5
		TerrainType.MEDIUM_JUNGLE: return 0.7
		TerrainType.HEAVY_JUNGLE: return 0.95
		_: return 0.0


# ============================================================================
# QUERY METHODS - Fast O(1) lookups for game logic
# ============================================================================

## Convert world position to grid coordinates
func world_to_grid(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		clampi(int(world_pos.x / cell_size_meters), 0, grid_size - 1),
		clampi(int(world_pos.z / cell_size_meters), 0, grid_size - 1)
	)


## Convert grid coordinates to world position (cell center)
func grid_to_world(grid_pos: Vector2i) -> Vector3:
	return Vector3(
		(grid_pos.x + 0.5) * cell_size_meters,
		0.0,  # Y filled by caller using get_elevation
		(grid_pos.y + 0.5) * cell_size_meters
	)


## Get cell index from grid coordinates
func _grid_to_index(gx: int, gz: int) -> int:
	return gz * grid_size + gx


## Get elevation at world position (meters)
func get_elevation(world_pos: Vector3) -> float:
	var g := world_to_grid(world_pos)
	return elevation[_grid_to_index(g.x, g.y)]


## Get elevation at grid coordinates
func get_elevation_at(gx: int, gz: int) -> float:
	if gx < 0 or gx >= grid_size or gz < 0 or gz >= grid_size:
		return 0.0
	return elevation[_grid_to_index(gx, gz)]


## Get slope at world position (0=flat, 1=cliff)
func get_slope(world_pos: Vector3) -> float:
	var g := world_to_grid(world_pos)
	return slope[_grid_to_index(g.x, g.y)]


## Get terrain type at world position
func get_terrain_type(world_pos: Vector3) -> int:
	var g := world_to_grid(world_pos)
	return terrain_type[_grid_to_index(g.x, g.y)]


## Get terrain type at grid coordinates
func get_terrain_type_at(gx: int, gz: int) -> int:
	if gx < 0 or gx >= grid_size or gz < 0 or gz >= grid_size:
		return TerrainType.CLIFF
	return terrain_type[_grid_to_index(gx, gz)]


## Get movement cost multiplier at world position
func get_movement_cost(world_pos: Vector3) -> float:
	var ttype: int = get_terrain_type(world_pos)
	var base_cost: float = MOVEMENT_COSTS.get(ttype, 1.0)

	# Slope modifier (steeper = slower)
	var slope_val: float = get_slope(world_pos)
	var slope_penalty: float = 1.0 + slope_val * 0.5  # Up to 50% slower on slopes

	return base_cost * slope_penalty


## Get cover value at world position (0-1)
func get_cover(world_pos: Vector3) -> float:
	var ttype: int = get_terrain_type(world_pos)
	return COVER_VALUES.get(ttype, 0.0)


## Get defense bonus at world position (damage multiplier, lower = better)
func get_defense_bonus(world_pos: Vector3) -> float:
	var ttype: int = get_terrain_type(world_pos)
	return DEFENSE_BONUS.get(ttype, 1.0)


## Get vegetation density at world position (0-1)
func get_vegetation(world_pos: Vector3) -> float:
	var g := world_to_grid(world_pos)
	return vegetation_density[_grid_to_index(g.x, g.y)]


## Check if position is passable
func is_position_passable(world_pos: Vector3) -> bool:
	var g := world_to_grid(world_pos)
	return is_passable[_grid_to_index(g.x, g.y)] == 1


## Check if grid cell is passable
func is_cell_passable(gx: int, gz: int) -> bool:
	if gx < 0 or gx >= grid_size or gz < 0 or gz >= grid_size:
		return false
	return is_passable[_grid_to_index(gx, gz)] == 1


## Get elevation difference between two positions (for height advantage)
func get_elevation_advantage(attacker_pos: Vector3, target_pos: Vector3) -> float:
	var attacker_h: float = get_elevation(attacker_pos)
	var target_h: float = get_elevation(target_pos)
	return attacker_h - target_h


## Check line of sight between two positions (basic grid raycast)
func has_line_of_sight(from_pos: Vector3, to_pos: Vector3) -> bool:
	var from_grid := world_to_grid(from_pos)
	var to_grid := world_to_grid(to_pos)

	var from_h: float = get_elevation(from_pos) + 1.8  # Eye height
	var to_h: float = get_elevation(to_pos) + 1.0  # Target height

	# Bresenham-style raycast through grid
	var dx: int = absi(to_grid.x - from_grid.x)
	var dz: int = absi(to_grid.y - from_grid.y)
	var sx: int = 1 if from_grid.x < to_grid.x else -1
	var sz: int = 1 if from_grid.y < to_grid.y else -1
	var err: int = dx - dz

	var x: int = from_grid.x
	var z: int = from_grid.y
	var steps: int = dx + dz
	if steps == 0:
		return true

	for i in steps:
		# Check if terrain blocks LOS
		var t: float = float(i) / float(steps)
		var expected_h: float = lerpf(from_h, to_h, t)
		var cell_h: float = get_elevation_at(x, z)
		var cell_type: int = get_terrain_type_at(x, z)

		# Cliffs and heavy jungle block LOS
		if cell_type == TerrainType.CLIFF:
			if cell_h > expected_h:
				return false
		elif cell_type == TerrainType.HEAVY_JUNGLE:
			# Dense jungle has chance to block based on distance
			if randf() < 0.3:  # 30% block chance per cell
				return false

		# Step to next cell
		var e2: int = 2 * err
		if e2 > -dz:
			err -= dz
			x += sx
		if e2 < dx:
			err += dx
			z += sz

	return true


# ============================================================================
# UPDATE METHODS - Called when terrain changes
# ============================================================================

## Update a region when clearing occurs
func update_region(center: Vector3, radius_meters: float) -> void:
	var g_center := world_to_grid(center)
	var g_radius: int = int(ceil(radius_meters / cell_size_meters))

	var min_x: int = maxi(0, g_center.x - g_radius)
	var max_x: int = mini(grid_size, g_center.x + g_radius + 1)
	var min_z: int = maxi(0, g_center.y - g_radius)
	var max_z: int = mini(grid_size, g_center.y + g_radius + 1)

	for gz in range(min_z, max_z):
		for gx in range(min_x, max_x):
			var idx: int = _grid_to_index(gx, gz)
			var world_x: float = (gx + 0.5) * cell_size_meters
			var world_z: float = (gz + 0.5) * cell_size_meters

			# Re-sample vegetation
			if clearing_system and clearing_system.has_method("get_density_at"):
				var density: float = clearing_system.get_density_at(world_x, world_z)
				vegetation_density[idx] = density

				# Update terrain type based on new vegetation
				if density < 0.1:
					terrain_type[idx] = TerrainType.CLEAR
					is_passable[idx] = 1
				elif density < 0.3:
					terrain_type[idx] = TerrainType.GRASSLAND
				elif density < 0.5:
					terrain_type[idx] = TerrainType.LIGHT_JUNGLE
				elif density < 0.7:
					terrain_type[idx] = TerrainType.MEDIUM_JUNGLE
				# else keep current type

	grid_updated.emit(Rect2i(min_x, min_z, max_x - min_x, max_z - min_z))


## Mark area as cleared (after jungle clearing)
func mark_cleared(center: Vector3, radius_meters: float) -> void:
	var g_center := world_to_grid(center)
	var g_radius: int = int(ceil(radius_meters / cell_size_meters))

	for gz in range(g_center.y - g_radius, g_center.y + g_radius + 1):
		for gx in range(g_center.x - g_radius, g_center.x + g_radius + 1):
			if gx < 0 or gx >= grid_size or gz < 0 or gz >= grid_size:
				continue

			var dist: float = Vector2(gx - g_center.x, gz - g_center.y).length()
			if dist <= g_radius:
				var idx: int = _grid_to_index(gx, gz)
				terrain_type[idx] = TerrainType.CLEAR
				vegetation_density[idx] = 0.0
				is_passable[idx] = 1

	grid_updated.emit(Rect2i(g_center.x - g_radius, g_center.y - g_radius, g_radius * 2, g_radius * 2))


## Get terrain type name (for debug)
func get_terrain_name(ttype: int) -> String:
	match ttype:
		TerrainType.CLEAR: return "Clear"
		TerrainType.RICE_PADDY: return "Rice Paddy"
		TerrainType.GRASSLAND: return "Grassland"
		TerrainType.LIGHT_JUNGLE: return "Light Jungle"
		TerrainType.MEDIUM_JUNGLE: return "Medium Jungle"
		TerrainType.HEAVY_JUNGLE: return "Heavy Jungle"
		TerrainType.WATER: return "Water"
		TerrainType.CLIFF: return "Cliff"
		_: return "Unknown"


## Print grid stats
func print_stats() -> void:
	var counts: Dictionary = {}
	for i in TerrainType.values():
		counts[i] = 0

	for i in terrain_type.size():
		var t: int = terrain_type[i]
		counts[t] = counts.get(t, 0) + 1

	print("[GameplayGrid] Terrain distribution:")
	for ttype: int in counts:
		var pct: float = 100.0 * counts[ttype] / terrain_type.size()
		print("  %s: %d cells (%.1f%%)" % [get_terrain_name(ttype), counts[ttype], pct])
