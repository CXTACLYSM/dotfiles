#!/usr/bin/env bash
# Регрессионные проверки nvim-конфига: синтаксис и загрузка модулей, чистые
# Lua-тесты, AST-хелпер, закреплённые плагины и парсеры, полный старт
# init.lua, gopls на фикстурах (module, standalone, политика toolchain),
# дерево правок на git-фикстуре, навигация (подсмотр, реализации, строка
# «где я», свёртки), SQL-запросы и TODO, переименование. Плагины, парсеры и хелпер ставит
# install.sh; здесь они только проверяются.
#
#   nvim/verify.sh             проверить этот каталог как nvim-конфиг
#   NVIM_CONFIG_DIR=... verify.sh   другой каталог (его имя должно быть nvim)
set -euo pipefail

# Проверки не касаются tmux, в котором их запустили.
unset TMUX TMUX_PANE

config_dir="${NVIM_CONFIG_DIR:-$(cd "$(dirname "$0")" && pwd)}"
config_home="$(dirname "$config_dir")"
tests="$config_dir/tests"

step() {
  printf '\n== %s ==\n' "$1"
}

for command in nvim go gopls git jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required" >&2
    exit 1
  }
done

data_dir="$(nvim --clean --headless -c 'lua io.stdout:write(vim.fn.stdpath("data"))' +qa)"
helper="${NVIM_CHANGE_TREE_HELPER:-$data_dir/change-tree/go-change-index}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/state/nvim" "$work/run" "$work/cache" \
  "$work/go-cache" "$work/go-path" "$work/go-mod-cache" "$work/helper-fixture"

nvim_env=(
  "XDG_STATE_HOME=$work/state"
  "XDG_RUNTIME_DIR=$work/run"
  "XDG_CACHE_HOME=$work/cache"
  # Fixtures use isolated GOPATH/GOMODCACHE/GOPROXY; an in-process gopls keeps
  # them out of the user's shared daemon.
  "NVIM_GOPLS_REMOTE=0"
  # Fixture repositories ignore the user's global git config.
  "GIT_CONFIG_GLOBAL=/dev/null"
  "NVIM_CHANGE_TREE_HELPER=$helper"
)

step "Versions"
nvim --version | head -n 1
GOTOOLCHAIN=local go version
gopls version | head -n 1

step "Lua syntax and modules"
env "${nvim_env[@]}" NVIM_CONFIG_DIR="$config_dir" \
  nvim --clean --headless -i NONE -l "$tests/load_smoke.lua"

step "Pure Lua regressions"
for name in pairs_smoke go_lsp_smoke go_returns_smoke go_tasks_smoke \
  completion_retrigger_smoke big_file_smoke go_debug_smoke change_tree_render
do
  env "${nvim_env[@]}" NVIM_CONFIG_LUA="$config_dir/lua" \
    nvim --clean --headless -i NONE -l "$tests/$name.lua"
done

step "AST helper"
test -x "$helper" || {
  echo "missing helper: $helper (install.sh builds it)" >&2
  exit 1
}
cat > "$work/helper-fixture/sample.go" <<'GO'
package sample

const (
    SchemaBootstrap = "bootstrap"
    SchemaTaskState = "state"
)

var (
    ErrNotFound = error(nil)
    ErrInvalidState = error(nil)
)

type State struct {
    Schema string
}
GO
printf '{"mode":"inspect_file","root":"%s","path":"sample.go"}' "$work/helper-fixture" \
  | "$helper" > "$work/index.json"
jq -e '
  .ok and .version == 3
  and ([.file.symbols[] | select(.kind == "const" and .name == "SchemaTaskState")] | length == 1)
  and ([.file.symbols[] | select(.kind == "var" and .name == "ErrInvalidState")] | length == 1)
  and ([.file.symbols[] | select(.kind == "field" and .name == "Schema")] | length == 1)
' "$work/index.json" >/dev/null
echo "GO_INDEX_HELPER_OK"

step "Pinned plugins and parsers"
env "${nvim_env[@]}" XDG_CONFIG_HOME="$config_home" NVIM_BOOTSTRAP_CHECK_ONLY=1 \
  nvim --clean --headless -i NONE -u NONE -l "$config_dir/tools/bootstrap.lua"

