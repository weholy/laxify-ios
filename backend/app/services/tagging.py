"""Turning whatever a track says about itself into tags we can reason about.

An upload describes itself in free text: a genre field someone typed, a tag
list, a title. "Emo Rap", "emo-rap", "emorap", "#emo #rap", "sad rap" are the
same thing, and none of them match each other as strings. This maps all of it
onto a small canonical vocabulary, so a listener's taste can be expressed as a
handful of tags and the wave can go looking for more of them.

Three axes, because they answer different questions:
  • **style** — what kind of music it is (emo-rap, phonk, house…)
  • **mood** — what it feels like (sad, calm, aggressive…)
  • **language** — which world it comes from (ru, en)

Deliberately small. A hundred tags nobody shares is a hundred tags that never
match; thirty that everybody's library touches is a taste profile.
"""

from __future__ import annotations

import re

# ─────────────────────────────────────────────────────────────────────────────
# The vocabulary
# ─────────────────────────────────────────────────────────────────────────────

# canonical tag -> the words that mean it, in either language.
STYLE_TAGS: dict[str, tuple[str, ...]] = {
    "emo-rap": ("emo rap", "emorap", "emo-rap", "sadboy", "sad rap", "эмо рэп", "эморэп"),
    "cloud-rap": ("cloud rap", "cloudrap", "клауд"),
    "trap": ("trap", "трэп", "треп"),
    "drill": ("drill", "дрилл"),
    "phonk": ("phonk", "фонк", "drift phonk"),
    "hip-hop": ("hip hop", "hiphop", "hip-hop", "rap", "рэп", "реп", "хип хоп", "hiphoprap"),
    "hyperpop": ("hyperpop", "hyper pop", "гиперпоп"),
    "pop": ("pop", "поп", "попса"),
    "rock": ("rock", "рок", "alternative", "альтернатива"),
    "punk": ("punk", "панк"),
    "metal": ("metal", "метал", "hardcore", "хардкор"),
    "shoegaze": ("shoegaze", "шугейз", "dream pop", "dreampop"),
    "indie": ("indie", "инди"),
    "electronic": ("electronic", "electro", "электроник", "edm"),
    "house": ("house", "хаус", "deep house"),
    "techno": ("techno", "техно"),
    "dnb": ("drum and bass", "drum & bass", "dnb", "d&b", "драм"),
    "dubstep": ("dubstep", "дабстеп", "bass"),
    "ambient": ("ambient", "эмбиент", "атмосфер"),
    "lofi": ("lofi", "lo-fi", "lo fi", "лоуфай", "лофай"),
    "jazz": ("jazz", "джаз"),
    "rnb": ("rnb", "r&b", "r n b", "рнб"),
    "soul": ("soul", "соул", "funk", "фанк"),
    "classical": ("classical", "классик", "piano", "фортепиано"),
    "folk": ("folk", "фолк", "acoustic", "акустик"),
    "reggaeton": ("reggaeton", "reggae", "регги", "латина"),
    "kpop": ("k-pop", "kpop", "кпоп"),
}

MOOD_TAGS: dict[str, tuple[str, ...]] = {
    "sad": ("sad", "грустн", "печаль", "depress", "депресс", "melanchol", "меланхол", "cry", "слез"),
    "calm": ("calm", "chill", "чилл", "спокойн", "тихая", "тихий", "relax", "релакс", "sleep", "сон"),
    "aggressive": ("aggressive", "агрессив", "hard", "жёстк", "жестк", "angry", "злой", "rage"),
    "energetic": ("energetic", "энергич", "hype", "бодр", "workout", "gym", "качалк", "dance", "танц"),
    "romantic": ("romantic", "романтик", "love", "любов", "lovesong"),
    "dark": ("dark", "тёмн", "темн", "horror", "witch", "gothic", "готик"),
    "dreamy": ("dreamy", "мечтат", "ethereal", "atmospheric", "воздушн"),
    "happy": ("happy", "весёл", "весел", "радост", "feelgood", "summer", "лето"),
}

# Treatments that change how a track sounds enough to be worth matching on.
TREATMENT_TAGS: dict[str, tuple[str, ...]] = {
    "slowed": ("slowed", "slow", "замедлен", "reverb"),
    "sped-up": ("sped up", "spedup", "speed up", "ускорен", "nightcore"),
    "remix": ("remix", "ремикс", "bootleg", "mashup"),
    "live": ("live", "концерт", "acoustic version"),
    "instrumental": ("instrumental", "инструментал", "beat", "бит"),
}

_CYRILLIC = re.compile(r"[а-яёА-ЯЁ]")
_SPLIT = re.compile(r"[\s,/|_\-#\"']+")


def _haystack(raw: dict) -> str:
    """Everything the upload says about itself, lowercased into one string."""
    user = raw.get("user") or {}
    parts = (
        raw.get("title"),
        raw.get("genre"),
        raw.get("tag_list"),
        raw.get("description"),
        user.get("username"),
    )
    return " ".join(str(p).lower() for p in parts if p)


def _match(text: str, table: dict[str, tuple[str, ...]]) -> set[str]:
    found: set[str] = set()
    for tag, needles in table.items():
        if any(needle in text for needle in needles):
            found.add(tag)
    return found


def derive(raw: dict) -> list[str]:
    """The canonical tags for one raw track, most specific first.

    Never empty: a track with nothing recognisable still gets a language,
    because that alone is worth matching on.
    """
    text = _haystack(raw)

    tags: list[str] = []
    tags += sorted(_match(text, STYLE_TAGS))
    tags += sorted(_match(text, MOOD_TAGS))
    tags += sorted(_match(text, TREATMENT_TAGS))

    title = f"{raw.get('title') or ''} {(raw.get('user') or {}).get('username') or ''}"
    tags.append("ru" if _CYRILLIC.search(title) else "en")

    return tags


def search_terms(tags: list[str], limit: int = 6) -> list[str]:
    """Words to actually go looking with.

    A canonical tag is for matching, not for searching — "emo-rap" finds less
    than "emo rap" does. The first spelling in each table is the one the
    source is most likely to have used.
    """
    terms: list[str] = []
    for tag in tags:
        for table in (STYLE_TAGS, MOOD_TAGS):
            if tag in table:
                terms.append(table[tag][0])
                break
        if len(terms) >= limit:
            break
    return terms
