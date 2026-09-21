# SporeX

Gra inspirowana Spore, ale z jednym świeżym założeniem na czele: **jedna ciągła galaktyka, zero ekranów ładowania, zero „poziomów”**. Od widoku całej galaktyki, przez gromady, układ słoneczny, planetę, chmury, taflę oceanu – aż do pojedynczej komórki – jest jeden gest: scroll.

Aktualny stan: **demo proceduralnego świata** – galaktyka → układ → planeta → atmosfera → ocean → komórka, którą można pływać. Zero obiektów, zero przeciwników. Szkielet LAN (host / join / discovery + synchronizacja seeda) jest, replikacji stanu graczy jeszcze nie ma.

## Uruchomienie

Wymagany Godot **4.7.2 (.NET)** – instalowany przez `winget install GodotEngine.GodotEngine.Mono`.

```powershell
.\run.ps1              # uruchamia grę
.\run.ps1 -Editor      # otwiera edytor Godot z projektem
```

Sterowanie:

| Akcja | Klawisz |
|---|---|
| Zaznacz gwiazdę (zielony pierścień) / planetę | LPM |
| Zoom (ciągły, przez wszystkie skale) | Scroll, Shift = 3× szybciej, PgUp/PgDn = ciągły |
| Obrót kamery | przeciągnij LPM/PPM |
| Pływanie komórką (po dojściu do skali komórki) | W/S/A/D, Shift = sprint |
| Jakość LOW / MEDIUM / HIGH | F1 / F2 / F3 |
| Host LAN / dołącz do pierwszego hosta w LAN | F5 / F6 |
| Pełny ekran / wyjście | F11 / Esc |

Argumenty debug (po `--`): `--seed=123`, `--d=2.5e7` (start w metrach od celu), `--autozoom=4.5`, `--shot=out.png --frames=90`, `--series=1 --every=30`, `--hide=Planet/Body/Clouds`, `--quality=0`, `--bench=1` (loguje klatki > 25 ms z fazą i skalą + histogram), `--gpulog=1` (czas GPU/CPU renderu co 30 klatek), `--select=N` (przełącz na N-ty grywalny układ), `--time=10` (czas gry na starcie).

## Decyzja: silnik

