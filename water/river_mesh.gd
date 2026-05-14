extends MeshInstance3D
class_name RiverMesh
## Generates water surface meshes from river paths using triangle strips
## The water surface sits slightly below terrain height for visual integration

const WATER_DEPTH_OFFSET: float = 0.3  # Meters below terrain surface
const SHADER_PATH: String = "res://water/water.gdshader"

# Cached shader material
var _water_material: ShaderMaterial


func _init() -> void:
	_load_water_material()


func _load_water_material() -> void:
	var shader := load(SHADER_PATH) as Shader
	if shader:
		_water_material = ShaderMaterial.new()
		_water_material.shader = shader
	else:
		push_warning("[RiverMesh] Failed to load water shader from: %s" % SHADER_PATH)


## Build river mesh from a path with varying widths
## path: PackedVector2Array of river centerline points (x, z coordinates in world space)
## widths: PackedFloat32Array of river width at each point (total width, not half-width)
## heightmap: HeightmapStorage instance for terrain height sampling
func build_from_path(path: PackedVector2Array, widths: PackedFloat32Array, heightmap: HeightmapStorage) -> void:
	if path.size() < 2:
		push_warning("[RiverMesh] Path must have at least 2 points")
		return

	if path.size() != widths.size():
		push_warning("[RiverMesh] Path and widths arrays must have same size")
		return

	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)

	# Accumulate distance along path for UV coordinate
	var accumulated_distance: float = 0.0

	for i in range(path.size()):
		var point: Vector2 = path[i]
		var width: float = widths[i]
		var half_width: float = width * 0.5

		# Calculate perpendicular direction
		var perpendicular: Vector2 = _calculate_perpendicular(path, i)

		# Calculate left and right bank positions
		var left_pos: Vector2 = point - perpendicular * half_width
		var right_pos: Vector2 = point + perpendicular * half_width

		# Sample terrain heights and apply water depth offset
		var left_height: float = heightmap.sample_world(left_pos.x, left_pos.y) - WATER_DEPTH_OFFSET
		var right_height: float = heightmap.sample_world(right_pos.x, right_pos.y) - WATER_DEPTH_OFFSET

		# Use average height for a flatter water surface
		var avg_height: float = (left_height + right_height) * 0.5

		# Calculate UV coordinates
		# U: 0 at left bank, 1 at right bank
		# V: accumulated distance along flow direction (for flow shader)
		var uv_v: float = accumulated_distance / width  # Normalize by width for consistent tiling

		# Create vertices for triangle strip (alternating left/right)
		var left_vertex := Vector3(left_pos.x, avg_height, left_pos.y)
		var right_vertex := Vector3(right_pos.x, avg_height, right_pos.y)

		# Add left vertex
		surface_tool.set_uv(Vector2(0.0, uv_v))
		surface_tool.set_normal(Vector3.UP)
		surface_tool.add_vertex(left_vertex)

		# Add right vertex
		surface_tool.set_uv(Vector2(1.0, uv_v))
		surface_tool.set_normal(Vector3.UP)
		surface_tool.add_vertex(right_vertex)

		# Accumulate distance for next point
		if i < path.size() - 1:
			accumulated_distance += point.distance_to(path[i + 1])

	# Generate tangents for normal mapping
	surface_tool.generate_tangents()

	# Commit mesh
	mesh = surface_tool.commit()

	# Apply water material
	if _water_material:
		material_override = _water_material


## Calculate perpendicular direction at a path point
## Returns normalized Vector2 perpendicular to the path direction
func _calculate_perpendicular(path: PackedVector2Array, index: int) -> Vector2:
	var direction: Vector2

	if index == 0:
		# First point: use direction to next point
		direction = (path[1] - path[0]).normalized()
	elif index == path.size() - 1:
		# Last point: use direction from previous point
		direction = (path[index] - path[index - 1]).normalized()
	else:
		# Middle points: average of incoming and outgoing directions
		var dir_in: Vector2 = (path[index] - path[index - 1]).normalized()
		var dir_out: Vector2 = (path[index + 1] - path[index]).normalized()
		direction = ((dir_in + dir_out) * 0.5).normalized()

	# Perpendicular is 90 degrees rotated (for right-hand rule in XZ plane)
	return Vector2(-direction.y, direction.x)


## Set a custom shader material (optional override)
func set_water_material(material: ShaderMaterial) -> void:
	_water_material = material
	if mesh:
		material_override = _water_material


## Get the currently applied water material
func get_water_material() -> ShaderMaterial:
	return _water_material


## Clear the mesh
func clear() -> void:
	mesh = null
