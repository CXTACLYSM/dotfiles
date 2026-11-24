#!/usr/bin/env bash
# Регрессионные проверки tmux-части: tmux.conf читается сервером без
# ошибок, сегмент git статус-бара (git-status.sh) и просмотр изменений
# prefix G (gitview) на временных репозиториях, документация prefix i
# (docs) с запросами grpcurl для rpc на временном проекте, наборы проектов
# и снимок сессий dev (-w, -W, -s, -r) с переключателем prefix f.
# Свой сервер tmux живёт в каталоге проверки (TMUX_TMPDIR) и не трогает
# рабочие сессии; репозитории — во временном каталоге с чистым git config.
#
#   tmux/verify.sh
set -euo pipefail

unset TMUX TMUX_PANE
here="$(cd "$(dirname "$0")" && pwd)"

step() {
  printf '\n== %s ==\n' "$1"
}

for command in tmux git fzf delta difft zsh nvim rg; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required" >&2
    exit 1
  }
done

work="$(mktemp -d)"
export TMUX_TMPDIR="$work"
socket=dotfiles-verify
trap 'tmux -L "$socket" kill-server 2>/dev/null || true; rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_STATUS_TTL=0

# $1: what; $2: got; $3: want.
same() {
  if [[ "$2" != "$3" ]]; then
    printf '%s: got %q, want %q\n' "$1" "$2" "$3" >&2
    exit 1
  fi
}

commit() {
  git -C "$1" -c user.name=fixture -c user.email=fixture@localhost commit -q --allow-empty -m "${2:-fixture}"
}

step "Versions"
tmux -V
git --version

step "tmux.conf"
tmux -L "$socket" -f /dev/null new-session -d -s probe -x 120 -y 30
tmux -L "$socket" source-file "$here/tmux.conf"
right="$(tmux -L "$socket" show -gv status-right)"
[[ "$right" == *git-status.sh* ]] || { echo "status-right without git-status.sh: $right" >&2; exit 1; }
# The session of a task is "project@branch": the project in its own plate,
# the branch in a second one; a plain session has one plate. The current
# window is a plate without the underline tmux adds by default; the index
# of a window is dimmer than its name.
tmux -L "$socket" new-session -d -s 'proj@TASK-1' -x 120 -y 30
left="$(tmux -L "$socket" display-message -p -t 'proj@TASK-1' '#{E:status-left}')"
[[ "$left" == *" proj #[default]#[fg=#b4befe,bg=#313244] @TASK-1 #[default]"* ]] || { echo "status-left of a task session: $left" >&2; exit 1; }
left="$(tmux -L "$socket" display-message -p -t probe '#{E:status-left}')"
[[ "$left" == *" probe #[default] "* && "$left" != *"@"* ]] || { echo "status-left of a plain session: $left" >&2; exit 1; }
tmux -L "$socket" kill-session -t 'proj@TASK-1'
[[ "$(tmux -L "$socket" show -gv window-status-current-style)" == default ]] || { echo "the current window is underlined" >&2; exit 1; }
[[ "$(tmux -L "$socket" show -gv window-status-format)" == *'#[fg=#6c7086]#I #[fg=#a6adc8]#W'* ]] || { echo "window index is not dimmed" >&2; exit 1; }
keys="$(tmux -L "$socket" list-keys -T prefix)"
[[ "$keys" == *" G "*gitview* ]] || { echo "prefix G is not bound to gitview" >&2; exit 1; }
hooks="$(tmux -L "$socket" show-hooks -g | grep -c 'dev -s -q')"
[[ "$hooks" -ge 12 ]] || { echo "snapshot hooks: $hooks" >&2; exit 1; }
# The Russian layout: the same key, the same command (tmux/ru-keys runs
# from tmux.conf through run-shell, so give it a moment).
for _ in 1 2 3 4 5 6 7 8 9 10; do tmux -L "$socket" list-keys -T prefix ы 2>/dev/null | grep -q . && break; sleep 0.3; done
for key in ы а п ш е; do   # s f g i t
  [[ "$(tmux -L "$socket" list-keys -T prefix "$key" 2>/dev/null)" == *"-T prefix $key "* ]] || { echo "no prefix $key" >&2; exit 1; }
done
[[ "$(tmux -L "$socket" list-keys -T prefix ы)" == *choose-tree* ]] || { echo "prefix ы is not the tree" >&2; exit 1; }
[[ "$(tmux -L "$socket" list-keys -T prefix п)" == *lazygit* ]] || { echo "prefix п is not lazygit" >&2; exit 1; }
[[ "$(tmux -L "$socket" list-keys -T copy-mode-vi н)" == *copy-pipe* ]] || { echo "copy mode: н is not y" >&2; exit 1; }
# In the root table only Alt-letter: a plain letter there is typing.
if tmux -L "$socket" list-keys -T root ы 2>/dev/null | grep -q .; then echo "a plain letter is bound in the root table" >&2; exit 1; fi
tmux -L "$socket" kill-server
echo "TMUX_CONF_OK"

