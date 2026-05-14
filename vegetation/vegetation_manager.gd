class_name VegetationManager
extends Node3D
## Grid-based vegetation with terrain types and density zones.
## Uses 2x2 cell bundles for efficient clearing and LOS.

## Terrain/Vegetation types
enum TerrainType {
	CLEAR,          # No vegetation (roads, clearings)
	RICE_PADDY,     # Flat water/crops - no trees
	GRASSLAND,      # Low grass, very sparse trees
	LIGHT_JUNGLE,   # Sparse trees, good visibility
	MEDIUM_JUNGLE,  # Moderate density
	HEAVY_JUNGLE,   # Dense canopy, blocks LOS
}

## Bundle size (2x2 cells treated as one unit)
const BUNDLE_SIZE := 2

## Individual cell size in meters
@export var cell_size: float = 4.0

## Maximum slope for vegetation
@export var max_slope_degrees: float = 50.0

## Use external models (disabled - too heavy for Intel UHD)
@export var use_external_models: bool = false

# Bundle size in meters
var bundle_meters: float:
	get: return cell_size * BUNDLE_SIZE

# Terrain type properties: [tree_chance, tree_count_min, tree_count_max, blocks_los, move_speed]
# move_speed: 1.0 = full speed, 0.5 = half speed, etc.
# RESTORED DENSITY - billboards provide thick jungle illusion at distance
const TYPE_PROPS := {
	TerrainType.CLEAR:         [0.00, 0, 0, false, 1.0],
	TerrainType.RICE_PADDY:    [0.00, 0, 0, false, 0.4],   # Water/mud - very slow
	TerrainType.GRASSLAND:     [0.08, 0, 1, false, 0.95],  # Very sparse
	TerrainType.LIGHT_JUNGLE:  [0.30, 1, 2, false, 0.8],   # Sparse
	TerrainType.MEDIUM_JUNGLE: [0.55, 1, 3, true,  0.5],   # Moderate density
	TerrainType.HEAVY_JUNGLE:  [0.80, 2, 4, true,  0.3],   # Dense canopy
}

# Loaded vegetation meshes
var _meshes: Array[Mesh] = []  # Tree meshes
var _grass_mesh: Mesh  # Grass patch mesh
var _fallback_mesh: ArrayMesh

# Grid data per chunk - stores TerrainType for each bundle
# Dictionary[Vector2i, PackedByteArray]
var _chunk_terrain: Dictionary = {}

# MultiMesh instances per chunk
var _chunk_instances: Dictionary = {}  # Trees
var _chunk_grass: Dictionary = {}  # Grass patches

# Bundles per chunk side
var _bundles_per_chunk: int

# Slope threshold
var _min_slope_dot: float

# Camera reference for frustum culling
var _camera: Camera3D
var _chunk_size: float = 256.0

# TerrainManager reference for water proximity checks
var _terrain_manager: Node = null

# Frustum culling accumulator (don't check every frame)
var _frustum_accumulator: float = 0.0
const FRUSTUM_UPDATE_INTERVAL := 0.1  # 10Hz


func _ready() -> void:
	_min_slope_dot = cos(deg_to_rad(max_slope_degrees))
	_load_vegetation_meshes()


func _process(delta: float) -> void:
	if not _camera:
		return

	_frustum_accumulator += delta
	if _frustum_accumulator < FRUSTUM_UPDATE_INTERVAL:
		return
	_frustum_accumulator = 0.0

	_update_frustum_culling()


## Set camera for frustum culling and LOD
func set_camera(cam: Camera3D) -> void:
	_camera = cam


## Set chunk size for culling calculations
func set_chunk_size(size: float) -> void:
	_chunk_size = size


