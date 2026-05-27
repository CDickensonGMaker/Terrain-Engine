extends RefCounted
class_name SwampDetector
## Detects swamp zones based on terrain characteristics
## Swamps form in flat, low-elevation areas near rivers

## Maximum slope for swamp terrain (radians, ~5 degrees)
var max_slope: float = 0.087

## Maximum elevation as fraction of height scale (30%)
var max_elevation_fraction: float = 0.30

## Maximum distance from river to consider (meters)
var river_proximity: float = 40.0

## Minimum area for a swamp zone (square meters)
var min_area: float = 200.0

## Internal reference to heightmap
var _heightmap: RefCounted = null  # HeightmapStorage

## Reference to water system for river positions
var _water_system: Node = null

## Direction offsets for 4-neighbor connectivity
const DIRS_4 := [
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)
]


## Result structure for swamp zone
class SwampZone:
	var cells: Array[Vector2i] = []  # All cells in the swamp
	var bounds: Rect2 = Rect2()
	var area: float = 0.0
	var avg_depth: float = 0.0  # Shallow water depth
	var center: Vector2 = Vector2.ZERO


## Detect swamp zones in the terrain
## OPTIMIZED: Check river proximity per-zone, not per-cell
func detect_swamps(heightmap: RefCounted, water_system: Node) -> Array[SwampZone]:
	_heightmap = heightmap
	_water_system = water_system

	var zones: Array[SwampZone] = []
	var size: int = heightmap.size
	var cell_size: float = heightmap.cell_size
	var height_scale: float = heightmap.height_scale

	# Track processed cells
	var processed := PackedByteArray()
	processed.resize(size * size)
	processed.fill(0)

	# First, identify candidate cells (flat, low) - NO river check here
	var candidates := _find_terrain_candidates(size, cell_size)
	print("[SwampDetector] Found %d terrain candidates (flat+low)" % candidates.size())

	if candidates.size() == 0:
		return zones

	# Create lookup set for candidates
	var candidate_set: Dictionary = {}
	for cell in candidates:
		candidate_set[cell] = true

	# Flood fill to group adjacent candidates into potential zones
	var potential_zones: Array[SwampZone] = []
	for cell in candidates:
		var idx: int = cell.y * size + cell.x
		if processed[idx] != 0:
			continue

		var zone := _flood_fill_zone(cell, candidate_set, processed, size, cell_size, height_scale)
		if zone and zone.area >= min_area:
			potential_zones.append(zone)

	print("[SwampDetector] Grouped into %d potential zones" % potential_zones.size())

	# Now filter zones by river proximity (check once per zone, not per cell)
	for zone in potential_zones:
		if _zone_near_river(zone, cell_size):
			zones.append(zone)

	print("[SwampDetector] %d zones near rivers" % zones.size())
	return zones


## Find cells that meet terrain criteria (flat + low elevation)
## Does NOT check river proximity - that's done per-zone later
func _find_terrain_candidates(size: int, cell_size: float) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	var max_elev: float = max_elevation_fraction

	# Calculate slope threshold
	var slope_factor: float = sin(max_slope)

	# Sample every 2 cells for performance
	for z in range(1, size - 1, 2):
		for x in range(1, size - 1, 2):
			var height: float = _heightmap.get_cell(x, z)

			# Check elevation threshold
			if height > max_elev:
				continue

			# Check slope
			var slope: float = _calculate_slope(x, z)
			if slope > slope_factor:
				continue

			# Skip if already water
			var world_x: float = x * cell_size
			var world_z: float = z * cell_size
			if _water_system and _water_system.is_water(world_x, world_z):
				continue

			candidates.append(Vector2i(x, z))

	return candidates


## Calculate slope at a cell (0=flat, 1=vertical)
func _calculate_slope(x: int, z: int) -> float:
	var _h_center: float = _heightmap.get_cell(x, z)
	var h_north: float = _heightmap.get_cell(x, z - 1)
	var h_south: float = _heightmap.get_cell(x, z + 1)
	var h_west: float = _heightmap.get_cell(x - 1, z)
	var h_east: float = _heightmap.get_cell(x + 1, z)

	var dx: float = (h_east - h_west) * 0.5
	var dz: float = (h_south - h_north) * 0.5

	return sqrt(dx * dx + dz * dz)


## Check if a zone is near a river (check zone center + edges)
func _zone_near_river(zone: SwampZone, cell_size: float) -> bool:
	if not _water_system:
		return false

	# Check zone center
	if _point_near_river(zone.center.x, zone.center.y):
		return true

	# Check a few edge points of the zone bounds
	var b := zone.bounds
	var check_points: Array[Vector2] = [
		Vector2(b.position.x, b.position.y),  # Top-left
		Vector2(b.end.x, b.position.y),       # Top-right
		Vector2(b.position.x, b.end.y),       # Bottom-left
		Vector2(b.end.x, b.end.y),            # Bottom-right
		Vector2(b.position.x + b.size.x * 0.5, b.position.y),  # Top-center
		Vector2(b.position.x + b.size.x * 0.5, b.end.y),       # Bottom-center
		Vector2(b.position.x, b.position.y + b.size.y * 0.5),  # Left-center
		Vector2(b.end.x, b.position.y + b.size.y * 0.5),       # Right-center
	]

	for pt in check_points:
		if _point_near_river(pt.x, pt.y):
			return true

	return false


