extends Node3D
## Terrain Lab - Main testing scene controller for large-scale terrain
## Controls: WASD - camera, Mouse Wheel - zoom, R - regenerate, T - wireframe
## Middle Mouse - rotate, F1-F4 - camera presets

# Preload class scripts
const TerrainManagerClass := preload("res://core/terrain_manager.gd")
const TerrainChunkClass := preload("res://core/terrain_chunk.gd")
const VegetationManagerClass := preload("res://vegetation/vegetation_manager.gd")
const BillboardVegetationClass := preload("res://vegetation/billboard_vegetation.gd")
const PoissonSamplerClass := preload("res://vegetation/poisson_sampler.gd")
const EngineeringSystemClass := preload("res://systems/engineering_system.gd")
const TerrainVFXClass := preload("res://systems/terrain_vfx.gd")
const QualitySettingsClass := preload("res://core/quality_settings.gd")
const GameplayGridClass := preload("res://core/gameplay_grid.gd")
# FogOfWarClass removed for performance optimization
const ConstructionMarkersClass := preload("res://systems/construction_markers.gd")
const WaterSystemClass := preload("res://water/water_system.gd")

@onready var camera_rig: Node3D = $CameraRig
@onready var spring_arm: SpringArm3D = $CameraRig/SpringArm3D
@onready var camera: Camera3D = $CameraRig/SpringArm3D/Camera3D
@onready var ui: Control = $UI
@onready var loading_label: Label = $LoadingUI/LoadingLabel
@onready var loading_ui: Control = $LoadingUI

# Terrain systems
var terrain_manager: Node3D  # TerrainManager
var vegetation_manager: Node3D  # VegetationManager
var billboard_vegetation: Node3D  # BillboardVegetation
var quality_settings: Node  # QualitySettings

# Camera settings (RTS style from BP Dark Shadows)
var pan_speed: float = 50.0
var zoom_min: float = 30.0       # Close view
var zoom_max: float = 1500.0     # Overview for 3km map
var zoom_speed: float = 30.0
var rotate_speed: float = 2.0
var tilt_speed: float = 1.5
var min_tilt: float = -85.0      # Almost straight down
var max_tilt: float = -15.0      # Shallow angle

var zoom_target: float = 300.0   # Start zoomed out
var current_tilt: float = -55.0
var current_yaw: float = 0.0
var is_rotating: bool = false
var last_mouse_pos: Vector2

# Terrain-following camera
var min_camera_height: float = 6.0  # Minimum height above terrain (4-8m range)

# Camera presets: [tilt, zoom, name]
const CAMERA_PRESETS: Array = [
	[-55.0, 300.0, "Overview"],      # F1: Default terrain view
	[-85.0, 1200.0, "Top Down"],     # F2: Map view (3km visible)
	[-35.0, 150.0, "Standard"],      # F3: RTS view
	[-20.0, 60.0, "Action"],         # F4: Close action
]

# Interaction modes
enum InteractionMode { DAMAGE, ENGINEERING }
var interaction_mode: InteractionMode = InteractionMode.DAMAGE
var current_damage_type: int = 1
var current_engineering_op: int = 0  # EngineeringSystem.OperationType
var clearing_mode: bool = false

# Systems (autoloads)
var terrain_engine: Node
var damage_system: Node
var clearing_system: Node

# Local systems
var engineering_system: Node
var terrain_vfx: Node
var construction_markers: Node
var gameplay_grid: RefCounted  # GameplayGrid for efficient game logic queries
var water_system: Node  # WaterSystem for rivers, ponds, lakes, coastal


