#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pillow",
#   "piexif",
# ]
# ///
"""Generate a synthetic test library for LocalGallery.

Produces a folder tree of labeled placeholder JPEGs (plus a few PNG/WebP/GIF,
standalone videos and Live Photo pairs) with EXIF dates/GPS, .xmp sidecars
(digiKam:TagsList, photo-tools:CountryCode, MWG face regions) and filesystem
dates matching the photo dates. Fully deterministic for a given --seed: all
randomness happens in the single-threaded planning phase; render workers are
pure functions of their record.

Sidecar format follows the app's literal string parser (MetadataReader):
  - sidecar named "<file>.<ext>.xmp"
  - tags:    <digiKam:TagsList> block, entries exactly <rdf:li>value</rdf:li>
  - country: <photo-tools:CountryCode>IT</photo-tools:CountryCode>
  - regions: <mwg-rs:Area .../> attribute form with stArea:x/y/w/h,
             stArea:unit="normalized"; <mwg-rs:Name> element BEFORE its Area
             (parser looks back 2000 chars for the LAST preceding Name, so
             unnamed regions are emitted before any named region).

Modes:
  generate:  generate_test_library.py --out DIR [--count N] [--seed S] [--today YYYY-MM-DD]
  install:   generate_test_library.py --out DIR --install [booted|UDID]
             rsyncs DIR into the simulator Files-app local storage at
             .../File Provider Storage/TestLibrary/ (stable path: photo IDs
             are derived from the absolute file path).
"""

from __future__ import annotations

import argparse
import colorsys
import glob
import hashlib
import json
import math
import multiprocessing
import os
import plistlib
import random
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from xml.sax.saxutils import escape

W, H = 800, 600
JPEG_QUALITY = 70

# ---------------------------------------------------------------------------
# Static world model
# ---------------------------------------------------------------------------

FIRST_NAMES = [
    "Anna", "Ben", "Clara", "David", "Emma", "Felix", "Greta", "Hannah",
    "Ivan", "Julia", "Karl", "Lena", "Marco", "Nina", "Oskar", "Paula",
    "Quentin", "Rosa", "Simon", "Tessa", "Ulrich", "Vera", "Willem", "Xenia",
    "Yara", "Zoe", "Adam", "Bella", "Caleb", "Dora", "Elias", "Frieda",
]

LAST_NAMES = [
    "Smith", "Meyer", "King", "Rossi", "Tanaka", "Novak", "Berg", "Silva",
    "Weber", "Kim", "Ortiz", "Dubois", "Larsen", "Costa", "Haas", "Vogel",
    "Mori", "Lang", "Petrov", "Blanc",
]

# (city, country, region, iso_code, lat, lon, landmark_tag)
HOME = ("Berlin", "Germany", "Berlin", "DE", 52.5200, 13.4050, "Landmarks/Brandenburg Gate")
DESTINATIONS = [
    ("Rome", "Italy", "Lazio", "IT", 41.9028, 12.4964, "Landmarks/Colosseum"),
    ("Lisbon", "Portugal", "Lisboa", "PT", 38.7223, -9.1393, "Landmarks/Belem Tower"),
    ("Kyoto", "Japan", "Kansai", "JP", 35.0116, 135.7681, "Landmarks/Fushimi Inari"),
    ("New York", "United States", "New York", "US", 40.7128, -74.0060, "Landmarks/Statue Of Liberty"),
    ("Paris", "France", "Ile-de-France", "FR", 48.8566, 2.3522, "Landmarks/Eiffel Tower"),
    ("Barcelona", "Spain", "Catalonia", "ES", 41.3874, 2.1686, "Landmarks/Sagrada Familia"),
    ("Amsterdam", "Netherlands", "North Holland", "NL", 52.3676, 4.9041, "Landmarks/Rijksmuseum"),
    ("Vienna", "Austria", "Vienna", "AT", 48.2082, 16.3738, "Landmarks/Schonbrunn"),
    ("Prague", "Czechia", "Prague", "CZ", 50.0755, 14.4378, "Landmarks/Charles Bridge"),
    ("Copenhagen", "Denmark", "Capital Region", "DK", 55.6761, 12.5683, "Landmarks/Nyhavn"),
    ("Marrakesh", "Morocco", "Marrakesh-Safi", "MA", 31.6295, -7.9811, "Landmarks/Jemaa el-Fnaa"),
    ("Sydney", "Australia", "New South Wales", "AU", -33.8688, 151.2093, "Landmarks/Sydney Opera House"),
    ("Reykjavik", "Iceland", "Capital Region", "IS", 64.1466, -21.9426, "Landmarks/Hallgrimskirkja"),
]

OBJECT_TAGS = [
    "Objects/Food/Pizza", "Objects/Food/Coffee", "Objects/Food/Ice Cream",
    "Objects/Vehicles/Bicycle", "Objects/Vehicles/Tram",
    "Objects/Animals/Dog", "Objects/Animals/Cat",
]
SCENE_TAGS = [
    "Scenes/Sunset", "Scenes/Beach", "Scenes/Forest", "Scenes/Snow",
    "Scenes/Night", "Scenes/Architecture",
]
TEXT_TAGS = ["Text/Street Sign", "Text/Menu"]
FLAT_TAGS = ["favorite", "print-candidate"]


