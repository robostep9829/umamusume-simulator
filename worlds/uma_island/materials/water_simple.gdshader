shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;

uniform vec3 absorptioncolour : source_color;
uniform float absorptionmultiplier = 1.0;

uniform vec2 sampler1speed = vec2(0.02, 0.0);
uniform vec2 sampler2speed = vec2(0.0, 0.02);
uniform float samplermix : hint_range(0.0, 1.0, 0.1) = 0.5;
uniform vec2 samplerscale = vec2(0.1);
uniform sampler2D normal1tex : filter_linear_mipmap_anisotropic, hint_normal;
uniform sampler2D normal2tex : filter_linear_mipmap_anisotropic, hint_normal;
uniform float normalstrength : hint_range(0.0, 5.0, 0.01) = 1.0;

varying vec2 uv_custom;
varying vec2 uv2_custom;

void vertex() {
	uv_custom = VERTEX.xz * samplerscale + (sampler1speed * TIME);
	uv2_custom = VERTEX.xz * samplerscale + (sampler2speed * TIME);
}

float schlickfresnel(float ior1, float ior2, vec3 view, vec3 norm) {
	float incident = dot(view, norm);
	float reflectance = ((ior2 - ior1)/(ior2 + ior1)) * ((ior2 - ior1)/(ior2 + ior1));
	float fresnelincident = reflectance + (1.0 - reflectance) * pow(1.0 - cos(incident), 5.0);
	return clamp(fresnelincident / incident, 0.0, 1.0);
}

void fragment() {
	vec2 nmap = mix(texture(normal1tex, uv_custom), texture(normal2tex, uv2_custom), samplermix).xy;
	NORMAL += TANGENT * (nmap.x - 0.5) * normalstrength;
	NORMAL += BINORMAL * (nmap.y - 0.5) * normalstrength;

	float fresnel = schlickfresnel(1.0, 1.33, VIEW, NORMAL);

	vec3 col = mix(absorptioncolour, vec3(1.0), fresnel);
	ALBEDO = col;
	ROUGHNESS = mix(0.3, 0.0, fresnel);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ALPHA = 1.0;
}
