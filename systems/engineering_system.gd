extends Node
## Engineering System - Terrain deformation for engineers and bulldozers
## Handles: clearing, flattening, trenches, roads, berms, foxholes

signal operation_started(op_type: OperationType, position: Vector3)
signal operation_completed(op_type: OperationType, position: Vector3)

enum OperationType {
	CLEAR_JUNGLE,      # Remove vegetation, minimal terrain change
	FLATTEN_AREA,      # Level terrain to average height (firebase pad)
	DIG_TRENCH,        # Linear depression (defensive line)
	BUILD_ROAD,        # Linear flattening with grades
	CREATE_BERM,       # Raised perimeter around area
	DIG_FOXHOLE,       # Small individual fighting position
	CRATER_BLAST,      # Explosive crater (for comparison)
	DET_CORD_LINE,     # Linear jungle clearing (LZ prep)
	DET_CORD_SQUARE,   # Square clearing for helicopter LZ
}

# Operation profiles (reduced sizes for better scale)
const OPERATION_PROFILES: Dictionary = {
	OperationType.CLEAR_JUNGLE: {
		"name": "Clear Jungle",
		"radius": 15.0,          # Reduced from 25
		"depth": 0.0,
		"flatten_amount": 0.1,
		"vegetation_clear": 1.0,
		"description": "Remove vegetation for LOS",
	},
	OperationType.FLATTEN_AREA: {
		"name": "Flatten Area",
		"radius": 25.0,          # Reduced from 40
		"depth": 0.0,
		"flatten_amount": 0.95,
		"vegetation_clear": 1.0,
		"description": "Level ground for firebase/helipad",
	},
	OperationType.DIG_TRENCH: {
		"name": "Dig Trench",
		"radius": 2.0,           # Reduced from 3
		"length": 20.0,          # Reduced from 30
		"depth": 0.025,
		"berm_height": 0.008,
		"vegetation_clear": 1.0,
		"description": "Defensive trench line",
	},
	OperationType.BUILD_ROAD: {
		"name": "Build Road",
		"radius": 4.0,           # Reduced from 6
		"length": 30.0,          # Reduced from 50
		"depth": 0.005,
		"flatten_amount": 0.9,
		"vegetation_clear": 1.0,
		"description": "Supply route with graded surface",
	},
	OperationType.CREATE_BERM: {
		"name": "Create Berm",
		"radius": 20.0,          # Reduced from 35
		"berm_width": 3.0,       # Reduced from 4
		"berm_height": 0.015,
		"trench_depth": 0.01,
		"vegetation_clear": 1.0,
		"description": "Raised perimeter for firebase",
	},
	OperationType.DIG_FOXHOLE: {
		"name": "Dig Foxhole",
		"radius": 1.5,           # Reduced from 2
		"depth": 0.012,
		"berm_height": 0.004,
		"vegetation_clear": 0.8,
		"description": "Individual fighting position",
	},
	OperationType.CRATER_BLAST: {
		"name": "Crater Blast",
		"radius": 5.0,           # Reduced from 8
		"depth": 0.04,
		"rim_height": 0.015,
		"vegetation_clear": 1.0,
		"description": "Explosive crater (demo charge)",
	},
	OperationType.DET_CORD_LINE: {
		"name": "Det Cord Line",
		"radius": 5.0,           # Reduced from 8
		"length": 40.0,          # Reduced from 60
		"depth": 0.002,
		"flatten_amount": 0.15,
		"vegetation_clear": 1.0,
		"description": "Linear jungle clearing for LZ prep",
	},
	OperationType.DET_CORD_SQUARE: {
		"name": "Det Cord Square",
		"size": 30.0,            # Reduced from 50
		"depth": 0.003,
		"flatten_amount": 0.3,
		"vegetation_clear": 1.0,
		"description": "Square LZ clearing for helicopters",
	},
}

# Reference to terrain manager
var terrain_manager: Node
var vegetation_manager: Node

# Current operation for linear operations (trench, road)
var linear_start: Vector3 = Vector3.INF
var linear_operation: OperationType = OperationType.CLEAR_JUNGLE

# Batch operation tracking for deferred chunk rebuilds
var _affected_chunks: Dictionary = {}  # Vector2i -> bool


func _ready() -> void:
	pass


## Begin a batch operation (collect affected chunks, rebuild at end)
func _begin_batch() -> void:
	_affected_chunks.clear()


