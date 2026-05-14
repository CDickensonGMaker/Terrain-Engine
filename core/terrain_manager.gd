extends Node3D
class_name TerrainManager
## Manages terrain chunks for large maps (3km x 3km)
## Streams chunks around camera for performance

const HeightmapStorageClass := preload("res://core/heightmap_storage.gd")
const TerrainChunkClass := preload("res://core/terrain_chunk.gd")
const RiverGeneratorClass := preload("res://water/river_generator.gd")
const RiverMeshClass := preload("res://water/river_mesh.gd")

signal terrain_ready
signal chunk_loaded(coord: Vector2i, is_playable: bool)
signal chunk_unloaded(coord: Vector2i)
signal generation_progress(stage: String, percent: float)

# Map configuration
@export var map_size: float = 3000.0  # Playable map size in meters
@export var chunk_size: float = 256.0  # Chunk size in meters
@export var cell_size: float = 2.0    # Height sample resolution
@export var height_scale: float = 280.0  # Max terrain height

# Streaming configuration
@export var load_distance: int = 3     # Chunks to load around camera
@export var unload_distance: int = 5   # Chunks to unload beyond this

# River configuration
@export var rivers_enabled: bool = true
@export var river_count: int = 6  # Number of rivers to generate

# Terrain data
var heightmap: RefCounted  # HeightmapStorage
var chunks: Dictionary = {}  # Vector2i -> TerrainChunk
var loading_chunks: Array[Vector2i] = []

# State
var is_ready: bool = false
var chunks_per_side: int  # Chunks per side
var chunk_cells: int

# Reference
var camera: Camera3D
var terrain_generator: Node  # TerrainEngine autoload
var vegetation_manager: Node  # VegetationManager - set externally for rice paddy coloring

# Rivers
var river_paths: Array = []
var river_meshes: Array = []
var near_water_mask: PackedByteArray  # for rice paddy clustering near rivers

# Deferred rebuild queue for async operations
var _rebuild_queue: Array[Vector2i] = []
var _rebuild_accumulator: float = 0.0
const REBUILD_BUDGET_MS := 8.0  # Max rebuild time per frame


func _ready() -> void:
	# Calculate grid dimensions
	chunks_per_side = int(ceil(map_size / chunk_size))
	chunk_cells = int(chunk_size / cell_size) + 1  # +1 for edge overlap

	print("[TerrainManager] Map: %.0fm (%dx%d chunks)" % [
		map_size, chunks_per_side, chunks_per_side
	])

	# Get terrain generator
	terrain_generator = get_node_or_null("/root/TerrainEngine")

	# Create heightmap storage
	heightmap = HeightmapStorageClass.new(map_size, cell_size)


func _process(delta: float) -> void:
	if not is_ready:
		return

	# Process deferred chunk rebuilds (prevents frame spikes)
	_process_rebuild_queue()

	# Stream chunks around camera
	if camera:
		_stream_chunks_around_camera()


## Process queued chunk rebuilds with time budget
func _process_rebuild_queue() -> void:
	if _rebuild_queue.is_empty():
		return

	var start_time := Time.get_ticks_msec()
	while not _rebuild_queue.is_empty():
		# Check time budget
		if Time.get_ticks_msec() - start_time > REBUILD_BUDGET_MS:
			break  # Continue next frame

		var coord: Vector2i = _rebuild_queue.pop_front()
		_rebuild_chunk_immediate(coord)


## Queue a chunk for deferred rebuild (prevents frame spikes)
func queue_chunk_rebuild(coord: Vector2i) -> void:
	if coord not in _rebuild_queue:
		_rebuild_queue.append(coord)


## Immediately rebuild a single chunk
func _rebuild_chunk_immediate(coord: Vector2i) -> void:
	if not chunks.has(coord):
		return

	# Clear vegetation visuals but preserve placement cache
	if vegetation_manager and vegetation_manager.has_method("clear_chunk_visuals"):
		vegetation_manager.clear_chunk_visuals(coord)

	# Unload chunk without touching vegetation (we already handled it)
	var chunk: Node3D = chunks[coord]
	chunk.unload()
	chunk.queue_free()
	chunks.erase(coord)

	# Reload chunk - generate_for_chunk will re-materialize from cache
	_load_chunk(coord)


