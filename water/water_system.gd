extends Node
class_name WaterSystem
## Central manager for all water bodies in the terrain
## Handles generation, tracking, and queries for water features

## Preload dependencies (must be before signals that use these types)
const WaterBodyDataClass := preload("res://water/water_body_data.gd")
const HydrologyMapClass := preload("res://water/hydrology_map.gd")
const RiverMeshClass := preload("res://water/river_mesh.gd")
const PondDetectorClass := preload("res://water/pond_detector.gd")
const WaterStaticMeshClass := preload("res://water/water_static_mesh.gd")
const WaterCoastalMeshClass := preload("res://water/water_coastal_mesh.gd")
const WaterSwampMeshClass := preload("res://water/water_swamp_mesh.gd")

signal water_generated
signal water_body_added(body: Resource)  # WaterBodyData

## All water bodies indexed by ID
var water_bodies: Dictionary = {}  # id -> WaterBodyData

## Spatial index: chunk coordinate -> array of water body IDs
var water_by_chunk: Dictionary = {}  # Vector2i -> Array[int]

## Global sea level in meters (for coastal generation)
var sea_level: float = 5.0

## Which map edges have ocean (bitmask: 1=North, 2=East, 4=South, 8=West)
## Set to 0 to disable coastal generation
var ocean_edges: int = 0b0000  # Disabled by default

## Enable swamp generation
var generate_swamps: bool = true

## Water type grid for O(1) lookups
## Each byte encodes: bits 0-2 = WaterType (0-6), bits 3-7 = depth_index (0-31)
var water_map: PackedByteArray = PackedByteArray()
var water_map_size: int = 0
var water_map_cell_size: float = 2.0

## Next available water body ID
var _next_id: int = 0

## Reference to heightmap for terrain queries
var _heightmap: RefCounted = null  # HeightmapStorage

## Last hydrology result (for water-level queries)
var _hydrology: RefCounted = null  # HydrologyMap

## Downsample factor for hydrology compute (0 = auto from map size)
var hydrology_downsample: int = 0

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


## Generate all water bodies from a single coherent hydrology pass.
## Water cascades from the peaks downhill: channels (creeks/rivers) form where flow
## concentrates, pools (ponds/lakes) form in depressions, swamps in flat wet lowland.
func generate_water_bodies() -> void:
	if not _heightmap:
		push_error("[WaterSystem] Cannot generate: no heightmap set")
		return

	var start_time := Time.get_ticks_msec()

	# Clear existing water bodies
	clear()

	# Run the unified hydrology model once.
	var hydro := HydrologyMapClass.new()
	hydro.downsample = _auto_downsample()
	hydro.ocean_edges = ocean_edges
	hydro.sea_level = sea_level
	hydro.generate(_heightmap)
	_hydrology = hydro

	# Rivers/creeks come out as flow-traced polylines.
	for river in hydro.rivers:
		_create_river_body(river["points"], river["widths"])

	# Ponds, lakes, swamps and coastal come out as connected cell groups.
	for b in hydro.extract_static_bodies(_heightmap):
		_create_static_body(b)

	# Build the O(1) lookup grid straight from the hydrology cell types.
	_build_water_map_from_hydrology(hydro)

	var elapsed := Time.get_ticks_msec() - start_time
	print("[WaterSystem] Generated %d water bodies in %dms (downsample %d)" % [
		water_bodies.size(), elapsed, hydro.downsample
	])

	water_generated.emit()


## Pick a hydrology compute resolution that keeps the flood/accumulation cheap.
func _auto_downsample() -> int:
	if hydrology_downsample > 0:
		return hydrology_downsample
	# Target roughly a 400-cell hydrology grid regardless of map size.
	return maxi(1, int(round(float(water_map_size) / 450.0)))


## Build a river/creek WaterBodyData from a flow-traced polyline.
func _create_river_body(points: PackedVector2Array, widths: PackedFloat32Array) -> void:
	if points.size() < 2:
		return

	var body := WaterBodyDataClass.new()
	body.id = _next_id
	_next_id += 1

	var avg_width: float = 0.0
	for w in widths:
		avg_width += w
	avg_width /= widths.size()

	body.type = WaterBodyDataClass.Type.CREEK if avg_width < 6.0 else WaterBodyDataClass.Type.RIVER
	body.path = points
	body.widths = widths
	body.depth = 1.0 if body.type == WaterBodyDataClass.Type.CREEK else 2.5

	var min_pt := Vector2(INF, INF)
	var max_pt := Vector2(-INF, -INF)
	for pt in points:
		min_pt.x = minf(min_pt.x, pt.x)
		min_pt.y = minf(min_pt.y, pt.y)
		max_pt.x = maxf(max_pt.x, pt.x)
		max_pt.y = maxf(max_pt.y, pt.y)
	var max_width: float = 0.0
	for w in widths:
		max_width = maxf(max_width, w)
	min_pt -= Vector2(max_width, max_width) * 0.5
	max_pt += Vector2(max_width, max_width) * 0.5
	body.bounds = Rect2(min_pt, max_pt - min_pt)

	body.flow_direction = (points[points.size() - 1] - points[0]).normalized()

	var total_elev: float = 0.0
	for pt in points:
		total_elev += _heightmap.sample_world(pt.x, pt.y)
	body.elevation = total_elev / points.size()

	_register_water_body(body)
	_generate_river_mesh(body)


