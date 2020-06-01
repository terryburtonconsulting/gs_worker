#!/bin/sh

# Keepalive is disabled: Starman's pre-fork workers block in keepalive wait,
# starving healthchecks and new connections. Not fixable without architectural
# changes to Starman's accept loop.

trap exit TERM;

WORKERS_ARG="--workers=${WORKERS:-4}"
[ -n "$MAX_REQUESTS" ] && MAX_REQUESTS_ARG="--max-requests=$MAX_REQUESTS"

exec "$@" $WORKERS_ARG $MAX_REQUESTS_ARG --disable-keepalive
