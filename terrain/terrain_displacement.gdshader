// =====================================================================
//  CDLOD TERRAIN SHADER  -  Godot 4.6  (YALNIZ Forward Mobile)
//  - Tek paylasilan grid mesh ([0..1] XZ), tek GLOBAL heightmap.
//  - Vertex'te textureLod (Forward Mobile vertex'te explicit LOD ister).
//  - Geomorphing: LOD geciste vertex kaba grid'e yumusak kayar -> pop YOK.
//  - Normal MORF'SUZ global konumdan -> blok dikisi/cizgi YOK.
//  - TEK materyal: albedo + normal + rough + ao (hepsi opsiyonel).
// =====================================================================
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable;

uniform vec2  world_min      = vec2(-2560.0, -2560.0);
uniform float world_size     = 5120.0;
uniform float height_scale   = 340.0;
uniform float height_offset  = 0.0;
uniform float hr             = 2049.0;

uniform vec2  node_origin    = vec2(0.0);
uniform float node_size      = 512.0;
uniform float morph_start    = 200.0;
uniform float morph_end      = 300.0;
uniform float grid_cells     = 32.0;

uniform vec3  cam_pos        = vec3(0.0);

// duz renk dolgusu (albedo dokusu yoksa)
uniform vec3 low_color  : source_color = vec3(0.34, 0.46, 0.22);
uniform vec3 high_color : source_color = vec3(0.62, 0.60, 0.55);
uniform vec3 slope_color: source_color = vec3(0.40, 0.35, 0.28);

// TEK materyal dokulari
uniform sampler2D albedo_tex : source_color,    filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal,     filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_tex  : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_tex     : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform bool  albedo_on      = false;
uniform bool  normal_on      = false;
uniform bool  rough_on       = false;
uniform bool  ao_on          = false;
uniform float tex_tiling     = 12.0;
uniform float normal_strength= 0.5;
uniform float ao_strength    = 1.0;

// SPLAT (doku boyama): SINIRSIZ zemin, texel basina en baskin 4
// (indeks,agirlik). splat_on=false iken bu blok HIC calismaz -> mevcut
// arazi birebir korunur.
uniform bool  splat_on       = false;
uniform float layer_count    = 1.0;
uniform sampler2D splat_idx  : filter_nearest, repeat_disable;
uniform sampler2D splat_w    : filter_linear,  repeat_disable;
uniform sampler2DArray layer_albedo_arr : source_color,      filter_linear_mipmap, repeat_enable;
uniform sampler2DArray layer_normal_arr : hint_normal,       filter_linear_mipmap, repeat_enable;
uniform sampler2DArray layer_rough_arr  : hint_roughness_r,  filter_linear_mipmap, repeat_enable;
uniform sampler2DArray layer_ao_arr     : hint_default_white,filter_linear_mipmap, repeat_enable;
uniform bool  layer_albedo_on = false;
uniform bool  layer_normal_on = false;
uniform bool  layer_rough_on  = false;
uniform bool  layer_ao_on     = false;

// DELIK (hole) maskesi: R8, 1=opak 0=delik. hole_on=false iken HIC
// orneklenmez (&& kisa-devre) -> mevcut arazi birebir korunur.
uniform bool  hole_on        = false;
uniform sampler2D hole_tex   : filter_linear, repeat_disable;

varying vec2 v_uv;       // morf'lanmis (geometri)
varying vec2 v_uv_geo;   // MORF'SUZ -> normal/aydinlatma (dikis YOK)
varying vec2 v_wxz;      // MORF'SUZ dunya XZ -> doku/splat/delik (kayma YOK)

float sample_raw(vec2 uv) {
	return textureLod(height_tex, clamp(uv, 0.0, 1.0), 0.0).r;
}

void vertex() {
	vec2 gp = clamp(VERTEX.xz, 0.0, 1.0);

	vec2 w0  = node_origin + gp * node_size;
	vec2 uv0 = (w0 - world_min) / world_size;
	float h0 = sample_raw(uv0) * height_scale + height_offset;

	float d  = distance(cam_pos, vec3(w0.x, h0, w0.y));
	float mk = clamp((d - morph_start) / max(morph_end - morph_start, 0.001),
					 0.0, 1.0);

	vec2 gp2 = gp - fract(gp * (grid_cells * 0.5)) * (2.0 / grid_cells) * mk;

	vec2 w   = node_origin + gp2 * node_size;
	vec2 uv  = (w - world_min) / world_size;
	float h  = sample_raw(uv) * height_scale + height_offset;

	VERTEX = vec3(w.x, h, w.y);
	v_uv = uv;
	v_uv_geo = uv0;
	v_wxz = w0;          // MORF'SUZ -> doku LOD geciste KAYMAZ
}

