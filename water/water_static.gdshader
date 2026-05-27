shader_type spatial;
render_mode depth_draw_always, cull_disabled;

// Include shared water utilities
#include "res://water/water_common.gdshaderinc"

// Water appearance - pond/lake colors (greenish, murky)
uniform vec4 water_color : source_color = vec4(0.20, 0.30, 0.22, 0.75);
uniform vec4 water_color_deep : source_color = vec4(0.12, 0.18, 0.10, 0.88);
uniform float depth_fade : hint_range(0.1, 10.0) = 3.0;

// Shore blending
uniform float shore_fade_distance : hint_range(0.5, 5.0) = 2.5;

// Specular
uniform float specular_strength : hint_range(0.0, 1.0) = 0.35;
uniform float specular_shininess : hint_range(1.0, 128.0) = 24.0;

// Gentle ripple animation (slower than river flow)
uniform float ripple_strength : hint_range(0.0, 0.05) = 0.015;
uniform float ripple_scale : hint_range(1.0, 30.0) = 8.0;
uniform float ripple_speed : hint_range(0.1, 2.0) = 0.6;

// Optional normal map
uniform sampler2D normal_map : hint_normal;
uniform bool use_normal_map = false;

// Shore distance from vertex color (R channel)
varying float v_shore_distance;
varying vec2 v_world_uv;

void vertex() {
	// Shore distance stored in vertex color R channel
	v_shore_distance = COLOR.r * 10.0;  // Scale: 0-1 maps to 0-10 meters

	// World-space UV for consistent ripple pattern
	v_world_uv = VERTEX.xz * 0.05;  // Scale factor for world UVs
}

void fragment() {
	// Multi-directional ripple pattern (gentle, pond-like)
	float ripple = water_ripple(v_world_uv, ripple_scale, ripple_speed, TIME);

	// Secondary slower ripple for variation
	float ripple2 = water_ripple(v_world_uv * 0.7 + vec2(0.3, 0.7), ripple_scale * 0.6, ripple_speed * 0.7, TIME);
	float combined_ripple = (ripple + ripple2) * 0.5;

	// Distort UVs gently
	vec2 distorted_uv = v_world_uv + vec2(combined_ripple * ripple_strength, combined_ripple * ripple_strength * 0.7);

	// Generate procedural normal from ripples
	vec3 procedural_normal = water_normal_from_height(v_world_uv, ripple_scale, ripple_speed, TIME, ripple_strength * 8.0);

	// Blend with secondary normal for more complexity
	vec3 procedural_normal2 = water_normal_from_height(v_world_uv * 0.7, ripple_scale * 0.6, ripple_speed * 0.7, TIME, ripple_strength * 5.0);
	vec3 blended_normal = normalize(procedural_normal + procedural_normal2 * 0.5);

	// Use normal map if provided, otherwise use procedural
	vec3 normal;
	if (use_normal_map) {
		vec3 normal_sample = texture(normal_map, distorted_uv).rgb * 2.0 - 1.0;
		normal = normalize(normal_sample + blended_normal * 0.3);
	} else {
		normal = blended_normal;
	}

	// Depth-based color mixing (darker in center)
	// Use shore distance as depth proxy
	float depth_factor = clamp(v_shore_distance / shore_fade_distance, 0.0, 1.0);
	vec4 final_color = water_color_by_depth(water_color, water_color_deep, depth_factor, 1.0);

	// Add subtle variation from ripples
	final_color.rgb += vec3(combined_ripple * 0.03 - 0.015);

	// Shore blending - fade alpha near edges
	float shore_blend = water_shore_blend(v_shore_distance, shore_fade_distance);
	float final_alpha = final_color.a * shore_blend;

	// Apply color
	ALBEDO = final_color.rgb;
	ALPHA = final_alpha;

	// Normal mapping
	NORMAL_MAP = normal * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.4;  // Slightly less pronounced than rivers

	// Specular/roughness for highlights (more subtle for still water)
	ROUGHNESS = 1.0 - specular_strength * 0.8;
	SPECULAR = specular_strength * 0.7;
	METALLIC = 0.0;
}
