CONTAINER_IP="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
: "${CONTAINER_IP:=$(hostname -f)}"

if [ -n "$HOST_PORT" ] && [ "$HOST_PORT" != "2222" ]; then
    DISPLAY_IP="${CONTAINER_IP}/${HOST_PORT}"
else
    DISPLAY_IP="$CONTAINER_IP"
fi

case "$TERM" in
    *color | *-24bits | xterm-24bits) color_prompt=yes ;;
esac
if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@'"$DISPLAY_IP"'\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@'"$DISPLAY_IP"':\w\$ '
fi
unset color_prompt
case "$TERM" in xterm* | rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@$DISPLAY_IP: \w\a\]$PS1" ;;
esac
