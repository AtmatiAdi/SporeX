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
| Host LAN / dołącz po IP / leć do drugiego gracza | F5 / F6 / F7 |
| Aktualizacja do najnowszego wydania (gdy HUD ją pokazuje) | F12 |
| Nowa losowa galaktyka z nowymi układami (debug; wyłączone u klienta LAN) | F9 |
| Pełny ekran / wyjście | F11 / Esc |
 `--host`, `--join=IP`, `--name=Ala` (multiplayer), `--starmult=K` (benchmark), `--click=x,y --clickframe=N` (symulowany klik).
Argumenty debug (po `--`): `--seed=123`, `--d=2.5e7` (start w metrach od celu), `--autozoom=4.5`, `--shot=out.png --frames=90`, `--series=1 --every=30`, `--hide=Planet/Body/Clouds`, `--quality=0`, `--bench=1` (loguje klatki > 25 ms z fazą i skalą + histogram), `--gpulog=1` (czas GPU/CPU renderu co 30 klatek), `--select=N` (przełącz na N-ty grywalny układ), `--time=10` (czas gry na starcie), `--yaw=20 --pitch=-60` (kąt kamery na starcie), `--regen=N` (w klatce N wciska F9 – test resetu galaktyki).

## Instalacja (gracze)

Pobierz **[SporeX-Setup.exe](https://github.com/AtmatiAdi/SporeX/releases/latest/download/SporeX-Setup.exe)** i uruchom. Instalator (300 KB, [tools/setup](tools/setup)) sam niczego nie zawiera: pyta GitHuba o najnowsze wydanie, pobiera `SporeX.exe`, sprawdza sumę SHA-256 i instaluje grę dla bieżącego użytkownika, bez administratora:

| co | gdzie |
|---|---|
| gra + aktualizator | `%LOCALAPPDATA%\SporeX\` |
| skróty | menu Start, pulpit |
| odinstalowanie | Ustawienia → Aplikacje → SporeX |
| reguła zapory dla LAN (jedno pytanie UAC przy instalacji, można odmówić) | „SporeX (LAN)” |
| zapisy i ustawienia | `%APPDATA%\Godot\app_userdata\SporeX` – instalacja ich nie dotyka |

Zainstalowana gra sprawdza przy starcie, czy jest nowsze wydanie. HUD pokazuje wtedy „dostępna wersja X – F12”. F12 uruchamia `SporeX-Setup.exe --update`, który czeka na zamknięcie gry, podmienia plik i uruchamia nową wersję.

## Multiplayer LAN

Cały wszechświat wynika z jednego seeda, więc dołączający dostaje od hosta tylko seed i buduje u siebie identyczną galaktykę. Potem każdy gracz kilka razy na sekundę wysyła swoją obecność: galaktykę, gwiazdę, pozycję kamery i skalę ([net_manager.gd](scripts/net/net_manager.gd)).

1. Komputer A: **F5** (host). HUD: „Sieć: host”.
2. Komputer B: **F6**, wpisz IP komputera A (albo zostaw podpowiedziany adres hosta wykrytego w LAN) i Enter.
3. Kamera B oddala się do widoku całej galaktyki, galaktyka B gaśnie, pod wygaszeniem podmienia się na galaktykę A, a kamera wlatuje prosto do gwiazdy, przy której jest host. Bez ekranu ładowania.
4. Drugi gracz to kolorowy pierścień z podpisem w miejscu jego kamery; lista graczy jest w HUD. **F7** przelatuje do drugiego gracza, a **F9** u hosta przenosi wszystkich do nowej galaktyki.

Porty: UDP 27015 (gra, ENet) i UDP 27016 (wykrywanie hostów, broadcast). Jeśli zapora zapyta – zezwól w sieci prywatnej. Bez instalatora: `run.ps1 -GameArgs "--host"` / `"--join=192.168.x.y"`.

Na razie widać tylko obecność gracza (gdzie jest, w jakiej skali), bez wspólnej rozgrywki – to następny krok (TASKS, sekcja 4).

## Wydania (deweloper)

```powershell
.\release.ps1 -Bump patch            # 0.1.0 -> 0.1.1: commit + tag + push; GitHub Actions buduje i publikuje
.\release.ps1 -Version 0.2.0 -Local  # wszystko na tym komputerze (eksport, cargo, gh release create)
.\release.ps1 -Bump minor -Local -DryRun
```

- [release.ps1](release.ps1) podnosi `config/version` w `project.godot` (i wersje w `export_presets.cfg` oraz `tools/setup/Cargo.toml`), commituje „Wydanie vX.Y.Z”, taguje i pushuje.
- [.github/workflows/release.yml](.github/workflows/release.yml) na tag `v*`:
  1. eksportuje grę ([tools/export.ps1](tools/export.ps1): standardowy Godot 4.7.2 + szablony, cache w CI),
  2. buduje i testuje instalator,
  3. liczy `SHA256SUMS.txt` i skanuje pliki Defenderem,
  4. publikuje wydanie z trzema zasobami o stałych nazwach (`SporeX.exe`, `SporeX-Setup.exe`, `SHA256SUMS.txt`) i zostawia trzy ostatnie wydania.
- Repo wydań to to samo, publiczne repo. Jedno źródło prawdy to `RELEASES_REPO` w [tools/setup/src/main.rs](tools/setup/src/main.rs); gra ma je w [updater.gd](scripts/core/updater.gd).
- Pliki nie są podpisane cyfrowo, więc SmartScreen może przy pierwszych pobraniach ostrzegać („Więcej informacji → Uruchom mimo to”). Podpis można dodać tak jak w SpectreNotes: SignPath Foundation, darmowy dla open source.

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

- Galaktyka ([galaxy_generator.gd](scripts/galaxy/galaxy_generator.gd)) – opis niżej, w sekcji „Galaktyka”.
- Układ ([system_generator.gd](scripts/system/system_generator.gd)): 3–8 planet, skompresowane orbity (jak w Spore), typy skalista/ocean/pustynna/lodowa/gazowa, jedna planeta oceaniczna – grywalna.
- Planeta ([planet_generator.gd](scripts/planet/planet_generator.gd)): mapa wysokości z szumu 3D próbkowanego na sferze (bez ściągania na biegunach), dwa przebiegi w wątku (256×128 od razu, potem 1024×512) – planeta pojawia się natychmiast i „dostraja się”. Teren przemieszczany w vertex shaderze, normalne z gradientu mapy w fragment shaderze.

## Galaktyka

**Kształt – składanie wzorców.** Galaktyka to nie jeden wzór na spiralę, tylko losowy zestaw nakładających się komponentów: dysk, ramiona spiralne, poprzeczka, pierścienie, sferoidy (zgrubienie / ciało eliptycznej), zlepy gwiazdotwórcze, strumienie pływowe, gromady. Najpierw losowana jest morfologia (8 typów: spiralna, wieloramienna, z poprzeczką, kłaczkowata, pierścieniowa, nieregularna, eliptyczna, soczewkowata), która daje zestaw bazowy, a potem **każda** galaktyka dostaje losowe dodatki: pierścienie rezonansowe, kompleksy gwiazdotwórcze, galaktykę satelitarną (55%; w części z nich krótki ogon pływowy z wyrwanych gwiazd), 18–45 gromad kulistych w halo i 15–40 gromad otwartych w dysku. Symetrię łamią:

- każde ramię ma własny skok, siłę, długość i kąt startu, część ramion się rozwidla, „pióra” odchodzą od ramion pod stałym kątem,
- wspólne dla dysku zniekształcenia: owalne ścięcie, domain warp szumem (ramiona i pierścienie wyginają się organicznie), wygięcie zewnętrznego dysku w pionie (jak w Drodze Mlecznej),
- szum gęstości odrzuca część próbek – gwiazdy tworzą kłęby i pustki zamiast równego rozkładu.

**Kolory z wieku i masy.** Każdy komponent ma zakres wieku (ramiona: 10 mln – 3 mld lat, zgrubienie: 6–12 mld, halo: 9–13 mld). Wiek jest losowany log-równomiernie, masa z funkcji IMF (Salpeter) obciętej na masie punktu zwrotnego dla tego wieku (gwiazdy cięższe już wypaliły się), temperatura z masy, kolor z krzywej ciała doskonale czarnego. Dodatkowo czerwone olbrzymy (tuż za punktem zwrotnym) i białe karły w starszych populacjach. Efekt: ramiona są niebieskie, zgrubienie żółto-czerwone, a najjaśniejsze gwiazdy (O/B, olbrzymy) dostają kolce dyfrakcyjne. HUD pokazuje klasę, temperaturę i wiek wybranej gwiazdy.

**Warstwy wizualne** ([galaxy_layer.gd](scripts/galaxy/galaxy_layer.gd)) – każda to jeden MultiMesh (jeden draw call), kolejność przez `render_priority`:

| Warstwa | Shader | Co to jest |
|---|---|---|
| Far | [far_galaxy](shaders/far_galaxy.gdshader) | 40–70 dalszych galaktyk w grupach (2,5–12 mln ly) + ~1000 odległych (głębokie pole). Każda to jeden quad z analityczną spiralą / eliptyczną / nieregularną w fragment shaderze |
| Stars | [billboard_point](shaders/billboard_point.gdshader) | 60 tys. gwiazd |
| Nebula | [nebula](shaders/nebula.gdshader) | poświata nierozdzielonych gwiazd, obszary H II (czerwień wodoru + niebieski O III), mgławice odbiciowe, pozostałości supernowych (powłoki) |
| Novae | nebula (`transients`) | supernowe: rozbłysk + rozszerzająca się fala, liczone w całości w shaderze z `TIME` (zero CPU) |
| Dust | [dust_lane](shaders/dust_lane.gdshader) | pasy pyłu (mnożenie przez transmisję – przyciemnia i zaczerwienia światło za nim) na wewnętrznych krawędziach ramion, wokół pierścieni, wzdłuż poprzeczki |
| Core | [quasar](shaders/quasar.gdshader) | supermasywna czarna dziura: dysk akrecyjny z cieniem, pierścieniem fotonowym i efektem Dopplera; w aktywnych jądrach (45%) dwa dżety z wędrującymi węzłami |

**Orientacja i zderzenia.** Galaktyka jest budowana w swojej płaszczyźnie, a potem obracana jako całość (nachylenie 0–75°, losowy azymut), więc nie leży zawsze płasko. Każdy sprite pyłu i poświaty ma w bazie instancji MultiMesha normalną dysku swojej galaktyki – spłaszczanie działa dla każdej orientacji. W ~3% seedów galaktyka jest **zderzoną parą**: druga galaktyka (własna morfologia, 50–85% rozmiaru, własne nachylenie) jest pełnym zestawem wzorców we własnej ramce, a z obu wychodzą długie ogony pływowe (jak Anteny czy Myszy). HUD pokazuje wtedy „zderzenie: X + Y”.

**Otoczenie** należy do galaktyki – jest liczone z jej seeda: 5–9 najbliższych sąsiadów (0,6–2,4 mln ly) to **prawdziwe galaktyki z tego samego generatora** (1200–3500 gwiazd każda zależnie od presetu, plus poświata i pył, własna morfologia i nachylenie, czasem nawet własne zderzenie), do tego 2–5 mega-mgławic (arkusze gazu z błądzenia losowego, ciemne węzły, młode gwiazdy). Wszystko liczy wątek roboczy po starcie (~150–350 ms, razem z buforami MultiMesha), a efekt płynnie wchodzi w ciągu ~1,5 s – bez ekranu ładowania. Kosztuje trzy dodatkowe draw calle.

Nic nie znika skokowo: przy wejściu do układu gwiezdnego mgławice, pył i jądro płynnie przygasają (do 35–60% jasności, w skali logarytmicznej między 3e17 a 3e14 m), a galaktyka zostaje na niebie w każdej skali – aż do planety, gdzie gasi ją dopiero dzienne niebo.

Triki, które trzymają wydajność: **spłaszczone billboardy** (poświata i pył ściskane wzdłuż normalnej dysku – z boku galaktyka ma cienki dysk i pas pyłu, en face pełne chmury, bez żadnej geometrii 3D), **zanikanie dużych sprite'ów** (co zajmuje prawie cały ekran lub ma kamerę w środku, zapada się do zdegenerowanego quada – przelot przez mgławicę nie kosztuje fill rate), szum bez `sin()` (stabilny na każdym GPU). Gęstość mgławic/pyłu/tła zależy od presetu jakości, ale gwiazdy i układy grywalne mają osobne pod-seedy, więc peery LAN na różnych presetach mają ten sam wszechświat.

GPU w najcięższym widoku (galaktyka z bliska, 1600×900): RTX 4050 – LOW 0,5 ms, HIGH 3,0 ms; Intel Arc (integra, LOW, z otoczeniem) – 1,3–1,9 ms, przelot galaktyka → komórka: 579/600 klatek < 16,7 ms.

### Prawdziwa liczba gwiazd – galaktyka wirtualna

Galaktyka ma **realną liczbę gwiazd** (~1,5·10¹¹ × (R / 50 tys. ly)², np. 221 mld dla R = 61 tys. ly), ale w pamięci nie ma żadnej z nich:

- **60 tys. gwiazd reprezentatywnych** (warstwa galaktyki) daje kształt z daleka – każda „waży” kilka milionów prawdziwych; resztę światła daje poświata.
- **Pole lokalne** ([local_stars.gd](scripts/galaxy/local_stars.gd) + [local_stars.gdshader](shaders/local_stars.gdshader)): reprezentatywne gwiazdy są binowane w zgrubną siatkę gęstości (R/40), przeskalowaną do realnej liczby. Przestrzeń jest pocięta na sześciany 40 ly; każdy ma deterministyczną liczbę gwiazd i seed. Blok sześcianów wokół kamery (9³ / 11³ / 13³ dla LOW / MED / HIGH, czyli ±180–260 ly) rysuje GPU – instancja to tylko (początek komórki, pierwszy indeks, liczba, seed, wiek) na paczkę 256 gwiazd, a gwiazda *i* powstaje w vertex shaderze z hasha całkowitoliczbowego: pozycja, wiek, masa z IMF, temperatura, jasność. CPU przebudowuje ~kilka tys. instancji tylko przy przekroczeniu granicy komórki.
- **Jasność z prawa odwrotnych kwadratów**: dalekie karły gasną same (zdegenerowany quad = zero wypełnienia), zostaje naturalne niebo z paralaksą.
- **Podział populacji**: ~10% gwiazd (m > 1 M☉ + olbrzymy) to populacja jasna, rysowana w całym bloku; karły (90%) tylko w 3³ komórkach przy kamerze – dalej i tak są niewidoczne. Tożsamość gwiazdy się nie zmienia.
- **Każda gwiazda to układ**: klik w gwiazdę pola lokalnego (skale 10¹³–10¹⁹ m) dodaje ją do galaktyki i generuje jej układ z seeda (komórka + indeks) – ten sam na każdej maszynie. GDScript ma lustrzaną kopię hasha; klik bada tylko komórki i gwiazdy w stożku promienia kliknięcia (52 ms zamiast 870 ms).

**Benchmark skali (Intel Arc, galaktyka z bliska, 1600×900)**

| Podejście | Gwiazd | CPU | Pamięć | GPU |
|---|---|---|---|---|
| Reprezentatywne ×1 | 60 tys. | 0,36 s generowanie | 4,6 MB bufora | 1,8–2,1 ms |
| ×10 na CPU | 600 tys. | 3,6 s | 46 MB | – |
| ×10 powielane na GPU (`--starmult=10`) | 600 tys. | 0 | 0 | 5,9 ms |
| ×100 powielane na GPU | 6 mln | (na CPU: ~36 s, ~0,7 GB) | 0 | 28 ms |
| ×1000 powielane na GPU | 60 mln | (na CPU: ~6 min, ~7 GB) | 0 | 524 ms |
| ×10 000 | 600 mln | nie uruchamiane – liniowo ~5 s/klatkę (ryzyko resetu sterownika) | | |
| **Pole lokalne, LOW** | 221 mld wirtualnie; ~1,8 mln wokół kamery, ~220 tys. na GPU | ~ms przy zmianie komórki | ~100 KB | cała klatka 2,3–2,6 ms |
| **Pole lokalne, HIGH** | 5,4 mln wokół kamery, 531 tys. na GPU | j.w. | j.w. | cała klatka 5,5–8,8 ms (z MSAA 4× i glow) |

Wniosek: brute force przestaje mieć sens przy ×10 (CPU) i ×100 (GPU), a z daleka i tak nic nie wnosi – piksel zawiera tysiące gwiazd, więcej punktów daje tylko przepalenie. Realna gęstość ma sens tylko tam, gdzie gwiazdy są rozdzielone: wokół kamery. Generowanie ~350–450 ms (GDScript, jednorazowo; F9 daje taki sam przestój).

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
scripts/net/        LAN: host/join/discovery, seed, obecność graczy (autoload)
scripts/core/updater.gd   sprawdzanie wydań na GitHubie, F12 = aktualizacja (autoload)
tools/export.ps1    eksport buildSporeX.exe (Godot + szablony pobierane raz)
tools/setup/        instalator / aktualizator (Rust, WinHTTP, bez zależności)
release.ps1, .github/workflows/release.yml   proces wydań
scripts/ui/         HUD
shaders/            billboard_point (gwiazdy), galaxy_sprite.gdshaderinc + nebula / dust_lane / far_galaxy / quasar,
                    planet_terrain, planet_ocean, atmosphere, clouds, ocean_surface, cell
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