step "git segment of the status bar"
status="$here/git-status.sh"
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
echo 'package main' > "$repo/main.go"
git -C "$repo" add -A
commit "$repo"
same "clean"            "$("$status" --plain "$repo")" "main"
echo '// change' >> "$repo/main.go"
same "unstaged"         "$("$status" --plain "$repo")" "main*"
git -C "$repo" add -A
same "staged"           "$("$status" --plain "$repo")" "main+"
echo '// more' >> "$repo/main.go"
same "both"             "$("$status" --plain "$repo")" "main*+"
git -C "$repo" add -A
commit "$repo" second
same "clean again"      "$("$status" --plain "$repo")" "main"
same "outside git"      "$("$status" --plain "$work")" ""
same "missing dir"      "$("$status" --plain "$work/nowhere")" ""

# A linked worktree (dev -b): @branch.
git -C "$repo" worktree add -q -b task "$work/wt" >/dev/null 2>&1
same "worktree"         "$("$status" --plain "$work/wt")" "@task"
echo 'x' > "$work/wt/new.go"
same "worktree, untracked files are not changes" "$("$status" --plain "$work/wt")" "@task"

# Ahead of and behind the upstream.
git clone -q --bare "$repo" "$work/remote.git"
git -C "$repo" remote add origin "$work/remote.git"
git -C "$repo" fetch -q origin
git -C "$repo" branch -q -u origin/main main
same "in sync"          "$("$status" --plain "$repo")" "main"
commit "$repo" third
same "ahead"            "$("$status" --plain "$repo")" "main ↑1"
git -C "$repo" reset -q --hard HEAD~2
same "behind"           "$("$status" --plain "$repo")" "main ↓1"
git -C "$repo" checkout -q --detach origin/main
sha="$(git -C "$repo" rev-parse --short HEAD)"
same "detached"         "$("$status" --plain "$repo")" "$sha"
git -C "$repo" checkout -q main

# tmux styles in the real output; the cache answers within its ttl.
styled="$("$status" "$repo")"
[[ "$styled" == '#[fg=#a6adc8]main'*'#[default] ' ]] || { echo "styled: $styled" >&2; exit 1; }
styled="$("$status" "$work/wt")"
[[ "$styled" == '#[fg=#b4befe]@task#[default] ' ]] || { echo "styled worktree: $styled" >&2; exit 1; }
export TMPDIR="$work/tmp" GIT_STATUS_TTL=60
mkdir -p "$TMPDIR"
same "first answer"     "$("$status" --plain "$repo")" "main ↓1"
echo '// late' >> "$repo/main.go"
same "cached answer"    "$("$status" --plain "$repo")" "main ↓1"
same "fresh answer"     "$(GIT_STATUS_TTL=0 "$status" --plain "$repo")" "main* ↓1"
[[ -n "$(ls "$TMPDIR"/dev-git-status-*/ 2>/dev/null)" ]] || { echo "no cache files" >&2; exit 1; }
echo "GIT_STATUS_OK"

step "git viewer (prefix G)"
view="$here/gitview"
vrepo="$work/view"
mkdir -p "$vrepo"
git -C "$vrepo" init -q -b main
printf 'package main\n\nfunc main() {}\n' > "$vrepo/main.go"
echo '# view' > "$vrepo/README.md"
git -C "$vrepo" add -A
commit "$vrepo" first
printf 'package main\n\nfunc main() {\n\tprintln("hi")\n}\n' > "$vrepo/main.go"
echo 'new' > "$vrepo/new.txt"
git -C "$vrepo" add new.txt
echo 'notes' > "$vrepo/notes.txt"
strip() { sed $'s/\e\\[[0-9;]*m//g'; }
# $1: what; $2: text; $3: needle.
has() {
  if [[ "$2" != *"$3"* ]]; then
    printf '%s: no %q in:\n%s\n' "$1" "$3" "$2" >&2
    exit 1
  fi
}
cd "$vrepo"
same "changes" "$("$view" --list changes | strip)" \
  "$(printf 'file\t M  main.go\tmain.go\nfile\tA   new.txt\tnew.txt\nfile\t??  notes.txt\tnotes.txt')"
same "staged" "$("$view" --list staged | strip)" "$(printf 'file\tA   new.txt\tnew.txt')"
log="$("$view" --list log | strip)"
[[ "$log" =~ ^commit$'\t'[0-9a-f]+\ first\ \ fixture,\ .*$'\t'[0-9a-f]+$ ]] || { echo "log: $log" >&2; exit 1; }
same "branch without origin" "$("$view" --list branch | strip)" "$(printf 'none\tнет коммитов сверх main\t-')"
git clone -q --bare "$vrepo" "$work/view-remote.git"
git -C "$vrepo" remote add origin "$work/view-remote.git"
git -C "$vrepo" fetch -q origin
git -C "$vrepo" remote set-head origin -a >/dev/null
same "branch in sync" "$("$view" --list branch | strip)" "$(printf 'none\tнет коммитов сверх origin/HEAD\t-')"
git -C "$vrepo" add main.go
commit "$vrepo" second
branch="$("$view" --list branch | strip)"
[[ "$branch" =~ ^commit$'\t'[0-9a-f]+\ second ]] && [[ "$(printf '%s\n' "$branch" | wc -l | tr -d ' ')" == 1 ]] ||
  { echo "branch: $branch" >&2; exit 1; }
