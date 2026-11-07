#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Theme-following ANSI colors
c_reset='\[\e[0m\]'
c_blue='\[\e[34m\]'        # icon, arrow
c_dim='\[\e[90m\]'         # directory (muted)
c_input='\[\e[1;34m\]'     # typed command (bold blue)

PS1="${c_reset}${c_blue}󰣇 ${c_dim}\w ${c_blue}❯ ${c_input}"

# Reset color and bold after pressing Enter so command output isn't affected
PS0='\e[0m'

export EDITOR=micro