step "Full init"
env "${nvim_env[@]}" XDG_CONFIG_HOME="$config_home" \
  nvim --headless -i NONE -u "$config_dir/init.lua" \
    --cmd "lua vim.g.fzf_lua_server='verify'" \
    -l "$tests/full_init_smoke.lua"

step "LSP integration fixtures"
module="$work/nvim-go-module"
standalone="$work/nvim-go-standalone"
trigger="$work/nvim-go-toolchain-trigger"
mkdir -p "$module/localdep" "$standalone" "$trigger"

cat > "$module/go.mod" <<'EOF_MODULE'
module example.com/editorfixture

go 1.23.0

require example.com/localdep v0.0.0

replace example.com/localdep => ./localdep
EOF_MODULE
cat > "$module/main.go" <<'EOF_MODULE_GO'
package main

import (
	"fmt"

	"example.com/localdep"
)

func greeting(name string) string {
	return localdep.Greeting(name)
}

func main() {
	fmt.Println(greeting("module"))
}

func renameFixture() int {
	value := 1
	return value
}

func sameSpellingFixture() int {
	value := 2
	return value
}

type Store interface {
	Save(name string) error
}

type memoryStore struct{}

func (memoryStore) Save(name string) error { return nil }

type fileStore struct{}

func (fileStore) Save(name string) error { return nil }

type service struct{ store Store }

func (s service) run(name string) error {
	return s.store.Save(name)
}

func (s service) retry(name string) error {
	if err := s.run(name); err != nil {
		return s.run(name)
	}
	return nil
}

func runAll(s service) {
	_ = s.retry("a")
	_ = s.run("b")
}

func countdown(n int) {
	if n > 0 {
		countdown(n - 1)
	}
}
EOF_MODULE_GO
cat > "$module/localdep/go.mod" <<'EOF_DEP_MOD'
module example.com/localdep

go 1.23.0
EOF_DEP_MOD
cat > "$module/localdep/greeting.go" <<'EOF_DEP_GO'
package localdep

func Greeting(name string) string {
	return "hello, " + name
}
EOF_DEP_GO

cat > "$standalone/main.go" <<'EOF_STANDALONE_MAIN'
package main

import "fmt"

func main() {
	fmt.Println(message("standalone"))
}

func renameFixture() int {
	value := 1
	return value
}

func sameSpellingFixture() int {
	value := 2
	return value
}
EOF_STANDALONE_MAIN
cat > "$standalone/helper.go" <<'EOF_STANDALONE_HELPER'
package main

func message(name string) string {
	return "hello, " + name
}
EOF_STANDALONE_HELPER

local_go_version="$(GOTOOLCHAIN=local go env GOVERSION)"
local_go_minor="${local_go_version#go1.}"
local_go_minor="${local_go_minor%%.*}"
case "$local_go_minor" in
  ''|*[!0-9]*)
    echo "unable to derive local Go minor version from $local_go_version" >&2
    exit 1
    ;;
esac
required_go="1.$((local_go_minor + 1)).0"

cat > "$trigger/go.mod" <<EOF_TRIGGER_MOD
module example.com/toolchaintrigger

go $required_go
EOF_TRIGGER_MOD
cat > "$trigger/main.go" <<'EOF_TRIGGER_GO'
package main

func main() {}
EOF_TRIGGER_GO

