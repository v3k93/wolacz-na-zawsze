#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WoW Forever Watcher
===================

Lekki program działający w tle obok gry. Obserwuje plik
``WTF/Account/<KONTO>/SavedVariables/WoWForever.lua`` zapisywany przez addon
"WoW Forever" i - gdy pojawi się nowe ``notification_id`` (kliknięcie
przycisku "Zawołaj Ekipę") - wysyła estetyczny embed na kanał Discord
przez Webhook.

Zależności: biblioteka standardowa + ``requests``.

Użycie:
    python wow_forever_watcher.py            # normalna praca
    python wow_forever_watcher.py --setup    # ponowna konfiguracja
    python wow_forever_watcher.py --test     # wyślij testową wiadomość
"""

from __future__ import annotations

import argparse
import glob
import json
import logging
import logging.handlers
import os
import random
import re
import string
import sys
import time
from datetime import datetime

try:
    import requests
except ImportError:  # pragma: no cover - komunikat dla użytkownika
    print("Brak biblioteki 'requests'. Zainstaluj ją poleceniem:  pip install requests")
    sys.exit(1)

APP_NAME = "WoW Forever Watcher"
APP_VERSION = "1.0.0"
ADDON_FILE = "WoWForever.lua"
DB_VARIABLE = "WoWForeverDB"

RESCAN_INTERVAL = 30          # co ile sekund szukać nowych kont / plików
MAX_RETRY_DELAY = 120         # maks. odstęp ponownej próby wysyłki (s)

DEFAULT_CONFIG = {
    "wow_path": "",
    "webhook_url": "",
    "poll_interval": 2,           # sekundy
    "max_age_minutes": 15,        # starsze wezwania (np. gdy watcher był wyłączony) są pomijane
    "mention": "",                # np. "@here" albo "<@&ID_ROLI>"
    "bot_username": "WoW Forever",
    "bot_avatar_url": "",
}

WEBHOOK_RE = re.compile(
    r"^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+/?$"
)

log = logging.getLogger("wowforever")


# ---------------------------------------------------------------------------
# Ścieżki programu
# ---------------------------------------------------------------------------

def app_dir() -> str:
    """Folder, w którym leży program (.py lub .exe z PyInstallera)."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


CONFIG_PATH = os.path.join(app_dir(), "config.json")
STATE_PATH = os.path.join(app_dir(), "state.json")
LOG_PATH = os.path.join(app_dir(), "watcher.log")


# ---------------------------------------------------------------------------
# Dane do embedów
# ---------------------------------------------------------------------------

# token klasy -> (polska nazwa, kolor klasy z gry)
CLASS_INFO = {
    "WARRIOR": ("Wojownik", 0xC69B6D),
    "PALADIN": ("Paladyn", 0xF58CBA),
    "HUNTER": ("Łowca", 0xAAD372),
    "ROGUE": ("Łotrzyk", 0xFFF468),
    "PRIEST": ("Kapłan", 0xFFFFFF),
    "DEATHKNIGHT": ("Rycerz Śmierci", 0xC41E3A),
    "SHAMAN": ("Szaman", 0x0070DD),
    "MAGE": ("Mag", 0x3FC7EB),
    "WARLOCK": ("Czarnoksiężnik", 0x8788EE),
    "MONK": ("Mnich", 0x00FF98),
    "DRUID": ("Druid", 0xFF7C0A),
    "DEMONHUNTER": ("Łowca Demonów", 0xA330C9),
    "EVOKER": ("Przywoływacz", 0x33937F),
}
DEFAULT_COLOR = 0x5865F2

ROLE_INFO = {
    "TANK": "🛡️ Tank",
    "HEALER": "💚 Healer",
    "DAMAGER": "⚔️ DPS",
}

ACTIVITY_ICONS = {
    "Dungeon": "🏰",
    "Raid Finder": "🐉",
    "Scenariusz": "📜",
    "Battleground": "🚩",
    "Premade / Szukam Grupy": "🔎",
}

FACTIONS = {
    "Alliance": "🔵 Przymierze",
    "Horde": "🔴 Horda",
}

