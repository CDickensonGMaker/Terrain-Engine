extends Node3D
class_name BillboardVegetation
## Billboard vegetation system for mid-distance tree rendering
## Uses 5 intersecting quads (cross/star formation) for 3D depth illusion
## Provides LOD between full 3D trees and distant fog

const BILLBOARD_RANGE_MIN := 80.0   # Start showing billboards
const BILLBOARD_RANGE_MAX := 800.0  # Stop showing billboards (extended range, no fog)
const BILLBOARDS_PER_CHUNK := 240   # Very high density for thick jungle feeling

# Billboard meshes (trees, bamboo, bushes)
var _tree_meshes: Array[ArrayMesh] = []
var _bush_mesh: ArrayMesh

# Loaded textures
var _tree_textures: Array[Texture2D] = []
var _bamboo_textures: Array[Texture2D] = []
var _bush_textures: Array[Texture2D] = []

# Billboard materials
var _tree_materials: Array[StandardMaterial3D] = []
var _bush_material: StandardMaterial3D

# Per-chunk billboard instances
var _chunk_billboards: Dictionary = {}  # Vector2i -> Node3D (container)

# Placement cache - built once per chunk, survives regen
# coord -> Array of placement dicts {position, rot_y, scale, mesh_idx, bundle_x, bundle_z}
var _chunk_placements: Dictionary = {}

# Reference to terrain system
var _terrain_manager: Node
var _vegetation_manager: Node
var _camera: Camera3D

# Chunk size
var _chunk_size: float = 256.0

# Update accumulator
var _lod_accumulator: float = 0.0
const LOD_UPDATE_INTERVAL := 0.1  # 10Hz


func _ready() -> void:
	_load_billboard_textures()
	_create_billboard_meshes()


func _process(delta: float) -> void:
	if not _camera:
		return

	_lod_accumulator += delta
	if _lod_accumulator < LOD_UPDATE_INTERVAL:
		return
	_lod_accumulator = 0.0

	_update_billboard_visibility()


## Set references
func set_terrain_manager(manager: Node) -> void:
	_terrain_manager = manager


func set_vegetation_manager(veg_manager: Node) -> void:
	_vegetation_manager = veg_manager


func set_camera(cam: Camera3D) -> void:
	_camera = cam


func set_chunk_size(size: float) -> void:
	_chunk_size = size


## Load billboard textures from assets
func _load_billboard_textures() -> void:
	# Tree billboards
	for i in range(1, 5):
		var path := "res://textures/billboards/tree%d_billboard.png" % i
		if ResourceLoader.exists(path):
			_tree_textures.append(load(path))
			print("[BillboardVegetation] Loaded: %s" % path)

	# Bamboo billboards
	for i in range(1, 4):
		var path := "res://textures/billboards/bamboo%d_billboard.png" % i
		if ResourceLoader.exists(path):
			_bamboo_textures.append(load(path))
			print("[BillboardVegetation] Loaded: %s" % path)

	# Bush billboards
	for i in range(1, 4):
		var path := "res://textures/billboards/bush%d_billboard.png" % i
		if ResourceLoader.exists(path):
			_bush_textures.append(load(path))
			print("[BillboardVegetation] Loaded: %s" % path)

	print("[BillboardVegetation] Loaded %d tree, %d bamboo, %d bush textures" % [
		_tree_textures.size(), _bamboo_textures.size(), _bush_textures.size()
	])


