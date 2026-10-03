// NOTE: Shader automatically converted from Godot Engine 4.7.2.stable.mono's StandardMaterial3D.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 albedo : source_color;
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;

uniform float distance_fade_min : hint_range(0.0, 4096.0, 0.01);
uniform float distance_fade_max : hint_range(0.0, 4096.0, 0.01);
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0, 0.001);
uniform float normal_mix : hint_range(0.0, 1.0, 0.001);

uniform sampler2D texture_normal : hint_roughness_normal, filter_linear_mipmap, repeat_enable;

uniform float z_clip_scale : hint_range(0.01, 1.0, 0.00001);

void vertex() {
	//UV = UV * uv1_scale.xy + uv1_offset.xy;

	// Billboard Mode: Y-Billboard
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(normalize(cross(vec3(0.0, 1.0, 0.0), MAIN_CAM_INV_VIEW_MATRIX[2].xyz)), 0.0),
			vec4(0.0, 1.0, 0.0, 0.0),
			vec4(normalize(cross(MAIN_CAM_INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
			MODEL_MATRIX[3]);

	// Billboard Keep Scale: Enabled
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	//NORMAL = mix(vec3(0.0, 1.0, 0.0), NORMAL, normal_mix);
	Z_CLIP_SCALE = z_clip_scale;
}

void light() {
	// Two-sided diffuse: use abs(NdotL) so a sun behind the plane
	// lights the front face the same way as a sun in front.
	// NOTE: defining light() replaces the default Burley/SchlickGGX,
	// so diffuse (and a simple specular) is accumulated manually here.
	// NORMAL, LIGHT, VIEW are in view space.
	//vec3 N = normalize(NORMAL);
	//vec3 L = normalize(LIGHT);
	//vec3 V = normalize(VIEW);

	float n_dot_l = dot(NORMAL, LIGHT);
	DIFFUSE_LIGHT += LIGHT_COLOR * abs(n_dot_l) * ATTENUATION / PI * (1.0 - METALLIC);

	// Two-sided specular: bend the normal toward the light so the
	// highlight matches the front-lit case.
	vec3 N_spec = NORMAL * (n_dot_l < 0.0 ? -1.0 : 1.0);
	vec3 H = normalize(LIGHT + VIEW);
	float n_dot_h = clamp(dot(N_spec, H), 0.0, 1.0);
	float shininess = mix(64.0, 8.0, clamp(ROUGHNESS, 0.0, 1.0));
	SPECULAR_LIGHT += LIGHT_COLOR * pow(n_dot_h, shininess) * ATTENUATION * SPECULAR_AMOUNT * (1.0 - ROUGHNESS) * (1.0 - METALLIC);
}

void fragment() {
	vec2 base_uv = UV;

	vec4 albedo_tex = texture(texture_albedo, base_uv);
	ALBEDO = albedo.rgb * albedo_tex.rgb;


	// Normal Map: Enabled
	NORMAL_MAP = texture(texture_normal, base_uv).rgb;
// 	NORMAL_MAP_DEPTH = normal_scale;
	ALPHA *= albedo.a * albedo_tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;

	{
		// Distance Fade: Object Dither
		float fade_distance = length((VIEW_MATRIX * MODEL_MATRIX[3]));

		// Use interleaved gradient noise, which is fast but still looks good.
		const vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
		float fade = clamp(smoothstep(distance_fade_min, distance_fade_max, fade_distance), 0.0, 1.0);
		// Use a hard cap to prevent a few stray pixels from remaining when past the fade-out distance.
		if (fade < 0.001 || fade < fract(magic.z * fract(dot(FRAGCOORD.xy, magic.xy)))) {
			discard;
		}
	}
}