## Update visibility based on frustum and distance
func _update_frustum_culling() -> void:
	var frustum := _camera.get_frustum()
	var cam_pos := _camera.global_position

	for coord: Vector2i in _chunk_instances:
		# Calculate chunk AABB
		var aabb := AABB(
			Vector3(coord.x * _chunk_size, -50, coord.y * _chunk_size),
			Vector3(_chunk_size, 400.0, _chunk_size)
		)

		# Check if in frustum
		var in_frustum := _aabb_in_frustum(aabb, frustum)

		# Distance-based grass culling (grass only visible within 100m)
		var chunk_center := Vector3(
			coord.x * _chunk_size + _chunk_size * 0.5,
			0,
			coord.y * _chunk_size + _chunk_size * 0.5
		)
		var dist := cam_pos.distance_to(chunk_center)
		var grass_visible := in_frustum and dist < 100.0

		# Apply visibility
		if _chunk_instances.has(coord):
			_chunk_instances[coord].visible = in_frustum
		if _chunk_grass.has(coord):
			_chunk_grass[coord].visible = grass_visible


## Test if AABB is inside or intersects frustum
func _aabb_in_frustum(aabb: AABB, frustum: Array[Plane]) -> bool:
	for plane: Plane in frustum:
		# Get the positive vertex (furthest in plane normal direction)
		var positive := aabb.position
		if plane.normal.x >= 0:
			positive.x += aabb.size.x
		if plane.normal.y >= 0:
			positive.y += aabb.size.y
		if plane.normal.z >= 0:
			positive.z += aabb.size.z

		# If positive vertex is behind plane, AABB is outside frustum
		if plane.distance_to(positive) < 0:
			return false

	return true


## Load vegetation meshes
func _load_vegetation_meshes() -> void:
	_meshes.clear()

	# Try loading palm tree first as primary tree mesh
	if use_external_models:
		var palm := _load_first_mesh("res://vegetation/models/palm_tree.blend")
		if palm:
			_meshes.append(palm)
			print("[VegetationManager] Using palm tree as primary mesh")

	# Fallback to procedural tree if no external tree loaded
	if _meshes.is_empty():
		_fallback_mesh = _create_procedural_tree()
		_meshes.append(_fallback_mesh)
		print("[VegetationManager] Using procedural tree as primary mesh")

	# Try loading grass patch
	_grass_mesh = _load_first_mesh("res://vegetation/models/grass/grass_patch.fbx")
	if not _grass_mesh:
		_grass_mesh = _create_procedural_grass()
		print("[VegetationManager] Using procedural grass")
	else:
		print("[VegetationManager] Loaded grass patch mesh")

	print("[VegetationManager] Loaded %d tree mesh(es)" % _meshes.size())


func _load_first_mesh(path: String) -> Mesh:
	if not ResourceLoader.exists(path):
		print("[VegetationManager] Path not found: %s" % path)
		return null
	var scene := load(path) as PackedScene
	if not scene:
		print("[VegetationManager] Failed to load as PackedScene: %s" % path)
		return null
	var root := scene.instantiate() as Node3D
	var mesh := _find_first_mesh(root)
	if mesh:
		var aabb := mesh.get_aabb()
		# Skip flat meshes (billboards/planes) - check minimum dimension
		var min_dim := minf(minf(aabb.size.x, aabb.size.y), aabb.size.z)
		if min_dim < 0.001:
			print("[VegetationManager] Skipping flat mesh: %s (min_dim=%.6f)" % [path.get_file(), min_dim])
			root.queue_free()
			return null
		print("[VegetationManager] Loaded mesh from %s: AABB=%s, surfaces=%d" % [
			path.get_file(), aabb.size, mesh.get_surface_count()
		])
	else:
		print("[VegetationManager] No mesh found in: %s" % path)
	root.queue_free()
	return mesh


func _find_first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	for child in node.get_children():
		var mesh := _find_first_mesh(child)
		if mesh:
			return mesh
	return null


