### CEL PROJEKTU
Gdy ktoś z naszej ekipy wchodzi do gry i zapisuje się na Dungeon (LFG/RDF), Battleground lub po prostu tworzy grupę i szuka ludzi, chce kliknąć jeden przycisk w grze ("📢 Zawołaj Ekipę"). Kliknięcie tego przycisku zapisuje dane o kolejce/grupie do pliku `SavedVariables` i wykonuje `ReloadUI()`, a lekki skrypt w Pythonie działający w tle na komputerze wykrywa zmianę w pliku i wysyła estetyczne powiadomienie na nasz kanał Discord przez **Discord Webhook**.

---

### ARCHITEKTURA I WYMAGANIA TECHNICZNE

#### CZĘŚĆ 1: Addon do WoW-a ("WoW Forever")
1. **Kompatybilność API:**
   - Zastosuj wrapper sprawdzający wersję klienta (`GetBuildInfo()`), tak aby pobieranie statusu kolejki i ról działało zarówno na starszym API (np. WotLK 3.3.5a / Classic: `GetLFGMode`, `GetLFGRoles`, `GetBattlefieldStatus`, `GetNumPartyMembers`) jak i nowszym API (`C_LFGList`, `GetNumGroupMembers`).
2. **Interfejs (UI) w grze:**
   - Stwórz niewielki, estetyczny, przesuwalny przycisk w stylu standardowego UI WoW-a z napisem **"📢 Zawołaj Ekipę"** (oraz obsługę komendy `/wf` lub `/wowforever`).
   - Dodaj małe pole tekstowe (opcjonalna krótka notatka, np. "Idziemy na 2 szybkie dungeony") lub możliwość kliknięcia przycisku od razu bez wpisywania czegokolwiek.
   - Dodaj przycisk także bezpośrednio przy oknie Dungeon Findera (`LFDParentFrame` / `PVEFrame`) oraz Battlegroundów (`PVPParentFrame`), aby był zawsze pod ręką podczas zapisywania się.
3. **Zbierane dane po kliknięciu przycisku:**
   - `notification_id`: Unikalny znacznik czasu (`time()`), **tylko i wyłącznie aktualizowany w momencie kliknięcia przycisku "Zawołaj Ekipę"** (dzięki temu zwykłe `/reload` lub wylogowanie z gry nie zmieni `notification_id` i nie wyśle duplikatu na Discorda!).
   - `player_name`: Nick postaci.
   - `player_class`: Klasa postaci (angielski token np. `WARRIOR`, `MAGE` do kolorowania na Discordzie) oraz poziom postaci (`UnitLevel("player")`).
   - `player_role`: Wybrana rola lub role (Tank / Healer / DPS).
   - `activity_type`: Typ aktywności (`Dungeon`, `Battleground`, `Premade / Szukam Grupy`).
   - `activity_name`: Konkretna nazwa dungeona/BG (jeśli wykryto aktywną kolejkę) lub domyślny status "Szukam ludzi do wspólnej gry!", jeśli przycisk kliknięto przed wejściem w kolejkę.
   - `group_size`: Aktualny stan grupy (np. `2/5`) oraz lista nicków osób, które już są w party.
   - `custom_note`: Opcjonalna notatka wpisana przez gracza.
4. **Zapis i przeładowanie:**
   - Po kliknięciu przycisku addon zapisuje tablicę do `WoWForeverDB` (w `SavedVariables`), wyświetla na czacie informację `"WoW Forever: Wysyłam powiadomienie na Discorda..."` i wywołuje `ReloadUI()`, aby natychmiast zrzucić plik `WoWForever.lua` na dysk.

---

#### CZĘŚĆ 2: Aplikacja w tle w Pythonie (`wow_forever_watcher.py`)
1. **Automatyczne wykrywanie ścieżki `SavedVariables`:**
   - Po pierwszym uruchomieniu skrypt pozwala wybrać folder z grą (lub sam skanuje folder `WTF/Account/*/SavedVariables/WoWForever.lua`), dzięki czemu znajomi nie muszą ręcznie szukać swojego konta w folderze `WTF`.
   - Konfiguracja (ścieżka do WoW-a oraz URL Webhooka Discorda) zapisuje się w prostym pliku `config.json` obok programu.
2. **Nasłuchiwanie i brak spamu (Deduplikacja):**
   - Skrypt monitoruje plik `WoWForever.lua` (co 2 sekundy lub przez `watchdog`).
   - Parsuje tabelę Lua i sprawdza pole `notification_id`.
   - Wysyła wiadomość na Discorda **TYLKO wtedy**, gdy `notification_id` jest nowsze niż ostatnio wysłane ID (zapisane lokalnie). Ignoruje pierwsze uruchomienie programu (stare zapisy) oraz zwykłe wylogowania z gry.
3. **Wygląd wiadomości na Discordzie (Bogaty Discord Embed przez Webhook):**
   - **Kolor paska bocznego (Embed Color):** Dokładny kolor klasy postaci z WoW-a (np. Paladyn `#F58CBA`, Mag `#3FC7EB`, Wojownik `#C69B6D`, Druid `#FF7C0A` itd.).
   - **Tytuł:** `⚔️ [Nick] (Lvl [Poziom] [Klasa]) woła ekipę do gry!`
   - **Pola (Fields):**
     - `🎯 Aktywność`: Nazwa dungeona / Battlegroundu / Szukanie grupy.
     - `🛡️ Rola`: Ikona i rola gracza (np. `🛡️ Tank`, `💚 Healer`, `⚔️ DPS`).
     - `👥 Stan grupy`: np. `2/5 (Wolne miejsca: 3)` + lista obecnych członków party.
     - `💬 Notatka`: (jeśli gracz coś wpisał, np. *"Szybkie daily przed spaniem"*).
   - **Footer (Stopka):** Losowy, klimatyczny tekst z puli (np. *"Wbijaj do gry, kolejka sama się nie zrobi!"*, *"Wezwanie z Azeroth • WoW Forever"*)+ godzina wysłania.

---

### CZEGO OCZEKUJĘ W ODPOWIEDZI:
1. Pełnego kodu pliku `WoWForever.toc`.
2. Pełnego, dobrze skomentowanego kodu pliku `WoWForever.lua` (bez skrótów typu `// reszta kodu tutaj`).
3. Pełnego kodu skryptu `wow_forever_watcher.py` (z użyciem minimalnej liczby zewnętrznych bibliotek, najlepiej standardowe biblioteki + `requests`).
4. Krótkiej instrukcji krok po kroku, jak skompilować skrypt Pythona przez `PyInstaller` do jednego pliku `.exe`, żebym mógł wysłać gotową paczkę znajomym razem z addonem.