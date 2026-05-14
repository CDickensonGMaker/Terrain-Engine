class_name PoissonSampler
extends RefCounted
## Poisson disk sampling using Bridson's algorithm for natural point distribution.
## Used for vegetation placement to ensure minimum spacing between trees/plants.


## Samples 2D points with guaranteed minimum distance between each point.
## Uses Bridson's algorithm for O(n) performance.
## [br][br]
## [param width]: Width of the sampling area.
## [param height]: Height of the sampling area.
## [param min_distance]: Minimum distance between any two points.
## [param max_attempts]: Maximum attempts to place a point around each active point.
## [br][br]
## Returns: PackedVector2Array of sampled points.
static func sample_2d(width: float, height: float, min_distance: float, max_attempts: int = 30) -> PackedVector2Array:
	var points := PackedVector2Array()

	if width <= 0.0 or height <= 0.0 or min_distance <= 0.0:
		return points

	# Cell size ensures at most one point per cell
	var cell_size := min_distance / sqrt(2.0)
	var grid_width := ceili(width / cell_size)
	var grid_height := ceili(height / cell_size)

	# Grid stores index into points array, -1 means empty
	var grid: Array[int] = []
	grid.resize(grid_width * grid_height)
	grid.fill(-1)

	# Active list contains indices of points that may spawn new points
	var active_list: Array[int] = []

	# Start with a random point
	var first_point := Vector2(
		randf() * width,
		randf() * height
	)

	points.append(first_point)
	active_list.append(0)
	_set_grid_cell(grid, grid_width, first_point, cell_size, 0)

	# Process active list until exhausted
	while not active_list.is_empty():
		# Pick random active point
		var active_idx := randi() % active_list.size()
		var point_idx := active_list[active_idx]
		var center := points[point_idx]

		var found_valid := false

		for _attempt in max_attempts:
			# Generate random point in annulus [min_distance, 2 * min_distance]
			var angle := randf() * TAU
			var radius := min_distance + randf() * min_distance

			var candidate := Vector2(
				center.x + cos(angle) * radius,
				center.y + sin(angle) * radius
			)

			# Check bounds
			if candidate.x < 0.0 or candidate.x >= width:
				continue
			if candidate.y < 0.0 or candidate.y >= height:
				continue

			# Check distance to nearby points using grid
			if _is_valid_point(candidate, points, grid, grid_width, grid_height, cell_size, min_distance):
				var new_idx := points.size()
				points.append(candidate)
				active_list.append(new_idx)
				_set_grid_cell(grid, grid_width, candidate, cell_size, new_idx)
				found_valid = true
				break

		# Remove from active list if no valid point found
		if not found_valid:
			active_list.remove_at(active_idx)

	return points


## Sets the grid cell for a point to store its index.
static func _set_grid_cell(grid: Array[int], grid_width: int, point: Vector2, cell_size: float, point_index: int) -> void:
	var gx := int(point.x / cell_size)
	var gy := int(point.y / cell_size)
	grid[gy * grid_width + gx] = point_index


## Checks if a candidate point maintains minimum distance from all neighbors.
## Only checks the 5x5 grid neighborhood for efficiency.
static func _is_valid_point(
	candidate: Vector2,
	points: PackedVector2Array,
	grid: Array[int],
	grid_width: int,
	grid_height: int,
	cell_size: float,
	min_distance: float
) -> bool:
	var gx := int(candidate.x / cell_size)
	var gy := int(candidate.y / cell_size)

	var min_dist_sq := min_distance * min_distance

	# Check 5x5 neighborhood (2 cells in each direction)
	var x_start := maxi(0, gx - 2)
	var x_end := mini(grid_width - 1, gx + 2)
	var y_start := maxi(0, gy - 2)
	var y_end := mini(grid_height - 1, gy + 2)

	for ny in range(y_start, y_end + 1):
		for nx in range(x_start, x_end + 1):
			var idx := grid[ny * grid_width + nx]
			if idx != -1:
				var neighbor := points[idx]
				var dist_sq := candidate.distance_squared_to(neighbor)
				if dist_sq < min_dist_sq:
					return false

	return true