## Generate vegetation for a chunk
func generate_for_chunk(chunk_coord: Vector2i, heightmap: Object, chunk_size: float) -> void:
	clear_chunk(chunk_coord)

	if _meshes.is_empty():
		return

	_bundles_per_chunk = int(chunk_size / bundle_meters)

	var world_offset := Vector3(
		chunk_coord.x * chunk_size,
		0.0,
		chunk_coord.y * chunk_size
	)

	# Create terrain type grid for this chunk
	var terrain := PackedByteArray()
	terrain.resize(_bundles_per_chunk * _bundles_per_chunk)

	# RNG seeded by chunk coord for consistency
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(chunk_coord)

	# Assign terrain types based on height/slope/noise
	for bz in _bundles_per_chunk:
		for bx in _bundles_per_chunk:
			var bundle_idx := bz * _bundles_per_chunk + bx

			# Bundle center world position
			var local_x := (bx + 0.5) * bundle_meters
			var local_z := (bz + 0.5) * bundle_meters
			var world_x := world_offset.x + local_x
			var world_z := world_offset.z + local_z

			# Sample terrain
			var height := heightmap.sample_world(world_x, world_z) as float
			var normal := heightmap.get_normal_world(world_x, world_z) as Vector3
			var slope_dot := normal.dot(Vector3.UP)

			# Determine terrain type based on conditions
			var terrain_type := _determine_terrain_type(height, slope_dot, rng, world_x, world_z)
			terrain[bundle_idx] = terrain_type

	_chunk_terrain[chunk_coord] = terrain

	# Generate vegetation based on terrain types
	_generate_chunk_vegetation(chunk_coord, heightmap, chunk_size)


## Determine terrain type for a bundle
## world_x/world_z are passed for water proximity checks
func _determine_terrain_type(height: float, slope_dot: float, rng: RandomNumberGenerator, world_x: float = 0.0, world_z: float = 0.0) -> int:
	# Steep slopes = clear
	if slope_dot < _min_slope_dot:
		return TerrainType.CLEAR

	# Check water proximity for rice paddy clustering
	var near_water := false
	if _terrain_manager and _terrain_manager.has_method("is_near_water"):
		near_water = _terrain_manager.is_near_water(world_x, world_z)

	# Low flat areas have chance of rice paddy - higher near water
	if height < 30.0 and slope_dot > 0.93:
		var paddy_chance: float = 0.7 if near_water else 0.15
		if rng.randf() < paddy_chance:
			return TerrainType.RICE_PADDY

	# Very flat = grassland chance
	if slope_dot > 0.98 and rng.randf() < 0.2:
		return TerrainType.GRASSLAND

	# Random jungle density
	var density_roll := rng.randf()
	if density_roll < 0.2:
		return TerrainType.LIGHT_JUNGLE
	elif density_roll < 0.5:
		return TerrainType.MEDIUM_JUNGLE
	else:
		return TerrainType.HEAVY_JUNGLE


