#!/usr/bin/env bash
# Регрессионные проверки nvim-конфига: синтаксис и загрузка модулей, чистые
# Lua-тесты, AST-хелпер, закреплённые плагины и парсеры, полный старт
# init.lua, gopls на фикстурах (module, standalone, политика toolchain),
# дерево правок на git-фикстуре, навигация (подсмотр, реализации, строка
# «где я», свёртки, поля структур в K, переход proto ↔ Go), SQL-запросы
# и TODO, категории поиска, дерево файлов, закреплённые файлы,
# переименование, оформление markdown. Плагины, парсеры и хелпер ставит
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

for command in nvim go gopls git jq rg fd; do
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
printf '{"mode":"declarations","root":"%s","paths":["sample.go"]}' "$work/helper-fixture" \
  | "$helper" > "$work/declarations.json"
jq -e '
  .ok and ([.declarations[] | "\(.kind) \(.name) \(.line)"]
    == ["const SchemaBootstrap 4", "const SchemaTaskState 5", "var ErrNotFound 9",
        "var ErrInvalidState 10", "struct State 13"])
' "$work/declarations.json" >/dev/null
echo "GO_INDEX_HELPER_OK"

step "Pinned plugins and parsers"
env "${nvim_env[@]}" XDG_CONFIG_HOME="$config_home" NVIM_BOOTSTRAP_CHECK_ONLY=1 \
  nvim --clean --headless -i NONE -u NONE -l "$config_dir/tools/bootstrap.lua"

step "Full init"
env "${nvim_env[@]}" XDG_CONFIG_HOME="$config_home" \
  nvim --headless -i NONE -u "$config_dir/init.lua" \
    --cmd "lua vim.g.fzf_lua_server='verify'" \
    -l "$tests/full_init_smoke.lua"

step "Markdown"
env "${nvim_env[@]}" XDG_CONFIG_HOME="$config_home" \
  nvim --headless -i NONE -u "$config_dir/init.lua" \
    --cmd "lua vim.g.fzf_lua_server='verify'" \
    -l "$tests/markdown_smoke.lua"

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

step "Hover"
module="$work/hover"
mkdir -p "$module/model" "$module/app"
cat > "$module/go.mod" <<'EOF_HOVER_MOD'
module example.com/hov

go 1.23
EOF_HOVER_MOD
cat > "$module/model/model.go" <<'EOF_HOVER_MODEL'
package model

import "time"

// Customer places orders.
type Customer struct {
	ID    int64
	Name  string
	Email string // contact address
}

// Address is where an order goes.
type Address struct {
	City   string
	Street string
}

// Item is one line of an order.
type Item struct {
	SKU   string
	Count int
	Price Money
}

// Notifier tells the customer.
type Notifier interface {
	Notify(o Order) error
}

// Order is a purchase.
type Order struct {
	ID       int64
	Customer *Customer
	Items    []Item
	Delivery Address `json:"delivery"`
	Meta     map[string]Item
	Created  time.Time
	Parent   *Order
	Notify   Notifier
	Status
}

type (
	Money struct {
		Amount   int64
		Currency string
	}

	Status struct {
		Code int
	}
)
EOF_HOVER_MODEL
cat > "$module/model/order.pb.go" <<'EOF_HOVER_PB'
// Code generated by protoc-gen-go. DO NOT EDIT.

package model

type CreateOrderRequest struct {
	state         int32
	// Who pays.
	CustomerId    int64                      `protobuf:"varint,1,opt,name=customer_id,json=customerId,proto3" json:"customer_id,omitempty"`
	Lines         []*CreateOrderRequest_Line `protobuf:"bytes,2,rep,name=lines,proto3" json:"lines,omitempty"`
	unknownFields []byte
	sizeCache     int32
}

type CreateOrderRequest_Line struct {
	state         int32
	Sku           string `protobuf:"bytes,1,opt,name=sku,proto3" json:"sku,omitempty"`
	unknownFields []byte
	sizeCache     int32
}
EOF_HOVER_PB
cat > "$module/app/main.go" <<'EOF_HOVER_MAIN'
package main

import (
	"fmt"

	"example.com/hov/model"
)

func handle(o *model.Order, items []model.Item) {
	c := o.Customer
	count := len(items)
	fmt.Println(o.ID, c.Name, count, o.Delivery.City)
}

func main() {
	var o model.Order
	f := handle
	f(&o, nil)
	handle(&o, nil)
}

func create(req *model.CreateOrderRequest) int64 {
	return req.CustomerId
}
EOF_HOVER_MAIN
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
      "$module/app/main.go" -l "$tests/go_hover_smoke.lua"
)

step "Proto"
module="$work/proto"
mkdir -p "$module/api/order/v1" "$module/pkg/api/order/v1" "$module/internal/app/order/mocks" \
  "$module/internal/clients"
cat > "$module/go.mod" <<'EOF_PROTO_MOD'
module example.com/shop

go 1.23
EOF_PROTO_MOD
cat > "$module/api/order/v1/order.proto" <<'EOF_PROTO'
syntax = "proto3";

