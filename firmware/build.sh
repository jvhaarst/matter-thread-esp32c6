#!/usr/bin/env bash
# Build the OpenThread RCP firmware for the Seeed Studio XIAO ESP32-C6.
#
# Runs entirely inside the pinned ESP-IDF container, so nothing is installed on
# the workstation. Output lands in firmware/out/.
#
#   ./firmware/build.sh
#
# Override the container runtime with CONTAINER_RUNTIME=docker.
set -euo pipefail

# espressif/idf:v6.1.1, pinned by digest. Bump both lines together.
IDF_VERSION="v6.1.1"
IDF_IMAGE="docker.io/espressif/idf@sha256:2b4f966c37eaedc19542b0637a5f850b2eff9478d8e858192aa0073d92c2dc91"

TARGET="esp32c6"
BOARD="xiao-esp32c6"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime="${CONTAINER_RUNTIME:-$(command -v podman || command -v docker)}"
mkdir -p "${here}/out"

# Same timestamp on every build of the same commit, so the binary is reproducible.
source_date_epoch="$(git -C "${here}" log -1 --format=%ct 2>/dev/null || echo 0)"

"${runtime}" run --rm \
    -v "${here}:/work" \
    -e IDF_VERSION="${IDF_VERSION}" \
    -e TARGET="${TARGET}" \
    -e BOARD="${BOARD}" \
    -e SOURCE_DATE_EPOCH="${source_date_epoch}" \
    "${IDF_IMAGE}" \
    bash -euo pipefail -c '
        actual="$(git -C "${IDF_PATH}" describe --tags)"
        if [ "${actual}" != "${IDF_VERSION}" ]; then
            echo "ERROR: image has ESP-IDF ${actual}, expected ${IDF_VERSION}" >&2
            exit 1
        fi

        for patch in /work/patches/*.patch; do
            echo "Applying $(basename "${patch}")"
            git -C "${IDF_PATH}" apply --verbose "${patch}"
        done

        cp -r "${IDF_PATH}/examples/openthread/ot_rcp" /tmp/ot_rcp
        cd /tmp/ot_rcp
        idf.py -D SDKCONFIG_DEFAULTS="sdkconfig.defaults;/work/sdkconfig.${BOARD}" \
            set-target "${TARGET}" build

        out="/work/out/ot_rcp-${BOARD}"
        (cd build && esptool --chip "${TARGET}" merge-bin -o "${out}.bin" @flash_args)

        ot="${IDF_PATH}/components/openthread/openthread"
        {
            echo "esp_idf=${actual}"
            echo "openthread_commit=$(git -C "${ot}" rev-parse HEAD)"
            echo "openthread_commit_date=$(git -C "${ot}" log -1 --format=%cs)"
            echo "spinel_rcp_api_version=$(sed -n "s/^#define SPINEL_RCP_API_VERSION \([0-9]*\).*/\1/p" "${ot}/src/lib/spinel/spinel.h")"
            echo "target=${TARGET}"
            echo "board=${BOARD}"
            echo "sha256=$(sha256sum "${out}.bin" | cut -d" " -f1)"
        } > "${out}.buildinfo"
        cat "${out}.buildinfo"
    '
