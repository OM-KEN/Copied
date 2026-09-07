#!/bin/bash
set -euo pipefail

fixture=$(mktemp -d "${TMPDIR:-/tmp}/Copied-build-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
cp build.sh Info.plist "$fixture/"
while IFS= read -r source; do
    mkdir -p "$fixture/$(dirname "$source")"
    touch "$fixture/$source"
done < <(awk '/^SOURCES=\(/ { inside=1; next } inside && /^\)/ { exit } inside { print $1 }' build.sh)
mkdir -p "$fixture/Copied.icon/Assets/nested" "$fixture/bin"
printf '1.0.0\n' > "$fixture/VERSION"
printf 'first icon\n' > "$fixture/Copied.icon/Assets/nested/icon with spaces.svg"
touch "$fixture/Copied.icon/icon.json" "$fixture/Localizable.xcstrings" "$fixture/Copied.svg"
cat > "$fixture/bin/swiftc" <<'STUB'
#!/bin/bash
printf 'compile\n' >> "$COPIED_BUILD_TEST_ROOT/compilations"
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then touch "$2"; exit 0; fi
    shift
done
exit 1
STUB
cat > "$fixture/bin/codesign" <<'STUB'
#!/bin/bash
if [[ -f "$COPIED_BUILD_TEST_ROOT/sign-fails" ]]; then exit 42; fi
STUB
printf '#!/bin/bash\nexit 0\n' > "$fixture/bin/xcrun"
chmod +x "$fixture/bin/"*
export COPIED_BUILD_TEST_ROOT="$fixture"
export PATH="$fixture/bin:$PATH"
cd "$fixture"
bash build.sh > build.log 2>&1
bash build.sh >> build.log 2>&1
[[ $(wc -l < compilations) -eq 1 ]]
printf 'changed icon\n' > "Copied.icon/Assets/nested/icon with spaces.svg"
bash build.sh >> build.log 2>&1
[[ $(wc -l < compilations) -eq 2 ]]
printf 'another icon\n' > "Copied.icon/Assets/nested/icon with spaces.svg"
touch sign-fails
if bash build.sh >> build.log 2>&1; then
    echo 'FAIL: signing failure was reported as success' >&2
    exit 1
fi
[[ ! -e .build/.source_fingerprint ]]
rm sign-fails
bash build.sh >> build.log 2>&1
[[ $(wc -l < compilations) -eq 4 ]]
rm ClipboardPipeline.swift
if bash build.sh >> build.log 2>&1; then
    echo 'FAIL: missing source was accepted' >&2
    exit 1
fi
[[ $(wc -l < compilations) -eq 4 ]]
echo 'BuildScriptTests: PASS'
