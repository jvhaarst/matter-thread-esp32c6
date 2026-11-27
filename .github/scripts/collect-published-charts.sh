#!/usr/bin/env bash
# Download every chart archive the published index lists into a directory, so the next
# Pages deployment carries them again. deploy-pages replaces the whole site, so an archive
# that is not in the uploaded artifact disappears, while an index that only merged the old
# entries would keep pointing at it.
#
#   collect-published-charts.sh <repository URL> <directory>
#
# An archive that is already gone is reported and skipped; regenerating the index from the
# directory afterwards drops its entry.
set -euo pipefail
url="${1:?repository URL}"
dir="${2:?directory}"
mkdir -p "$dir"
if ! curl -fsSL "$url/index.yaml" -o "$dir/published-index.yaml"; then
    echo "No published index at $url, nothing to collect"
    exit 0
fi
yq -r '.entries[][].urls[0]' "$dir/published-index.yaml" | while read -r archive; do
    name="$(basename "$archive")"
    if curl -fsSL "$archive" -o "$dir/$name"; then
        echo "kept $name"
    else
        rm -f "$dir/$name"
        echo "missing $name, dropped from the index"
    fi
done
rm -f "$dir/published-index.yaml"
