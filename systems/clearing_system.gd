extends Node
## Clearing System - Jungle clearing with progressive stages
## Handles vegetation removal and terrain flattening for firebase construction

signal clearing_started(zone_id: int, position: Vector3)
signal clearing_progress(zone_id: int, progress: float)
signal clearing_completed(zone_id: int)
signal vegetation_updated(region: Rect2i)

enum ClearingStage {
	JUNGLE,              # Full vegetation
	PARTIALLY_CLEARED,   # Trees down, stumps remain
	CLEARED,             # Open ground
	FORTIFIED,           # Flattened and prepared
}

# Clearing zone data
class ClearingZone:
	var id: int
	var center: Vector3
	var radius: float
	var stage: ClearingStage = ClearingStage.JUNGLE
	var progress: float = 0.0  # 0-1 within current stage
	var shape: String = "circle"  # "circle" or "rectangle"
	var rect_size: Vector2 = Vector2.ZERO  # For rectangular zones

# Stage visual parameters
const STAGE_PARAMS: Dictionary = {
	ClearingStage.JUNGLE: {
		"vegetation_density": 1.0,
		"height_flattening": 0.0,
		"ground_color": Color(0.12, 0.28, 0.08),  # Dense jungle green
		"tree_scale": 1.0,
	},
	ClearingStage.PARTIALLY_CLEARED: {
		"vegetation_density": 0.25,
		"height_flattening": 0.2,
		"ground_color": Color(0.3, 0.25, 0.15),  # Muddy brown-green
		"tree_scale": 0.3,  # Stumps only
	},
	ClearingStage.CLEARED: {
		"vegetation_density": 0.05,
		"height_flattening": 0.7,
		"ground_color": Color(0.45, 0.38, 0.28),  # Exposed dirt
		"tree_scale": 0.0,
	},
	ClearingStage.FORTIFIED: {
		"vegetation_density": 0.0,
		"height_flattening": 1.0,
		"ground_color": Color(0.52, 0.45, 0.35),  # Packed earth
		"tree_scale": 0.0,
	},
}

# Active clearing zones
var zones: Dictionary = {}  # id -> ClearingZone
var next_zone_id: int = 0

# Vegetation density map
var vegetation_map: Image
var vegetation_size: int = 512

# Clearing overlay texture
var clearing_texture: Image

# Reference to terrain manager (set by terrain_lab)
var terrain_manager: Node


func _ready() -> void:
	_init_vegetation_map()


## Set terrain manager reference (called by terrain_lab)
func set_terrain_manager(manager: Node) -> void:
	terrain_manager = manager


func _init_vegetation_map() -> void:
	vegetation_map = Image.create(vegetation_size, vegetation_size, false, Image.FORMAT_RF)
	vegetation_map.fill(Color(1.0, 1.0, 1.0, 1.0))  # Full vegetation

	clearing_texture = Image.create(vegetation_size, vegetation_size, false, Image.FORMAT_RGBA8)
	clearing_texture.fill(Color(0, 0, 0, 0))


## Create a new clearing zone
func create_zone(center: Vector3, radius: float, shape: String = "circle", rect_size: Vector2 = Vector2.ZERO) -> int:
	var zone := ClearingZone.new()
	zone.id = next_zone_id
	zone.center = center
	zone.radius = radius
	zone.shape = shape
	zone.rect_size = rect_size if shape == "rectangle" else Vector2.ZERO

	zones[zone.id] = zone
	next_zone_id += 1

	clearing_started.emit(zone.id, center)
	return zone.id


## Advance clearing progress
func advance_clearing(zone_id: int, amount: float) -> void:
	if not zones.has(zone_id):
		return

	var zone: ClearingZone = zones[zone_id]
	zone.progress += amount

	# Check for stage advancement
	if zone.progress >= 1.0:
		zone.progress = 0.0
		if zone.stage < ClearingStage.FORTIFIED:
			zone.stage = zone.stage + 1 as ClearingStage
			_apply_stage_changes(zone)

			if zone.stage == ClearingStage.FORTIFIED:
				clearing_completed.emit(zone_id)
		else:
			zone.progress = 1.0

	clearing_progress.emit(zone_id, _get_total_progress(zone))
	_update_vegetation_map(zone)


## Set zone directly to a stage (for testing)
func set_zone_stage(zone_id: int, stage: ClearingStage) -> void:
	if not zones.has(zone_id):
		return

	var zone: ClearingZone = zones[zone_id]
	zone.stage = stage
	zone.progress = 0.0

	_apply_stage_changes(zone)
	_update_vegetation_map(zone)


## Apply terrain modifications for current stage
func _apply_stage_changes(zone: ClearingZone) -> void:
	if not terrain_manager:
		push_warning("ClearingSystem: TerrainManager not set")
		return

	var params: Dictionary = STAGE_PARAMS[zone.stage]
	var flattening: float = params.height_flattening

	if flattening <= 0.0:
		return

	# Calculate target height (average of zone)
	var cell_size: float = terrain_manager.cell_size
	var heightmap = terrain_manager.heightmap
	var center := Vector2i(
		int(zone.center.x / cell_size),
		int(zone.center.z / cell_size)
	)
	var radius_cells: int = int(zone.radius / cell_size)

	# Find average height in zone
	var total_height: float = 0.0
	var count: int = 0

	for y in range(max(0, center.y - radius_cells), min(heightmap.size, center.y + radius_cells)):
		for x in range(max(0, center.x - radius_cells), min(heightmap.size, center.x + radius_cells)):
			if _is_in_zone(zone, x, y, center, radius_cells):
				total_height += heightmap.get_cell(x, y)
				count += 1

	if count == 0:
		return

	var target_height: float = total_height / float(count)

	# Apply flattening via terrain_manager (this also rebuilds chunks)
	var flatten_func := func(current_height: float, falloff_amount: float) -> float:
		var blend: float = flattening * falloff_amount
		return lerp(current_height, target_height, blend)

	terrain_manager.modify_terrain(zone.center, zone.radius, flatten_func)


