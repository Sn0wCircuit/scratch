#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Catppuccin Mocha palette (truecolor)
c_blue='\[\e[38;2;137;180;250m\]'   # icon
c_dim='\[\e[38;2;108;112;134m\]'    # directory (muted)
c_mauve='\[\e[38;2;203;166;247m\]'  # arrow
c_text='\[\e[38;2;166;227;161m\]'   # typed command (green)
c_reset='\[\e[0m\]'

PS1="${c_blue}󰣇 ${c_dim}\w ${c_mauve}❯ ${c_text}"

# Reset color after pressing Enter so command output isn't tinted
PS0='\e[0m'

export EDITOR=micro
