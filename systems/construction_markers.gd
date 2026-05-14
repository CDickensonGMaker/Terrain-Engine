extends Node3D
class_name ConstructionMarkers
## Visual markers for construction operations - stakes, tape, progress indicators

signal marker_placed(marker_id: int, position: Vector3)
signal marker_removed(marker_id: int)

enum MarkerType {
	STAKE,           # Corner stake for area marking
	TAPE_LINE,       # Tape between stakes
	PROGRESS_RING,   # Circular progress indicator
	ZONE_OUTLINE,    # Outline of construction zone
	LZ_MARKER,       # Landing zone markers (cross pattern)
}

# Active markers
var markers: Dictionary = {}  # marker_id -> Node3D
var next_marker_id: int = 0

# Materials
var stake_material: StandardMaterial3D
var tape_material: StandardMaterial3D
var progress_material: StandardMaterial3D
var lz_material: StandardMaterial3D


func _ready() -> void:
	_create_materials()


func _create_materials() -> void:
	# Wooden stake material
	stake_material = StandardMaterial3D.new()
	stake_material.albedo_color = Color(0.5, 0.35, 0.2)
	stake_material.roughness = 0.9

	# Construction tape material (orange/red stripes)
	tape_material = StandardMaterial3D.new()
	tape_material.albedo_color = Color(1.0, 0.4, 0.1)
	tape_material.emission_enabled = true
	tape_material.emission = Color(1.0, 0.3, 0.0)
	tape_material.emission_energy_multiplier = 0.3

	# Progress ring material (green glow)
	progress_material = StandardMaterial3D.new()
	progress_material.albedo_color = Color(0.2, 0.8, 0.2, 0.7)
	progress_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	progress_material.emission_enabled = true
	progress_material.emission = Color(0.1, 0.6, 0.1)
	progress_material.emission_energy_multiplier = 0.5

	# LZ marker material (bright orange)
	lz_material = StandardMaterial3D.new()
	lz_material.albedo_color = Color(1.0, 0.5, 0.0)
	lz_material.emission_enabled = true
	lz_material.emission = Color(1.0, 0.4, 0.0)
	lz_material.emission_energy_multiplier = 0.8


## Place corner stakes for an area
func place_area_stakes(center: Vector3, size: float, terrain_height_func: Callable = Callable()) -> int:
	var container := Node3D.new()
	container.name = "AreaStakes"
	add_child(container)

	var half := size / 2.0
	var corners := [
		Vector3(center.x - half, 0, center.z - half),
		Vector3(center.x + half, 0, center.z - half),
		Vector3(center.x + half, 0, center.z + half),
		Vector3(center.x - half, 0, center.z + half),
	]

	for i in range(corners.size()):
		var corner: Vector3 = corners[i]
		if terrain_height_func.is_valid():
			corner.y = terrain_height_func.call(corner)

		var stake := _create_stake()
		stake.position = corner
		container.add_child(stake)

		# Add tape to next corner
		var next_corner: Vector3 = corners[(i + 1) % corners.size()]
		if terrain_height_func.is_valid():
			next_corner.y = terrain_height_func.call(next_corner)
		var tape := _create_tape_line(corner, next_corner)
		container.add_child(tape)

	var marker_id := next_marker_id
	next_marker_id += 1
	markers[marker_id] = container
	marker_placed.emit(marker_id, center)

	return marker_id


## Place LZ markers (cross pattern)
func place_lz_markers(center: Vector3, size: float, terrain_height_func: Callable = Callable()) -> int:
	var container := Node3D.new()
	container.name = "LZMarkers"
	add_child(container)

	var half := size / 2.0
	var y_offset := 0.2

	# Get terrain height at center
	var center_y: float = center.y
	if terrain_height_func.is_valid():
		center_y = terrain_height_func.call(center)

	# Create cross pattern with cylinders
	var arm_width := 3.0
	var arm_length := half * 0.8

	# Horizontal arm
	var h_arm := _create_lz_arm(arm_length * 2, arm_width)
	h_arm.position = Vector3(center.x, center_y + y_offset, center.z)
	container.add_child(h_arm)

	# Vertical arm
	var v_arm := _create_lz_arm(arm_length * 2, arm_width)
	v_arm.position = Vector3(center.x, center_y + y_offset, center.z)
	v_arm.rotation.y = PI / 2
	container.add_child(v_arm)

	# Corner markers
	var corner_size := 4.0
	var corner_offset := half * 0.9
	var corner_positions := [
		Vector3(center.x - corner_offset, 0, center.z - corner_offset),
		Vector3(center.x + corner_offset, 0, center.z - corner_offset),
		Vector3(center.x + corner_offset, 0, center.z + corner_offset),
		Vector3(center.x - corner_offset, 0, center.z + corner_offset),
	]

	for idx in range(corner_positions.size()):
		var pos: Vector3 = corner_positions[idx]
		if terrain_height_func.is_valid():
			pos.y = terrain_height_func.call(pos) + y_offset
		else:
			pos.y = center_y + y_offset
		var corner := _create_corner_marker(corner_size)
		corner.position = pos
		container.add_child(corner)

	var marker_id := next_marker_id
	next_marker_id += 1
	markers[marker_id] = container
	marker_placed.emit(marker_id, center)

	return marker_id


