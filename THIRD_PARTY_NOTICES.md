# Third-party notices

LangSwitch itself is released under the MIT License (see `LICENSE`). It includes the following
third-party components, each under its own terms.

## Hunspell 1.7.6

- Location: `ThirdParty/Hunspell/`
- Upstream: <https://github.com/hunspell/hunspell>, revision `15faca15532b34db3106d50f162e5edc2503d6d6`
- License: tri-licensed GPL 2.0+ / LGPL 2.1+ / MPL 1.1. LangSwitch uses it under the **Mozilla Public
  License 1.1** (`ThirdParty/Hunspell/COPYING.MPL`).
- Modifications: none to the engine. `hunvisapi.h` and `hunversion.h` are generated from the upstream
  templates; `include/CHunspell.h` exposes the C API to Swift.
- Source availability: the complete, unmodified source of the component is part of this repository,
  together with its checksums (`ThirdParty/Hunspell/manifest.json`) and build notes.

## Russian spelling dictionary (ru_RU)

- Location: `Sources/LangSwitchLexicon/Resources/Hunspell/ru/`
- Source: LibreOffice dictionaries, revision `c0865a85eb67dc377f2cf8e8fe2c4fa9e53f0dcb`
- Copyright (c) 1997–2008 Alexander I. Lebedev. BSD-style license; the full text is in
  `README_ru_RU.txt` next to the dictionary. Distributed unmodified.

## English spelling dictionary (en_US)

- Location: `Sources/LangSwitchLexicon/Resources/Hunspell/en/`
- Source: SCOWL / English Speller Database, release 2026.02.25, <https://wordlist.aspell.net>
- Copyright 2000–2026 Kevin Atkinson and contributors. Permissive license; the full text is in
  `README_en_US.txt` next to the dictionary. Distributed unmodified.

## Word frequencies (FrequencyWords, OpenSubtitles 2018)

- Location: `Sources/LangSwitchCore/Resources/Frequency/ru-extended.txt`, `en-extended.txt` — word
  lists derived from the counts (filtered against the spelling dictionaries, ordered by frequency).
- Source: <https://github.com/hermitdave/FrequencyWords>, `content/2018/ru/ru_full.txt` and
  `content/2018/en/en_full.txt`, by Hermit Dave, based on the OpenSubtitles 2018 corpus.
- License: **Creative Commons Attribution-ShareAlike 4.0** (<https://creativecommons.org/licenses/by-sa/4.0/>).
  The two derived lists are distributed under the same license. They are data files read by the
  application; the MIT License of the code does not extend to them.

## Sentences (Tatoeba)

- Location: `Sources/LangSwitchCore/Resources/Context/ru.pairs`, `en.pairs` — counts of neighbouring
  word pairs computed from the sentences; `Tests/LangSwitchLexiconTests/Fixtures/sentences-*.txt` and
  `unlisted-*.txt` — sentences and words taken from them unchanged.
- Source: <https://tatoeba.org>, per-language sentence exports of 14 November 2026.
- License: **Creative Commons Attribution 2.0 France** (<https://creativecommons.org/licenses/by/2.0/fr/>).
  Sentences are the work of Tatoeba contributors.

How these files are produced is described in `docs/DATA.md`.

## Authored data

The core frequency lists (`ru.txt`, `en.txt`), term list, thesaurus and trainer texts in
`Sources/LangSwitchCore/Resources/`, and the typo and colloquial corpora in
`Tests/LangSwitchLexiconTests/Fixtures/`, were written for this project and are covered by the MIT License.
