# Всё ПО окружения. install.sh ставит его через `brew bundle`; вручную:
#   brew bundle --file Brewfile

# Терминал и шелл
brew "tmux"
brew "zsh-autosuggestions"
brew "zsh-syntax-highlighting"
brew "fzf"
brew "fd"
brew "ripgrep"
brew "jq"

# Редактор и Go
brew "neovim"
brew "tree-sitter-cli" # компиляция парсеров Tree-sitter (Go, SQL) для nvim-treesitter
brew "go"
brew "gopls"
brew "gofumpt" # форматирование Go при сохранении (conform.nvim)
brew "delve"
brew "node" # движок диаграмм mermaid в markdown (ascii-mermaid) — локальный скрипт, без npm

# git
brew "git-delta"
brew "lazygit"
brew "difftastic"

# Запросы к сервисам: gRPC и HTTP. Оба под MIT, в сеть ходят только к
# серверу запроса: ни телеметрии, ни проверки обновлений. grpcurl берёт
# схему с сервера (reflection) или из -proto; xh — HTTPie-синтаксис,
# --offline собирает запрос без отправки, --curl печатает его как curl.
brew "grpcurl"
brew "xh"

# iTerm2: если он уже стоит не из brew, cask пропускается.
cask "iterm2" unless File.exist?("/Applications/iTerm.app")
# Шрифт с глифами Nerd Font: значки файлов в nvim (дерево слева, Space f).
# Профиль iTerm2 «Go Backend» ссылается на него.
cask "font-jetbrains-mono-nerd-font"
