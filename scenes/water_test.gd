extends Node3D
## Water Test Scene - Small terrain strip for testing all water types
## Quick loading, shows rivers, ponds, lakes, coastal, and swamps

const TerrainManagerClass := preload("res://core/terrain_manager.gd")
const TerrainChunkClass := preload("res://core/terrain_chunk.gd")
const WaterSystemClass := preload("res://water/water_system.gd")
const WaterBodyDataClass := preload("res://water/water_body_data.gd")
const WaterStaticMeshClass := preload("res://water/water_static_mesh.gd")

@onready var camera_rig: Node3D = $CameraRig
@onready var spring_arm: SpringArm3D = $CameraRig/SpringArm3D
@onready var camera: Camera3D = $CameraRig/SpringArm3D/Camera3D
@onready var loading_label: Label = $LoadingUI/LoadingLabel
@onready var loading_ui: Control = $LoadingUI
@onready var info_label: Label = $InfoUI/InfoLabel

var terrain_manager: Node3D
var water_system: Node
var terrain_engine: Node

# Camera
var zoom_target: float = 150.0
var current_tilt: float = -55.0
var is_rotating: bool = false
var last_mouse_pos: Vector2

func _ready() -> void:
	terrain_engine = get_node_or_null("/root/TerrainEngine")

	# Create small terrain manager
	terrain_manager = TerrainManagerClass.new()
	terrain_manager.name = "TerrainManager"
	terrain_manager.map_size = 512.0      # 512m x 512m - fast loading
	terrain_manager.chunk_size = 128.0    # 4 chunks (2x2)
	terrain_manager.cell_size = 2.0       # 2m resolution
	terrain_manager.load_distance = 2
	terrain_manager.unload_distance = 3
	terrain_manager.rivers_enabled = true
	add_child(terrain_manager)

	# Create water system
	water_system = WaterSystemClass.new()
	water_system.name = "WaterSystem"
	add_child(water_system)

	# Connect signals
	terrain_manager.terrain_ready.connect(_on_terrain_ready)
	terrain_manager.generation_progress.connect(_on_generation_progress)

	# Setup default textures
	_setup_default_shader_textures()

	# Generate
	loading_ui.visible = true
	call_deferred("_generate_terrain")


func _setup_default_shader_textures() -> void:
	var default_height := Image.create(4, 4, false, Image.FORMAT_RF)
	default_height.fill(Color(0.5, 0.5, 0.5, 1.0))
	var height_tex := ImageTexture.create_from_image(default_height)

	var default_veg := Image.create(4, 4, false, Image.FORMAT_RF)
	default_veg.fill(Color(1.0, 1.0, 1.0, 1.0))
	var veg_tex := ImageTexture.create_from_image(default_veg)

	var default_clear := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	default_clear.fill(Color(0, 0, 0, 0))
	var clear_tex := ImageTexture.create_from_image(default_clear)

	TerrainChunkClass._create_shared_material()

	var params := {
		"heightmap": height_tex,
		"vegetation_texture": veg_tex,
		"clearing_texture": clear_tex,
		"terrain_size": 257,
		"cell_size": 2.0,
		"height_scale": 80.0
	}
	TerrainChunkClass.set_shader_parameters(params)


func _generate_terrain() -> void:
	print("[WaterTest] Generating 512m x 512m test terrain...")

	if terrain_engine:
		# Use rolling hills for varied terrain
		terrain_engine.set_preset(0)  # ROLLING_HILLS
		terrain_engine.height_scale = 80.0  # Lower for smaller map

	await terrain_manager.generate_terrain()


func _on_generation_progress(stage: String, percent: float) -> void:
	loading_label.text = "%s... %.0f%%" % [stage, percent * 100]


func _on_terrain_ready() -> void:
	print("[WaterTest] Terrain ready!")
	loading_ui.visible = false

	# Carve water features into the terrain for testing
	_carve_water_features()

	# Rebuild terrain chunks to show carved areas
	_rebuild_all_chunks()

	_setup_camera()
	_setup_terrain_shader()
	_generate_water()
	_update_info()


