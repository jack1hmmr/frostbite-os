if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" && "$(tty 2>/dev/null)" == "/dev/tty1" ]]; then
  exec /usr/local/bin/frostbite-session
fi
