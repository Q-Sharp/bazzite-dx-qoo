# Enroll the MOK key that signs the nct6687 kernel module (required once for Secure Boot)
enroll-nct6687-signing-key:
    #!/usr/bin/bash
    set -euo pipefail
    echo "This enrolls the MOK key that signs the nct6687 kernel module."
    echo "mokutil will ask you to set a one-time password."
    echo "On the next reboot, choose 'Enroll MOK' and enter that password."
    sudo mokutil --import /etc/pki/mok/MOK.der
