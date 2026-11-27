#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}
if [[ ! -d "$sdk" && -d /opt/homebrew/share/android-commandlinetools ]]; then
  sdk=/opt/homebrew/share/android-commandlinetools
fi
tools="$sdk/build-tools/36.0.0"
platform="$sdk/platforms/android-36/android.jar"
if [[ ! -f "$platform" || ! -x "$tools/d8" ]]; then
  echo 'Set ANDROID_HOME to an SDK with platforms;android-36 and build-tools;36.0.0.' >&2
  exit 1
fi

mkdir -p .build/android dist
stage=$(mktemp -d "$PWD/.build/android/build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
vlc=$(./scripts/prepare-vlc.sh android)
res="$stage/res"
mkdir -p "$res"/{raw,drawable-nodpi} "$stage"/{generated,classes,dex}
ANDROID_HOME="$sdk" ./scripts/build-android-core.sh "$stage/lib"
cp -R Android/res/. "$res/"
cp Shared/Resources/*.mp4 "$res/raw/"
cp Shared/Resources/*.jpg "$res/drawable-nodpi/"
cp Shared/Resources/Marque.png "$res/drawable-nodpi/trame.png"
"$tools/aapt2" compile --dir "$res" -o "$stage/resources.zip"
"$tools/aapt2" compile --dir "$vlc/res" -o "$stage/vlc-resources.zip"
"$tools/aapt2" link -I "$platform" --manifest Android/AndroidManifest.xml \
  --extra-packages org.videolan --java "$stage/generated" -0 mp4 -o "$stage/app.apk" "$stage/resources.zip" "$stage/vlc-resources.zip"
compiler=${KOTLINC:-$(command -v kotlinc || true)}
if [[ -z $compiler ]]; then compiler="/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc"; fi
if [[ ! -f $compiler ]]; then echo 'Install Kotlin/JVM or set KOTLINC to its kotlinc script.' >&2; exit 1; fi
javac -Xlint:-options --release 8 -d "$stage/classes" "$stage/generated/app/trame/player/R.java" "$stage/generated/org/videolan/R.java"
jar cf "$stage/resources.jar" -C "$stage/classes" .
bash "$compiler" -jvm-target 1.8 -classpath "$platform:$stage/resources.jar:$vlc/classes.jar" -include-runtime \
  -d "$stage/trame.jar" Android/src/app/trame/player/*.kt
"$tools/d8" --min-api 26 --lib "$platform" --output "$stage/dex" "$vlc/classes.jar" "$stage/resources.jar" "$stage/trame.jar"
(cd "$stage/dex" && zip -q -0 "$stage/app.apk" classes*.dex)
mkdir -p "$stage/assets/licenses"
cp -R "$vlc/jni/." "$stage/lib/"
cp -R "$vlc/assets/." "$stage/assets/"
cp Shared/Licenses/LibVLC.txt "$stage/assets/licenses/"
cp LICENSE "$stage/assets/licenses/Trame.txt"
python3 scripts/rust-notices.py aarch64-linux-android "$stage/assets/licenses/Rust-crates.txt"
kotlin_licenses=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().parents[1] / "license")' "$compiler")
if [[ -d "$kotlin_licenses" ]]; then
  cp "$kotlin_licenses/LICENSE.txt" "$stage/assets/licenses/Kotlin.txt"
  cp "$kotlin_licenses/COPYRIGHT.txt" "$stage/assets/licenses/Kotlin-COPYRIGHT.txt"
  cp "$kotlin_licenses/NOTICE.txt" "$stage/assets/licenses/Kotlin-NOTICE.txt"
fi
(cd "$stage" && zip -qr app.apk assets && zip -q -0 app.apk lib/*/*.so)
"$tools/zipalign" -P 16 -f 4 "$stage/app.apk" "$stage/aligned.apk"

# Keep the personal sideload identity across builds. Only the signed APK is distributed.
keydir="$PWD/.android-signing"
(
  umask 077
  mkdir -p "$keydir"
  if [[ ! -e "$keydir/trame.p12" ]]; then
    if [[ ! -f "$keydir/password" ]]; then openssl rand -hex 32 > "$keydir/password"; fi
    keytool -genkeypair -noprompt -keystore "$keydir/trame.p12" -storetype PKCS12 \
      -storepass:file "$keydir/password" -alias trame -keyalg RSA -keysize 3072 \
      -validity 10000 -dname "CN=Trame Local"
  fi
)
"$tools/apksigner" sign --ks "$keydir/trame.p12" --ks-pass "file:$keydir/password" \
  --out "$stage/Trame.apk" "$stage/aligned.apk"
"$tools/apksigner" verify --verbose "$stage/Trame.apk"
"$tools/zipalign" -P 16 -c 4 "$stage/Trame.apk"
mv "$stage/Trame.apk" dist/Trame.apk
echo 'dist/Trame.apk'