git -C "$vrepo" reset -q --soft HEAD~1
git -C "$vrepo" restore -q --staged main.go

export FZF_PREVIEW_COLUMNS=100 COLUMNS=100
has "delta preview of a file"   "$(FZF_PROMPT='changes · delta › ' "$view" --preview file main.go | strip)" 'println("hi")'
has "difft preview of a file"   "$(FZF_PROMPT='changes · difft › ' "$view" --preview file main.go | strip)" 'println("hi")'
has "difft names the language"  "$(FZF_PROMPT='changes · difft › ' "$view" --preview file main.go | strip)" 'main.go --- Go'
has "git preview of a file"     "$(FZF_PROMPT='changes · git › ' "$view" --preview file main.go | strip)" '+	println("hi")'
has "untracked file, delta"     "$(FZF_PROMPT='changes · delta › ' "$view" --preview file notes.txt | strip)" 'notes'
has "untracked file, difft"     "$(FZF_PROMPT='changes · difft › ' "$view" --preview file notes.txt | strip)" 'notes'
has "untracked file, git"       "$(FZF_PROMPT='changes · git › ' "$view" --preview file notes.txt | strip)" '+notes'
has "staged file"               "$(FZF_PROMPT='staged · delta › ' "$view" --preview file new.txt | strip)" 'new.txt'
sha="$(git -C "$vrepo" rev-parse --short HEAD)"
has "commit, delta"             "$(FZF_PROMPT='log · delta › ' "$view" --preview commit "$sha" | strip)" 'first'
has "commit, difft"             "$(FZF_PROMPT='log · difft › ' "$view" --preview commit "$sha" | strip)" 'README.md --- Text'
has "commit, git"               "$(FZF_PROMPT='log · git › ' "$view" --preview commit "$sha" | strip)" '+# view'
same "nothing to show"          "$(FZF_PROMPT='branch · git › ' "$view" --preview none - | strip)" 'нечего показывать'
same "a wrong prompt falls back" "$(FZF_PROMPT='?' "$view" --cycle mode)" "change-prompt(staged · delta › )+reload($view --list staged)+first"
same "next mode"                "$(FZF_PROMPT='branch · git › ' "$view" --cycle mode)" "change-prompt(changes · git › )+reload($view --list changes)+first"
same "next renderer"            "$(FZF_PROMPT='log · git › ' "$view" --cycle renderer)" 'change-prompt(log · delta › )+refresh-preview'
export GITVIEW_PAGER=cat
has "whole file, delta"         "$(FZF_PROMPT='changes · delta › ' "$view" --open file main.go | strip)" 'println("hi")'
has "whole file, difft"         "$(FZF_PROMPT='changes · difft › ' "$view" --open file main.go | strip)" 'println("hi")'
has "whole commit, git"         "$(FZF_PROMPT='log · git › ' "$view" --open commit "$sha" | strip)" 'first'
unset GITVIEW_PAGER FZF_PREVIEW_COLUMNS
cd "$work"
if "$view" "$work" >/dev/null 2>&1; then
  echo "gitview opened outside a repository" >&2
  exit 1
fi
echo "GITVIEW_OK"

step "documentation (prefix i): rpc requests"
docs="$here/docs"
drepo="$work/docs-project"
mkdir -p "$drepo/api/order/v1" "$drepo/cmd/app"
printf 'module example.com/docsfix\n\ngo 1.23\n' > "$drepo/go.mod"
echo '# docs fixture' > "$drepo/README.md"
cat > "$drepo/cmd/app/main.go" <<'EOF_DOCS_MAIN'
package main

import (
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

func main() {
	server := grpc.NewServer()
	reflection.Register(server)
}
EOF_DOCS_MAIN
cat > "$drepo/api/order/v1/order.proto" <<'EOF_DOCS_PROTO'
syntax = "proto3";

package order.v1;

// OrderService manages orders.
service OrderService {
  // CreateOrder places an order.
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse);
  rpc GetOrder (GetOrderRequest) returns (Order);
}

message CreateOrderRequest {
  int64 user_id = 1;
  repeated string tags = 2;
}

