# WoW Forever – „Zawołaj Ekipę”

Jedno kliknięcie w grze → estetyczne powiadomienie na Discordzie, że ktoś z ekipy
stoi w kolejce do dungeona / battlegroundu albo szuka ludzi.

```
[WoW] przycisk "Zawołaj Ekipę"
   └─► WoWForeverDB (SavedVariables) + ReloadUI()
          └─► WTF/Account/<KONTO>/SavedVariables/WoWForever.lua
                 └─► WoWForeverWatcher.exe (co 2 s sprawdza notification_id)
                        └─► Discord Webhook (embed w kolorze klasy)
```

## Zawartość

| Plik | Opis |
|---|---|
| `WoWForever/WoWForever.toc` | Opis addonu dla gry |
| `WoWForever/WoWForever.lua` | Addon (przycisk, panel, zbieranie danych, `/wf`) |
| `wow_forever_watcher.py` | Program w tle (stdlib + `requests`) |
| `build_exe.bat` | Buduje `.exe` i gotową paczkę `.zip` dla znajomych |

## Instalacja (dla każdego z ekipy)

1. Skopiuj folder **`WoWForever`** do `World of Warcraft\_forever_\Interface\AddOns\`
   (Retail: `_retail_\Interface\AddOns`, Classic: `_classic_\Interface\AddOns`, klient 3.3.5a: `Interface\AddOns`).
   Nazwa folderu `_forever_` pochodzi z narzędzi społeczności – sprawdź ją w swojej instalacji.
   Nie zmieniaj nazwy folderu – od niej zależy nazwa pliku `WoWForever.lua`.
2. Uruchom **`WoWForeverWatcher.exe`** (najlepiej w osobnym folderze, np. `C:\WoWForever`).
   Przy pierwszym starcie:
   * program sam wyszuka folder gry (rejestr Battle.net + typowe lokalizacje)
     albo pozwoli go wskazać w okienku,
   * poprosi o URL webhooka Discorda
     (*Ustawienia kanału → Integracje → Webhooki → Nowy webhook → Kopiuj URL*),
   * zapisze wszystko do `config.json` obok programu i może wysłać testową wiadomość.
3. Wejdź do gry. Jeśli addon jest szary na liście – zaznacz *„Load out of date AddOns”*.

## Użycie w grze

* Panel **WoW Forever** (przesuwalny) – opcjonalna notatka + przycisk **Zawołaj Ekipę**
  (Enter w polu notatki też wysyła).
* Ten sam przycisk pojawia się przy oknie Dungeon Findera / PvP
  (`PVEFrame`, a w 3.3.5a `LFDParentFrame` i `PVPParentFrame`). **Shift + przeciągnij**, by go przesunąć.
* Kliknięcie zapisuje dane i robi `ReloadUI()` – to normalne, tak gra zapisuje plik na dysk.
  W trakcie walki przycisk jest zablokowany.

| Komenda | Działanie |
|---|---|
| `/wf` lub `/wowforever` | pokaż / ukryj panel |
| `/wf send [notatka]` | zawołaj ekipę od razu |
| `/wf test` | podgląd danych na czacie (nic nie wysyła) |
| `/wf ascii` | interfejs bez polskich znaków (gdy czcionka gry pokazuje krzaki) |
| `/wf reset` | reset pozycji panelu i przycisków |

> Emoji 📢 nie istnieje w czcionkach WoW-a, dlatego na przycisku jest ikona okrzyku bojowego.
> Na Discordzie wszystkie emoji wyświetlają się normalnie.

## World of Warcraft: Forever

Addon jest przygotowany pod Forever (interfejs `16001`, klient 1.60.1), na podstawie kodu UI Blizzarda dla 1.60.1
i addonów zaktualizowanych pod Forever (DBM, BigWigs, ElvUI, BetterFriendlist):

* Forever **nie ma Dungeon Findera** (losowej kolejki do dungeonów). Wezwanie pokaże wtedy
  „Premade / Szukam Grupy” z nazwą aktywności wystawionej w Group Finderze albo „Szukam ludzi do wspólnej gry!”.
* Przycisk przy oknie pojawia się w **Group Finderze w stylu Vanilla** (`LFGParentFrame`), a nie w `PVEFrame`.
* Kolejki na battlegroundy są odczytywane przez `GetBattlefieldStatus`, tak jak w DBM i ElvUI.
* Nazwy postaci mają imię i nazwisko (`GetUnitName`), a zamiast serwera pokazywany jest ruleset.
* „Secret values” z Midnight są pomijane (traktowane jak brak danych), więc nie powodują błędów Lua.
* Jeśli po premierze numer interfejsu będzie inny niż `16001` (16001 to wartość z bety), sprawdź go
  komendą `/dump select(4, GetBuildInfo())` i dopisz do `## Interface:`.

