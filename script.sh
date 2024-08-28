#!/bin/bash

# Needs "jq" locally, `sudo apt install jq`
# Needs "openssl" locally, `sudo apt install openssl`
# Needs "ssh" locally, `sudo apt install ssh`

# Needs "tar" on server
# Needs "rsync" on server

# -----------------------------------------------------------------------------
# To test this script you can use docker

## syntax=docker/dockerfile:1
#FROM ubuntu:latest
#
## install app dependencies
#RUN apt-get update && apt-get install -y jq openssl ssh
#
#CMD ["/mount"]
#WORKDIR /mount
#
## docker build -t test_image .
## docker run -it --mount type=bind,source="$(pwd)"/mount,target=/mount --name test_container test_image sh

# -----------------------------------------------------------------------------
#   Basic
# -----------------------------------------------------------------------------

# Change standard echo function
function echo() { builtin echo -e "$@"; }

# check if stdout is a terminal
if test -t 1; then

  # see if it supports colors
  ncolors=$(tput colors 2> /dev/null)

  if test -n "${ncolors}" && test $ncolors -ge 8; then
    # ANSI escape codes
    bold="\033[1m"
    underline="\033[4m"
    standout="\033[0m" 
    normal="\033[0m" 
    black="\033[30m"
    red="\033[31m"
    green="\033[32m"
    yellow="\033[1;33m"
    blue="\033[34m"
    magenta="\033[1;35m"
    cyan="\033[36m"
    white="\033[1;37m"
  fi
fi

SCRIPT_NAME="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")"


# -----------------------------------------------------------------------------
#   Dependencies
# -----------------------------------------------------------------------------

if [[ "$EUID" -ne "0" ]]; then
  echo "[${red}fail${standout}] Please run as root or with sudo."
  exit 1
fi

if ! command -v jq &> /dev/null ; then 
  echo "[${red}fail${standout}] The jq program must be installed."
  exit 1
fi

if ! command -v openssl &> /dev/null ; then 
  echo "[${red}fail${standout}] The openssl program must be installed."
  exit 1
fi

if ! command -v ssh &> /dev/null ; then 
  echo "[${red}fail${standout}] The ssh program must be installed."
  exit 1
fi


# -----------------------------------------------------------------------------
#   Functions
# -----------------------------------------------------------------------------

