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
keys="$(tmux -L "$socket" list-keys -T prefix)"
[[ "$keys" == *" G "*gitview* ]] || { echo "prefix G is not bound to gitview" >&2; exit 1; }
hooks="$(tmux -L "$socket" show-hooks -g | grep -c 'dev -s -q')"
[[ "$hooks" -ge 12 ]] || { echo "snapshot hooks: $hooks" >&2; exit 1; }
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

printf '\nTMUX_VERIFY_OK\n'
