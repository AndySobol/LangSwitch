# Сборка компонента отдельно от LangSwitch

Каталог содержит полный исходный код Hunspell 1.7.6, с которым собран LangSwitch, и два сгенерированных
заголовка. Собрать статическую библиотеку можно без SwiftPM, одними Xcode Command Line Tools:

    ./build-static.sh /absolute/path/to/output

Команда создаёт `libhunspell.a`. Для использования нужны `src/hunspell/hunspell.h` и соседние заголовки.
LangSwitch компилирует тот же набор `.cxx` как цель `CHunspell`: C++14, `HUNSPELL_STATIC`,
`BUILDING_LIBHUNSPELL`.
