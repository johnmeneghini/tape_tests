#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2024 John Meneghini <jmeneghi@redhat.com> All rights reserved.
#

if [ $# -lt 2 -o $# -gt 2 ]
then
  echo ""
  echo " usage: ${0##*/} <sg_device> <sleep_seconds>"
  echo ""
  echo "  example:"
  echo ""
  echo "      ${0##*/} /dev/sg1 0"
  echo "      ${0##*/} dev/sg2 10"
  echo ""
  exit
fi

DEV="$1"
SLEEP="$2"

if [ ! -c $DEV ]; then
  echo "  Invalid argument: ${DEV}" >&2
  exit 1
fi

sleep $SLEEP
echo "--- sg_reset --target $DEV"
sg_reset --target $DEV

