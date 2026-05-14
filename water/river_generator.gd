extends RefCounted
class_name RiverGenerator
## Extracts river paths from heightmap by computing flow accumulation
## Uses simplified D8 flow direction algorithm to find valleys


## Simple class to hold a river path with varying widths
class RiverPath:
	var points: PackedVector2Array
	var widths: PackedFloat32Array

	func _init() -> void:
		points = PackedVector2Array()
		widths = PackedFloat32Array()

	func add_point(pos: Vector2, width: float) -> void:
		points.append(pos)
		widths.append(width)

	func size() -> int:
		return points.size()


## 8-direction offsets for neighbor cells (D8 algorithm)
const DIR_OFFSETS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1,  0),                  Vector2i(1,  0),
	Vector2i(-1,  1), Vector2i(0,  1), Vector2i(1,  1)
]

## Diagonal directions have longer distance
const DIR_DISTANCES: Array[float] = [
	1.414, 1.0, 1.414,
	1.0,        1.0,
	1.414, 1.0, 1.414
]

## Scale factor for converting accumulation to river width
var width_scale: float = 0.1

## Minimum points required to form a valid river path
var min_river_length: int = 10

## Number of rivers to generate in fast mode
var num_rivers: int = 8

## Base width for rivers (meters)
var base_width: float = 4.0

## Width growth rate per step
var width_growth: float = 0.15


## FAST: Extract rivers using gradient descent (no flow accumulation)
## Much faster than full D8 - traces rivers downhill from random high points
func extract_rivers_fast(heightmap: HeightmapStorage, river_count: int = 8) -> Array[RiverPath]:
	var paths: Array[RiverPath] = []
	var map_size: int = heightmap.size
	var cell_size: float = heightmap.cell_size
	var rng := RandomNumberGenerator.new()
	rng.seed = 42  # Consistent rivers per map

	# Find candidate starting points (high elevation, not at edges)
	var margin: int = map_size / 10
	var candidates: Array[Vector2i] = []

	# Sample grid to find high points
	var sample_step: int = map_size / 20
	for z in range(margin, map_size - margin, sample_step):
		for x in range(margin, map_size - margin, sample_step):
			var h: float = heightmap.get_cell(x, z)
			if h > 0.5:  # Upper half of height range
				candidates.append(Vector2i(x, z))

	# Sort by height (highest first)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return heightmap.get_cell(a.x, a.y) > heightmap.get_cell(b.x, b.y)
	)

	# Track visited cells to avoid overlapping rivers
	var visited: Dictionary = {}

	# Trace rivers from high points
	var rivers_created: int = 0
	for start in candidates:
		if rivers_created >= river_count:
			break

		# Skip if too close to existing river
		var too_close := false
		for dx in range(-10, 11):
			for dz in range(-10, 11):
				if visited.has(Vector2i(start.x + dx, start.y + dz)):
					too_close = true
					break
			if too_close:
				break
		if too_close:
			continue

		# Trace river downhill
		var path: RiverPath = _trace_river_downhill(heightmap, start, visited)
		if path.size() >= min_river_length:
			paths.append(path)
			rivers_created += 1

	return paths


## Trace a single river path downhill using gradient descent
func _trace_river_downhill(heightmap: HeightmapStorage, start: Vector2i, visited: Dictionary) -> RiverPath:
	var path := RiverPath.new()
	var map_size: int = heightmap.size
	var cell_size: float = heightmap.cell_size
	var current := start
	var width: float = base_width
	var max_steps: int = 2000  # Prevent infinite loops
	var steps: int = 0

	while steps < max_steps:
		steps += 1

		# Mark as visited
		visited[current] = true

		# Add point to path
		var world_pos := Vector2(current.x * cell_size, current.y * cell_size)
		path.add_point(world_pos, width)

		# Increase width as river flows
		width += width_growth

		# Find steepest descent neighbor
		var current_h: float = heightmap.get_cell(current.x, current.y)
		var best_neighbor: Vector2i = Vector2i(-1, -1)
		var best_slope: float = 0.0

		for dir_idx in range(8):
			var offset: Vector2i = DIR_OFFSETS[dir_idx]
			var nx: int = current.x + offset.x
			var nz: int = current.y + offset.y

			# Bounds check
			if nx < 1 or nx >= map_size - 1 or nz < 1 or nz >= map_size - 1:
				continue

			var nh: float = heightmap.get_cell(nx, nz)
			var drop: float = current_h - nh

			if drop > 0:
				var slope: float = drop / DIR_DISTANCES[dir_idx]
				if slope > best_slope:
					best_slope = slope
					best_neighbor = Vector2i(nx, nz)

		# Stop if no downhill neighbor (pit or edge)
		if best_neighbor.x < 0:
			break

		# Stop if we've been here before (joining another river)
		if visited.has(best_neighbor):
			# Add final point where rivers merge
			var merge_pos := Vector2(best_neighbor.x * cell_size, best_neighbor.y * cell_size)
			path.add_point(merge_pos, width)
			break

		current = best_neighbor

	return path


