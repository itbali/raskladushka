#!/bin/bash
# Сборка для скачивания с GitHub: подпись Developer ID, нотаризация Apple, zip.
#   Tools/release-github.sh           — build/github/Raskladushka-<версия>.zip
#   Tools/release-github.sh --draft   — то же и черновик релиза v<версия> на GitHub (нужен gh)
# Настройки те же, что у Tools/release.sh: Tools/appstore/config.env. Ключ App Store Connect нужен
# обязательно — им Xcode получает сертификат Developer ID, им же сборка отправляется на нотаризацию.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f Tools/appstore/config.env ]]; then
  set -a; source Tools/appstore/config.env; set +a
fi
: "${DEVELOPMENT_TEAM:?Задайте DEVELOPMENT_TEAM в Tools/appstore/config.env}"
: "${ASC_KEY_ID:?Задайте ASC_KEY_ID в Tools/appstore/config.env}"
: "${ASC_ISSUER_ID:?Задайте ASC_ISSUER_ID в Tools/appstore/config.env}"
ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")

VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
OUT=build/github
ARCHIVE=build/Raskladushka-github.xcarchive
APP=$OUT/export/Raskladushka.app
ZIP=$OUT/Raskladushka-$VERSION.zip

xcodegen generate
(cd Packages/SwitcherCore && swift test)

rm -rf "$ARCHIVE" "$OUT"
mkdir -p "$OUT"
xcodebuild -project Raskladushka.xcodeproj -scheme Raskladushka -configuration Release \
  -derivedDataPath build -archivePath "$ARCHIVE" -allowProvisioningUpdates "${AUTH[@]}" archive
# Только системный PATH: rsync из Homebrew ломает экспорт.
PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" -exportOptionsPlist AppStore/ExportOptions-developer-id.plist \
  -allowProvisioningUpdates "${AUTH[@]}"

# Нотаризация: Apple проверяет сборку, квитанция прикрепляется к приложению.
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" --wait
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP"
spctl -a -vv "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
echo "Готово: $ZIP"
shasum -a 256 "$ZIP"

if [[ "${1:-}" == "--draft" ]]; then
  gh release create "v$VERSION" "$ZIP" --draft --title "Раскладушка $VERSION" \
    --notes-file "AppStore/release-notes/$VERSION.md"
fi