## Initialize terrain generation (async)
func generate_terrain(seed_value: int = -1) -> void:
	is_ready = false
	generation_progress.emit("Initializing", 0.0)

	if terrain_generator:
		# Configure generator for large map
		terrain_generator.terrain_size = heightmap.size
		terrain_generator.cell_size = cell_size
		terrain_generator.height_scale = height_scale

		# Generate heightmap
		generation_progress.emit("Generating heightmap", 0.1)
		terrain_generator.generate(seed_value)

		# Copy data to storage
		heightmap.data = terrain_generator.heightmap_data.duplicate()
		heightmap.height_scale = height_scale

		generation_progress.emit("Heightmap complete", 0.5)
	else:
		# Fallback: generate simple noise terrain
		_generate_fallback_terrain()

	heightmap.print_stats()

	# Extract rivers and carve riverbeds BEFORE building chunks (optional - slow on large maps)
	if rivers_enabled:
		generation_progress.emit("Extracting rivers", 0.55)
		_extract_and_carve_rivers()
		_build_water_proximity_mask()

	# Load initial chunks
	generation_progress.emit("Loading chunks", 0.6)
	_load_initial_chunks()

	# Build river water surface meshes
	if rivers_enabled:
		generation_progress.emit("Building water", 0.9)
		_build_river_meshes()

	is_ready = true
	generation_progress.emit("Complete", 1.0)
	terrain_ready.emit()


## Fallback terrain generation if TerrainEngine not available
func _generate_fallback_terrain() -> void:
	print("[TerrainManager] Using fallback terrain generation")

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	noise.frequency = 0.002
	noise.seed = randi()

	heightmap.data.resize(heightmap.size * heightmap.size)

	for z in range(heightmap.size):
		for x in range(heightmap.size):
			var h: float = noise.get_noise_2d(x, z)
			h = (h + 1.0) * 0.5  # Normalize to 0-1
			heightmap.data[z * heightmap.size + x] = h


## Load chunks around center of map initially
func _load_initial_chunks() -> void:
	# Load ALL chunks
	for z in range(chunks_per_side):
		for x in range(chunks_per_side):
			var coord := Vector2i(x, z)
			if not chunks.has(coord):
				_load_chunk(coord)


## Stream chunks based on camera position
func _stream_chunks_around_camera() -> void:
	var camera_chunk := _world_to_chunk(camera.global_position)

	# Load nearby chunks
	_load_chunks_around(camera_chunk, load_distance)

	# Unload distant chunks
	_unload_distant_chunks(camera_chunk, unload_distance)


## Load all chunks within radius of center
func _load_chunks_around(center: Vector2i, radius: int) -> void:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var coord := center + Vector2i(dx, dz)

			# Skip if out of bounds
			if coord.x < 0 or coord.x >= chunks_per_side:
				continue
			if coord.y < 0 or coord.y >= chunks_per_side:
				continue

			# Skip if already loaded or loading
			if chunks.has(coord) or coord in loading_chunks:
				continue

			_load_chunk(coord)


## Load a single chunk
func _load_chunk(coord: Vector2i) -> void:
	loading_chunks.append(coord)

	# Extract heightmap region for this chunk
	var start_x: int = coord.x * int(chunk_size / cell_size)
	var start_z: int = coord.y * int(chunk_size / cell_size)
	var region: PackedFloat32Array = heightmap.extract_region(start_x, start_z, chunk_cells)

	# Create chunk
	var chunk := TerrainChunkClass.new(coord, chunk_size, cell_size)
	chunk.name = "Chunk_%d_%d" % [coord.x, coord.y]
	add_child(chunk)

	# Classify vegetation BEFORE mesh build so the mesh can color rice paddies
	var veg_bytes := PackedByteArray()
	var bundles_per_chunk: int = 0
	if vegetation_manager:
		vegetation_manager.generate_for_chunk(coord, heightmap, chunk_size)
		if vegetation_manager._chunk_terrain.has(coord):
			veg_bytes = vegetation_manager._chunk_terrain[coord]
			bundles_per_chunk = vegetation_manager._bundles_per_chunk

	# Build mesh with vegetation bytes for rice paddy coloring
	chunk.build_mesh(region, height_scale, veg_bytes, bundles_per_chunk)

	# Create collision for raycasting
	chunk.create_raycast_collision()

	# Bake navigation (optional - can be deferred)
	# chunk.bake_navigation()

	# Register
	chunks[coord] = chunk
	loading_chunks.erase(coord)

	# Emit with playable flag
	var is_playable: bool = is_playable_chunk(coord)
	chunk_loaded.emit(coord, is_playable)