message CreateOrderResponse { Order order = 1; }
message GetOrderRequest { int64 id = 1; }
message Order { int64 id = 1; }
EOF_DOCS_PROTO
git -C "$drepo" init -q -b main
cd "$drepo"
listed="$("$docs" --list)"
has "the contract is listed" "$listed" "$(printf 'api\tapi/order/v1/order.proto\tapi\tapi/order/v1/order.proto')"
has "an rpc is listed"       "$listed" "$(printf 'rpc\tOrderService/CreateOrder api/order/v1/order.proto\trpc\tapi/order/v1/order.proto\tOrderService\tCreateOrder')"
has "the second rpc too"     "$listed" "$(printf 'rpc\tOrderService/GetOrder api/order/v1/order.proto\trpc\tapi/order/v1/order.proto\tOrderService\tGetOrder')"
preview="$("$docs" --preview rpc api/order/v1/order.proto OrderService CreateOrder | strip)"
has "the rpc with its comment" "$preview" '// CreateOrder places an order.'
has "the request message"      "$preview" 'repeated string tags = 2;'
has "the command"              "$preview" "grpcurl -plaintext -d '{\"user_id\": 0, \"tags\": [\"\"]}' localhost:8080 order.v1.OrderService/CreateOrder"
same "copy" "$(DOCS_CLIPBOARD=cat "$docs" --copy rpc api/order/v1/order.proto OrderService GetOrder)" \
  "grpcurl -plaintext -d '{\"id\": 0}' localhost:8080 order.v1.OrderService/GetOrder"
# Enter on an rpc: the command typed into a new rpc window of the session.
tmux -f /dev/null new-session -d -s shop -n editor -c "$drepo" -x 160 -y 40
"$docs" --open rpc api/order/v1/order.proto OrderService CreateOrder
same "rpc window" "$(tmux list-windows -t shop -F '#W' | tr '\n' ' ')" "editor rpc "
same "the rpc window is shown" "$(tmux display-message -p -t shop '#W')" "rpc"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pane="$(tmux capture-pane -p -t shop:rpc | tr -d '\n')"
  [[ "$pane" == *"order.v1.OrderService/CreateOrder"* ]] && break
  sleep 0.5
done
has "the command is typed, not run" "$pane" "grpcurl -plaintext -d '{\"user_id\": 0, \"tags\": [\"\"]}' localhost:8080 order.v1.OrderService/CreateOrder"
"$docs" --open rpc api/order/v1/order.proto OrderService GetOrder
same "the same window again" "$(tmux list-windows -t shop -F '#W' | tr '\n' ' ')" "editor rpc "
tmux kill-server
# Enter on a document (two arguments, not the four of an rpc): the file in
# a read-only nvim. (Under no_unset the missing $4 and $5 once stopped the
# script and Enter did nothing.)
mkdir -p "$work/stub"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/nvim.args"\n' "$work" > "$work/stub/nvim"
chmod +x "$work/stub/nvim"
echo '# shop' > "$drepo/README.md"
PATH="$work/stub:$PATH" "$docs" --open md README.md
has "a document opens for reading" "$(tr '\n' ' ' < "$work/nvim.args")" "-R "
has "the document itself" "$(tail -n 1 "$work/nvim.args")" "README.md"
cd "$work"
echo "DOCS_OK"

step "dev: sets of projects, snapshot and restore"
dev="$here/dev"
projects="$here/projects"
export XDG_STATE_HOME="$work/state" DEV_SETS="$work/sets" DEV_LAYOUTS="$work/layouts" DEV_PROJECT_ROOTS="$work/roots"
mkdir -p "$work/proj" "$work/other" "$work/layouts" "$work/roots/proj" "$work/roots/spare"
printf 'module example.com/proj\n\ngo 1.23\n' > "$work/proj/go.mod"
git -C "$work/proj" init -q -b main
git -C "$work/proj" add -A
commit "$work/proj" init
# A layout without nvim: the windows are enough for the checks.
printf "win editor\nwin server 'echo server'\nwin tests\n" > "$work/layouts/proj.zsh"
other="$(cd "$work/other" && pwd -P)"
work_real="$(cd "$work" && pwd -P)"
snapshot="$work/state/dev/sessions"
state_of() { awk -F'\t' -v s="$1" '$1 == "session" && $2 == s { print $9 }' "$snapshot"; }
tmux -f /dev/null new-session -d -s seed -c "$work" -x 120 -y 30
same "dev -d" "$(cd "$work/proj" && "$dev" -d)" "proj"
same "layout windows" "$(tmux list-windows -t '=proj' -F '#W' | tr '\n' ' ')" "editor server tests "
# No layout file: the windows by default, git (lazygit) the last one.
mkdir -p "$work/auto"
printf 'module example.com/auto\n\ngo 1.23\n' > "$work/auto/go.mod"
same "dev -d without a layout" "$(cd "$work/auto" && "$dev" -d)" "auto"
same "default windows, git last" "$(tmux list-windows -t '=auto' -F '#W' | tr '\n' ' ')" "editor server tests infra shell git "
same "the git window in the root" "$(tmux list-panes -t '=auto:git' -F '#{pane_current_path}')" "$work_real/auto"
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ "$(tmux list-panes -t '=auto:git' -F '#{pane_current_command}')" == lazygit ]] && break; sleep 0.3; done
same "lazygit running there" "$(tmux list-panes -t '=auto:git' -F '#{pane_current_command}')" "lazygit"
tmux kill-session -t '=auto'
tmux new-window -d -t '=proj:' -n extra -c "$work/other"
tmux split-window -d -t '=proj:extra' -c "$work"
tmux select-window -t '=proj:tests'
"$dev" -s >/dev/null
[[ -f "$snapshot" ]] || { echo "no snapshot at $snapshot" >&2; exit 1; }
# dev keeps the root as typed ($work/proj); tmux reports real paths for panes.
has "the session with its root" "$(cat "$snapshot")" "$(printf 'session\tproj\t%s\tproj\t\t\t' "$work/proj")"
has "the extra window" "$(cat "$snapshot")" "$(printf 'window\tproj\t3\textra\t')"
has "a pane with its directory" "$(cat "$snapshot")" "$(printf 'pane\tproj\t3\t0\t%s\t' "$other")"
same "the active window is recorded" "$(awk -F'\t' '$1 == "session" && $2 == "proj" { print $8 }' "$snapshot")" "tests"
same "an open session is live" "$(state_of proj)" "live"
same "dev -W" "$(grep -v '^#' <("$dev" -W team >/dev/null; cat "$work/sets/team"))" "$work/proj"