run_lsp_fixture() {
  local scenario="$1"
  local root="$2"
  local file="$3"
  local output="$work/lsp-$scenario.log"

  (
    cd "$trigger"
    env "${nvim_env[@]}" \
      XDG_CONFIG_HOME="$config_home" \
      GOCACHE="$work/go-cache" \
      GOPATH="$work/go-path" \
      GOMODCACHE="$work/go-mod-cache" \
      GOPROXY="http://127.0.0.1:1" \
      GOTOOLCHAIN=auto \
      NVIM_LSP_SCENARIO="$scenario" \
      NVIM_EXPECTED_ROOT="$root" \
      nvim --headless -i NONE \
        -u "$config_dir/init.lua" \
        --cmd "lua vim.g.fzf_lua_server='verify'; local c=vim.lsp.protocol.make_client_capabilities(); c.workspace.didChangeWatchedFiles={dynamicRegistration=false,relativePatternSupport=false}; vim.lsp.config('*',{capabilities=c})" \
        "$file" -l "$tests/lsp_integration.lua"
  ) >"$output" 2>&1 || {
    cat "$output" >&2
    return 1
  }

  cat "$output"
  if grep -E 'go: downloading|identify (GOMODCACHE|GOROOT)' "$output" >/dev/null; then
    echo "unexpected Go toolchain lookup/download in $scenario fixture" >&2
    return 1
  fi
}

run_lsp_fixture module "$module" "$module/main.go"
run_lsp_fixture standalone "$standalone" "$standalone/main.go"

toolchain_output="$work/lsp-toolchain-policy.log"
(
  cd "$trigger"
  env "${nvim_env[@]}" \
    XDG_CONFIG_HOME="$config_home" \
    GOCACHE="$work/go-cache" \
    GOPATH="$work/go-path" \
    GOMODCACHE="$work/go-mod-cache" \
    GOPROXY="http://127.0.0.1:1" \
    GOTOOLCHAIN=local \
    NVIM_EXPECTED_ROOT="$trigger" \
    NVIM_REQUIRED_GO="$required_go" \
    nvim --headless -i NONE \
      -u "$config_dir/init.lua" \
      --cmd "lua vim.g.fzf_lua_server='verify'; local c=vim.lsp.protocol.make_client_capabilities(); c.workspace.didChangeWatchedFiles={dynamicRegistration=false,relativePatternSupport=false}; vim.lsp.config('*',{capabilities=c})" \
      "$trigger/main.go" -l "$tests/toolchain_policy.lua"
) >"$toolchain_output" 2>&1 || {
  cat "$toolchain_output" >&2
  exit 1
}
cat "$toolchain_output"
if grep -E 'go: downloading|identify (GOMODCACHE|GOROOT)' "$toolchain_output" >/dev/null; then
  echo "unexpected toolchain download in newer-version fixture" >&2
  exit 1
fi

step "Change tree"
repo="$work/change-tree"
mkdir -p "$repo"
cat > "$repo/go.mod" <<'EOF_TREE_MOD'
module example.com/changetree

go 1.23.0
EOF_TREE_MOD
cat > "$repo/main.go" <<'EOF_TREE_MAIN'
package main

import "fmt"

func greeting(name string) string {
	return "hello, " + name
}

func main() {
	fmt.Println(greeting("tree"))
}
EOF_TREE_MAIN
cat > "$repo/main_test.go" <<'EOF_TREE_TEST'
package main

import "testing"

func TestGreeting(t *testing.T) {
	if greeting("x") == "" {
		t.Fatal("empty")
	}
}
EOF_TREE_TEST
(
  cd "$repo"
  export GIT_CONFIG_GLOBAL=/dev/null
  git init -q -b main
  git add -A
  git -c user.name=fixture -c user.email=fixture@localhost commit -q -m fixture
)
# The edit the tree has to find: greeting changed after the last commit.
sed -i '' 's/"hello, "/"hi, "/' "$repo/main.go"
(
  cd "$repo"
  env "${nvim_env[@]}" \
    XDG_CONFIG_HOME="$config_home" \
    GOCACHE="$work/go-cache" \
    GOPATH="$work/go-path" \
    GOMODCACHE="$work/go-mod-cache" \
    GOPROXY="http://127.0.0.1:1" \
    nvim --headless -i NONE -u "$config_dir/init.lua" \
      --cmd "lua vim.g.fzf_lua_server='verify'" \
      "$repo/main.go" -l "$tests/change_tree_smoke.lua"
)

step "Navigation"
module="$work/nav"
mkdir -p "$module"
cat > "$module/go.mod" <<'EOF_NAV_MOD'
module example.com/nav

go 1.23
EOF_NAV_MOD
cat > "$module/main.go" <<'EOF_NAV_MAIN'
package main

