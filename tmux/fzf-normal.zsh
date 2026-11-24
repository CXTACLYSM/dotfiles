# Нормальный режим для fzf в попапах tmux — тот же, что у окон поиска
# nvim (nvim/lua/picker_mode.lua): Esc выходит из набора в режим с «·N» в
# приглашении, где j / k ходят по списку, g — первая строка, l или Enter
# принимает, q или Esc закрывает, i возвращает набор; набранный запрос
# остаётся. Состояние живёт в приглашении (fzf сам ничего не помнит), каждая
# клавиша — transform, который читает $FZF_PROMPT, так что без задержек.
# Списки открываются сразу в нормальном режиме.
#
#   source ~/.config/dotfiles/tmux/fzf-normal.zsh
#   fzf --prompt "$(fzf_normal_prompt вид)" "${(@)fzf_normal_binds}" …
#
# Приглашение набора — «вид › », нормального режима — «вид ·N › ».

fzf_normal_mark='·N › '

fzf_normal_prompt() {
  print -r -- "${1:+$1 }$fzf_normal_mark"
}

# transform: одна ветка в нормальном режиме, другая при наборе.
fzf_normal_either() {
  print -r -- "transform:case \"\$FZF_PROMPT\" in *\"$fzf_normal_mark\") $1 ;; *) $2 ;; esac"
}

fzf_normal_to_normal='p="${FZF_PROMPT%› }"; p="${p% }"; echo "change-prompt(${p:+$p }'$fzf_normal_mark')"'
fzf_normal_to_typing='p="${FZF_PROMPT%'$fzf_normal_mark'}"; p="${p% }"; echo "change-prompt(${p:+$p }› )"'

typeset -ga fzf_normal_binds
fzf_normal_binds=(
  --bind "esc:$(fzf_normal_either 'echo abort' "$fzf_normal_to_normal")"
  --bind "i:$(fzf_normal_either "$fzf_normal_to_typing" 'echo "put(i)"')"
)
for fzf_normal_key fzf_normal_action in j down k up g first q abort l accept h ''; do
  fzf_normal_binds+=(--bind "$fzf_normal_key:$(fzf_normal_either "echo \"$fzf_normal_action\"" "echo \"put($fzf_normal_key)\"")")
done
unset fzf_normal_key fzf_normal_action