# Without a server the snapshot stays; the first snapshot of a new server
# carries the sessions of the old one over as kept.
tmux kill-server
same "no server: the snapshot is kept" "$("$dev" -s 2>&1 || true)" "dev: нет сессий tmux — снимок не изменён"
same "still live in the file" "$(state_of proj)" "live"
tmux -f /dev/null new-session -d -s seed -c "$work" -x 120 -y 30
"$dev" -s >/dev/null
same "a new server: the old session is kept" "$(state_of proj)" "kept"
has "with its windows" "$(cat "$snapshot")" "$(printf 'window\tproj\t3\textra\t')"
has "dev -r" "$("$dev" -d -r)" "восстановлено: proj"
same "windows of the layout and the extra one" "$(tmux list-windows -t '=proj' -F '#W' | tr '\n' ' ')" "editor server tests extra "
same "panes of the extra window in their directories" "$(tmux list-panes -t '=proj:extra' -F '#{pane_current_path}' | tr '\n' ' ')" "$other $work_real "
same "the active window again" "$(tmux display-message -p -t '=proj:' '#{window_name}')" "tests"
same "a typed command of the layout" "$(tmux capture-pane -p -t '=proj:server' | grep -c 'echo server')" "1"
has "nothing to restore twice" "$("$dev" -d -r)" "proj (уже открыта)"
"$dev" -s >/dev/null
same "restored: live again" "$(state_of proj)" "live"

# Closed on the same server: dropped from the snapshot. A kept session of
# the previous server survives the snapshots of this one.
tmux kill-session -t '=proj'
"$dev" -s >/dev/null
same "a closed session is forgotten" "$(state_of proj)" ""
printf 'server\t1\nsession\tproj\t%s\tproj\t\t\t\ttests\tlive\nwindow\tproj\t0\teditor\t\t1\npane\tproj\t0\t0\t%s\tzsh\t1\n' "$work/proj" "$work/proj" > "$snapshot"
"$dev" -s >/dev/null
same "from the previous server: kept" "$(state_of proj)" "kept"
"$dev" -s >/dev/null
same "and kept through the next snapshot" "$(state_of proj)" "kept"
# A saved session whose directory is gone is skipped, the others come back.
printf 'session\tgone\t%s/gone\tgone\t\t\t\teditor\tkept\nwindow\tgone\t0\teditor\t\t1\npane\tgone\t0\t0\t%s/gone\tzsh\t1\n' "$work" "$work" >> "$snapshot"
restored="$("$dev" -d -r 2>&1)"
has "gone directory skipped" "$restored" "gone (нет каталога"
has "proj restored anyway" "$restored" "восстановлено: proj"
same "dev -r by name, already open" "$("$dev" -d -r proj)" "пропущено: proj (уже открыта)"

# prefix f: a saved session is listed as ○ instead of its directory, with
# a preview from the snapshot.
tmux kill-session -t '=proj'
listed="$("$projects" --list)"
has "saved session listed" "$listed" "$(printf 'saved\t○ proj\tproj')"
[[ "$listed" != *"roots/proj"* ]] || { echo "the directory of a saved session is listed twice" >&2; exit 1; }
has "spare directory listed" "$listed" "roots/spare"
has "saved preview: windows" "$("$projects" --preview saved proj)" "0 editor"
has "saved preview: directories" "$("$projects" --preview saved proj)" "$work/proj"

# Sets: dev -w opens every project, -d only prints the sessions.
same "dev -w (list)" "$("$dev" -w | tr '\n' ' ')" "team:   $work/proj "
same "dev -d -w" "$("$dev" -d -w team)" "proj"
tmux has-session -t '=proj'
if "$dev" -w nowhere 2>/dev/null; then echo "an unknown set opened" >&2; exit 1; fi
tmux kill-server
unset XDG_STATE_HOME DEV_SETS DEV_LAYOUTS DEV_PROJECT_ROOTS
echo "DEV_SESSIONS_OK"