# usage: fingerprint [-i identity_file]
#                    [-p port]
#                    destination
function fingerprint() {
  local PORT=22
  local KEYFILE=""
  local DESTINATION=""
  while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
    -i | --identity_file )
      shift; KEYFILE="$1"
      ;;
    -p | --port )
      shift; PORT="$1"
      ;;
  esac; shift; done
  DESTINATION="$1"

  local OUTPUT=$({ { sleep 1; echo ""; } | script -q /dev/null -c "ssh -i ${KEYFILE} -p ${PORT} ${DESTINATION} exit ; " ; })
  if [[ "" == "${OUTPUT}" ]] ; then
    # You have already accepted the fingerprint
    echo "PASS"
    return 0;
    :;
  else
    local LINE=$(echo "$OUTPUT" | grep "SHA256")
    if [[ "" == "${LINE}" ]] ; then
      local LINE=$(echo "$OUTPUT" | grep "Enter passphrase for key")
      if [[ "" == "${LINE}" ]] ; then
        # ERROR
        echo "ERROR"
        return 1;
        :;
      else
        # You have already accepted the fingerprint
        echo "PASS"
       return 0;
        :;
      fi
    else
      local FINGERPRINT=$(echo ${LINE#*SHA256:} | sed 's/\..*//')
      echo "$FINGERPRINT"
      return 0;
    fi
  fi
}


# -----------------------------------------------------------------------------
#   Variables
# -----------------------------------------------------------------------------

CONFIG="config.json"

if [[ ! -f "${CONFIG}" ]] ; then 
  echo "[${red}fail${standout}] A \"${CONFIG}\" config file is necessary."
  exit 1
fi

# Name or IP of the server
SERVER_IP=$(jq -r " .server.ip " "${CONFIG}")

# Login username
SERVER_USER=$(jq -r " .server.user " "${CONFIG}")

# SSH port
SERVER_PORT=$(jq -r " .server.port " "${CONFIG}")

# Path and name of the private key
SERVER_KEY_FILE=$(jq -r " .server.key.file " "${CONFIG}")

# Passwort for the private key file (not recommended in terms of security)
SERVER_KEY_PASSWORD=$(jq -r " .server.key.password " "${CONFIG}")


# Name of the docker
DOCKER_NAME=$(jq -r " .docker.name " "${CONFIG}")

# Path you want a backup
BACKUP_SERVER_SOURCEFOLDER=""
  LF_ARRAY=$(jq -r " .backup.server.sourceFolder[] " "${CONFIG}")
  readarray -t BACKUP_SERVER_SOURCEFOLDER <<< "${LF_ARRAY}"

# Path you will place the backup
BACKUP_SERVER_DESTINATIONFOLDER=$(jq -r " .backup.server.destinationFolder " "${CONFIG}")

# Name of the archive file
BACKUP_NAME=""
  EVAL_COMMAND=$(jq -r " .backup.name " "${CONFIG}")
  BACKUP_NAME=$(eval echo $EVAL_COMMAND)

# Extension of the archive file
BACKUP_SERVER_EXTENSION=$(jq -r " .backup.server.extension " "${CONFIG}")

# Archive full name on the server
BACKUP_SERVER_NAME=$(echo "${BACKUP_SERVER_DESTINATIONFOLDER}/${BACKUP_NAME}${BACKUP_SERVER_EXTENSION}" | tr -s /)

# Path on the local machine
BACKUP_LOCAL_DESTINATIONFOLDER=$(jq -r " .backup.local.destinationFolder " "${CONFIG}")

# Archive full name on the local machine
BACKUP_LOCAL_NAME=$(echo "${BACKUP_LOCAL_DESTINATIONFOLDER}/${BACKUP_NAME}${BACKUP_SERVER_EXTENSION}" | tr -s /)
BACKUP_LOCAL_VALIDPOSTFIX=$(jq -r " .backup.local.validPostfix " "${CONFIG}")
BACKUP_LOCAL_DAMAGEPOSTFIX=$(jq -r " .backup.local.damagePostfix " "${CONFIG}")
BACKUP_LOCAL_NAME_VALID=$(echo "${BACKUP_LOCAL_DESTINATIONFOLDER}/${BACKUP_NAME}${BACKUP_LOCAL_VALIDPOSTFIX}${BACKUP_SERVER_EXTENSION}" | tr -s /)
BACKUP_LOCAL_NAME_DAMAGED=$(echo "${BACKUP_LOCAL_DESTINATIONFOLDER}/${BACKUP_NAME}${BACKUP_LOCAL_DAMAGEPOSTFIX}${BACKUP_SERVER_EXTENSION}" | tr -s /)

# Full name of server log file
LOG_SERVER=$(echo "${BACKUP_SERVER_DESTINATIONFOLDER}/log.log" | tr -s /)

# Full name of local log file
LOG_LOCAL=$(echo "${BACKUP_LOCAL_DESTINATIONFOLDER}/${BACKUP_NAME}.log" | tr -s /)


# -----------------------------------------------------------------------------
# Validity check of the variables

if [[ ! -f "${SERVER_KEY_FILE}" ]] ; then 
  echo "[${red}fail${standout}] A \"${SERVER_KEY_FILE}\" key file is necessary." 
  exit 1
fi


# -----------------------------------------------------------------------------
#   Input parameters
# -----------------------------------------------------------------------------

while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
  -h | --help )
    _h=true
    ;;
  -t | --test )
    _t=true
    ;;
  --init )
    _init=true
    ;;
  --interactive )
    _interactive=true
    ;;
  -p | --password )
    shift; SERVER_KEY_PASSWORD=$1
    ;;
esac; shift; done


# -----------------------------------------------------------------------------
# Performing special tasks

if [[ "true" == "$_h" ]] ; then
  echo "usage: ${SCRIPT_NAME} [-h help] [-t test] [init] [interactive] [-p password]"
  echo ""
  echo "help:        Shows the help (this output)"
  echo "test:        To test the password and the fingerprint. Returns 0=No error/1=Error"
  echo "init:        Accepts the fingerprint. Returns 0=No error/1=Error"
  echo "interactive: If no password is set, you will be asked for the password."
  echo "password:    Sets and overwrites the password of the private key,"
  echo "             note that a password entered here is saved in the history."
  echo "             Use the config file (${CONFIG})."
  exit 0
fi

if [[ "true" == "$_t" ]] ; then
  ERROR=0
  
  if [[ "" != "${SERVER_KEY_PASSWORD}" ]] ; then
    if openssl rsa -noout -in "${SERVER_KEY_FILE}" -passin "pass:${SERVER_KEY_PASSWORD}" 2>/dev/null; then
      echo "[${green}pass${standout}] Password matches"
    else
      echo "[${red}fail${standout}] Password does not match."
      ERROR=1
    fi
  else
    echo "[${red}fail${standout}] No password available."
    ERROR=1
  fi 
  
  RESULT=$(fingerprint -i "${SERVER_KEY_FILE}" -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_IP})
  if [[ "ERROR" == "${RESULT}" ]] ; then
    echo "[${red}fail${standout}] There is a connection problem."
    ERROR=1
  elif [[ "" == "${RESULT}" ]] ; then
    echo "[${red}fail${standout}] This logical error should not occur."
    ERROR=1
  elif [[ "PASS" == "${RESULT}" ]] ; then
    echo "[${green}pass${standout}] You can connect to the server."
  else
    echo "[${red}fail${standout}] You need to accept the fingerprint"
    echo "       ${RESULT}"
    ERROR=1
  fi
  
  exit ${ERROR}