## Gently lower south edge for coastal water
func _carve_water_features() -> void:
	var heightmap = terrain_manager.heightmap
	var size: int = heightmap.size
	var height_scale: float = heightmap.height_scale

	print("[WaterTest] Preparing terrain for water features...")

	# Only gently lower the south edge for coastal - don't carve huge holes
	var coastal_height: float = 25.0 / height_scale
	for z in range(int(size * 0.85), size):
		var blend: float = float(z - int(size * 0.85)) / (size * 0.15)
		for x in range(size):
			var current: float = heightmap.get_cell(x, z)
			# Only lower if terrain is above sea level
			if current > coastal_height:
				var target: float = lerpf(current, coastal_height, blend * 0.7)
				heightmap.set_cell(x, z, target)

	print("[WaterTest] Lowered south edge for coastal")


## Rebuild all terrain chunks after heightmap modification
func _rebuild_all_chunks() -> void:
	for chunk in terrain_manager.chunks.values():
		if chunk and chunk.has_method("rebuild_mesh"):
			chunk.rebuild_mesh()
	print("[WaterTest] Rebuilt %d chunks" % terrain_manager.chunks.size())


func _setup_camera() -> void:
	var center := Vector3(256.0, 50.0, 256.0)
	camera_rig.position = center
	spring_arm.spring_length = zoom_target
	spring_arm.rotation_degrees.x = current_tilt
	terrain_manager.set_camera(camera)


func _setup_terrain_shader() -> void:
	if not TerrainChunkClass.is_using_shader():
		return

	var params := {}
	if terrain_manager and terrain_manager.heightmap:
		var heightmap_tex: ImageTexture = terrain_manager.heightmap.get_texture()
		if heightmap_tex:
			params["heightmap"] = heightmap_tex

	params["terrain_size"] = terrain_manager.heightmap.size if terrain_manager.heightmap else 257
	params["cell_size"] = terrain_manager.cell_size
	params["height_scale"] = terrain_manager.height_scale

	TerrainChunkClass.set_shader_parameters(params)


func _generate_water() -> void:
	if not water_system:
		return

	water_system.initialize(terrain_manager.heightmap, terrain_manager.chunk_size)

	# Unified hydrology pass: rivers cascade from the peaks, pools form in depressions.
	water_system.ocean_edges = 0b0100  # South edge coastal
	water_system.sea_level = 30.0
	water_system.generate_swamps = true
	water_system.generate_water_bodies()

	# Safety net: if the terrain happens to have no closed basins, drop in a test pool.
	var stats: Dictionary = water_system.get_stats()
	if stats.get("ponds", 0) == 0 and stats.get("lakes", 0) == 0:
		_create_manual_pond()
		_create_manual_lake()

	water_system.print_stats()

	# Shore blending
	var wetness_tex: ImageTexture = water_system.generate_wetness_texture(8.0)
	if wetness_tex:
		TerrainChunkClass.set_shader_texture("wetness_texture", wetness_tex)


