#!/usr/bin/env python3
"""Fits the automatic-correction policy to the evaluation corpora.

The spelling model proposes a replacement for an unknown word; this policy decides whether the
proposal is safe to apply without asking. It is a set of small logistic models, one per family of
slips with an offset for every kind of slip, over features of the proposal (how common the word is,
whether it was seen after the previous word, how far the next explanation is, ...). Nothing here looks at particular words.

    LANGSWITCH_ANALYSIS=analysis.tsv swift test -c release -Xswiftc -enable-testing --filter corpusAnalysis
    python3 scripts/train-correction-policy.py analysis.tsv [--write]

One row in five is held out: the script reports the result on rows the models have not seen.
With --write the models, fitted on every row, go to Sources/LangSwitchCore/Resources/Rules/correction-policy.json.
"""
import collections, json, math, sys, zlib
from pathlib import Path

FAMILIES = {
    "slip": ["swappedLetters", "droppedLetter", "doubledLetter"],
    "stray": ["strayLetter", "neighbouringKey"],
    "split": ["missingSpace"],
    "joiner": ["missingHyphen", "strayHyphen", "missingApostrophe"],
    "spelling": ["droppedDoubleLetter", "confusedVowel", "confusedConsonant", "softSign", "ruleSpelling",
                 "silentLetter", "misplacedDouble"],
    "double": ["twoSlips"],
}
FAMILY_OF = {edit: family for family, edits in FAMILIES.items() for edit in edits}
PROCLITICS = {
    "ru": set("в во к ко с со у о об на по за до от из не ни и а но при про под над для без".split()),
    "en": set("a an the in on at to of no as is it up so i".split()),
}
# Shares of ordinary typing that each corpus stands for: slips of the hand are the everyday case,
# the lists of slang and unlisted words are deliberately dense stress tests.
WEIGHTS = {"typo": 1.0, "mistake": 1.0, "slip": 1.5, "frequent": 0.5, "clean": 2.0, "colloquial": 0.25, "colloquial-after": 0.25, "unlisted": 0.5}
MISTYPED = ("typo", "mistake", "slip", "frequent")
# What counts for a proposal can never count against it, and the other way round: the corpora differ
# in more than the typing they hold, and an unconstrained fit would pick those differences up.
SUPPORTS = {"rank", "commonest", "everyday", "listed", "seenAfter", "seenAfterLog", "margin", "clear", "distinct",
            "unique", "seenTogether", "seenTogetherLog", "glued", "long"}
OPPOSES = {"unranked", "lemmaOnly", "rivalRanked", "candidates", "score", "firstLetter"}
FEATURES = [
    "bias", "length2", "length3", "length4", "long", "size", "rank", "unranked", "lemmaOnly", "commonest", "everyday",
    "listed", "seenAfter", "seenAfterLog", "margin", "clear", "distinct", "unique", "firstLetter", "plausibility",
    "rivalRanked", "candidates", "seenTogether", "seenTogetherLog", "glued", "score", "english",
]


def load(path):
    rows = []
    for line in Path(path).read_text().split("\n")[1:]:
        fields = line.split("\t")
        if len(fields) < 7:
            continue
        corpus, word, right, previous, _, plausibility, listed = fields[:7]
        count, _, listed = listed.partition(";")
        candidates = []
        for item in filter(None, listed.split("|")):
            text, edit, score, form, lemma, after, together = item.rsplit(":", 6)
            candidates.append(dict(word=text, edit=edit, score=float(score), form=int(form), lemma=int(lemma),
                                   after=int(after), together=int(together)))
        kind, _, language = corpus.rpartition("-")
        if language not in ("ru", "en"):
            kind, language = corpus, "ru"
        rows.append(dict(corpus=corpus, kind=kind, language=language, word=word, right=right, previous=previous,
                         plausibility=float(plausibility), count=int(count), candidates=candidates,
                         held_out=zlib.crc32(f"{corpus}/{word}/{previous}".encode()) % 5 == 0))
    return rows


def features(row):
    best = row["candidates"][0]
    rival = row["candidates"][1] if len(row["candidates"]) > 1 else None
    word, target, length = row["word"], best["word"].lower(), len(row["word"])
    parts = target.split(" ")
    margin = min(rival["score"] - best["score"], 1.0) if rival else 1.0
    values = {
        "bias": 1.0,
        "length2": float(length == 2), "length3": float(length == 3), "length4": float(length == 4),
        "long": float(length >= 7),
        "size": min(length, 12) / 12,
        "rank": 1 - math.log10(best["form"] + 10) / 5.5 if best["form"] >= 0 else 0.0,
        "unranked": float(best["form"] < 0),
        "lemmaOnly": float(best["form"] < 0 <= best["lemma"]),
        "commonest": float(0 <= best["form"] < 300),
        "everyday": float(0 <= best["form"] < 6000),
        "listed": float(0 <= best["form"] < 30000),
        "seenAfter": float(best["after"] > 0),
        "seenAfterLog": min(math.log10(best["after"] + 1) / 3, 1.0),
        "margin": margin,
        "clear": float(margin >= 0.15),
        "distinct": float(margin >= 0.4),
        "unique": float(rival is None),
        "firstLetter": float(target[:1] != word[:1]),
        "plausibility": max(-4.0, min(row["plausibility"], 2.0)) / 4,
        "rivalRanked": float(rival is not None and rival["form"] >= 0 and margin < 0.5),
        "candidates": min(math.log10(row["count"]) / 1.5, 1.0),
        "seenTogether": float(best["together"] > 0),
        "seenTogetherLog": min(math.log10(best["together"] + 1) / 3, 1.0),
        "glued": float(len(parts) == 2 and parts[0] in PROCLITICS[row["language"]] and len(parts[1]) >= 3),
        "score": best["score"] / 2.5,
        "english": float(row["language"] == "en"),
    }
    return best["edit"], [values[name] for name in FEATURES]