def places_path(place) -> str:
    city, country, region = place[0], place[1], place[2]
    return f"Places/{country}/{region}/{city}"


def name_hash(name: str) -> bytes:
    return hashlib.md5(name.encode("utf-8")).digest()


def person_color(name: str) -> tuple[int, int, int]:
    h = name_hash(name)
    hue = h[0] / 255.0
    r, g, b = colorsys.hsv_to_rgb(hue, 0.62, 0.88)
    return (int(r * 255), int(g * 255), int(b * 255))


def folder_gradient(rel_dir: str) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    h = name_hash(rel_dir)
    hue1 = h[0] / 255.0
    hue2 = (hue1 + 0.13 + (h[1] / 255.0) * 0.2) % 1.0
    c1 = colorsys.hsv_to_rgb(hue1, 0.45, 0.55)
    c2 = colorsys.hsv_to_rgb(hue2, 0.35, 0.30)
    return (
        tuple(int(v * 255) for v in c1),
        tuple(int(v * 255) for v in c2),
    )


# ---------------------------------------------------------------------------
# Records (picklable, fully precomputed in the planning phase)
# ---------------------------------------------------------------------------

@dataclass
class PhotoRec:
    rel: str                      # path relative to --out
    dt: datetime                  # photo datetime (naive local)
    fmt: str = "JPEG"             # JPEG | PNG | WEBP | GIF
    embed_exif: bool = True       # write EXIF date (+GPS when gps set)
    gps: tuple[float, float] | None = None
    set_utime: bool = True
    # faces: (name_or_None, cx, cy, w, h, (r,g,b), initials) — normalized coords
    faces: list = field(default_factory=list)
    tags: list = field(default_factory=list)
    country: str | None = None
    sidecar: str = "none"         # none | normal | empty | truncated | no_w
    place_label: str = ""
    folder_label: str = ""


@dataclass
class VideoRec:
    rel: str
    dt: datetime
    duration: float = 2.5
    set_utime: bool = True


# ---------------------------------------------------------------------------
# Planning (single-threaded, all RNG here)
# ---------------------------------------------------------------------------

@dataclass
class Person:
    name: str
    initials: str
    color: tuple[int, int, int]
    rank: int
    old_only: bool
    birthday: tuple[int, int]     # (month, day)


def make_people(rng: random.Random) -> list[Person]:
    combos = [(f, l) for f in FIRST_NAMES for l in LAST_NAMES]
    rng.shuffle(combos)
    people: list[Person] = []
    seen = set()
    # Person 0 fixed for the "Anna" first-token edge case.
    picks = [("Anna", "Smith")]
    seen.add(("Anna", "Smith"))
    for c in combos:
        if len(picks) >= 100:
            break
        if c in seen:
            continue
        seen.add(c)
        picks.append(c)
    for i, (f, l) in enumerate(picks):
        name = f"{f} {l}"
        h = name_hash(name)
        bmonth = 1 + h[2] % 12
        bday = 1 + h[3] % 28
        people.append(Person(
            name=name,
            initials=(f[0] + l[0]).upper(),
            color=person_color(name),
            rank=i,
            old_only=(i >= 88),   # tail people with only old photos (rail exclusion)
            birthday=(bmonth, bday),
        ))
    return people


