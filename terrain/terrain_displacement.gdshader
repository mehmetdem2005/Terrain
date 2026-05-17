// =====================================================================
//  CDLOD TERRAIN SHADER  -  Godot 4.6  (YALNIZ Forward Mobile)
//  - Tek paylasilan grid mesh ([0..1] XZ), tek GLOBAL heightmap.
//  - Vertex'te textureLod (Forward Mobile vertex'te explicit LOD ister).
//  - Geomorphing: LOD geciste vertex kaba grid'e yumusak kayar -> pop YOK,
//    komsu bloklar daima uyumlu -> catlak YOK -> skirt YOK.
//  - Normal tek global dokudan turetilir -> chunk dikisi YOK.
// =====================================================================
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable;

uniform vec2  world_min      = vec2(-2560.0, -2560.0);
uniform float world_size     = 5120.0;
uniform float height_scale   = 340.0;
uniform float height_offset  = 0.0;
uniform float hr             = 2049.0;     // global heightmap cozunurluk

// --- per-blok (havuzdaki MeshInstance materyali her karede gunceller) ---
uniform vec2  node_origin    = vec2(0.0);  // blok dunya XZ kosesi
uniform float node_size      = 512.0;      // blok dunya kenar uzunlugu
uniform float morph_start    = 200.0;
uniform float morph_end      = 300.0;
uniform float grid_cells     = 32.0;       // mesh kenar hucre sayisi

uniform vec3  cam_pos        = vec3(0.0);

uniform vec3 low_color  : source_color = vec3(0.34, 0.46, 0.22);
uniform vec3 high_color : source_color = vec3(0.62, 0.60, 0.55);
uniform vec3 slope_color: source_color = vec3(0.40, 0.35, 0.28);

varying vec2 v_uv;

float sample_raw(vec2 uv) {
	return textureLod(height_tex, clamp(uv, 0.0, 1.0), 0.0).r;
}

void vertex() {
	vec2 gp = clamp(VERTEX.xz, 0.0, 1.0);          // mesh [0..1]

	vec2 w0  = node_origin + gp * node_size;
	vec2 uv0 = (w0 - world_min) / world_size;
	float h0 = sample_raw(uv0) * height_scale + height_offset;

	float d  = distance(cam_pos, vec3(w0.x, h0, w0.y));
	float mk = clamp((d - morph_start) / max(morph_end - morph_start, 0.001),
					 0.0, 1.0);

	// kaba grid'e (her 2. vertex) yumusak kayma -> geomorph
	vec2 gp2 = gp - fract(gp * (grid_cells * 0.5)) * (2.0 / grid_cells) * mk;

	vec2 w   = node_origin + gp2 * node_size;
	vec2 uv  = (w - world_min) / world_size;
	float h  = sample_raw(uv) * height_scale + height_offset;

	VERTEX = vec3(w.x, h, w.y);
	v_uv = uv;
}

void fragment() {
	float t  = 1.0 / (hr - 1.0);                    // 1 texel (uv)
	float ws = world_size / (hr - 1.0);             // 1 texel (metre)
	float hL = sample_raw(v_uv - vec2(t, 0.0)) * height_scale;
	float hR = sample_raw(v_uv + vec2(t, 0.0)) * height_scale;
	float hD = sample_raw(v_uv - vec2(0.0, t)) * height_scale;
	float hU = sample_raw(v_uv + vec2(0.0, t)) * height_scale;
	vec3 n = normalize(vec3(hL - hR, 2.0 * ws, hD - hU));

	float h01   = sample_raw(v_uv);
	float slope = 1.0 - clamp(n.y, 0.0, 1.0);

	vec3 col = mix(low_color, high_color, clamp(h01, 0.0, 1.0));
	col = mix(col, slope_color, smoothstep(0.35, 0.7, slope));
	ALBEDO = col;
	NORMAL = n;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
