if [[ -z "${DISPLAY:-}" && "${XDG_VTNR:-1}" == "1" ]]; then
  exec /usr/local/bin/frostbite-session
fi
