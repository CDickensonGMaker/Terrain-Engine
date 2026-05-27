shader_type spatial;
render_mode depth_draw_always, cull_disabled;

// Include shared water utilities
#include "res://water/water_common.gdshaderinc"

// Coastal water colors (blue-gray ocean)
uniform vec4 water_color : source_color = vec4(0.25, 0.35, 0.45, 0.85);
uniform vec4 water_color_deep : source_color = vec4(0.12, 0.20, 0.30, 0.92);
uniform float depth_fade : hint_range(0.1, 20.0) = 8.0;

// Shore blending
uniform float shore_fade_distance : hint_range(0.5, 10.0) = 4.0;

// Foam
uniform vec4 foam_color : source_color = vec4(0.95, 0.95, 0.90, 0.8);
uniform float foam_threshold : hint_range(0.0, 1.0) = 0.3;
uniform float foam_intensity : hint_range(0.0, 2.0) = 1.0;

// Wave animation (more dramatic than ponds)
uniform float wave_strength : hint_range(0.0, 0.1) = 0.04;
uniform float wave_scale : hint_range(1.0, 20.0) = 6.0;
uniform float wave_speed : hint_range(0.1, 3.0) = 1.2;

// Ocean swell (large slow waves)
uniform float swell_strength : hint_range(0.0, 0.05) = 0.02;
uniform float swell_scale : hint_range(0.5, 5.0) = 2.0;
uniform float swell_speed : hint_range(0.1, 1.0) = 0.3;
uniform vec2 swell_direction = vec2(1.0, 0.3);

// Specular
uniform float specular_strength : hint_range(0.0, 1.0) = 0.5;
uniform float specular_shininess : hint_range(1.0, 128.0) = 48.0;

// Optional normal map
uniform sampler2D normal_map : hint_normal;
uniform bool use_normal_map = false;

// Shore distance from vertex color (R channel)
varying float v_shore_distance;
varying vec2 v_world_uv;
varying float v_depth;

void vertex() {
	// Shore distance stored in vertex color R channel
	v_shore_distance = COLOR.r * 20.0;  // Scale: 0-1 maps to 0-20 meters

	// Depth stored in vertex color G channel
	v_depth = COLOR.g * 10.0;  // Scale: 0-1 maps to 0-10 meters

	// World-space UV for consistent wave pattern
	v_world_uv = VERTEX.xz * 0.02;

	// Add vertex displacement for ocean swell
	float swell = water_wave(VERTEX.xz * 0.01, normalize(swell_direction), swell_scale, swell_speed, TIME);
	VERTEX.y += swell * swell_strength * v_shore_distance;  // Less swell near shore
}

void fragment() {
	// Ocean swell (large rolling waves)
	float swell = water_wave(v_world_uv, normalize(swell_direction), swell_scale, swell_speed, TIME);

	// Smaller choppy waves
	float wave1 = water_wave(v_world_uv, vec2(1.0, 0.2), wave_scale, wave_speed, TIME);
	float wave2 = water_wave(v_world_uv, vec2(-0.5, 0.8), wave_scale * 1.3, wave_speed * 0.8, TIME);
	float wave3 = water_wave(v_world_uv, vec2(0.3, -0.6), wave_scale * 0.7, wave_speed * 1.2, TIME);

	float combined_wave = (swell * 0.4 + wave1 * 0.3 + wave2 * 0.2 + wave3 * 0.1);

	// Distort UVs
	vec2 distorted_uv = v_world_uv + vec2(combined_wave * wave_strength, combined_wave * wave_strength * 0.7);

	// Generate procedural normals from waves
	vec3 normal1 = water_normal_from_height(v_world_uv, wave_scale, wave_speed, TIME, wave_strength * 12.0);
	vec3 normal2 = water_normal_from_height(v_world_uv * 1.3, wave_scale * 0.7, wave_speed * 0.8, TIME, wave_strength * 8.0);
	vec3 swell_normal = water_normal_from_height(v_world_uv * 0.5, swell_scale, swell_speed, TIME, swell_strength * 20.0);

	vec3 blended_normal = normalize(normal1 + normal2 * 0.5 + swell_normal * 0.3);

	// Use normal map if provided
	vec3 normal;
	if (use_normal_map) {
		vec3 normal_sample = texture(normal_map, distorted_uv).rgb * 2.0 - 1.0;
		normal = normalize(normal_sample + blended_normal * 0.4);
	} else {
		normal = blended_normal;
	}

	// Depth-based color mixing
	float depth_factor = clamp(v_depth / depth_fade, 0.0, 1.0);
	vec4 base_color = water_color_by_depth(water_color, water_color_deep, depth_factor, 1.0);

	// Add wave color variation
	base_color.rgb += vec3(combined_wave * 0.05 - 0.025);

	// Foam calculation
	float foam = 0.0;

	// Shore foam (breaking waves)
	float shore_foam_factor = 1.0 - smoothstep(0.0, shore_fade_distance * 2.0, v_shore_distance);
	float wave_crest = smoothstep(0.6, 0.9, combined_wave);
	foam += shore_foam_factor * wave_crest * foam_intensity;

	// Whitecap foam on wave crests in deeper water
	float whitecap = smoothstep(0.75, 0.95, combined_wave) * 0.3;
	foam += whitecap * foam_intensity * depth_factor;

	// Apply foam
	foam = clamp(foam, 0.0, 1.0);
	vec3 final_color = mix(base_color.rgb, foam_color.rgb, foam * foam_color.a);

	// Shore blending - fade alpha near edges
	float shore_blend = water_shore_blend(v_shore_distance, shore_fade_distance);
	float final_alpha = base_color.a * shore_blend;

	// Increase alpha where there's foam
	final_alpha = mix(final_alpha, 1.0, foam * 0.5);

	// Apply color
	ALBEDO = final_color;
	ALPHA = final_alpha;

	// Normal mapping
	NORMAL_MAP = normal * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.6;

	// Specular/roughness for highlights (ocean is more reflective)
	ROUGHNESS = 1.0 - specular_strength;
	SPECULAR = specular_strength;
	METALLIC = 0.0;
}
