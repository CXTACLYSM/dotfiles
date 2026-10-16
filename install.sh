#!/bin/zsh
# Установка окружения из этого репозитория. Повторный запуск безопасен:
# сделанные шаги пропускаются, а всё, что заменяется, сначала переносится в
# ~/.local/state/dotfiles/backup-<время>/. sudo не используется.
#
#   ./install.sh                установить
#   ./install.sh --dry-run      показать, что будет сделано, ничего не меняя
#   ./install.sh --check        только проверить состояние
#   ./install.sh --no-brew      без brew bundle (пакеты уже стоят)
#   ./install.sh --skip-verify  без прогона nvim/verify.sh (1–2 минуты)
#
# Шаги:
#   brew    пакеты из Brewfile
#   privacy статистика Homebrew и телеметрия Go выключаются
#   anchor  ~/.config/dotfiles → этот репозиторий (через него ссылаются конфиги)
#   zsh     строка `source …/zsh/zshrc.zsh` в конце ~/.zshrc
#   tmux    строка `source-file …/tmux/tmux.conf` в ~/.tmux.conf;
#           dev, devlog, projects → ~/.local/bin
#   git     include.path в ~/.gitconfig; конфиг lazygit
#   iterm   профиль Go Backend (dynamic profile)
#   nvim    ~/.config/nvim → nvim/; плагины и парсеры по lock-файлу;
#           AST-хелпер дерева правок; nvim/verify.sh
# Содержимое ~/.zshrc, ~/.tmux.conf и ~/.gitconfig кроме этих строк не
# трогается: машинно-специфичные настройки остаются там.

emulate -L zsh
setopt PIPE_FAIL

repo=${0:A:h}
anchor=$HOME/.config/dotfiles
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
backup_root=$HOME/.local/state/dotfiles/backup-$(date +%Y%m%d-%H%M%S)

mode=install brew_step=1 verify_step=1
for arg in "$@"; do
  case $arg in
    --dry-run)     mode=dry-run ;;
    --check)       mode=check ;;
    --no-brew)     brew_step=0 ;;
    --skip-verify) verify_step=0 ;;
    -h|--help)     sed -n '2,/^$/s/^# \{0,1\}//p' $0; exit 0 ;;
    *)             print -u2 "install.sh: неизвестный флаг $arg (--help)"; exit 2 ;;
  esac
done

# ============================================================
# Вывод
# ============================================================

typeset -i failures=0
typeset -a manual

section() { print -r -- $'\n\e[1m== '"$1"$' ==\e[0m' }
ok()      { print -r -- $'  \e[32m✓\e[0m '"$1" }
bad()     { print -r -- $'  \e[31m✗\e[0m '"$1"; failures+=1 }
info()    { print -r -- "  · $1" }
die()     { print -u2 -r -- $'\e[31minstall.sh:\e[0m '"$1"; exit 1 }

# act "что делается" команда…: печатает действие; в --dry-run не выполняет.
act() {
  local what=$1
  shift
  if [[ $mode == dry-run ]]; then
    print -r -- "  → (dry-run) $what"
    return 0
  fi
  print -r -- "  → $what"
  "$@" || die "не удалось: $what"
}

