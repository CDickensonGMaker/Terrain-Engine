extends MeshInstance3D
class_name TerrainMesh
## Terrain Mesh - Simple direct mesh generation from heightmap

signal mesh_updated

@export var auto_update: bool = true

# Mesh settings
var grid_size: int = 64  # Vertices per side
var terrain_world_size: float = 256.0
var height_scale: float = 150.0

# Material
var terrain_material: StandardMaterial3D

# Reference
var terrain_engine: Node


func _ready() -> void:
	print("[TerrainMesh] Initializing...")
	terrain_engine = get_node_or_null("/root/TerrainEngine")

	if terrain_engine:
		print("[TerrainMesh] TerrainEngine found")
		terrain_engine.terrain_generated.connect(_on_terrain_generated)
	else:
		print("[TerrainMesh] WARNING: TerrainEngine not found")

	_setup_material()


func _setup_material() -> void:
	terrain_material = StandardMaterial3D.new()
	terrain_material.albedo_color = Color(0.3, 0.5, 0.2)
	terrain_material.roughness = 0.9
	terrain_material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Show both sides
	terrain_material.vertex_color_use_as_albedo = true  # Use vertex colors
	terrain_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	material_override = terrain_material
	print("[TerrainMesh] Material ready")


func _on_terrain_generated(_heightmap: Image) -> void:
	print("[TerrainMesh] Signal received")
	if auto_update:
		generate_mesh()


func generate_mesh() -> void:
	print("[TerrainMesh] === GENERATING MESH ===")

	# Get terrain engine if needed
	if not terrain_engine:
		terrain_engine = get_node_or_null("/root/TerrainEngine")

	if not terrain_engine:
		print("[TerrainMesh] No terrain engine - making flat plane")
		_make_simple_plane()
		return

	if terrain_engine.heightmap_data.size() == 0:
		print("[TerrainMesh] No heightmap data - making flat plane")
		_make_simple_plane()
		return

	# Get params
	var engine_size: int = terrain_engine.terrain_size
	var cell_size: float = terrain_engine.cell_size
	height_scale = terrain_engine.height_scale
	terrain_world_size = engine_size * cell_size

	print("[TerrainMesh] Engine size: %d, cell_size: %.1f, world_size: %.1f" % [engine_size, cell_size, terrain_world_size])

	# Build mesh directly with SurfaceTool
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var step: float = terrain_world_size / float(grid_size)
	print("[TerrainMesh] Grid: %dx%d, step: %.2f" % [grid_size, grid_size, step])

	# Generate vertices in a grid
	var vertices: Array[Vector3] = []
	var colors: Array[Color] = []

	for z in range(grid_size + 1):
		for x in range(grid_size + 1):
			var world_x: float = x * step
			var world_z: float = z * step
			var h: float = _sample_height(world_x, world_z)

			vertices.append(Vector3(world_x, h, world_z))
			colors.append(_get_color(h))

	print("[TerrainMesh] Created %d vertices" % vertices.size())

	# Generate triangles
	var tri_count: int = 0
	for z in range(grid_size):
		for x in range(grid_size):
			var i: int = z * (grid_size + 1) + x

			# Get the 4 corners of this quad
			var v0: Vector3 = vertices[i]
			var v1: Vector3 = vertices[i + 1]
			var v2: Vector3 = vertices[i + grid_size + 1]
			var v3: Vector3 = vertices[i + grid_size + 2]

			var c0: Color = colors[i]
			var c1: Color = colors[i + 1]
			var c2: Color = colors[i + grid_size + 1]
			var c3: Color = colors[i + grid_size + 2]

			# Triangle 1: v0, v1, v2 (counter-clockwise from above)
			var n1: Vector3 = (v1 - v0).cross(v2 - v0).normalized()
			if n1.y < 0:
				n1 = -n1  # Ensure normal points up
			st.set_normal(n1)
			st.set_color(c0)
			st.add_vertex(v0)
			st.set_color(c1)
			st.add_vertex(v1)
			st.set_color(c2)
			st.add_vertex(v2)

			# Triangle 2: v1, v3, v2 (counter-clockwise from above)
			var n2: Vector3 = (v3 - v1).cross(v2 - v1).normalized()
			if n2.y < 0:
				n2 = -n2  # Ensure normal points up
			st.set_normal(n2)
			st.set_color(c1)
			st.add_vertex(v1)
			st.set_color(c3)
			st.add_vertex(v3)
			st.set_color(c2)
			st.add_vertex(v2)

			tri_count += 2

	print("[TerrainMesh] Created %d triangles" % tri_count)

	# Commit mesh
	mesh = st.commit()

	if mesh:
		print("[TerrainMesh] Mesh committed: %d surfaces" % mesh.get_surface_count())
		var aabb: AABB = mesh.get_aabb()
		print("[TerrainMesh] AABB: pos=%s size=%s" % [aabb.position, aabb.size])
	else:
		print("[TerrainMesh] ERROR: mesh is null after commit!")

	# Collision
	_create_collision()

	mesh_updated.emit()
	print("[TerrainMesh] === DONE ===")


func _sample_height(world_x: float, world_z: float) -> float:
	if not terrain_engine:
		return 0.0

	var data: PackedFloat32Array = terrain_engine.heightmap_data
	if data.size() == 0:
		return 0.0

	var cell_size: float = terrain_engine.cell_size
	var size: int = terrain_engine.terrain_size

	# Convert to heightmap coords
	var hx: int = int(world_x / cell_size)
	var hz: int = int(world_z / cell_size)

	# Clamp
	hx = clampi(hx, 0, size - 1)
	hz = clampi(hz, 0, size - 1)

	var idx: int = hz * size + hx
	if idx >= 0 and idx < data.size():
		return data[idx] * height_scale

	return 0.0


func _get_color(h: float) -> Color:
	var t: float = clampf(h / height_scale, 0.0, 1.0) if height_scale > 0 else 0.0
	# Green to brown to gray
	if t < 0.5:
		return Color(0.2, 0.45, 0.15).lerp(Color(0.4, 0.35, 0.2), t * 2.0)
	else:
		return Color(0.4, 0.35, 0.2).lerp(Color(0.6, 0.55, 0.5), (t - 0.5) * 2.0)


func _make_simple_plane() -> void:
	print("[TerrainMesh] Making simple test plane")
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Simple 2-triangle plane at y=0
	var size: float = 256.0

	st.set_normal(Vector3.UP)
	st.set_color(Color.GREEN)

	# Triangle 1
	st.add_vertex(Vector3(0, 0, 0))
	st.add_vertex(Vector3(0, 0, size))
	st.add_vertex(Vector3(size, 0, 0))

	# Triangle 2
	st.add_vertex(Vector3(size, 0, 0))
	st.add_vertex(Vector3(0, 0, size))
	st.add_vertex(Vector3(size, 0, size))

	mesh = st.commit()
	print("[TerrainMesh] Simple plane created")


func _create_collision() -> void:
	# Remove old collision bodies immediately (but not during damage updates)
	var to_remove: Array[Node] = []
	for child in get_children():
		if child is StaticBody3D:
			to_remove.append(child)
	for child in to_remove:
		remove_child(child)
		child.free()

	if not mesh:
		return

	# Create trimesh collision from mesh
	create_trimesh_collision()

	# Configure the collision body
	for child in get_children():
		if child is StaticBody3D:
			child.collision_layer = 1
			child.collision_mask = 0
			print("[TerrainMesh] Trimesh collision created")
