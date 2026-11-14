#!/bin/zsh
# Downloads the open corpora that the generated language data is built from (about 90 MB).
# Nothing here is needed to build or run LangSwitch: the generated files are in the repository.
# See docs/DATA.md for sources, licences and the rebuild steps.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
data="$root/.build/data"

fetch() {
    local folder=$1 url=$2
    mkdir -p "$data/$folder"
    curl --fail --silent --show-error --location --output "$data/$folder/${url:t}" "$url"
}

for code in ru en; do
    fetch "frequencywords-$code" \
        "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/$code/${code}_full.txt"
done
fetch tatoeba-ru "https://downloads.tatoeba.org/exports/per_language/rus/rus_sentences.tsv.bz2"
fetch tatoeba-en "https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2"
bzip2 -dkf "$data/tatoeba-ru/rus_sentences.tsv.bz2" "$data/tatoeba-en/eng_sentences.tsv.bz2"

shasum -a 256 "$data"/frequencywords-*/*.txt "$data"/tatoeba-*/*.bz2
echo "Next: swift run -c release LangSwitchData \"$data\" \"$root\""
