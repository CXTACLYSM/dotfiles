#!/bin/zsh
# Подробный обзор дедлайнов — открывается по prefix-t во всплывающем окне tmux.
# Часы тикают (перерисовка раз в секунду), по каждому сроку: дата, полоса
# прогресса от постановки к сроку, «прошло X из Y · осталось Z».
# Цифра — убрать соответствующий дедлайн (файл переписывается атомарно,
# статус-бар обновляется сразу); любая другая клавиша закрывает окно.
# `--once` — один кадр без цикла (для проверки).
#
# Против моргания: кадр собирается в буфер и печатается одним куском поверх
# предыдущего (\e[H + \e[K построчно), экран не очищается; файл читается
# при старте и после удаления; время — zsh/datetime, форков в цикле нет.

zmodload zsh/datetime
export LC_ALL=ru_RU.UTF-8

f=$HOME/.deadline
W=56   # ширина полосы прогресса

rst=$'\e[0m'; bold=$'\e[1m'
dim=$'\e[38;5;242m'; grey=$'\e[38;5;250m'
yel=$'\e[38;5;221m'; red=$'\e[38;5;196m'
restc=$'\e[38;5;238m'
K=$'\e[K'   # дочистить хвост строки от прошлого кадра

# Остаток в человеческом виде — в $REPLY, без сабшеллов в цикле отрисовки.
fmt() {
  local left=$1 d h m
  d=$(( left / 86400 )); h=$(( left % 86400 / 3600 )); m=$(( left % 3600 / 60 ))
  if   (( d > 0 )); then REPLY="${d}д ${h}ч"
  elif (( h > 0 )); then REPLY="${h}ч ${m}м"
  else                   REPLY="${m}м"
  fi
}

typeset -a entries   # "epoch|сырая строка файла", по возрастанию срока

parse() {
  entries=()
  local line w t now=$EPOCHSECONDS
  [[ -r $f ]] || return 0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    w=${line%%|*}
    strftime -r -s t '%Y-%m-%d %H:%M' "$w" 2>/dev/null || continue
    (( now - t < 300 )) && entries+=("$t|$line")   # истёкшие ≥5м не показываем
  done < "$f"
  entries=(${(on)entries})
}

# Убрать i-й показанный дедлайн: вычесть его строку из файла, перечитать.
del() {
  local raw=${entries[$1]#*|} line removed=0
  local -a kept
  [[ -n $raw && -r $f ]] || return 0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if (( ! removed )) && [[ $line == "$raw" ]]; then removed=1; continue; fi
    kept+=("$line")
  done < "$f"
  if (( ${#kept} )); then
    print -rl -- $kept > "$f.tmp" && mv "$f.tmp" "$f"
  else
    rm -f "$f" "$f.tmp"
  fi
  command tmux refresh-client -S 2>/dev/null
  parse
}

draw() {
  local now=$EPOCHSECONDS buf=$'\e[H' clock today
  local e i raw w rest l s t when left col total el pct fill left_s el_s total_s

  strftime -s clock '%H:%M:%S' $now
  strftime -s today '%A, %e %B' $now
  buf+="$K"$'\n'"  ${bold}${clock}${rst}  ${dim}${today}${rst}$K"$'\n'"$K"$'\n'

  (( ${#entries} )) || buf+="  ${dim}дедлайнов нет${rst}$K"$'\n'"$K"$'\n'

  for (( i = 1; i <= ${#entries}; i++ )); do
    e=${entries[i]}; t=${e%%|*}; raw=${e#*|}
    rest=${raw#*|}
    if [[ $rest == *'|'* ]]; then l=${rest%%|*}; s=${rest#*|}; else l=$rest; s=; fi
    strftime -s when '%a %d.%m %H:%M' $t
    left=$(( t - now ))
    buf+="  ${dim}${i} ·${rst} ${bold}${l}${rst}  ${dim}${when}${rst}$K"$'\n'
    if (( left <= 0 )); then
      fmt $(( -left ))
      buf+="  ${red}${(pl:$W::█:)}${rst}$K"$'\n'
      buf+="  ${red}время вышло $REPLY назад${rst}$K"$'\n'
    else
      col=$grey
      (( left < 10800 )) && col=$yel
      (( left < 1800 ))  && col=$red
      fmt $left; left_s=$REPLY
      fill=0
      if [[ $s == <-> ]] && (( s < t )); then
        total=$(( t - s )); el=$(( now - s )); (( el < 0 )) && el=0
        fill=$(( W * el / total )); (( fill > W )) && fill=$W
        pct=$(( 100 * el / total ))
        fmt $el; el_s=$REPLY
        fmt $total; total_s=$REPLY
        buf+="  ${col}${(pl:$fill::█:)}${restc}${(pl:$(( W - fill ))::░:)}${rst}$K"$'\n'
        buf+="  ${dim}прошло $el_s из $total_s (${pct}%) ·${rst} ${col}осталось $left_s${rst}$K"$'\n'
      else
        buf+="  ${restc}${(pl:$W::░:)}${rst}$K"$'\n'
        buf+="  ${col}осталось $left_s${rst}$K"$'\n'
      fi
    fi
    buf+="$K"$'\n'
  done

  buf+="  ${dim}цифра — убрать дедлайн · любая другая клавиша — закрыть${rst}$K"$'\n'
  buf+=$'\e[J'   # дочистить низ, если строк стало меньше
  print -rn -- $buf
}

parse

if [[ $1 == --once ]]; then
  draw
  exit 0
fi

trap 'print -n "\e[?25h"' EXIT
print -n $'\e[?25l'
while true; do
  draw
  if read -s -t 1 -k 1 key; then
    if [[ $key == [1-9] ]] && (( key <= ${#entries} )); then
      del $key
    else
      break
    fi
  fi
done