## Brak spamu (deduplikacja)

* `notification_id` (= `time()`) zmienia się **tylko** po kliknięciu „Zawołaj Ekipę”.
  Zwykłe `/reload` i wylogowanie nie zmieniają go, więc nic nie zostanie wysłane.
* Watcher zapamiętuje ostatnio wysłane ID w `state.json` (osobno dla każdego konta).
* Przy pierwszym uruchomieniu programu stare zapisy są ignorowane.
* Wezwania starsze niż `max_age_minutes` (domyślnie 15 min – np. kliknięte, gdy watcher był wyłączony) są pomijane.

## `config.json`

```json
{
  "wow_path": "C:\\Program Files (x86)\\World of Warcraft",
  "webhook_url": "https://discord.com/api/webhooks/...",
  "poll_interval": 2,
  "max_age_minutes": 15,
  "mention": "",
  "bot_username": "WoW Forever",
  "bot_avatar_url": ""
}
```

`mention` – np. `"@here"` albo `"<@&ID_ROLI>"`, jeśli wezwanie ma kogoś pingować.
Ponowna konfiguracja: `WoWForeverWatcher.exe --setup`, test: `WoWForeverWatcher.exe --test`.
Log programu: `watcher.log` obok programu.

## Budowanie `.exe` (PyInstaller) – krok po kroku

1. Zainstaluj Pythona 3.10+ z [python.org](https://www.python.org/downloads/)
   (zaznacz **„Add python.exe to PATH”**, zostaw zaznaczone **tcl/tk** – potrzebne do okienka wyboru folderu).
2. Otwórz wiersz poleceń w folderze projektu i zainstaluj zależności:
   ```bat
   python -m pip install requests pyinstaller
   ```
3. Zbuduj jeden plik `.exe`:
   ```bat
   python -m PyInstaller --onefile --console --clean --name WoWForeverWatcher wow_forever_watcher.py
   ```
   Gotowy plik: `dist\WoWForeverWatcher.exe`.
   Zostaw `--console` – okno pokazuje znajomym, że program działa i co wysyła
   (można je zminimalizować). Opcjonalnie dodaj `--icon ikona.ico`.
4. Spakuj dla znajomych: `WoWForeverWatcher.exe` + folder `WoWForever` (+ ten plik jako instrukcja) do `.zip`.

   **Albo zrób kroki 2–4 jednym kliknięciem: `build_exe.bat`** → powstaje `WoWForever_paczka.zip`.

Wskazówki:
* `.exe` z PyInstallera bywa fałszywie oznaczany przez antywirusy / SmartScreen
  (*Więcej informacji → Uruchom mimo to*). Pomaga budowanie na czystym, aktualnym Pythonie.
* Autostart z Windowsem: `Win+R` → `shell:startup` → wklej tam skrót do `WoWForeverWatcher.exe`.
* `config.json` zawiera URL webhooka – **nie** wkładaj swojego do paczki, każdy wpisze go przy pierwszym starcie
  (albo celowo dołącz wspólny, jeśli ufacie sobie nawzajem).

## Aktualizacja numeru wersji w `.toc`

Jeśli po patchu addon wymaga „Load out of date AddOns”, sprawdź numer w grze:
`/dump select(4, GetBuildInfo())` i dopisz go do linii `## Interface:` w `WoWForever.toc`.
