extends MeshInstance3D
class_name WaterCoastalMesh
## Generates ocean water mesh for coastal zones
## Uses grid-based cells with depth and shore distance in vertex colors

## Water surface elevation (sea level)
var water_elevation: float = 5.0

## Shore distance for alpha blending
var shore_fade_distance: float = 8.0

## Preload coastal material
var _material: ShaderMaterial = null


func _ready() -> void:
	_setup_material()


func _setup_material() -> void:
	var shader := preload("res://water/water_coastal.gdshader")
	_material = ShaderMaterial.new()
	_material.shader = shader


## Build mesh from coastal cells
func build_from_cells(cells: Array[Vector2i], elevation: float, heightmap: RefCounted) -> void:
	if cells.size() < 1:
		push_error("[WaterCoastalMesh] No cells provided")
		return

	water_elevation = elevation
	var cell_size: float = heightmap.cell_size
	var height_scale: float = heightmap.height_scale

	# Create a cell lookup set
	var cell_set: Dictionary = {}
	for cell in cells:
		cell_set[cell] = true

	# Build vertices - one quad per cell
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var vertex_idx: int = 0

	for cell in cells:
		var world_x: float = cell.x * cell_size
		var world_z: float = cell.y * cell_size

		# Get terrain height at cell center for depth calculation
		var terrain_height: float = heightmap.get_cell(cell.x, cell.y) * height_scale
		var depth: float = maxf(0.0, elevation - terrain_height)
		var normalized_depth: float = clampf(depth / 10.0, 0.0, 1.0)  # 0-10m range

		# Calculate shore distance (distance to nearest non-water cell)
		var shore_dist: float = _cell_distance_to_edge(cell, cell_set) * cell_size
		var normalized_shore: float = clampf(shore_dist / 20.0, 0.0, 1.0)  # 0-20m range

		# Vertex color: R = shore distance, G = depth
		var color := Color(normalized_shore, normalized_depth, 0.0, 1.0)

		# Four corners of the cell
		var corners: Array[Vector3] = [
			Vector3(world_x, elevation, world_z),
			Vector3(world_x + cell_size, elevation, world_z),
			Vector3(world_x + cell_size, elevation, world_z + cell_size),
			Vector3(world_x, elevation, world_z + cell_size)
		]

		var corner_uvs: Array[Vector2] = [
			Vector2(0.0, 0.0),
			Vector2(1.0, 0.0),
			Vector2(1.0, 1.0),
			Vector2(0.0, 1.0)
		]

		# Add quad vertices
		for i in range(4):
			vertices.append(corners[i])
			normals.append(Vector3.UP)
			uvs.append(corner_uvs[i] + Vector2(cell.x, cell.y))  # Tile UVs
			colors.append(color)

		# Two triangles per quad
		indices.append(vertex_idx)
		indices.append(vertex_idx + 1)
		indices.append(vertex_idx + 2)
		indices.append(vertex_idx)
		indices.append(vertex_idx + 2)
		indices.append(vertex_idx + 3)

		vertex_idx += 4

	# Create mesh
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	if _material:
		array_mesh.surface_set_material(0, _material)

	self.mesh = array_mesh


## Calculate cell distance to edge of water body
func _cell_distance_to_edge(cell: Vector2i, cell_set: Dictionary) -> int:
	var dirs: Array[Vector2i] = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]

	for dist in range(1, 30):  # Max distance 30 cells
		for dir in dirs:
			var check: Vector2i = cell + dir * dist
			if not cell_set.has(check):
				return dist
	return 30


## Set wave parameters
func set_wave_params(strength: float, wave_scale: float, speed: float) -> void:
	if _material:
		_material.set_shader_parameter("wave_strength", strength)
		_material.set_shader_parameter("wave_scale", wave_scale)
		_material.set_shader_parameter("wave_speed", speed)


## Set swell parameters
func set_swell_params(strength: float, swell_scale: float, speed: float, direction: Vector2) -> void:
	if _material:
		_material.set_shader_parameter("swell_strength", strength)
		_material.set_shader_parameter("swell_scale", swell_scale)
		_material.set_shader_parameter("swell_speed", speed)
		_material.set_shader_parameter("swell_direction", direction)


## Set foam parameters
func set_foam_params(intensity: float, threshold: float) -> void:
	if _material:
		_material.set_shader_parameter("foam_intensity", intensity)
		_material.set_shader_parameter("foam_threshold", threshold)
