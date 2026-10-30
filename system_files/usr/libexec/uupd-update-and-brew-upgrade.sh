#!/usr/bin/bash

BREW_UNIT=brew-upgrade-manual.service

/usr/libexec/uupd-update
uupd_status=$?

if [[ -O /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    journalctl --user -u "${BREW_UNIT}" -f -o cat --synchronize-on-exit=yes --lines=0 &
    journal_pid=$!
    trap 'kill -TERM "${journal_pid}" 2>/dev/null; wait "${journal_pid}"' EXIT
    systemctl --user start --wait "${BREW_UNIT}" || exit
fi

exit "${uupd_status}"
