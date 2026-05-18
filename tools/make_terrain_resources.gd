extends SceneTree

# terrain_material.tres + terrain_assets.tres uretir (forrest_ground doku).
# Calistir: godot --headless -s tools/make_terrain_resources.gd

const DIFF := "res://textures/forrest_ground_01_diff_1k.png"
const NORM := "res://textures/forrest_ground_01_nor_gl_1k.png"


func _initialize() -> void:
	var tex := Terrain3DTextureAsset.new()
	tex.name = "ground"
	tex.id = 0
	tex.albedo_color = Color(1, 1, 1, 1)
	tex.albedo_texture = load(DIFF)
	tex.normal_texture = load(NORM)
	tex.uv_scale = 0.1            # ~10 m doku tekrari (eski tex_tiling=10)
	tex.ao_strength = 0.6
	tex.roughness = 0.0
	# Doku tekrarini kir (Terrain3D "detiling" - tekrar deseni gozukmesin):
	tex.detiling_rotation = 0.3   # her tile'a rastgele aci
	tex.detiling_shift = 0.3      # her tile'a rastgele kaydirma

	var assets := Terrain3DAssets.new()
	var tl: Array[Terrain3DTextureAsset] = [tex]
	assets.texture_list = tl

	# Terrain3D'nin KENDI varsayilan shader'i kullanilir (C++ ile uyumlu,
	# renderer'a gore otomatik uyarlanir). Onceki extras/lightweight
	# override'i 1.0.1 control-map'i yanlis cozup egimlerde SIYAH lekeye
	# yol aciyordu - kaldirildi.
	var mat := Terrain3DMaterial.new()
	mat.show_checkered = false
	mat.auto_shader = false
	mat.dual_scaling = false      # mobilde pahali - kapali
	mat.world_background = 0      # NONE -> harita disi cizilmez (skirt yok)

	var e1 := ResourceSaver.save(assets, "res://terrain/terrain_assets.tres")
	var e2 := ResourceSaver.save(mat, "res://terrain/terrain_material.tres")
	print("assets save=", e1, " material save=", e2)
	quit(0)