func _ready() -> void:
	terrain_engine = get_node_or_null("/root/TerrainEngine")
	damage_system = get_node_or_null("/root/DamageSystem")
	clearing_system = get_node_or_null("/root/ClearingSystem")

	# Create terrain manager
	terrain_manager = TerrainManagerClass.new()
	terrain_manager.name = "TerrainManager"
	terrain_manager.map_size = 3000.0  # 3km x 3km (Steel Division scale)
	terrain_manager.chunk_size = 256.0
	terrain_manager.cell_size = 4.0    # 4m resolution (optimized for performance)
	terrain_manager.load_distance = 2
	terrain_manager.unload_distance = 3
	add_child(terrain_manager)

	# Create vegetation manager
	vegetation_manager = VegetationManagerClass.new()
	vegetation_manager.name = "VegetationManager"
	add_child(vegetation_manager)

	# Create billboard vegetation system
	billboard_vegetation = BillboardVegetationClass.new()
	billboard_vegetation.name = "BillboardVegetation"
	add_child(billboard_vegetation)

	# Create quality settings
	quality_settings = QualitySettingsClass.new()
	quality_settings.name = "QualitySettings"
	add_child(quality_settings)

	# Create engineering system
	engineering_system = EngineeringSystemClass.new()
	engineering_system.name = "EngineeringSystem"
	add_child(engineering_system)

	# Create VFX system
	terrain_vfx = TerrainVFXClass.new()
	terrain_vfx.name = "TerrainVFX"
	add_child(terrain_vfx)

	# Create construction markers
	construction_markers = ConstructionMarkersClass.new()
	construction_markers.name = "ConstructionMarkers"
	add_child(construction_markers)

	# Create water system
	water_system = WaterSystemClass.new()
	water_system.name = "WaterSystem"
	add_child(water_system)

	# Connect signals
	terrain_manager.terrain_ready.connect(_on_terrain_ready)
	terrain_manager.generation_progress.connect(_on_generation_progress)
	terrain_manager.chunk_loaded.connect(_on_chunk_loaded)

	_connect_ui()

	# IMPORTANT: Set up default shader textures BEFORE terrain generation
	# This prevents white terrain from unbound texture samplers
	_setup_default_shader_textures()

	# Start terrain generation
	loading_ui.visible = true
	call_deferred("_generate_initial_terrain")


func _setup_camera() -> void:
	# Position camera rig at center of playable area
	var bounds: Rect2 = terrain_manager.get_playable_bounds()
	var center_x: float = bounds.position.x + bounds.size.x / 2.0
	var center_z: float = bounds.position.y + bounds.size.y / 2.0
	var terrain_center := Vector3(center_x, 150, center_z)
	camera_rig.position = terrain_center

	# Set spring arm properties
	spring_arm.spring_length = zoom_target
	spring_arm.rotation_degrees.x = current_tilt

	# Set camera reference for streaming
	terrain_manager.set_camera(camera)

	print("[TerrainLab] Camera at %s, zoom %.0f, tilt %.0f" % [terrain_center, zoom_target, current_tilt])


## Setup environment (fog disabled for clarity)
func _setup_jungle_fog() -> void:
	var world_env := get_node_or_null("WorldEnvironment")
	if not world_env or not world_env.environment:
		print("[TerrainLab] WorldEnvironment not found")
		return

	var env: Environment = world_env.environment

	# Fog disabled - user requested removal
	env.fog_enabled = false

	print("[TerrainLab] Environment configured (fog disabled)")


## Setup default shader textures BEFORE terrain generation
## This prevents white terrain from unbound texture samplers
func _setup_default_shader_textures() -> void:
	# Create default textures with neutral values
	# These get overwritten once terrain is ready, but prevent white terrain during loading

	# Default heightmap (mid-gray = 0.5 height)
	var default_height := Image.create(4, 4, false, Image.FORMAT_RF)
	default_height.fill(Color(0.5, 0.5, 0.5, 1.0))
	var height_tex := ImageTexture.create_from_image(default_height)

	# Default vegetation (full vegetation = 1.0)
	var default_veg := Image.create(4, 4, false, Image.FORMAT_RF)
	default_veg.fill(Color(1.0, 1.0, 1.0, 1.0))
	var veg_tex := ImageTexture.create_from_image(default_veg)

	# Default clearing (transparent = no clearing overlay)
	var default_clear := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	default_clear.fill(Color(0, 0, 0, 0))
	var clear_tex := ImageTexture.create_from_image(default_clear)

	# Pre-initialize the shared material by forcing its creation
	TerrainChunkClass._create_shared_material()

	# Set default textures
	var params := {
		"heightmap": height_tex,
		"vegetation_texture": veg_tex,
		"clearing_texture": clear_tex,
		"terrain_size": 769,
		"cell_size": 4.0,
		"height_scale": 280.0
	}
	TerrainChunkClass.set_shader_parameters(params)
	print("[TerrainLab] Default shader textures initialized (prevents white terrain)")


