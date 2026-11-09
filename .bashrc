#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='󰣇 \[\e[90m\]\w\[\e[0m\] ❯ '
export EDITOR=micro
fastfetch