step "attention: an agent waiting for you (prefix s, status bar)"
attention="$here/attention"
tmux -L "$socket" kill-server 2>/dev/null || true
tmux -L "$socket" -f "$here/tmux.conf" new-session -d -s shop -n editor -x 120 -y 24 -c "$work"
for w in server tests; do tmux -L "$socket" new-window -d -t shop -n "$w" -c "$work"; done
tmux -L "$socket" new-session -d -s billing -n editor -x 120 -y 24 -c "$work"
tmux -L "$socket" new-window -d -t billing -n tests -c "$work"
asock="$(tmux -L "$socket" display -p '#{socket_path}')"
pane_of() { tmux -L "$socket" display -p -t "$1" '#{pane_id}'; }
# The hook runs inside the pane: $TMUX_PANE names the window; outside tmux nothing happens.
TMUX="$asock,0,0" TMUX_PANE="$(pane_of shop:tests)" "$attention" wait
TMUX="$asock,0,0" TMUX_PANE="$(pane_of shop:editor)" "$attention" done
TMUX="$asock,0,0" TMUX_PANE="$(pane_of billing:tests)" "$attention" wait
same "marks on the windows" "$(TMUX="$asock,0,0" "$attention" list | sort | tr '\t\n' ' ;')" "billing tests wait;shop editor done;shop tests wait;"
( unset TMUX TMUX_PANE; "$attention" wait; ) && echo "  outside tmux: quiet"
same "the counter of waiting windows" "$(TMUX="$asock,0,0" "$attention" status)" "#[fg=#1e1e2e,bg=#f9e2af,bold] ? 2 #[default] "
has "the status bar: ? at the waiting window" "$(tmux -L "$socket" display -p -t shop:editor '#{W:#{E:window-status-format}}')" 'tests#[fg=#f9e2af,bold] ?'
has "the status bar: ✓ at the finished one" "$(tmux -L "$socket" display -p -t shop:editor '#{W:#{E:window-status-format}}')" 'editor#[fg=#a6e3a1] ✓'
has "status-right counts the waiting windows" "$(tmux -L "$socket" show -gv status-right)" 'attention status'
tree="$(tmux -L "$socket" list-keys -T prefix s)"
has "prefix s is the tree with the marks" "$tree" 'choose-tree -Zs -F'
has "the session line lists the waiting windows" "$tree" '#{W:#{?#{==:#{@attention},wait}'
same "the session line rendered" "$(tmux -L "$socket" display -p -t shop:editor '#{W:#{?#{==:#{@attention},wait},? #{window_name} ,}}#{W:#{?#{==:#{@attention},done},✓ #{window_name} ,}}')" "? tests ✓ editor "
# Entering a window: done is seen and goes, wait stays until the agent answers.
tmux -L "$socket" select-window -t shop:tests
sleep 0.5
tmux -L "$socket" select-window -t shop:editor
sleep 0.7
same "done gone on entering, wait kept" "$(TMUX="$asock,0,0" "$attention" list | sort | tr '\t\n' ' ;')" "billing tests wait;shop tests wait;"
TMUX="$asock,0,0" TMUX_PANE="$(pane_of shop:tests)" "$attention" busy
TMUX="$asock,0,0" TMUX_PANE="$(pane_of billing:tests)" "$attention" clear
same "busy and clear" "$(TMUX="$asock,0,0" "$attention" list | tr '\t\n' ' ;')" "shop tests busy;"
same "no counter without waiting windows" "$(TMUX="$asock,0,0" "$attention" status)" ""
tmux -L "$socket" kill-server
# The hooks of Claude Code: written once, foreign hooks kept, idempotent.
settings="$work/claude-settings.json"
printf '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}' > "$settings"
if "$here/agent-hooks" --check claude "$settings" >/dev/null; then echo "check passed before the hooks were written" >&2; exit 1; fi
"$here/agent-hooks" claude "$settings"
"$here/agent-hooks" --check claude "$settings" || { echo "hooks missing after writing" >&2; exit 1; }
"$here/agent-hooks" claude "$settings"
same "foreign Stop hook kept, ours once" "$(jq -c '[.hooks.Stop[].hooks[0].command]' "$settings")" '["say done","~/.config/dotfiles/tmux/attention done"]'
same "the other settings untouched" "$(jq -r .theme "$settings")" "dark"
same "permission prompts and questions mark wait" "$(jq -r '.hooks.Notification[0].matcher, .hooks.PermissionRequest[0].hooks[0].command' "$settings" | tr '\n' ';')" "permission_prompt|elicitation_dialog|agent_needs_input;~/.config/dotfiles/tmux/attention wait;"
same "a turn done, a prompt busy, a session end clear" "$(jq -r '.hooks.Stop[1].hooks[0].command, .hooks.UserPromptSubmit[0].hooks[0].command, .hooks.SessionEnd[0].hooks[0].command' "$settings" | sed 's|.*attention ||' | tr '\n' ' ')" "done busy clear "
# Codex: the same events in ~/.codex/hooks.json, Interrupt instead of Notification; a missing file is created.
codex_hooks="$work/codex/hooks.json"
mkdir -p "$work/codex"
"$here/agent-hooks" codex "$codex_hooks"
"$here/agent-hooks" --check codex "$codex_hooks" || { echo "codex hooks missing after writing" >&2; exit 1; }
same "codex events" "$(jq -r '.hooks | keys | join(" ")' "$codex_hooks")" "Interrupt PermissionRequest PreToolUse SessionEnd SessionStart Stop UserPromptSubmit"
same "codex: approval marks wait, an interrupt ends the turn" "$(jq -r '.hooks.PermissionRequest[0].hooks[0].command, .hooks.Interrupt[0].hooks[0].command' "$codex_hooks" | sed 's|.*attention ||' | tr '\n' ' ')" "wait done "
if "$here/agent-hooks" --check cursor "$codex_hooks" 2>/dev/null; then echo "an unknown agent must be refused" >&2; exit 1; fi
echo "ATTENTION_OK"