package order.v1;

option go_package = "example.com/shop/pkg/api/order/v1;orderv1";

// OrderService manages orders.
service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse);
  rpc GetOrder(GetOrderRequest) returns (Order);
}

message Order {
  message Item {
    string sku = 1;
    int32 count = 2;
  }
  int64 id = 1;
  repeated Item items = 2;
  Status status = 3;
}

enum Status {
  STATUS_UNSPECIFIED = 0;
  STATUS_ACTIVE = 1;
}

message CreateOrderRequest {
  int64 user_id = 1;
}

message CreateOrderResponse {
  Order order = 1;
}

message GetOrderRequest {
  int64 id = 1;
}
EOF_PROTO
cat > "$module/pkg/api/order/v1/order.pb.go" <<'EOF_PROTO_PB'
// Code generated by protoc-gen-go. DO NOT EDIT.
// versions:
// 	protoc-gen-go v1.34.2
// source: order/v1/order.proto

package orderv1

type Status int32

const (
	Status_STATUS_UNSPECIFIED Status = 0
	Status_STATUS_ACTIVE      Status = 1
)

type Order struct {
	Id     int64
	Items  []*Order_Item
	Status Status
}

func (x *Order) GetId() int64 {
	if x != nil {
		return x.Id
	}
	return 0
}

type Order_Item struct {
	Sku   string
	Count int32
}

type CreateOrderRequest struct {
	UserId int64
}

func (x *CreateOrderRequest) GetUserId() int64 {
	if x != nil {
		return x.UserId
	}
	return 0
}

type CreateOrderResponse struct {
	Order *Order
}

type GetOrderRequest struct {
	Id int64
}
EOF_PROTO_PB
cat > "$module/pkg/api/order/v1/order_grpc.pb.go" <<'EOF_PROTO_GRPC'
// Code generated by protoc-gen-go-grpc. DO NOT EDIT.
// versions:
// - protoc-gen-go-grpc v1.5.1
// source: order/v1/order.proto

package orderv1

import "context"

type OrderServiceClient interface {
	CreateOrder(ctx context.Context, in *CreateOrderRequest) (*CreateOrderResponse, error)
	GetOrder(ctx context.Context, in *GetOrderRequest) (*Order, error)
}

type orderServiceClient struct{}

func (c *orderServiceClient) CreateOrder(ctx context.Context, in *CreateOrderRequest) (*CreateOrderResponse, error) {
	return nil, nil
}

func (c *orderServiceClient) GetOrder(ctx context.Context, in *GetOrderRequest) (*Order, error) {
	return nil, nil
}

type OrderServiceServer interface {
	CreateOrder(context.Context, *CreateOrderRequest) (*CreateOrderResponse, error)
	GetOrder(context.Context, *GetOrderRequest) (*Order, error)
	mustEmbedUnimplementedOrderServiceServer()
}

type UnimplementedOrderServiceServer struct{}

func (UnimplementedOrderServiceServer) CreateOrder(context.Context, *CreateOrderRequest) (*CreateOrderResponse, error) {
	return nil, nil
}

func (UnimplementedOrderServiceServer) GetOrder(context.Context, *GetOrderRequest) (*Order, error) {
	return nil, nil
}

func (UnimplementedOrderServiceServer) mustEmbedUnimplementedOrderServiceServer() {}
EOF_PROTO_GRPC
cat > "$module/internal/app/order/handler.go" <<'EOF_PROTO_HANDLER'
package order

import (
	"context"

	orderv1 "example.com/shop/pkg/api/order/v1"
)

// Implementation serves OrderService.
type Implementation struct {
	orderv1.UnimplementedOrderServiceServer
}

func (i *Implementation) CreateOrder(ctx context.Context, req *orderv1.CreateOrderRequest) (*orderv1.CreateOrderResponse, error) {
	_ = req.GetUserId()
	return &orderv1.CreateOrderResponse{Order: &orderv1.Order{Status: orderv1.Status_STATUS_ACTIVE}}, nil
}
EOF_PROTO_HANDLER
cat > "$module/internal/app/order/mocks/server_mock.go" <<'EOF_PROTO_MOCK'
package mocks

import (
	"context"

	orderv1 "example.com/shop/pkg/api/order/v1"
)

type ServerMock struct {
	orderv1.UnimplementedOrderServiceServer
}

func (ServerMock) CreateOrder(context.Context, *orderv1.CreateOrderRequest) (*orderv1.CreateOrderResponse, error) {
	return nil, nil
}
EOF_PROTO_MOCK
cat > "$module/internal/clients/order.go" <<'EOF_PROTO_CLIENT'
package clients

import (
	"context"

	orderv1 "example.com/shop/pkg/api/order/v1"
)

func Create(c orderv1.OrderServiceClient) error {
	_, err := c.CreateOrder(context.Background(), &orderv1.CreateOrderRequest{UserId: 1})
	return err
}
EOF_PROTO_CLIENT
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
      "$module/internal/app/order/handler.go" -l "$tests/go_proto_smoke.lua"
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