## Setup terrain shader textures (heightmap, vegetation, clearing)
func _setup_terrain_shader_textures() -> void:
	# Check if terrain chunks are using shader
	if not TerrainChunkClass.is_using_shader():
		print("[TerrainLab] Terrain not using shader, skipping texture setup")
		return

	var params := {}

	# Set heightmap texture from terrain manager
	if terrain_manager and terrain_manager.heightmap:
		var heightmap_tex: ImageTexture = terrain_manager.heightmap.get_texture()
		if heightmap_tex:
			params["heightmap"] = heightmap_tex

	# Set terrain size parameters
	params["terrain_size"] = terrain_manager.heightmap.size if terrain_manager and terrain_manager.heightmap else 1537
	params["cell_size"] = terrain_manager.cell_size if terrain_manager else 4.0
	params["height_scale"] = terrain_manager.height_scale if terrain_manager else 280.0

	# Set vegetation and clearing textures from clearing system
	if clearing_system:
		var veg_tex: ImageTexture = clearing_system.get_vegetation_texture()
		if veg_tex:
			params["vegetation_texture"] = veg_tex

		var clear_tex: ImageTexture = clearing_system.get_clearing_texture()
		if clear_tex:
			params["clearing_texture"] = clear_tex

	# Apply all parameters
	TerrainChunkClass.set_shader_parameters(params)
	print("[TerrainLab] Terrain shader textures configured: %d parameters" % params.size())


## Called when clearing system updates vegetation
func _on_vegetation_updated(_region: Rect2i) -> void:
	if not clearing_system:
		return

	# Update vegetation and clearing textures in terrain shader
	var veg_tex: ImageTexture = clearing_system.get_vegetation_texture()
	if veg_tex:
		TerrainChunkClass.set_shader_texture("vegetation_texture", veg_tex)

	var clear_tex: ImageTexture = clearing_system.get_clearing_texture()
	if clear_tex:
		TerrainChunkClass.set_shader_texture("clearing_texture", clear_tex)


## Called when clearing system updates vegetation - update gameplay grid
func _on_grid_region_changed(region: Rect2i) -> void:
	if gameplay_grid:
		# Convert texture region to world coordinates and update grid
		var world_center := Vector3(
			(region.position.x + region.size.x / 2.0) * terrain_manager.map_size / 512.0,
			0,
			(region.position.y + region.size.y / 2.0) * terrain_manager.map_size / 512.0
		)
		var radius: float = maxf(region.size.x, region.size.y) * terrain_manager.map_size / 512.0
		gameplay_grid.update_region(world_center, radius)


func _connect_ui() -> void:
	if ui:
		if ui.has_signal("preset_changed"):
			ui.preset_changed.connect(_on_preset_changed)
		if ui.has_signal("param_changed"):
			ui.param_changed.connect(_on_param_changed)
		if ui.has_signal("regenerate_requested"):
			ui.regenerate_requested.connect(_on_regenerate)
		if ui.has_signal("damage_mode_changed"):
			ui.damage_mode_changed.connect(_on_damage_mode_changed)
		if ui.has_signal("clearing_mode_changed"):
			ui.clearing_mode_changed.connect(_on_clearing_mode_changed)


func _generate_initial_terrain() -> void:
	print("[TerrainLab] Generating %.0fkm x %.0fkm terrain..." % [terrain_manager.map_size/1000, terrain_manager.map_size/1000])

	if terrain_engine:
		terrain_engine.set_preset(0)  # ROLLING_HILLS
		terrain_engine.height_scale = 280.0

	# Wire vegetation_manager to terrain_manager BEFORE generation
	# so rice paddies can be colored correctly during mesh build
	if vegetation_manager:
		terrain_manager.vegetation_manager = vegetation_manager
		vegetation_manager._terrain_manager = terrain_manager  # For water proximity checks

	terrain_manager.generate_terrain()


func _on_generation_progress(stage: String, percent: float) -> void:
	loading_label.text = "%s... %.0f%%" % [stage, percent * 100]


