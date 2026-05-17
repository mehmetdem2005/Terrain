// =====================================================================
//  TERRAIN DISPLACEMENT SHADER  -  Godot 4.6  (Mobile renderer uyumlu)
//  Duz paylasilan PlaneMesh'i height texture ile vertex'te yukari iter.
//  Mesh hic bake edilmez -> her chunk ayni mesh'i kullanir, sadece
//  height_tex degisir. LOD = mesh subdivide sayisi.
// =====================================================================
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable;

uniform float height_scale   = 12.0;
uniform float height_offset  = 0.0;
uniform float chunk_world_size = 128.0;
// UV uzayinda bir texel (komsu ornekleme offseti) = 1/verts
uniform float uv_texel       = 0.00775194;
// Komsu iki texel arasi DUNYA mesafesi (normal egim olcegi) = chunk/(verts-1)
uniform float world_step     = 1.0;

uniform bool use_albedo = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform vec3 low_color  : source_color = vec3(0.34, 0.46, 0.22);
uniform vec3 high_color : source_color = vec3(0.62, 0.60, 0.55);
uniform vec3 slope_color: source_color = vec3(0.40, 0.35, 0.28);

varying float v_h01;
varying float v_slope;

float sample_h(vec2 uv) {
	return texture(height_tex, uv).r * height_scale + height_offset;
}

void vertex() {
	vec2 uv = UV;
	float h  = sample_h(uv);
	VERTEX.y += h;

	// Komsu texel farkindan normal (vertex'te 2 ekstra fetch -> ucuz)
	// merkezi fark -> chunk birlesiminde isik kaynakli cizgiyi azaltir
	float hxp = sample_h(uv + vec2(uv_texel, 0.0));
	float hxn = sample_h(uv - vec2(uv_texel, 0.0));
	float hzp = sample_h(uv + vec2(0.0, uv_texel));
	float hzn = sample_h(uv - vec2(0.0, uv_texel));
	vec3 n = normalize(vec3(hxn - hxp, 2.0 * world_step, hzn - hzp));
	NORMAL = n;

	v_h01   = texture(height_tex, uv).r;
	v_slope = 1.0 - clamp(n.y, 0.0, 1.0);
}

void fragment() {
	vec3 col;
	if (use_albedo) {
		col = texture(albedo_tex, UV).rgb;
	} else {
		col = mix(low_color, high_color, clamp(v_h01, 0.0, 1.0));
	}
	col = mix(col, slope_color, smoothstep(0.35, 0.7, v_slope));
	ALBEDO = col;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
