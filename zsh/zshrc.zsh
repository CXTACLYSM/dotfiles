# Интерактивный zsh: окружение для Go, история, дополнение, клавиши, промпт,
# fzf, плагины. Подключается последней строкой ~/.zshrc (её добавляет
# install.sh):
#   source ~/.config/dotfiles/zsh/zshrc.zsh
# Всё машинно-специфичное (прокси, GOPRIVATE/GOPROXY, свои алиасы) остаётся
# в ~/.zshrc выше этой строки и в репозиторий не попадает.

# ============================================================
# Окружение
# ============================================================

# Homebrew: Apple Silicon (/opt/homebrew) или Intel (/usr/local). Обычно
# ~/.zprofile уже сделал shellenv; здесь — если нет.
if [[ -z $HOMEBREW_PREFIX ]]; then
  for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x $_brew ]] && { eval "$($_brew shellenv)"; break }
  done
  unset _brew
fi

export EDITOR=nvim
export VISUAL=nvim

# go install → ~/go/bin (GOPATH по умолчанию; без форка `go env` на старте);
# ~/.local/bin — dev, devlog, projects. GOTOOLCHAIN не задаётся: auto,
# gopls наследует ту же политику.
typeset -U path
path=("$HOME/go/bin" "$HOME/.local/bin" $path)

# ============================================================
# История
# ============================================================

# Дефолт macOS (2000/1000, запись при выходе) теряет команды при работе
# в нескольких tmux-панелях: последний закрытый шелл затирает остальных.
HISTFILE="$HOME/.zsh_history"
HISTSIZE=120000
SAVEHIST=100000

setopt EXTENDED_HISTORY          # метка времени и длительность каждой команды
setopt INC_APPEND_HISTORY_TIME   # писать в файл сразу после команды, а не при выходе
setopt HIST_IGNORE_ALL_DUPS      # повтор команды убирает старый дубль
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_IGNORE_SPACE         # команда с пробелом в начале не попадает в историю
setopt HIST_VERIFY               # !! сначала подставляется в строку, потом Enter

# Намеренно НЕ share_history: у каждой tmux-панели своя «стрелка вверх»,
# файл всё равно общий — fzf Ctrl-R ищет по всему сразу.

# ============================================================
# Поведение
# ============================================================

setopt AUTO_CD               # `..` или имя каталога == cd
setopt AUTO_PUSHD            # каждый cd кладёт каталог в стек: `cd -<Tab>`
setopt PUSHD_IGNORE_DUPS
setopt PUSHD_SILENT
setopt INTERACTIVE_COMMENTS  # '#' работает в командной строке (вставка сниппетов)
setopt NO_FLOW_CONTROL       # Ctrl-S не замораживает терминал
setopt NO_BEEP

export CLICOLOR=1            # цветной ls на macOS

# Ctrl-W и Alt-стрелки останавливаются на / . - _ = — редактирование путей
# и флагов по кускам, а не целиком.
WORDCHARS='*?[]~&;!#$%^(){}<>'

# ============================================================
# Дополнение
# ============================================================

# Дополнения brew-пакетов (fd, rg, gh, ...) — до compinit.
[[ -n $HOMEBREW_PREFIX ]] && fpath=($HOMEBREW_PREFIX/share/zsh/site-functions $fpath)

zmodload zsh/complist
autoload -Uz compinit

