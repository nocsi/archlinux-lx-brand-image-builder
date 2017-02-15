#!/bin/bash

set -e

DATE=$(date +"%Y.%m.%d")

# remove any existing root filesystem from the repo history
# git filter-branch -f --tree-filter 'rm -f arch-rootfs*' --prune-empty master

# build an updated root filesystem
sudo ./mkimage-arch.sh ${DATE}

# update the Dockerfile with the latest build "number"
# sed "s/TAG/${DATE}/" Dockerfile.tpl > Dockerfile

# commit the changes
# git add Dockerfile && git commit -m "Update Dockerfile (${DATE})"
# git add arch-rootfs-${DATE}.tar.xz && git commit -m "Update rootfs (${DATE})"
