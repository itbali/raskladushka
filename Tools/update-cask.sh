#!/bin/bash
# Описание пакета для Homebrew (репозиторий itbali/homebrew-tap).
#   Tools/update-cask.sh <образ.dmg>          — печатает Casks/raskladushka.rb для текущей версии
#   Tools/update-cask.sh <образ.dmg> <папка>  — записывает его в <папка>/Casks/raskladushka.rb
# Запускать после публикации релиза: адрес образа в пакете ведёт на опубликованный файл.
# Установка у пользователя: brew install --cask itbali/tap/raskladushka
set -euo pipefail
cd "$(dirname "$0")/.."
DMG=${1:?Укажите путь к образу .dmg}
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

CASK=$(cat <<RUBY
cask "raskladushka" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/itbali/raskladushka/releases/download/v#{version}/Raskladushka-#{version}.dmg"
  name "Raskladushka"
  name "Раскладушка"
  desc "Fixes text typed in the wrong keyboard layout and switches the layout"
  homepage "https://github.com/itbali/raskladushka"

  auto_updates true
  depends_on macos: ">= :ventura"

  app "Raskladushka.app"

  zap trash: [
    "~/Library/Containers/com.alexey.duzhev.raskladushka",
  ]
end
RUBY
)

if [[ -n "${2:-}" ]]; then
  mkdir -p "$2/Casks"
  printf '%s\n' "$CASK" > "$2/Casks/raskladushka.rb"
  echo "Записано: $2/Casks/raskladushka.rb"
else
  printf '%s\n' "$CASK"
fi
