# Counteracts /etc/profile.d/bash-prompt-wsl.sh (fedoraremix, unpackaged),
# which EXPORTS PS1. An exported PS1 leaks into child-process environments —
# notably the login-shell environment probe of VS-Code-family remote servers
# (Antigravity), which then injects it into every terminal. Terminals that
# inherit a PS1 skip the distro prompt setup (/etc/bashrc and
# bash-color-prompt.sh only apply when PS1 is bash's untouched default) and
# end up with the raw "bash-5.2$" prompt.
# This runs last in /etc/profile.d (zzz prefix): keep the value for the shell
# that displays it, drop the export flag; in non-interactive shells (which
# never display a prompt) drop PS1 entirely.
if [ -n "${BASH_VERSION:-}" ]; then
    case $- in
        *i*) export -n PS1 2>/dev/null ;;
        *)   unset PS1 ;;
    esac
fi
