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
brew "delve"

# git
brew "git-delta"
brew "lazygit"
brew "difftastic"

# iTerm2: если он уже стоит не из brew, cask пропускается.
cask "iterm2" unless File.exist?("/Applications/iTerm.app")
