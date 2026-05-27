extends RefCounted
class_name CoastalDetector
## Detects coastal zones by flooding from map edges to sea level
## Creates ocean water along map boundaries

## Which edges have ocean (bitmask: 1=North, 2=East, 4=South, 8=West)
var ocean_edges: int = 0b1111  # All edges by default

## Sea level in meters
var sea_level: float = 5.0

## Maximum flood distance from edge (cells)
var max_flood_distance: int = 200

## Minimum coastal width for mesh generation (meters)
var min_coastal_width: float = 10.0

## Internal reference to heightmap
var _heightmap: RefCounted = null  # HeightmapStorage

## Direction offsets for 4-neighbor connectivity
const DIRS_4 := [
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)
]


## Result structure for coastal zone
class CoastalZone:
	var cells: Array[Vector2i] = []  # All cells in the coastal zone
	var shoreline: PackedVector2Array = PackedVector2Array()  # Shoreline points
	var edge_mask: int = 0  # Which edges this zone touches
	var bounds: Rect2 = Rect2()
	var area: float = 0.0
	var avg_depth: float = 0.0


## Detect coastal zones from map edges
func detect_coastal(heightmap: RefCounted, sea_level_meters: float) -> Array[CoastalZone]:
	_heightmap = heightmap
	sea_level = sea_level_meters

	var zones: Array[CoastalZone] = []
	var size: int = heightmap.size
	var cell_size: float = heightmap.cell_size
	var height_scale: float = heightmap.height_scale

	# Normalized sea level
	var sea_level_norm: float = sea_level / height_scale

	# Track flooded cells
	var flooded := PackedByteArray()
	flooded.resize(size * size)
	flooded.fill(0)

	# Flood from each enabled edge
	var all_coastal_cells: Array[Vector2i] = []

	# North edge (z = 0)
	if ocean_edges & 1:
		var edge_cells := _flood_from_edge(0, size, true, sea_level_norm, flooded)
		all_coastal_cells.append_array(edge_cells)

	# East edge (x = size-1)
	if ocean_edges & 2:
		var edge_cells := _flood_from_edge(size - 1, size, false, sea_level_norm, flooded)
		all_coastal_cells.append_array(edge_cells)

	# South edge (z = size-1)
	if ocean_edges & 4:
		var edge_cells := _flood_from_edge(size - 1, size, true, sea_level_norm, flooded)
		all_coastal_cells.append_array(edge_cells)

	# West edge (x = 0)
	if ocean_edges & 8:
		var edge_cells := _flood_from_edge(0, size, false, sea_level_norm, flooded)
		all_coastal_cells.append_array(edge_cells)

	if all_coastal_cells.size() == 0:
		return zones

	# Create single coastal zone from all flooded cells
	var zone := CoastalZone.new()
	zone.cells = all_coastal_cells
	zone.edge_mask = ocean_edges

	# Calculate bounds and area
	var min_pt := Vector2(INF, INF)
	var max_pt := Vector2(-INF, -INF)
	var total_depth: float = 0.0

	for cell in zone.cells:
		var world_x: float = cell.x * cell_size
		var world_z: float = cell.y * cell_size
		min_pt.x = minf(min_pt.x, world_x)
		min_pt.y = minf(min_pt.y, world_z)
		max_pt.x = maxf(max_pt.x, world_x + cell_size)
		max_pt.y = maxf(max_pt.y, world_z + cell_size)

		var cell_height: float = heightmap.get_cell(cell.x, cell.y) * height_scale
		total_depth += sea_level - cell_height

	zone.bounds = Rect2(min_pt, max_pt - min_pt)
	zone.area = zone.cells.size() * cell_size * cell_size
	zone.avg_depth = total_depth / zone.cells.size() if zone.cells.size() > 0 else 0.0

	# Extract shoreline
	zone.shoreline = _extract_shoreline(zone.cells, flooded, size, cell_size)

	zones.append(zone)

	print("[CoastalDetector] Found coastal zone: %d cells, %.0fm² area, %.1fm avg depth" % [
		zone.cells.size(), zone.area, zone.avg_depth
	])

	return zones


## Flood from an edge inward
func _flood_from_edge(edge_coord: int, size: int, is_z_edge: bool, sea_level_norm: float, flooded: PackedByteArray) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var frontier: Array[Vector2i] = []

	# Initialize frontier with edge cells below sea level
	for i in range(size):
		var x: int = i if is_z_edge else edge_coord
		var z: int = edge_coord if is_z_edge else i

		var height: float = _heightmap.get_cell(x, z)
		if height < sea_level_norm:
			var cell := Vector2i(x, z)
			var idx: int = z * size + x
			if flooded[idx] == 0:
				frontier.append(cell)
				flooded[idx] = 1

	# BFS flood fill
	var processed := 0
	var max_cells: int = max_flood_distance * size * 2

	while frontier.size() > 0 and processed < max_cells:
		var current: Vector2i = frontier.pop_front()
		result.append(current)
		processed += 1

		# Check neighbors
		for dir in DIRS_4:
			var neighbor := Vector2i(current.x + dir.x, current.y + dir.y)

			# Bounds check
			if neighbor.x < 0 or neighbor.x >= size or neighbor.y < 0 or neighbor.y >= size:
				continue

			var idx: int = neighbor.y * size + neighbor.x
			if flooded[idx] != 0:
				continue

			# Check height
			var height: float = _heightmap.get_cell(neighbor.x, neighbor.y)
			if height < sea_level_norm:
				flooded[idx] = 1
				frontier.append(neighbor)

	return result


## Extract shoreline points from coastal cells
func _extract_shoreline(cells: Array[Vector2i], flooded: PackedByteArray, size: int, cell_size: float) -> PackedVector2Array:
	var shoreline := PackedVector2Array()

	# Find edge cells (cells with at least one non-flooded neighbor that's above sea level)
	for cell in cells:
		var is_edge := false

		for dir in DIRS_4:
			var neighbor := Vector2i(cell.x + dir.x, cell.y + dir.y)

			# Map boundary is also shoreline
			if neighbor.x < 0 or neighbor.x >= size or neighbor.y < 0 or neighbor.y >= size:
				continue

			var idx: int = neighbor.y * size + neighbor.x
			if flooded[idx] == 0:
				is_edge = true
				break

		if is_edge:
			var world_x: float = (cell.x + 0.5) * cell_size
			var world_z: float = (cell.y + 0.5) * cell_size
			shoreline.append(Vector2(world_x, world_z))

	return shoreline


## Sort shoreline points into a continuous path (approximate)
func sort_shoreline(points: PackedVector2Array) -> PackedVector2Array:
	if points.size() < 3:
		return points

	var sorted := PackedVector2Array()
	var remaining: Array[Vector2] = []

	for pt in points:
		remaining.append(pt)

	# Start with first point
	sorted.append(remaining.pop_back())

	# Greedily add nearest point
	while remaining.size() > 0:
		var last: Vector2 = sorted[sorted.size() - 1]
		var best_idx: int = 0
		var best_dist: float = INF

		for i in range(remaining.size()):
			var dist: float = last.distance_squared_to(remaining[i])
			if dist < best_dist:
				best_dist = dist
				best_idx = i

		sorted.append(remaining[best_idx])
		remaining.remove_at(best_idx)

	return sorted