FOOTERS = [
    "Wbijaj do gry, kolejka sama się nie zrobi!",
    "Wezwanie z Azeroth • WoW Forever",
    "Kto pierwszy, ten tankuje.",
    "Lootu nikt za Ciebie nie zbierze!",
    "Za Hordę! Za Przymierze! Za ekipę!",
    "Healer nie gryzie. Zazwyczaj.",
    "Jeszcze tylko jeden dungeon...",
    "Rycerze okrągłego stołu? Nie, ekipa przy kolejce.",
]


# ---------------------------------------------------------------------------
# Logowanie
# ---------------------------------------------------------------------------

def setup_logging(verbose: bool = False) -> None:
    # PyInstaller --noconsole -> sys.stdout może być None
    for stream in (sys.stdout, sys.stderr):
        if stream is not None and hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except (OSError, ValueError):
                pass

    log.setLevel(logging.DEBUG if verbose else logging.INFO)
    fmt = logging.Formatter("[%(asctime)s] %(message)s", datefmt="%H:%M:%S")

    if sys.stdout is not None:
        console = logging.StreamHandler(sys.stdout)
        console.setFormatter(fmt)
        log.addHandler(console)

    try:
        file_handler = logging.handlers.RotatingFileHandler(
            LOG_PATH, maxBytes=512 * 1024, backupCount=1, encoding="utf-8"
        )
        file_handler.setFormatter(
            logging.Formatter("%(asctime)s %(levelname)s %(message)s")
        )
        log.addHandler(file_handler)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Parser tabel Lua (format SavedVariables)
# ---------------------------------------------------------------------------

class LuaParseError(ValueError):
    pass


_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NUMBER_RE = re.compile(
    r"-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)"
)
_LONG_BRACKET_RE = re.compile(r"\[(=*)\[")
_DIGITS_RE = re.compile(r"\d{1,3}")

_ESCAPES = {
    "n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b",
    "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n",
}


def _fix_text(raw: str) -> str:
    """Plik czytamy jako latin-1 (bajt = znak), tu zamieniamy bajty na UTF-8."""
    try:
        return raw.encode("latin-1").decode("utf-8", errors="replace")
    except UnicodeEncodeError:
        return raw


