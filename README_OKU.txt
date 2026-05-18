==========================================================
  FARE SIMULATORU - TERRAIN PROJESI (Terrain3D)
  Godot 4.6.x ile acin (4.6.2 onerilir)
==========================================================

HAZIR GELIR - HICBIR SEY YAPMAYIN
---------------------------------
  Projeyi acin, oynatma tusuna (F5) basin. Arazi gelir.
  Arazi = resmi Terrain3D eklentisi (addons/terrain_3d).
  Bolge verisi terrain/terrain_data/ icinde HAZIR (25 bolge).
  Editorde Terrain3D dugumunu secince Terrain3D arac cubugu
  cikar: sculpt, delik, doku boyama, renk - hepsi yerlesik.


KONTROLLER (oyuncu)
-------------------
  Masaustu : W A S D yuru, Shift kos, Space zipla,
             sol tik fare kilitle (bakis), ESC birak.
  Mobil    : sol-alt sanal joystick yuru, sag yari surukle
             bakis, ZIPLA dugmesi.


KLASOR YAPISI
-------------
  project.godot                  -> proje dosyasi
  addons/terrain_3d/             -> resmi Terrain3D eklentisi
  heightmap/yarimada_16bit.exr   -> kaynak heightmap (import kaynagi)
  terrain/terrain_data/          -> Terrain3D bolge dosyalari (.res)
  terrain/terrain_material.tres  -> Terrain3D materyali
  terrain/terrain_assets.tres    -> doku asset'i (forrest_ground)
  scripts/player.gd              -> oyuncu (Terrain3D.data.get_height)
  scripts/fly_camera.gd          -> serbest kamera (opsiyonel)
  scripts/virtual_joystick.gd    -> mobil joystick UI
  scenes/main.tscn               -> ana sahne (Terrain3D + Player)
  tools/import_heightmap.gd      -> EXR -> bolge verisi (tek seferlik)
  tools/make_terrain_resources.gd-> material/assets uretici


EXR'I DEGISTIRIRSENIZ - YENIDEN IMPORT
--------------------------------------
  Kaynak heightmap'i degistirirseniz bolge verisini
  yeniden uretin (terminalde, proje kokunde):
    godot --headless -s tools/import_heightmap.gd
  Bu, heightmap/yarimada_16bit.exr dosyasini
  terrain/terrain_data/ icine yeniden yazar.
  Dunya olcegi: ~5120 m genislik, ~340 m yukseklik
  (vertex_spacing = 5120 / (EXR genisligi - 1)).


ARAZIYI DUZENLEME (Terrain3D editoru)
-------------------------------------
  1. scenes/main.tscn ac, 3B sekmesine gec.
  2. Sahne agacindan "Terrain3D" dugumunu sec.
  3. Ust/yan Terrain3D arac cubugu: Sculpt (yukselt/alcalt/
     yumusat/duzlestir/egim), Delik, Doku boyama, Renk.
  4. Degisiklikler bolge dosyalarina kaydedilir (Ctrl+S
     veya Terrain3D > Save). terrain/terrain_data/ guncellenir.


COLLISION / OYUNCU
------------------
  Terrain3D collision_mode = DYNAMIC_GAME (varsayilan): oyun
  sirasinda kamera cevresinde otomatik collision uretir.
  Terrain layer 1, oyuncu mask 1 -> CharacterBody3D yurur.
  Spawn'da Terrain3D.data.get_height ile yere oturulur
  (player.gd spawn_xz ile spawn noktasi ayarlanir).


NOTLAR
------
  - Renderer = Mobile (Project Settings).
  - Terrain3D ikilileri tum platformlar icin gelir; Android
    arm64 + arm32 terrain.gdextension'a eklenmistir.
  - Bolge boyutu 256, mesh LOD ve detay Terrain3D dugumunde.
==========================================================