## Build a pond/lake/swamp/coastal WaterBodyData from a hydrology cell group.
func _create_static_body(b: Dictionary) -> void:
	var cells: Array[Vector2i] = b["cells"]
	if cells.size() < 8:
		return  # Skip tiny fragments

	var type_code: int = b["type"]
	if type_code == WaterBodyDataClass.Type.SWAMP and not generate_swamps:
		return

	var body := WaterBodyDataClass.new()
	body.id = _next_id
	_next_id += 1

	# Standing fresh water splits into pond vs lake by area.
	var area: float = cells.size() * _heightmap.cell_size * _heightmap.cell_size
	if type_code == WaterBodyDataClass.Type.LAKE and area < 2500.0:
		body.type = WaterBodyDataClass.Type.POND
	else:
		body.type = type_code

	body.elevation = b["surface"]
	body.depth = b["depth"]
	body.bounds = b["bounds"]
	body.polygon = _cells_to_polygon(cells)

	_register_water_body(body)

	match body.type:
		WaterBodyDataClass.Type.COASTAL:
			_generate_coastal_mesh(body, cells)
		WaterBodyDataClass.Type.SWAMP:
			_generate_swamp_mesh(body, cells)
		_:
			_generate_static_mesh(body, cells)


## Build an outline polygon from a group of cells (for point-in-body queries).
func _cells_to_polygon(cells: Array[Vector2i]) -> PackedVector2Array:
	var detector := PondDetectorClass.new()
	detector._heightmap = _heightmap
	var dep := PondDetectorClass.Depression.new()
	dep.cells.assign(cells)
	var poly: PackedVector2Array = detector.cells_to_polygon(dep)
	if poly.size() >= 4:
		poly = detector.simplify_polygon(poly, _heightmap.cell_size * 2.0)
	return poly


## Generate mesh for a river/creek
func _generate_river_mesh(body: Resource) -> void:
	var river_mesh := RiverMeshClass.new()
	river_mesh.build_from_path(body.path, body.widths, _heightmap)

	body.mesh = river_mesh.mesh
	body.mesh_instance = river_mesh

	river_mesh.name = "River_%d" % body.id
	_water_container.add_child(river_mesh)


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


## Generate mesh for a coastal zone
func _generate_coastal_mesh(body: Resource, cells: Array) -> void:
	var coastal_mesh := WaterCoastalMeshClass.new()

	var typed_cells: Array[Vector2i] = []
	for cell in cells:
		typed_cells.append(cell)

	coastal_mesh.build_from_cells(typed_cells, body.elevation, _heightmap)

	body.mesh = coastal_mesh.mesh
	body.mesh_instance = coastal_mesh

	coastal_mesh.name = "Coastal_%d" % body.id
	_water_container.add_child(coastal_mesh)


## Generate mesh for a swamp zone
func _generate_swamp_mesh(body: Resource, cells: Array) -> void:
	var swamp_mesh := WaterSwampMeshClass.new()

	var typed_cells: Array[Vector2i] = []
	for cell in cells:
		typed_cells.append(cell)

	swamp_mesh.build_from_cells(typed_cells, body.elevation, _heightmap)

	body.mesh = swamp_mesh.mesh
	body.mesh_instance = swamp_mesh

	swamp_mesh.name = "Swamp_%d" % body.id
	_water_container.add_child(swamp_mesh)


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


## Build the O(1) lookup grid directly from hydrology cell types + surfaces.
func _build_water_map_from_hydrology(hydro: RefCounted) -> void:
	water_map.fill(0)

	var water_cells: int = 0
	var total_cells: int = water_map_size * water_map_size
	for i in range(total_cells):
		var t: int = hydro.water_type_full[i]
		if t == 0:
			continue
		var x: int = i % water_map_size
		var z: int = i / water_map_size
		var terrain: float = _heightmap.get_cell(x, z) * _heightmap.height_scale
		var depth: float = maxf(0.0, hydro.water_surface_full[i] - terrain)
		var depth_index: int = clampi(int(depth * 2.0), 0, 31)
		water_map[i] = t | (depth_index << 3)
		water_cells += 1

	var percent: float = 100.0 * water_cells / total_cells
	print("[WaterSystem] Water map: %d/%d cells (%.1f%%)" % [water_cells, total_cells, percent])