short() { print -r -- ${1/#$HOME/~} }

# Перенести существующий путь в каталог бэкапа (с путём относительно ~).
backup() {
  local target=$1 rel
  [[ -e $target || -L $target ]] || return 0
  rel=${target#$HOME/}
  [[ $rel == $target ]] && rel=${target#/}
  if [[ $mode == dry-run ]]; then
    print -r -- "    (dry-run) в бэкап: $(short $target)"
    return 0
  fi
  mkdir -p ${backup_root}/${rel:h} || die "не создать $backup_root"
  mv $target $backup_root/$rel || die "не перенести в бэкап $(short $target)"
  print -r -- "    в бэкап: $(short $backup_root)/$rel"
}

# Симлинк dst → src; существующий другой файл или ссылка уходят в бэкап.
link() {
  local src=$1 dst=$2
  if [[ -L $dst && ${dst:A} == ${src:A} ]]; then
    [[ $mode == check ]] && ok "$(short $dst) → $(short $src)"
    return 0
  fi
  if [[ $mode == check ]]; then
    bad "$(short $dst) не ссылается на $(short $src)"
    return 0
  fi
  backup $dst
  act "ссылка $(short $dst) → $(short $src)" mkdir -p ${dst:h}
  [[ $mode == dry-run ]] || ln -s $src $dst || die "не создать ссылку $(short $dst)"
}

# Строка в конце файла (файл создаётся при отсутствии); копия файла — в бэкап.
ensure_line() {
  local file=$1 line=$2
  if [[ -f $file ]] && grep -qxF -- $line $file; then
    [[ $mode == check ]] && ok "$(short $file): $line"
    return 0
  fi
  if [[ $mode == check ]]; then
    bad "в $(short $file) нет строки: $line"
    return 0
  fi
  if [[ -f $file && $mode != dry-run ]]; then
    mkdir -p $backup_root
    cp -p $file $backup_root/${file:t}.orig || die "не скопировать $(short $file)"
  fi
  act "строка в $(short $file): $line" true
  [[ $mode == dry-run ]] || print -r -- $'\n# dotfiles\n'"$line" >> $file || die "не дописать $(short $file)"
}

# ============================================================
# Проверки окружения
# ============================================================

section "macOS"
[[ $(uname -s) == Darwin ]] || die "скрипт рассчитан на macOS"
ok "macOS $(sw_vers -productVersion), $(uname -m)"

if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode Command Line Tools: $(xcode-select -p)"
else
  bad "нет Xcode Command Line Tools (git, компилятор C)"
  [[ $mode == check ]] || die "поставь их: xcode-select --install — и запусти install.sh снова"
fi

# brew мог быть ещё не в PATH (первый запуск после установки Homebrew).
if (( ! $+commands[brew] )); then
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x $candidate ]] && { eval "$($candidate shellenv)"; break }
  done
fi
if (( $+commands[brew] )); then
  ok "Homebrew $(brew --version | head -1 | awk '{print $2}') в $(brew --prefix)"
else
  bad "нет Homebrew"
  [[ $mode == check ]] || die "поставь Homebrew (https://brew.sh или через IT) и запусти install.sh снова"
fi

# ============================================================
# brew
# ============================================================

section "brew: пакеты из Brewfile"
if (( ! $+commands[brew] )); then
  info "пропущено: нет Homebrew"
elif [[ $mode == check || $mode == dry-run ]]; then
  if brew bundle check --no-upgrade --file=$repo/Brewfile >/dev/null 2>&1; then
    ok "все пакеты Brewfile установлены"
  else
    missing=(${(f)"$(brew bundle check --no-upgrade --file=$repo/Brewfile --verbose 2>&1 | sed -n 's/^→ //p')"})
    if [[ $mode == check ]]; then
      bad "не установлено: ${missing:-см. brew bundle check --verbose}"
    else
      print -r -- "  → (dry-run) brew bundle: ${missing:-установит недостающее}"
    fi
  fi
elif (( brew_step )); then
  act "brew bundle --file Brewfile (без обновления уже стоящего)" brew bundle --no-upgrade --file=$repo/Brewfile
else
  info "пропущено (--no-brew)"
fi

# zsh запоминает содержимое PATH при первом обращении к $commands: без
# rehash только что поставленные brew bundle программы не видны.
rehash
for tool in tmux nvim go gopls dlv fzf fd rg jq tree-sitter delta lazygit difft git; do
  (( $+commands[$tool] )) || {
    if [[ $mode == install ]]; then
      (( brew_step )) && die "нет команды $tool после brew bundle — проверь вывод brew выше"
      die "нет команды $tool — запусти без --no-brew"
    fi
    info "нет команды $tool (поставит brew bundle)"
  }
done

# ============================================================
# Телеметрия
# ============================================================

# Homebrew по умолчанию отправляет статистику установок, Go собирает
# счётчики использования (режим local — пока только на диск). Обе
# выключаются; go — из ~, чтобы go.mod рядом не начал скачивание toolchain.
section "privacy"
if (( $+commands[brew] )); then
  if brew analytics state 2>/dev/null | grep -q disabled; then
    [[ $mode == check ]] && ok "Homebrew: статистика выключена"
  elif [[ $mode == check ]]; then
    bad "Homebrew отправляет статистику установок (brew analytics off)"
  else
    act "brew analytics off" brew analytics off
  fi
fi
if (( $+commands[go] )); then
  if [[ $(cd ~ && GOTOOLCHAIN=local go telemetry 2>/dev/null) == off ]]; then
    [[ $mode == check ]] && ok "Go: телеметрия выключена"
  elif [[ $mode == check ]]; then
    bad "Go собирает телеметрию (go telemetry off)"
  else
    act "go telemetry off" zsh -c 'cd ~ && GOTOOLCHAIN=local go telemetry off'
  fi
fi

# ============================================================
# Конфиги
# ============================================================

section "anchor"
if [[ ${anchor:A} == ${repo:A} && ! -L $anchor ]]; then
  # Репозиторий склонирован прямо в ~/.config/dotfiles: ссылка не нужна.
  [[ $mode == check ]] && ok "репозиторий лежит в $(short $anchor)"
else
  link $repo $anchor
fi

section "zsh"
ensure_line $HOME/.zshrc "source ~/.config/dotfiles/zsh/zshrc.zsh"

section "tmux"
ensure_line $HOME/.tmux.conf "source-file ~/.config/dotfiles/tmux/tmux.conf"
for tool in dev devlog projects; do
  link $repo/tmux/$tool $HOME/.local/bin/$tool
done

section "git"
include='~/.config/dotfiles/git/gitconfig'
if git config --global --get-all include.path 2>/dev/null | grep -qxF -- $include; then
  [[ $mode == check ]] && ok "~/.gitconfig: include.path = $include"
elif [[ $mode == check ]]; then
  bad "в ~/.gitconfig нет include.path = $include"
else
  [[ -f $HOME/.gitconfig && $mode != dry-run ]] && { mkdir -p $backup_root; cp -p $HOME/.gitconfig $backup_root/gitconfig.orig }
  act "include.path = $include в ~/.gitconfig" git config --global --add include.path $include
fi
link $repo/git/lazygit.yml "$HOME/Library/Application Support/lazygit/config.yml"
if [[ -z $(git config --global user.email) ]]; then
  manual+='git: задай имя и почту — git config --global user.name "…" и user.email "…"'
fi

section "iTerm2"
profiles="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
profile_src=$repo/iterm/go-backend.json
profile_dst="$profiles/go-backend.json"
if cmp -s $profile_src $profile_dst; then
  [[ $mode == check ]] && ok "профиль Go Backend: $(short $profile_dst)"
elif [[ $mode == check ]]; then
  bad "профиль Go Backend не установлен или отличается: $(short $profile_dst)"
else
  backup $profile_dst
  act "профиль Go Backend → $(short $profile_dst)" mkdir -p $profiles
  [[ $mode == dry-run ]] || cp $profile_src $profile_dst || die "не скопировать профиль iTerm"
fi
guid=$(jq -r '.Profiles[0].Guid' $profile_src 2>/dev/null)
if [[ -n $guid && $(defaults read com.googlecode.iterm2 "Default Bookmark Guid" 2>/dev/null) == $guid ]]; then
  [[ $mode == check ]] && ok "Go Backend — профиль по умолчанию"
elif [[ $mode == check ]]; then
  info "Go Backend не профиль по умолчанию"
elif pgrep -x iTerm2 >/dev/null; then
  # Пока iTerm запущен, он перезапишет настройку при выходе.
  manual+='iTerm2: Settings → Profiles → Go Backend → Other Actions… → Set as Default'
elif [[ -n $guid ]]; then
  act "Go Backend — профиль iTerm по умолчанию" \
    defaults write com.googlecode.iterm2 "Default Bookmark Guid" -string $guid
fi

# ============================================================
# nvim
# ============================================================

section "nvim"
link $repo/nvim $config_home/nvim

if (( $+commands[nvim] )); then
  data_dir=$(nvim --clean --headless -c 'lua io.stdout:write(vim.fn.stdpath("data"))' +qa 2>/dev/null)
  helper=$data_dir/change-tree/go-change-index

  if [[ $mode == check ]]; then
    [[ -x $helper ]] && ok "AST-хелпер: $(short $helper)" || bad "нет AST-хелпера: $(short $helper)"
    if NVIM_BOOTSTRAP_CHECK_ONLY=1 nvim --clean --headless -i NONE -u NONE \
        -l $repo/nvim/tools/bootstrap.lua >/dev/null 2>&1; then
      ok "плагины и парсеры совпадают с lock-файлом"
    else
      bad "плагины или парсеры не установлены — запусти install.sh"
    fi
  else
    # Хелпер собирается из исходников репозитория: только стандартная
    # библиотека Go, без сети (GOPROXY=off) и без смены toolchain.
    goindex=$repo/nvim/tools/goindex
    if [[ -x $helper && $helper -nt $goindex/main.go && $helper -nt $goindex/go.mod ]]; then
      info "AST-хелпер актуален: $(short $helper)"
    else
      act "тесты AST-хелпера" zsh -c "cd ${(q)goindex} && GOTOOLCHAIN=local GOFLAGS= GOPROXY=off go test ./... >/dev/null"
      act "сборка AST-хелпера → $(short $helper)" zsh -c "mkdir -p ${(q)helper:h} && cd ${(q)goindex} && GOTOOLCHAIN=local GOFLAGS= GOPROXY=off go build -trimpath -o ${(q)helper} ."
    fi
    # Плагины — git clone строго по коммитам nvim-pack-lock.json; парсеры
    # Go, SQL и тегов в комментариях — сборка nvim-treesitter (tree-sitter +
    # компилятор C).
    act "плагины по lock-файлу и парсеры Tree-sitter" \
      nvim --headless -i NONE -u $config_home/nvim/init.lua \
        --cmd "lua vim.g.fzf_lua_server='bootstrap'" \
        -l $repo/nvim/tools/bootstrap.lua
    if (( verify_step )); then
      verify_log=$HOME/.local/state/dotfiles/verify.log
      [[ $mode == dry-run ]] || mkdir -p ${verify_log:h}
      act "проверки nvim (nvim/verify.sh, лог: $(short $verify_log))" \
        zsh -c "${(q)repo}/nvim/verify.sh > ${(q)verify_log} 2>&1"
    else
      info "nvim/verify.sh пропущен (--skip-verify)"
    fi
  fi
else
  info "nvim не установлен — шаг пропущен"
fi

if (( $+commands[DevToolsSecurity] )) && ! DevToolsSecurity -status 2>/dev/null | grep -q enabled; then
  manual+='delve: включить режим разработчика — sudo DevToolsSecurity -enable && sudo dscl . append /Groups/_developer GroupMembership $(whoami) (на управляемом Mac — через IT)'
fi

# ============================================================
# Итог
# ============================================================

section "Итог"
if [[ $mode == check ]]; then
  (( failures == 0 )) && ok "всё на месте" || bad "проблем: $failures"
else
  [[ -d $backup_root ]] && info "бэкап заменённого: $(short $backup_root)"
  info "новый шелл: exec zsh; запущенный tmux: tmux source-file ~/.tmux.conf"
fi
for item in $manual; do
  info "вручную — $item"
done
(( failures == 0 ))
