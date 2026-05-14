extends Node3D
class_name TerrainChunk
## A single terrain chunk (256m x 256m) with mesh, collision, and navigation

signal mesh_ready
signal nav_ready

# Chunk identity
var coord: Vector2i  # Chunk grid coordinates
var chunk_size: float = 256.0  # Meters
var cell_size: float = 2.0  # Meters per vertex
var grid_resolution: int = 128  # Vertices per side (256m / 2m)

# Components
var mesh_instance: MeshInstance3D
var nav_region: NavigationRegion3D
var collision_body: StaticBody3D  # Optional - only for raycast picking

# State
var is_loaded: bool = false
var height_scale: float = 280.0

# Material (shared across chunks) - can be ShaderMaterial or StandardMaterial3D
static var shared_material: Material
static var _using_shader: bool = false


func _init(chunk_coord: Vector2i, size: float = 256.0, c_size: float = 2.0) -> void:
	coord = chunk_coord
	chunk_size = size
	cell_size = c_size
	grid_resolution = int(chunk_size / cell_size)


func _ready() -> void:
	# Create mesh instance
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	add_child(mesh_instance)

	# Create navigation region
	nav_region = NavigationRegion3D.new()
	nav_region.name = "NavRegion"
	add_child(nav_region)

	# Position chunk at world coordinates
	var world_x: float = coord.x * chunk_size
	var world_z: float = coord.y * chunk_size
	position = Vector3(world_x, 0, world_z)


## Build mesh from heightmap region data
## region_data: PackedFloat32Array of normalized heights (grid_resolution+1 x grid_resolution+1)
func build_mesh(region_data: PackedFloat32Array, h_scale: float = 280.0) -> void:
	height_scale = h_scale

	if region_data.size() < (grid_resolution + 1) * (grid_resolution + 1):
		push_error("[TerrainChunk] Region data too small: %d (expected %d)" % [
			region_data.size(), (grid_resolution + 1) * (grid_resolution + 1)
		])
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var step: float = chunk_size / float(grid_resolution)
	var data_width: int = grid_resolution + 1

	# Generate vertices in a grid
	var vertices: Array[Vector3] = []
	var colors: Array[Color] = []

	for z in range(grid_resolution + 1):
		for x in range(grid_resolution + 1):
			var local_x: float = x * step
			var local_z: float = z * step
			var h: float = region_data[z * data_width + x] * height_scale

			vertices.append(Vector3(local_x, h, local_z))
			colors.append(_get_terrain_color(h, region_data[z * data_width + x]))

	# Generate triangles (counter-clockwise winding for upward normals)
	for z in range(grid_resolution):
		for x in range(grid_resolution):
			var i: int = z * data_width + x

			# Get 4 corners of this quad
			var v0: Vector3 = vertices[i]
			var v1: Vector3 = vertices[i + 1]
			var v2: Vector3 = vertices[i + data_width]
			var v3: Vector3 = vertices[i + data_width + 1]

			var c0: Color = colors[i]
			var c1: Color = colors[i + 1]
			var c2: Color = colors[i + data_width]
			var c3: Color = colors[i + data_width + 1]

			# Triangle 1: v0, v1, v2
			var n1: Vector3 = (v1 - v0).cross(v2 - v0).normalized()
			if n1.y < 0:
				n1 = -n1
			st.set_normal(n1)
			st.set_color(c0)
			st.add_vertex(v0)
			st.set_color(c1)
			st.add_vertex(v1)
			st.set_color(c2)
			st.add_vertex(v2)

			# Triangle 2: v1, v3, v2
			var n2: Vector3 = (v3 - v1).cross(v2 - v1).normalized()
			if n2.y < 0:
				n2 = -n2
			st.set_normal(n2)
			st.set_color(c1)
			st.add_vertex(v1)
			st.set_color(c3)
			st.add_vertex(v3)
			st.set_color(c2)
			st.add_vertex(v2)

	mesh_instance.mesh = st.commit()

	# Apply shared material
	if not shared_material:
		_create_shared_material()
	mesh_instance.material_override = shared_material

	is_loaded = true
	mesh_ready.emit()

	print("[TerrainChunk] Chunk %s mesh built: %d vertices" % [coord, vertices.size()])