class LuaTableParser:
    """Minimalny parser literałów Lua: tabele, teksty, liczby, true/false/nil
    oraz komentarze (WoW dopisuje np. ``-- [1]`` przy elementach list)."""

    def __init__(self, text: str):
        self.s = text
        self.i = 0
        self.n = len(text)

    # -- narzędzia ---------------------------------------------------------
    def _peek(self, offset: int = 0) -> str:
        j = self.i + offset
        return self.s[j] if j < self.n else ""

    def _error(self, message: str) -> LuaParseError:
        line = self.s.count("\n", 0, self.i) + 1
        return LuaParseError(f"{message} (linia {line})")

    def _expect(self, ch: str) -> None:
        if self._peek() != ch:
            raise self._error(f"Oczekiwano '{ch}'")
        self.i += 1

    def _skip(self) -> None:
        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t\r\n\f\v":
                self.i += 1
            elif self.s.startswith("--", self.i):
                self.i += 2
                m = _LONG_BRACKET_RE.match(self.s, self.i)
                if m:
                    self._read_long_bracket(len(m.group(1)))
                else:
                    nl = self.s.find("\n", self.i)
                    self.i = self.n if nl == -1 else nl + 1
            else:
                break

    def _read_long_bracket(self, level: int) -> str:
        start = self.i + level + 2
        close = "]" + "=" * level + "]"
        end = self.s.find(close, start)
        if end == -1:
            raise self._error("Niezamknięty długi nawias")
        self.i = end + len(close)
        content = self.s[start:end]
        if content.startswith("\r\n"):
            content = content[2:]
        elif content.startswith("\n"):
            content = content[1:]
        return content

    def _identifier(self):
        m = _IDENT_RE.match(self.s, self.i)
        if not m:
            return None
        self.i = m.end()
        return m.group(0)

    # -- wartości ----------------------------------------------------------
    def parse_assignments(self) -> dict:
        """Plik SavedVariables: ciąg przypisań ``Nazwa = wartość``."""
        result = {}
        while True:
            self._skip()
            if self.i >= self.n:
                return result
            name = self._identifier()
            if name is None:
                raise self._error("Oczekiwano nazwy zmiennej")
            self._skip()
            self._expect("=")
            result[name] = self._value()
            self._skip()
            if self._peek() == ";":
                self.i += 1

    def _value(self):
        self._skip()
        c = self._peek()
        if c == "":
            raise self._error("Nieoczekiwany koniec pliku")
        if c == "{":
            return self._table()
        if c in "\"'":
            return self._string()
        if c == "[":
            m = _LONG_BRACKET_RE.match(self.s, self.i)
            if m:
                return _fix_text(self._read_long_bracket(len(m.group(1))))
        if c == "-" or c == "." or c.isdigit():
            return self._number()
        ident = self._identifier()
        if ident == "true":
            return True
        if ident == "false":
            return False
        if ident == "nil":
            return None
        raise self._error(f"Nieznana wartość: {ident or c!r}")

    def _number(self):
        m = _NUMBER_RE.match(self.s, self.i)
        if not m:
            raise self._error("Niepoprawna liczba")
        self.i = m.end()
        txt = m.group(0)
        if "x" in txt or "X" in txt:
            return int(txt, 16)
        if re.fullmatch(r"-?\d+", txt):
            return int(txt)
        value = float(txt)
        return int(value) if value.is_integer() and abs(value) < 2 ** 53 else value

    def _string(self) -> str:
        quote = self.s[self.i]
        self.i += 1
        out = []
        while True:
            if self.i >= self.n:
                raise self._error("Niezamknięty tekst")
            c = self.s[self.i]
            if c == quote:
                self.i += 1
                break
            if c == "\\":
                self.i += 1
                e = self._peek()
                if e == "":
                    raise self._error("Niezamknięty tekst")
                if e.isdigit():
                    m = _DIGITS_RE.match(self.s, self.i)
                    out.append(chr(int(m.group(0)) & 0xFF))
                    self.i = m.end()
                elif e == "x":
                    out.append(chr(int(self.s[self.i + 1:self.i + 3], 16)))
                    self.i += 3
                elif e == "\r":
                    out.append("\n")
                    self.i += 2 if self._peek(1) == "\n" else 1
                else:
                    out.append(_ESCAPES.get(e, e))
                    self.i += 1
            elif c == "\n":
                raise self._error("Niezamknięty tekst")
            else:
                out.append(c)
                self.i += 1
        return _fix_text("".join(out))

    def _table(self):
        self._expect("{")
        keyed = {}
        array = []
        while True:
            self._skip()
            c = self._peek()
            if c == "}":
                self.i += 1
                break
            if c == "[" and not _LONG_BRACKET_RE.match(self.s, self.i):
                self.i += 1
                key = self._value()
                self._skip()
                self._expect("]")
                self._skip()
                self._expect("=")
                keyed[key] = self._value()
            else:
                saved = self.i
                ident = self._identifier()
                self._skip()
                if ident is not None and self._peek() == "=" and self._peek(1) != "=":
                    self.i += 1
                    keyed[ident] = self._value()
                else:
                    self.i = saved
                    array.append(self._value())
            self._skip()
            c = self._peek()
            if c in (",", ";"):
                self.i += 1
            elif c != "}":
                raise self._error("Oczekiwano ',' lub '}'")

        for index, value in enumerate(array, start=1):
            keyed[index] = value
        # Tabela z kluczami 1..n -> lista Pythona
        if keyed and all(isinstance(k, int) for k in keyed):
            if sorted(keyed) == list(range(1, len(keyed) + 1)):
                return [keyed[k] for k in range(1, len(keyed) + 1)]
        return keyed


def as_list(value) -> list:
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value[k] for k in sorted(value, key=str)]
    return []


def as_text(value, default: str = "") -> str:
    if value is None:
        return default
    if isinstance(value, bool):
        return "tak" if value else "nie"
    text = str(value).strip()
    return text if text else default


