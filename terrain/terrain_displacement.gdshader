// =====================================================================
//  CDLOD TERRAIN SHADER  -  Godot 4.6  (YALNIZ Forward Mobile)
//  - Tek paylasilan grid mesh ([0..1] XZ), tek GLOBAL heightmap.
//  - Vertex'te textureLod (Forward Mobile vertex'te explicit LOD ister).
//  - Geomorphing: LOD geciste vertex kaba grid'e yumusak kayar -> pop YOK,
//    komsu bloklar daima uyumlu -> catlak YOK -> skirt YOK.
//  - Normal tek global dokudan turetilir -> chunk dikisi YOK.
//  - 3 katman (alcak/egim/yuksek) + detay; her biri diffuse + normal.
//    Doku atanmamissa duz renk dolgusuna duser (albedo_on/normal_on).
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

// --- duz renk dolgusu (doku yoksa) ---
uniform vec3 low_color  : source_color = vec3(0.34, 0.46, 0.22);
uniform vec3 high_color : source_color = vec3(0.62, 0.60, 0.55);
uniform vec3 slope_color: source_color = vec3(0.40, 0.35, 0.28);

// --- katman dokulari (8 yuva) ---
uniform sampler2D low_albedo    : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D low_normal    : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D slope_albedo  : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D slope_normal  : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D high_albedo   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D high_normal   : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : hint_normal,  filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_tex     : hint_roughness_r, filter_linear_mipmap, repeat_enable;

uniform bool  albedo_on      = false;      // diffuse dokular atandi mi
uniform bool  normal_on      = false;      // normal map'ler atandi mi
uniform bool  detail_on      = false;      // detay katmani atandi mi
uniform bool  rough_on       = false;      // roughness dokusu atandi mi
uniform float tex_tiling     = 24.0;       // metre / doku tekrari
uniform float detail_tiling  = 4.0;        // metre / detay tekrari
uniform float detail_strength= 0.35;
uniform float high_start     = 0.55;       // yukseklik karisim esikleri (0..1 ham)
uniform float high_end       = 0.78;
uniform float slope_start    = 0.35;       // egim karisim esikleri
uniform float slope_end      = 0.70;
uniform float normal_strength= 1.0;

varying vec2 v_uv;
varying vec3 v_wpos;

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
	v_wpos = VERTEX;
}

// tanjant uzayindan dunya uzayina (terrain mesh'te TANGENT yok -> n'den kur)
vec3 apply_nmap(vec3 n, vec3 nm, float k) {
	nm = nm * 2.0 - 1.0;
	nm.xy *= k;
	vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t  = normalize(cross(up, n));
	vec3 b  = cross(n, t);
	return normalize(t * nm.x + b * nm.y + n * nm.z);
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

	// karisim agirliklari: yukseklik (alcak<->yuksek), uzerine egim (kaya)
	float wh = smoothstep(high_start, high_end, h01);
	float wsl = smoothstep(slope_start, slope_end, slope);

	vec2 uvw = v_wpos.xz / max(tex_tiling, 0.001);

	if (albedo_on) {
		vec3 a_low  = texture(low_albedo,  uvw).rgb;
		vec3 a_high = texture(high_albedo, uvw).rgb;
		vec3 a_slp  = texture(slope_albedo, uvw).rgb;
		vec3 col = mix(a_low, a_high, wh);
		col = mix(col, a_slp, wsl);
		if (detail_on) {
			vec3 dt = texture(detail_albedo, v_wpos.xz / max(detail_tiling, 0.001)).rgb;
			col *= mix(vec3(1.0), dt * 2.0, detail_strength);
		}
		ALBEDO = col;
	} else {
		vec3 col = mix(low_color, high_color, clamp(h01, 0.0, 1.0));
		col = mix(col, slope_color, smoothstep(0.35, 0.7, slope));
		ALBEDO = col;
	}

	if (normal_on) {
		vec3 nm_low  = texture(low_normal,  uvw).rgb;
		vec3 nm_high = texture(high_normal, uvw).rgb;
		vec3 nm_slp  = texture(slope_normal, uvw).rgb;
		vec3 nm = mix(nm_low, nm_high, wh);
		nm = mix(nm, nm_slp, wsl);
		if (detail_on) {
			vec3 nd = texture(detail_normal, v_wpos.xz / max(detail_tiling, 0.001)).rgb;
			nm = normalize(mix(nm, nd, detail_strength * 0.5));
		}
		n = apply_nmap(n, nm, normal_strength);
	}

	NORMAL = n;
	ROUGHNESS = rough_on ? texture(rough_tex, uvw).r : 1.0;
	METALLIC = 0.0;
}