class Planner:
    def __init__(self, count: int, seed: int, today: date):
        self.rng = random.Random(seed)
        self.count = count
        self.today = today
        self.now_dt = datetime(today.year, today.month, today.day, 12, 0, 0)
        self.people = make_people(self.rng)
        self.weights = [1.0 / (p.rank + 1) ** 0.9 for p in self.people]
        self.photos: list[PhotoRec] = []
        self.videos: list[VideoRec] = []
        self.empty_dirs: list[str] = []
        self._img_num = 0
        self._vid_num = 0

    # -- helpers ------------------------------------------------------------

    def next_img(self) -> str:
        self._img_num += 1
        return f"IMG_{self._img_num:05d}"

    def next_vid(self) -> str:
        self._vid_num += 1
        return f"VID_{self._vid_num:04d}"

    def jitter_gps(self, place) -> tuple[float, float]:
        lat, lon = place[4], place[5]
        return (
            round(lat + self.rng.uniform(-0.02, 0.02), 6),
            round(lon + self.rng.uniform(-0.02, 0.02), 6),
        )

    def sample_faces(self, dt: datetime, force_person: Person | None = None) -> list:
        rng = self.rng
        n = rng.choices([0, 1, 2, 3, 4], weights=[35, 30, 20, 10, 5])[0]
        if force_person is not None and n == 0:
            n = 1
        if n == 0:
            return []
        recent = dt > self.now_dt - timedelta(days=3 * 365)
        eligible = [(p, w) for p, w in zip(self.people, self.weights)
                    if not (p.old_only and recent)]
        chosen: list[Person] = []
        if force_person is not None:
            chosen.append(force_person)
        tries = 0
        while len(chosen) < n and tries < 40:
            tries += 1
            p = rng.choices([e[0] for e in eligible], weights=[e[1] for e in eligible])[0]
            if p not in chosen:
                chosen.append(p)
        return self.face_specs(chosen)

    def face_specs(self, chosen: list[Person | None]) -> list:
        rng = self.rng
        n = len(chosen)
        faces = []
        for i, p in enumerate(chosen):
            cx = 0.5 + (i - (n - 1) / 2) * 0.18 + rng.uniform(-0.015, 0.015)
            cy = 0.40 + rng.uniform(-0.05, 0.05)
            r_px = rng.randint(48, 72)
            w = round(2 * r_px / W, 4)
            h = round(2 * r_px / H, 4)
            cx = round(min(0.88, max(0.12, cx)), 4)
            cy = round(min(0.75, max(0.2, cy)), 4)
            if p is None:
                faces.append((None, cx, cy, w, h, (128, 128, 128), "?"))
            else:
                faces.append((p.name, cx, cy, w, h, p.color, p.initials))
        return faces

    def base_tags(self, place, faces, on_trip: bool) -> tuple[list[str], str]:
        rng = self.rng
        tags = [f"People/{f[0]}" for f in faces if f[0] is not None]
        tags.append(places_path(place))
        if rng.random() < (0.25 if on_trip else 0.08):
            tags.append(place[6])  # landmark
        if rng.random() < 0.18:
            tags.append(rng.choice(OBJECT_TAGS))
        if rng.random() < 0.15:
            tags.append(rng.choice(SCENE_TAGS))
        if rng.random() < 0.03:
            tags.append(rng.choice(TEXT_TAGS))
        if rng.random() < 0.04:
            tags.append(rng.choice(FLAT_TAGS))
        return tags, place[3]

    def add_photo(self, rel_dir: str, dt: datetime, place, on_trip: bool,
                  force_person: Person | None = None, stem: str | None = None) -> PhotoRec:
        rng = self.rng
        stem = stem or self.next_img()
        faces = self.sample_faces(dt, force_person)
        tags, country = self.base_tags(place, faces, on_trip)
        gps = self.jitter_gps(place) if rng.random() < 0.93 else None
        rec = PhotoRec(
            rel=f"{rel_dir}/{stem}.jpg",
            dt=dt,
            gps=gps,
            faces=faces,
            tags=tags,
            country=country,
            sidecar="normal" if rng.random() < 0.85 else "none",
            place_label=f"{place[0]}, {place[1]}",
            folder_label=rel_dir.split("/")[-1],
        )
        self.photos.append(rec)
        return rec

    def day_dt(self, d: date) -> datetime:
        rng = self.rng
        return datetime(d.year, d.month, d.day,
                        rng.randint(8, 20), rng.randint(0, 59), rng.randint(0, 59))

    # -- main timeline ------------------------------------------------------

    def plan_year(self, year: int, budget: int):
        rng = self.rng
        today = self.today
        is_current = year == today.year
        year_end = date(year, today.month, today.day) if is_current else date(year, 12, 31)
        year_start = date(year, 1, 1)
        span_days = (year_end - year_start).days

        n_trips_target = rng.randint(2, 4)
        trip_budget = int(budget * 0.28)
        event_budget = int(budget * 0.07)
        start_len = len(self.photos)

        # --- trips ---
        trips = []
        used_days: set[int] = set()
        for _ in range(n_trips_target):
            dur = rng.randint(3, 14)
            if span_days < dur + 10:
                continue
            for _attempt in range(15):
                start_doy = rng.randint(5, span_days - dur - 2)
                trip_days = set(range(start_doy, start_doy + dur))
                if not (trip_days & used_days):
                    used_days |= trip_days
                    trips.append((start_doy, dur, rng.choice(DESTINATIONS)))
                    break
        if trips and trip_budget > 0:
            durs = [t[1] for t in trips]
            total_dur = sum(durs)
            trip_left = trip_budget
            for (start_doy, dur, dest) in trips:
                n = min(trip_left, max(5, int(trip_budget * dur / total_dur)))
                trip_left -= n
                start = year_start + timedelta(days=start_doy)
                folder = f"{year}/{year}-{start.month:02d} {dest[0]}"
                for i in range(n):
                    d = start + timedelta(days=i % dur)
                    self.add_photo(folder, self.day_dt(d), dest, on_trip=True)

        # --- events (birthdays of top people, Christmas) ---
        ev_people = rng.sample(self.people[:15], k=min(3, len(self.people[:15])))
        events = []
        for p in ev_people[: rng.randint(2, 3)]:
            m, d = p.birthday
            if is_current and (m, d) >= (today.month, today.day):
                continue
            first = p.name.split()[0]
            events.append((date(year, m, d), f"{year}/{year}-{m:02d} {first}s Birthday", p))
        if not is_current:
            events.append((date(year, 12, 24), f"{year}/{year}-12 Christmas", None))
        event_left = event_budget
        for ev_date, folder, person in events:
            n = min(rng.randint(16, 45), event_left)
            event_left -= n
            for i in range(n):
                d = ev_date + timedelta(days=rng.randint(0, 1))
                if d > year_end:
                    d = ev_date
                self.add_photo(folder, self.day_dt(d), HOME, on_trip=False,
                               force_person=person if i % 2 == 0 else None)

        # --- everyday ---
        folder = f"{year}/Everyday"
        n_everyday = max(0, budget - (len(self.photos) - start_len))
        # Seed on-this-day photos for past years so onThisDay memories fire.
        otd = 0
        if not is_current and n_everyday > 0:
            try:
                otd_date = date(year, today.month, today.day)
            except ValueError:
                otd_date = None
            if otd_date is not None:
                otd = min(6, n_everyday)
                for _ in range(otd):
                    self.add_photo(folder, self.day_dt(otd_date), HOME, on_trip=False)
        remaining = n_everyday - otd
        if remaining > 0:
            n_days = min(140, max(12, remaining // 3))
            all_days = [d for d in range(span_days + 1) if d not in used_days]
            rng.shuffle(all_days)
            day_list = sorted(all_days[:n_days])
            for i in range(remaining):
                doy = day_list[i % len(day_list)]
                d = year_start + timedelta(days=doy)
                self.add_photo(folder, self.day_dt(d), HOME, on_trip=False)

    def plan_unsorted(self, budget: int):
        rng = self.rng
        for i in range(budget):
            year = rng.randint(2018, self.today.year - 1)
            d = date(year, rng.randint(1, 12), rng.randint(1, 28))
            place = HOME if rng.random() < 0.7 else rng.choice(DESTINATIONS)
            rec = self.add_photo("Unsorted", self.day_dt(d), place, on_trip=False)
            if i % 7 == 0:
                rec.rel = rec.rel[:-4] + ".JPG"
            elif i % 11 == 0:
                rec.rel = rec.rel[:-4] + ".JPEG"

    # -- videos -------------------------------------------------------------

    def plan_videos(self):
        rng = self.rng
        n_standalone = max(6, round(self.count * 150 / 20000))
        n_live = max(3, round(self.count * 50 / 20000))

        for i in range(n_standalone):
            year = rng.randint(2019, self.today.year)
            last_day = date(year, self.today.month, self.today.day) if year == self.today.year else date(year, 12, 28)
            doy = rng.randint(0, max(1, (last_day - date(year, 1, 1)).days))
            d = date(year, 1, 1) + timedelta(days=doy)
            stem = self.next_vid()
            if i % 5 < 2:
                rel = f"Videos/{stem}.mp4"          # videos-only leaf
            else:
                rel = f"{year}/Everyday/{stem}.mp4"
            self.videos.append(VideoRec(rel=rel, dt=self.day_dt(d),
                                        duration=round(rng.uniform(2.0, 4.0), 1)))

        # Live Photo pairs: promote existing planned JPEGs by adding a same-stem .mov.
        candidates = [p for p in self.photos
                      if p.fmt == "JPEG" and p.rel.lower().endswith(".jpg")
                      and not p.rel.startswith("Edge Cases")]
        pairs = rng.sample(candidates, k=min(n_live, len(candidates)))
        for p in pairs:
            mov_rel = p.rel[: p.rel.rfind(".")] + ".mov"
            self.videos.append(VideoRec(rel=mov_rel, dt=p.dt,
                                        duration=round(rng.uniform(1.6, 3.0), 1)))

    # -- edge cases ---------------------------------------------------------

    def plan_edge_cases(self):
        rng = self.rng
        today = self.today

        def old_day() -> datetime:
            year = rng.randint(2019, today.year - 2)
            return self.day_dt(date(year, rng.randint(1, 12), rng.randint(1, 28)))

        # Embedded EXIF only — no sidecar at all.
        for _ in range(20):
            self.photos.append(PhotoRec(
                rel=f"Edge Cases/Embedded Only/{self.next_img()}.jpg",
                dt=old_day(), gps=self.jitter_gps(HOME),
                sidecar="none", place_label="Berlin, Germany",
                folder_label="Embedded Only"))

        # Sidecar only — no EXIF date/GPS; fs date fallback via utime.
        for _ in range(20):
            faces = self.face_specs(rng.sample(self.people[:20], k=rng.randint(1, 2)))
            tags = [f"People/{f[0]}" for f in faces] + [places_path(HOME)]
            self.photos.append(PhotoRec(
                rel=f"Edge Cases/Sidecar Only/{self.next_img()}.jpg",
                dt=old_day(), embed_exif=False, gps=None,
                faces=faces, tags=tags, country="DE", sidecar="normal",
                place_label="Berlin, Germany", folder_label="Sidecar Only"))

        # No date anywhere — no EXIF, no sidecar, mtime left at generation time.
        for _ in range(5):
            self.photos.append(PhotoRec(
                rel=f"Edge Cases/No Date/{self.next_img()}.jpg",
                dt=old_day(), embed_exif=False, gps=None, set_utime=False,
                sidecar="none", folder_label="No Date"))

        # Unnamed face regions — sidecars containing ONLY unnamed regions
        # (parser looks back 2000 chars for the last preceding mwg-rs:Name).
        for i in range(8):
            faces = self.face_specs([None] * rng.randint(1, 2))
            tags = [places_path(HOME)]
            if i < 4:
                tags.append(f"People/{self.people[i + 1].name}")
            self.photos.append(PhotoRec(
                rel=f"Edge Cases/Unnamed Faces/{self.next_img()}.jpg",
                dt=old_day(), gps=self.jitter_gps(HOME),
                faces=faces, tags=tags, country="DE", sidecar="normal",
                place_label="Berlin, Germany", folder_label="Unnamed Faces"))

        # First-token match — tag "People/Anna", region name "Anna Smith".
        anna = self.people[0]
        for _ in range(6):
            faces = self.face_specs([anna])
            self.photos.append(PhotoRec(
                rel=f"Edge Cases/Token Match/{self.next_img()}.jpg",
                dt=old_day(), gps=self.jitter_gps(HOME),
                faces=faces, tags=["People/Anna", places_path(HOME)],
                country="DE", sidecar="normal",
                place_label="Berlin, Germany", folder_label="Token Match"))

        # Case-variant duplicate tags — first-wins dedupe.
        for _ in range(6):
            faces = self.face_specs([anna])
            self.photos.append(PhotoRec(
                rel=f"Edge Cases/Case Variants/{self.next_img()}.jpg",
                dt=old_day(), gps=self.jitter_gps(HOME),
                faces=faces,
                tags=["people/anna smith", "People/Anna Smith", places_path(HOME)],
                country="DE", sidecar="normal",
                place_label="Berlin, Germany", folder_label="Case Variants"))

        # Alternative formats.
        fmts = [("JPG", "JPEG"), ("JPG", "JPEG"), ("JPG", "JPEG"),
                ("JPEG", "JPEG"), ("JPEG", "JPEG"), ("JPEG", "JPEG"),
                ("png", "PNG"), ("png", "PNG"),
                ("webp", "WEBP"), ("webp", "WEBP"),
                ("gif", "GIF"), ("gif", "GIF")]
        for ext, fmt in fmts:
            embed = fmt == "JPEG"
            self.photos.append(PhotoRec(
                rel=f"Edge Cases/Formats/{self.next_img()}.{ext}",
                dt=old_day(), fmt=fmt, embed_exif=embed,
                gps=self.jitter_gps(HOME) if embed else None,
                tags=[places_path(HOME)], country="DE",
                sidecar="normal", place_label="Berlin, Germany",
                folder_label="Formats"))

        # Broken sidecars: empty, truncated, region missing stArea:w.
        for kind in ["empty", "empty", "truncated", "truncated", "no_w", "no_w"]:
            faces = self.face_specs(rng.sample(self.people[:10], k=1))
            tags = [f"People/{f[0]}" for f in faces] + [places_path(HOME)]
            self.photos.append(PhotoRec(
                rel=f"Edge Cases/Broken Sidecars/{self.next_img()}.jpg",
                dt=old_day(), gps=self.jitter_gps(HOME),
                faces=faces, tags=tags, country="DE", sidecar=kind,
                place_label="Berlin, Germany", folder_label="Broken Sidecars"))

        # Deep nesting (5 levels below the root).
        deep_dir = "Edge Cases/Deep/Level 2/Level 3/Level 4/Level 5"
        for _ in range(16):
            self.add_photo(deep_dir, old_day(), HOME, on_trip=False)

        # Unicode + spaces in folder and file names.
        uni_dir = "Edge Cases/Ünïcode Fötos — 写真"
        for i in range(16):
            rec = self.add_photo(uni_dir, old_day(), HOME, on_trip=False)
            if i % 4 == 0:
                rec.rel = f"{uni_dir}/Café Photo {i:02d}.jpg"

        # An empty folder.
        self.empty_dirs.append("Edge Cases/Empty Folder")

    # -- guarantees ---------------------------------------------------------

    def ensure_rail_recency(self):
        """Top 25 people need >=1 photo within the last 2 years."""
        cutoff = self.now_dt - timedelta(days=2 * 365 - 30)
        recent_by_person: set[str] = set()
        recent_photos = [p for p in self.photos
                         if p.dt >= cutoff and p.sidecar == "normal"]
        for p in recent_photos:
            for t in p.tags:
                if t.startswith("People/"):
                    recent_by_person.add(t[len("People/"):])
        fixables = [p for p in recent_photos if len(p.faces) < 4]
        for person in self.people[:25]:
            if person.name in recent_by_person or not fixables:
                continue
            target = self.rng.choice(fixables)
            extra = self.face_specs([person])
            target.faces.extend(extra)
            target.tags.append(f"People/{person.name}")

    # -- top level ----------------------------------------------------------

    def plan(self):
        edge_total = 115
        if self.count < 300:
            raise SystemExit("--count must be >= 300 (edge-case set alone is ~115 photos)")
        main_budget = self.count - edge_total
        unsorted_n = max(10, main_budget // 60)
        main_budget -= unsorted_n

        years = list(range(2018, self.today.year + 1))
        per_year = main_budget // len(years)
        extra = main_budget - per_year * len(years)
        for i, y in enumerate(years):
            self.plan_year(y, per_year + (1 if i < extra else 0))
        self.plan_unsorted(unsorted_n)
        self.plan_edge_cases()

        # Exact-count adjustment: trim surplus from (or pad shortfall into)
        # Everyday folders, never touching on-this-day seeds.
        surplus = len(self.photos) - self.count
        if surplus > 0:
            removable_idx = [i for i, p in enumerate(self.photos)
                             if "/Everyday/" in p.rel
                             and (p.dt.month, p.dt.day) != (self.today.month, self.today.day)]
            drop = set(removable_idx[-surplus:])
            self.photos = [p for i, p in enumerate(self.photos) if i not in drop]
        elif surplus < 0:
            pad_year = self.today.year - 1
            for _ in range(-surplus):
                d = date(pad_year, self.rng.randint(1, 12), self.rng.randint(1, 28))
                self.add_photo(f"{pad_year}/Everyday", self.day_dt(d), HOME, on_trip=False)

        self.ensure_rail_recency()
        self.plan_videos()

        # Attach gradients derived from each record's folder.
        return self.photos, self.videos, self.empty_dirs


# ---------------------------------------------------------------------------
# Sidecar XML
# ---------------------------------------------------------------------------

def build_sidecar_xml(rec: PhotoRec) -> str:
    lines: list[str] = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append('<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="generate_test_library.py">')
    lines.append(' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">')
    lines.append('  <rdf:Description rdf:about=""')
    lines.append('    xmlns:digiKam="http://www.digikam.org/ns/1.0/"')
    lines.append('    xmlns:photo-tools="https://github.com/j23n/photo-tools/ns/1.0/"')
    lines.append('    xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"')
    lines.append('    xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#"')
    lines.append('    xmlns:stDim="http://ns.adobe.com/xap/1.0/sType/Dimensions#">')
    if rec.tags:
        lines.append('   <digiKam:TagsList>')
        lines.append('    <rdf:Seq>')
        for t in rec.tags:
            lines.append(f'     <rdf:li>{escape(t)}</rdf:li>')
        lines.append('    </rdf:Seq>')
        lines.append('   </digiKam:TagsList>')
    if rec.country:
        lines.append(f'   <photo-tools:CountryCode>{escape(rec.country)}</photo-tools:CountryCode>')
    if rec.faces:
        # Unnamed regions first: the parser resolves a region's name from the
        # LAST mwg-rs:Name in the preceding 2000 chars, so an unnamed region
        # emitted after a named one would inherit that name.
        faces = sorted(rec.faces, key=lambda f: 0 if f[0] is None else 1)
        lines.append('   <mwg-rs:Regions rdf:parseType="Resource">')
        lines.append(f'    <mwg-rs:AppliedToDimensions stDim:w="{W}" stDim:h="{H}" stDim:unit="pixel"/>')
        lines.append('    <mwg-rs:RegionList>')
        lines.append('     <rdf:Seq>')
        for (name, cx, cy, w, h, _color, _initials) in faces:
            lines.append('      <rdf:li rdf:parseType="Resource">')
            lines.append('       <mwg-rs:Type>Face</mwg-rs:Type>')
            if name is not None:
                lines.append(f'       <mwg-rs:Name>{escape(name)}</mwg-rs:Name>')
            w_attr = '' if rec.sidecar == "no_w" else f' stArea:w="{w}"'
            lines.append(
                f'       <mwg-rs:Area stArea:x="{cx}" stArea:y="{cy}"'
                f'{w_attr} stArea:h="{h}" stArea:unit="normalized"/>')
            lines.append('      </rdf:li>')
        lines.append('     </rdf:Seq>')
        lines.append('    </mwg-rs:RegionList>')
        lines.append('   </mwg-rs:Regions>')
    lines.append('  </rdf:Description>')
    lines.append(' </rdf:RDF>')
    lines.append('</x:xmpmeta>')
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Render workers (pure functions of their record; no RNG)
# ---------------------------------------------------------------------------

_G: dict = {}


def _init_worker(out_dir: str, ffmpeg_path: str | None):
    from PIL import ImageFont
    _G["out"] = out_dir
    _G["ffmpeg"] = ffmpeg_path
    try:
        _G["font_big"] = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 30)
        _G["font_small"] = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 19)
        _G["font_face"] = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 26)
    except OSError:
        f = ImageFont.load_default()
        _G["font_big"] = _G["font_small"] = _G["font_face"] = f