## Manually create a test pond at northwest
## Samples actual terrain to find a suitable low point
func _create_manual_pond() -> void:
	var heightmap = terrain_manager.heightmap
	var cell_size: float = heightmap.cell_size
	var height_scale: float = heightmap.height_scale
	var size: int = heightmap.size

	# Search for a local minimum in the northwest quadrant
	var search_start := Vector2i(int(size * 0.15), int(size * 0.15))
	var search_end := Vector2i(int(size * 0.35), int(size * 0.35))

	var min_height: float = INF
	var min_pos := Vector2i.ZERO
	for z in range(search_start.y, search_end.y, 4):
		for x in range(search_start.x, search_end.x, 4):
			var h: float = heightmap.get_cell(x, z)
			if h < min_height:
				min_height = h
				min_pos = Vector2i(x, z)

	if min_height == INF:
		print("[WaterTest] No suitable pond location found")
		return

	# Water surface = minimum terrain + small pond depth
	var pond_depth: float = 2.0
	var water_surface: float = min_height * height_scale + pond_depth

	# Collect cells where terrain is below water surface
	var radius: int = int(size * 0.06)
	var cells: Array[Vector2i] = []
	for z in range(min_pos.y - radius, min_pos.y + radius):
		for x in range(min_pos.x - radius, min_pos.x + radius):
			if x < 0 or x >= size or z < 0 or z >= size:
				continue
			var dist: float = Vector2(x, z).distance_to(Vector2(min_pos))
			if dist >= radius:
				continue
			# Only include cells below water surface
			var terrain_h: float = heightmap.get_cell(x, z) * height_scale
			if terrain_h < water_surface:
				cells.append(Vector2i(x, z))

	if cells.size() < 10:
		print("[WaterTest] Pond area too small: %d cells" % cells.size())
		return

	# Create water body data
	var body := WaterBodyDataClass.new()
	body.id = 100
	body.type = WaterBodyDataClass.Type.POND
	body.elevation = water_surface
	body.depth = pond_depth

	# Calculate bounds
	var world_center := Vector2(min_pos.x * cell_size, min_pos.y * cell_size)
	var world_radius: float = radius * cell_size
	body.bounds = Rect2(world_center.x - world_radius, world_center.y - world_radius,
		world_radius * 2, world_radius * 2)

	# Create circular polygon
	body.polygon = PackedVector2Array()
	for i in range(16):
		var angle: float = i * TAU / 16.0
		body.polygon.append(world_center + Vector2(cos(angle), sin(angle)) * world_radius)

	# Register with water system
	water_system.water_bodies[body.id] = body

	# Create mesh
	var static_mesh := WaterStaticMeshClass.new()
	static_mesh.build_from_cells(cells, water_surface, heightmap)
	static_mesh.name = "Pond_Manual"
	body.mesh = static_mesh.mesh
	body.mesh_instance = static_mesh
	water_system.get_node("WaterBodies").add_child(static_mesh)

	print("[WaterTest] Created pond at height %.1fm with %d cells" % [water_surface, cells.size()])


## Manually create a test lake at northeast
## Samples actual terrain to find a suitable low point
func _create_manual_lake() -> void:
	var heightmap = terrain_manager.heightmap
	var cell_size: float = heightmap.cell_size
	var height_scale: float = heightmap.height_scale
	var size: int = heightmap.size

	# Search for a local minimum in the northeast quadrant
	var search_start := Vector2i(int(size * 0.60), int(size * 0.15))
	var search_end := Vector2i(int(size * 0.85), int(size * 0.40))

	var min_height: float = INF
	var min_pos := Vector2i.ZERO
	for z in range(search_start.y, search_end.y, 4):
		for x in range(search_start.x, search_end.x, 4):
			var h: float = heightmap.get_cell(x, z)
			if h < min_height:
				min_height = h
				min_pos = Vector2i(x, z)

	if min_height == INF:
		print("[WaterTest] No suitable lake location found")
		return

	# Water surface = minimum terrain + lake depth
	var lake_depth: float = 4.0
	var water_surface: float = min_height * height_scale + lake_depth

	# Collect cells where terrain is below water surface (larger radius for lake)
	var radius: int = int(size * 0.10)
	var cells: Array[Vector2i] = []
	for z in range(min_pos.y - radius, min_pos.y + radius):
		for x in range(min_pos.x - radius, min_pos.x + radius):
			if x < 0 or x >= size or z < 0 or z >= size:
				continue
			var dist: float = Vector2(x, z).distance_to(Vector2(min_pos))
			if dist >= radius:
				continue
			# Only include cells below water surface
			var terrain_h: float = heightmap.get_cell(x, z) * height_scale
			if terrain_h < water_surface:
				cells.append(Vector2i(x, z))

	if cells.size() < 10:
		print("[WaterTest] Lake area too small: %d cells" % cells.size())
		return

	# Create water body data
	var body := WaterBodyDataClass.new()
	body.id = 101
	body.type = WaterBodyDataClass.Type.LAKE
	body.elevation = water_surface
	body.depth = lake_depth

	# Calculate bounds
	var world_center := Vector2(min_pos.x * cell_size, min_pos.y * cell_size)
	var world_radius: float = radius * cell_size
	body.bounds = Rect2(world_center.x - world_radius, world_center.y - world_radius,
		world_radius * 2, world_radius * 2)

	# Create circular polygon
	body.polygon = PackedVector2Array()
	for i in range(20):
		var angle: float = i * TAU / 20.0
		body.polygon.append(world_center + Vector2(cos(angle), sin(angle)) * world_radius)

	# Register with water system
	water_system.water_bodies[body.id] = body

	# Create mesh
	var static_mesh := WaterStaticMeshClass.new()
	static_mesh.build_from_cells(cells, water_surface, heightmap)
	static_mesh.name = "Lake_Manual"
	body.mesh = static_mesh.mesh
	body.mesh_instance = static_mesh
	water_system.get_node("WaterBodies").add_child(static_mesh)

	print("[WaterTest] Created lake at height %.1fm with %d cells" % [water_surface, cells.size()])


