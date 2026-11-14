#!/bin/zsh
# Проверки go/go-tools: выбор инструментов Go под установленный go.
#
# Два случая. go из Homebrew — инструменты из PATH, файл для nvim с их
# путями. go чужой — копия GOROOT (клон APFS, мгновенно) первой в PATH и
# GOPROXY на каталог с модулем example.com/tool в трёх версиях: старая,
# ровно под установленный Go и под Go новее; скрипт должен выбрать среднюю,
# собрать её тем же go, записать файл, при повторе ничего не пересобирать.
# Кеши Go — временные, GOFLAGS=-mod=vendor в окружении не должен мешать.

emulate -L zsh
setopt pipe_fail err_exit
autoload -Uz is-at-least

here=${0:A:h}
tools=$here/go-tools
work=$(cd "$(mktemp -d)" && pwd -P)
# (the module cache is read-only: writable first)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

same() { [[ "$2" == "$3" ]] || { print -u2 -r -- "$1: got '$2', want '$3'"; exit 1 }; }
has()  { [[ "$2" == *"$3"* ]] || { print -u2 -r -- "$1: no '$3' in: $2"; exit 1 }; }
step() { print -r -- $'\n== '"$1"' =='; }

step "Versions"
GOTOOLCHAIN=local go version
have=$(GOTOOLCHAIN=local go env GOVERSION); have=${have#go}
minor=${${have#1.}%%.*}
goroot=$(GOTOOLCHAIN=local go env GOROOT)
brew_prefix=$(brew --prefix)

# ------------------------------------------------------------
step "go from Homebrew: the tools of PATH"
# ------------------------------------------------------------
if [[ ${goroot:A} == ${brew_prefix:A}/Cellar/go/* ]]; then
  out=$(GO_TOOLS_FILE=$work/brew.env GO_TOOLS_DIR=$work/brew-tools $tools)
  has "brew: the source of go" "$out" "из Homebrew"
  has "brew: the file is written" "$out" "записан"
  env_file=$(<$work/brew.env)
  has "brew: GO_FROM" "$env_file" "GO_FROM=brew"
  has "brew: GO_VERSION" "$env_file" "GO_VERSION=go$have"
  has "brew: gopls of PATH" "$env_file" "GOPLS=${commands[gopls]}"
  has "brew: dlv of PATH" "$env_file" "DLV=${commands[dlv]}"
  GO_TOOLS_FILE=$work/brew.env GO_TOOLS_DIR=$work/brew-tools $tools --check >/dev/null
  out=$(GO_TOOLS_FILE=$work/brew.env GO_TOOLS_DIR=$work/brew-tools $tools)
  has "brew: a second run changes nothing" "$out" "без изменений"
  echo "GO_TOOLS_BREW_OK"
else
  echo "GO_TOOLS_BREW_SKIPPED (go is not from Homebrew here)"
fi

# ------------------------------------------------------------
step "another go: the tools built by it"
# ------------------------------------------------------------
# A clone of GOROOT outside the Homebrew cellar stands for a corporate Go.
cp -Rc $goroot $work/goroot 2>/dev/null || cp -R $goroot $work/goroot
[[ -x $work/goroot/bin/go ]] || { echo "no go in the clone" >&2; exit 1 }

# A proxy in a directory: example.com/tool in four versions. The go line
# of each is what the choice looks at.
proxy=$work/proxy/example.com/tool/@v
mkdir -p $proxy
add_version() {
  local v=$1 goline=$2 stage
  stage=$work/stage/example.com/tool@$v   # (a second statement: $v is set by now)
  mkdir -p $stage
  printf 'module example.com/tool\n\ngo %s\n' $goline > $stage/go.mod
  printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("tool %s") }\n' $v > $stage/main.go
  cp $stage/go.mod $proxy/$v.mod
  printf '{"Version":"%s","Time":"2026-01-01T00:00:00Z"}\n' $v > $proxy/$v.info
  (cd $work/stage && zip -qr $proxy/$v.zip example.com/tool@$v)
  print -r -- $v >> $proxy/list
}
add_version v0.1.0 1.20
add_version v0.2.0 1.$minor
add_version v0.3.0 1.$((minor + 1))
add_version v0.4.0-rc.1 1.20

typeset -a corp
corp=(
  env "PATH=$work/goroot/bin:$PATH"
  GO_TOOLS_BREW_PREFIX=$brew_prefix
  GO_TOOLS_FILE=$work/corp.env GO_TOOLS_DIR=$work/corp-tools
  GO_TOOLS_SPEC="hello example.com/tool example.com/tool"
  GOPROXY=file://$work/proxy GOSUMDB=off GOFLAGS=-mod=vendor
  GOMODCACHE=$work/modcache GOCACHE=$work/gocache GOPATH=$work/gopath
)
same "the clone is the go of PATH" "$($corp sh -c 'command -v go')" "$work/goroot/bin/go"

out=$($corp $tools --dry-run)
has "dry-run: another go" "$out" "не из Homebrew"
has "dry-run: the version under the installed go" "$out" "(dry-run) go install example.com/tool@v0.2.0"
[[ ! -e $work/corp-tools/bin/hello ]] || { echo "dry-run installed" >&2; exit 1 }
[[ ! -e $work/corp.env ]] || { echo "dry-run wrote the file" >&2; exit 1 }

out=$($corp $tools)
has "install: go install of the chosen version" "$out" "go install example.com/tool@v0.2.0"
[[ -x $work/corp-tools/bin/hello ]] || { echo "the tool is not built: $out" >&2; ls -R $work/corp-tools >&2 2>/dev/null; exit 1 }
same "the built tool runs" "$($work/corp-tools/bin/hello)" "tool v0.2.0"
env_file=$(<$work/corp.env)
has "env: GO_FROM" "$env_file" "GO_FROM=other"
has "env: GO_VERSION" "$env_file" "GO_VERSION=go$have"
has "env: the tool by its path" "$env_file" "HELLO=$work/corp-tools/bin/hello"
same "built by the go of PATH" "$(go version -m $work/corp-tools/bin/hello | head -n 1 | sed 's/.*: //')" "go$have"

out=$($corp $tools --check)
has "check: the tool" "$out" "hello: $work/corp-tools/bin/hello"
has "check: the file" "$out" "соответствует"
out=$($corp $tools)
[[ $out != *"go install"* ]] || { echo "a second run rebuilt the tool: $out" >&2; exit 1 }
has "a second run keeps the file" "$out" "без изменений"

# A module nobody can build with this go: the run fails and says so.
mkdir -p $work/proxy/example.com/tooold/@v
printf 'module example.com/tooold\n\ngo 1.%d\n' $((minor + 2)) > $work/proxy/example.com/tooold/@v/v1.0.0.mod
printf '{"Version":"v1.0.0","Time":"2026-01-01T00:00:00Z"}\n' > $work/proxy/example.com/tooold/@v/v1.0.0.info
print -r -- v1.0.0 > $work/proxy/example.com/tooold/@v/list
if out=$($corp GO_TOOLS_SPEC="old example.com/tooold example.com/tooold" GO_TOOLS_FILE=$work/old.env $tools 2>&1); then
  echo "a module for a newer go was installed: $out" >&2; exit 1
fi
has "no version fits: said" "$out" "не выбрать версию example.com/tooold"
[[ ! -e $work/old.env ]] || { echo "the file was written after a failure" >&2; exit 1 }
echo "GO_TOOLS_OTHER_OK"

echo
echo "GO_TOOLS_VERIFY_OK"