fi

if [[ "true" == "$_init" ]] ; then
  RESULT=$(fingerprint -i "${SERVER_KEY_FILE}" -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_IP})
  if [[ "ERROR" == "${RESULT}" ]] ; then
    echo "[${red}fail${standout}] There is a connection problem."
    exit 1
  elif [[ "" == "${RESULT}" ]] ; then
    echo "[${red}fail${standout}] This logical error should not occur."
    exit 1
  elif [[ "PASS" == "${RESULT}" ]] ; then
    echo "[${green}pass${standout}] You can connect to the server, init was not necessary."
    exit 0
  else
    echo "[${green}pass${standout}] You have accepted the fingerprint, ${SERVER_USER}@${SERVER_IP}"
    echo "       ${RESULT}"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "${SERVER_KEY_FILE}" -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_IP} exit &> /dev/null;
    exit 0
  fi
  
  exit 1
fi


# -----------------------------------------------------------------------------
#   Test settings and connection
# -----------------------------------------------------------------------------

# If the password is blank, you must enter it manually
if [[ "" == "${SERVER_KEY_PASSWORD}" ]] ; then
  if [[ "true" == "$_interactive" ]] ; then
    read -sp "Enter passphrase for ${SERVER_KEY_FILE}:" SERVER_KEY_PASSWORD
    echo ""
  else
    echo "[${red}fail${standout}] No password available."
    exit 1;
  fi
fi

if ! openssl rsa -noout -in "${SERVER_KEY_FILE}" -passin "pass:${SERVER_KEY_PASSWORD}" 2>/dev/null ; then
  echo "[${red}fail${standout}] The password is wrong."
  exit 1;
fi

RESULT=$(fingerprint -i "${SERVER_KEY_FILE}" -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_IP})
if [[ "ERROR" == "${RESULT}" ]] ; then
  echo "[${red}fail${standout}] There is a connection problem."
  exit 1
elif [[ "" == "${RESULT}" ]] ; then
  echo "[${red}fail${standout}] This logical error should not occur."
  exit 1
elif [[ "PASS" == "${RESULT}" ]] ; then
  :;
else
  echo "[${red}fail${standout}] You need to accept the fingerprint"
  echo "       ${RESULT}"
  exit 1
fi

#REMOTE_COMMANDS_TEST=$(cat << END_REMOTE_COMMANDS_TEST
#  echo "yes" > test.test
#END_REMOTE_COMMANDS_TEST
#)
#
#{ sleep 1; echo "${SERVER_KEY_PASSWORD}"; } | script -q /dev/null -c "ssh -i ${SERVER_KEY_FILE} -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_IP} \"${REMOTE_COMMANDS_TEST}\" ; " ;

echo "end test"
exit 1

# -----------------------------------------------------------------------------
#   Backup
# -----------------------------------------------------------------------------