## Generate vegetation meshes for chunk
func _generate_chunk_vegetation(chunk_coord: Vector2i, heightmap: Object, chunk_size: float) -> void:
	var terrain: PackedByteArray = _chunk_terrain[chunk_coord]

	var world_offset := Vector3(
		chunk_coord.x * chunk_size,
		0.0,
		chunk_coord.y * chunk_size
	)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(chunk_coord) + 1000

	var transforms: Array[Transform3D] = []

	for bz in _bundles_per_chunk:
		for bx in _bundles_per_chunk:
			var bundle_idx := bz * _bundles_per_chunk + bx
			var terrain_type: int = terrain[bundle_idx]

			var props: Array = TYPE_PROPS[terrain_type]
			var tree_chance: float = props[0]
			var count_min: int = props[1]
			var count_max: int = props[2]

			if tree_chance <= 0.0 or rng.randf() > tree_chance:
				continue

			# Number of trees in this bundle
			var tree_count := rng.randi_range(count_min, count_max)

			# Place trees within the 2x2 bundle
			for _t in tree_count:
				var local_x := bx * bundle_meters + rng.randf() * bundle_meters
				var local_z := bz * bundle_meters + rng.randf() * bundle_meters
				var world_x := world_offset.x + local_x
				var world_z := world_offset.z + local_z

				var height := heightmap.sample_world(world_x, world_z) as float

				var inst_transform := Transform3D.IDENTITY

				# Random lean/tilt for natural variety (up to 15 degrees)
				var tilt_x := rng.randf_range(-0.26, 0.26)  # ~15 degrees in radians
				var tilt_z := rng.randf_range(-0.26, 0.26)
				inst_transform = inst_transform.rotated(Vector3.RIGHT, tilt_x)
				inst_transform = inst_transform.rotated(Vector3.FORWARD, tilt_z)

				# Random Y rotation
				inst_transform = inst_transform.rotated(Vector3.UP, rng.randf() * TAU)

				# Palm tree is ~10m tall, scale 0.7-1.3 for variety
				var tree_scale := rng.randf_range(0.7, 1.3)
				inst_transform = inst_transform.scaled(Vector3.ONE * tree_scale)
				inst_transform.origin = Vector3(world_x, height, world_z)

				transforms.append(inst_transform)

	if transforms.is_empty():
		return

	# Create MultiMesh with optimized buffer upload
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _meshes[0]
	multimesh.instance_count = transforms.size()

	# Build buffer directly instead of per-instance set_instance_transform calls
	# Format: 12 floats per instance (basis rows + origin components)
	var buffer := PackedFloat32Array()
	buffer.resize(transforms.size() * 12)
	for i in transforms.size():
		var t := transforms[i]
		var b := i * 12
		buffer[b + 0] = t.basis.x.x; buffer[b + 1] = t.basis.y.x
		buffer[b + 2] = t.basis.z.x; buffer[b + 3] = t.origin.x
		buffer[b + 4] = t.basis.x.y; buffer[b + 5] = t.basis.y.y
		buffer[b + 6] = t.basis.z.y; buffer[b + 7] = t.origin.y
		buffer[b + 8] = t.basis.x.z; buffer[b + 9] = t.basis.y.z
		buffer[b + 10] = t.basis.z.z; buffer[b + 11] = t.origin.z
	multimesh.buffer = buffer

	var mm_instance := MultiMeshInstance3D.new()
	mm_instance.multimesh = multimesh
	mm_instance.name = "Veg_%d_%d" % [chunk_coord.x, chunk_coord.y]
	add_child(mm_instance)

	_chunk_instances[chunk_coord] = mm_instance

	# Generate grass patches
	_generate_chunk_grass(chunk_coord, heightmap, chunk_size)

	print("[VegetationManager] Chunk %s: %d trees placed" % [chunk_coord, transforms.size()])


## Generate grass patches for chunk
func _generate_chunk_grass(chunk_coord: Vector2i, heightmap: Object, chunk_size: float) -> void:
	if not _grass_mesh:
		return

	var terrain: PackedByteArray = _chunk_terrain[chunk_coord]

	var world_offset := Vector3(
		chunk_coord.x * chunk_size,
		0.0,
		chunk_coord.y * chunk_size
	)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(chunk_coord) + 5000  # Different seed than trees

	var grass_transforms: Array[Transform3D] = []

	# Grass is more frequent but only in vegetated areas
	for bz in _bundles_per_chunk:
		for bx in _bundles_per_chunk:
			var bundle_idx := bz * _bundles_per_chunk + bx
			var terrain_type: int = terrain[bundle_idx]

			# Only place grass in jungle/grassland areas
			if terrain_type == TerrainType.CLEAR or terrain_type == TerrainType.RICE_PADDY:
				continue

			# More grass in heavier jungle
			var grass_count := 0
			match terrain_type:
				TerrainType.GRASSLAND: grass_count = rng.randi_range(1, 2)
				TerrainType.LIGHT_JUNGLE: grass_count = rng.randi_range(1, 3)
				TerrainType.MEDIUM_JUNGLE: grass_count = rng.randi_range(2, 4)
				TerrainType.HEAVY_JUNGLE: grass_count = rng.randi_range(3, 5)

			for _g in grass_count:
				var local_x := bx * bundle_meters + rng.randf() * bundle_meters
				var local_z := bz * bundle_meters + rng.randf() * bundle_meters
				var world_x := world_offset.x + local_x
				var world_z := world_offset.z + local_z

				var height := heightmap.sample_world(world_x, world_z) as float

				var inst_transform := Transform3D.IDENTITY
				inst_transform = inst_transform.rotated(Vector3.UP, rng.randf() * TAU)

				# Grass patches scaled 0.8-1.5
				var grass_scale := rng.randf_range(0.8, 1.5)
				inst_transform = inst_transform.scaled(Vector3.ONE * grass_scale)
				inst_transform.origin = Vector3(world_x, height, world_z)

				grass_transforms.append(inst_transform)

	if grass_transforms.is_empty():
		return

	# Create grass MultiMesh with optimized buffer upload
	var grass_mm := MultiMesh.new()
	grass_mm.transform_format = MultiMesh.TRANSFORM_3D
	grass_mm.mesh = _grass_mesh
	grass_mm.instance_count = grass_transforms.size()

	# Build buffer directly instead of per-instance set_instance_transform calls
	var buffer := PackedFloat32Array()
	buffer.resize(grass_transforms.size() * 12)
	for i in grass_transforms.size():
		var t := grass_transforms[i]
		var b := i * 12
		buffer[b + 0] = t.basis.x.x; buffer[b + 1] = t.basis.y.x
		buffer[b + 2] = t.basis.z.x; buffer[b + 3] = t.origin.x
		buffer[b + 4] = t.basis.x.y; buffer[b + 5] = t.basis.y.y
		buffer[b + 6] = t.basis.z.y; buffer[b + 7] = t.origin.y
		buffer[b + 8] = t.basis.x.z; buffer[b + 9] = t.basis.y.z
		buffer[b + 10] = t.basis.z.z; buffer[b + 11] = t.origin.z
	grass_mm.buffer = buffer

	var grass_instance := MultiMeshInstance3D.new()
	grass_instance.multimesh = grass_mm
	grass_instance.name = "Grass_%d_%d" % [chunk_coord.x, chunk_coord.y]
	add_child(grass_instance)

	_chunk_grass[chunk_coord] = grass_instance


