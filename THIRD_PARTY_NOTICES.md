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

## Authored data

The frequency lists, term list, slang list, misspelling tables, thesaurus and trainer texts in
`Sources/LangSwitchCore/Resources/` were written for this project and are covered by the MIT License.