## Mark a chunk as affected during batch operation
func _mark_affected_chunk(world_pos: Vector3) -> void:
	if not terrain_manager:
		return
	var chunk_size: float = terrain_manager.chunk_size
	var coord := Vector2i(
		int(floor(world_pos.x / chunk_size)),
		int(floor(world_pos.z / chunk_size))
	)
	_affected_chunks[coord] = true


## End batch operation and queue all affected chunks for deferred rebuild
func _end_batch() -> void:
	if not terrain_manager:
		return

	# Queue all affected chunks for deferred rebuild
	for coord: Vector2i in _affected_chunks:
		if terrain_manager.has_method("queue_chunk_rebuild"):
			terrain_manager.queue_chunk_rebuild(coord)

	_affected_chunks.clear()


## Set terrain manager reference
func set_terrain_manager(manager: Node) -> void:
	terrain_manager = manager


## Set vegetation manager reference
func set_vegetation_manager(veg_manager: Node) -> void:
	vegetation_manager = veg_manager


## Execute an operation at position
func execute_operation(op_type: OperationType, position: Vector3, direction: Vector3 = Vector3.FORWARD) -> void:
	if not terrain_manager:
		push_warning("EngineeringSystem: TerrainManager not set")
		return

	operation_started.emit(op_type, position)

	match op_type:
		OperationType.CLEAR_JUNGLE:
			_execute_clear_jungle(position)
		OperationType.FLATTEN_AREA:
			_execute_flatten_area(position)
		OperationType.DIG_TRENCH:
			_execute_dig_trench(position, direction)
		OperationType.BUILD_ROAD:
			_execute_build_road(position, direction)
		OperationType.CREATE_BERM:
			_execute_create_berm(position)
		OperationType.DIG_FOXHOLE:
			_execute_dig_foxhole(position)
		OperationType.CRATER_BLAST:
			_execute_crater_blast(position)
		OperationType.DET_CORD_LINE:
			_execute_det_cord_line(position, direction)
		OperationType.DET_CORD_SQUARE:
			_execute_det_cord_square(position)

	operation_completed.emit(op_type, position)


## Start a linear operation (first click sets start, second click executes)
## Uses batching to prevent frame spikes during long operations
func start_linear_operation(op_type: OperationType, position: Vector3) -> bool:
	if linear_start == Vector3.INF:
		# First click - set start point
		linear_start = position
		linear_operation = op_type
		return false  # Not complete yet
	else:
		# Second click - execute from start to position
		var direction: Vector3 = (position - linear_start).normalized()
		if direction.length() < 0.1:
			direction = Vector3.FORWARD

		# Execute along the line
		var length: float = linear_start.distance_to(position)
		var profile: Dictionary = OPERATION_PROFILES[op_type]
		var segment_length: float = profile.get("length", 30.0)

		# Begin batch operation (defer chunk rebuilds)
		_begin_batch()

		# Execute multiple segments if needed
		var current_pos: Vector3 = linear_start
		var remaining: float = length

		while remaining > 0:
			_execute_operation_internal(op_type, current_pos, direction)
			current_pos += direction * segment_length
			remaining -= segment_length

		# End batch - queue all affected chunks for deferred rebuild
		_end_batch()

		operation_completed.emit(op_type, linear_start)

		# Reset for next operation
		linear_start = Vector3.INF
		return true  # Complete


## Internal operation execution (no signals, for batch use)
func _execute_operation_internal(op_type: OperationType, position: Vector3, direction: Vector3) -> void:
	if not terrain_manager:
		return

	match op_type:
		OperationType.CLEAR_JUNGLE:
			_execute_clear_jungle(position)
		OperationType.FLATTEN_AREA:
			_execute_flatten_area(position)
		OperationType.DIG_TRENCH:
			_execute_dig_trench_batched(position, direction)
		OperationType.BUILD_ROAD:
			_execute_build_road_batched(position, direction)
		OperationType.CREATE_BERM:
			_execute_create_berm(position)
		OperationType.DIG_FOXHOLE:
			_execute_dig_foxhole(position)
		OperationType.CRATER_BLAST:
			_execute_crater_blast(position)
		OperationType.DET_CORD_LINE:
			_execute_det_cord_line_batched(position, direction)
		OperationType.DET_CORD_SQUARE:
			_execute_det_cord_square(position)


## Cancel linear operation
func cancel_linear_operation() -> void:
	linear_start = Vector3.INF


## Check if linear operation is in progress
func is_linear_in_progress() -> bool:
	return linear_start != Vector3.INF


