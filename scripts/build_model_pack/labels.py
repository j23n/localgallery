"""Taxonomy leaves → zero-shot label set, derived from photo-tools.

The label set is not invented here: it is the set of distinct `Objects/*` and
`Scenes/*` target paths in photo-tools'
`src/photo_tools/data/ram_tag_mapping.yaml`, which is the file that defines
what a *legal* tag is for both tools. Deriving the list rather than curating a
new one means every tag the core can write is a tag photo-tools already knows
how to read, and a taxonomy change over there is a rebuild over here rather
than a merge.

# Prompts

photo-tools has no prompt phrasing to mirror — its tagger is RAM++, a
multi-label classifier with a trained per-class head, and its `clip_tagger.py`
only produces *image* embeddings (landmarks, duplicates, "find similar"). So
the phrasing is ours, and it is deliberately boring:

    a photo of a {leaf}

with three deviations, all of them mechanical:

1. **Article.** `a`/`an` by first letter, with a short exception list for the
   words where the letter lies (`a uniform`, `an hour`).
2. **Overrides.** `OVERRIDES` below hand-writes the prompt for the leaves where
   the template produces nonsense: the eight `*/General` catch-alls (whose leaf
   word is not the concept — the *parent* is), the `Scenes/Weather/*` branch
   (adjectives and seasons, not nouns), and a handful of mass nouns.
3. **Disambiguation.** 61 leaf words are used by more than one path. Some of
   those pairs are genuinely different concepts — `Objects/Food/Fruit/Apple`
   and `Objects/Plant/Tree/Apple` are a fruit and a tree — and giving both the
   same prompt would give them the same embedding, the same score, and a
   coin-flip for the cap. So a duplicated leaf gets its parent appended:

       a photo of an apple, a kind of fruit
       a photo of an apple, a kind of tree

   The other duplicates are filing inconsistencies in the mapping rather than
   distinct concepts (`Vehicle/Water/Boat` and `Vehicle/Watercraft/Boat`), and
   there the suffix is harmless noise: both paths mean boat, both score alike,
   and both are emitted. That is the same outcome as identical prompts, minus
   the tie-break coin flip.

The template was picked by measurement, not taste — see the README's
"Prompt template" section for the comparison against the article-less and
bare-leaf variants.
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml

# ---------------------------------------------------------------------------
# Where the taxonomy comes from
# ---------------------------------------------------------------------------

#: photo-tools checkout, sibling of the localgallery checkout by default.
DEFAULT_PHOTO_TOOLS = Path(__file__).resolve().parents[3] / "photo-tools"

MAPPING_RELPATH = Path("src/photo_tools/data/ram_tag_mapping.yaml")

#: Only these two roots are zero-shot-taggable. `People/*` is face recognition
#: (Phase 2) and both `gallery-meta` and the pack loader refuse it; `Landmarks/*`
#: and `Places/*` are geocoding, which stays desktop-side.
ROOTS = ("Objects", "Scenes")

#: Per-root caps, straight from photo-tools' `taxonomy.CATEGORY_CONFIG`.
ROOT_MAX_TAGS = {"Objects": 8, "Scenes": 6}


# ---------------------------------------------------------------------------
# Prompt phrasing
# ---------------------------------------------------------------------------

TEMPLATE = "a photo of {article} {text}"

#: Words whose first letter lies about the article they take.
_AN_EXCEPTIONS = ("hour", "honest", "herb")
_A_EXCEPTIONS = ("uniform", "unicycle", "university", "ukulele", "utensil", "one", "ewe")

#: Full-path prompt overrides. Kept explicit and small: every entry here is a
#: place the template would produce something a human would not say.
OVERRIDES = {
    # `*/General` — the leaf word is a placeholder; the parent is the concept.
    "Objects/Art/General": "a photo of a work of art",
    "Objects/Artifact/General": "a photo of a man-made artifact",
    "Objects/Container/General": "a photo of a container",
    "Objects/Furniture/General": "a photo of a piece of furniture",
    "Objects/Instrument/General": "a photo of a musical instrument",
    "Objects/Plant/General": "a photo of a plant",
    "Objects/Toy/General": "a photo of a toy",
    "Objects/Weapon/General": "a photo of a weapon",
    # Mass nouns and category words the article breaks.
    "Objects/Medical/Equipment": "a photo of medical equipment",
    "Objects/Sport/Equipment": "a photo of sports equipment",
    "Objects/Artifact/Currency/Money": "a photo of money",
    "Objects/Urban/Money": "a photo of money on a street",
    "Objects/Household/Kitchenware/Silverware": "a photo of silverware",
    "Objects/Tool/Kitchen/Silverware": "a photo of kitchen silverware",
    # `Scenes/Weather/*` is adjectives and seasons, not nouns.
    "Scenes/Weather/Autumn": "a photo taken in autumn",
    "Scenes/Weather/Spring": "a photo taken in spring",
    "Scenes/Weather/Summer": "a photo taken in summer",
    "Scenes/Weather/Winter": "a photo taken in winter",
    "Scenes/Weather/Cloudy": "a photo taken on a cloudy day",
    "Scenes/Weather/Foggy": "a photo taken in fog",
    "Scenes/Weather/Frost": "a photo of frost",
    "Scenes/Weather/Rainy": "a photo taken in the rain",
    "Scenes/Weather/Snowy": "a photo taken in the snow",
    "Scenes/Weather/Stormy": "a photo taken during a storm",
    "Scenes/Weather/Sunny": "a photo taken on a sunny day",
    "Scenes/Weather/Windy": "a photo taken on a windy day",
    # Scene words that are not places you photograph "a" of.
    "Scenes/Nature/Water/Underwater": "an underwater photo",
    "Scenes/Venue/Religious/Worship": "a photo of a place of worship",
}


def article_for(text: str) -> str:
    """`a` or `an` for `text`, by first letter plus a short exception list."""
    lowered = text.lower()
    if lowered.startswith(_A_EXCEPTIONS):
        return "a"
    if lowered.startswith(_AN_EXCEPTIONS):
        return "an"
    return "an" if lowered[:1] in "aeiou" else "a"


def leaf_of(path: str) -> str:
    """Last path segment, e.g. `Cat` for `Objects/Animal/Mammal/Cat`."""
    return path.rsplit("/", 1)[1]


def parent_of(path: str) -> str:
    """Second-to-last segment, e.g. `Mammal` for `Objects/Animal/Mammal/Cat`."""
    return path.rsplit("/", 2)[-2]


def _text_of(path: str) -> str:
    """The noun phrase for `path`: the leaf, lowercased, hyphens kept."""
    return leaf_of(path).lower()


def prompt_for(path: str, duplicated_leaves: set[str]) -> str:
    """The single prompt string whose embedding this label ships.

    `duplicated_leaves` is the set of leaf words used by more than one path in
    the *whole* label set, so the caller has to build the list before it can
    ask for prompts. That coupling is deliberate: whether a label needs its
    parent for disambiguation is a property of the set, not of the label.
    """
    if path in OVERRIDES:
        return OVERRIDES[path]
    text = _text_of(path)
    prompt = TEMPLATE.format(article=article_for(text), text=text)
    if leaf_of(path) in duplicated_leaves:
        parent = parent_of(path).lower()
        prompt = f"{prompt}, a kind of {parent}"
    return prompt


# ---------------------------------------------------------------------------
# Label-set construction
# ---------------------------------------------------------------------------


def mapping_path(photo_tools_root: Path | None = None) -> Path:
    root = Path(photo_tools_root) if photo_tools_root else DEFAULT_PHOTO_TOOLS
    return root / MAPPING_RELPATH


def taxonomy_paths(photo_tools_root: Path | None = None) -> list[str]:
    """Every distinct `Objects/*` / `Scenes/*` target path, sorted."""
    src = mapping_path(photo_tools_root)
    with open(src) as f:
        mapping = yaml.safe_load(f)

    paths: set[str] = set()
    for entry in mapping.values():
        if entry is None:
            continue
        category = entry["category"]
        if category not in ROOTS:
            continue
        path = f"{category}/{entry['tag']}"
        if not re.fullmatch(r"[A-Za-z0-9 /-]+", path):
            raise ValueError(f"unexpected characters in taxonomy path {path!r}")
        if "/" not in entry["tag"]:
            # A two-segment path (`Scenes/Building`) is legal; a one-segment
            # one would make the root its own leaf, which the pack loader
            # cannot key against `roots`.
            pass
        paths.add(path)
    return sorted(paths)


def build_labels(photo_tools_root: Path | None = None) -> list[dict[str, str]]:
    """`[{"path": ..., "prompt": ...}, ...]`, sorted by path.

    Sorted, not mapping-order: the row order of `label_embeddings.f32` is this
    list's order, and a rebuild has to reproduce it byte for byte.
    """
    paths = taxonomy_paths(photo_tools_root)
    seen: dict[str, int] = {}
    for path in paths:
        seen[leaf_of(path)] = seen.get(leaf_of(path), 0) + 1
    duplicated = {leaf for leaf, n in seen.items() if n > 1}
    return [{"path": p, "prompt": prompt_for(p, duplicated)} for p in paths]


if __name__ == "__main__":  # pragma: no cover - a quick eyeball of the list
    import sys

    labels = build_labels()
    print(f"{len(labels)} labels", file=sys.stderr)
    for label in labels:
        print(f"{label['path']}\t{label['prompt']}")
