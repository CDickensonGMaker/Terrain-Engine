extends MeshInstance3D
class_name WaterStaticMesh
## Generates flat water surface mesh for ponds and lakes
## Uses polygon triangulation for irregular shorelines

## Water surface elevation
var water_elevation: float = 0.0

## Shore distance for alpha blending (stored in vertex color R)
var shore_fade_distance: float = 3.0

## Preload static water material
var _material: ShaderMaterial = null


func _init() -> void:
	# Setup material in _init so it's ready before build_from_cells is called
	_setup_material()


func _ready() -> void:
	# Ensure material is set up
	if not _material:
		_setup_material()


func _setup_material() -> void:
	var shader := preload("res://water/water_static.gdshader")
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.render_priority = 1  # Render after terrain


## Build mesh from polygon at specified elevation
func build_from_polygon(polygon: PackedVector2Array, elevation: float, heightmap: RefCounted = null) -> void:
	if polygon.size() < 3:
		push_error("[WaterStaticMesh] Polygon too small: %d points" % polygon.size())
		return

	water_elevation = elevation

	# Triangulate the polygon
	var indices: PackedInt32Array = Geometry2D.triangulate_polygon(polygon)
	if indices.size() == 0:
		push_warning("[WaterStaticMesh] Failed to triangulate polygon, trying convex hull")
		# Fall back to convex hull
		var hull := Geometry2D.convex_hull(polygon)
		indices = Geometry2D.triangulate_polygon(hull)
		if indices.size() == 0:
			push_error("[WaterStaticMesh] Could not triangulate polygon")
			return

	# Calculate centroid for shore distance
	var centroid := Vector2.ZERO
	for pt in polygon:
		centroid += pt
	centroid /= polygon.size()

	# Build mesh arrays
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()

	# Calculate bounds for UV mapping
	var min_pt := Vector2(INF, INF)
	var max_pt := Vector2(-INF, -INF)
	for pt in polygon:
		min_pt.x = minf(min_pt.x, pt.x)
		min_pt.y = minf(min_pt.y, pt.y)
		max_pt.x = maxf(max_pt.x, pt.x)
		max_pt.y = maxf(max_pt.y, pt.y)

	var bounds_size: Vector2 = max_pt - min_pt
	if bounds_size.x < 0.001:
		bounds_size.x = 1.0
	if bounds_size.y < 0.001:
		bounds_size.y = 1.0

	# Build vertices from polygon points
	for pt in polygon:
		# Y position is water elevation (slightly above terrain for visibility)
		var y_pos: float = elevation + 0.05

		vertices.append(Vector3(pt.x, y_pos, pt.y))
		normals.append(Vector3.UP)

		# UV mapping based on world position
		var uv := Vector2(
			(pt.x - min_pt.x) / bounds_size.x,
			(pt.y - min_pt.y) / bounds_size.y
		)
		uvs.append(uv)

		# Shore distance in vertex color R channel
		# Calculate distance to nearest edge
		var shore_dist: float = _distance_to_polygon_edge(pt, polygon)
		var normalized_shore: float = clampf(shore_dist / shore_fade_distance, 0.0, 1.0)
		colors.append(Color(normalized_shore, 0.0, 0.0, 1.0))

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

	# Apply material
	if _material:
		array_mesh.surface_set_material(0, _material)

	self.mesh = array_mesh


## Calculate distance from a point to the nearest polygon edge
func _distance_to_polygon_edge(point: Vector2, polygon: PackedVector2Array) -> float:
	var min_dist: float = INF

	for i in range(polygon.size()):
		var j: int = (i + 1) % polygon.size()
		var edge_start: Vector2 = polygon[i]
		var edge_end: Vector2 = polygon[j]

		var dist: float = _point_to_segment_distance(point, edge_start, edge_end)
		min_dist = minf(min_dist, dist)

	return min_dist


## Calculate distance from point to line segment
func _point_to_segment_distance(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> float:
	var seg: Vector2 = seg_end - seg_start
	var seg_len_sq: float = seg.length_squared()

	if seg_len_sq < 0.0001:
		return point.distance_to(seg_start)

	var t: float = clampf((point - seg_start).dot(seg) / seg_len_sq, 0.0, 1.0)
	var closest: Vector2 = seg_start + seg * t
	return point.distance_to(closest)


## Build mesh from a grid of cells.
## The water surface is a single FLAT horizontal plane at `elevation` (the pour level).
## Per-vertex water depth (elevation - terrain) goes in vertex color G; shore distance
## in R. This is what makes lakes read as flat blue water instead of stair-stepped slabs.
const DEPTH_NORM_RANGE: float = 4.0  # meters mapped to G = 1.0 (full "deep")

func build_from_cells(cells: Array[Vector2i], elevation: float, heightmap: RefCounted) -> void:
	if cells.size() < 1:
		push_error("[WaterStaticMesh] No cells provided")
		return

	# Ensure material is ready
	if not _material:
		_setup_material()

	water_elevation = elevation
	var cell_size: float = heightmap.cell_size
	var height_scale: float = heightmap.height_scale
	var hmap_size: int = heightmap.size

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

		# Shore distance (how many cells to the edge of the body)
		var shore_dist: float = _cell_distance_to_edge(cell, cell_set) * cell_size
		var normalized_shore: float = clampf(shore_dist / shore_fade_distance, 0.0, 1.0)

		# Four corners - flat surface at `elevation`, depth sampled from terrain.
		var corner_cells := [
			Vector2i(cell.x, cell.y),
			Vector2i(cell.x + 1, cell.y),
			Vector2i(cell.x + 1, cell.y + 1),
			Vector2i(cell.x, cell.y + 1)
		]
		var corner_uvs := [
			Vector2(0.0, 0.0),
			Vector2(1.0, 0.0),
			Vector2(1.0, 1.0),
			Vector2(0.0, 1.0)
		]

		for i in range(4):
			var ccx: int = clampi(corner_cells[i].x, 0, hmap_size - 1)
			var ccz: int = clampi(corner_cells[i].y, 0, hmap_size - 1)
			var corner_terrain: float = heightmap.get_cell(ccx, ccz) * height_scale
			var depth: float = maxf(0.0, elevation - corner_terrain)
			var normalized_depth: float = clampf(depth / DEPTH_NORM_RANGE, 0.0, 1.0)

			var corner_x: float = world_x + (cell_size if i == 1 or i == 2 else 0.0)
			var corner_z: float = world_z + (cell_size if i == 2 or i == 3 else 0.0)

			vertices.append(Vector3(corner_x, elevation, corner_z))
			normals.append(Vector3.UP)
			uvs.append(corner_uvs[i] + Vector2(cell.x, cell.y))  # Tile UVs
			colors.append(Color(normalized_shore, normalized_depth, 0.0, 1.0))

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
	else:
		push_warning("[WaterStaticMesh] Material not ready!")

	self.mesh = array_mesh


## Calculate cell distance to edge of water body
func _cell_distance_to_edge(cell: Vector2i, cell_set: Dictionary) -> int:
	# BFS to find distance to nearest non-water cell
	var dirs: Array[Vector2i] = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]

	for dist in range(1, 20):  # Max distance 20 cells
		for dir in dirs:
			var check: Vector2i = cell + dir * dist
			if not cell_set.has(check):
				return dist
	return 20


## Set water color
func set_water_color(color: Color) -> void:
	if _material:
		_material.set_shader_parameter("water_color", color)


## Set water color for deep areas
func set_water_color_deep(color: Color) -> void:
	if _material:
		_material.set_shader_parameter("water_color_deep", color)
