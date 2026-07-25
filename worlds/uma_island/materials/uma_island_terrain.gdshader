shader_type spatial;

// --- Layer 1: Sand (base) ---
uniform sampler2D sand_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D sand_roughness : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D sand_normal : hint_normal;
uniform vec2 sand_uv_scale = vec2(10.0);

// --- Layer 2: Dirt ---
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D dirt_roughness : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D dirt_normal : hint_normal;
uniform vec2 dirt_uv_scale = vec2(8.0);

// --- Layer 3: Grass ---
uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D grass_roughness : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D grass_normal : hint_normal;
uniform vec2 grass_uv_scale = vec2(6.0);

// --- Layer 4: Stone ---
uniform sampler2D stone_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D stone_roughness : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D stone_normal : hint_normal;
uniform vec2 stone_uv_scale = vec2(4.0);

// --- Single splatmap (R=dirt, G=grass, B=stone) ---
uniform sampler2D splatmap : source_color, filter_linear_mipmap_anisotropic;

void vertex() {
}

void fragment() {
	vec3 s_albedo = texture(sand_albedo, UV * sand_uv_scale).rgb;
	vec3 d_albedo = texture(dirt_albedo, UV * dirt_uv_scale).rgb;
	vec3 g_albedo = texture(grass_albedo, UV * grass_uv_scale).rgb;
	vec3 t_albedo = texture(stone_albedo, UV * stone_uv_scale).rgb;

	float s_rough = texture(sand_roughness, UV * sand_uv_scale).r;
	float d_rough = texture(dirt_roughness, UV * dirt_uv_scale).r;
	float g_rough = texture(grass_roughness, UV * grass_uv_scale).r;
	float t_rough = texture(stone_roughness, UV * stone_uv_scale).r;

	vec3 s_normal = texture(sand_normal, UV * sand_uv_scale).rgb * 2.0 - 1.0;
	vec3 d_normal = texture(dirt_normal, UV * dirt_uv_scale).rgb * 2.0 - 1.0;
	vec3 g_normal = texture(grass_normal, UV * grass_uv_scale).rgb * 2.0 - 1.0;
	vec3 t_normal = texture(stone_normal, UV * stone_uv_scale).rgb * 2.0 - 1.0;

	vec4 splat = texture(splatmap, UV);
	float dirt_mask = splat.r;
	float grass_mask = splat.g;
	float stone_mask = splat.b;
	float sand_mask = 1.0 - clamp(dirt_mask + grass_mask + stone_mask, 0.0, 1.0);

	float total = sand_mask + dirt_mask + grass_mask + stone_mask;
	sand_mask /= total;
	dirt_mask /= total;
	grass_mask /= total;
	stone_mask /= total;

	ALBEDO = s_albedo * sand_mask + d_albedo * dirt_mask + g_albedo * grass_mask + t_albedo * stone_mask;
	ROUGHNESS = s_rough * sand_mask + d_rough * dirt_mask + g_rough * grass_mask + t_rough * stone_mask;

	vec3 blended_normal = normalize(s_normal * sand_mask + d_normal * dirt_mask + g_normal * grass_mask + t_normal * stone_mask);
	NORMAL_MAP = blended_normal * 0.5 + 0.5;
}
