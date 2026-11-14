#!/bin/sh
set -eu
source_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$source_root/.build"}
mkdir -p "$output"
for source_file in "$source_root"/src/hunspell/*.cxx; do
    name=$(basename "$source_file" .cxx)
    xcrun clang++ -std=c++14 -O2 -Werror -DHUNSPELL_STATIC -DBUILDING_LIBHUNSPELL \
        -c "$source_file" -o "$output/$name.o"
done
xcrun libtool -static -o "$output/libhunspell.a" "$output"/*.o