## Check if heightmap cell is within zone
func _is_in_zone(zone: ClearingZone, x: int, y: int, center: Vector2i, radius_cells: int) -> bool:
	if zone.shape == "rectangle" and terrain_manager:
		var half_w: int = int(zone.rect_size.x / (terrain_manager.cell_size * 2))
		var half_h: int = int(zone.rect_size.y / (terrain_manager.cell_size * 2))
		return abs(x - center.x) <= half_w and abs(y - center.y) <= half_h
	else:
		var dist: float = Vector2(x - center.x, y - center.y).length()
		return dist <= radius_cells


## Update vegetation density map
func _update_vegetation_map(zone: ClearingZone) -> void:
	if not terrain_manager:
		return

	var params: Dictionary = STAGE_PARAMS[zone.stage]
	var density: float = params.vegetation_density
	var ground_color: Color = params.ground_color

	var scale: float = float(vegetation_size) / terrain_manager.map_size

	var tex_center := Vector2i(
		int(zone.center.x * scale),
		int(zone.center.z * scale)
	)
	var tex_radius: int = int(zone.radius * scale) + 1

	for y in range(max(0, tex_center.y - tex_radius), min(vegetation_size, tex_center.y + tex_radius)):
		for x in range(max(0, tex_center.x - tex_radius), min(vegetation_size, tex_center.x + tex_radius)):
			var in_zone: bool = false

			if zone.shape == "rectangle":
				var half_w: int = int(zone.rect_size.x * scale * 0.5)
				var half_h: int = int(zone.rect_size.y * scale * 0.5)
				in_zone = abs(x - tex_center.x) <= half_w and abs(y - tex_center.y) <= half_h
			else:
				var dist: float = Vector2(x - tex_center.x, y - tex_center.y).length()
				in_zone = dist <= tex_radius

			if in_zone:
				# Calculate falloff at edges
				var edge_dist: float
				if zone.shape == "rectangle":
					var half_w: float = zone.rect_size.x * scale * 0.5
					var half_h: float = zone.rect_size.y * scale * 0.5
					var dx: float = abs(x - tex_center.x)
					var dy: float = abs(y - tex_center.y)
					edge_dist = min((half_w - dx) / (half_w * 0.2), (half_h - dy) / (half_h * 0.2))
				else:
					var dist: float = Vector2(x - tex_center.x, y - tex_center.y).length()
					edge_dist = (tex_radius - dist) / (tex_radius * 0.2)

				var falloff: float = clampf(edge_dist, 0.0, 1.0)

				# Update vegetation density
				var current_density: float = vegetation_map.get_pixel(x, y).r
				var new_density: float = lerp(current_density, density, falloff)
				vegetation_map.set_pixel(x, y, Color(new_density, new_density, new_density, 1.0))

				# Update clearing color overlay
				var current_color: Color = clearing_texture.get_pixel(x, y)
				var alpha: float = (1.0 - density) * falloff
				var new_color := Color(
					lerp(current_color.r, ground_color.r, alpha),
					lerp(current_color.g, ground_color.g, alpha),
					lerp(current_color.b, ground_color.b, alpha),
					max(current_color.a, alpha)
				)
				clearing_texture.set_pixel(x, y, new_color)

	vegetation_updated.emit(Rect2i(tex_center - Vector2i(tex_radius, tex_radius),
								  Vector2i(tex_radius * 2, tex_radius * 2)))


func _get_total_progress(zone: ClearingZone) -> float:
	var stage_progress: float = float(zone.stage) / float(ClearingStage.FORTIFIED)
	var within_stage: float = zone.progress / float(ClearingStage.FORTIFIED)
	return stage_progress + within_stage


## Get vegetation density at world position (0-1)
func get_vegetation_density(world_pos: Vector3) -> float:
	if not terrain_manager:
		return 1.0

	var scale: float = float(vegetation_size) / terrain_manager.map_size
	var x: int = clampi(int(world_pos.x * scale), 0, vegetation_size - 1)
	var y: int = clampi(int(world_pos.z * scale), 0, vegetation_size - 1)

	return vegetation_map.get_pixel(x, y).r


## Get vegetation texture for terrain material
func get_vegetation_texture() -> ImageTexture:
	return ImageTexture.create_from_image(vegetation_map)


## Get clearing color overlay texture
func get_clearing_texture() -> ImageTexture:
	return ImageTexture.create_from_image(clearing_texture)


## Remove a clearing zone
func remove_zone(zone_id: int) -> void:
	zones.erase(zone_id)


## Clear all zones (for testing reset)
func clear_all_zones() -> void:
	zones.clear()
	vegetation_map.fill(Color(1.0, 1.0, 1.0, 1.0))
	clearing_texture.fill(Color(0, 0, 0, 0))
	vegetation_updated.emit(Rect2i(Vector2i.ZERO, Vector2i(vegetation_size, vegetation_size)))