import "fmt"

// Order is a purchase.
type Order struct {
	ID    int
	Total int
}

// greeting builds a greeting.
// It has two comment lines.
func greeting(name string) string {
	return "hello, " + name
}

type Service struct{ prefix string }

func (s *Service) Describe(o Order) string {
	label := fmt.Sprintf("%d", o.Total)
	format := func() string {
		return s.prefix + label
	}
	return format()
}

// Store keeps orders.
type Store interface {
	Save(o Order) error
}

type memoryStore struct{}

// Save keeps the order in memory.
func (memoryStore) Save(o Order) error { return nil }

func persist(s Store, o Order) error {
	return s.Save(o)
}

type Notifier interface {
	Notify(text string)
}

type emailNotifier struct{}

func (emailNotifier) Notify(text string) {}

type smsNotifier struct{}

func (smsNotifier) Notify(text string) {}

func main() {
	var o Order
	fmt.Println(greeting("x"), (&Service{}).Describe(o))
	_ = persist(memoryStore{}, o)
	var n Notifier = emailNotifier{}
	n.Notify("hi")
	_ = smsNotifier{}
}
EOF_NAV_MAIN
cat > "$module/store_mock.go" <<'EOF_NAV_MOCK'
// Code generated by MockGen. DO NOT EDIT.

package main

// MockStore is a mock of the Store interface.
type MockStore struct{}

func (MockStore) Save(o Order) error { return nil }
EOF_NAV_MOCK
module="$(cd "$module" && pwd -P)"
(
  cd "$module"
  env "${nvim_env[@]}" \
    XDG_CONFIG_HOME="$config_home" \
    GOCACHE="$work/go-cache" \
    GOPATH="$work/go-path" \
    GOMODCACHE="$work/go-mod-cache" \
    GOPROXY=off \
    nvim --headless -i NONE -u "$config_dir/init.lua" \
      --cmd "lua vim.g.fzf_lua_server='verify'" \
      "$module/main.go" -l "$tests/nav_smoke.lua"
)

step "SQL and TODO"
(
  cd "$work"
  env "${nvim_env[@]}" \
    XDG_CONFIG_HOME="$config_home" \
    nvim --headless -i NONE -u "$config_dir/init.lua" \
      --cmd "lua vim.g.fzf_lua_server='verify'" \
      -l "$tests/sql_todo_smoke.lua"
)

step "Rename"
module="$work/rename"
mkdir -p "$module/store" "$module/service"
cat > "$module/go.mod" <<'EOF_RENAME_MOD'
module example.com/app

go 1.23
EOF_RENAME_MOD
cat > "$module/store/store.go" <<'EOF_RENAME_STORE'
package store

type Store struct{}

func (s *Store) Save(name string) error {
	return nil
}
EOF_RENAME_STORE
cat > "$module/service/service.go" <<'EOF_RENAME_SERVICE'
package service

import "example.com/app/store"

type Service struct{ st *store.Store }

func (s Service) Run() error {
	return s.st.Save("x")
}
EOF_RENAME_SERVICE
cat > "$module/main.go" <<'EOF_RENAME_MAIN'
package main

import (
	"example.com/app/service"
	"example.com/app/store"
)

func main() {
	_ = (&store.Store{}).Save("y")
	_ = service.Service{}.Run()
}
EOF_RENAME_MAIN
echo '# notes' > "$module/store/README.md"
module="$(cd "$module" && pwd -P)"
(
  cd "$module"
  env "${nvim_env[@]}" \
    XDG_CONFIG_HOME="$config_home" \
    GOCACHE="$work/go-cache" \
    GOPATH="$work/go-path" \
    GOMODCACHE="$work/go-mod-cache" \
    GOPROXY=off \
    NVIM_RENAME_ROOT="$module" \
    NVIM_RENAME_EXTRA=README.md \
    nvim --headless -i NONE -u "$config_dir/init.lua" \
      --cmd "lua vim.g.fzf_lua_server='verify'" \
      "$module/store/store.go" -l "$tests/rename_smoke.lua"
)

printf '\nVERIFY_OK\n'