def _dms(value: float):
    v = abs(value)
    d = int(v)
    m = int((v - d) * 60)
    s = round(((v - d) * 60 - m) * 60 * 10000)
    return ((d, 1), (m, 1), (s, 10000))


def _build_exif(dt: datetime, gps: tuple[float, float] | None) -> bytes:
    import piexif
    ds = dt.strftime("%Y:%m:%d %H:%M:%S").encode("ascii")
    zeroth = {
        piexif.ImageIFD.Make: b"LocalGallery",
        piexif.ImageIFD.Model: b"SyntheticCam",
        piexif.ImageIFD.DateTime: ds,
    }
    exif_ifd = {
        piexif.ExifIFD.DateTimeOriginal: ds,
        piexif.ExifIFD.DateTimeDigitized: ds,
        piexif.ExifIFD.PixelXDimension: W,
        piexif.ExifIFD.PixelYDimension: H,
    }
    gps_ifd = {}
    if gps is not None:
        lat, lon = gps
        gps_ifd = {
            piexif.GPSIFD.GPSVersionID: (2, 3, 0, 0),
            piexif.GPSIFD.GPSLatitudeRef: b"N" if lat >= 0 else b"S",
            piexif.GPSIFD.GPSLatitude: _dms(lat),
            piexif.GPSIFD.GPSLongitudeRef: b"E" if lon >= 0 else b"W",
            piexif.GPSIFD.GPSLongitude: _dms(lon),
        }
    return piexif.dump({"0th": zeroth, "Exif": exif_ifd, "GPS": gps_ifd})


