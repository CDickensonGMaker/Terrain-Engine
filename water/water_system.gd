extends Node
class_name WaterSystem
## Central manager for all water bodies in the terrain
## Handles generation, tracking, and queries for water features

## Preload dependencies (must be before signals that use these types)
const WaterBodyDataClass := preload("res://water/water_body_data.gd")
const RiverGeneratorClass := preload("res://water/river_generator.gd")
const RiverMeshClass := preload("res://water/river_mesh.gd")
const PondDetectorClass := preload("res://water/pond_detector.gd")
const WaterStaticMeshClass := preload("res://water/water_static_mesh.gd")

signal water_generated
signal water_body_added(body: Resource)  # WaterBodyData

## All water bodies indexed by ID
var water_bodies: Dictionary = {}  # id -> WaterBodyData

## Spatial index: chunk coordinate -> array of water body IDs
var water_by_chunk: Dictionary = {}  # Vector2i -> Array[int]

## Global sea level in meters (for coastal generation)
var sea_level: float = 5.0

## Water type grid for O(1) lookups
## Each byte encodes: bits 0-2 = WaterType (0-6), bits 3-7 = depth_index (0-31)
var water_map: PackedByteArray = PackedByteArray()
var water_map_size: int = 0
var water_map_cell_size: float = 2.0

## Next available water body ID
var _next_id: int = 0

## Reference to heightmap for terrain queries
var _heightmap: RefCounted = null  # HeightmapStorage

## Chunk size for spatial indexing
var _chunk_size: float = 256.0

## Container node for water meshes
var _water_container: Node3D = null


func _ready() -> void:
	_water_container = Node3D.new()
	_water_container.name = "WaterBodies"
	add_child(_water_container)


## Initialize water system with heightmap reference
func initialize(heightmap: RefCounted, chunk_size: float = 256.0) -> void:
	_heightmap = heightmap
	_chunk_size = chunk_size

	# Initialize water map to match heightmap size
	water_map_size = heightmap.size
	water_map_cell_size = heightmap.cell_size
	water_map.resize(water_map_size * water_map_size)
	water_map.fill(0)

	print("[WaterSystem] Initialized: %dx%d grid, %.1fm cells" % [
		water_map_size, water_map_size, water_map_cell_size
	])


## Generate all water bodies from heightmap
func generate_water_bodies() -> void:
	if not _heightmap:
		push_error("[WaterSystem] Cannot generate: no heightmap set")
		return

	var start_time := Time.get_ticks_msec()

	# Clear existing water bodies
	clear()

	# Phase 1: Extract rivers using existing RiverGenerator
	_generate_rivers()

	# Phase 2: Detect ponds and lakes
	_generate_static_bodies()

	# Phase 3: Generate coastal zones (to be implemented)
	# _generate_coastal()

	# Build water map for O(1) lookups
	_build_water_map()

	var elapsed := Time.get_ticks_msec() - start_time
	print("[WaterSystem] Generated %d water bodies in %dms" % [water_bodies.size(), elapsed])

	water_generated.emit()


## Generate rivers from heightmap flow
func _generate_rivers() -> void:
	var generator := RiverGeneratorClass.new()
	generator.num_rivers = 6
	generator.base_width = 8.0
	generator.width_growth = 0.2
	generator.min_river_length = 20

	var river_paths: Array = generator.extract_rivers_fast(_heightmap, generator.num_rivers)

	for i in range(river_paths.size()):
		var river_path = river_paths[i]
		if river_path.size() < 2:
			continue

		var body := WaterBodyDataClass.new()
		body.id = _next_id
		_next_id += 1

		# Classify as creek or river based on average width
		var avg_width: float = 0.0
		for w in river_path.widths:
			avg_width += w
		avg_width /= river_path.widths.size()

		body.type = WaterBodyDataClass.Type.CREEK if avg_width < 6.0 else WaterBodyDataClass.Type.RIVER
		body.path = river_path.points
		body.widths = river_path.widths
		body.depth = 1.0 if body.type == WaterBodyDataClass.Type.CREEK else 2.5

		# Calculate bounds
		var min_pt := Vector2(INF, INF)
		var max_pt := Vector2(-INF, -INF)
		for pt in body.path:
			min_pt.x = minf(min_pt.x, pt.x)
			min_pt.y = minf(min_pt.y, pt.y)
			max_pt.x = maxf(max_pt.x, pt.x)
			max_pt.y = maxf(max_pt.y, pt.y)

		# Expand bounds by max width
		var max_width: float = 0.0
		for w in body.widths:
			max_width = maxf(max_width, w)
		min_pt -= Vector2(max_width, max_width) * 0.5
		max_pt += Vector2(max_width, max_width) * 0.5

		body.bounds = Rect2(min_pt, max_pt - min_pt)

		# Calculate average flow direction
		if body.path.size() >= 2:
			body.flow_direction = (body.path[-1] - body.path[0]).normalized()

		# Calculate average elevation
		var total_elev: float = 0.0
		for pt in body.path:
			total_elev += _heightmap.sample_world(pt.x, pt.y)
		body.elevation = total_elev / body.path.size()

		# Add to registry
		_register_water_body(body)

		# Generate mesh
		_generate_river_mesh(body)