## Clear vegetation in a circular area - clears entire bundles
func clear_area(center: Vector3, radius: float, chunk_size: float) -> int:
	var cleared := 0
	var radius_sq := radius * radius

	for chunk_coord: Vector2i in _chunk_terrain.keys().duplicate():
		var terrain: PackedByteArray = _chunk_terrain[chunk_coord]
		var chunk_world_x := chunk_coord.x * chunk_size
		var chunk_world_z := chunk_coord.y * chunk_size
		var changed := false

		for bz in _bundles_per_chunk:
			for bx in _bundles_per_chunk:
				var bundle_idx := bz * _bundles_per_chunk + bx

				if terrain[bundle_idx] == TerrainType.CLEAR:
					continue

				var bundle_x := chunk_world_x + (bx + 0.5) * bundle_meters
				var bundle_z := chunk_world_z + (bz + 0.5) * bundle_meters
				var dist_sq := (bundle_x - center.x) ** 2 + (bundle_z - center.z) ** 2

				if dist_sq < radius_sq:
					terrain[bundle_idx] = TerrainType.CLEAR
					cleared += 1
					changed = true

		if changed:
			_chunk_terrain[chunk_coord] = terrain
			# Rebuild chunk vegetation
			if _chunk_instances.has(chunk_coord):
				_chunk_instances[chunk_coord].queue_free()
				_chunk_instances.erase(chunk_coord)
			# Would need heightmap to fully rebuild - for now just clear

	return cleared


## Check if position blocks LOS (heavy/medium jungle)
func blocks_los(world_pos: Vector3, chunk_size: float) -> bool:
	var chunk_coord := Vector2i(
		int(floor(world_pos.x / chunk_size)),
		int(floor(world_pos.z / chunk_size))
	)

	if not _chunk_terrain.has(chunk_coord):
		return false

	var terrain: PackedByteArray = _chunk_terrain[chunk_coord]
	var local_x := fmod(world_pos.x, chunk_size)
	var local_z := fmod(world_pos.z, chunk_size)
	if local_x < 0: local_x += chunk_size
	if local_z < 0: local_z += chunk_size

	var bx := int(local_x / bundle_meters)
	var bz := int(local_z / bundle_meters)

	if bx < 0 or bx >= _bundles_per_chunk or bz < 0 or bz >= _bundles_per_chunk:
		return false

	var terrain_type: int = terrain[bz * _bundles_per_chunk + bx]
	var props: Array = TYPE_PROPS[terrain_type]
	return props[3]  # blocks_los


