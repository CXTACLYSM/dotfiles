#!/bin/zsh
# Плашки дедлайнов для tmux status-right.
# ~/.deadline: по строке на дедлайн — "YYYY-MM-DD HH:MM|Подпись|epoch-постановки"
# (третье поле пишет команда deadline из zshrc; без него плашка без прогресса).
# Показываются до трёх сроков, от ближайшего к дальнему. Ближайший — плашка,
# фон которой работает полосой прогресса: светлая часть растёт слева направо
# по мере того, как идёт время от постановки к сроку; <3ч текст желтеет,
# <30м плашка сплошь красная. После срока 5 минут висит «время вышло», затем
# скрипт сам вычищает строку из файла (атомарной перезаписью). Дедлайны,
# истёкшие вне tmux, объявляет и чистит стартовая проверка в zshrc.
# Остальные сроки — приглушённым текстом без плашки.

zmodload zsh/datetime
export LC_ALL=en_US.UTF-8   # посимвольные срезы кириллицы для полосы

f=$HOME/.deadline
[[ -r $f ]] || exit 0
now=$EPOCHSECONDS

# Остаток в человеческом виде: 6д 14ч / 14ч 8м / 42м.
fmt() {
  local left=$1 d h m
  d=$(( left / 86400 )); h=$(( left % 86400 / 3600 )); m=$(( left % 3600 / 60 ))
  if   (( d > 0 )); then print -rn -- "${d}д ${h}ч"
  elif (( h > 0 )); then print -rn -- "${h}ч ${m}м"
  else                   print -rn -- "${m}м"
  fi
}

future=()                # "epoch|подпись|epoch-постановки", будущие
passed_t= passed_label=  # последний прошедший (< 5 минут назад)
keep=() dirty=0
while IFS= read -r line; do
  [[ -n $line ]] || continue
  w=${line%%|*}; rest=${line#*|}
  if [[ $rest == *'|'* ]]; then l=${rest%%|*}; s=${rest#*|}; else l=$rest; s=; fi
  if ! strftime -r -s t '%Y-%m-%d %H:%M' "$w" 2>/dev/null; then
    keep+=("$line"); continue
  fi
  if (( t > now )); then
    future+=("$t|$l|$s"); keep+=("$line")
  elif (( now - t < 300 )); then
    if [[ -z $passed_t ]] || (( t > passed_t )); then
      passed_t=$t passed_label=$l
    fi
    keep+=("$line")
  else
    dirty=1   # истёк больше 5 минут назад — убираем из файла
  fi
done < "$f"

if (( dirty )); then
  if (( ${#keep} )); then
    print -rl -- $keep > "$f.tmp" && mv "$f.tmp" "$f"
  else
    rm -f "$f" "$f.tmp"
  fi
fi

chips=()
[[ -n $passed_t ]] &&
  chips+=("#[fg=colour231,bg=red,bold] ${passed_label}: время вышло #[default]")

main_done=$passed_t   # напоминание занимает место главной плашки
for entry in ${(on)future}; do   # epoch'и одной длины: сортировка строк = по времени
  (( ${#chips} >= 3 )) && break
  t=${entry%%|*}; rest=${entry#*|}; l=${rest%%|*}; s=${rest#*|}
  left=$(( t - now ))
  out=$(fmt $left)

  if [[ -n $main_done ]]; then
    chips+=("#[fg=colour242] $l $out #[default]")
    continue
  fi
  main_done=1

  text=" $l $out "
  if (( left < 1800 )); then
    chips+=("#[fg=colour231,bg=red,bold]${text}#[default]")
    continue
  fi
  fg='#[fg=colour250'
  (( left < 10800 )) && fg='#[fg=colour221'
  n=$#text
  fill=0
  if [[ $s == <-> ]] && (( s < t && now > s )); then
    fill=$(( n * (now - s) / (t - s) ))
    (( fill > n )) && fill=$n
  fi
  chips+=("${fg},bg=colour242]${text[1,$fill]}${fg},bg=colour238]${text[$((fill+1)),$n]}#[default]")
done

print -rn -- "${(j: :)chips}"