func _on_terrain_ready() -> void:
	print("[TerrainLab] Terrain ready!")
	loading_ui.visible = false
	_setup_camera()
	_setup_jungle_fog()

	# Set terrain manager reference for damage and clearing systems
	if damage_system:
		damage_system.set_terrain_manager(terrain_manager)
		damage_system.set_vegetation_manager(vegetation_manager)
		if billboard_vegetation:
			damage_system.set_billboard_vegetation(billboard_vegetation)
	if clearing_system:
		clearing_system.set_terrain_manager(terrain_manager)
		# Connect clearing system to update terrain shader textures
		if clearing_system.has_signal("vegetation_updated"):
			clearing_system.vegetation_updated.connect(_on_vegetation_updated)

	# Initialize terrain shader textures
	_setup_terrain_shader_textures()

	# Create and populate gameplay grid for efficient game logic queries
	gameplay_grid = GameplayGridClass.new(terrain_manager.map_size, 256)
	gameplay_grid.set_heightmap(terrain_manager.heightmap)
	gameplay_grid.set_clearing_system(clearing_system)
	gameplay_grid.build_from_terrain()
	gameplay_grid.print_stats()

	# Initialize and generate water system
	if water_system:
		water_system.initialize(terrain_manager.heightmap, terrain_manager.chunk_size)
		water_system.generate_water_bodies()
		water_system.print_stats()

	# Connect clearing system to update gameplay grid
	if clearing_system and clearing_system.has_signal("vegetation_updated"):
		clearing_system.vegetation_updated.connect(_on_grid_region_changed)

	# Set up engineering system
	if engineering_system:
		engineering_system.set_terrain_manager(terrain_manager)
		engineering_system.set_vegetation_manager(vegetation_manager)
		# Connect VFX to engineering operations
		if terrain_vfx:
			engineering_system.operation_completed.connect(_on_engineering_completed)

	# Connect damage system to VFX
	if damage_system and terrain_vfx:
		damage_system.damage_applied.connect(_on_damage_applied)

	# Set up vegetation systems with camera and chunk size references
	if vegetation_manager:
		vegetation_manager.set_camera(camera)
		vegetation_manager.set_chunk_size(terrain_manager.chunk_size)

	if billboard_vegetation:
		billboard_vegetation.set_camera(camera)
		billboard_vegetation.set_chunk_size(terrain_manager.chunk_size)
		billboard_vegetation.set_terrain_manager(terrain_manager)
		billboard_vegetation.set_vegetation_manager(vegetation_manager)


func _on_chunk_loaded(coord: Vector2i, is_playable: bool) -> void:
	# Vegetation classification now happens in terrain_manager._load_chunk BEFORE mesh build
	# (so rice paddies can be colored correctly). Only generate billboards here.
	if is_playable:
		# Generate billboards for this chunk if vegetation terrain data exists
		if billboard_vegetation and vegetation_manager._chunk_terrain.has(coord):
			billboard_vegetation.generate_for_chunk(
				coord,
				terrain_manager.heightmap,
				vegetation_manager._chunk_terrain[coord]
			)