# Remote commands section
REMOTE_COMMANDS=$(cat << END_REMOTE_COMMANDS

#!/bin/bash

echo "Time: \$(date '+y%Ym%md%d %H:%M:%S')" > "${LOG_SERVER}"

echo "\$(date '+%H:%M:%S') Create dir" >> "${LOG_SERVER}"
mkdir -p "${BACKUP_SERVER_DESTINATIONFOLDER}"

# Set to name or ID of the container to be watched.
CONTAINER=\$(docker ps --all | grep "${DOCKER_NAME}" | cut -f1 -d' ')

# Define backup name
[[ -z \${CONTAINER} ]] && CONTAINER="000000000000"

echo "\$(date '+%H:%M:%S') Look for \${CONTAINER}" >> "${LOG_SERVER}"

# Stop script if backup name is used
if [[ "\${CONTAINER}" = "000000000000" ]] ; then
  echo "\$(date '+%H:%M:%S') Container not found, must be stopped"
  echo "\$(date '+%H:%M:%S') Container not found, must be stopped" >> "${LOG_SERVER}"
  exit 2;
else

  # Set timeout to the number of seconds you are willing to wait.
  timeout=500
  # Timeout counter
  counter=0

  # Stop the container
  if [[ "\$( docker container inspect -f '{{.State.Running}}' \${CONTAINER} )" == "true" ]] ; then 
    echo "\$(date '+%H:%M:%S') docker stop \${CONTAINER}"
    echo "\$(date '+%H:%M:%S') docker stop \${CONTAINER}" >> "${LOG_SERVER}"
    docker stop \${CONTAINER}
  fi

  # This first echo is important for keeping the output clean and not overwriting the previous line of output.
  echo "\$(date '+%H:%M:%S') Waiting for \${CONTAINER} to be ready (\${counter}/\${timeout})"
  echo "\$(date '+%H:%M:%S') Waiting for \${CONTAINER} to be ready (\${counter}/\${timeout})" >> "${LOG_SERVER}"

  #This says that until docker inspect reports the container is in a running state, keep looping.
  until [[ "\$( docker container inspect -f '{{json .State.Running}}' \${CONTAINER} )" == "false" ]] ; do

    # If we've reached the timeout period, report that and exit to prevent running an infinite loop.
    if [[ \${timeout} -lt \${counter} ]]; then
      echo "ERROR: Timed out waiting for \${CONTAINER} to come up."
      exit 3
    fi

    if (( \$counter % 5 == 0 )); then
      echo -e "\e[1A\e[KWaiting for \${CONTAINER} to be ready (\${counter}/\${timeout})"
    fi

    sleep 1s
    ((counter++))

  done
fi

echo "\$(date '+%H:%M:%S') tar to: ${BACKUP_SERVER_NAME} from: ${BACKUP_SERVER_SOURCEFOLDER}"
echo "\$(date '+%H:%M:%S') tar to: ${BACKUP_SERVER_NAME} from: ${BACKUP_SERVER_SOURCEFOLDER}" >> "${LOG_SERVER}"
tar -czf "${BACKUP_SERVER_NAME}" "${BACKUP_SERVER_SOURCEFOLDER[@]}"

echo "\$(date '+%H:%M:%S') Start docker \${CONTAINER}"
echo "\$(date '+%H:%M:%S') Start docker \${CONTAINER}" >> "${LOG_SERVER}"
docker start \${CONTAINER}

END_REMOTE_COMMANDS
)


# -----------------------------------------------------------------------------

echo "$(date '+%H:%M:%S') Run remote commands section"
echo "$(date '+%H:%M:%S') Run remote commands section" >> "${LOG_LOCAL}"
ssh -i ${SERVER_KEY_FILE} -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_IP} "${REMOTE_COMMANDS}"


# -----------------------------------------------------------------------------

echo "$(date '+%H:%M:%S') Download archive file"
MSG1="$(date '+%H:%M:%S') Download archive file"
rsync -chavzP --partial --progress --stats -e "ssh -i ${SERVER_KEY_FILE} -p ${SERVER_PORT}" ${SERVER_USER}@${SERVER_IP}:"${BACKUP_SERVER_NAME}" "${BACKUP_LOCAL_NAME}"


echo "$(date '+%H:%M:%S') Download log file"
MSG2="$(date '+%H:%M:%S') Download log file"
rsync -chavzP --partial --progress --stats -e "ssh -p ${SERVER_PORT}" ${SERVER_USER}@${SERVER_IP}:"${LOG_SERVER}" "${LOG_LOCAL}"


echo "${MSG1}" >> "${LOG_LOCAL}"
echo "${MSG2}" >> "${LOG_LOCAL}"

echo "$(date '+%H:%M:%S') Data are copied"
echo "$(date '+%H:%M:%S') Data are copied" >> "${LOG_LOCAL}"


echo "$(date '+%H:%M:%S') Determine server sha256 checksum of"
echo "$(date '+%H:%M:%S') Determine server sha256 checksum of" >> "${LOG_LOCAL}"
var=($(ssh -i ${SERVER_KEY_FILE} -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_IP} "sha256sum ${BACKUP_SERVER_NAME}"))
echo "$(date '+%H:%M:%S') Server sha256 : ${var[0]}" >> "${LOG_LOCAL}"


echo "$(date '+%H:%M:%S') Determine local sha256 checksum"
echo "$(date '+%H:%M:%S') Determine local sha256 checksum" >> "${LOG_LOCAL}"
var2=($(sha256sum ${BACKUP_LOCAL_NAME}))
echo "$(date '+%H:%M:%S') Local  sha256 : ${var2[0]}" >> "${LOG_LOCAL}"


if [[ "${var[0]}" == "${var2[0]}" ]] ; then
  echo "$(date '+%H:%M:%S') Data are valid"
  echo "$(date '+%H:%M:%S') Data are valid" >> "${LOG_LOCAL}"
  mv "${BACKUP_LOCAL_NAME}" "${BACKUP_LOCAL_NAME_VALID}"
  ssh -i ${SERVER_KEY_FILE} -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_IP} "rm ${BACKUP_SERVER_NAME} ; rm ${LOG_SERVER}"
else
  echo "$(date '+%H:%M:%S') Data damaged"
  echo "$(date '+%H:%M:%S') Data damaged" >> "${LOG_LOCAL}"
  mv "${BACKUP_LOCAL_NAME}" "${BACKUP_LOCAL_NAME_DAMAGED}"
fi


# -----------------------------------------------------------------------------
