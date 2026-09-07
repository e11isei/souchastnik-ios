#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

echo "== Подготовка iOS-зависимостей =="
bash scripts/bootstrap.sh

echo "== Сборка для iOS Simulator =="
xcodebuild \
  -project Souchastnik.xcodeproj \
  -scheme Souchastnik \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "== Открытие проекта =="
open Souchastnik.xcodeproj
echo "Готово. Для данных импортируйте Data/StarterPack на вкладке «Словари»."
