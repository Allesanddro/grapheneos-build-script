#!/usr/bin/env bash

# === ARGUMENTS & DEFAULTS ===
CHANNEL_DEFAULT="stable"

if [ $# -ge 2 ]; then
  TAG_INPUT="$1"
  RELEASE_CHANNEL="$2"
elif [ $# -eq 1 ]; then
  RELEASE_CHANNEL="$1"
  echo "[*] No tag provided, fetching latest GrapheneOS release tag..."
  TAG_INPUT=$(curl -s https://grapheneos.org/releases | grep -oE '[0-9]{10}' | head -n1)
  [ -z "$TAG_INPUT" ] && { echo "ERROR: Could not fetch latest tag."; exit 1; }
else
  RELEASE_CHANNEL="$CHANNEL_DEFAULT"
  echo "[*] No arguments given, defaulting to channel '$RELEASE_CHANNEL' and fetching latest GrapheneOS release tag..."
  TAG_INPUT=$(curl -s https://grapheneos.org/releases | grep -oE '[0-9]{10}' | head -n1)
  [ -z "$TAG_INPUT" ] && { echo "ERROR: Could not fetch latest tag."; exit 1; }
fi

echo "[*] Using tag: $TAG_INPUT"
echo "[*] Using channel: $RELEASE_CHANNEL"

# === CONFIG ===
WORKDIR="$HOME/grapheneos-build"
TAG_NAME="refs/tags/${TAG_INPUT}"
BUILD_NUMBER="$TAG_INPUT"
DEVICE="husky"
UPDATE_URL="https://update.fuckdmca.cc"
CN="WamboEDV"

KEYDIR="$HOME/keys/$DEVICE"
mkdir -p "$KEYDIR"

# Upload config
UPLOAD_USER="root"
UPLOAD_HOST="192.168.178.128"
UPLOAD_PATH="/var/www/grapheneos-releases"
SSH_KEY="$HOME/.ssh/build_rsync"


# === CLEAN OPTION ===
CLEAN_MODE="none"   # default

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --clean=*)
      CLEAN_MODE="${1#*=}"
      ;;
  esac
  shift
done

echo "[*] Clean mode: $CLEAN_MODE"

case "$CLEAN_MODE" in
  none)
    echo "[*] Skipping clean step"
    ;;
  partial)
    echo "[*] Doing partial clean (device/product only, keep full repo sync)..."
    #rm -rf "$WORKDIR/out/soong/.intermediates"
    #rm -rf "$WORKDIR/out/soong/.bootstrap"
    #rm -rf "$WORKDIR/out/target/product/${DEVICE}/obj"
    #rm -rf "$WORKDIR/out/target/product/${DEVICE}/system"
    #rm -rf "$WORKDIR/out/target/product/${DEVICE}/vendor"
    #rm -rf "$WORKDIR/out/target/product/${DEVICE}/recovery"
    #rm -rf "$WORKDIR/out/target/product/${DEVICE}/cache"

    # Remove build number + date cache
    rm -f "$WORKDIR/out/soong/build_number.txt"
    rm -f "$WORKDIR/out/build_date.txt"


    # Remove intermediate packaging dirs
    #rm -rf "$WORKDIR/out/target/product/${DEVICE}/obj/PACKAGING/target_files_intermediates/IMAGES"
    ;;

  full)
    echo "[*] Doing full clean (entire out/)..."
    rm -rf "$WORKDIR/out/"
    ;;
  *)
    echo "ERROR: Unknown clean mode '$CLEAN_MODE' (use none|partial|full)"
    exit 1
    ;;
esac






