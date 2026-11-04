#!/bin/sh


terminate() {
    printf "${RED}${BOLD}%s${NC}\n" "ERROR: $1"
  echo
    exit 1
}

usage() {
    echo "Usage: (as root) $0 [PATH_TO_DOCKERD.JSON]"
    echo
    echo "This script will modify the logger in the dockerd.json file to 'local'"
    echo
}

readonly RED='\e[31m' # Red color
readonly NC='\e[m' # No color / reset
readonly BOLD='\e[1m' # Bold font
DOCKERD_FILE=$1

# Test if script has root privileges, exit otherwise
id=$(id -u)
if [ "${id}" -ne 0 ]; then
  usage
  terminate "You need to be root to run this script"
fi

# Check if the dockerd.json file path is provided as an argument
if [ -z "$1" ]; then
  usage
  terminate "no path to dockerd.json provided"
fi

# Check if dockerd.json file exists
if [ ! -f "${DOCKERD_FILE}" ]; then
  usage
  terminate "no dockerd.json found at provided location"
fi

# Output the original JSON file
echo "Original dockerd.json file:"
echo "----------------------------"
echo
jq . "${DOCKERD_FILE}"
echo

# Use jq to safely update the log-driver and merge new log-opts

# add iptables=true
#jq '
#  .["group"] = "administrators" |
#  .["log-driver"] = "local" |
#  .["log-opts"] = {
#    "max-file": "5",
#    "max-size": "20m"
#  } |
#  .["iptables"] = true
#' "$DOCKERD_FILE" > "$DOCKERD_FILE.tmp" && mv "$DOCKERD_FILE.tmp" "$DOCKERD_FILE"

# Docker 27+ dockerd no longer auto-discovers docker-proxy's location (via PATH or a hardcoded default) when
# userland-proxy is enabled (the default) - it now fails outright with "userland-proxy is enabled, but
# userland-proxy-path is not set" unless the config file says where it is. Synology installs it outside dockerd's
# built-in search paths, so this has to be set explicitly; derived from DOCKERD_FILE's own location rather than
# passed in, since it's always "<pkg dir>/etc/dockerd.json" next to "<pkg dir>/target/usr/bin/docker-proxy".
DOCKER_PROXY_BIN="$(dirname "$(dirname "${DOCKERD_FILE}")")/target/usr/bin/docker-proxy"

jq --arg proxy_path "${DOCKER_PROXY_BIN}" '
  .["group"] = "administrators" |
  .["log-driver"] = "local" |
  .["log-opts"] = {
    "max-file": "5",
    "max-size": "20m"
  } |
  .["userland-proxy-path"] = $proxy_path
' "$DOCKERD_FILE" > "$DOCKERD_FILE.tmp" && mv "$DOCKERD_FILE.tmp" "$DOCKERD_FILE"

# Output the new JSON file
echo "Updated dockerd.json file:"
echo "----------------------------"
echo
jq . "${DOCKERD_FILE}"
echo

exit 0
