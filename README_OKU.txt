==========================================================
  FARE SIMULATORU - TERRAIN PROJESI
  Godot 4.6.x ile acin (4.6.2 onerilir)
==========================================================

HAZIR GELIR - HICBIR SEY YAPMAYIN
---------------------------------
  Projeyi acin, oynatma tusuna (F5) basin. Arazi gelir.
  Chunk verileri (terrain/chunks/) zip icinde HAZIR.
  Editorde de arazi otomatik gorunur (proje acilir acilmaz).


KONTROLLER (test kamerasi)
--------------------------
  Sag tik (basili) : etrafa bak
  W A S D          : hareket
  Q / E            : alcal / yuksel
  Shift            : hizli mod


KLASOR YAPISI
-------------
  project.godot                   -> proje dosyasi
  heightmap/yarimada_16bit.exr     -> kaynak heightmap
  terrain/terrain_data.bin         -> HAZIR birlestirilmis chunk verisi
  terrain/terrain_meta.json        -> chunk tarifi
  terrain/terrain_displacement.gdshader -> GPU displacement shader
  scripts/terrain_chunk_manager.gd -> streaming + LOD + collision
  scripts/terrain_baker.gd         -> chunk olusturucu (buton ile)
  scripts/fly_camera.gd            -> test kamerasi
  scenes/main.tscn                 -> ana sahne (her sey bagli)


EXR'I DEGISTIRIRSENIZ - "CHUNK OLUSTUR" BUTONU
----------------------------------------------
  Sadece kaynak heightmap'i degistirirseniz chunk'lari
  yeniden uretmeniz gerekir:
    1. main.tscn'de "TerrainBaker" node'unu secin.
    2. Inspector'da "CHUNK OLUSTUR" butonuna basin.
    3. Output'ta "CHUNK OLUSTURMA TAMAM" yazisini bekleyin.
  Arazi aynali cikarsa: TerrainBaker > flip_y secenegini acip
  tekrar basin.


AYARLAR (Inspector)
-------------------
  TerrainChunkManager node'unu secin. Tum ayarlar gruplu:
    World Scale  -> texel_size (chunk metre boyutu), height_scale
    Streaming    -> load_radius, performans ayarlari
    LOD          -> detay seviyeleri
    Collision    -> fare cevresi collision yaricapi
  auto_center acik -> arazi dunya orijinine ortali.


NOTLAR
------
  - Renderer = Mobile (Project Settings).
  - Chunk formati: ham half-float .bin (3.6 MB toplam).
  - Editor onizleme kasarsa: editor_preview_lod degerini 2 yapin.
==========================================================
