extends MeshInstance3D
class_name WaterSwampMesh
## Generates swamp water mesh with murky appearance
## Uses grid-based cells with shore distance in vertex colors

## Water surface elevation
var water_elevation: float = 5.0

## Shore fade distance
var shore_fade_distance: float = 4.0

## Material
var _material: ShaderMaterial = null


func _ready() -> void:
	_setup_material()


func _setup_material() -> void:
	var shader := preload("res://water/water_swamp.gdshader")
	_material = ShaderMaterial.new()
	_material.shader = shader


## Build mesh from swamp cells
func build_from_cells(cells: Array[Vector2i], elevation: float, heightmap: RefCounted) -> void:
	if cells.size() < 1:
		push_error("[WaterSwampMesh] No cells provided")
		return

	water_elevation = elevation
	var cell_size: float = heightmap.cell_size

	# Create a cell lookup set
	var cell_set: Dictionary = {}
	for cell in cells:
		cell_set[cell] = true

	# Build vertices
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var vertex_idx: int = 0

	for cell in cells:
		var world_x: float = cell.x * cell_size
		var world_z: float = cell.y * cell_size

		# Calculate shore distance (distance to nearest non-swamp cell)
		var shore_dist: float = _cell_distance_to_edge(cell, cell_set) * cell_size
		var normalized_shore: float = clampf(shore_dist / 20.0, 0.0, 1.0)

		# Get terrain height for depth calculation
		var terrain_height: float = heightmap.get_cell(cell.x, cell.y) * heightmap.height_scale
		var depth: float = maxf(0.0, elevation - terrain_height)
		var normalized_depth: float = clampf(depth / 2.0, 0.0, 1.0)  # Swamps are shallow

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
			uvs.append(corner_uvs[i] + Vector2(cell.x, cell.y))
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


## Calculate cell distance to edge of swamp
func _cell_distance_to_edge(cell: Vector2i, cell_set: Dictionary) -> int:
	var dirs: Array[Vector2i] = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]

	for dist in range(1, 25):  # Max 25 cells
		for dir in dirs:
			var check: Vector2i = cell + dir * dist
			if not cell_set.has(check):
				return dist
	return 25


## Set muck parameters
func set_muck_params(intensity: float, muck_scale: float) -> void:
	if _material:
		_material.set_shader_parameter("muck_intensity", intensity)
		_material.set_shader_parameter("muck_scale", muck_scale)


## Set ripple parameters
func set_ripple_params(strength: float, ripple_scale: float, speed: float) -> void:
	if _material:
		_material.set_shader_parameter("ripple_strength", strength)
		_material.set_shader_parameter("ripple_scale", ripple_scale)
		_material.set_shader_parameter("ripple_speed", speed)