vec3 apply_nmap(vec3 n, vec3 nm, float k) {
	nm = nm * 2.0 - 1.0;
	nm.xy *= k;
	vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t  = normalize(cross(up, n));
	vec3 b  = cross(n, t);
	return normalize(t * nm.x + b * nm.y + n * nm.z);
}

void fragment() {
	if (hole_on) {
		vec2 huv = clamp((v_wxz - world_min) / world_size, 0.0, 1.0);
		if (texture(hole_tex, huv).r < 0.5) discard;
	}

	float t  = 1.0 / (hr - 1.0);
	float ws = world_size / (hr - 1.0);
	float hL = sample_raw(v_uv_geo - vec2(t, 0.0)) * height_scale;
	float hR = sample_raw(v_uv_geo + vec2(t, 0.0)) * height_scale;
	float hD = sample_raw(v_uv_geo - vec2(0.0, t)) * height_scale;
	float hU = sample_raw(v_uv_geo + vec2(0.0, t)) * height_scale;
	vec3 n = normalize(vec3(hL - hR, 2.0 * ws, hD - hU));

	float h01   = sample_raw(v_uv_geo);
	float slope = 1.0 - clamp(n.y, 0.0, 1.0);

	vec2 uvw = v_wxz / max(tex_tiling, 0.001);

	if (splat_on && layer_albedo_on) {
		vec2 suv = clamp((v_wxz - world_min) / world_size, 0.0, 1.0);
		vec4 si = texture(splat_idx, suv);
		vec4 sw = texture(splat_w, suv);
		float wsum = sw.r + sw.g + sw.b + sw.a;
		if (wsum < 1e-4) { sw = vec4(1.0, 0.0, 0.0, 0.0); wsum = 1.0; }
		float inv = 1.0 / wsum;
		float lmax = max(layer_count - 1.0, 0.0);
		float i0 = clamp(floor(si.r * 255.0 + 0.5), 0.0, lmax);
		float i1 = clamp(floor(si.g * 255.0 + 0.5), 0.0, lmax);
		float i2 = clamp(floor(si.b * 255.0 + 0.5), 0.0, lmax);
		float i3 = clamp(floor(si.a * 255.0 + 0.5), 0.0, lmax);

		vec3 alb = texture(layer_albedo_arr, vec3(uvw, i0)).rgb * sw.r;
		alb += texture(layer_albedo_arr, vec3(uvw, i1)).rgb * sw.g;
		alb += texture(layer_albedo_arr, vec3(uvw, i2)).rgb * sw.b;
		alb += texture(layer_albedo_arr, vec3(uvw, i3)).rgb * sw.a;
		ALBEDO = alb * inv;

		if (layer_normal_on) {
			vec3 nm = texture(layer_normal_arr, vec3(uvw, i0)).rgb * sw.r;
			nm += texture(layer_normal_arr, vec3(uvw, i1)).rgb * sw.g;
			nm += texture(layer_normal_arr, vec3(uvw, i2)).rgb * sw.b;
			nm += texture(layer_normal_arr, vec3(uvw, i3)).rgb * sw.a;
			n = apply_nmap(n, nm * inv, normal_strength);
		}
		NORMAL = n;

		if (layer_rough_on) {
			float rg = texture(layer_rough_arr, vec3(uvw, i0)).r * sw.r;
			rg += texture(layer_rough_arr, vec3(uvw, i1)).r * sw.g;
			rg += texture(layer_rough_arr, vec3(uvw, i2)).r * sw.b;
			rg += texture(layer_rough_arr, vec3(uvw, i3)).r * sw.a;
			ROUGHNESS = rg * inv;
		} else {
			ROUGHNESS = 1.0;
		}

		if (layer_ao_on) {
			float ao = texture(layer_ao_arr, vec3(uvw, i0)).r * sw.r;
			ao += texture(layer_ao_arr, vec3(uvw, i1)).r * sw.g;
			ao += texture(layer_ao_arr, vec3(uvw, i2)).r * sw.b;
			ao += texture(layer_ao_arr, vec3(uvw, i3)).r * sw.a;
			AO = mix(1.0, ao * inv, ao_strength);
			AO_LIGHT_AFFECT = 1.0;
		}
		METALLIC = 0.0;
	} else {
		if (albedo_on) {
			ALBEDO = texture(albedo_tex, uvw).rgb;
		} else {
			vec3 col = mix(low_color, high_color, clamp(h01, 0.0, 1.0));
			col = mix(col, slope_color, smoothstep(0.35, 0.7, slope));
			ALBEDO = col;
		}

		if (normal_on) {
			n = apply_nmap(n, texture(normal_tex, uvw).rgb, normal_strength);
		}
		NORMAL = n;

		ROUGHNESS = rough_on ? texture(rough_tex, uvw).r : 1.0;
		if (ao_on) {
			float ao = texture(ao_tex, uvw).r;
			AO = mix(1.0, ao, ao_strength);
			AO_LIGHT_AFFECT = 1.0;
		}
		METALLIC = 0.0;
	}
}
