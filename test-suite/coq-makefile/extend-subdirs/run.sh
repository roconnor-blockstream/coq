#!/usr/bin/env bash

#set -x
set -e

. ../template/init.sh

coq_makefile -f _CoqProject -o Makefile
make
exec test -f "subdir/done"