def render_photo(rec: PhotoRec) -> int:
    from PIL import Image, ImageDraw
    out = _G["out"]
    path = os.path.join(out, rec.rel)

    rel_dir = os.path.dirname(rec.rel)
    c1, c2 = folder_gradient(rel_dir)
    grad = Image.new("RGB", (1, 64))
    for y in range(64):
        t = y / 63
        grad.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(c1, c2)))
    img = grad.resize((W, H), Image.BILINEAR)
    draw = ImageDraw.Draw(img)

    # Faces: colored circle + initials at the exact normalized region coords.
    for (name, cx, cy, w, h, color, initials) in rec.faces:
        x0 = cx * W - w * W / 2
        y0 = cy * H - h * H / 2
        x1 = cx * W + w * W / 2
        y1 = cy * H + h * H / 2
        draw.ellipse([x0, y0, x1, y1], fill=color, outline=(255, 255, 255), width=3)
        draw.text((cx * W, cy * H), initials, font=_G["font_face"],
                  fill=(255, 255, 255), anchor="mm",
                  stroke_width=1, stroke_fill=(0, 0, 0))

    # Label block.
    stem = os.path.splitext(os.path.basename(rec.rel))[0]
    draw.text((20, H - 116), stem, font=_G["font_big"],
              fill=(255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0))
    draw.text((20, H - 76), rec.dt.strftime("%Y-%m-%d %H:%M"), font=_G["font_small"],
              fill=(255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0))
    line3 = rec.folder_label + (f"  ·  {rec.place_label}" if rec.place_label else "")
    draw.text((20, H - 48), line3, font=_G["font_small"],
              fill=(255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0))
    names = ", ".join(f[0] if f[0] else "(unnamed)" for f in rec.faces)
    if names:
        draw.text((20, 20), names, font=_G["font_small"],
                  fill=(255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0))

    if rec.fmt == "JPEG":
        exif_bytes = _build_exif(rec.dt, rec.gps) if rec.embed_exif else None
        if exif_bytes:
            img.save(path, "JPEG", quality=JPEG_QUALITY, exif=exif_bytes)
        else:
            img.save(path, "JPEG", quality=JPEG_QUALITY)
    elif rec.fmt == "PNG":
        img.save(path, "PNG")
    elif rec.fmt == "WEBP":
        img.save(path, "WEBP", quality=JPEG_QUALITY)
    elif rec.fmt == "GIF":
        img.convert("P", palette=Image.ADAPTIVE).save(path, "GIF")

    # Sidecar.
    if rec.sidecar != "none":
        sc_path = path + ".xmp"
        if rec.sidecar == "empty":
            data = b""
        else:
            xml = build_sidecar_xml(rec)
            if rec.sidecar == "truncated":
                xml = xml[: int(len(xml) * 0.55)]
            data = xml.encode("utf-8")
        with open(sc_path, "wb") as f:
            f.write(data)
        if rec.set_utime:
            ts = rec.dt.timestamp()
            os.utime(sc_path, (ts, ts))

    if rec.set_utime:
        ts = rec.dt.timestamp()
        os.utime(path, (ts, ts))
    return 1