## Generate mesh for a river/creek
func _generate_river_mesh(body: Resource) -> void:
	var river_mesh := RiverMeshClass.new()
	river_mesh.build_from_path(body.path, body.widths, _heightmap)

	body.mesh = river_mesh.mesh
	body.mesh_instance = river_mesh

	river_mesh.name = "River_%d" % body.id
	_water_container.add_child(river_mesh)


## Generate ponds and lakes from terrain depressions
func _generate_static_bodies() -> void:
	var detector := PondDetectorClass.new()
	detector.min_depth = 0.8  # Minimum 0.8m deep depressions
	detector.min_area = 100.0  # At least 100 m^2
	detector.max_area = 25000.0  # Max 25000 m^2 (larger would be lakes)
	detector.minima_search_step = 8  # Sample every 8 cells for performance

	var depressions: Array = detector.detect_depressions(_heightmap)

	for depression in depressions:
		var body := WaterBodyDataClass.new()
		body.id = _next_id
		_next_id += 1

		# Classify based on area
		if depression.area < 2500.0:
			body.type = WaterBodyDataClass.Type.POND
		else:
			body.type = WaterBodyDataClass.Type.LAKE

		body.elevation = depression.pour_elevation
		body.depth = depression.water_depth
		body.bounds = depression.bounds

		# Generate polygon from cells
		body.polygon = detector.cells_to_polygon(depression)
		if body.polygon.size() < 3:
			continue  # Skip if polygon generation failed

		# Simplify polygon for performance
		body.polygon = detector.simplify_polygon(body.polygon, _heightmap.cell_size * 2.0)

		# Add to registry
		_register_water_body(body)

		# Generate mesh
		_generate_static_mesh(body, depression.cells)

	print("[WaterSystem] Generated %d ponds/lakes" % depressions.size())


## Generate mesh for a pond/lake
func _generate_static_mesh(body: Resource, cells: Array) -> void:
	var static_mesh := WaterStaticMeshClass.new()

	# Use cells-based mesh for more accurate shore fading
	var typed_cells: Array[Vector2i] = []
	for cell in cells:
		typed_cells.append(cell)

	static_mesh.build_from_cells(typed_cells, body.elevation, _heightmap)

	body.mesh = static_mesh.mesh
	body.mesh_instance = static_mesh

	var type_name: String = "Pond" if body.type == WaterBodyDataClass.Type.POND else "Lake"
	static_mesh.name = "%s_%d" % [type_name, body.id]
	_water_container.add_child(static_mesh)


## Register a water body and update spatial index
func _register_water_body(body: Resource) -> void:
	water_bodies[body.id] = body

	# Update chunk spatial index
	var min_chunk := Vector2i(
		int(floor(body.bounds.position.x / _chunk_size)),
		int(floor(body.bounds.position.y / _chunk_size))
	)
	var max_chunk := Vector2i(
		int(floor(body.bounds.end.x / _chunk_size)),
		int(floor(body.bounds.end.y / _chunk_size))
	)

	for cz in range(min_chunk.y, max_chunk.y + 1):
		for cx in range(min_chunk.x, max_chunk.x + 1):
			var coord := Vector2i(cx, cz)
			if not water_by_chunk.has(coord):
				water_by_chunk[coord] = []
			water_by_chunk[coord].append(body.id)

	water_body_added.emit(body)


