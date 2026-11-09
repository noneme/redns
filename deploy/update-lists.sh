#!/usr/bin/env bash
# Обновление списков, закреплённых по commit-SHA (raw.githubusercontent.com).
#
# Для каждого списка в конфиге находит текущий HEAD ветки (файл ищется в
# default-ветке, master, main, gh-pages, production), показывает, что именно
# поменяется (SHA, дата и сообщение коммита), проверяет, что файл существует
# в новом коммите, и только после твоего подтверждения:
#   1. делает бэкап конфига,
#   2. подставляет новые SHA,
#   3. проверяет новый конфиг командой `redns check` (скачивает списки),
#   4. выполняет `systemctl reload redns`.
#
# Не закреплённые списки (ссылки на ветку, например .../main/...) скрипт
# предложит зафиксировать за текущим HEAD.
#
# Использование:
#   sudo update-redns-lists [-c /etc/redns/config.yaml] [--dry-run] [--yes]
# --yes пропускает вопрос подтверждения (для админки).

set -euo pipefail

CONFIG="/etc/redns/config.yaml"
DRY_RUN=0
YES=0

usage() {
  cat <<EOF
Использование: $0 [-c конфиг] [--dry-run] [--yes]
  -c PATH       файл конфига (по умолчанию /etc/redns/config.yaml)
  --dry-run     только показать, что изменится, ничего не менять
  --yes         не спрашивать подтверждение (для админки)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONFIG="${2:---c требует путь}"; shift 2 ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

die() { echo -e "\033[31mОшибка:\033[0m $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "нужен curl"
[[ -f $CONFIG ]] || die "нет конфига $CONFIG"
[[ -r $CONFIG ]] || die "не читается $CONFIG (запусти с sudo)"
[[ $DRY_RUN -eq 1 || -w $CONFIG ]] || die "не записываем в $CONFIG (запусти с sudo)"

json_get() { # $1=json $2=поле — первое вхождение строкового значения
  printf '%s' "$1" | sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" | head -1
}

api() { # $1=путь API; $2=quiet — не печатать ошибку; возвращает ненулевой код
  local out
  if ! out="$(curl -fsS --max-time 20 "https://api.github.com$1" 2>&1)"; then
    [[ ${2:-} != quiet ]] && echo "  (GitHub API: ${out:0:160})" >&2
    return 1
  fi
  printf '%s' "$out"
}

URLS=()
while IFS= read -r line; do
  [[ -n $line ]] && URLS+=("$line")
done < <(grep -oE 'https://raw\.githubusercontent\.com/[A-Za-z0-9._/-]+' "$CONFIG" | sort -u || true)
[[ ${#URLS[@]} -gt 0 ]] || die "в $CONFIG нет списков raw.githubusercontent.com — обновлять нечего"

# Кэш «owner/repo<TAB>sha<TAB>branch» — обычный строковый список, bash 3.2-совместимо.
REPO_CACHE=""

get_head() { # $1=owner $2=repo $3=path; результат в HEAD_SHA/HEAD_BRANCH
  local o="$1" r="$2" p="$3" key="$1/$2"
  local ek es eb
  while IFS=$'\t' read -r ek es eb; do
    if [[ $ek == "$key" ]]; then
      HEAD_SHA="$es"
      HEAD_BRANCH="$eb"
      return 0
    fi
  done <<< "$REPO_CACHE"
  local meta default branch="" ref
  meta="$(api "/repos/$o/$r")" || return 1
  default="$(json_get "$meta" default_branch)"
  for ref in "$default" master main gh-pages production; do
    [[ -z $ref ]] && continue
    if api "/repos/$o/$r/contents/$p?ref=$ref" quiet >/dev/null; then
      branch="$ref"
      break
    fi
  done
  if [[ -z $branch ]]; then
    echo "  $key: файл $p не найден ни в одной известной ветке (default: $default)" >&2
    return 1
  fi
  local cj
  cj="$(api "/repos/$o/$r/commits/$branch")" || return 1
  HEAD_SHA="$(json_get "$cj" sha)"
  [[ -n $HEAD_SHA ]] || return 1
  HEAD_DATE="$(json_get "$cj" date)"
  HEAD_MSG="$(json_get "$cj" message)"
  HEAD_BRANCH="$branch"
  REPO_CACHE+="${key}"$'\t'"${HEAD_SHA}"$'\t'"${branch}"$'\n'
}

updates=()
uptodate=0
skipped=0

for url in "${URLS[@]}"; do
  rest="${url#https://raw.githubusercontent.com/}"
  owner="${rest%%/*}"; rest="${rest#*/}"
  repo="${rest%%/*}";  rest="${rest#*/}"
  ref="${rest%%/*}"
  path="${rest#*/}"
  if [[ $path == "$rest" ]]; then
    echo "  $url: непонятный URL (нет пути к файлу), пропускаю"
    skipped=$((skipped+1))
    continue
  fi

  if ! get_head "$owner" "$repo" "$path"; then
    skipped=$((skipped+1))
    continue
  fi
  if [[ $ref == "$HEAD_SHA" ]]; then
    echo "  $owner/$repo ($HEAD_BRANCH): уже на ${ref:0:12}"
    uptodate=$((uptodate+1))
    continue
  fi
  new_url="${url/$ref/$HEAD_SHA}"
  code="$(curl -fsSI --max-time 15 "$new_url" -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)"
  if [[ $code != 200 ]]; then
    echo "  $owner/$repo: файл $path в ${HEAD_SHA:0:12} отвечает HTTP $code — пропускаю, поправь путь руками"
    skipped=$((skipped+1))
    continue
  fi
  if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    old_disp="${ref:0:12}"
  else
    old_disp="$ref (ветка)"
  fi
  updates+=("$url"$'\t'"$new_url"$'\t'"$owner/$repo ($HEAD_BRANCH)"$'\t'"$old_disp"$'\t'"${HEAD_SHA:0:12}"$'\t'"$HEAD_DATE"$'\t'"$HEAD_MSG")
done

if [[ ${#updates[@]} -eq 0 ]]; then
  echo "Обновлять нечего: актуальных $uptodate, пропущено $skipped."
  exit 0
fi

echo
echo "Будут обновлены:"
for u in "${updates[@]}"; do
  IFS=$'\t' read -r old new repo oldref newref date msg <<< "$u"
  echo
  echo "  $repo"
  echo "    $oldref → $newref  ($date)"
  echo "    коммит: $msg"
  echo "    $old"
done
echo

if [[ $DRY_RUN -eq 1 ]]; then
  echo "--dry-run: конфиг не трогал."
  exit 0
fi

if [[ $YES -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    echo "Нужно подтверждение: запусти в терминале или передай --yes" >&2
    exit 2
  fi
  read -r -p "Обновить $CONFIG и выполнить systemctl reload redns? [y/N] " ans
  [[ $ans =~ ^[Yy]([Ee][Ss][Hh])?$ ]] || { echo "Отменено."; exit 1; }
fi

backup="$CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$CONFIG" "$backup"
tmp="$(mktemp "${CONFIG}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

exprs=()
for u in "${updates[@]}"; do
  IFS=$'\t' read -r old new _ _ _ _ _ <<< "$u"
  exprs+=(-e "s|$old|$new|")
done
sed "${exprs[@]}" "$CONFIG" > "$tmp"

if command -v redns >/dev/null 2>&1; then
  echo
  echo "Проверяю новый конфиг (redns check — скачает списки)…"
  if ! redns check -c "$tmp" | tail -5; then
    echo "Новый конфиг не прошёл проверку, $CONFIG не тронут. Бэкап: $backup" >&2
    exit 1
  fi
fi

chmod --reference="$CONFIG" "$tmp" 2>/dev/null || chmod 0640 "$tmp"
chown --reference="$CONFIG" "$tmp" 2>/dev/null || true
mv -f "$tmp" "$CONFIG"
trap - EXIT
echo "Конфиг обновлён. Бэкап: $backup"

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet redns 2>/dev/null; then
  if systemctl reload redns; then
    echo "redns обработал SIGHUP — списки обновлены."
  else
    echo "systemctl reload redns не удался — посмотри journalctl -u redns" >&2
    exit 1
  fi
else
  echo "Сервис redns не работает — не забудь: sudo systemctl reload redns"
fi