## Create shared material for all chunks
## Uses terrain shader with vertex colors if available, falls back to StandardMaterial3D
static func _create_shared_material() -> void:
	# Try to load terrain shader
	var shader_path := "res://shaders/terrain.gdshader"
	if ResourceLoader.exists(shader_path):
		var shader := load(shader_path) as Shader
		if shader:
			var shader_mat := ShaderMaterial.new()
			shader_mat.shader = shader

			shared_material = shader_mat
			_using_shader = true
			print("[TerrainChunk] Using terrain shader with vertex colors")
			return

	# Fallback to basic material
	var fallback_mat := StandardMaterial3D.new()
	fallback_mat.albedo_color = Color(0.3, 0.5, 0.2)
	fallback_mat.roughness = 0.9
	fallback_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	fallback_mat.vertex_color_use_as_albedo = true
	fallback_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	shared_material = fallback_mat
	_using_shader = false
	print("[TerrainChunk] Using fallback standard material")


## Check if using shader material
static func is_using_shader() -> bool:
	return _using_shader


## Update shader parameter (for clearing/vegetation textures)
static func set_shader_texture(param_name: String, texture: Texture2D) -> void:
	if not _using_shader or not shared_material:
		return
	var shader_mat := shared_material as ShaderMaterial
	if shader_mat:
		shader_mat.set_shader_parameter(param_name, texture)


## Update multiple shader parameters at once
static func set_shader_parameters(params: Dictionary) -> void:
	if not _using_shader or not shared_material:
		return
	var shader_mat := shared_material as ShaderMaterial
	if shader_mat:
		for key: String in params:
			shader_mat.set_shader_parameter(key, params[key])


## Height-based terrain coloring
func _get_terrain_color(h: float, normalized_h: float) -> Color:
	# Vietnam-style terrain coloring
	var t: float = clampf(normalized_h, 0.0, 1.0)

	# Lowland (rice paddies) -> Jungle -> Highlands -> Cliffs
	if t < 0.15:
		# Lowland - rice paddy green
		return Color(0.18, 0.38, 0.12).lerp(Color(0.12, 0.32, 0.08), t / 0.15)
	elif t < 0.4:
		# Jungle - dense vegetation
		var blend: float = (t - 0.15) / 0.25
		return Color(0.12, 0.32, 0.08).lerp(Color(0.15, 0.28, 0.1), blend)
	elif t < 0.65:
		# Highlands - subtropical
		var blend: float = (t - 0.4) / 0.25
		return Color(0.15, 0.28, 0.1).lerp(Color(0.25, 0.32, 0.18), blend)
	elif t < 0.85:
		# Slopes - exposed earth
		var blend: float = (t - 0.65) / 0.2
		return Color(0.25, 0.32, 0.18).lerp(Color(0.4, 0.35, 0.25), blend)
	else:
		# Peaks - rock
		var blend: float = (t - 0.85) / 0.15
		return Color(0.4, 0.35, 0.25).lerp(Color(0.5, 0.45, 0.4), blend)


## Create optional collision for raycast picking (not for unit movement)
func create_raycast_collision() -> void:
	if collision_body:
		return

	if not mesh_instance.mesh:
		return

	collision_body = StaticBody3D.new()
	collision_body.name = "RaycastCollision"
	collision_body.collision_layer = 1  # Terrain layer
	collision_body.collision_mask = 0   # No response

	var collision_shape := CollisionShape3D.new()
	collision_shape.shape = mesh_instance.mesh.create_trimesh_shape()
	collision_body.add_child(collision_shape)

	add_child(collision_body)


## Bake navigation mesh for pathfinding
func bake_navigation() -> void:
	if not mesh_instance.mesh:
		return

	var nav_mesh := NavigationMesh.new()

	# Configure for RTS pathfinding
	nav_mesh.agent_radius = 1.0
	nav_mesh.agent_height = 2.0
	nav_mesh.agent_max_climb = 0.5
	nav_mesh.agent_max_slope = 45.0
	nav_mesh.cell_size = 0.5
	nav_mesh.cell_height = 0.25

	# Source geometry from mesh
	var source := NavigationMeshSourceGeometryData3D.new()
	source.add_mesh(mesh_instance.mesh, mesh_instance.global_transform)

	# Bake (synchronous for now - could be async in future)
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source)

	nav_region.navigation_mesh = nav_mesh
	nav_ready.emit()

	print("[TerrainChunk] Chunk %s navigation baked" % [coord])


## Unload chunk (free resources)
func unload() -> void:
	if mesh_instance:
		mesh_instance.mesh = null
	if collision_body:
		collision_body.queue_free()
		collision_body = null
	if nav_region:
		nav_region.navigation_mesh = null
	is_loaded = false


## Get world bounds of this chunk
func get_world_bounds() -> AABB:
	var origin := Vector3(coord.x * chunk_size, 0, coord.y * chunk_size)
	return AABB(origin, Vector3(chunk_size, height_scale, chunk_size))