def as_int(value, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def read_notification(path: str):
    """Zwraca słownik z ostatnim wezwaniem albo None (brak danych)."""
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    parsed = LuaTableParser(raw.decode("latin-1")).parse_assignments()
    db = parsed.get(DB_VARIABLE)
    if not isinstance(db, dict):
        return None
    notification = db.get("notification")
    if not isinstance(notification, dict):
        return None
    if not notification.get("notification_id"):
        notification["notification_id"] = db.get("notification_id")
    return notification


# ---------------------------------------------------------------------------
# Konfiguracja i stan
# ---------------------------------------------------------------------------

def load_json(path: str, default: dict) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else dict(default)
    except FileNotFoundError:
        return dict(default)
    except (OSError, ValueError) as exc:
        log.warning("Nie udało się wczytać %s: %s", os.path.basename(path), exc)
        return dict(default)


def save_json(path: str, data: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def load_config() -> dict:
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(load_json(CONFIG_PATH, {}))
    return cfg


def config_is_valid(cfg: dict) -> bool:
    return bool(
        cfg.get("wow_path")
        and os.path.isdir(cfg["wow_path"])
        and WEBHOOK_RE.match(cfg.get("webhook_url", ""))
    )


class State:
    """Ostatnio wysłane notification_id dla każdego pliku (state.json)."""

    def __init__(self, path: str):
        self.path = path
        data = load_json(path, {})
        ids = data.get("last_ids", {})
        self.last_ids = {k: as_int(v) for k, v in ids.items()} if isinstance(ids, dict) else {}

    def get(self, key: str):
        return self.last_ids.get(key)

    def set(self, key: str, value: int) -> None:
        self.last_ids[key] = int(value)
        try:
            save_json(self.path, {"last_ids": self.last_ids})
        except OSError as exc:
            log.error("Nie mogę zapisać %s: %s", self.path, exc)


# ---------------------------------------------------------------------------
# Wyszukiwanie folderu gry i plików SavedVariables
# ---------------------------------------------------------------------------

def normalize_path(path: str) -> str:
    return os.path.normcase(os.path.abspath(path))


def find_saved_variables(root: str) -> list:
    """Szuka WoWForever.lua we wszystkich kontach i wersjach gry
    (_retail_, _classic_, _classic_era_, klient 3.3.5a itd.)."""
    if not root or not os.path.isdir(root):
        return []
    base = glob.escape(os.path.abspath(root))
    patterns = [
        os.path.join(base, "WTF", "Account", "*", "SavedVariables", ADDON_FILE),
        os.path.join(base, "*", "WTF", "Account", "*", "SavedVariables", ADDON_FILE),
        os.path.join(base, "Account", "*", "SavedVariables", ADDON_FILE),  # wskazano folder WTF
    ]
    found = {}
    for pattern in patterns:
        for path in glob.glob(pattern):
            found[normalize_path(path)] = path
    return sorted(found.values())


def looks_like_wow_folder(path: str) -> bool:
    if not path or not os.path.isdir(path):
        return False
    markers = ["WTF", "Wow.exe", "WowClassic.exe", "Wow-64.exe", "World of Warcraft.app"]
    if any(os.path.exists(os.path.join(path, m)) for m in markers):
        return True
    return bool(glob.glob(os.path.join(glob.escape(path), "_*_", "WTF")))


def _registry_wow_paths() -> list:
    paths = []
    try:
        import winreg  # tylko Windows
    except ImportError:
        return paths
    keys = [
        r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
        r"SOFTWARE\Blizzard Entertainment\World of Warcraft",
    ]
    for key in keys:
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key) as handle:
                value, _ = winreg.QueryValueEx(handle, "InstallPath")
                if value:
                    value = os.path.normpath(value)
                    name = os.path.basename(value)
                    if name.startswith("_") and name.endswith("_"):
                        value = os.path.dirname(value)  # ..\_retail_ -> folder gry
                    paths.append(value)
        except OSError:
            continue
    return paths


def detect_wow_paths() -> list:
    """Lista prawdopodobnych folderów z grą (bez duplikatów)."""
    candidates = list(_registry_wow_paths())

    if os.name == "nt":
        drives = [f"{d}:\\" for d in string.ascii_uppercase if os.path.exists(f"{d}:\\")]
        for drive in drives:
            for sub in ("", "Program Files (x86)", "Program Files", "Games", "Gry", "Blizzard"):
                folder = os.path.join(drive, sub)
                try:
                    entries = list(os.scandir(folder))
                except OSError:
                    continue
                for entry in entries:
                    if entry.is_dir() and ("wow" in entry.name.lower() or "warcraft" in entry.name.lower()):
                        candidates.append(entry.path)
    else:
        home = os.path.expanduser("~")
        candidates += [
            "/Applications/World of Warcraft",
            os.path.join(home, "Games", "World of Warcraft"),
            os.path.join(home, "Games", "world-of-warcraft", "drive_c", "Program Files (x86)", "World of Warcraft"),
        ]

    result, seen = [], set()
    for path in candidates:
        key = normalize_path(path)
        if key not in seen and looks_like_wow_folder(path):
            seen.add(key)
            result.append(path)
    return result


# ---------------------------------------------------------------------------
# Kreator konfiguracji (pierwsze uruchomienie)
# ---------------------------------------------------------------------------

def ask(prompt: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    try:
        answer = input(f"{prompt}{suffix}: ").strip().strip('"')
    except EOFError:
        answer = ""
    return answer or default


def ask_yes_no(prompt: str, default: bool = True) -> bool:
    hint = "T/n" if default else "t/N"
    answer = ask(f"{prompt} ({hint})").lower()
    if not answer:
        return default
    return answer[0] in ("t", "y")


def pick_folder_dialog():
    """Okno wyboru folderu (tkinter). Zwraca None, gdy niedostępne."""
    try:
        import tkinter as tk
        from tkinter import filedialog
    except ImportError:
        return None
    try:
        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        path = filedialog.askdirectory(title="Wybierz folder z grą World of Warcraft")
        root.destroy()
        return os.path.normpath(path) if path else None
    except Exception:  # brak środowiska graficznego itp.
        return None


def choose_wow_path(current: str) -> str:
    print("\n=== Krok 1/2: Folder z grą ===")
    candidates = detect_wow_paths()
    if current and os.path.isdir(current) and normalize_path(current) not in {normalize_path(c) for c in candidates}:
        candidates.insert(0, current)

    while True:
        if candidates:
            print("Znalezione foldery z grą:")
            for idx, path in enumerate(candidates, start=1):
                count = len(find_saved_variables(path))
                info = f"addon zapisał już dane ({count})" if count else "brak danych addonu (jeszcze)"
                print(f"  {idx}. {path}  – {info}")
            print("  W. Wybierz inny folder w okienku")
            print("  Albo wklej ścieżkę ręcznie.")
            answer = ask("Twój wybór", "1")
        else:
            print("Nie znalazłem automatycznie folderu z grą.")
            answer = "w"

        path = None
        if answer.isdigit() and 1 <= int(answer) <= len(candidates):
            path = candidates[int(answer) - 1]
        elif answer.lower() == "w":
            path = pick_folder_dialog()
            if not path:
                path = ask("Wklej ścieżkę do folderu World of Warcraft")
        else:
            path = answer

        if not path or not os.path.isdir(path):
            print("  ✗ Ten folder nie istnieje, spróbuj jeszcze raz.")
            continue
        if not looks_like_wow_folder(path) and not ask_yes_no(
            "  Ten folder nie wygląda na folder WoW-a (brak WTF / Wow.exe). Użyć mimo to?", False
        ):
            continue
        return os.path.abspath(path)


def choose_webhook(current: str) -> str:
    print("\n=== Krok 2/2: Discord Webhook ===")
    print("Discord: Ustawienia kanału → Integracje → Webhooki → Nowy webhook → Kopiuj URL")
    while True:
        url = ask("Wklej URL webhooka", current)
        if WEBHOOK_RE.match(url):
            return url
        print("  ✗ To nie wygląda na URL webhooka Discorda (https://discord.com/api/webhooks/...).")


def run_setup(cfg: dict) -> dict:
    print("=" * 60)
    print(f" {APP_NAME} {APP_VERSION} – konfiguracja")
    print("=" * 60)
    cfg = dict(cfg)
    cfg["wow_path"] = choose_wow_path(cfg.get("wow_path", ""))
    cfg["webhook_url"] = choose_webhook(cfg.get("webhook_url", ""))
    save_json(CONFIG_PATH, cfg)
    print(f"\n✓ Zapisano konfigurację: {CONFIG_PATH}")
    if ask_yes_no("Wysłać testową wiadomość na Discorda?", True):
        send_test(cfg)
    return cfg


# ---------------------------------------------------------------------------
# Discord
# ---------------------------------------------------------------------------

def clip(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[: limit - 1] + "…"


def build_payload(n: dict, cfg: dict) -> dict:
    token = as_text(n.get("player_class")).upper()
    class_pl, color = CLASS_INFO.get(token, (None, DEFAULT_COLOR))
    class_name = class_pl or as_text(n.get("player_class_name")) or token.title() or "?"

    name = as_text(n.get("player_name"), "Ktoś")
    level = as_int(n.get("player_level"))
    level_part = f"Lvl {level} " if level > 0 else ""
    title = f"⚔️ {name} ({level_part}{class_name}) woła ekipę do gry!"

    # 🎯 Aktywność
    activity_type = as_text(n.get("activity_type"), "Premade / Szukam Grupy")
    activity_name = as_text(n.get("activity_name"), "Szukam ludzi do wspólnej gry!")
    status = as_text(n.get("activity_status"))
    icon = ACTIVITY_ICONS.get(activity_type, "🎮")
    activity_value = f"{icon} **{activity_type}**\n{activity_name}"
    if status:
        activity_value += f"\n*{status}*"

    # 🛡️ Rola
    roles = [ROLE_INFO.get(as_text(r).upper(), as_text(r)) for r in as_list(n.get("player_role"))]
    roles = [r for r in roles if r]
    role_value = "\n".join(roles) if roles else "❔ Dowolna"
    if n.get("is_leader") is True:
        role_value += "\n👑 Chętny na lidera"

    # 👥 Stan grupy
    current = max(1, as_int(n.get("group_current"), 1))
    maximum = as_int(n.get("group_max"))
    if maximum <= 0:
        size = as_text(n.get("group_size"))
        m = re.match(r"(\d+)\s*/\s*(\d+)", size)
        current, maximum = (int(m.group(1)), int(m.group(2))) if m else (current, 5)
    free = max(0, maximum - current)
    group_value = f"**{current}/{maximum}** (Wolne miejsca: {free})"
    members = [as_text(m) for m in as_list(n.get("group_members")) if as_text(m)]
    if members:
        shown = members[:15]
        group_value += "\n" + ", ".join(shown)
        if len(members) > len(shown):
            group_value += f" (+{len(members) - len(shown)})"

    fields = [
        {"name": "🎯 Aktywność", "value": clip(activity_value, 1024), "inline": False},
        {"name": "🛡️ Rola", "value": clip(role_value, 1024), "inline": True},
        {"name": "👥 Stan grupy", "value": clip(group_value, 1024), "inline": True},
    ]
    note = as_text(n.get("custom_note"))
    if note:
        fields.append({"name": "💬 Notatka", "value": clip(f"*{note}*", 1024), "inline": False})

    description_parts = []
    realm = as_text(n.get("player_realm"))
    if realm:
        description_parts.append(f"🌍 {realm}")
    faction = FACTIONS.get(as_text(n.get("player_faction")))
    if faction:
        description_parts.append(faction)

    sent_at = datetime.now().strftime("%H:%M")
    embed = {
        "title": clip(title, 256),
        "color": color,
        "fields": fields,
        "footer": {"text": f"{random.choice(FOOTERS)} • {sent_at}"},
    }
    if description_parts:
        embed["description"] = " • ".join(description_parts)

    payload = {
        "username": cfg.get("bot_username") or "WoW Forever",
        "embeds": [embed],
        "allowed_mentions": {"parse": []},
    }
    if cfg.get("bot_avatar_url"):
        payload["avatar_url"] = cfg["bot_avatar_url"]
    mention = as_text(cfg.get("mention"))
    if mention:
        payload["content"] = mention
        payload["allowed_mentions"] = {"parse": ["everyone", "roles", "users"]}
    return payload


def send_to_discord(url: str, payload: dict) -> str:
    """Zwraca 'ok', 'retry' (błąd chwilowy) lub 'fail' (błąd trwały)."""
    for _ in range(3):
        try:
            response = requests.post(url, json=payload, timeout=15)
        except requests.RequestException as exc:
            log.warning("Brak połączenia z Discordem: %s", exc)
            return "retry"

        if response.status_code in (200, 204):
            return "ok"
        if response.status_code == 429:
            try:
                wait = float(response.json().get("retry_after", 1))
            except ValueError:
                wait = 2.0
            log.info("Discord prosi o chwilę przerwy (%.1fs)...", wait)
            time.sleep(min(max(wait, 0.5), 30))
            continue
        if response.status_code >= 500:
            log.warning("Discord chwilowo nie działa (HTTP %s)", response.status_code)
            return "retry"

        log.error("Discord odrzucił wiadomość (HTTP %s): %s",
                  response.status_code, response.text[:300])
        if response.status_code in (401, 404):
            log.error("Webhook jest niepoprawny lub usunięty – uruchom program z opcją --setup.")
        return "fail"
    return "retry"


def send_test(cfg: dict) -> bool:
    sample = {
        "notification_id": int(time.time()),
        "player_name": "Testowy",
        "player_realm": "Azeroth",
        "player_class": "PALADIN",
        "player_level": 80,
        "player_faction": "Alliance",
        "player_role": ["TANK", "HEALER"],
        "activity_type": "Dungeon",
        "activity_name": "Utgarde Keep",
        "activity_status": "To tylko test – WoW Forever Watcher działa!",
        "group_current": 2,
        "group_max": 5,
        "group_members": ["Testowy", "Kumpel"],
        "custom_note": "Wiadomość testowa",
    }
    result = send_to_discord(cfg["webhook_url"], build_payload(sample, cfg))
    if result == "ok":
        print("✓ Testowa wiadomość wysłana – sprawdź kanał na Discordzie.")
        return True
    print("✗ Nie udało się wysłać testowej wiadomości (szczegóły powyżej).")
    return False


# ---------------------------------------------------------------------------
# Obserwator plików
# ---------------------------------------------------------------------------

class TrackedFile:
    def __init__(self, path: str, baseline: bool):
        self.path = path
        self.key = normalize_path(path)
        self.signature = None      # (mtime_ns, size) ostatnio przetworzonej wersji
        self.baseline = baseline   # True = tylko zapamiętaj ID, nic nie wysyłaj
        self.pending = False       # wysyłka nie powiodła się, ponów
        self.next_try = 0.0
        self.failures = 0
        self.error_signature = None

    def describe(self) -> str:
        # ...\WTF\Account\NAZWA_KONTA\SavedVariables\WoWForever.lua -> NAZWA_KONTA
        parts = os.path.normpath(self.path).split(os.sep)
        try:
            idx = [p.lower() for p in parts].index("account")
            account = parts[idx + 1]
            flavour = parts[idx - 2] if idx >= 2 and parts[idx - 2].startswith("_") else ""
            return f"{account} {flavour}".strip()
        except (ValueError, IndexError):
            return self.path


class Watcher:
    def __init__(self, cfg: dict, state: State):
        self.cfg = cfg
        self.state = state
        self.files = {}
        self.last_scan = 0.0
        self.interval = max(1.0, float(cfg.get("poll_interval") or 2))
        self.max_age = float(cfg.get("max_age_minutes") or 0) * 60

    def rescan(self, startup: bool) -> None:
        for path in find_saved_variables(self.cfg["wow_path"]):
            key = normalize_path(path)
            if key in self.files:
                continue
            # Przy starcie programu plik bez historii = stare zapisy -> ignorujemy.
            baseline = startup and self.state.get(key) is None
            tracked = TrackedFile(path, baseline)
            self.files[key] = tracked
            log.info("Obserwuję konto: %s", tracked.describe())
        self.last_scan = time.time()

    def run(self) -> None:
        log.info("%s %s uruchomiony.", APP_NAME, APP_VERSION)
        log.info("Folder gry: %s", self.cfg["wow_path"])
        self.rescan(startup=True)
        if not self.files:
            log.info("Nie ma jeszcze pliku %s. Wejdź do gry z włączonym addonem – "
                     "plik pojawi się po pierwszym /reload lub wylogowaniu.", ADDON_FILE)
        log.info("Czekam na wezwania... (Ctrl+C kończy)")

        while True:
            if time.time() - self.last_scan >= RESCAN_INTERVAL:
                self.rescan(startup=False)
            for tracked in list(self.files.values()):
                try:
                    self.check(tracked)
                except Exception:  # pojedynczy plik nie może zatrzymać programu
                    log.exception("Nieoczekiwany błąd przy %s", tracked.path)
            time.sleep(self.interval)

    def check(self, tracked: TrackedFile) -> None:
        try:
            st = os.stat(tracked.path)
        except FileNotFoundError:
            return
        signature = (st.st_mtime_ns, st.st_size)

        now = time.time()
        if signature == tracked.signature and not (tracked.pending and now >= tracked.next_try):
            return

        try:
            notification = read_notification(tracked.path)
        except (OSError, LuaParseError) as exc:
            # Gra mogła jeszcze nie skończyć zapisu – spróbujemy przy następnym cyklu.
            if tracked.error_signature != signature:
                log.debug("Nie mogę odczytać %s: %s", tracked.path, exc)
                tracked.error_signature = signature
            return
        tracked.signature = signature
        tracked.error_signature = None

        nid = as_int(notification.get("notification_id")) if notification else 0
        last_id = self.state.get(tracked.key) or 0

        if tracked.baseline:
            tracked.baseline = False
            self.state.set(tracked.key, max(last_id, nid))
            if nid:
                log.info("[%s] Pomijam stare wezwanie zapisane przed startem programu.", tracked.describe())
            return

        if not nid or nid <= last_id:
            tracked.pending = False      # zwykły /reload lub wylogowanie – nic nowego
            return

        age = now - nid
        if self.max_age and age > self.max_age:
            log.info("[%s] Pomijam wezwanie sprzed %d min (starsze niż %d min).",
                     tracked.describe(), int(age // 60), int(self.max_age // 60))
            self.state.set(tracked.key, nid)
            tracked.pending = False
            return

        log.info("[%s] Nowe wezwanie od %s (%s – %s). Wysyłam na Discorda...",
                 tracked.describe(), as_text(notification.get("player_name"), "?"),
                 as_text(notification.get("activity_type")), as_text(notification.get("activity_name")))
        result = send_to_discord(self.cfg["webhook_url"], build_payload(notification, self.cfg))

        if result == "ok":
            log.info("[%s] ✓ Wysłano!", tracked.describe())
            self.state.set(tracked.key, nid)
            tracked.pending = False
            tracked.failures = 0
        elif result == "retry":
            tracked.failures += 1
            delay = min(MAX_RETRY_DELAY, 5 * 2 ** (tracked.failures - 1))
            tracked.pending = True
            tracked.next_try = now + delay
            log.info("[%s] Ponowię próbę za %ds.", tracked.describe(), delay)
        else:
            # Błąd trwały (np. zły webhook) – nie zapętlamy się na tym wezwaniu.
            self.state.set(tracked.key, nid)
            tracked.pending = False


# ---------------------------------------------------------------------------
# Start programu
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=f"{APP_NAME} – powiadomienia WoW → Discord")
    parser.add_argument("--setup", action="store_true", help="uruchom ponownie konfigurację")
    parser.add_argument("--test", action="store_true", help="wyślij testową wiadomość i zakończ")
    parser.add_argument("--verbose", action="store_true", help="więcej informacji w logu")
    args = parser.parse_args()

    setup_logging(args.verbose)
    cfg = load_config()

    if args.setup or not config_is_valid(cfg):
        cfg = run_setup(cfg)

    if args.test:
        return 0 if send_test(cfg) else 1

    Watcher(cfg, State(STATE_PATH)).run()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nDo zobaczenia w Azeroth!")
        sys.exit(0)
    except Exception:
        log.exception("Krytyczny błąd programu")
        if getattr(sys, "frozen", False):
            try:
                input("\nNaciśnij Enter, aby zamknąć...")
            except EOFError:
                pass
        sys.exit(1)