## Clear all water bodies
func clear() -> void:
	# Remove mesh instances
	for child in _water_container.get_children():
		child.queue_free()

	water_bodies.clear()
	water_by_chunk.clear()
	water_map.fill(0)
	_next_id = 0
	_hydrology = null


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


## Get the flat water-surface height (meters) at a world position.
## Returns -INF when there is no water there (callers should check is_water first).
func get_water_level_at(world_x: float, world_z: float) -> float:
	if not _hydrology:
		return -INF
	var cx: int = int(floor(world_x / water_map_cell_size))
	var cz: int = int(floor(world_z / water_map_cell_size))
	if cx < 0 or cx >= water_map_size or cz < 0 or cz >= water_map_size:
		return -INF
	var idx: int = cz * water_map_size + cx
	if _hydrology.water_type_full[idx] == 0:
		return -INF
	return _hydrology.water_surface_full[idx]


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


## Generate wetness texture for terrain shore blending
## Returns an ImageTexture with R = wetness (1 = water, fades to 0)
func generate_wetness_texture(fade_distance: float = 20.0) -> ImageTexture:
	# Create image matching water map size
	var img := Image.create(water_map_size, water_map_size, false, Image.FORMAT_R8)
	img.fill(Color(0, 0, 0, 1))

	# First pass: mark water cells
	for z in range(water_map_size):
		for x in range(water_map_size):
			if water_map[z * water_map_size + x] > 0:
				img.set_pixel(x, z, Color(1, 0, 0, 1))

	# Calculate distance in cells for fade
	var fade_cells: int = int(ceil(fade_distance / water_map_cell_size))

	# Second pass: expand wetness outward from water edges
	# Use a simple distance field approximation
	for dist in range(1, fade_cells + 1):
		var wetness: float = 1.0 - (float(dist) / float(fade_cells))
		wetness = wetness * wetness  # Square for smoother falloff

		for z in range(water_map_size):
			for x in range(water_map_size):
				# Skip if already has higher wetness
				if img.get_pixel(x, z).r >= wetness:
					continue

				# Check if any neighbor at dist-1 has wetness
				var has_wet_neighbor := false
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dz == 0:
							continue
						var nx: int = x + dx
						var nz: int = z + dz
						if nx >= 0 and nx < water_map_size and nz >= 0 and nz < water_map_size:
							var neighbor_wetness: float = img.get_pixel(nx, nz).r
							if neighbor_wetness > wetness:
								has_wet_neighbor = true
								break
					if has_wet_neighbor:
						break

				if has_wet_neighbor:
					img.set_pixel(x, z, Color(wetness, 0, 0, 1))

	# Create texture
	var tex := ImageTexture.create_from_image(img)
	print("[WaterSystem] Generated wetness texture: %dx%d, fade %.1fm" % [
		water_map_size, water_map_size, fade_distance
	])
	return tex


## Get distance to nearest water (in meters)
func get_distance_to_water(world_x: float, world_z: float) -> float:
	var cx: int = int(floor(world_x / water_map_cell_size))
	var cz: int = int(floor(world_z / water_map_cell_size))

	if cx < 0 or cx >= water_map_size or cz < 0 or cz >= water_map_size:
		return INF

	# If in water, distance is 0
	if water_map[cz * water_map_size + cx] > 0:
		return 0.0

	# Search outward for nearest water
	var max_search: int = 30  # ~60m at 2m cells
	for dist in range(1, max_search + 1):
		for dz in range(-dist, dist + 1):
			for dx in range(-dist, dist + 1):
				if abs(dx) != dist and abs(dz) != dist:
					continue  # Only check perimeter

				var nx: int = cx + dx
				var nz: int = cz + dz
				if nx >= 0 and nx < water_map_size and nz >= 0 and nz < water_map_size:
					if water_map[nz * water_map_size + nx] > 0:
						return sqrt(dx * dx + dz * dz) * water_map_cell_size

	return INF


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


## Get water stats as dictionary
func get_stats() -> Dictionary:
	var stats := {
		"total": water_bodies.size(),
		"rivers": 0,
		"creeks": 0,
		"ponds": 0,
		"lakes": 0,
		"swamps": 0,
		"coastal": false
	}

	for body in water_bodies.values():
		match body.type:
			1:  # Creek
				stats["creeks"] += 1
			2:  # River
				stats["rivers"] += 1
			3:  # Pond
				stats["ponds"] += 1
			4:  # Lake
				stats["lakes"] += 1
			5:  # Swamp
				stats["swamps"] += 1
			6:  # Coastal
				stats["coastal"] = true

	return stats
