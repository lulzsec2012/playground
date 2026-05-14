if [[ "$INSIDE_EMACS" = 'vterm' ]] && [[ -n ${EMACS_VTERM_PATH} ]] && [[ -f ${EMACS_VTERM_PATH}/etc/emacs-vterm-bash.sh ]]; then
    source ${EMACS_VTERM_PATH}/etc/emacs-vterm-bash.sh
fi
if [[ -n "$EAT_SHELL_INTEGRATION_DIR" ]]; then
    source "$EAT_SHELL_INTEGRATION_DIR/bash"
    PROMPT_COMMAND=("__eat_before_prompt_command __eat_prompt_command __eat_after_prompt_command")
fi