## Build water map grid for O(1) lookups
func _build_water_map() -> void:
	water_map.fill(0)

	for body in water_bodies.values():
		_rasterize_water_body(body)

	# Count water cells
	var water_cells: int = 0
	for byte in water_map:
		if byte > 0:
			water_cells += 1

	var total_cells: int = water_map_size * water_map_size
	var percent: float = 100.0 * water_cells / total_cells
	print("[WaterSystem] Water map: %d/%d cells (%.1f%%)" % [water_cells, total_cells, percent])


## Rasterize a water body into the water map
func _rasterize_water_body(body: Resource) -> void:
	var type_bits: int = body.type  # 0-6 fits in 3 bits
	var depth_index: int = clampi(int(body.depth * 2), 0, 31)  # 0-31 (0.5m increments up to 15.5m)
	var byte_value: int = type_bits | (depth_index << 3)

	if body.is_flowing():
		# Rasterize river/creek path
		var path: PackedVector2Array = body.path
		var widths: PackedFloat32Array = body.widths
		for i in range(path.size() - 1):
			var start: Vector2 = path[i]
			var end_pt: Vector2 = path[i + 1]
			var width: float = (widths[i] + widths[i + 1]) * 0.5
			_rasterize_thick_line(start, end_pt, width, byte_value)
	else:
		# Rasterize polygon (for ponds/lakes/coastal)
		var polygon: PackedVector2Array = body.polygon
		_rasterize_polygon(polygon, byte_value)


## Rasterize a thick line into water map
func _rasterize_thick_line(start: Vector2, end: Vector2, width: float, byte_value: int) -> void:
	var half_width: float = width * 0.5
	var dir := (end - start).normalized()
	var length := start.distance_to(end)
	var perp := Vector2(-dir.y, dir.x)

	# Step along line
	var step_size: float = water_map_cell_size * 0.5
	var steps: int = int(ceil(length / step_size))

	for s in range(steps + 1):
		var t: float = float(s) / float(steps) if steps > 0 else 0.0
		var center := start.lerp(end, t)

		# Fill perpendicular strip
		var width_steps: int = int(ceil(half_width / step_size))
		for w in range(-width_steps, width_steps + 1):
			var offset := perp * (w * step_size)
			var point := center + offset

			var cx: int = int(floor(point.x / water_map_cell_size))
			var cz: int = int(floor(point.y / water_map_cell_size))

			if cx >= 0 and cx < water_map_size and cz >= 0 and cz < water_map_size:
				water_map[cz * water_map_size + cx] = byte_value


## Rasterize a polygon into water map (scanline fill)
func _rasterize_polygon(polygon: PackedVector2Array, byte_value: int) -> void:
	if polygon.size() < 3:
		return

	# Find bounding box
	var min_pt := Vector2(INF, INF)
	var max_pt := Vector2(-INF, -INF)
	for pt in polygon:
		min_pt.x = minf(min_pt.x, pt.x)
		min_pt.y = minf(min_pt.y, pt.y)
		max_pt.x = maxf(max_pt.x, pt.x)
		max_pt.y = maxf(max_pt.y, pt.y)

	# Convert to cell coordinates
	var min_cell := Vector2i(
		int(floor(min_pt.x / water_map_cell_size)),
		int(floor(min_pt.y / water_map_cell_size))
	)
	var max_cell := Vector2i(
		int(ceil(max_pt.x / water_map_cell_size)),
		int(ceil(max_pt.y / water_map_cell_size))
	)

	# Scanline fill
	for cz in range(max(0, min_cell.y), min(water_map_size, max_cell.y + 1)):
		for cx in range(max(0, min_cell.x), min(water_map_size, max_cell.x + 1)):
			var world_x: float = (cx + 0.5) * water_map_cell_size
			var world_z: float = (cz + 0.5) * water_map_cell_size

			if _point_in_polygon(Vector2(world_x, world_z), polygon):
				water_map[cz * water_map_size + cx] = byte_value