## Create 5-plane cross billboard mesh for 3D depth illusion
func _create_cross_billboard_mesh(tex: Texture2D, width: float, height: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# 5 quads at different angles: 0, 36, 72, 108, 144 degrees (star pattern)
	var plane_count := 5
	var angle_step := PI / float(plane_count)

	for p in plane_count:
		var angle := float(p) * angle_step
		var dir := Vector3(cos(angle), 0, sin(angle))
		var perp := Vector3(-dir.z, 0, dir.x)

		# Quad corners
		var half_w := width * 0.5
		var bottom_left := perp * -half_w
		var bottom_right := perp * half_w
		var top_left := perp * -half_w + Vector3(0, height, 0)
		var top_right := perp * half_w + Vector3(0, height, 0)

		# Normal facing one direction
		var normal := dir

		# Front face
		st.set_normal(normal)
		st.set_uv(Vector2(0, 1))
		st.add_vertex(bottom_left)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(bottom_right)
		st.set_uv(Vector2(1, 0))
		st.add_vertex(top_right)

		st.set_uv(Vector2(0, 1))
		st.add_vertex(bottom_left)
		st.set_uv(Vector2(1, 0))
		st.add_vertex(top_right)
		st.set_uv(Vector2(0, 0))
		st.add_vertex(top_left)

		# Back face
		st.set_normal(-normal)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(bottom_left)
		st.set_uv(Vector2(1, 0))
		st.add_vertex(top_left)
		st.set_uv(Vector2(0, 0))
		st.add_vertex(top_right)

		st.set_uv(Vector2(1, 1))
		st.add_vertex(bottom_left)
		st.set_uv(Vector2(0, 0))
		st.add_vertex(top_right)
		st.set_uv(Vector2(0, 1))
		st.add_vertex(bottom_right)

	var mesh := st.commit()

	# Create material
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	mat.albedo_texture = tex
	mesh.surface_set_material(0, mat)

	return mesh


## Create billboard meshes from loaded textures
func _create_billboard_meshes() -> void:
	# Create tree billboard meshes (tall)
	for tex in _tree_textures:
		var mesh := _create_cross_billboard_mesh(tex, 6.0, 10.0)
		_tree_meshes.append(mesh)

	# Create bamboo billboard meshes (tall, narrow)
	for tex in _bamboo_textures:
		var mesh := _create_cross_billboard_mesh(tex, 4.0, 12.0)
		_tree_meshes.append(mesh)  # Add to tree meshes for variety

	# Create bush mesh (short, wide)
	if not _bush_textures.is_empty():
		_bush_mesh = _create_cross_billboard_mesh(_bush_textures[0], 3.0, 2.5)

	print("[BillboardVegetation] Created %d billboard mesh variants" % _tree_meshes.size())


## Generate billboards for a chunk
## Uses placement cache pattern to prevent tree teleportation on regen
func generate_for_chunk(coord: Vector2i, heightmap: Object, vegetation_terrain: PackedByteArray) -> void:
	if _tree_meshes.is_empty():
		return

	_clear_chunk_nodes(coord)  # Frees MultiMesh nodes only, keeps cache

	# Build the placement cache on first visit, reuse on subsequent calls
	if not _chunk_placements.has(coord):
		_build_placements(coord, heightmap)

	_materialize_chunk(coord, vegetation_terrain)


## Build placement cache - RNG lives here, called once per chunk
func _build_placements(coord: Vector2i, heightmap: Object) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(coord) + 9999  # Different seed than 3D trees

	var placements: Array = []
	var world_offset_x := coord.x * _chunk_size
	var world_offset_z := coord.y * _chunk_size
	var bundles_per_side := int(_chunk_size / 8.0)

	for i in BILLBOARDS_PER_CHUNK:
		var local_x := rng.randf() * _chunk_size
		var local_z := rng.randf() * _chunk_size
		var world_x := world_offset_x + local_x
		var world_z := world_offset_z + local_z

		var bundle_x := int(local_x / 8.0)
		var bundle_z := int(local_z / 8.0)
		if bundle_x < 0 or bundle_x >= bundles_per_side:
			continue
		if bundle_z < 0 or bundle_z >= bundles_per_side:
			continue

		var height := 0.0
		if heightmap and heightmap.has_method("sample_world"):
			height = heightmap.sample_world(world_x, world_z)

		var rot_y := rng.randf() * TAU
		var scale_val := rng.randf_range(0.7, 1.3)
		var mesh_idx := rng.randi() % _tree_meshes.size() if not _tree_meshes.is_empty() else 0

		placements.append({
			"position": Vector3(world_x, height, world_z),
			"rot_y": rot_y,
			"scale": scale_val,
			"mesh_idx": mesh_idx,
			"bundle_x": bundle_x,
			"bundle_z": bundle_z,
		})

	_chunk_placements[coord] = placements


## Materialize visible billboards from cached placements
func _materialize_chunk(coord: Vector2i, vegetation_terrain: PackedByteArray) -> void:
	var placements: Array = _chunk_placements[coord]
	var bundles_per_side := int(_chunk_size / 8.0)
	var transforms_by_mesh: Dictionary = {}

	for p in placements:
		var bundle_idx: int = p.bundle_z * bundles_per_side + p.bundle_x
		if bundle_idx >= vegetation_terrain.size():
			continue
		var terrain_type: int = vegetation_terrain[bundle_idx]
		# Skip clear, rice paddy, and grassland areas
		if terrain_type < 3:  # CLEAR, RICE_PADDY, GRASSLAND
			continue

		if not transforms_by_mesh.has(p.mesh_idx):
			transforms_by_mesh[p.mesh_idx] = []

		var t := Transform3D.IDENTITY
		t = t.rotated(Vector3.UP, p.rot_y)
		t = t.scaled(Vector3.ONE * p.scale)
		t.origin = p.position
		transforms_by_mesh[p.mesh_idx].append(t)

	# Count total for logging
	var total_count := 0
	for mesh_idx in transforms_by_mesh:
		total_count += transforms_by_mesh[mesh_idx].size()

	if total_count == 0:
		return

	# Create a container for this chunk's billboards
	var container := Node3D.new()
	container.name = "Billboard_%d_%d" % [coord.x, coord.y]
	add_child(container)

	# Create MultiMesh for each mesh type
	for mesh_idx: int in transforms_by_mesh:
		var group_transforms: Array = transforms_by_mesh[mesh_idx]
		if group_transforms.is_empty():
			continue

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _tree_meshes[mesh_idx]
		mm.instance_count = group_transforms.size()

		# Build buffer directly
		var buffer := PackedFloat32Array()
		buffer.resize(group_transforms.size() * 12)
		for i in group_transforms.size():
			var t: Transform3D = group_transforms[i]
			var b := i * 12
			buffer[b + 0] = t.basis.x.x; buffer[b + 1] = t.basis.y.x
			buffer[b + 2] = t.basis.z.x; buffer[b + 3] = t.origin.x
			buffer[b + 4] = t.basis.x.y; buffer[b + 5] = t.basis.y.y
			buffer[b + 6] = t.basis.z.y; buffer[b + 7] = t.origin.y
			buffer[b + 8] = t.basis.x.z; buffer[b + 9] = t.basis.y.z
			buffer[b + 10] = t.basis.z.z; buffer[b + 11] = t.origin.z
		mm.buffer = buffer

		var mm_instance := MultiMeshInstance3D.new()
		mm_instance.multimesh = mm
		mm_instance.name = "BB_Mesh_%d" % mesh_idx
		container.add_child(mm_instance)

	_chunk_billboards[coord] = container
	container.visible = false  # Start hidden, LOD system will enable
	print("[BillboardVegetation] Generated %d billboards for chunk %s" % [total_count, coord])


## Clear billboard nodes only (keeps placement cache for regen)
func _clear_chunk_nodes(coord: Vector2i) -> void:
	if _chunk_billboards.has(coord):
		var container: Node3D = _chunk_billboards[coord]
		if is_instance_valid(container):
			container.queue_free()
		_chunk_billboards.erase(coord)


## Full unload - clears both nodes AND placement cache
## Call this on chunk streaming unload, NOT on destruction regen
func clear_chunk(coord: Vector2i) -> void:
	_clear_chunk_nodes(coord)
	_chunk_placements.erase(coord)


## Clear all billboards and caches
func clear_all() -> void:
	for container: Node3D in _chunk_billboards.values():
		if is_instance_valid(container):
			container.queue_free()
	_chunk_billboards.clear()
	_chunk_placements.clear()


## Update billboard visibility based on camera distance
func _update_billboard_visibility() -> void:
	var cam_pos := _camera.global_position

	for coord: Vector2i in _chunk_billboards:
		var container: Node3D = _chunk_billboards[coord]
		if not is_instance_valid(container):
			continue

		var chunk_center := Vector3(
			coord.x * _chunk_size + _chunk_size * 0.5,
			0,
			coord.y * _chunk_size + _chunk_size * 0.5
		)
		var dist := cam_pos.distance_to(chunk_center)

		# Show billboards in the mid-distance range
		# Near: 3D trees visible (handled by vegetation_manager)
		# Mid: Billboards visible
		# Far: Fog + terrain shader takes over
		container.visible = dist >= BILLBOARD_RANGE_MIN and dist < BILLBOARD_RANGE_MAX


## Get billboard instance count for performance monitoring
func get_total_billboard_count() -> int:
	var total := 0
	for coord in _chunk_billboards:
		var container: Node3D = _chunk_billboards[coord]
		if is_instance_valid(container) and container.visible:
			for child in container.get_children():
				if child is MultiMeshInstance3D:
					total += child.multimesh.instance_count
	return total
