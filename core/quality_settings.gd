extends Node
class_name QualitySettings
## Quality presets for TerrainEngine performance optimization
## Allows scaling visuals based on hardware capability

enum Preset {
	POTATO,   # Intel UHD minimum playable
	LOW,      # Integrated graphics
	MEDIUM,   # Entry-level discrete GPU
	HIGH,     # Mid-range discrete GPU
	ULTRA,    # High-end GPU
}

# Current active preset
var current_preset: Preset = Preset.MEDIUM

# Settings applied from preset
var vegetation_density: float = 0.5
var grass_enabled: bool = true
var billboards_enabled: bool = true
var load_distance: int = 2
var fog_density: float = 0.008
var fog_enabled: bool = true
var canopy_enabled: bool = true
var shadow_distance: float = 1500.0
var near_tree_distance: float = 80.0
var billboard_distance: float = 350.0

# Preset definitions
const PRESETS := {
	Preset.POTATO: {
		"vegetation_density": 0.1,
		"grass_enabled": false,
		"billboards_enabled": false,
		"load_distance": 1,
		"fog_density": 0.02,
		"fog_enabled": true,
		"canopy_enabled": false,
		"shadow_distance": 500.0,
		"near_tree_distance": 50.0,
		"billboard_distance": 200.0,
	},
	Preset.LOW: {
		"vegetation_density": 0.25,
		"grass_enabled": false,
		"billboards_enabled": true,
		"load_distance": 1,
		"fog_density": 0.012,
		"fog_enabled": true,
		"canopy_enabled": false,
		"shadow_distance": 800.0,
		"near_tree_distance": 60.0,
		"billboard_distance": 250.0,
	},
	Preset.MEDIUM: {
		"vegetation_density": 0.5,
		"grass_enabled": true,
		"billboards_enabled": true,
		"load_distance": 2,
		"fog_density": 0.008,
		"fog_enabled": true,
		"canopy_enabled": true,
		"shadow_distance": 1500.0,
		"near_tree_distance": 80.0,
		"billboard_distance": 350.0,
	},
	Preset.HIGH: {
		"vegetation_density": 0.75,
		"grass_enabled": true,
		"billboards_enabled": true,
		"load_distance": 2,
		"fog_density": 0.005,
		"fog_enabled": true,
		"canopy_enabled": true,
		"shadow_distance": 2000.0,
		"near_tree_distance": 100.0,
		"billboard_distance": 400.0,
	},
	Preset.ULTRA: {
		"vegetation_density": 1.0,
		"grass_enabled": true,
		"billboards_enabled": true,
		"load_distance": 3,
		"fog_density": 0.003,
		"fog_enabled": true,
		"canopy_enabled": true,
		"shadow_distance": 2500.0,
		"near_tree_distance": 120.0,
		"billboard_distance": 500.0,
	},
}

signal preset_changed(preset: Preset)


func _ready() -> void:
	# Auto-detect hardware and set initial preset
	_auto_detect_preset()


## Apply a quality preset
func apply_preset(preset: Preset) -> void:
	if not PRESETS.has(preset):
		push_warning("QualitySettings: Invalid preset %d" % preset)
		return

	current_preset = preset
	var settings: Dictionary = PRESETS[preset]

	vegetation_density = settings.vegetation_density
	grass_enabled = settings.grass_enabled
	billboards_enabled = settings.billboards_enabled
	load_distance = settings.load_distance
	fog_density = settings.fog_density
	fog_enabled = settings.fog_enabled
	canopy_enabled = settings.canopy_enabled
	shadow_distance = settings.shadow_distance
	near_tree_distance = settings.near_tree_distance
	billboard_distance = settings.billboard_distance

	preset_changed.emit(preset)
	print("[QualitySettings] Applied preset: %s" % get_preset_name(preset))


## Get preset name as string
static func get_preset_name(preset: Preset) -> String:
	match preset:
		Preset.POTATO: return "POTATO"
		Preset.LOW: return "LOW"
		Preset.MEDIUM: return "MEDIUM"
		Preset.HIGH: return "HIGH"
		Preset.ULTRA: return "ULTRA"
	return "UNKNOWN"


## Auto-detect appropriate preset based on hardware
func _auto_detect_preset() -> void:
	var renderer := RenderingServer.get_video_adapter_name().to_lower()

	# Check for integrated graphics
	if "intel" in renderer and ("uhd" in renderer or "hd graphics" in renderer):
		apply_preset(Preset.POTATO)
		print("[QualitySettings] Detected Intel integrated graphics - using POTATO preset")
		return

	if "amd" in renderer and ("vega" in renderer or "radeon graphics" in renderer):
		apply_preset(Preset.LOW)
		print("[QualitySettings] Detected AMD integrated graphics - using LOW preset")
		return

	# Check for low-end discrete GPUs
	if "1050" in renderer or "1060" in renderer or "rx 560" in renderer:
		apply_preset(Preset.LOW)
		print("[QualitySettings] Detected entry-level GPU - using LOW preset")
		return

	# Check for mid-range GPUs
	if "1660" in renderer or "2060" in renderer or "rx 580" in renderer or "rx 5600" in renderer:
		apply_preset(Preset.MEDIUM)
		print("[QualitySettings] Detected mid-range GPU - using MEDIUM preset")
		return

	# Check for high-end GPUs
	if "3070" in renderer or "3080" in renderer or "4070" in renderer or "rx 6800" in renderer:
		apply_preset(Preset.HIGH)
		print("[QualitySettings] Detected high-end GPU - using HIGH preset")
		return

	# Default to MEDIUM for unknown hardware
	apply_preset(Preset.MEDIUM)
	print("[QualitySettings] Unknown GPU (%s) - using MEDIUM preset" % renderer)


## Get current settings as dictionary
func get_current_settings() -> Dictionary:
	return {
		"vegetation_density": vegetation_density,
		"grass_enabled": grass_enabled,
		"billboards_enabled": billboards_enabled,
		"load_distance": load_distance,
		"fog_density": fog_density,
		"fog_enabled": fog_enabled,
		"canopy_enabled": canopy_enabled,
		"shadow_distance": shadow_distance,
		"near_tree_distance": near_tree_distance,
		"billboard_distance": billboard_distance,
	}