## Get linear start position (for preview)
func get_linear_start() -> Vector3:
	return linear_start


# ============================================================================
# OPERATION IMPLEMENTATIONS
# ============================================================================

func _execute_clear_jungle(position: Vector3) -> void:
	var profile: Dictionary = OPERATION_PROFILES[OperationType.CLEAR_JUNGLE]
	var radius: float = profile.radius
	var flatten: float = profile.flatten_amount

	# Slight terrain leveling
	if flatten > 0:
		var target_height: float = _get_average_height(position, radius)
		var modifier := func(h: float, falloff: float) -> float:
			return lerp(h, target_height, flatten * falloff * 0.5)
		terrain_manager.modify_terrain(position, radius, modifier)

	# Clear vegetation
	_clear_vegetation(position, radius)
	print("[Engineering] Cleared jungle at %s (radius %.0fm)" % [position, radius])


func _execute_flatten_area(position: Vector3) -> void:
	var profile: Dictionary = OPERATION_PROFILES[OperationType.FLATTEN_AREA]
	var radius: float = profile.radius
	var flatten: float = profile.flatten_amount

	# Get target height (average of area)
	var target_height: float = _get_average_height(position, radius)

	# Flatten terrain
	var modifier := func(h: float, falloff: float) -> float:
		# Strong flattening in center, gradual blend at edges
		var blend: float = flatten * smoothstep(0.0, 0.7, falloff)
		return lerp(h, target_height, blend)

	terrain_manager.modify_terrain(position, radius, modifier)

	# Clear vegetation
	_clear_vegetation(position, radius)
	print("[Engineering] Flattened area at %s (radius %.0fm)" % [position, radius])


func _execute_dig_trench(position: Vector3, direction: Vector3) -> void:
	_execute_dig_trench_batched(position, direction)
	print("[Engineering] Dug trench at %s" % position)


## Batched trench digging (marks chunks, doesn't print)
func _execute_dig_trench_batched(position: Vector3, direction: Vector3) -> void:
	var profile: Dictionary = OPERATION_PROFILES[OperationType.DIG_TRENCH]
	var width: float = profile.radius
	var length: float = profile.length
	var depth: float = profile.depth
	var berm_height: float = profile.berm_height

	# Dig along the direction
	var steps: int = int(length / 2.0)
	var step_size: float = length / float(steps)

	for i in range(steps):
		var offset: float = (float(i) - steps / 2.0) * step_size
		var pos: Vector3 = position + direction * offset

		var modifier := func(h: float, falloff: float) -> float:
			# Trench profile: depression in center, berms on sides
			if falloff > 0.6:
				# Center of trench - dig down
				var dig_falloff: float = (falloff - 0.6) / 0.4
				return h - depth * dig_falloff
			elif falloff > 0.3:
				# Berm zone - pile dirt up
				var berm_falloff: float = (falloff - 0.3) / 0.3
				return h + berm_height * berm_falloff
			else:
				return h

		terrain_manager.modify_terrain(pos, width * 1.5, modifier)
		_mark_affected_chunk(pos)

	# Clear vegetation along trench
	for i in range(steps):
		var offset: float = (float(i) - steps / 2.0) * step_size
		var pos: Vector3 = position + direction * offset
		_clear_vegetation(pos, width * 2)


func _execute_build_road(position: Vector3, direction: Vector3) -> void:
	_execute_build_road_batched(position, direction)
	print("[Engineering] Built road at %s" % position)


## Batched road building (marks chunks, doesn't print)
func _execute_build_road_batched(position: Vector3, direction: Vector3) -> void:
	var profile: Dictionary = OPERATION_PROFILES[OperationType.BUILD_ROAD]
	var width: float = profile.radius
	var length: float = profile.length
	var cut_depth: float = profile.depth
	var flatten: float = profile.flatten_amount

	# Build road along direction
	var steps: int = int(length / 3.0)
	var step_size: float = length / float(steps)

	# First pass: calculate average height along road
	var total_height: float = 0.0
	var count: int = 0
	for i in range(steps):
		var offset: float = (float(i) - steps / 2.0) * step_size
		var pos: Vector3 = position + direction * offset
		total_height += _get_average_height(pos, width)
		count += 1
	var target_height: float = total_height / float(count) if count > 0 else 0.5

	# Second pass: flatten to target height
	for i in range(steps):
		var offset: float = (float(i) - steps / 2.0) * step_size
		var pos: Vector3 = position + direction * offset

		var modifier := func(h: float, falloff: float) -> float:
			# Flatten road surface, cut slightly into terrain
			var road_h: float = target_height - cut_depth
			var blend: float = flatten * smoothstep(0.0, 0.8, falloff)
			return lerp(h, road_h, blend)

		terrain_manager.modify_terrain(pos, width, modifier)
		_mark_affected_chunk(pos)
		_clear_vegetation(pos, width * 1.2)