func _update_info() -> void:
	if not info_label or not water_system:
		return

	var stats: Dictionary = water_system.get_stats()
	var text := "WATER TEST SCENE\n"
	text += "Map: 512m x 512m\n"
	text += "─────────────────\n"
	text += "Rivers: %d\n" % stats.get("rivers", 0)
	text += "Creeks: %d\n" % stats.get("creeks", 0)
	text += "Ponds: %d\n" % stats.get("ponds", 0)
	text += "Lakes: %d\n" % stats.get("lakes", 0)
	text += "Swamps: %d\n" % stats.get("swamps", 0)
	text += "Coastal: %s\n" % ("Yes" if stats.get("coastal", false) else "No")
	text += "─────────────────\n"
	text += "[R] Regenerate\n"
	text += "[WASD] Move camera\n"
	text += "[Scroll] Zoom"

	info_label.text = text


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_target = max(20.0, zoom_target - 15.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_target = min(500.0, zoom_target + 15.0)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			is_rotating = event.pressed
			last_mouse_pos = event.position

	if event is InputEventMouseMotion and is_rotating:
		var delta = event.position - last_mouse_pos
		camera_rig.rotate_y(-delta.x * 0.01)
		current_tilt += delta.y * 0.5
		current_tilt = clamp(current_tilt, -85.0, -15.0)
		spring_arm.rotation_degrees.x = current_tilt
		last_mouse_pos = event.position

	if event.is_action_pressed("regenerate_terrain"):
		_regenerate()


func _process(delta: float) -> void:
	spring_arm.spring_length = lerp(spring_arm.spring_length, zoom_target, delta * 8.0)
	_handle_pan(delta)

	if terrain_manager and terrain_manager.is_ready:
		var terrain_height: float = terrain_manager.get_height_at(camera_rig.position)
		var min_y: float = terrain_height + 5.0
		if camera_rig.position.y < min_y:
			camera_rig.position.y = min_y


func _handle_pan(delta: float) -> void:
	var move := Vector3.ZERO

	if Input.is_action_pressed("camera_forward") or Input.is_action_pressed("ui_up"):
		move.z -= 1
	if Input.is_action_pressed("camera_back") or Input.is_action_pressed("ui_down"):
		move.z += 1
	if Input.is_action_pressed("camera_left") or Input.is_action_pressed("ui_left"):
		move.x -= 1
	if Input.is_action_pressed("camera_right") or Input.is_action_pressed("ui_right"):
		move.x += 1

	if move != Vector3.ZERO:
		var speed_mult := spring_arm.spring_length / 100.0
		var pan := (camera_rig.basis * move).normalized() * 25.0 * speed_mult * delta
		pan.y = 0

		var new_pos := camera_rig.position + pan
		new_pos.x = clampf(new_pos.x, 0.0, 512.0)
		new_pos.z = clampf(new_pos.z, 0.0, 512.0)
		camera_rig.position = new_pos


func _regenerate() -> void:
	print("[WaterTest] Regenerating...")
	loading_ui.visible = true

	if water_system:
		water_system.clear()

	await terrain_manager.generate_terrain()
