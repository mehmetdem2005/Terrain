@tool
extends Node
class_name TerrainBaker
# =====================================================================
#  TERRAIN BAKER  -  Godot 4.6
#  EXR heightmap'i -> TEK birlestirilmis veri dosyasi olarak yazar:
#    terrain/terrain_data.bin   (tum chunk'lar pes pese)
#    terrain/terrain_meta.json  (chunk tarifi)
#  Tek dosya = Android'de zip cikarinca kaybolma riski yok.
#
#  KULLANIM: Sahnede TerrainBaker node'unu secin -> Inspector'da
#  "CHUNK OLUSTUR" butonuna basin. (Sadece EXR'i degistirdiyseniz gerekli.)
# =====================================================================

@export_group("Bake Ayarlari")
## Kaynak EXR heightmap dosyasi
@export_file("*.exr") var source_exr: String = "res://heightmap/yarimada_16bit.exr"
## Birlestirilmis chunk verisinin yazilacagi dosya
@export_file("*.bin") var data_file: String = "res://terrain/terrain_data.bin"
## Metadata dosyasi
@export_file("*.json") var meta_file: String = "res://terrain/terrain_meta.json"
## Hedef cozunurluk - chunk_size'a tam bolunmeli (1254 -> 1280)
@export var target_size: int = 1280
## Chunk basina texel sayisi
@export var chunk_size: int = 128
## Arazi EXR'a gore aynali cikarsa acin (dikey eksende cevirir)
@export var flip_y: bool = false

@warning_ignore("unused_private_class_variable")
@export_tool_button("CHUNK OLUSTUR") var _btn_bake = bake


func bake() -> void:
	# --- 1) EXR'i yukle ---
	var src := Image.load_from_file(source_exr)
	if src == null:
		var tex := load(source_exr) as Texture2D
		if tex != null:
			src = tex.get_image()
	if src == null:
		push_error("[Baker] EXR yuklenemedi: " + source_exr)
		return
	print("[Baker] Kaynak EXR: ", src.get_size(), "  format: ", src.get_format())

	# --- 2) Tek kanal float + hedef boyut ---
	src.convert(Image.FORMAT_RF)
	if src.get_width() != target_size or src.get_height() != target_size:
		src.resize(target_size, target_size, Image.INTERPOLATE_BILINEAR)
		print("[Baker] Yeniden boyut: ", target_size, "x", target_size)
	if flip_y:
		src.flip_y()

	var cps := int(target_size / chunk_size)
	var verts := chunk_size + 1
	var tile_bytes := verts * verts * 4          # RF = 4 bayt/texel (32-bit)
	var chunk_meta := {}
	var g_min := INF
	var g_max := -INF

	# --- 3) Tum chunk'lari TEK tampona pes pese yaz (cy-major, cx-minor) ---
	var combined := PackedByteArray()
	for cy in cps:
		for cx in cps:
			var img := Image.create(verts, verts, false, Image.FORMAT_RF)
			var c_min := INF
			var c_max := -INF
			for y in verts:
				for x in verts:
					var sx: int = clampi(cx * chunk_size + x, 0, target_size - 1)
					var sy: int = clampi(cy * chunk_size + y, 0, target_size - 1)
					var h: float = src.get_pixel(sx, sy).r
					img.set_pixel(x, y, Color(h, 0.0, 0.0))
					c_min = minf(c_min, h)
					c_max = maxf(c_max, h)
			# img zaten FORMAT_RF (32-bit float) - tam hassasiyet, basamaklanma yok
			combined.append_array(img.get_data())
			chunk_meta["%d_%d" % [cx, cy]] = {"min": c_min, "max": c_max}
			g_min = minf(g_min, c_min)
			g_max = maxf(g_max, c_max)

	# --- 4) Tek veri dosyasini yaz ---
	var df := FileAccess.open(data_file, FileAccess.WRITE)
	if df == null:
		push_error("[Baker] Veri dosyasi yazilamadi: " + data_file)
		return
	df.store_buffer(combined)
	df.close()

	# --- 5) Metadata ---
	var meta := {
		"chunk": chunk_size,
		"verts_per_chunk": verts,
		"chunks_per_side": cps,
		"target_size": target_size,
		"format": "rf",
		"packed": true,
		"tile_bytes": tile_bytes,
		"data_min": g_min,
		"data_max": g_max,
		"chunks": chunk_meta,
	}
	var mf := FileAccess.open(meta_file, FileAccess.WRITE)
	mf.store_string(JSON.stringify(meta, "\t"))
	mf.close()

	print("[Baker] CHUNK OLUSTURMA TAMAM -> %d chunk | %d bayt | aralik %.4f .. %.4f"
			% [cps * cps, combined.size(), g_min, g_max])

	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs:
			fs.scan()