step "Search categories"
module="$work/categories"
mkdir -p "$module/api/order/v1" "$module/pkg/api/order/v1" "$module/cmd/app" \
  "$module/internal/order/mocks" "$module/internal/order/testdata" \
  "$module/internal/order/repo" "$module/internal/orders"
cat > "$module/go.mod" <<'EOF_CAT_MOD'
module example.com/cats

go 1.23
EOF_CAT_MOD
echo '*.env' > "$module/.gitignore"
echo 'DSN=postgres://local' > "$module/internal/order/local.env"
cat > "$module/api/order/v1/order.proto" <<'EOF_CAT_PROTO'
syntax = "proto3";

package order.v1;

service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderRequest);
}

message CreateOrderRequest {
  string id = 1;
}
EOF_CAT_PROTO
cat > "$module/pkg/api/order/v1/order.pb.go" <<'EOF_CAT_PB'
// Code generated by protoc-gen-go. DO NOT EDIT.

package orderv1

type CreateOrderRequest struct {
	Id string
}

func (x *CreateOrderRequest) GetId() string { return x.Id }
EOF_CAT_PB
cat > "$module/pkg/api/order/v1/order_grpc.pb.go" <<'EOF_CAT_GRPC'
// Code generated by protoc-gen-go-grpc. DO NOT EDIT.

package orderv1

type OrderServiceServer interface {
	CreateOrder(*CreateOrderRequest) (*CreateOrderRequest, error)
}
EOF_CAT_GRPC
cat > "$module/pkg/api/order/v1/order.pb.validate.go" <<'EOF_CAT_VALIDATE'
// Code generated by protoc-gen-validate. DO NOT EDIT.

package orderv1

type FieldValidationError struct{}
EOF_CAT_VALIDATE
cat > "$module/internal/order/service.go" <<'EOF_CAT_SERVICE'
package order

type Service struct{}

func (s *Service) CreateOrder(id string) error { return nil }
EOF_CAT_SERVICE
cat > "$module/internal/order/service_test.go" <<'EOF_CAT_TEST'
package order

import "testing"

func TestCreateOrder(t *testing.T) {
	if (&Service{}).CreateOrder("x") != nil {
		t.Fatal("error")
	}
}
EOF_CAT_TEST
cat > "$module/internal/order/mocks/store_mock.go" <<'EOF_CAT_MOCK'
// Code generated by MockGen. DO NOT EDIT.

package mocks

type MockStore struct{}

func (MockStore) CreateOrder(id string) error { return nil }
EOF_CAT_MOCK
echo '{"id": "x"}' > "$module/internal/order/testdata/golden.json"
cat > "$module/internal/order/repo/pg.go" <<'EOF_CAT_REPO'
package repo

func SaveOrder(id string) error { return nil }
EOF_CAT_REPO
cat > "$module/internal/orders/batch.go" <<'EOF_CAT_BATCH'
package orders

func CreateOrderBatch(ids []string) error { return nil }
EOF_CAT_BATCH
cat > "$module/cmd/app/main.go" <<'EOF_CAT_MAIN'
package main

func main() {}
EOF_CAT_MAIN
module="$(cd "$module" && pwd -P)"
# rg and fd read .gitignore inside a git repository only.
(cd "$module" && GIT_CONFIG_GLOBAL=/dev/null git init -q -b main)
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
      "$module/internal/order/service.go" -l "$tests/categories_smoke.lua"
)

step "File tree"
module="$work/file-tree"
mkdir -p "$module/api/order/v1" "$module/cmd/app" "$module/internal/order/repo" \
  "$module/internal/user" "$module/pkg/api/order/v1"
printf 'module example.com/tree\n\ngo 1.23\n' > "$module/go.mod"
echo '# tree' > "$module/README.md"
echo 'syntax = "proto3";' > "$module/api/order/v1/order.proto"
printf 'package main\n\nfunc main() {}\n' > "$module/cmd/app/main.go"
printf 'package repo\n' > "$module/internal/order/repo/pg.go"
printf 'package order\n\nfunc Service() {}\n' > "$module/internal/order/service.go"
printf 'package order\n' > "$module/internal/order/service_test.go"
printf '// Package user keeps accounts. And more.\npackage user\n' > "$module/internal/user/user.go"
printf 'package v1\n' > "$module/pkg/api/order/v1/order.pb.go"
module="$(cd "$module" && pwd -P)"
# A real fzf runs in a terminal here: fzf-lua starts its own RPC server
# (in XDG_RUNTIME_DIR) for the keys that call Lua.
(
  cd "$module"
  env "${nvim_env[@]}" \
    XDG_CONFIG_HOME="$config_home" \
    nvim --headless -i NONE -u "$config_dir/init.lua" \
      "$module/README.md" -l "$tests/file_tree_smoke.lua"
  env "${nvim_env[@]}" \
    XDG_CONFIG_HOME="$config_home" \
    nvim --headless -i NONE -u "$config_dir/init.lua" \
      --cmd "lua vim.g.fzf_lua_server='verify'" \
      "$module/README.md" -l "$tests/pins_smoke.lua"
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
