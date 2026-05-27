extends RefCounted
class_name PondDetector
## Detects depressions in terrain for pond/lake generation
## Uses flood fill from local minima to find water bodies

## Minimum depression depth to consider (meters)
var min_depth: float = 0.5

## Minimum area to consider (square meters)
var min_area: float = 50.0

## Maximum area before splitting detection (square meters)
var max_area: float = 50000.0

## Cell step for finding local minima (skip cells for performance)
var minima_search_step: int = 4

## Internal reference to heightmap
var _heightmap: RefCounted = null  # HeightmapStorage

## Direction offsets for 8-neighbor connectivity
const DIRS_8 := [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0),                   Vector2i(1, 0),
	Vector2i(-1, 1),  Vector2i(0, 1),  Vector2i(1, 1)
]

## Direction offsets for 4-neighbor connectivity (for flood fill)
const DIRS_4 := [
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)
]


## Result structure for a detected depression
class Depression:
	var cells: Array[Vector2i] = []  # All cells in the depression
	var minimum: Vector2i = Vector2i.ZERO  # Lowest point cell
	var pour_point: Vector2i = Vector2i.ZERO  # Where water overflows
	var min_elevation: float = 0.0  # Height at minimum (meters)
	var pour_elevation: float = 0.0  # Height at pour point (meters)
	var water_depth: float = 0.0  # pour_elevation - min_elevation
	var area: float = 0.0  # Area in square meters
	var bounds: Rect2 = Rect2()  # World bounds


## Detect all depressions in the heightmap
func detect_depressions(heightmap: RefCounted) -> Array[Depression]:
	_heightmap = heightmap
	var depressions: Array[Depression] = []

	# Track which cells have been processed
	var processed := PackedByteArray()
	processed.resize(heightmap.size * heightmap.size)
	processed.fill(0)

	# Find local minima
	var minima := _find_local_minima()
	print("[PondDetector] Found %d local minima" % minima.size())

	# Sort minima by elevation (process lowest first)
	minima.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return heightmap.get_cell(a.x, a.y) < heightmap.get_cell(b.x, b.y)
	)

	# Flood fill from each minimum
	for minimum in minima:
		var idx: int = minimum.y * heightmap.size + minimum.x
		if processed[idx] != 0:
			continue  # Already part of another depression

		var depression := _flood_fill_depression(minimum, processed)

		if depression and depression.water_depth >= min_depth / heightmap.height_scale:
			if depression.area >= min_area and depression.area <= max_area:
				depressions.append(depression)

	print("[PondDetector] Detected %d depressions" % depressions.size())
	return depressions


## Find local minima in the heightmap
func _find_local_minima() -> Array[Vector2i]:
	var minima: Array[Vector2i] = []
	var size: int = _heightmap.size

	# Skip edges and sample at intervals for performance
	for z in range(minima_search_step, size - minima_search_step, minima_search_step):
		for x in range(minima_search_step, size - minima_search_step, minima_search_step):
			if _is_local_minimum(x, z):
				minima.append(Vector2i(x, z))

	return minima


## Check if a cell is a local minimum (lower than all 8 neighbors)
func _is_local_minimum(x: int, z: int) -> bool:
	var height: float = _heightmap.get_cell(x, z)

	for dir in DIRS_8:
		var nx: int = x + dir.x
		var nz: int = z + dir.y
		var neighbor_height: float = _heightmap.get_cell(nx, nz)

		if neighbor_height <= height:
			return false

	return true


## Flood fill from a minimum to find depression extent
func _flood_fill_depression(start: Vector2i, global_processed: PackedByteArray) -> Depression:
	var size: int = _heightmap.size
	var cell_size: float = _heightmap.cell_size

	# Priority queue: (elevation, cell) - process lowest cells first
	var frontier: Array = []
	var in_depression: Dictionary = {}  # cell -> true
	var rim: Dictionary = {}  # Cells on the edge that could be pour points

	var start_elev: float = _heightmap.get_cell(start.x, start.y)
	frontier.append([start_elev, start])
	in_depression[start] = true

	var min_cell: Vector2i = start
	var min_elev: float = start_elev
	var pour_cell: Vector2i = start
	var pour_elev: float = INF

	# Maximum cells to process (prevent runaway on flat terrain)
	const MAX_CELLS := 100000
	var cells_processed := 0

	while frontier.size() > 0 and cells_processed < MAX_CELLS:
		# Sort by elevation (simple priority queue)
		frontier.sort_custom(func(a: Array, b: Array) -> bool:
			return a[0] < b[0]
		)

		var entry: Array = frontier.pop_front()
		var current_elev: float = entry[0]
		var current: Vector2i = entry[1]
		cells_processed += 1

		# If we've risen above the current pour point, stop expanding
		if current_elev > pour_elev:
			continue

		# Check 4-connected neighbors
		for dir in DIRS_4:
			var neighbor := Vector2i(current.x + dir.x, current.y + dir.y)

			# Bounds check
			if neighbor.x < 0 or neighbor.x >= size or neighbor.y < 0 or neighbor.y >= size:
				# Edge of map is a pour point
				if current_elev < pour_elev:
					pour_elev = current_elev
					pour_cell = current
				continue

			# Skip if already in depression
			if in_depression.has(neighbor):
				continue

			var neighbor_elev: float = _heightmap.get_cell(neighbor.x, neighbor.y)

			# If neighbor is higher, it's a potential rim/pour point
			if neighbor_elev > current_elev:
				# Track the lowest rim point (pour point)
				if neighbor_elev < pour_elev:
					pour_elev = neighbor_elev
					pour_cell = neighbor
				rim[neighbor] = true
			else:
				# Neighbor is same height or lower - add to depression
				in_depression[neighbor] = true
				frontier.append([neighbor_elev, neighbor])

				# Track minimum
				if neighbor_elev < min_elev:
					min_elev = neighbor_elev
					min_cell = neighbor

	# If no pour point found or depression too small, skip
	if pour_elev == INF or in_depression.size() < 4:
		return null

	# Build depression result
	var depression := Depression.new()
	depression.minimum = min_cell
	depression.pour_point = pour_cell
	depression.min_elevation = min_elev * _heightmap.height_scale
	depression.pour_elevation = pour_elev * _heightmap.height_scale
	depression.water_depth = depression.pour_elevation - depression.min_elevation

	# Collect cells below pour point elevation
	var min_pt := Vector2(INF, INF)
	var max_pt := Vector2(-INF, -INF)

	for cell in in_depression.keys():
		var cell_elev: float = _heightmap.get_cell(cell.x, cell.y)
		if cell_elev < pour_elev:
			depression.cells.append(cell)

			# Mark as globally processed
			var idx: int = cell.y * size + cell.x
			global_processed[idx] = 1

			# Track bounds
			var world_x: float = cell.x * cell_size
			var world_z: float = cell.y * cell_size
			min_pt.x = minf(min_pt.x, world_x)
			min_pt.y = minf(min_pt.y, world_z)
			max_pt.x = maxf(max_pt.x, world_x + cell_size)
			max_pt.y = maxf(max_pt.y, world_z + cell_size)

	if depression.cells.size() == 0:
		return null

	depression.bounds = Rect2(min_pt, max_pt - min_pt)
	depression.area = depression.cells.size() * cell_size * cell_size

	return depression