func _input(event: InputEvent) -> void:
	# Zoom with mouse wheel
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_target = max(zoom_min, zoom_target - zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_target = min(zoom_max, zoom_target + zoom_speed)
		# Middle mouse rotate
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			is_rotating = event.pressed
			last_mouse_pos = event.position

	# Middle mouse drag for rotation
	if event is InputEventMouseMotion and is_rotating:
		var delta = event.position - last_mouse_pos
		# Horizontal = yaw
		camera_rig.rotate_y(-delta.x * rotate_speed * 0.005)
		current_yaw = camera_rig.rotation_degrees.y
		# Vertical = tilt
		current_tilt += delta.y * tilt_speed * 0.5
		current_tilt = clamp(current_tilt, min_tilt, max_tilt)
		spring_arm.rotation_degrees.x = current_tilt
		last_mouse_pos = event.position

	# Camera presets
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1: _apply_camera_preset(0)
			KEY_F2: _apply_camera_preset(1)
			KEY_F3: _apply_camera_preset(2)
			KEY_F4: _apply_camera_preset(3)


func _process(delta: float) -> void:
	# Smooth zoom
	spring_arm.spring_length = lerp(spring_arm.spring_length, zoom_target, delta * 8.0)

	# WASD panning
	_handle_pan(delta)

	# Terrain-following: keep camera rig above terrain
	if terrain_manager and terrain_manager.is_ready:
		var terrain_height: float = terrain_manager.get_height_at(camera_rig.position)
		var min_y: float = terrain_height + min_camera_height
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
		# Scale pan speed with zoom level
		var speed_mult := spring_arm.spring_length / 200.0
		var pan := (camera_rig.basis * move).normalized() * pan_speed * speed_mult * delta
		pan.y = 0

		# Clamp to playable bounds
		var new_pos := camera_rig.position + pan
		var bounds: Rect2 = terrain_manager.get_playable_bounds()
		new_pos.x = clampf(new_pos.x, bounds.position.x, bounds.position.x + bounds.size.x)
		new_pos.z = clampf(new_pos.z, bounds.position.y, bounds.position.y + bounds.size.y)
		camera_rig.position = new_pos


func _apply_camera_preset(index: int) -> void:
	if index < 0 or index >= CAMERA_PRESETS.size():
		return
	var preset = CAMERA_PRESETS[index]
	current_tilt = preset[0]
	zoom_target = preset[1]
	spring_arm.rotation_degrees.x = current_tilt
	print("[TerrainLab] Camera preset: %s (tilt %.0f, zoom %.0f)" % [preset[2], preset[0], preset[1]])


func _unhandled_input(event: InputEvent) -> void:
	# Regenerate terrain
	if event.is_action_pressed("regenerate_terrain"):
		_on_regenerate()

	# Toggle wireframe
	if event.is_action_pressed("toggle_wireframe"):
		_toggle_wireframe()

	# Number keys to select engineering operation (1-9)
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_select_engineering_op(0)  # Clear Jungle
			KEY_2:
				_select_engineering_op(1)  # Flatten Area
			KEY_3:
				_select_engineering_op(2)  # Dig Trench
			KEY_4:
				_select_engineering_op(3)  # Build Road
			KEY_5:
				_select_engineering_op(4)  # Create Berm
			KEY_6:
				_select_engineering_op(5)  # Dig Foxhole
			KEY_7:
				_select_engineering_op(6)  # Crater Blast
			KEY_8:
				_select_engineering_op(7)  # Det Cord Line
			KEY_9:
				_select_engineering_op(8)  # Det Cord Square
			KEY_0:
				_select_damage_mode()      # Switch to damage mode
			KEY_ESCAPE:
				_cancel_operation()
			KEY_F:
				_toggle_env_fog()          # Toggle environment fog
			KEY_M:
				_place_test_markers()      # Place construction markers

	# Place operation (left click)
	if event.is_action_pressed("place_damage"):
		var hit_pos := _raycast_terrain()
		if hit_pos != Vector3.INF:
			if interaction_mode == InteractionMode.ENGINEERING:
				_apply_engineering(hit_pos)
			elif clearing_mode:
				_start_clearing(hit_pos)
			else:
				_apply_damage(hit_pos)

	# Create clearing zone (right click)
	if event.is_action_pressed("clear_jungle"):
		var hit_pos := _raycast_terrain()
		if hit_pos != Vector3.INF:
			_start_clearing(hit_pos)


func _raycast_terrain() -> Vector3:
	var mouse_pos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse_pos)
	var dir := camera.project_ray_normal(mouse_pos)
	var to := from + dir * 10000.0  # Extended range for 3km map

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 0xFFFFFFFF
	query.collide_with_areas = true
	query.collide_with_bodies = true

	var result := space_state.intersect_ray(query)
	if result:
		return result.position

	return Vector3.INF


func _apply_damage(pos: Vector3) -> void:
	if damage_system:
		var type: int = current_damage_type
		if ui and ui.has_method("get_selected_damage_type"):
			type = ui.get_selected_damage_type()

		# Damage system now handles both heightmap modification and chunk rebuild
		damage_system.apply_damage(pos, type)
		print("Damage applied at: ", pos)


func _start_clearing(pos: Vector3) -> void:
	if clearing_system:
		var zone_id: int = clearing_system.create_zone(pos, 30.0)
		# Set to CLEARED stage - this triggers terrain flattening and chunk rebuild
		clearing_system.set_zone_stage(zone_id, 2)

		# Clear vegetation in area
		vegetation_manager.clear_area(pos, 30.0, terrain_manager.chunk_size)

		# Regenerate billboards for affected chunks
		if billboard_vegetation:
			var radius: float = 30.0
			var chunk_size: float = terrain_manager.chunk_size
			# Find all affected chunks
			var min_cx := int(floor((pos.x - radius) / chunk_size))
			var max_cx := int(floor((pos.x + radius) / chunk_size))
			var min_cz := int(floor((pos.z - radius) / chunk_size))
			var max_cz := int(floor((pos.z + radius) / chunk_size))

			for cz in range(min_cz, max_cz + 1):
				for cx in range(min_cx, max_cx + 1):
					var coord := Vector2i(cx, cz)
					if vegetation_manager._chunk_terrain.has(coord):
						billboard_vegetation.generate_for_chunk(
							coord,
							terrain_manager.heightmap,
							vegetation_manager._chunk_terrain[coord]
						)

		print("Clearing zone created at: ", pos)


