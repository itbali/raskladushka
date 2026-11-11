#!/bin/bash
# Сборка пакета для App Store.
#   Tools/release.sh            — архив и экспорт подписанного .pkg в build/export
#   Tools/release.sh --upload   — то же и загрузка в App Store Connect
# Настройки (команда разработчика, ключ App Store Connect) — в Tools/appstore/config.env,
# образец: Tools/appstore/config.example.env. Сам ключ .p8 лежит вне репозитория.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f Tools/appstore/config.env ]]; then
  set -a; source Tools/appstore/config.env; set +a
fi
: "${DEVELOPMENT_TEAM:?Задайте DEVELOPMENT_TEAM в Tools/appstore/config.env}"

xcodegen generate
(cd Packages/SwitcherCore && swift test)

AUTH=()
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi

rm -rf build/Raskladushka.xcarchive build/export
xcodebuild -project Raskladushka.xcodeproj -scheme Raskladushka -configuration Release \
  -derivedDataPath build -archivePath build/Raskladushka.xcarchive \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} archive

OPTIONS=AppStore/ExportOptions.plist
if [[ "${1:-}" == "--upload" ]]; then
  OPTIONS=build/ExportOptions-upload.plist
  sed 's#<string>export</string>#<string>upload</string>#' AppStore/ExportOptions.plist > "$OPTIONS"
fi
# Только системный PATH: rsync из Homebrew ломает экспорт.
PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/xcodebuild -exportArchive -archivePath build/Raskladushka.xcarchive -exportPath build/export \
  -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}
echo "Готово: build/export"
