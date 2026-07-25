shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform float wave_height : hint_range(0.0, 2.0) = 0.5;
uniform float wave_frequency : hint_range(0.1, 5.0) = 1.2;
uniform float wave_speed : hint_range(0.0, 5.0) = 1.0;

uniform vec3 shallow_color : source_color = vec3(0.10, 0.55, 0.58);
uniform vec3 deep_color : source_color = vec3(0.02, 0.08, 0.30);
uniform float depth_scale : hint_range(0.0, 20.0) = 6.0;

uniform float fresnel_power : hint_range(1.0, 16.0) = 4.0;
uniform float fresnel_intensity : hint_range(0.0, 1.0) = 0.8;

uniform float foam_threshold : hint_range(0.0, 1.0) = 0.65;
uniform vec3 foam_color : source_color = vec3(1.0);
uniform float foam_intensity : hint_range(0.0, 1.0) = 0.5;

uniform float roughness : hint_range(0.0, 1.0) = 0.05;

uniform float detail_scale : hint_range(1.0, 20.0) = 6.0;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.35;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;

void vertex() {
	vec3 pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * wave_speed;
	float f = wave_frequency;

	float wave = sin(pos.x * f + pos.z * f * 0.8 + t) * wave_height;
	VERTEX.y += wave;

	float dx = f * cos(pos.x * f + pos.z * f * 0.8 + t) * wave_height;
	float dz = f * 0.8 * cos(pos.x * f + pos.z * f * 0.8 + t) * wave_height;

	NORMAL = normalize(vec3(-dx, 1.0, -dz));
}

void fragment() {
	float NdotV = max(dot(NORMAL, VIEW), 0.0);
	float fresnel = pow(1.0 - NdotV, fresnel_power) * fresnel_intensity;

	float depth = texture(depth_tex, SCREEN_UV).r;
	float depth_factor = clamp((depth - FRAGCOORD.z) * depth_scale, 0.0, 1.0);

	vec2 uv = UV * detail_scale;
	float f = wave_frequency * 3.0;
	float nt = TIME * wave_speed * 1.5;

	float nx = sin(uv.x * f * 3.7 + uv.y * f * 1.3 + nt * 2.0) * 0.15
	         + sin(uv.x * f * 1.1 + uv.y * f * 4.2 + nt * 1.4) * 0.10
	         + sin(uv.x * f * 5.3 + uv.y * f * 2.8 + nt * 2.5) * 0.07;
	float nz = sin(uv.x * f * 2.1 + uv.y * f * 3.4 + nt * 1.7) * 0.15
	         + sin(uv.x * f * 4.3 - uv.y * f * 1.7 + nt * 1.1) * 0.10
	         + sin(uv.x * f * 1.9 + uv.y * f * 5.1 + nt * 2.2) * 0.07;

	vec3 detail_normal = vec3(-nx * detail_strength, 1.0, -nz * detail_strength);
	NORMAL_MAP = normalize(detail_normal) * 0.5 + 0.5;

	float foam = smoothstep(foam_threshold, 1.0, NORMAL.y) * foam_intensity;

	vec3 water_col = mix(shallow_color, deep_color, depth_factor);
	ALBEDO = mix(water_col, foam_color, foam);
	ALPHA = mix(0.5, 0.9, depth_factor);
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	RIM = fresnel;
	RIM_TINT = 1.0;
}