func _toggle_wireframe() -> void:
	var vp := get_viewport()
	if vp.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME:
		vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	else:
		vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME


func _on_preset_changed(preset: int) -> void:
	print("[TerrainLab] Preset changed to %d" % preset)
	if terrain_engine:
		terrain_engine.set_preset(preset)
		_on_regenerate()


func _on_param_changed(param: String, value: Variant) -> void:
	if terrain_engine:
		terrain_engine.set_param(param, value)


func _on_regenerate() -> void:
	print("[TerrainLab] Regenerating terrain...")
	loading_ui.visible = true

	# Clear vegetation and billboards
	vegetation_manager.clear_all()
	if billboard_vegetation:
		billboard_vegetation.clear_all()

	# Clear water
	if water_system:
		water_system.clear()

	# Regenerate terrain
	terrain_manager.generate_terrain()


func _on_damage_mode_changed(type: int) -> void:
	current_damage_type = type


func _on_clearing_mode_changed(enabled: bool) -> void:
	clearing_mode = enabled


# ============================================================================
# ENGINEERING OPERATIONS
# ============================================================================

func _select_engineering_op(op_type: int) -> void:
	interaction_mode = InteractionMode.ENGINEERING
	current_engineering_op = op_type
	var op_name: String = EngineeringSystemClass.get_operation_name(op_type)
	var op_desc: String = EngineeringSystemClass.get_operation_description(op_type)

	if EngineeringSystemClass.is_linear_operation(op_type):
		print("[TerrainLab] Engineering: %s - %s (click start, then end)" % [op_name, op_desc])
	else:
		print("[TerrainLab] Engineering: %s - %s (click to place)" % [op_name, op_desc])


func _select_damage_mode() -> void:
	interaction_mode = InteractionMode.DAMAGE
	_cancel_operation()
	print("[TerrainLab] Switched to DAMAGE mode (0=Small, use dropdown for type)")


func _cancel_operation() -> void:
	if engineering_system:
		engineering_system.cancel_linear_operation()
		print("[TerrainLab] Operation cancelled")


func _apply_engineering(pos: Vector3) -> void:
	if not engineering_system:
		return

	var op_type: int = current_engineering_op

	# Check if this is a linear operation
	if EngineeringSystemClass.is_linear_operation(op_type):
		var completed: bool = engineering_system.start_linear_operation(op_type, pos)
		if not completed:
			print("[TerrainLab] Linear op started at %s - click end point" % pos)
			# Place start marker
			if construction_markers:
				var height_func := func(p: Vector3) -> float:
					return terrain_manager.get_height_at(p)
				construction_markers.place_area_stakes(pos, 5.0, height_func)
	else:
		# Single-click operation
		engineering_system.execute_operation(op_type, pos)


# ============================================================================
# VFX & FOG OF WAR
# ============================================================================

func _on_damage_applied(position: Vector3, type: int, _radius: float) -> void:
	if terrain_vfx:
		terrain_vfx.play_damage_effect(position, type)


func _on_engineering_completed(op_type: int, position: Vector3) -> void:
	if terrain_vfx:
		terrain_vfx.play_engineering_effect(position, op_type)

func _toggle_env_fog() -> void:
	var env := get_node_or_null("WorldEnvironment")
	if env and env.environment:
		env.environment.fog_enabled = not env.environment.fog_enabled
		print("[TerrainLab] Environment Fog: %s" % ("ON" if env.environment.fog_enabled else "OFF"))


func _place_test_markers() -> void:
	if not construction_markers:
		return

	var pos := _raycast_terrain()
	if pos == Vector3.INF:
		return

	var height_func := func(p: Vector3) -> float:
		return terrain_manager.get_height_at(p)

	# Place LZ markers at cursor position
	construction_markers.place_lz_markers(pos, 50.0, height_func)
	print("[TerrainLab] Placed LZ markers at %s" % pos)