# === HELPERS ===
die(){ echo "ERROR: $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

# === PRECHECKS ===
[ -z "$TAG_NAME" ] && die "Set TAG_NAME to a GrapheneOS stable tag."

# === 1. Install base packages (if missing) ===
BASE_PKGS=(
  git-core gnupg flex bison build-essential zip curl zlib1g-dev
  libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev
  libxml2-utils xsltproc unzip fontconfig rsync e2fsprogs openssh-client
  python3 python3-pip openjdk-17-jdk wget
)
echo "[*] Ensuring base packages installed..."
sudo apt update
for pkg in "${BASE_PKGS[@]}"; do
  dpkg -s "$pkg" >/dev/null 2>&1 || sudo apt install -y "$pkg"
done

# === 2. Node.js 22 ===
if have node; then
  NODE_VER=$(node -v | sed 's/^v//; s/\..*//')
  if [ "$NODE_VER" -ne 22 ]; then
    echo "[*] Node version is not 22.x, installing Node 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
  fi
else
  echo "[*] Installing Node.js 22..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

# === 3. Yarn ===
have yarn || sudo npm install -g yarn

# === 4. repo tool ===
mkdir -p ~/bin
if [ ! -f ~/bin/repo ]; then
  echo "[*] Installing repo tool..."
  curl -o ~/bin/repo https://storage.googleapis.com/git-repo-downloads/repo
  chmod a+x ~/bin/repo
fi
grep -qxF 'export PATH=$HOME/bin:$PATH' ~/.bashrc || echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
export PATH="$HOME/bin:$PATH"

# === 5. Init / update repo ===
mkdir -p "$WORKDIR"
cd "$WORKDIR"

#rm out/ -rf

echo "[*] Resetting repository to a clean state (excluding vendor/adevtool/dl)..."
repo forall -c "git reset --hard"
repo forall -c "git clean -fdx -e dl/"


echo "[*] Initializing and syncing repository for tag $TAG_NAME..."
repo init -u https://github.com/GrapheneOS/platform_manifest.git -b "$TAG_NAME"
repo sync -c -j"$(nproc)" --force-sync



# === 6. adevtool prep ===
yarn install --cwd vendor/adevtool/
source build/envsetup.sh
lunch sdk_phone64_x86_64-cur-user
m arsclib

# === 7. vendor extraction ===
source build/envsetup.sh
"$WORKDIR/vendor/adevtool/bin/run" generate-all -d "$DEVICE"

# === 8. Updater URL patch ===
export OFFICIAL_BUILD=true
sed -i "s#https://seamlessupdate.app#${UPDATE_URL}#g; s#https://releases.grapheneos.org#${UPDATE_URL}#g" \
  packages/apps/Updater/res/values/config.xml || true

# === 9. Keys ===
mkdir -p "$WORKDIR/keys"
if [ ! -d "$KEYDIR" ]; then
  echo "[*] Generating new keys in $KEYDIR ..."
  mkdir -p "$KEYDIR"
  pushd "$KEYDIR"
  "$WORKDIR/development/tools/make_key" releasekey "/CN=${CN}/"
  "$WORKDIR/development/tools/make_key" platform "/CN=${CN}/"
  "$WORKDIR/development/tools/make_key" shared "/CN=${CN}/"
  "$WORKDIR/development/tools/make_key" media "/CN=${CN}/"
  "$WORKDIR/development/tools/make_key" networkstack "/CN=${CN}/"
  "$WORKDIR/development/tools/make_key" sdk_sandbox "/CN=${CN}/"
  "$WORKDIR/development/tools/make_key" bluetooth "/CN=${CN}/"
  openssl genrsa 4096 | openssl pkcs8 -topk8 -scrypt -out avb.pem
  "$WORKDIR/external/avb/avbtool.py" extract_public_key \
    --key avb.pem --output avb_pkmd.bin
  ssh-keygen -t ed25519 -f id_ed25519 -N ''
  popd
  "$WORKDIR/script/encrypt-keys" "$KEYDIR"
else
  echo "[*] Reusing existing keys from $KEYDIR"
fi
rm -rf "$WORKDIR/keys/$DEVICE"
ln -s "$KEYDIR" "$WORKDIR/keys/$DEVICE"

# === 10. Build ===
source build/envsetup.sh
lunch "$DEVICE"-cur-user
m vendorbootimage vendorkernelbootimage target-files-package -j"$(nproc)"
m otatools-package -j"$(nproc)"

# === 11. Finalize release ===
BUILD_NUMBER=$(cat out/soong/build_number.txt)
script/finalize.sh
script/generate-release.sh "$DEVICE" "$BUILD_NUMBER"

# === 11.5. Incremental OTA generation ===
KEY_DIR_TMP=$(mktemp -d /dev/shm/generate-delta.XXXXXXXXXX)
trap "rm -rf \"$KEY_DIR_TMP\"" EXIT
cp "$KEYDIR"/* "$KEY_DIR_TMP"
script/decrypt-keys "$KEY_DIR_TMP"

PREV_BUILD_FILE="$WORKDIR/last_build.txt"
if [ -f "$PREV_BUILD_FILE" ]; then
  PREV_BUILD=$(cat "$PREV_BUILD_FILE")
  PREV_TARGET_FILES="$WORKDIR/releases/${PREV_BUILD}/release-${DEVICE}-${PREV_BUILD}/${DEVICE}-target_files.zip"
  CUR_TARGET_FILES="$WORKDIR/releases/${BUILD_NUMBER}/release-${DEVICE}-${BUILD_NUMBER}/${DEVICE}-target_files.zip"
  
  if [ -f "$PREV_TARGET_FILES" ]; then
    echo "[*] Generating incremental OTA: ${PREV_BUILD} -> ${BUILD_NUMBER}"
    "$WORKDIR/out/host/linux-x86/bin/ota_from_target_files" \
      -k "$KEY_DIR_TMP/releasekey" \
      -i "$PREV_TARGET_FILES" \
      "$CUR_TARGET_FILES" \
      "$WORKDIR/releases/${BUILD_NUMBER}/release-${DEVICE}-${BUILD_NUMBER}/${DEVICE}-incremental-${PREV_BUILD}-${BUILD_NUMBER}.zip"
  fi
fi
echo "$BUILD_NUMBER" > "$PREV_BUILD_FILE"

# === 12. Upload release via rsync over SSH ===
echo "[*] Uploading release for channel: $RELEASE_CHANNEL"
SOURCE_DIR="$WORKDIR/releases/${BUILD_NUMBER}/release-${DEVICE}-${BUILD_NUMBER}"
[ ! -d "$SOURCE_DIR" ] && die "Release source dir missing: $SOURCE_DIR"

echo "[*] Uploading via rsync (SSH, overwrite enabled)..."

rsync -avz --progress --delete --inplace \
  -e "ssh -i $SSH_KEY" \
  --include="${DEVICE}-factory-*.zip" \
  --include="${DEVICE}-install-*.zip" \
  --include="${DEVICE}-install-*.zip.sig" \
  --include="${DEVICE}-ota_update-*.zip" \
  --include="${DEVICE}-incremental-*.zip" \
  --include="${DEVICE}-${RELEASE_CHANNEL}" \
  --exclude='*' \
  "$SOURCE_DIR/" \
  "${UPLOAD_USER}@${UPLOAD_HOST}:${UPLOAD_PATH}/"

echo
echo "=== DONE ==="
echo "Release files uploaded to http://${UPLOAD_HOST}/grapheneos-releases/"
echo "Channel URL: http://${UPLOAD_HOST}/grapheneos-releases/${DEVICE}-${RELEASE_CHANNEL}"