## Unload chunks beyond distance from center
## Uses Chebyshev distance (max of dx, dy) to match the square loading pattern
func _unload_distant_chunks(center: Vector2i, max_distance: int) -> void:
	var to_unload: Array[Vector2i] = []

	for coord in chunks:
		# Use Chebyshev distance (max of absolute differences) to match square load pattern
		var dist := maxi(absi(coord.x - center.x), absi(coord.y - center.y))
		if dist > max_distance:
			to_unload.append(coord)

	for coord in to_unload:
		_unload_chunk(coord)


## Unload a single chunk
func _unload_chunk(coord: Vector2i) -> void:
	if not chunks.has(coord):
		return

	var chunk: Node3D = chunks[coord]  # TerrainChunk
	chunk.unload()
	chunk.queue_free()
	chunks.erase(coord)

	# Full clear vegetation when streaming out (not rebuilding)
	if vegetation_manager and vegetation_manager.has_method("clear_chunk_full"):
		vegetation_manager.clear_chunk_full(coord)

	chunk_unloaded.emit(coord)


## Convert world position to chunk coordinates
func _world_to_chunk(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(world_pos.x / chunk_size)),
		int(floor(world_pos.z / chunk_size))
	)


## Get terrain height at world position (O(1) bilinear interpolation)
## This is the primary API for unit movement - does NOT use physics
func get_height_at(world_pos: Vector3) -> float:
	return heightmap.sample_world(world_pos.x, world_pos.z)


## Get terrain normal at world position
func get_normal_at(world_pos: Vector3) -> Vector3:
	return heightmap.get_normal_world(world_pos.x, world_pos.z)


## Modify terrain in a region (for damage/clearing)
func modify_terrain(center: Vector3, radius_meters: float, modifier: Callable) -> void:
	var cell_center: Vector2i = heightmap.world_to_cell(center.x, center.z)
	var cell_radius: int = int(ceil(radius_meters / cell_size))

	var affected: Rect2i = heightmap.modify_region(cell_center, cell_radius, modifier)

	# Rebuild affected chunks
	_rebuild_chunks_in_region(affected)


## Rebuild chunks that overlap with a cell region
func _rebuild_chunks_in_region(cell_region: Rect2i) -> void:
	var cells_per_chunk: int = int(chunk_size / cell_size)

	var min_chunk := Vector2i(
		cell_region.position.x / cells_per_chunk,
		cell_region.position.y / cells_per_chunk
	)
	var max_chunk := Vector2i(
		(cell_region.position.x + cell_region.size.x) / cells_per_chunk,
		(cell_region.position.y + cell_region.size.y) / cells_per_chunk
	)

	for cz in range(min_chunk.y, max_chunk.y + 1):
		for cx in range(min_chunk.x, max_chunk.x + 1):
			var coord := Vector2i(cx, cz)
			if chunks.has(coord):
				# Use _rebuild_chunk_immediate which preserves the vegetation cache.
				# _unload_chunk calls vegetation_manager.clear_chunk_full() which wipes
				# _chunk_terrain and _chunk_placements, causing trees to respawn in
				# their original positions after every explosion.
				_rebuild_chunk_immediate(coord)


## Set camera for streaming
func set_camera(cam: Camera3D) -> void:
	camera = cam


## Check if chunk coordinates are within playable area (all chunks are playable now)
func is_playable_chunk(coord: Vector2i) -> bool:
	return coord.x >= 0 and coord.x < chunks_per_side and coord.y >= 0 and coord.y < chunks_per_side


## Get playable world bounds (for camera clamping)
func get_playable_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(map_size, map_size))


## Get all loaded chunk coordinates
func get_loaded_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for coord in chunks:
		result.append(coord)
	return result


## Get total loaded chunk count
func get_loaded_chunk_count() -> int:
	return chunks.size()


## Get chunk at coordinates (may be null if not loaded)
func get_chunk(coord: Vector2i) -> Node3D:  # TerrainChunk
	return chunks.get(coord)


## Force load all chunks (for small maps or loading screens)
func load_all_chunks() -> void:
	for z in range(chunks_per_side):
		for x in range(chunks_per_side):
			var coord := Vector2i(x, z)
			if not chunks.has(coord):
				_load_chunk(coord)

	print("[TerrainManager] Loaded all %d chunks" % chunks.size())


# ============================================================================
# RIVER SYSTEM
# ============================================================================