**Godot 4.7** (GDScript jako klej + shadery GLSL na GPU; C# i GDExtension C++/Rust dostępne, gdy trzeba). Powody, w kolejności ważności:

1. **Dwa renderery w jednym buildzie**: Forward+ (Vulkan) dla mocnych kart, Compatibility (OpenGL 3.3) dla integr. Ten sam kod, przełącznik w ustawieniach projektu, plus presety jakości (`GraphicsSettings`).
2. **Wydajność tam, gdzie się liczy**: cała galaktyka (60 000 gwiazd + pył) to *jeden* draw call MultiMesh; teren planety, woda, atmosfera, komórka, „śnieg morski” – wszystko liczone w shaderach. CPU dotyka tylko kilku uniformów na klatkę. Ciężkie generowanie (mapa wysokości) idzie w wątku roboczym.
3. **GDScript ma 64-bitowe `float`** – dokładnie to, czego potrzebuje ciągła skala 25 rzędów wielkości (patrz niżej). Hot-pathy CPU (gdy się pojawią: LOD terenu, fizyka stworów, AI) idą do C#/GDExtension.
4. **Wbudowany multiplayer** (ENet, RPC, high-level API) + UDP broadcast do LAN discovery – bez zewnętrznych zależności.
5. Lekki edytor, hot-reload, brak licencji/royalties, mały binarny (~90 MB z .NET).

Odrzucone: **Unreal** (za ciężki na integrę, sam edytor to problem), **Unity** (licencja, waga, brak korzyści względem Godota przy tej grafice), **Bevy/Rust** (świetna wydajność ECS, ale brak edytora, niedojrzały multiplayer i rendering, ogromny narzut na iterację), **własny silnik** (miesiące pracy zanim pojawi się pierwsza planeta).

## Architektura: jak działa „brak ekranów ładowania”

Problem: float32 na GPU ma ~7 cyfr precyzji. Galaktyka ma 10²¹ m, komórka 10⁻⁴ m. Nie da się tego trzymać w jednym układzie współrzędnych.

Rozwiązanie – **kamera scale-space** ([scale_camera.gd](scripts/core/scale_camera.gd)):

- Jeden parametr zoomu `d` (metry, double) – odległość kamery od punktu skupienia.
- Kamera **zawsze** stoi 10 jednostek sceny od punktu skupienia; co klatkę cały świat jest przeskalowywany tak, że `u = d / 10` metrów = 1 jednostka. Renderer nigdy nie widzi dużych liczb.
- **Łańcuch kotwic** ([universe.gd](scripts/core/universe.gd)): `G` (środek galaktyki) → `S` (wybrana gwiazda) → `P` (środek planety) → `L` (punkt lądowania na tafli morza). Każda warstwa renderowania jest zakotwiczona w jednym z nich, a jej pozycja w scenie to `(kotwica − fokus) / u` liczone w double ([dvec3.gd](scripts/core/dvec3.gd)) i dopiero na końcu rzutowane na float.
- Punkt skupienia **ślizga się po łańcuchu** w funkcji `log(d)`: środek galaktyki → gwiazda → planeta → punkt na powierzchni pod kamerą → 2,5 m pod wodą (komórka). Każde przejście to gładki blend, więc nie ma żadnego „cięcia”.
- Przy 1,2 promienia planety kamera **blokuje się** na punkcie pod sobą (jeśli to ląd – snap do najbliższej wody z mapy wysokości, różnica rozpływa się jako pan) i od tej pory orbituje wokół niego w lokalnym układzie „góra = pion”. Odblokowanie przy oddalaniu jest ciągłe (wymuszone pitch −90° przy progu + wygaszany roll).
- Zmiana zaznaczenia (klik w inną gwiazdę/planetę) nie teleportuje – dodaje offset, który wygasa wykładniczo = kamera „dolatuje”.

Warstwy (każda w metrach, poza galaktyką w ly): [galaxy_layer.gd](scripts/galaxy/galaxy_layer.gd) · [system_layer.gd](scripts/system/system_layer.gd) · [planet_layer.gd](scripts/planet/planet_layer.gd) · [surface_layer.gd](scripts/surface/surface_layer.gd) · [cell_layer.gd](scripts/cell/cell_layer.gd). Widoczność każdej warstwy zależy od `d`; cross-fade planeta-kula ↔ lokalna tafla wody między 40 a 20 km.

## Proceduralność i determinizm

Jeden 64-bitowy seed galaktyki → [seeds.gd](scripts/core/seeds.gd) wyprowadza seedy gwiazd → układów → planet → terenu. Ta sama liczba daje ten sam wszechświat na każdej maszynie, dlatego host LAN wysyła klientowi tylko seed ([net_manager.gd](scripts/net/net_manager.gd)).

- Galaktyka ([galaxy_generator.gd](scripts/galaxy/galaxy_generator.gd)): 2–5 ramion spiralnych, losowe skręcenie, bulge, dysk wykładniczy, klasy widmowe O–M, 8 grywalnych układów (gwiazdy F/G/K w środkowym dysku).
- Układ ([system_generator.gd](scripts/system/system_generator.gd)): 3–8 planet, skompresowane orbity (jak w Spore), typy skalista/ocean/pustynna/lodowa/gazowa, jedna planeta oceaniczna – grywalna.
- Planeta ([planet_generator.gd](scripts/planet/planet_generator.gd)): mapa wysokości z szumu 3D próbkowanego na sferze (bez ściągania na biegunach), dwa przebiegi w wątku (256×128 od razu, potem 1024×512) – planeta pojawia się natychmiast i „dostraja się”. Teren przemieszczany w vertex shaderze, normalne z gradientu mapy w fragment shaderze.

## Struktura

```
project.godot
scenes/main.tscn                 – jedna scena, wszystko budowane w kodzie
scripts/main.gd                  – spina kamerę, warstwy, światło, mgłę, HUD, harness testowy
scripts/core/       dvec3, seeds, universe (łańcuch kotwic), scale_camera
scripts/galaxy/     generator + warstwa (MultiMesh)
scripts/system/     generator + warstwa (słońce, orbity, markery)
scripts/planet/     generator (wątek) + warstwa (teren, ocean, chmury, atmosfera)
scripts/surface/    lokalna tafla morza
scripts/cell/       komórka gracza + śnieg morski
scripts/settings/   presety jakości (autoload)
scripts/net/        LAN: host/join/discovery, sync seeda (autoload)
scripts/ui/         HUD
shaders/            billboard_point, planet_terrain, planet_ocean, atmosphere, clouds, ocean_surface, cell
TASKS.md            roadmapa
```

## Wydajność – zasady, których trzymamy się od pierwszego commita

- Nic nie jest ładowane z dysku w trakcie gry: wszystko generowane, ciężkie rzeczy w wątkach lub na GPU, wyniki wchodzą do sceny asynchronicznie.
- Jeden draw call na warstwę tam, gdzie się da (MultiMesh + instance custom data).
- Żadnych `set_instance_*` w pętli na klatkę; dane wchodzą przez `MultiMesh.buffer`.
- Brak cieni dynamicznych w demie; efekty (glow, MSAA, FXAA, skalowanie 3D) tylko przez presety jakości.
- Test regresji renderingu: `--autozoom` + `--series` daje serię klatek przez wszystkie skale; skrypt montażu liczy „białe piksele” (tak znaleźliśmy NaN w shaderze atmosfery).

## Benchmark płynności zoomu (2026-09-22)

`run.ps1 -GameArgs "--d=1.2e21","--autozoom=5","--bench=1","--shot=b.png","--frames=600"` – przelot galaktyka → komórka w 10 s.

| Co mierzono | Przed | Po |
|---|---|---|
| Wejście do układu gwiezdnego (pierwsze rysowanie materiałów) | **87 ms** stutter | brak – pipeline'y kompilowane na starcie (`_force_all_visible`, 3 klatki rozgrzewki) |
| Planeta po zmianie celu | 0,4–1 s „płaska” kula, potem pop terenu | teren od razu – 8 grywalnych planet liczone w tle na starcie ([height_map_service.gd](scripts/planet/height_map_service.gd)), nowe poziomy detalu wchodzą cross-fade'em (`hm_blend`) |
| Chmury po zmianie celu | regeneracja tekstury szumu (pop) | jedna tekstura, per-planeta offset UV |
| Zoom przez „puste” zakresy (lot do gwiazdy 3e16→1e13 m, planeta-kropka 6e10→3e9 m) | liniowo w log(d) – odczuwalny zastój | mnożnik prędkości ×2,8 / ×2 z miękkimi krawędziami (`ScaleCamera.zoom_rate_mult`) |
| Mapa wysokości 1024×512 (wątek roboczy) | 350 ms | bez zmian – nie blokuje klatki; kandydat do C#/compute (TASKS) |
| GPU, dowolna skala, HIGH, 1280×720 | ≤ 5 ms | ≤ 5 ms |
| Start (generowanie galaktyki + kompilacja) | ~0,3 s | ~0,5 s (o rozgrzewkę), tylko raz |

Wynik: 577/600 klatek < 16,7 ms, dwie klatki startowe > 100 ms, reszta < 33 ms.
