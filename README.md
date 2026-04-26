# rauthy-pam-nss-arch

Modified https://github.com/sebadob/rauthy-pam-nss to inlcude Arch. suport for Debian and Rhel have not been tested, Only Arch has been tested and verified to work.

## Features
- supports both Rauthy managed users and local ones (including homed)
- parse config variables from file to allow incorporation in other scripts while retaining the ability to run stand-alone
  - see the example-config
## Useage
1. clone repo ``git clone https://github.com/deathblade666/rauthy-pam-nss-arch``
2. run the install nss (Must be run as root) ``sudo ./install.sh nss`` then follow the prompts\
3. install PAM module ``sudo ./install.sh pam``