## Extract rivers from heightmap and carve riverbeds
func _extract_and_carve_rivers() -> void:
	# Free prior river meshes
	for rm in river_meshes:
		if is_instance_valid(rm):
			rm.queue_free()
	river_meshes.clear()
	river_paths.clear()

	var gen := RiverGeneratorClass.new()
	gen.min_river_length = 50
	gen.base_width = 6.0
	gen.width_growth = 0.08
	# Use fast gradient descent instead of slow D8 flow accumulation
	var paths: Array = gen.extract_rivers_fast(heightmap, river_count)
	river_paths = paths

	# Smooth paths (D8 discretization is jaggy)
	for path in river_paths:
		_smooth_river_path(path)

	# Carve riverbeds into heightmap
	for path in river_paths:
		_carve_riverbed(path)

	print("[TerrainManager] Extracted %d river paths" % river_paths.size())


## Smooth a river path with windowed averaging
func _smooth_river_path(path) -> void:
	if path.points.size() < 5:
		return
	var smoothed := PackedVector2Array()
	smoothed.resize(path.points.size())
	smoothed[0] = path.points[0]
	smoothed[path.points.size() - 1] = path.points[path.points.size() - 1]
	for i in range(1, path.points.size() - 1):
		var prev: Vector2 = path.points[i - 1]
		var curr: Vector2 = path.points[i]
		var next_pt: Vector2 = path.points[i + 1]
		smoothed[i] = (prev + curr * 2.0 + next_pt) * 0.25
	path.points = smoothed


## Carve riverbed into heightmap (must happen BEFORE chunk mesh generation)
func _carve_riverbed(path) -> void:
	var carve_depth_meters: float = 1.8
	var carve_radius: int = 2  # cells perpendicular
	for i in path.points.size():
		var p: Vector2 = path.points[i]
		var center_cell: Vector2i = heightmap.world_to_cell(p.x, p.y)
		for dz in range(-carve_radius, carve_radius + 1):
			for dx in range(-carve_radius, carve_radius + 1):
				var nx: int = center_cell.x + dx
				var nz: int = center_cell.y + dz
				if nx < 0 or nx >= heightmap.size:
					continue
				if nz < 0 or nz >= heightmap.size:
					continue
				var dist: float = sqrt(float(dx * dx + dz * dz))
				if dist > float(carve_radius):
					continue
				var falloff: float = 1.0 - (dist / float(carve_radius))
				var current: float = heightmap.get_cell(nx, nz)
				var depth_normalized: float = (carve_depth_meters * falloff) / height_scale
				heightmap.set_cell(nx, nz, maxf(0.0, current - depth_normalized))


## Build river water surface meshes after terrain chunks are loaded
func _build_river_meshes() -> void:
	for path in river_paths:
		if path.size() < 2:
			continue
		var rm = RiverMeshClass.new()
		rm.name = "River_%d" % river_meshes.size()
		add_child(rm)
		rm.build_from_path(path.points, path.widths, heightmap)
		river_meshes.append(rm)
	print("[TerrainManager] Built %d river meshes" % river_meshes.size())


## Build proximity mask for rice paddy clustering near rivers
func _build_water_proximity_mask() -> void:
	var mask_size: int = heightmap.size
	near_water_mask = PackedByteArray()
	near_water_mask.resize(mask_size * mask_size)
	near_water_mask.fill(0)

	var influence_radius: int = 8  # cells (~16m at 2m cell size)
	var r_sq: int = influence_radius * influence_radius
	for path in river_paths:
		for p: Vector2 in path.points:
			var center_cell: Vector2i = heightmap.world_to_cell(p.x, p.y)
			for dz in range(-influence_radius, influence_radius + 1):
				for dx in range(-influence_radius, influence_radius + 1):
					var nx: int = center_cell.x + dx
					var nz: int = center_cell.y + dz
					if nx < 0 or nx >= mask_size:
						continue
					if nz < 0 or nz >= mask_size:
						continue
					if dx * dx + dz * dz > r_sq:
						continue
					near_water_mask[nz * mask_size + nx] = 1


## Check if a world position is near water (for rice paddy clustering)
func is_near_water(world_x: float, world_z: float) -> bool:
	if near_water_mask.is_empty():
		return false
	var cell: Vector2i = heightmap.world_to_cell(world_x, world_z)
	if cell.x < 0 or cell.x >= heightmap.size:
		return false
	if cell.y < 0 or cell.y >= heightmap.size:
		return false
	return near_water_mask[cell.y * heightmap.size + cell.x] == 1