# Полная перепроверка дампа — не чаще раза в сутки, иначе быстрый старт (-C).
# -u: если каталог brew принадлежит другому пользователю (Mac на несколько
# учётных записей или brew поставил администратор), compaudit считает
# site-functions «небезопасным» и спрашивает при каждом старте. Бинарники и
# плагины оттуда же и так исполняются, так что доверие ничего не меняет.
() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  local dump=$HOME/.cache/zsh/zcompdump
  mkdir -p ${dump:h}
  if [[ -e $dump && -n $dump(#qN.mh-24) ]]; then
    compinit -C -u -d $dump
  else
    compinit -u -d $dump
  fi
}

zstyle ':completion:*' menu select                             # выбор стрелками
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors ''                          # подсветка типов файлов
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{242}— %d —%f'
zstyle ':completion:*' squeeze-slashes true
zstyle ':completion:*' use-cache true
zstyle ':completion:*' cache-path "$HOME/.cache/zsh/zcompcache"

# ============================================================
# Клавиши
# ============================================================

# Явно emacs-режим: иначе EDITOR=nvim молча включил бы vi-режим zle.
bindkey -e

# Стрелки вверх/вниз: поиск по уже набранному началу строки
# (`git <Up>` листает только git-команды).
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
() {
  local k
  for k in '^[[A' '^[OA' "${terminfo[kcuu1]}"; do
    [[ -n $k ]] && bindkey "$k" up-line-or-beginning-search
  done
  for k in '^[[B' '^[OB' "${terminfo[kcud1]}"; do
    [[ -n $k ]] && bindkey "$k" down-line-or-beginning-search
  done
}

# Alt/Ctrl-стрелки — по словам.
bindkey '^[[1;3C' forward-word
bindkey '^[[1;3D' backward-word
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word

# Ctrl-X Ctrl-E — редактировать текущую командную строку в $EDITOR (nvim).
autoload -Uz edit-command-line
zle -N edit-command-line
bindkey '^X^E' edit-command-line

# Ctrl-Z на пустой строке — вернуться в свёрнутый nvim (fg);
# на непустой — спрятать набранное до следующего промпта (push-input).
ctrl-z-toggle() {
  if [[ -z $BUFFER ]] && (( $#jobstates )); then
    BUFFER='fg'
    zle accept-line
  else
    zle push-input
  fi
}
zle -N ctrl-z-toggle
bindkey '^Z' ctrl-z-toggle

# ============================================================
# Промпт
# ============================================================
#   ~/…/service/internal/store main* 130 ❯
#   путь · git-ветка (* незакоммиченное, + в индексе) · код ошибки (если ≠0);
#   ❯ краснеет после ошибки. Однострочный: контекст сессии уже даёт tmux.

setopt PROMPT_SUBST
autoload -Uz vcs_info add-zsh-hook

zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:git:*' check-for-changes true
zstyle ':vcs_info:git:*' unstagedstr '*'
zstyle ':vcs_info:git:*' stagedstr '+'
zstyle ':vcs_info:git:*' formats ' %F{242}%b%f%F{red}%u%f%F{green}%c%f'
zstyle ':vcs_info:git:*' actionformats ' %F{242}%b%f %F{yellow}%a%f%F{red}%u%f%F{green}%c%f'
add-zsh-hook precmd vcs_info

# Путь: целиком, а с глубины 5 — первый элемент + … + последние три.
PROMPT='%F{cyan}%(5~|%-1~/…/%3~|%~)%f${vcs_info_msg_0_}%(?.. %F{red}%?%f) %(?.%F{magenta}.%F{red})❯%f '

# Справа — длительность команды, если она шла дольше 5 с;
# из scrollback убирается после Enter (TRANSIENT_RPROMPT).
setopt TRANSIENT_RPROMPT
_cmd_t0=
_cmd_timer_start() { _cmd_t0=$SECONDS }
_cmd_timer_show() {
  RPROMPT=''
  [[ -n $_cmd_t0 ]] || return 0
  local d=$(( SECONDS - _cmd_t0 )); _cmd_t0=
  (( d >= 5 )) || return 0
  local out="$(( d % 60 ))s"
  (( d >= 60 ))   && out="$(( d / 60 % 60 ))m $out"
  (( d >= 3600 )) && out="$(( d / 3600 ))h $out"
  RPROMPT="%F{yellow}${out}%f"
}
add-zsh-hook preexec _cmd_timer_start
add-zsh-hook precmd  _cmd_timer_show

# ============================================================
# tmux: статус команды у фонового окна (tmux/tmux.conf)
# ============================================================
#   Пока команда идёт, у окна в статус-баре ●, по завершении — ✓ или ✗,
#   пока не зайдёшь в окно. Окно, на которое смотришь, не помечается.
#   Space gt из nvim шлёт go test в окно tests — результат виден из editor.
#   Команда дольше 10 с звонит bell: tmux подсвечивает окно, iTerm — вкладку.
#   Полноэкранные программы и возврат в nvim (fg) не помечаются: их ● — шум.

if [[ -n $TMUX_PANE ]]; then
  _tmux_quiet=(nvim vim vi less man ssh lazygit htop top fg)
  _tmux_t0=

  _tmux_cmd_start() {
    _tmux_t0=
    local cmd=${${(z)3}[1]}
    (( ${_tmux_quiet[(Ie)${cmd:t}]} )) && return
    _tmux_t0=$SECONDS
    command tmux set -w -t $TMUX_PANE @cmd run 2>/dev/null
  }

  _tmux_cmd_done() {
    local st=$? state=ok
    [[ -n $_tmux_t0 ]] || return 0
    (( st == 0 )) || state=fail
    (( SECONDS - _tmux_t0 >= 10 )) && print -n '\a'
    _tmux_t0=
    # Активное окно — метку снять, фоновое — показать результат.
    command tmux if -F -t $TMUX_PANE '#{window_active}' \
      "set -wu -t $TMUX_PANE @cmd" "set -w -t $TMUX_PANE @cmd $state" 2>/dev/null
  }

  add-zsh-hook preexec _tmux_cmd_start
  add-zsh-hook precmd  _tmux_cmd_done
fi

# ============================================================
# Дедлайны: плашка в статус-баре tmux (tmux/deadline.sh)
# ============================================================
#   deadline                          — список всех с остатком
#   deadline 2030-01-15 10:00 Подпись — добавить
#   deadline clear                    — убрать все

deadline() {
  local f=~/.deadline
  if [[ $1 == clear ]]; then
    rm -f $f
    command tmux refresh-client -S 2>/dev/null
    return
  fi
  if (( $# >= 3 )); then
    local when="$1 $2"
    if ! date -j -f '%Y-%m-%d %H:%M' "$when" +%s >/dev/null 2>&1; then
      print 'формат: deadline YYYY-MM-DD HH:MM подпись' >&2
      return 1
    fi
    shift 2
    print -r -- "$when|$*|$(date +%s)" >> $f
    command tmux refresh-client -S 2>/dev/null
    return
  fi
  (( $# == 0 )) || { print 'формат: deadline [YYYY-MM-DD HH:MM подпись | clear]' >&2; return 1 }
  [[ -r $f ]] || { print 'дедлайнов нет'; return }
  local w l s t left sign now=$(date +%s)
  while IFS='|' read -r w l s; do
    t=$(date -j -f '%Y-%m-%d %H:%M' "$w" +%s 2>/dev/null) || continue
    left=$(( t - now )); sign=
    (( left < 0 )) && { left=$(( -left )); sign='-' }
    printf '%s  %s%dд %dч %dм  %s\n' "$w" "$sign" \
      $(( left / 86400 )) $(( left % 86400 / 3600 )) $(( left % 3600 / 60 )) "$l"
  done < $f
}

# Дедлайны, истёкшие больше 5 минут назад (например, пока tmux не работал),
# объявить при входе и вычистить из файла; свежеистёкшие (<5м) не трогаем —
# их 5 минут держит статус-бар и убирает deadline.sh.
() {
  local f=~/.deadline
  [[ -r $f ]] || return 0
  zmodload zsh/datetime 2>/dev/null || return 0
  local now=$EPOCHSECONDS line w t
  local -a keep gone
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    w=${line%%|*}
    if strftime -r -s t '%Y-%m-%d %H:%M' "$w" 2>/dev/null && (( now - t >= 300 )); then
      gone+=("${${line#*|}%%|*} ($w)")
    else
      keep+=("$line")
    fi
  done < $f
  (( ${#gone} )) || return 0
  print -P -- "%F{221}⏰ время вышло:%f ${(j:, :)gone}"
  if (( ${#keep} )); then
    print -rl -- $keep > $f.tmp && command mv $f.tmp $f
  else
    command rm -f $f $f.tmp
  fi
  command tmux refresh-client -S 2>/dev/null
}

# ============================================================
# fzf: Ctrl-R история, Ctrl-T файлы, Alt-C (или Esc,c) — cd
# ============================================================

if (( $+commands[fzf] )); then
  source <(fzf --zsh)

  # fd быстрее find и уважает .gitignore.
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git --strip-cwd-prefix'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
  export FZF_DEFAULT_OPTS='--height 50% --layout=reverse'
  export FZF_TMUX_OPTS='-p 80%,60%'   # в tmux — всплывающее окно по центру
fi

# ============================================================
# Плагины (brew)
# ============================================================

# Серым — продолжение команды из истории; принять целиком: → или End,
# по одному слову: Alt-F / Alt-→.
[[ -f $HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] &&
  source $HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Подсветка при наборе: опечатка в команде видна красным до Enter.
# Подключается последним — так требует сам плагин.
[[ -f $HOMEBREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] &&
  source $HOMEBREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