func _execute_create_berm(position: Vector3) -> void:
	var profile: Dictionary = OPERATION_PROFILES[OperationType.CREATE_BERM]
	var inner_radius: float = profile.radius
	var berm_width: float = profile.berm_width
	var berm_height: float = profile.berm_height
	var trench_depth: float = profile.trench_depth

	var outer_radius: float = inner_radius + berm_width

	# Flatten interior first
	var target_height: float = _get_average_height(position, inner_radius)

	var modifier := func(h: float, falloff: float) -> float:
		# Calculate distance from center (inverse of falloff)
		var dist_ratio: float = 1.0 - falloff  # 0 at center, 1 at edge

		# Inner flat area (0 to 0.7 of inner_radius)
		if dist_ratio < 0.7:
			var flatten_blend: float = smoothstep(0.0, 0.3, falloff)
			return lerp(h, target_height - trench_depth * 0.3, flatten_blend * 0.8)

		# Transition zone (0.7 to 0.85)
		elif dist_ratio < 0.85:
			var t: float = (dist_ratio - 0.7) / 0.15
			var berm_h: float = target_height + berm_height * sin(t * PI)
			return lerp(h, berm_h, 0.9)

		# Berm ring (0.85 to 1.0)
		else:
			var t: float = (dist_ratio - 0.85) / 0.15
			var berm_h: float = target_height + berm_height * (1.0 - t * 0.5)
			return lerp(h, berm_h, 0.85 * (1.0 - t * 0.5))

	terrain_manager.modify_terrain(position, outer_radius, modifier)

	# Clear vegetation
	_clear_vegetation(position, outer_radius)
	print("[Engineering] Created berm at %s (%.0fm radius)" % [position, inner_radius])


func _execute_dig_foxhole(position: Vector3) -> void:
	var profile: Dictionary = OPERATION_PROFILES[OperationType.DIG_FOXHOLE]
	var radius: float = profile.radius
	var depth: float = profile.depth
	var berm_height: float = profile.berm_height

	var modifier := func(h: float, falloff: float) -> float:
		if falloff > 0.5:
			# Center - dig down
			var dig_blend: float = (falloff - 0.5) / 0.5
			return h - depth * dig_blend
		else:
			# Edge - small berm
			var berm_blend: float = falloff / 0.5
			return h + berm_height * berm_blend * (1.0 - berm_blend)

	terrain_manager.modify_terrain(position, radius * 1.5, modifier)
	_clear_vegetation(position, radius * 2)
	print("[Engineering] Dug foxhole at %s" % position)


func _execute_crater_blast(position: Vector3) -> void:
	var profile: Dictionary = OPERATION_PROFILES[OperationType.CRATER_BLAST]
	var radius: float = profile.radius
	var depth: float = profile.depth
	var rim_height: float = profile.rim_height

	var modifier := func(h: float, falloff: float) -> float:
		# Classic crater shape
		if falloff > 0.7:
			# Inner crater
			var crater_blend: float = pow((falloff - 0.7) / 0.3, 1.5)
			return h - depth * crater_blend
		elif falloff > 0.4:
			# Rim
			var rim_blend: float = (falloff - 0.4) / 0.3
			return h + rim_height * sin(rim_blend * PI)
		else:
			# Outer falloff
			return h

	terrain_manager.modify_terrain(position, radius * 1.3, modifier)
	_clear_vegetation(position, radius * 1.5)
	print("[Engineering] Crater blast at %s" % position)


func _execute_det_cord_line(position: Vector3, direction: Vector3) -> void:
	_execute_det_cord_line_batched(position, direction)
	print("[Engineering] Det cord line at %s" % position)