## Check if a single point is near a river
func _point_near_river(world_x: float, world_z: float) -> bool:
	# Check distance to water
	var dist: float = _water_system.get_distance_to_water(world_x, world_z)
	if dist < river_proximity:
		# Verify it's a river (not pond/lake/coastal)
		var sample_dist: float = minf(dist, 10.0)
		for angle in [0.0, PI * 0.5, PI, PI * 1.5]:
			var sx: float = world_x + cos(angle) * sample_dist
			var sz: float = world_z + sin(angle) * sample_dist
			var water_type: int = _water_system.get_water_type(sx, sz)
			# Creek (1) or River (2)
			if water_type == 1 or water_type == 2:
				return true
	return false


## Flood fill to create a connected swamp zone
func _flood_fill_zone(start: Vector2i, candidate_set: Dictionary, processed: PackedByteArray, size: int, cell_size: float, height_scale: float) -> SwampZone:
	var zone := SwampZone.new()
	var frontier: Array[Vector2i] = [start]

	var min_pt := Vector2(INF, INF)
	var max_pt := Vector2(-INF, -INF)
	var total_depth: float = 0.0
	var center_sum := Vector2.ZERO

	while frontier.size() > 0:
		var current: Vector2i = frontier.pop_back()
		var idx: int = current.y * size + current.x

		if processed[idx] != 0:
			continue
		processed[idx] = 1

		zone.cells.append(current)

		# Calculate world position
		var world_x: float = current.x * cell_size
		var world_z: float = current.y * cell_size

		# Track bounds
		min_pt.x = minf(min_pt.x, world_x)
		min_pt.y = minf(min_pt.y, world_z)
		max_pt.x = maxf(max_pt.x, world_x + cell_size)
		max_pt.y = maxf(max_pt.y, world_z + cell_size)
		center_sum += Vector2(world_x + cell_size * 0.5, world_z + cell_size * 0.5)

		# Swamps are shallow - depth based on elevation below threshold
		var height: float = _heightmap.get_cell(current.x, current.y) * height_scale
		var swamp_depth: float = clampf(max_elevation_fraction * height_scale - height, 0.1, 1.0)
		total_depth += swamp_depth

		# Check neighbors
		for dir in DIRS_4:
			var neighbor := Vector2i(current.x + dir.x, current.y + dir.y)
			if neighbor.x < 0 or neighbor.x >= size or neighbor.y < 0 or neighbor.y >= size:
				continue

			var n_idx: int = neighbor.y * size + neighbor.x
			if processed[n_idx] != 0:
				continue

			if candidate_set.has(neighbor):
				frontier.append(neighbor)

	if zone.cells.size() == 0:
		return null

	zone.bounds = Rect2(min_pt, max_pt - min_pt)
	zone.area = zone.cells.size() * cell_size * cell_size
	zone.avg_depth = total_depth / zone.cells.size()
	zone.center = center_sum / zone.cells.size()

	return zone


## Generate polygon outline from zone cells
func cells_to_polygon(zone: SwampZone, cell_size: float) -> PackedVector2Array:
	if zone.cells.size() == 0:
		return PackedVector2Array()

	# Create a set for fast lookup
	var cell_set: Dictionary = {}
	for cell in zone.cells:
		cell_set[cell] = true

	# Find edge cells
	var edge_cells: Array[Vector2i] = []
	for cell in zone.cells:
		for dir in DIRS_4:
			var neighbor := Vector2i(cell.x + dir.x, cell.y + dir.y)
			if not cell_set.has(neighbor):
				edge_cells.append(cell)
				break

	if edge_cells.size() < 3:
		return PackedVector2Array()

	# Convert to world coordinates
	var points: PackedVector2Array = PackedVector2Array()
	for cell in edge_cells:
		var world_x: float = (cell.x + 0.5) * cell_size
		var world_z: float = (cell.y + 0.5) * cell_size
		points.append(Vector2(world_x, world_z))

	# Sort by angle from centroid
	var centroid := zone.center
	var sorted_points: Array[Vector2] = []
	for pt in points:
		sorted_points.append(pt)

	sorted_points.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		var angle_a := atan2(a.y - centroid.y, a.x - centroid.x)
		var angle_b := atan2(b.y - centroid.y, b.x - centroid.x)
		return angle_a < angle_b
	)

	var polygon := PackedVector2Array()
	for pt in sorted_points:
		polygon.append(pt)

	return polygon
