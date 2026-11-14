# Hunspell 1.7.6

Закреплённый upstream: <https://github.com/hunspell/hunspell/tree/15faca15532b34db3106d50f162e5edc2503d6d6>.
Из тройной лицензии GPL/LGPL/MPL выбрана **MPL 1.1**; исходные заголовки и тексты лицензий сохранены.

Код движка не изменён. `hunvisapi.h` и `hunversion.h` получены подстановкой значений в шаблоны upstream,
`include/CHunspell.h` открывает C API для Swift. Параметры компиляции — в `Package.swift` (цель `CHunspell`).

`manifest.json` хранит SHA-256 архива upstream, каждого исходного и сгенерированного файла.
`scripts/check-vendored.py` сверяет каталог с манифестом при каждой проверке; сеть для этого не нужна.

Словари и их лицензии лежат в `Sources/LangSwitchLexicon/Resources/Hunspell`: русский — из LibreOffice,
английский — SCOWL/ESDB 2026.02.25. Оба скопированы без изменений.
