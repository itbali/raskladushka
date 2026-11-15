#!/bin/bash
# Сборка для скачивания с GitHub: подпись Developer ID, нотаризация Apple, образ .dmg, запись для автообновления.
#   Tools/release-github.sh           — build/github/Raskladushka-<версия>.dmg и appcast.xml в корне проекта
#   Tools/release-github.sh --draft   — то же и черновик релиза v<версия> на GitHub (нужен gh)
# Собирается цель RaskladushkaDirect: то же приложение плюс автообновление Sparkle.
# После публикации релиза appcast.xml нужно закоммитить и запушить — по нему приложения узнают о новой версии.
# Настройки те же, что у Tools/release.sh: Tools/appstore/config.env. Ключ App Store Connect нужен
# обязательно: им сборка отправляется на нотаризацию. Сертификат «Developer ID Application» должен
# лежать в связке ключей.
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
DERIVED=build/direct
SPARKLE=$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin
APP=$OUT/export/Raskladushka.app
DMG=$OUT/Raskladushka-$VERSION.dmg

xcodegen generate
(cd Packages/SwitcherCore && swift test)

rm -rf "$ARCHIVE" "$OUT"
mkdir -p "$OUT"
python3 Tools/check_localization.py
xcodebuild -project Raskladushka.xcodeproj -scheme RaskladushkaDirect -configuration Release \
  -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" -allowProvisioningUpdates "${AUTH[@]}" archive
# Только системный PATH: rsync из Homebrew ломает экспорт.
PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" -exportOptionsPlist AppStore/ExportOptions-developer-id.plist \
  -allowProvisioningUpdates "${AUTH[@]}"

notarize() {
  xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
}

# Нотаризация приложения: Apple проверяет сборку, квитанция прикрепляется к приложению.
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip"
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP"
spctl -a -vv "$APP"

# Образ: приложение и ярлык папки «Программы», чтобы перетащить одно в другое. С dmgbuild у окна образа
# будет фон со стрелкой (раскладка пишется прямо в образ, Finder не открывается); без него — простое окно.
# Образ тоже подписывается и нотаризуется — иначе macOS предупреждает уже при его открытии.
# pip ставит dmgbuild в папку пользователя, которой обычно нет в PATH, — зовём его как модуль Python.
if /usr/bin/python3 -c "import dmgbuild" 2>/dev/null; then
  /usr/bin/python3 Tools/build_dmg.py "$APP" "$DMG"
else
  echo "dmgbuild не найден (pip3 install dmgbuild) — образ будет без фона"
  mkdir "$OUT/dmg"
  cp -R "$APP" "$OUT/dmg/"
  ln -s /Applications "$OUT/dmg/Applications"
  hdiutil create -volname "Раскладушка" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG"
  rm -rf "$OUT/dmg"
fi
codesign --sign "Developer ID Application" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

# Запись для автообновления: подпись образа ключом Sparkle (лежит в связке ключей, запись raskladushka).
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
SIGNATURE=$("$SPARKLE/sign_update" --account raskladushka "$DMG")
cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Раскладушка</title>
    <link>https://github.com/itbali/raskladushka</link>
    <item>
      <title>Раскладушка $VERSION</title>
      <link>https://github.com/itbali/raskladushka/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/itbali/raskladushka/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <enclosure url="https://github.com/itbali/raskladushka/releases/download/v$VERSION/Raskladushka-$VERSION.dmg"
                 $SIGNATURE type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

echo "Готово: $DMG"
shasum -a 256 "$DMG"
echo "appcast.xml обновлён — закоммитьте и запушьте его после публикации релиза."

if [[ "${1:-}" == "--draft" ]]; then
  gh release create "v$VERSION" "$DMG" --draft --title "Раскладушка $VERSION" \
    --notes-file "AppStore/release-notes/$VERSION.md"
fi