## Get terrain type at world position
func get_terrain_type_at(world_pos: Vector3, chunk_size: float) -> int:
	var chunk_coord := Vector2i(
		int(floor(world_pos.x / chunk_size)),
		int(floor(world_pos.z / chunk_size))
	)

	if not _chunk_terrain.has(chunk_coord):
		return TerrainType.CLEAR

	var terrain: PackedByteArray = _chunk_terrain[chunk_coord]
	var local_x := fmod(world_pos.x, chunk_size)
	var local_z := fmod(world_pos.z, chunk_size)
	if local_x < 0: local_x += chunk_size
	if local_z < 0: local_z += chunk_size

	var bx := int(local_x / bundle_meters)
	var bz := int(local_z / bundle_meters)

	if bx < 0 or bx >= _bundles_per_chunk or bz < 0 or bz >= _bundles_per_chunk:
		return TerrainType.CLEAR

	return terrain[bz * _bundles_per_chunk + bx]


## Get movement speed multiplier at world position (1.0 = full speed)
func get_movement_multiplier_at(world_pos: Vector3, chunk_size: float) -> float:
	var terrain_type := get_terrain_type_at(world_pos, chunk_size)
	var props: Array = TYPE_PROPS[terrain_type]
	return props[4]  # movement_speed


## Set terrain type at world position
func set_terrain_type_at(world_pos: Vector3, chunk_size: float, new_type: int) -> void:
	var chunk_coord := Vector2i(
		int(floor(world_pos.x / chunk_size)),
		int(floor(world_pos.z / chunk_size))
	)

	if not _chunk_terrain.has(chunk_coord):
		return

	var terrain: PackedByteArray = _chunk_terrain[chunk_coord]
	var local_x := fmod(world_pos.x, chunk_size)
	var local_z := fmod(world_pos.z, chunk_size)
	if local_x < 0: local_x += chunk_size
	if local_z < 0: local_z += chunk_size

	var bx := int(local_x / bundle_meters)
	var bz := int(local_z / bundle_meters)

	if bx >= 0 and bx < _bundles_per_chunk and bz >= 0 and bz < _bundles_per_chunk:
		terrain[bz * _bundles_per_chunk + bx] = new_type
		_chunk_terrain[chunk_coord] = terrain


## Clear specific chunk
func clear_chunk(chunk_coord: Vector2i) -> void:
	if _chunk_instances.has(chunk_coord):
		var instance: MultiMeshInstance3D = _chunk_instances[chunk_coord]
		if is_instance_valid(instance):
			instance.queue_free()
		_chunk_instances.erase(chunk_coord)
	if _chunk_grass.has(chunk_coord):
		var grass: MultiMeshInstance3D = _chunk_grass[chunk_coord]
		if is_instance_valid(grass):
			grass.queue_free()
		_chunk_grass.erase(chunk_coord)
	_chunk_terrain.erase(chunk_coord)


## Clear all vegetation
func clear_all() -> void:
	for instance: MultiMeshInstance3D in _chunk_instances.values():
		if is_instance_valid(instance):
			instance.queue_free()
	for grass: MultiMeshInstance3D in _chunk_grass.values():
		if is_instance_valid(grass):
			grass.queue_free()
	_chunk_instances.clear()
	_chunk_grass.clear()
	_chunk_terrain.clear()


