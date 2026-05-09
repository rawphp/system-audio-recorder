# Vendor

Static third-party libraries vendored as `.xcframework`s. These are checked into the repo so that builds and notarization are reproducible without fetching anything at build time.

## lame.xcframework

`libmp3lame` from LAME 3.100, built as a universal (arm64 + x86_64) static library and packaged as an `.xcframework`. Linked into the app target via `project.yml`.

### Source

- Upstream: https://lame.sourceforge.io/
- Version: `lame-3.100`
- Source tarball: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- SHA-256: `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`
- License: LGPL 2.0 (see `LICENSE-LAME.txt` and `LICENSE-LAME-additional.txt`)

### Reproducible build

Run from a clean checkout on macOS with Xcode command-line tools installed:

```bash
# 1. Download + verify
curl -L -o /tmp/lame-3.100.tar.gz \
  https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
echo "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  /tmp/lame-3.100.tar.gz" \
  | shasum -a 256 -c -

# 2. Extract
cd /tmp && tar xzf lame-3.100.tar.gz

# 3. Build arm64
cd /tmp/lame-3.100
./configure --host=aarch64-apple-darwin --prefix=/tmp/lame-arm64 \
  --disable-shared --enable-static --disable-frontend --disable-decoder \
  CC="clang -arch arm64 -mmacosx-version-min=14.4" \
  CFLAGS="-arch arm64 -mmacosx-version-min=14.4 -O2"
make clean && make -j8 && make install

# 4. Build x86_64
make distclean
./configure --host=x86_64-apple-darwin --prefix=/tmp/lame-x86_64 \
  --disable-shared --enable-static --disable-frontend --disable-decoder \
  CC="clang -arch x86_64 -mmacosx-version-min=14.4" \
  CFLAGS="-arch x86_64 -mmacosx-version-min=14.4 -O2"
make clean && make -j8 && make install

# 5. Fat-merge into a single universal static archive
lipo -create -output /tmp/lame-universal.a \
  /tmp/lame-arm64/lib/libmp3lame.a \
  /tmp/lame-x86_64/lib/libmp3lame.a

# 6. Build xcframework (replace REPO_ROOT with the absolute path to this checkout)
cd "$REPO_ROOT"
rm -rf Vendor/lame.xcframework
xcodebuild -create-xcframework \
  -library /tmp/lame-universal.a -headers /tmp/lame-arm64/include \
  -output Vendor/lame.xcframework

# 7. Add Swift module map so `import lame` works
cat > Vendor/lame.xcframework/macos-arm64_x86_64/Headers/module.modulemap <<'EOF'
module lame {
    header "lame/lame.h"
    export *
}
EOF
```

### Configure flags explained

| Flag | Why |
|---|---|
| `--disable-shared --enable-static` | Static archive only — avoids dyld + notarization bundling |
| `--disable-frontend` | We only need the encoder library, not the `lame` CLI |
| `--disable-decoder` | We only encode; saves ~tens of KB |
| `-mmacosx-version-min=14.4` | Matches app deployment target |

### Layout

```
lame.xcframework/
  Info.plist
  macos-arm64_x86_64/
    lame-universal.a            # fat archive: arm64 + x86_64
    Headers/
      module.modulemap          # exposes module `lame`
      lame/
        lame.h                  # public API
```

### Swift import

```swift
import lame
let version = String(cString: get_lame_version())  // "3.100"
```

### Verification

```bash
lipo -info Vendor/lame.xcframework/macos-arm64_x86_64/lame-universal.a
# Architectures in the fat file: ... are: x86_64 arm64
```