def render_video(rec: VideoRec) -> int:
    out = _G["out"]
    ffmpeg = _G["ffmpeg"]
    if not ffmpeg:
        return 0
    path = os.path.join(out, rec.rel)
    creation = rec.dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    cmd = [
        ffmpeg, "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=640x480:rate=30",
        "-t", str(rec.duration),
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        "-metadata", f"creation_time={creation}",
        path,
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    if rec.set_utime:
        ts = rec.dt.timestamp()
        os.utime(path, (ts, ts))
    return 1


# ---------------------------------------------------------------------------
# Simulator install
# ---------------------------------------------------------------------------

FILE_PROVIDER_GROUP = "group.com.apple.FileProvider.LocalStorage"


def resolve_udid(arg: str) -> str:
    if arg.lower() != "booted":
        return arg
    out = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "booted", "-j"],
        check=True, capture_output=True, text=True).stdout
    data = json.loads(out)
    for devices in data.get("devices", {}).values():
        for dev in devices:
            if dev.get("state") == "Booted":
                return dev["udid"]
    raise SystemExit("No booted simulator found (xcrun simctl list devices booted)")


def find_file_provider_storage(udid: str) -> str:
    base = os.path.expanduser(
        f"~/Library/Developer/CoreSimulator/Devices/{udid}/data/Containers/Shared/AppGroup")
    for plist_path in sorted(glob.glob(os.path.join(base, "*", ".com.apple.mobile_container_manager.metadata.plist"))):
        try:
            with open(plist_path, "rb") as f:
                meta = plistlib.load(f)
        except Exception:
            continue
        if meta.get("MCMMetadataIdentifier") == FILE_PROVIDER_GROUP:
            return os.path.join(os.path.dirname(plist_path), "File Provider Storage")
    raise SystemExit(f"No AppGroup with {FILE_PROVIDER_GROUP} under {base} "
                     "(open the Files app in the simulator once, then retry)")