## Create procedural palm tree mesh - Vietnam jungle style
## OPTIMIZED: Single surface with vertex colors to reduce draw calls from 9 to 1
func _create_procedural_tree() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Colors for trunk and fronds
	var trunk_color := Color(0.35, 0.28, 0.2)  # Palm bark color
	var frond_color := Color(0.15, 0.35, 0.1)  # Bright palm green

	# Build trunk (6-sided cylinder, 10m tall)
	var trunk_segments := 6
	var trunk_bottom_radius := 0.25
	var trunk_top_radius := 0.15
	var trunk_height := 8.0

	for i in trunk_segments:
		var angle0 := (float(i) / trunk_segments) * TAU
		var angle1 := (float(i + 1) / trunk_segments) * TAU

		var bottom0 := Vector3(cos(angle0) * trunk_bottom_radius, 0, sin(angle0) * trunk_bottom_radius)
		var bottom1 := Vector3(cos(angle1) * trunk_bottom_radius, 0, sin(angle1) * trunk_bottom_radius)
		var top0 := Vector3(cos(angle0) * trunk_top_radius, trunk_height, sin(angle0) * trunk_top_radius)
		var top1 := Vector3(cos(angle1) * trunk_top_radius, trunk_height, sin(angle1) * trunk_top_radius)

		# Normal pointing outward
		var normal := Vector3(cos((angle0 + angle1) * 0.5), 0.1, sin((angle0 + angle1) * 0.5)).normalized()

		st.set_color(trunk_color)
		st.set_normal(normal)

		# Two triangles per segment
		st.add_vertex(bottom0)
		st.add_vertex(bottom1)
		st.add_vertex(top1)

		st.add_vertex(bottom0)
		st.add_vertex(top1)
		st.add_vertex(top0)

	# Build fronds - 8 radiating from top
	var frond_count := 8
	var frond_length := 4.0
	var crown_height := trunk_height
	var droop_angle := deg_to_rad(35.0)

	for i in frond_count:
		var angle := (float(i) / frond_count) * TAU
		var dir := Vector3(cos(angle), 0, sin(angle))
		var drooped_dir := Vector3(dir.x * cos(droop_angle), -sin(droop_angle), dir.z * cos(droop_angle)).normalized()

		var base := Vector3(0, crown_height, 0)
		var tip := base + drooped_dir * frond_length
		var mid := base + drooped_dir * (frond_length * 0.5) + Vector3(0, 0.3, 0)

		var width := 0.4
		var perp := Vector3(-dir.z, 0, dir.x) * width

		st.set_color(frond_color)
		st.set_normal(Vector3.UP)

		# Front face triangles
		st.add_vertex(base)
		st.add_vertex(mid + perp * 0.8)
		st.add_vertex(mid - perp * 0.8)

		st.add_vertex(mid + perp * 0.8)
		st.add_vertex(tip)
		st.add_vertex(mid - perp * 0.8)

		# Back face triangles
		st.set_normal(-Vector3.UP)
		st.add_vertex(base)
		st.add_vertex(mid - perp * 0.8)
		st.add_vertex(mid + perp * 0.8)

		st.add_vertex(mid - perp * 0.8)
		st.add_vertex(tip)
		st.add_vertex(mid + perp * 0.8)

	# Generate normals and index the mesh
	st.generate_normals()
	st.index()

	# Create material with vertex colors
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mesh := st.commit()
	mesh.surface_set_material(0, mat)

	# Verify single surface
	assert(mesh.get_surface_count() == 1, "Tree mesh should have exactly 1 surface")

	return mesh


## Create procedural grass patch mesh
func _create_procedural_grass() -> ArrayMesh:
	var mesh := ArrayMesh.new()

	var grass_mat := StandardMaterial3D.new()
	grass_mat.albedo_color = Color(0.2, 0.4, 0.12)  # Jungle grass green
	grass_mat.roughness = 0.9
	grass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(grass_mat)

	# Create a cluster of grass blades
	var blade_count := 5
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345  # Consistent for all grass meshes

	for i in blade_count:
		var offset_x := rng.randf_range(-0.3, 0.3)
		var offset_z := rng.randf_range(-0.3, 0.3)
		var height := rng.randf_range(0.4, 0.8)
		var lean := rng.randf_range(-0.15, 0.15)

		# Grass blade - thin triangle
		var base1 := Vector3(offset_x - 0.03, 0, offset_z)
		var base2 := Vector3(offset_x + 0.03, 0, offset_z)
		var tip := Vector3(offset_x + lean, height, offset_z + lean * 0.5)

		st.set_normal(Vector3(0, 0.5, 0.5).normalized())
		st.add_vertex(base1)
		st.add_vertex(base2)
		st.add_vertex(tip)

		# Back face
		st.add_vertex(base2)
		st.add_vertex(base1)
		st.add_vertex(tip)

	mesh = st.commit()
	return mesh
