#!/usr/bin/env bash
# Рендерит .drawio в картинку через CLI приложения drawio desktop.
#
#   ./drawio2png.sh                     все *.drawio в текущем каталоге
#   ./drawio2png.sh a.drawio b.drawio   указанные файлы
#   ./drawio2png.sh path/to/dir         все *.drawio в указанном каталоге
#   SCALE=3 ./drawio2png.sh             масштаб (по умолчанию 2)
#   FORMAT=svg ./drawio2png.sh          формат: png | svg | pdf | jpg (по умолчанию png)
#
# Результат кладётся рядом с исходником под тем же именем, существующий перезаписывается.
# Нужен drawio в PATH:  brew install --cask drawio

set -euo pipefail

SCALE="${SCALE:-2}"
FORMAT="${FORMAT:-png}"

case "${1:-}" in
  -h|--help)
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if ! command -v drawio >/dev/null 2>&1; then
  echo "drawio не найден в PATH." >&2
  echo "Установить: brew install --cask drawio" >&2
  exit 127
fi

collect_dir() {
  local d="$1"
  shopt -s nullglob
  local found=("$d"/*.drawio)
  shopt -u nullglob
  printf '%s\n' "${found[@]}"
}

files=()
if [ "$#" -eq 0 ]; then
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(collect_dir ".")
else
  for arg in "$@"; do
    if [ -d "$arg" ]; then
      while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(collect_dir "$arg")
    else
      files+=("$arg")
    fi
  done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "Нечего рендерить: файлов .drawio не найдено" >&2
  exit 1
fi

fail=0
for src in "${files[@]}"; do
  if [ ! -f "$src" ]; then
    echo "  ПРОПУСК  $src — файла нет" >&2
    fail=1
    continue
  fi
  out="${src%.drawio}.${FORMAT}"
  # --no-sandbox нужен Electron при запуске без интерактивного окна
  if drawio -x -f "$FORMAT" -s "$SCALE" --no-sandbox -o "$out" "$src" >/dev/null 2>&1 && [ -s "$out" ]; then
    size=$(du -h "$out" | cut -f1 | tr -d ' ')
    dims=$(file -b "$out" | grep -oE '[0-9]+ x [0-9]+' | head -1 || true)
    echo "  ok  $out  ${dims:+$dims  }${size}"
  else
    echo "  ОШИБКА  $src — экспорт не удался" >&2
    fail=1
  fi
done

exit "$fail"
