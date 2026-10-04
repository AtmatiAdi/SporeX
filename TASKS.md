# SporeX – lista zadań

Legenda: `[x]` zrobione w demie · `[ ]` do zrobienia. Kolejność w każdej sekcji ≈ priorytet.

## 0. Fundament (demo)

- [x] Wybór silnika: Godot 4.7 (.NET) – uzasadnienie w README
- [x] Kamera scale-space: jeden ciągły parametr zoomu, precyzja double, łańcuch kotwic G→S→P→L
- [x] Proceduralna galaktyka (60k gwiazd, pył, 8 grywalnych układów) – jeden draw call
- [x] Proceduralny układ słoneczny (słońce, orbity, planety, markery)
- [x] Proceduralna planeta (mapa wysokości w wątku, teren + ocean + chmury + atmosfera)
- [x] Zejście: orbita → blokada na punkcie pod kamerą (snap do wody) → atmosfera → chmury (mgła) → tafla morza → pod wodę
- [x] Faza komórki: pływanie W/S/A/D, śnieg morski, mgła podwodna
- [x] Zaznaczanie gwiazd/planet kliknięciem, dolot zamiast teleportu
- [x] Presety jakości LOW/MEDIUM/HIGH + autodetekcja GPU
- [x] Szkielet LAN: host, join, UDP discovery, sync seeda
- [x] Harness testowy: screenshoty/serie klatek z wiersza poleceń, autozoom, ukrywanie warstw, benchmark klatek
- [x] Płynność: rozgrzewka pipeline'ów, prefetch + cache map wysokości, cross-fade LOD terenu, adaptacyjna prędkość zoomu

## 1. Świat proceduralny – następne kroki

