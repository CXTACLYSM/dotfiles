#!/bin/zsh
# Сегмент git в status-right tmux: ветка каталога активной панели со
# знаками как в промпте zsh (`*` незакоммиченное, `+` в индексе), `↑n ↓n`
# относительно upstream (только когда не ноль), в linked worktree ветка
# пишется как `@ветка` — по аналогии с именами сессий `проект@ветка` у
# `dev -b`. Вне git сегмент пустой; detached HEAD — короткий sha.
#
#   git-status.sh КАТАЛОГ          строка со стилями tmux (#[fg=…])
#   git-status.sh --plain КАТАЛОГ  без стилей (для проверок)
#
# tmux зовёт скрипт каждые status-interval (2 с); ответ по каталогу
# кэшируется на GIT_STATUS_TTL секунд (5) в $TMPDIR, чтобы git не дёргался
# постоянно. Изменения проверяются `git diff --quiet`: без обхода
# неотслеживаемых файлов это быстро и в больших репозиториях.

emulate -L zsh
setopt extended_glob
zmodload zsh/stat zsh/datetime 2>/dev/null

plain=0
[[ ${1-} == --plain ]] && { plain=1; shift }
dir=${1:-$PWD}
[[ -d $dir ]] || exit 0

ttl=${GIT_STATUS_TTL:-5}
cache_dir=${TMPDIR:-/tmp}/dev-git-status-$UID
key=${dir//[^A-Za-z0-9_.-]/_}
(( ${#key} > 200 )) && key=${key[-200,-1]}
cache=$cache_dir/$key.$plain

if (( ttl > 0 )) && [[ -f $cache ]]; then
  zstat -A mtime +mtime $cache 2>/dev/null
  if (( EPOCHSECONDS - mtime[1] < ttl )); then
    cat $cache
    exit 0
  fi
fi

out=
if [[ $(git -C $dir rev-parse --is-inside-work-tree 2>/dev/null) == true ]]; then
  branch=$(git -C $dir symbolic-ref --short -q HEAD 2>/dev/null) ||
    branch=$(git -C $dir rev-parse --short HEAD 2>/dev/null)
  unstaged= staged= worktree=0 ahead=0 behind=0
  git -C $dir diff --quiet --ignore-submodules -- 2>/dev/null; (( $? == 1 )) && unstaged='*'
  git -C $dir diff --cached --quiet --ignore-submodules -- 2>/dev/null; (( $? == 1 )) && staged='+'
  gitdir=$(git -C $dir rev-parse --path-format=absolute --git-dir 2>/dev/null)
  common=$(git -C $dir rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [[ -n $gitdir && $gitdir != $common ]] && worktree=1
  counts=$(git -C $dir rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
  if [[ $counts == <->[[:space:]]##<-> ]]; then
    behind=${counts%%[[:space:]]*} ahead=${counts##*[[:space:]]}
  fi

  if (( plain )); then
    (( worktree )) && out='@'
    out+=$branch$unstaged$staged
    (( ahead > 0 )) && out+=" ↑$ahead"
    (( behind > 0 )) && out+=" ↓$behind"
  else
    # catppuccin mocha: subtext0, lavender, red, green, sky.
    if (( worktree )); then out='#[fg=#b4befe]@'; else out='#[fg=#a6adc8]'; fi
    out+=$branch
    [[ -n $unstaged ]] && out+="#[fg=#f38ba8]*"
    [[ -n $staged ]] && out+="#[fg=#a6e3a1]+"
    (( ahead > 0 )) && out+=" #[fg=#89dceb]↑$ahead"
    (( behind > 0 )) && out+=" #[fg=#89dceb]↓$behind"
    out+='#[default] '
  fi
fi

if (( ttl > 0 )); then
  mkdir -p $cache_dir 2>/dev/null &&
    print -rn -- $out > $cache.$$ 2>/dev/null && mv -f $cache.$$ $cache 2>/dev/null
fi
print -rn -- $out
