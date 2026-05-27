extends Resource
class_name WaterBodyData
## Data container for a single water body (river, pond, lake, coastal zone)
## Used by WaterSystem for tracking and rendering water features

## Water body classification
enum Type {
	NONE = 0,
	CREEK = 1,      # Width < 6m, flowing
	RIVER = 2,      # Width 6-50m, flowing
	POND = 3,       # Area < 2500 m^2, static
	LAKE = 4,       # Area >= 2500 m^2, static
	SWAMP = 5,      # Shallow, vegetated wetland
	COASTAL = 6,    # Ocean/sea edge
}

## Unique identifier for this water body
@export var id: int = -1

## Classification of this water body
@export var type: Type = Type.NONE

## Water surface elevation in meters
@export var elevation: float = 0.0

## Bounding box in world coordinates (x, z)
@export var bounds: Rect2 = Rect2()

## Shoreline polygon for static bodies (ponds, lakes, coastal)
## Points are in world coordinates (x, z)
@export var polygon: PackedVector2Array = PackedVector2Array()

## Center path for flowing water (rivers, creeks)
## Points are in world coordinates (x, z)
@export var path: PackedVector2Array = PackedVector2Array()

## Width at each path point (for rivers/creeks)
@export var widths: PackedFloat32Array = PackedFloat32Array()

## Average flow direction (normalized, for shader)
@export var flow_direction: Vector2 = Vector2.RIGHT

## Flow speed in m/s (affects shader animation)
@export var flow_speed: float = 0.5

## Average depth in meters
@export var depth: float = 1.0

## Generated mesh (set by WaterMeshBuilder)
var mesh: Mesh = null

## Mesh instance in scene (set by WaterSystem)
var mesh_instance: MeshInstance3D = null


## Check if this is a flowing water body
func is_flowing() -> bool:
	return type == Type.CREEK or type == Type.RIVER


## Check if this is a static water body
func is_static() -> bool:
	return type == Type.POND or type == Type.LAKE or type == Type.COASTAL


## Get area in square meters
func get_area() -> float:
	if is_flowing():
		# Approximate area from path and widths
		var area: float = 0.0
		for i in range(path.size() - 1):
			var segment_length: float = path[i].distance_to(path[i + 1])
			var avg_width: float = (widths[i] + widths[i + 1]) * 0.5
			area += segment_length * avg_width
		return area
	else:
		# Use bounding box as approximation (polygon area calculation is expensive)
		return bounds.get_area()


## Get center point in world coordinates
func get_center() -> Vector2:
	if is_flowing() and path.size() > 0:
		return path[path.size() / 2]
	else:
		return bounds.get_center()


## Check if a world position is inside this water body
func contains_point(world_x: float, world_z: float) -> bool:
	var point := Vector2(world_x, world_z)

	# Quick bounds check first
	if not bounds.has_point(point):
		return false

	if is_flowing():
		# Check distance to path segments
		return _point_near_path(point)
	else:
		# Check if inside polygon
		return _point_in_polygon(point)


## Get water depth at a world position (0 if outside)
func get_depth_at(world_x: float, world_z: float) -> float:
	if not contains_point(world_x, world_z):
		return 0.0

	# For simplicity, return uniform depth
	# TODO: Per-point depth calculation for more realism
	return depth


## Get flow direction at a world position
func get_flow_at(world_x: float, world_z: float) -> Vector2:
	if not is_flowing():
		return Vector2.ZERO

	if not contains_point(world_x, world_z):
		return Vector2.ZERO

	# Find nearest path segment and return its direction
	var point := Vector2(world_x, world_z)
	var best_dir := flow_direction
	var best_dist := INF

	for i in range(path.size() - 1):
		var seg_start := path[i]
		var seg_end := path[i + 1]
		var closest := _closest_point_on_segment(point, seg_start, seg_end)
		var dist := point.distance_to(closest)

		if dist < best_dist:
			best_dist = dist
			best_dir = (seg_end - seg_start).normalized()

	return best_dir * flow_speed


## Check if point is near the river/creek path
func _point_near_path(point: Vector2) -> bool:
	for i in range(path.size() - 1):
		var seg_start := path[i]
		var seg_end := path[i + 1]
		var closest := _closest_point_on_segment(point, seg_start, seg_end)
		var dist := point.distance_to(closest)

		# Interpolate width at closest point
		var t := seg_start.distance_to(closest) / seg_start.distance_to(seg_end)
		t = clampf(t, 0.0, 1.0)
		var width_at_point := lerpf(widths[i], widths[i + 1], t)

		if dist <= width_at_point * 0.5:
			return true

	return false


## Find closest point on a line segment
func _closest_point_on_segment(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> Vector2:
	var seg := seg_end - seg_start
	var seg_len_sq := seg.length_squared()

	if seg_len_sq < 0.0001:
		return seg_start

	var t := clampf((point - seg_start).dot(seg) / seg_len_sq, 0.0, 1.0)
	return seg_start + seg * t


## Point-in-polygon test using ray casting
func _point_in_polygon(point: Vector2) -> bool:
	if polygon.size() < 3:
		return false

	var inside := false
	var j := polygon.size() - 1

	for i in range(polygon.size()):
		var pi := polygon[i]
		var pj := polygon[j]

		if ((pi.y > point.y) != (pj.y > point.y)) and \
		   (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside

		j = i

	return inside


## Get type name as string
static func type_name(t: Type) -> String:
	match t:
		Type.NONE: return "None"
		Type.CREEK: return "Creek"
		Type.RIVER: return "River"
		Type.POND: return "Pond"
		Type.LAKE: return "Lake"
		Type.SWAMP: return "Swamp"
		Type.COASTAL: return "Coastal"
	return "Unknown"


## Debug string representation
func _to_string() -> String:
	return "[WaterBody %d: %s, elev=%.1fm, area=%.0fm²]" % [
		id, type_name(type), elevation, get_area()
	]