- [ ] Planeta: cubesphere + quadtree LOD terenu (obecna kula 512×256 jest OK z orbity, ale nie do chodzenia po lądzie)
- [ ] Planeta: generowanie mapy wysokości na GPU (compute shader w Forward+, fallback do wątku CPU w Compatibility)
- [ ] Planeta: biomy z temperatury/wilgotności (nie tylko z wysokości), pustynie, lód, wulkany
- [ ] Planeta: rotacja osi (nachylenie), pory dnia sterowane obrotem – już jest spin, brakuje nachylenia
- [ ] Planety nie-oceaniczne: gazowe olbrzymy (pasy, shader), lodowe, pustynne – dziś mają tylko kolor i promień
- [ ] Księżyce i pierścienie
- [ ] Układ: widoczność planet z daleka (dziś tylko markery) – tarcze o minimalnym rozmiarze w px
- [x] Galaktyka v2: morfologia ze składanych wzorców (8 typów + losowe dodatki), kolory gwiazd z wieku i masy, mgławice, pasy pyłu, supernowe, kwazar z dżetami, gromady, galaktyka satelitarna ze strumieniem, sąsiednie galaktyki i głębokie pole, F9 = nowa galaktyka
- [x] Galaktyka: losowa orientacja w przestrzeni, rzadkie zderzone pary z ogonami pływowymi
- [x] Otoczenie z seeda galaktyki: 5–9 prawdziwych sąsiednich galaktyk + mega-mgławice, generowane w wątku, płynne wejście
- [x] Galaktyka wirtualna: realna liczba gwiazd (~10¹¹), pole lokalne w realnej gęstości na GPU, podział jasne/karły, klik = nowy układ
- [ ] Lot między gwiazdami: dziś zmiana gwiazdy przy małym `d` to prawie skok (offset przycinany do 3·d) – dodać automatyczne oddalenie → przelot → zbliżenie
- [ ] Pole lokalne na skali galaktyki: kolejne poziomy LOD komórek (np. 320 ly tylko z olbrzymami), żeby przejście 3e19 → 1e20 m było gęstsze
- [ ] Siatka gęstości w wątku (dziś ~dziesiątki ms na starcie, na głównym wątku)
- [ ] Galaktyka: generowanie w wątku (dziś ~400 ms na starcie i przy F9) – bufor MultiMesh podmieniany, gdy gotowy
- [ ] Galaktyka: jądro jako cel do zaznaczenia (dolot do czarnej dziury – dziś fokus przechodzi na gwiazdę przy 3e20 m)
- [ ] Galaktyka: mgławica „od środka” przy przelocie przez nią (dziś sprite'y rozpuszczają się w pobliżu kamery)
- [ ] Galaktyka: nazwy/typy mgławic i gromad w UI, dźwięk/ping przy supernowej w pobliżu
- [ ] Niebo przy planecie: pas galaktyki już jest (ta sama geometria), dodać jego ekspozycję zależną od fazy (dzień/noc/pod wodą)
- [ ] Galaktyka: streaming sąsiadów – gwiazdy w promieniu N ly dostają nazwy/układy lazy
- [ ] Ocean: dno z mapy wysokości (dziś woda jest „bez dna”), przezroczystość zależna od głębokości
- [ ] Ocean: powierzchnia widziana od spodu (refrakcja, promienie światła), gradient głębokości
- [ ] Przejście lądowe: kamera ma dojść do lądu tak samo jak do wody (potrzebny LOD terenu)

## 2. Faza komórki

- [ ] Sterowanie „do kursora” (jak w Spore) obok WASD; głębokość Q/E
- [ ] Wygląd komórki: edytor części (wici, rzęski, kolce, usta) – dane w jednym seedzie/ID
- [ ] Pożywienie (plankton), inne komórki, drapieżniki – spawn proceduralny w promieniu kamery
- [ ] Wzrost: rozmiar komórki × skala świata = „świat robi się mniejszy” (kamera ma to za darmo – zmienia się tylko `CELL_RADIUS`)
- [ ] Ewolucja komórka → organizm wodny (ryba) → wyjście na ląd – bez ekranów, przez zmianę skali `d` i modelu

## 3. Dalsze fazy (szkielet)

- [ ] Stwór (ląd), plemię, cywilizacja, kosmos – każda to nowy zakres `d` + warstwy; kamera scale-space już to obsługuje
- [ ] Kosmos: statek jako „fokus”, latanie między układami = ten sam zoom co dziś

## 4. Multiplayer LAN

- [x] Obecność graczy: galaktyka, gwiazda (także wirtualna), pozycja kamery, skala – znacznik + nazwa + lista w HUD, F7 = leć do gracza
- [ ] Replikacja w skali planety/komórki: pozycja w łańcuchu kotwic (gwiazda, planeta, punkt L, pozycja lokalna) + `d` – komórki innych graczy widoczne, gdy są w tej samej skali
- [x] Dołączenie = przelot kamery z własnej galaktyki do galaktyki hosta (oddalenie → wygaszenie → podmiana seeda → zbliżenie do gwiazdy hosta); F9 hosta przenosi wszystkich
- [ ] Gra przez internet (dziś tylko LAN / IP): Steam Networking (P2P bez przekierowania portów) albo relay
- [ ] Autorytet hosta, snapshoty, interpolacja
- [x] Dołączanie po IP (F6, podpowiedź z wykrytych hostów)
- [ ] Lobby/UI: lista hostów, nazwy graczy w menu
- [ ] Zapis/wczytanie: seed + stan gracza (mały plik), brak zapisu świata (deterministyczny)

## 5. Wydajność i jakość

- [ ] Profilowanie na Intel Arc (Compatibility renderer) – cel: 60 FPS w każdej skali
- [ ] Renderer Compatibility: sprawdzić globalne uniformy shaderów, brak reverse-Z, glow
- [ ] Przenieść generowanie mapy wysokości do C# lub GDExtension (dziś ~350 ms w wątku GDScript przy 1024×512; prefetch to maskuje, ale przy 8+ planetach w kolejce warto)
- [ ] Start: generowanie galaktyki + budowa buforów (60k gwiazd + ~5k sprite'ów) w wątku, żeby pierwsze klatki nie trwały 150 ms (patrz sekcja 1)
- [ ] Occlusion/visibility: warstwy poza zakresem `d` są ukrywane – dodać `visibility_range` na meshach
- [ ] HDR/tonemapping per faza (kosmos vs dzień na planecie vs pod wodą)
- [ ] Cienie tylko w HIGH, tylko przy powierzchni
- [ ] Automatyczny test regresji: `--autozoom` + montaż + próg „białych pikseli” w CI

## 6. Dystrybucja

- [x] Eksport Windows (jeden exe), instalator z GitHub Releases, aktualizacja z gry (F12), release.ps1 + GitHub Actions
- [ ] Podpis cyfrowy (SignPath Foundation, jak SpectreNotes) – bez niego SmartScreen ostrzega
- [ ] Ikona gry (exe, skróty, instalator)
- [ ] Steam: zmiana nazwy (znak „Spore” należy do EA), Steamworks, GodotSteam

## 7. UX

- [ ] Ekran startowy = widok galaktyki (już jest), tylko subtelne UI: nazwa układu przy markerze, tooltip planety
- [ ] Wskaźnik skali (pasek logarytmiczny) zamiast surowych metrów w HUD
- [ ] Dźwięk: ambient zależny od fazy (kosmos → wiatr → pod wodą), cross-fade po `d`
- [ ] Ustawienia (rozdzielczość, vsync, jakość, czułość myszy) zapisywane w `user://`