## Extract rivers from heightmap using flow accumulation (SLOW - use extract_rivers_fast instead)
## threshold: normalized accumulation threshold (0-1), where 1.0 = max accumulation
func extract_rivers(heightmap: HeightmapStorage, threshold: float = 0.3) -> Array[RiverPath]:
	var map_size: int = heightmap.size
	var total_cells: int = map_size * map_size

	# Step 1: Calculate flow direction for each cell (steepest descent)
	var flow_dir: PackedByteArray = _compute_flow_directions(heightmap)

	# Step 2: Accumulate flow (count cells draining to each cell)
	var accumulation: PackedFloat32Array = _compute_flow_accumulation(flow_dir, map_size)

	# Store accumulation in heightmap for later use
	heightmap.river_accumulation = accumulation

	# Step 3: Find max accumulation for normalization
	var max_accum: float = 1.0
	for acc in accumulation:
		max_accum = maxf(max_accum, acc)

	# Step 4: Mark cells that exceed threshold as river cells
	var river_cells: PackedByteArray = PackedByteArray()
	river_cells.resize(total_cells)
	river_cells.fill(0)

	var accum_threshold: float = threshold * max_accum
	for i in range(total_cells):
		if accumulation[i] >= accum_threshold:
			river_cells[i] = 1

	# Step 5: Connect river cells into paths
	var paths: Array[RiverPath] = _trace_river_paths(river_cells, accumulation, flow_dir, heightmap)

	return paths


## Compute D8 flow direction for each cell (index of steepest descent neighbor)
## Returns 255 for flat/pit cells with no outflow
func _compute_flow_directions(heightmap: HeightmapStorage) -> PackedByteArray:
	var map_size: int = heightmap.size
	var flow_dir: PackedByteArray = PackedByteArray()
	flow_dir.resize(map_size * map_size)
	flow_dir.fill(255)  # 255 = no flow direction (pit or edge)

	for z in range(map_size):
		for x in range(map_size):
			var h: float = heightmap.get_cell(x, z)
			var steepest_slope: float = 0.0
			var steepest_dir: int = 255

			for dir_idx in range(8):
				var offset: Vector2i = DIR_OFFSETS[dir_idx]
				var nx: int = x + offset.x
				var nz: int = z + offset.y

				# Skip out-of-bounds
				if nx < 0 or nx >= map_size or nz < 0 or nz >= map_size:
					continue

				var nh: float = heightmap.get_cell(nx, nz)
				var drop: float = h - nh

				if drop > 0:
					var slope: float = drop / DIR_DISTANCES[dir_idx]
					if slope > steepest_slope:
						steepest_slope = slope
						steepest_dir = dir_idx

			flow_dir[z * map_size + x] = steepest_dir

	return flow_dir


