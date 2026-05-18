@tool
extends Terrain3D
# =====================================================================
#  ARAZI KURULUM - her sey Inspector'dan (script acmaya gerek YOK)
#  Terrain3D dugumunu sec -> asagidaki gruplari ayarla ->
#  "Yeniden Uret" kutusunu isaretle. EXR'den bolge verisi + materyal
#  + doku yeniden bake edilir. (Sadece EDITORDE calisir; oyunda degil.)
#
#  Diger ayarlar (mesh_lods, collision, vertex_spacing, world_background
#  vb.) zaten Terrain3D dugumunun / Material / Assets'in kendi
#  Inspector bolumlerinde.
# =====================================================================

const MAT_PATH := "res://terrain/terrain_material.tres"
const AST_PATH := "res://terrain/terrain_assets.tres"

@export_group("Arazi Kaynagi")
@export_file("*.exr") var kaynak_exr := "res://heightmap/yarimada_16bit.exr"
## Arazinin toplam genisligi (metre). Yatay olcek = bu / (EXR piksel-1).
@export var dunya_genisligi_m: float = 5120.0
## En yuksek nokta (metre). EXR 0..1 degeri bununla carpilir.
@export var max_yukseklik_m: float = 340.0
@export var yukseklik_offset_m: float = 0.0
## Acik: ada dunya orijinine ortalanir (oyuncu 0,0'da tepede dogar).
@export var orijine_ortala: bool = true
@export_dir var veri_klasoru := "res://terrain/terrain_data"

@export_group("Zemin Dokusu")
@export var albedo: Texture2D = preload(
	"res://textures/forrest_ground_01_diff_1k.png")
@export var normal: Texture2D = preload(
	"res://textures/forrest_ground_01_nor_gl_1k.png")
## Doku kac metrede bir tekrar etsin (kucuk = sik desen).
@export var doku_tekrar_m: float = 10.0
## DETILING - tekrar desenini kirar AMA MOBILDE PAHALIDIR (kasma yapar).
## Varsayilan 0 (kapali). Sadece guclu cihazda artir.
@export_range(0.0, 1.0) var rastgele_aci: float = 0.0
## DETILING kaydirma - aym uyari (mobilde pahali).
@export_range(0.0, 1.0) var rastgele_kaydir: float = 0.0
@export_range(0.0, 1.0) var ao_gucu: float = 0.6
@export_range(0.0, 1.0) var puruzluluk: float = 0.0

@export_group("Islem")
## Bunu ISARETLE -> yukaridaki ayarlarla araziyi yeniden uretir.
@export var yeniden_uret: bool = false: set = _set_yeniden_uret


func _set_yeniden_uret(v: bool) -> void:
	yeniden_uret = false
	if v and Engine.is_editor_hint():
		_yeniden_uret()


func _yeniden_uret() -> void:
	if data == null:
		push_error("[arazi] Terrain3D.data yok - sahne editorde acik mi?")
		return
	var img: Image = Terrain3DUtil.load_image(
		kaynak_exr, ResourceLoader.CACHE_MODE_IGNORE)
	if img == null:
		push_error("[arazi] EXR yuklenemedi: " + kaynak_exr)
		return
	var sz := img.get_size()
	vertex_spacing = dunya_genisligi_m / float(maxi(sz.x - 1, 1))
	var off := 0.0
	if orijine_ortala:
		off = float(sz.x - 1) * vertex_spacing * 0.5
	var imgs: Array[Image] = []
	imgs.resize(Terrain3DRegion.TYPE_MAX)
	imgs[Terrain3DRegion.TYPE_HEIGHT] = img
	data.import_images(imgs, Vector3(-off, 0.0, -off),
		yukseklik_offset_m, max_yukseklik_m)
	data.calc_height_range(true)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(veri_klasoru))
	data.save_directory(veri_klasoru)
	data_directory = veri_klasoru

	var tex := Terrain3DTextureAsset.new()
	tex.name = "ground"
	tex.id = 0
	tex.albedo_color = Color(1, 1, 1, 1)
	tex.albedo_texture = albedo
	tex.normal_texture = normal
	tex.uv_scale = 1.0 / maxf(doku_tekrar_m, 0.01)
	tex.ao_strength = ao_gucu
	tex.roughness = puruzluluk
	tex.detiling_rotation = rastgele_aci
	tex.detiling_shift = rastgele_kaydir
	var ast := Terrain3DAssets.new()
	var tl: Array[Terrain3DTextureAsset] = [tex]
	ast.texture_list = tl

	var mat := Terrain3DMaterial.new()
	mat.show_checkered = false
	mat.auto_shader = false
	mat.dual_scaling = false
	mat.world_background = 0

	ResourceSaver.save(ast, AST_PATH)
	ResourceSaver.save(mat, MAT_PATH)
	assets = load(AST_PATH)
	material = load(MAT_PATH)
	print("[arazi] yeniden uretildi: bolge=", data.get_region_count(),
		" vertex_spacing=", vertex_spacing,
		" merkez_h=", data.get_height(Vector3.ZERO))