## Point-in-polygon test
func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside := false
	var j := polygon.size() - 1

	for i in range(polygon.size()):
		var pi := polygon[i]
		var pj := polygon[j]

		if ((pi.y > point.y) != (pj.y > point.y)) and \
		   (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside

		j = i

	return inside


## Clear all water bodies
func clear() -> void:
	# Remove mesh instances
	for child in _water_container.get_children():
		child.queue_free()

	water_bodies.clear()
	water_by_chunk.clear()
	water_map.fill(0)
	_next_id = 0


# =============================================================================
# PUBLIC QUERY API
# =============================================================================

## Check if a world position is in water
func is_water(world_x: float, world_z: float) -> bool:
	var cx: int = int(floor(world_x / water_map_cell_size))
	var cz: int = int(floor(world_z / water_map_cell_size))

	if cx < 0 or cx >= water_map_size or cz < 0 or cz >= water_map_size:
		return false

	return water_map[cz * water_map_size + cx] > 0


## Get water type at a world position (returns WaterBodyData.Type)
func get_water_type(world_x: float, world_z: float) -> int:
	var cx: int = int(floor(world_x / water_map_cell_size))
	var cz: int = int(floor(world_z / water_map_cell_size))

	if cx < 0 or cx >= water_map_size or cz < 0 or cz >= water_map_size:
		return WaterBodyDataClass.Type.NONE

	var byte_value: int = water_map[cz * water_map_size + cx]
	return byte_value & 0x07  # Bottom 3 bits


## Get water depth at a world position (meters, 0 if not in water)
func get_water_depth(world_x: float, world_z: float) -> float:
	var cx: int = int(floor(world_x / water_map_cell_size))
	var cz: int = int(floor(world_z / water_map_cell_size))

	if cx < 0 or cx >= water_map_size or cz < 0 or cz >= water_map_size:
		return 0.0

	var byte_value: int = water_map[cz * water_map_size + cx]
	if byte_value == 0:
		return 0.0

	var depth_index: int = (byte_value >> 3) & 0x1F  # Bits 3-7
	return depth_index * 0.5  # 0.5m per index unit


## Get water body at a world position (or null)
func get_water_at(world_pos: Vector3) -> Resource:
	var chunk_coord := Vector2i(
		int(floor(world_pos.x / _chunk_size)),
		int(floor(world_pos.z / _chunk_size))
	)

	if not water_by_chunk.has(chunk_coord):
		return null

	for body_id in water_by_chunk[chunk_coord]:
		var body: Resource = water_bodies[body_id]
		if body.contains_point(world_pos.x, world_pos.z):
			return body

	return null


## Get flow direction at a world position (for boats, debris)
func get_flow_at(world_x: float, world_z: float) -> Vector2:
	var body := get_water_at(Vector3(world_x, 0, world_z))
	if body:
		return body.get_flow_at(world_x, world_z)
	return Vector2.ZERO


## Get all water bodies in a chunk
func get_water_in_chunk(chunk_coord: Vector2i) -> Array[Resource]:
	var result: Array[Resource] = []

	if water_by_chunk.has(chunk_coord):
		for body_id in water_by_chunk[chunk_coord]:
			result.append(water_bodies[body_id])

	return result


## Get water bodies within a radius of a point
func get_water_near(world_pos: Vector3, radius: float) -> Array[Resource]:
	var result: Array[Resource] = []
	var search_rect := Rect2(
		world_pos.x - radius,
		world_pos.z - radius,
		radius * 2,
		radius * 2
	)

	for body in water_bodies.values():
		if body.bounds.intersects(search_rect):
			result.append(body)

	return result


## Debug: print water system stats
func print_stats() -> void:
	print("[WaterSystem] === Water System Stats ===")
	print("  Total bodies: %d" % water_bodies.size())

	var by_type: Dictionary = {}
	for body in water_bodies.values():
		var type_name: String = WaterBodyDataClass.type_name(body.type)
		by_type[type_name] = by_type.get(type_name, 0) + 1

	for type_name in by_type:
		print("  - %s: %d" % [type_name, by_type[type_name]])

	var water_cells: int = 0
	for byte in water_map:
		if byte > 0:
			water_cells += 1

	print("  Water cells: %d (%.1f%%)" % [
		water_cells,
		100.0 * water_cells / (water_map_size * water_map_size)
	])