## Compute flow accumulation using upstream traversal
## For each cell, counts how many cells drain into it
func _compute_flow_accumulation(flow_dir: PackedByteArray, map_size: int) -> PackedFloat32Array:
	var accumulation: PackedFloat32Array = PackedFloat32Array()
	accumulation.resize(map_size * map_size)
	accumulation.fill(1.0)  # Each cell contributes 1 to itself

	# Build in-degree count (how many cells flow into each cell)
	var in_degree: PackedInt32Array = PackedInt32Array()
	in_degree.resize(map_size * map_size)
	in_degree.fill(0)

	# Count incoming flows
	for z in range(map_size):
		for x in range(map_size):
			var dir: int = flow_dir[z * map_size + x]
			if dir < 8:  # Valid direction
				var offset: Vector2i = DIR_OFFSETS[dir]
				var nx: int = x + offset.x
				var nz: int = z + offset.y
				if nx >= 0 and nx < map_size and nz >= 0 and nz < map_size:
					in_degree[nz * map_size + nx] += 1

	# Process cells with zero in-degree first (topological sort)
	var queue: Array[Vector2i] = []
	for z in range(map_size):
		for x in range(map_size):
			if in_degree[z * map_size + x] == 0:
				queue.append(Vector2i(x, z))

	# Process queue, propagating accumulation downstream
	while queue.size() > 0:
		var cell: Vector2i = queue.pop_front()
		var idx: int = cell.y * map_size + cell.x
		var dir: int = flow_dir[idx]

		if dir < 8:  # Has valid outflow
			var offset: Vector2i = DIR_OFFSETS[dir]
			var nx: int = cell.x + offset.x
			var nz: int = cell.y + offset.y

			if nx >= 0 and nx < map_size and nz >= 0 and nz < map_size:
				var nidx: int = nz * map_size + nx
				accumulation[nidx] += accumulation[idx]
				in_degree[nidx] -= 1

				if in_degree[nidx] == 0:
					queue.append(Vector2i(nx, nz))

	return accumulation


## Trace connected river cells into paths following flow direction
func _trace_river_paths(
	river_cells: PackedByteArray,
	accumulation: PackedFloat32Array,
	flow_dir: PackedByteArray,
	heightmap: HeightmapStorage
) -> Array[RiverPath]:
	var paths: Array[RiverPath] = []
	var map_size: int = heightmap.size
	var cell_size: float = heightmap.cell_size

	# Track which cells have been visited
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(map_size * map_size)
	visited.fill(0)

	# Find river sources (river cells with no upstream river cell)
	var sources: Array[Vector2i] = []
	for z in range(map_size):
		for x in range(map_size):
			var idx: int = z * map_size + x
			if river_cells[idx] == 0:
				continue

			# Check if any neighbor flows into this cell and is also a river
			var has_upstream_river: bool = false
			for dir_idx in range(8):
				var offset: Vector2i = DIR_OFFSETS[dir_idx]
				var nx: int = x + offset.x
				var nz: int = z + offset.y

				if nx < 0 or nx >= map_size or nz < 0 or nz >= map_size:
					continue

				var nidx: int = nz * map_size + nx
				if river_cells[nidx] == 0:
					continue

				# Check if neighbor flows into current cell
				var neighbor_dir: int = flow_dir[nidx]
				if neighbor_dir < 8:
					var flow_offset: Vector2i = DIR_OFFSETS[neighbor_dir]
					if nx + flow_offset.x == x and nz + flow_offset.y == z:
						has_upstream_river = true
						break

			if not has_upstream_river:
				sources.append(Vector2i(x, z))

	# Trace path from each source downstream
	for source in sources:
		if visited[source.y * map_size + source.x] == 1:
			continue

		var path: RiverPath = RiverPath.new()
		var current: Vector2i = source

		while true:
			var idx: int = current.y * map_size + current.x

			if visited[idx] == 1:
				break

			visited[idx] = 1

			# Add point in world coordinates
			var world_pos: Vector2 = Vector2(
				current.x * cell_size,
				current.y * cell_size
			)
			var width: float = sqrt(accumulation[idx]) * width_scale * cell_size
			path.add_point(world_pos, width)

			# Follow flow direction
			var dir: int = flow_dir[idx]
			if dir >= 8:  # No outflow (pit or edge)
				break

			var offset: Vector2i = DIR_OFFSETS[dir]
			var next: Vector2i = Vector2i(current.x + offset.x, current.y + offset.y)

			# Check bounds
			if next.x < 0 or next.x >= map_size or next.y < 0 or next.y >= map_size:
				break

			# Only continue if next cell is also a river cell
			if river_cells[next.y * map_size + next.x] == 0:
				break

			current = next

		# Only keep paths with enough points
		if path.size() >= min_river_length:
			paths.append(path)

	return paths


## Convert river paths to cell coordinates (for debugging)
func paths_to_cells(paths: Array[RiverPath], cell_size: float) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for path in paths:
		var cells: PackedVector2Array = PackedVector2Array()
		for point in path.points:
			cells.append(Vector2(
				int(point.x / cell_size),
				int(point.y / cell_size)
			))
		result.append(cells)
	return result