def do_install(src: str, target: str):
    if not os.path.isdir(src):
        raise SystemExit(f"--out directory does not exist: {src}")
    udid = resolve_udid(target)
    storage = find_file_provider_storage(udid)
    dest = os.path.join(storage, "TestLibrary")
    os.makedirs(dest, exist_ok=True)
    print(f"Installing to {dest}")
    subprocess.run(["rsync", "-a", "--delete", src.rstrip("/") + "/", dest + "/"], check=True)
    # Nudge the Files app to re-enumerate.
    subprocess.run(["xcrun", "simctl", "terminate", udid, "com.apple.DocumentsApp"],
                   capture_output=True)
    n_files = sum(len(fs) for _, _, fs in os.walk(dest))
    print(f"Installed {n_files} files to {dest}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def human_size(n: int) -> str:
    for unit in ["B", "KB", "MB", "GB"]:
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return f"{n} GB"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="Output directory (the library root)")
    ap.add_argument("--count", type=int, default=20000, help="Number of still photos (default 20000)")
    ap.add_argument("--seed", type=int, default=42, help="RNG seed (default 42)")
    ap.add_argument("--today", type=str, default=None, help="Anchor date YYYY-MM-DD (default: today)")
    ap.add_argument("--install", nargs="?", const="booted", default=None, metavar="booted|UDID",
                    help="Install --out into the simulator's Files-app storage (no generation)")
    args = ap.parse_args()

    if args.install is not None:
        do_install(args.out, args.install)
        return

    today = date.fromisoformat(args.today) if args.today else date.today()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    ffmpeg = shutil.which("ffmpeg") or (
        "/opt/homebrew/bin/ffmpeg" if os.path.exists("/opt/homebrew/bin/ffmpeg") else None)
    if not ffmpeg:
        print("WARNING: ffmpeg not found — skipping all videos / Live Photo pairs", file=sys.stderr)

    t0 = time.monotonic()
    planner = Planner(args.count, args.seed, today)
    photos, videos, empty_dirs = planner.plan()

    # Create every directory up front (workers only write files).
    dirs = {os.path.join(out, os.path.dirname(p.rel)) for p in photos}
    dirs |= {os.path.join(out, os.path.dirname(v.rel)) for v in videos}
    dirs |= {os.path.join(out, d) for d in empty_dirs}
    for d in sorted(dirs):
        os.makedirs(d, exist_ok=True)

    n_workers = max(2, os.cpu_count() or 4)
    print(f"Planning done: {len(photos)} photos, {len(videos)} videos "
          f"({time.monotonic() - t0:.1f}s). Rendering with {n_workers} workers...")

    done = 0
    with multiprocessing.Pool(n_workers, initializer=_init_worker,
                              initargs=(out, ffmpeg)) as pool:
        for _ in pool.imap_unordered(render_photo, photos, chunksize=64):
            done += 1
            if done % 2000 == 0:
                print(f"  photos: {done}/{len(photos)}")
        if ffmpeg and videos:
            vdone = 0
            for _ in pool.imap_unordered(render_video, videos, chunksize=1):
                vdone += 1
                if vdone % 50 == 0:
                    print(f"  videos: {vdone}/{len(videos)}")

    elapsed = time.monotonic() - t0

    # Summary.
    n_sidecars = sum(1 for p in photos if p.sidecar != "none")
    sc_kinds: dict[str, int] = {}
    for p in photos:
        sc_kinds[p.sidecar] = sc_kinds.get(p.sidecar, 0) + 1
    live_stems = {os.path.splitext(p.rel)[0].lower() for p in photos if p.rel.lower().endswith((".jpg", ".jpeg"))}
    n_live = sum(1 for v in videos if v.rel.lower().endswith(".mov")
                 and os.path.splitext(v.rel)[0].lower() in live_stems)
    n_standalone = len(videos) - n_live
    tagged_people = {t[len("People/"):] for p in photos for t in p.tags
                     if t.startswith("People/")}
    total_size = 0
    total_files = 0
    for root, _, files in os.walk(out):
        for f in files:
            total_files += 1
            total_size += os.path.getsize(os.path.join(root, f))

    print()
    print("=== Generation summary ===")
    print(f"Photos (stills):    {len(photos)}")
    print(f"Sidecars:           {n_sidecars}  "
          f"(normal {sc_kinds.get('normal', 0)}, empty {sc_kinds.get('empty', 0)}, "
          f"truncated {sc_kinds.get('truncated', 0)}, missing-w {sc_kinds.get('no_w', 0)})")
    print(f"Videos:             {n_standalone} standalone + {n_live} Live Photo pairs")
    print(f"People tagged:      {len(tagged_people)} distinct "
          f"(of {len(planner.people)}, {sum(1 for p in planner.people if p.old_only)} old-only)")
    print(f"Folders:            {len(dirs)} (+{len(empty_dirs)} empty)")
    print(f"Total files:        {total_files}")
    print(f"Total size:         {human_size(total_size)}")
    print(f"Elapsed:            {elapsed:.1f}s")
    print()
    print(f"Library root: {out}")
    print("Install into the booted simulator with:")
    print(f"  uv run {os.path.abspath(__file__)} --out {out} --install booted")


if __name__ == "__main__":
    main()