## Batched det cord line (marks chunks, doesn't print)
func _execute_det_cord_line_batched(position: Vector3, direction: Vector3) -> void:
	var profile: Dictionary = OPERATION_PROFILES[OperationType.DET_CORD_LINE]
	var width: float = profile.radius
	var length: float = profile.length
	var depth: float = profile.depth
	var flatten: float = profile.flatten_amount

	# Clear along the direction
	var steps: int = int(length / 4.0)
	var step_size: float = length / float(steps)

	# Calculate average height along line for flattening
	var total_height: float = 0.0
	var count: int = 0
	for i in range(steps):
		var offset: float = (float(i) - steps / 2.0) * step_size
		var pos: Vector3 = position + direction * offset
		total_height += _get_average_height(pos, width * 0.5)
		count += 1
	var target_height: float = total_height / float(count) if count > 0 else 0.5

	# Apply clearing with slight flattening
	for i in range(steps):
		var offset: float = (float(i) - steps / 2.0) * step_size
		var pos: Vector3 = position + direction * offset

		var modifier := func(h: float, falloff: float) -> float:
			# Slight depression and leveling from blast
			var blast_h: float = lerp(h, target_height, flatten * falloff)
			return blast_h - depth * falloff

		terrain_manager.modify_terrain(pos, width, modifier)
		_mark_affected_chunk(pos)
		_clear_vegetation(pos, width * 1.2)


func _execute_det_cord_square(position: Vector3) -> void:
	var profile: Dictionary = OPERATION_PROFILES[OperationType.DET_CORD_SQUARE]
	var size: float = profile.size
	var depth: float = profile.depth
	var flatten: float = profile.flatten_amount

	var half_size: float = size / 2.0

	# Get target height for flattening (center of LZ)
	var target_height: float = _get_average_height(position, half_size * 0.7)

	# Apply square clearing with grid of modifications
	var grid_step: float = 10.0  # Modify in 10m grid
	var grid_count: int = int(size / grid_step)

	for gz in range(grid_count):
		for gx in range(grid_count):
			var local_x: float = (gx - grid_count / 2.0 + 0.5) * grid_step
			var local_z: float = (gz - grid_count / 2.0 + 0.5) * grid_step
			var pos: Vector3 = position + Vector3(local_x, 0, local_z)

			# Calculate falloff based on distance to edge (square falloff)
			var edge_dist_x: float = half_size - abs(local_x)
			var edge_dist_z: float = half_size - abs(local_z)
			var edge_dist: float = min(edge_dist_x, edge_dist_z)
			var edge_falloff: float = clampf(edge_dist / (half_size * 0.3), 0.0, 1.0)

			var modifier := func(h: float, falloff: float) -> float:
				var blend: float = flatten * falloff * edge_falloff
				var flat_h: float = lerp(h, target_height, blend)
				return flat_h - depth * falloff * edge_falloff

			terrain_manager.modify_terrain(pos, grid_step, modifier)
			_clear_vegetation(pos, grid_step * 1.1)

	print("[Engineering] Det cord square LZ at %s (%.0fm x %.0fm)" % [position, size, size])


# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

func _get_average_height(position: Vector3, radius: float) -> float:
	if not terrain_manager:
		return 0.5

	var heightmap = terrain_manager.heightmap
	var cell_size: float = terrain_manager.cell_size

	var center_x: int = int(position.x / cell_size)
	var center_z: int = int(position.z / cell_size)
	var radius_cells: int = int(radius / cell_size)

	var total: float = 0.0
	var count: int = 0

	for z in range(center_z - radius_cells, center_z + radius_cells + 1):
		for x in range(center_x - radius_cells, center_x + radius_cells + 1):
			var dist: float = Vector2(x - center_x, z - center_z).length()
			if dist <= radius_cells:
				total += heightmap.get_cell(x, z)
				count += 1

	return total / float(count) if count > 0 else 0.5


func _clear_vegetation(position: Vector3, radius: float) -> void:
	if vegetation_manager and vegetation_manager.has_method("clear_area"):
		vegetation_manager.clear_area(position, radius, terrain_manager.chunk_size)


## Get operation name
static func get_operation_name(op_type: OperationType) -> String:
	if OPERATION_PROFILES.has(op_type):
		return OPERATION_PROFILES[op_type].name
	return "Unknown"


## Get operation description
static func get_operation_description(op_type: OperationType) -> String:
	if OPERATION_PROFILES.has(op_type):
		return OPERATION_PROFILES[op_type].description
	return ""


## Check if operation is linear (requires two clicks)
static func is_linear_operation(op_type: OperationType) -> bool:
	return (op_type == OperationType.DIG_TRENCH or
			op_type == OperationType.BUILD_ROAD or
			op_type == OperationType.DET_CORD_LINE)