step "fzf popups: the normal mode of the nvim pickers (j / k, i, Esc)"
# The binds are fzf transforms that read the prompt; run them as fzf would.
normal_run() {
  zsh -c 'source "$1"; key=$2; prompt=$3
    for ((i = 1; i <= ${#fzf_normal_binds}; i += 2)); do
      b=${fzf_normal_binds[i+1]}; [[ $b == "$key:"* ]] && bind=${b#$key:}
    done
    FZF_PROMPT=$prompt zsh -c "${bind#transform:}"' _ "$here/fzf-normal.zsh" "$1" "$2"
}
same "the list opens in the normal mode" "$(zsh -c 'source "$1"; fzf_normal_prompt вид' _ "$here/fzf-normal.zsh")" "вид ·N › "
same "j moves in the normal mode" "$(normal_run j 'вид ·N › ')" "down"
same "j types while typing" "$(normal_run j 'вид › ')" "put(j)"
same "k, g, l, q, h" "$(normal_run k 'вид ·N › ') $(normal_run g 'вид ·N › ') $(normal_run l 'вид ·N › ') $(normal_run q 'вид ·N › ') [$(normal_run h 'вид ·N › ')]" "up first accept abort []"
same "Esc leaves typing for the normal mode, the base kept" "$(normal_run esc 'вид › ')" "change-prompt(вид ·N › )"
same "Esc in the normal mode closes" "$(normal_run esc 'вид ·N › ')" "abort"
same "i types again" "$(normal_run i 'вид ·N › ')" "change-prompt(вид › )"
same "i while typing is a letter" "$(normal_run i 'вид › ')" "put(i)"
same "without a base" "$(normal_run esc '› ') $(normal_run i '·N › ')" "change-prompt(·N › ) change-prompt(› )"
for picker in view projects; do
  has "$picker uses the normal mode" "$(cat "$here/$picker")" 'fzf-normal.zsh'
done
echo "FZF_NORMAL_OK"

step "view: windows of several sessions on one screen (prefix S)"
view="$here/view"
tmux -L "$socket" kill-server 2>/dev/null || true
tmux -L "$socket" -f "$here/tmux.conf" new-session -d -s shop -n editor -x 120 -y 30 -c "$work"
for w in server tests; do tmux -L "$socket" new-window -d -t shop -n "$w" -c "$work"; done
tmux -L "$socket" new-session -d -s billing -n tests -x 120 -y 30 -c "$work"
tmux -L "$socket" new-session -d -s mono -n editor -x 120 -y 30 -c "$work"
tmux -L "$socket" split-window -d -h -t mono:editor -c "$work"
asock="$(tmux -L "$socket" display -p '#{socket_path}')"
export XDG_STATE_HOME="$work/state"
TMUX="$asock,0,0" TMUX_PANE="$(pane_of shop:tests)" "$attention" wait
mono_layout="$(tmux -L "$socket" display -p -t mono:editor '#{window_layout}')"
has "prefix S toggles the view" "$(tmux -L "$socket" list-keys -T prefix S)" 'view toggle'
has "status-right names the view" "$(tmux -L "$socket" show -gv status-right)" 'view status'
same "no view: no badge" "$(TMUX="$asock,0,0" "$view" status)" ""
TMUX="$asock,0,0" "$view" make shop:tests billing:tests mono:editor
same "the view holds the panes of the three windows" "$(tmux -L "$socket" list-panes -t view -F '#{@view_origin}' | sort | tr '\n' ' ')" "billing:tests mono:editor mono:editor shop:tests "
same "the windows left their sessions, a stub keeps a session alive" "$(tmux -L "$socket" list-windows -a -F '#{session_name}:#{window_index}=#{window_name}' | tr '\n' ' ')" "billing:1=· mono:1=· shop:1=editor shop:2=server view:1=view "
same "the view window names its panes" "$(tmux -L "$socket" show -wv -t view:1 pane-border-status)" "top"
same "the badge while the view is open" "$(TMUX="$asock,0,0" "$view" status)" "#[fg=#1e1e2e,bg=#89b4fa,bold] view #[default] "
has "the record of where each window came from" "$(cat "$work/state/dev/view")" "$(printf 'W\t%s\tshop\t3\ttests' "$(tmux -L "$socket" display -p -t view:1.3 '#{@view_origin}' >/dev/null; echo '@2')")"
if TMUX="$asock,0,0" "$view" make billing:tests 2>/dev/null; then echo "a second view must be refused" >&2; exit 1; fi
TMUX="$asock,0,0" "$view" back
same "back: every window in its session at its index, the stubs gone, the view gone" "$(tmux -L "$socket" list-windows -a -F '#{session_name}:#{window_index}=#{window_name}:#{window_panes}' | tr '\n' ' ')" "billing:1=tests:1 mono:1=editor:2 shop:1=editor:1 shop:2=server:1 shop:3=tests:1 "
same "the layout of a split window is back" "$(tmux -L "$socket" display -p -t mono:editor '#{window_layout}')" "$mono_layout"
same "the attention mark is back" "$(tmux -L "$socket" show -wv -t shop:tests @attention)" "wait"
same "no origin marks left on the panes" "$(tmux -L "$socket" list-panes -a -F '#{@view_origin}' | tr -d '\n')" ""
[[ -f "$work/state/dev/view" ]] && { echo "the record must go with the view" >&2; exit 1; }
# From the tree: the marks come one by one, the view is built when they stop.
TMUX="$asock,0,0" "$view" pick shop:tests
TMUX="$asock,0,0" "$view" pick billing:tests
sleep 1.2
same "pick: the view from the tagged windows" "$(tmux -L "$socket" list-panes -t view -F '#{@view_origin}' | sort | tr '\n' ' ')" "billing:tests shop:tests "
TMUX="$asock,0,0" "$view" back
same "and back" "$(tmux -L "$socket" list-windows -a -F '#{session_name}:#{window_index}' | tr '\n' ' ')" "billing:1 mono:1 shop:1 shop:2 shop:3 "
# renumber-windows: the neighbours moved down when a window left; two middle
# windows of six come back exactly where they were.
tmux -L "$socket" new-session -d -s six -n editor -x 120 -y 30 -c "$work"
for w in server tests infra shell git; do tmux -L "$socket" new-window -d -t six -n "$w" -c "$work"; done
TMUX="$asock,0,0" "$view" make six:tests six:shell
same "the rest renumbered meanwhile" "$(tmux -L "$socket" list-windows -t six -F '#{window_index}=#{window_name}' | tr '\n' ' ')" "1=editor 2=server 3=infra 4=git "
TMUX="$asock,0,0" "$view" back
same "the order of the session is back" "$(tmux -L "$socket" list-windows -t six -F '#{window_index}=#{window_name}' | tr '\n' ' ')" "1=editor 2=server 3=tests 4=infra 5=shell 6=git "
TMUX="$asock,0,0" "$view" make six:git
TMUX="$asock,0,0" "$view" back
same "the last window comes back last" "$(tmux -L "$socket" list-windows -t six -F '#{window_index}=#{window_name}' | tr '\n' ' ')" "1=editor 2=server 3=tests 4=infra 5=shell 6=git "
# A target that is no window: refused before anything moves (tmux itself
# answers an empty id, or another window of the session, for a bad target).
if TMUX="$asock,0,0" "$view" make six:tests nosuch:1 2>/dev/null; then echo "a missing window must be refused" >&2; exit 1; fi
if TMUX="$asock,0,0" "$view" make six:tests six:9 2>/dev/null; then echo "a missing index must be refused" >&2; exit 1; fi
same "nothing moved, no view" "$(tmux -L "$socket" list-windows -a -F '#{session_name}' | sort -u | tr '\n' ' ')" "billing mono shop six "
has "the error is logged" "$(cat "$work/state/dev/view.log")" "нет окна nosuch:1"
# The record lost while a view is open: back brings the panes home by their labels.
TMUX="$asock,0,0" "$view" make six:tests billing:tests
rm -f "$work/state/dev/view"
TMUX="$asock,0,0" "$view" back
same "recovered by the labels: the windows are back, the stub and the view gone" "$(tmux -L "$socket" list-windows -a -F '#{session_name}:#{window_name}' | sort | tr '\n' ' ')" "billing:tests mono:editor shop:editor shop:server shop:tests six:editor six:git six:infra six:server six:shell six:tests "
has "the tree counts windows in English" "$(tmux -L "$socket" list-keys -T prefix s)" 'session_windows} windows'
unset XDG_STATE_HOME
tmux -L "$socket" kill-server
echo "VIEW_OK"

printf '\nTMUX_VERIFY_OK\n'