def fit(samples, names, steps=600, rate=0.5, penalty=1e-3):
    size = len(samples[0][0])
    weights = [0.0] * size
    total = sum(weight for _, _, weight in samples)
    signs = [1 if name in SUPPORTS else -1 if name in OPPOSES else 0 for name in names] + [0] * (size - len(names))
    for _ in range(steps):
        gradient = [0.0] * size
        for vector, label, weight in samples:
            z = sum(w * x for w, x in zip(weights, vector))
            error = (1 / (1 + math.exp(-max(-30, min(z, 30)))) - label) * weight
            for index, x in enumerate(vector):
                if x:
                    gradient[index] += error * x
        weights = [w - rate * (g / total + penalty * w) for w, g in zip(weights, gradient)]
        weights = [max(w, 0.0) if sign > 0 else min(w, 0.0) if sign < 0 else w for w, sign in zip(weights, signs)]
    return weights


def probability(weights, vector):
    z = sum(w * x for w, x in zip(weights, vector))
    return 1 / (1 + math.exp(-max(-30, min(z, 30))))


def samples_of(rows):
    grouped = collections.defaultdict(list)
    for row in rows:
        if not row["candidates"]:
            continue
        edit, vector = features(row)
        label = float(row["kind"] in MISTYPED and row["candidates"][0]["word"].lower() == row["right"])
        grouped[edit].append((vector, label, WEIGHTS[row["kind"]]))
    return grouped


def fit_all(rows):
    """One model per family of slips, with an offset for every kind inside it; returned per kind."""
    grouped = samples_of(rows)
    models = {}
    for family, edits in FAMILIES.items():
        pooled = [(vector + [float(edit == other) for other in edits[1:]], label, weight)
                  for edit in edits for vector, label, weight in grouped.get(edit, [])]
        if not pooled:
            continue
        weights = fit(pooled, FEATURES)
        shared, offsets = weights[:len(FEATURES)], [0.0] + weights[len(FEATURES):]
        for edit, offset in zip(edits, offsets):
            # The offset of a kind is folded into the bias, which is the first feature.
            models[edit] = [shared[0] + offset] + shared[1:]
    return models


def report(models, rows, thresholds):
    totals = collections.Counter(row["corpus"] for row in rows)
    print("threshold  " + "  ".join(f"{name:>16}" for name in sorted(totals)))
    for threshold in thresholds:
        fixed, wrong = collections.Counter(), collections.Counter()
        for row in rows:
            if not row["candidates"]:
                continue
            edit, vector = features(row)
            if edit not in models or probability(models[edit], vector) < threshold:
                continue
            right = row["kind"] in MISTYPED and row["candidates"][0]["word"].lower() == row["right"]
            (fixed if right else wrong)[row["corpus"]] += 1
        cells = []
        for name in sorted(totals):
            if name.startswith(MISTYPED):
                cells.append(f"{100 * fixed[name] / totals[name]:5.1f} / {100 * wrong[name] / totals[name]:5.2f}   ")
            else:
                cells.append(f"{100 * wrong[name] / totals[name]:13.2f}   ")
        print(f"   {threshold:.2f}    " + "  ".join(cells))


def main():
    rows = load(sys.argv[1])
    training = [row for row in rows if not row["held_out"]]
    testing = [row for row in rows if row["held_out"]]
    print(f"{len(training)} rows to fit, {len(testing)} held out.")
    print("Held-out rows: typos and slips as fixed % / replaced by another word %, the rest as changed %.")
    report(fit_all(training), testing, [0.5, 0.6, 0.7, 0.78, 0.85, 0.9, 0.95])
    if "--write" in sys.argv:
        models = fit_all(rows)
        threshold = float(sys.argv[sys.argv.index("--threshold") + 1]) if "--threshold" in sys.argv else 0.8
        policy = {"threshold": threshold, "features": FEATURES,
                  "models": {edit: [round(w, 4) for w in weights] for edit, weights in sorted(models.items())}}
        target = Path(__file__).resolve().parent.parent / "Sources/LangSwitchCore/Resources/Rules/correction-policy.json"
        target.write_text(json.dumps(policy, ensure_ascii=False, indent=1) + "\n")
        print(f"written {target}")


main()
