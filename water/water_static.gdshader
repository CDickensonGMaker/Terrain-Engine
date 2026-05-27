shader_type spatial;
render_mode depth_draw_always, cull_disabled;

// Include shared water utilities
#include "res://water/water_common.gdshaderinc"

// Realistic blue water (shallow turquoise -> deep blue). Depth comes from vertex
// color G (= water_surface - terrain), so shallow shores read light, centres deep.
uniform vec4 water_color : source_color = vec4(0.10, 0.42, 0.52, 0.60);
uniform vec4 water_color_deep : source_color = vec4(0.04, 0.13, 0.32, 0.92);

// Tint reflected toward the sky at grazing angles (Fresnel).
uniform vec4 fresnel_color : source_color = vec4(0.55, 0.70, 0.85, 1.0);
uniform float fresnel_power : hint_range(1.0, 8.0) = 5.0;

// Shore blending (meters), distance stored in vertex color R.
uniform float shore_fade_distance : hint_range(0.5, 5.0) = 2.5;

// Specular
uniform float specular_strength : hint_range(0.0, 1.0) = 0.4;

// Gentle ripple animation
uniform float ripple_strength : hint_range(0.0, 0.05) = 0.015;
uniform float ripple_scale : hint_range(1.0, 30.0) = 8.0;
uniform float ripple_speed : hint_range(0.1, 2.0) = 0.6;

varying float v_shore_distance;  // meters to shore
varying float v_depth;           // 0 (shallow) .. 1 (deep), from vertex color G
varying vec2 v_world_uv;

void vertex() {
	v_shore_distance = COLOR.r * 10.0;  // 0-1 maps to 0-10 meters
	v_depth = COLOR.g;
	v_world_uv = VERTEX.xz * 0.05;
}

void fragment() {
	// Multi-directional ripple pattern (gentle, pond-like)
	float ripple = water_ripple(v_world_uv, ripple_scale, ripple_speed, TIME);
	float ripple2 = water_ripple(v_world_uv * 0.7 + vec2(0.3, 0.7), ripple_scale * 0.6, ripple_speed * 0.7, TIME);
	float combined_ripple = (ripple + ripple2) * 0.5;

	// Procedural normals from the ripples (no textures needed - cheap).
	vec3 n1 = water_normal_from_height(v_world_uv, ripple_scale, ripple_speed, TIME, ripple_strength * 8.0);
	vec3 n2 = water_normal_from_height(v_world_uv * 0.7, ripple_scale * 0.6, ripple_speed * 0.7, TIME, ripple_strength * 5.0);
	vec3 normal = normalize(n1 + n2 * 0.5);

	// Shallow -> deep blue from the REAL depth carried in vertex color G.
	vec4 final_color = mix(water_color, water_color_deep, clamp(v_depth, 0.0, 1.0));
	final_color.rgb += vec3(combined_ripple * 0.03 - 0.015);

	// Fresnel: water gets more reflective (sky-tinted) at grazing view angles.
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);
	final_color.rgb = mix(final_color.rgb, fresnel_color.rgb, fresnel * 0.6);

	// Alpha: clearer in the shallows, opaque in the deep, faded right at the shore.
	float shore_blend = water_shore_blend(v_shore_distance, shore_fade_distance);
	float depth_alpha = mix(0.45, 1.0, clamp(v_depth, 0.0, 1.0));
	ALPHA = final_color.a * depth_alpha * shore_blend;

	ALBEDO = final_color.rgb;
	NORMAL_MAP = normal * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.4;

	// Smooth, reflective surface.
	ROUGHNESS = clamp(0.12 + (1.0 - specular_strength) * 0.3, 0.05, 0.6);
	SPECULAR = clamp(0.5 + fresnel * 0.5, 0.0, 1.0) * specular_strength + 0.1;
	METALLIC = 0.0;
}