## Convert depression cells to a polygon outline (for mesh generation)
func cells_to_polygon(depression: Depression) -> PackedVector2Array:
	if depression.cells.size() == 0:
		return PackedVector2Array()

	var cell_size: float = _heightmap.cell_size

	# Create a set for fast lookup
	var cell_set: Dictionary = {}
	for cell in depression.cells:
		cell_set[cell] = true

	# Find edge cells (cells with at least one neighbor not in the set)
	var edge_cells: Array[Vector2i] = []
	for cell in depression.cells:
		for dir in DIRS_4:
			var neighbor := Vector2i(cell.x + dir.x, cell.y + dir.y)
			if not cell_set.has(neighbor):
				edge_cells.append(cell)
				break

	if edge_cells.size() < 3:
		return PackedVector2Array()

	# Convert edge cells to world coordinates (cell centers)
	var points: PackedVector2Array = PackedVector2Array()
	for cell in edge_cells:
		var world_x: float = (cell.x + 0.5) * cell_size
		var world_z: float = (cell.y + 0.5) * cell_size
		points.append(Vector2(world_x, world_z))

	# Sort points by angle from centroid for proper polygon winding
	var centroid := Vector2.ZERO
	for pt in points:
		centroid += pt
	centroid /= points.size()

	var sorted_points: Array[Vector2] = []
	for pt in points:
		sorted_points.append(pt)

	sorted_points.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		var angle_a := atan2(a.y - centroid.y, a.x - centroid.x)
		var angle_b := atan2(b.y - centroid.y, b.x - centroid.x)
		return angle_a < angle_b
	)

	# Build final polygon
	var polygon := PackedVector2Array()
	for pt in sorted_points:
		polygon.append(pt)

	return polygon


## Simplify polygon using Douglas-Peucker algorithm
func simplify_polygon(polygon: PackedVector2Array, tolerance: float = 2.0) -> PackedVector2Array:
	if polygon.size() < 4:
		return polygon

	# Douglas-Peucker simplification
	return _douglas_peucker(polygon, 0, polygon.size() - 1, tolerance)


func _douglas_peucker(points: PackedVector2Array, start_idx: int, end_idx: int, tolerance: float) -> PackedVector2Array:
	if end_idx - start_idx < 2:
		var result := PackedVector2Array()
		result.append(points[start_idx])
		if start_idx != end_idx:
			result.append(points[end_idx])
		return result

	# Find point with maximum distance from line
	var max_dist: float = 0.0
	var max_idx: int = start_idx

	var start_pt: Vector2 = points[start_idx]
	var end_pt: Vector2 = points[end_idx]
	var line_vec: Vector2 = end_pt - start_pt
	var line_len: float = line_vec.length()

	if line_len > 0.001:
		line_vec /= line_len

		for i in range(start_idx + 1, end_idx):
			var pt: Vector2 = points[i]
			var to_pt: Vector2 = pt - start_pt
			var proj: float = to_pt.dot(line_vec)
			var closest: Vector2 = start_pt + line_vec * clampf(proj, 0.0, line_len)
			var dist: float = pt.distance_to(closest)

			if dist > max_dist:
				max_dist = dist
				max_idx = i

	# If max distance is greater than tolerance, recursively simplify
	if max_dist > tolerance:
		var left := _douglas_peucker(points, start_idx, max_idx, tolerance)
		var right := _douglas_peucker(points, max_idx, end_idx, tolerance)

		# Combine (skip duplicate middle point)
		var result := PackedVector2Array()
		for i in range(left.size() - 1):
			result.append(left[i])
		for pt in right:
			result.append(pt)
		return result
	else:
		var result := PackedVector2Array()
		result.append(start_pt)
		result.append(end_pt)
		return result
