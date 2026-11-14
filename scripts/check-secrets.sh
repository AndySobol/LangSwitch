#!/bin/zsh
# Fails when something that looks like a credential is about to be committed.
# Scans tracked and untracked-but-not-ignored files; binary files are skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

patterns=(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'AKIA[0-9A-Z]{16}'
    'gh[pousr]_[A-Za-z0-9]{36,}'
    'github_pat_[A-Za-z0-9_]{60,}'
    'sk-[A-Za-z0-9_-]{32,}'
    'xox[baprs]-[A-Za-z0-9-]{20,}'
    'AIza[0-9A-Za-z_-]{35}'
    '(password|passwd|secret|api[_-]?key|token)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"' ]{12,}["'"'"']'
)

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    files=("${(@f)$(git ls-files --cached --others --exclude-standard)}")
else
    files=("${(@f)$(find . -type f -not -path './.build/*' -not -path './dist/*' -not -path './.legacy/*' -not -path './.git/*')}")
fi

found=0
for pattern in "${patterns[@]}"; do
    if matches=$(grep -IEn -i -- "$pattern" "${files[@]}" 2>/dev/null | grep -v '^scripts/check-secrets.sh:' ); then
        echo "Possible secret ($pattern):" >&2
        echo "$matches" | cut -c1-160 >&2
        found=1
    fi
done

for file in "${files[@]}"; do
    case "$file" in
        *.p12|*.pem|*.key|*.mobileprovision|*.provisionprofile|*.keychain|.env|.env.*)
            echo "Credential file must not be committed: $file" >&2
            found=1 ;;
    esac
done

if [[ $found -ne 0 ]]; then exit 1; fi
echo "OK: no secrets found in ${#files[@]} files"