## Place circular progress indicator
func place_progress_ring(center: Vector3, radius: float, progress: float = 0.0) -> int:
	var ring := _create_progress_ring(radius)
	ring.position = center + Vector3(0, 0.3, 0)
	add_child(ring)

	var marker_id := next_marker_id
	next_marker_id += 1
	markers[marker_id] = ring
	marker_placed.emit(marker_id, center)

	return marker_id


## Update progress ring
func update_progress(marker_id: int, progress: float) -> void:
	if not markers.has(marker_id):
		return

	var ring: Node3D = markers[marker_id]
	# Scale ring based on progress (full at 1.0)
	var scale_factor: float = 0.3 + progress * 0.7
	ring.scale = Vector3(scale_factor, 1.0, scale_factor)

	# Update material color (red -> yellow -> green)
	var mat: StandardMaterial3D = ring.get_child(0).material_override if ring.get_child_count() > 0 else null
	if mat:
		var color: Color
		if progress < 0.5:
			color = Color(1.0, progress * 2, 0.0)
		else:
			color = Color(1.0 - (progress - 0.5) * 2, 1.0, 0.0)
		mat.albedo_color = color
		mat.albedo_color.a = 0.7
		mat.emission = color * 0.5


## Place linear construction markers (for roads, trenches)
func place_line_markers(start: Vector3, end: Vector3, spacing: float = 10.0, terrain_height_func: Callable = Callable()) -> int:
	var container := Node3D.new()
	container.name = "LineMarkers"
	add_child(container)

	var direction: Vector3 = (end - start).normalized()
	var length: float = start.distance_to(end)
	var steps: int = int(length / spacing) + 1

	for i in range(steps):
		var t: float = float(i) / float(steps - 1) if steps > 1 else 0.0
		var pos: Vector3 = start.lerp(end, t)
		if terrain_height_func.is_valid():
			pos.y = terrain_height_func.call(pos)

		var stake := _create_stake()
		stake.position = pos
		container.add_child(stake)

	# Add tape along the line
	var tape := _create_tape_line(start, end)
	if terrain_height_func.is_valid():
		tape.position.y = (terrain_height_func.call(start) + terrain_height_func.call(end)) / 2.0 + 1.0
	container.add_child(tape)

	var marker_id := next_marker_id
	next_marker_id += 1
	markers[marker_id] = container
	marker_placed.emit(marker_id, (start + end) / 2.0)

	return marker_id


## Remove marker
func remove_marker(marker_id: int) -> void:
	if markers.has(marker_id):
		var marker: Node3D = markers[marker_id]
		marker.queue_free()
		markers.erase(marker_id)
		marker_removed.emit(marker_id)


## Remove all markers
func clear_all_markers() -> void:
	for marker_id in markers.keys():
		remove_marker(marker_id)


# ============================================================================
# INTERNAL HELPERS
# ============================================================================

func _create_stake() -> MeshInstance3D:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.05
	cylinder.bottom_radius = 0.08
	cylinder.height = 1.5

	var mesh := MeshInstance3D.new()
	mesh.mesh = cylinder
	mesh.material_override = stake_material
	mesh.position.y = 0.75  # Half height above ground

	return mesh


func _create_tape_line(start: Vector3, end: Vector3) -> MeshInstance3D:
	var length: float = start.distance_to(end)
	var midpoint: Vector3 = (start + end) / 2.0

	var box := BoxMesh.new()
	box.size = Vector3(length, 0.1, 0.05)

	var mesh := MeshInstance3D.new()
	mesh.mesh = box
	mesh.material_override = tape_material
	mesh.position = midpoint + Vector3(0, 1.2, 0)

	# Rotate to face end point
	var direction: Vector3 = (end - start).normalized()
	mesh.rotation.y = atan2(direction.x, direction.z)

	return mesh


func _create_progress_ring(radius: float) -> Node3D:
	var container := Node3D.new()

	# Create torus-like ring using multiple small cylinders
	var segments: int = 32
	var tube_radius: float = 0.15

	for i in range(segments):
		var angle: float = float(i) / float(segments) * TAU
		var x: float = cos(angle) * radius
		var z: float = sin(angle) * radius

		var cylinder := CylinderMesh.new()
		cylinder.top_radius = tube_radius
		cylinder.bottom_radius = tube_radius
		cylinder.height = 0.1

		var mesh := MeshInstance3D.new()
		mesh.mesh = cylinder
		mesh.material_override = progress_material.duplicate()
		mesh.position = Vector3(x, 0, z)
		mesh.rotation.x = PI / 2
		container.add_child(mesh)

	return container


func _create_lz_arm(length: float, width: float) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3(length, 0.1, width)

	var mesh := MeshInstance3D.new()
	mesh.mesh = box
	mesh.material_override = lz_material

	return mesh


func _create_corner_marker(size: float) -> Node3D:
	var container := Node3D.new()

	# L-shaped corner marker
	var arm1 := BoxMesh.new()
	arm1.size = Vector3(size, 0.1, size * 0.3)

	var arm2 := BoxMesh.new()
	arm2.size = Vector3(size * 0.3, 0.1, size)

	var mesh1 := MeshInstance3D.new()
	mesh1.mesh = arm1
	mesh1.material_override = lz_material
	mesh1.position.x = size * 0.35

	var mesh2 := MeshInstance3D.new()
	mesh2.mesh = arm2
	mesh2.material_override = lz_material
	mesh2.position.z = size * 0.35

	container.add_child(mesh1)
	container.add_child(mesh2)

	return container
