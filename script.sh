#!/bin/bash

# Needs "jq" locally, `sudo apt install jq`
# Needs "openssl" locally, `sudo apt install openssl`
# Needs "ssh" locally, `sudo apt install ssh`
# Needs "shred" locally
# Needs "mktemp" locally
# Needs "stat" locally

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
#CMD ["/SshBackupOfDocker"]
#WORKDIR /SshBackupOfDocker
#
## docker build -t test_image .
## docker run -it --mount type=bind,source="$(pwd)"/SshBackupOfDocker,target=/SshBackupOfDocker --name test_container test_image sh


# -----------------------------------------------------------------------------
#   Input parameters
# -----------------------------------------------------------------------------

cd "$(dirname "$0")"

while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
  -h | --help )
    _h=true
    ;;
  -v | --verbose )
    _v=true
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
  -r | --remove )
    _remove=true
    ;;
  -l | --login )
    _login=true
    ;;
  -s | --scan )
    _scan=true
    ;;
  -p | --password )
    shift; SERVER_KEY_PASSWORD_OVERWRITE=$1
    ;;
esac; shift; done

function cleanup {
  vecho "Cleanup" 2> /dev/null
  shred -u "${TEMP_KEY}" 2> /dev/null
}

trap cleanup EXIT

if [[ "true" == "$_h" ]] ; then
  echo "usage: ${SCRIPT_NAME} [-h help] [-v verbose] [-t test] [init] [interactive] [-p password]"
  echo ""
  echo "help:        Shows the help (this output)."
  echo "verbose:     Detailed mode for displaying additional information."
  echo "test:        To test the password and the fingerprint. Returns 0=No error/1=Error"
  echo "init:        Accepts the fingerprint. Returns 0=No error/1=Error"
  echo "interactive: If no password is set, you will be asked for the password."
  echo "remove:      Removes the server's fingerprint from your computer."
  echo "login:       Uses the data from the config file to log in to the server."
  echo "scan:        Scan the server and determine the fingerprint."
  echo "password:    Sets and overwrites the password of the private key,"
  echo "             note that a password entered here is saved in the history."
  echo "             Use the config file (${CONFIG})."
  echo ""
  echo "Set the rights of the config and script file:"
  echo "  'chmod 600 example.file'"
  echo "  'chown root example.file'"
  echo "  'chgrp root example.file'"
  echo ""
  echo "Create a task in the Synology with the following content:"
  echo "  /bin/bash -c \"/bin/bash '/volume1/folder/script.sh' '-t' > >(tee '/volume1/folder/log.log') RET_VAL=\$?; exit \$RET_VAL\" "
  echo ""
  echo "Return values:"
  echo "  0 OK"
  echo "  1 Dependent program not available"
  echo "  2 Config file not found."
  echo "  3 Key file not found."
  echo "  4 Permissions of key file of group and other needs to be 0."
  echo "  5 Password does not match."
  echo "  6 No password available."
  echo "  7 There is a connection problem."
  echo "  8 This logical error should not occur."
  echo "  9 Unknown error."
  echo " 10 You need to accept the fingerprint."
  echo " 11 There is a connection problem."
  echo " 12 This logical error should not occur."
  echo " 13 Data damaged."
  echo ""
  echo "101 Server: Container not found, must be stopped."
  echo "102 Server: Timed out waiting for container to come up."
  echo ""
  
  exit 0
fi


# -----------------------------------------------------------------------------
#   Basic
# -----------------------------------------------------------------------------

# check if stdout is a terminal
if test -t 1; then
    # ANSI escape codes
    bold="\033[1m"
    underline="\033[4m"
    normal="\033[0m" 
    black="\033[30m"
    red="\033[31m"
    green="\033[32m"
    yellow="\033[0;33m"
    blue="\033[34m"
    magenta="\033[1;35m"
    cyan="\033[36m"
    white="\033[1;37m"
fi

# Change standard echo function
function echo() { builtin echo -e "$@"; }

function vecho() { if [[ "true" == "$_v" ]] ; then echo "[${cyan}info${normal}] $(date '+%H:%M:%S') $@"; fi ; }

function lecho() { echo "$(date '+%H:%M:%S') $@"; }


SCRIPT_NAME="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")"


# -----------------------------------------------------------------------------
#   Dependencies
# -----------------------------------------------------------------------------

function dependent_program() {
  if ! command -v "$1" &> /dev/null ; then 
    echo "[${red}fail${normal}] The $1 program must be installed."
    exit 1
  else 
    vecho "  $1"
  fi
}

vecho "Programs are installed:"
dependent_program "jq"
dependent_program "openssl"
dependent_program "ssh"
dependent_program "shred"
dependent_program "mktemp"
dependent_program "stat"


# -----------------------------------------------------------------------------
#   Functions
# -----------------------------------------------------------------------------

# usage: [-i identity_file] [-p port] [-u user] [-h host] user@host
#
# identity_file : Your private key, can be encrypted
# port          : Server port, if empty, 22 is used
# user          : Server user
# host          : Server host or IP
# user@host     : user and host, overwrites user and host parameters
#
# Returns (You can use ${RETURN_VALUE:0:4} ):
# PASS             (return value   0) : You have already accepted the fingerprint.
# PASS-ENCRYPTED   (return value   0) : Fingerprint is accepted, but an encrypted certificate file was used.
# FAIL-FINGERPRINT (return value   1) : Fingerprint not accepted.
# FAIL-IP          (return value   2) : Wrong IP or wrong host.
# FAIL-PORT        (return value   3) : Wrong port on the server, because wrong port is used, or wrong server with different port, or timeout.
# FAIL-HOST        (return value   4) : Incorrect host name.
# FAIL-IDENTITY    (return value   5) : Identity file is empty or was not found.
# FAIL-254         (return value 254) : Unknown error.
# FAIL-255         (return value 255) : Unknown error.
#
function is_fingerprint_accepted() {
  local KEYFILE=""
  local PORT=22
  local USER="root"
  local HOST=""
  local DESTINATION=""
  local OUTPUT=""
  local RETURN_VALUE=255
  
  while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
    -i | --identity_file )
      shift; KEYFILE="$1"
      ;;
    -p | --port )
      shift; PORT="$1"
      ;;
    -u | --user )
      shift; USER="$1"
      ;;
    -h | --host )
      shift; HOST="$1"
      ;;
  esac; shift; done
  DESTINATION="$1"
  if [[ "" != "${DESTINATION}" ]] ; then
    local ARR
    IFS='@'; ARR=($DESTINATION); unset IFS;
    USER="${ARR[0]}"
    HOST="${ARR[1]}"
  fi
  
  OUTPUT=$(ssh -o ConnectTimeout=3 -o BatchMode=yes -i "${KEYFILE}" -p "${PORT}" "${USER}@${HOST}" exit 2>&1 )
  RETURN_VALUE="$?"
  if [[ "" != "${OUTPUT}" ]] ; then
    OUTPUT="${OUTPUT::-1}"
  fi
  
  IFS=$'\n'; ARR=($OUTPUT); unset IFS;
  OUTPUT="${ARR[0]}"
    
  if [[ "0" == "${RETURN_VALUE}" ]] ; then
    # You have already accepted the fingerprint
    echo "PASS"
    return 0;
  elif [[ "255" == "${RETURN_VALUE}" ]] ; then
    # Error
    if [[ "${OUTPUT}" == "Host key verification failed." ]] ; then
      # Fingerprint not accepted
      echo "FAIL-FINGERPRINT"
      return 1;
    elif [[ "${OUTPUT}" == "${USER}@${HOST}: Permission denied (publickey)." ]] ; then
      # Fingerprint is accepted, but an encrypted certificate file was used.
      echo "PASS-ENCRYPTED"
      return 0;
    elif [[ "${OUTPUT}" == "ssh: connect to host ${HOST} port ${PORT}: Connection refused" ]] ; then
      # Wrong IP or wrong host
      echo "FAIL-IP"
      return 2;
    elif [[ "${OUTPUT}" == "ssh: connect to host ${HOST} port ${PORT}: Connection timed out" ]] ; then
      # Wrong port on the server, because wrong port is used, or wrong server with different port, or timeout
      echo "FAIL-PORT"
      return 3;
    elif [[ "${OUTPUT}" == "ssh: Could not resolve hostname ${HOST,,}: Name or service not known" ]] ; then
      # Incorrect host name 
      echo "FAIL-HOST"
      return 4;
    elif [[ "${OUTPUT}" == "Warning: Identity file  not accessible: No such file or directory." ]] ; then
      # Identity file is empty or was not found
      echo "FAIL-IDENTITY"
      return 5;
    else
      # Unknown error
      echo "FAIL-254"
      return 254;
    fi
  else
    # Unknown error
    echo "FAIL-255"
    return 255;
  fi
}

# usage: [-i identity_file] [-p port] [-u user] [-h host] user@host
#
# identity_file : Your private key, can be encrypted
# port          : Server port, if empty, 22 is used
# user          : Server user
# host          : Server host or IP
# user@host     : user and host, overwrites user and host parameters
#
# Returns:
# YES   (return value   0) : When the fingerprint must be accepted
# NO    (return value   1) : Fingerprint is accepted
# ERROR (return value 255) : Parameter or connection error
#
function is_fingerprint_confirmation_required() {
  local KEYFILE=""
  local PORT=22
  local USER="root"
  local HOST=""
  local DESTINATION=""
  local OUTPUT=""
  
  while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
    -i | --identity_file )
      shift; KEYFILE="$1"
      ;;
    -p | --port )
      shift; PORT="$1"
      ;;
    -u | --user )
      shift; USER="$1"
      ;;
    -h | --host )
      shift; HOST="$1"
      ;;
  esac; shift; done
  DESTINATION="$1"
  if [[ "" != "${DESTINATION}" ]] ; then
    local ARR
    IFS='@'; ARR=($DESTINATION); unset IFS;
    USER="${ARR[0]}"
    HOST="${ARR[1]}"
  fi
  
  OUTPUT=$(is_fingerprint_accepted -i "${KEYFILE}" -p "${PORT}" -u "${USER}" -h "${HOST}" "${DESTINATION}" )
  OUTPUT_4CHARACTERS="${OUTPUT:0:4}"
  if [[ "PASS" == "${OUTPUT_4CHARACTERS}" ]] ; then
    echo "NO";
    return 1;
  elif [[ "FAIL-FINGERPRINT" == "${OUTPUT}" ]] ; then
    echo "YES";
    return 0;
  else
    echo "ERROR";
    return 255;
  fi
}

# usage: [-i identity_file] [-p port] [-u user] [-h host] user@host
#
# identity_file : Your private key, can be encrypted
# port          : Server port, if empty, 22 is used
# user          : Server user
# host          : Server host or IP
# user@host     : user and host, overwrites user and host parameters
#
function fingerprint_dialog() {
  local KEYFILE=""
  local PORT=22
  local USER="root"
  local HOST=""
  local DESTINATION=""
  
  while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
    -i | --identity_file )
      shift; KEYFILE="$1"
      ;;
    -p | --port )
      shift; PORT="$1"
      ;;
    -u | --user )
      shift; USER="$1"
      ;;
    -h | --host )
      shift; HOST="$1"
      ;;
  esac; shift; done
  DESTINATION="$1"
  if [[ "" != "${DESTINATION}" ]] ; then
    local ARR
    IFS='@'; ARR=($DESTINATION); unset IFS;
    USER="${ARR[0]}"
    HOST="${ARR[1]}"
  fi
  
  ssh -o ConnectTimeout=3 -i "${KEYFILE}" -p "${PORT}" "${USER}@${HOST}" exit

}


# -----------------------------------------------------------------------------
#   Variables
# -----------------------------------------------------------------------------

CONFIG="config.json"

vecho "Your config file is '${CONFIG}'."
if [[ ! -f "${CONFIG}" ]] ; then 
  echo "[${red}fail${normal}] A \"${CONFIG}\" config file is necessary."
  exit 2
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

vecho "Your key file is '${SERVER_KEY_FILE}'."
if [[ ! -f "${SERVER_KEY_FILE}" ]] ; then 
  echo "[${red}fail${normal}] A \"${SERVER_KEY_FILE}\" key file is necessary." 
  exit 3
fi

if [[ "" != "${SERVER_KEY_PASSWORD_OVERWRITE}" ]] ; then
  vecho "Password has been passed and overwrites the one read."
  SERVER_KEY_PASSWORD="${SERVER_KEY_PASSWORD_OVERWRITE}"
fi

PERMISSION=$(stat -c "%a" "${SERVER_KEY_FILE}")
vecho "Permissions is ${PERMISSION} for '${SERVER_KEY_FILE}'."
if [[ "$EUID" -ne "0" ]]; then
  if [[ "${PERMISSION:1:2}" != "00" ]] ; then 
    echo "[${red}fail${normal}] Permissions ${PERMISSION} for '${SERVER_KEY_FILE}' are too open (group and other needs to be 0)."
    exit 4
  fi
fi


# -----------------------------------------------------------------------------
# Performing special tasks

if [[ "true" == "$_t" ]] ; then
  ERROR=0
  
  if [[ "" != "${SERVER_KEY_PASSWORD}" ]] ; then
    if openssl rsa -noout -in "${SERVER_KEY_FILE}" -passin "pass:${SERVER_KEY_PASSWORD}" 2>/dev/null; then
      echo "[${green}pass${normal}] Password matches"
    else
      echo "[${red}fail${normal}] Password does not match."
      ERROR=5
    fi
  else
    echo "[${red}fail${normal}] No password available."
    ERROR=6
  fi 
  
  RESULT=$(is_fingerprint_accepted -i "${SERVER_KEY_FILE}" -p "${SERVER_PORT}" "${SERVER_USER}@${SERVER_IP}")
  if [[ "PASS" == "${RESULT}" ]] ; then
    echo "[${green}pass${normal}] You have already accepted the fingerprint."
  elif [[ "PASS-ENCRYPTED" == "${RESULT}" ]] ; then
    echo "[${green}pass${normal}] You have already accepted the fingerprint, the certificate file ist encrypted."
  elif [[ "FAIL-FINGERPRINT" == "${RESULT}" ]] ; then
    echo "[${red}fail${normal}] Fingerprint not accepted."
  elif [[ "FAIL-IP" == "${RESULT}" ]] ; then
    echo "[${red}fail${normal}] Wrong IP or wrong host."
  elif [[ "FAIL-PORT" == "${RESULT}" ]] ; then
    echo "[${red}fail${normal}] Wrong port on the server, because wrong port is used, or wrong server with different port, or timeout."
  elif [[ "FAIL-HOST" == "${RESULT}" ]] ; then
    echo "[${red}fail${normal}] Incorrect host name."
  elif [[ "FAIL-IDENTITY" == "${RESULT}" ]] ; then
    echo "[${red}fail${normal}] Identity file is empty or was not found."
  elif [[ "FAIL-254" == "${RESULT}" ]] ; then
    echo "[${red}fail${normal}] Unknown error 254."
  elif [[ "FAIL-255" == "${RESULT}" ]] ; then
    echo "[${red}fail${normal}] Unknown error 255."
  else
    echo "[${red}fail${normal}] Unknown error."
  fi
  
  exit ${ERROR}
fi

if [[ "true" == "$_init" ]] ; then
  RESULT=$(is_fingerprint_confirmation_required -i "${SERVER_KEY_FILE}" -p "${SERVER_PORT}" "${SERVER_USER}@${SERVER_IP}")
  if [[ "ERROR" == "${RESULT}" ]] ; then
    echo "[${red}fail${normal}] There is a connection problem."
    exit 7
  elif [[ "YES" == "${RESULT}" ]] ; then
    fingerprint_dialog -i "${TEMP_KEY}" -p "${SERVER_PORT}" "${SERVER_USER}@${SERVER_IP}"
    exit 0
  elif [[ "NO" == "${RESULT}" ]] ; then
    echo "[${green}pass${normal}] You can connect to the server, init was not necessary."
    exit 0
  else
    echo "[${red}fail${normal}] This logical error should not occur."
    exit 8
  fi
  
  exit 9
fi

if [[ "true" == "$_remove" ]] ; then
  dependent_program "ssh-keygen"
  vecho "Removing the host key of ${SERVER_IP}."
  ssh-keygen -R "${SERVER_IP}"  
  exit 0
fi

if [[ "true" == "$_scan" ]] ; then
  dependent_program "ssh-keyscan"
  dependent_program "ssh-keygen"
  vecho "Scan server and determine fingerprint"
  ssh-keyscan "${SERVER_IP}" | ssh-keygen -lf -
  exit 0
fi


# -----------------------------------------------------------------------------
#   Test settings and connection
# -----------------------------------------------------------------------------

# If the password is blank, you must enter it manually
if [[ "" == "${SERVER_KEY_PASSWORD}" ]] ; then
  vecho "Password not set."
  if [[ "true" == "$_interactive" ]] ; then
    read -sp "Enter passphrase for ${SERVER_KEY_FILE}:" SERVER_KEY_PASSWORD
    echo ""
  else
    echo "[${red}fail${normal}] No password available."
    exit 6;
  fi
fi

if ! openssl rsa -noout -in "${SERVER_KEY_FILE}" -passin "pass:${SERVER_KEY_PASSWORD}" 2>/dev/null ; then
  echo "[${red}fail${normal}] The password is wrong."
  exit 5;
else
  vecho "Password correct."
fi

# File has 600 permission
TEMP_KEY=$(mktemp)
openssl rsa -in "${SERVER_KEY_FILE}" -passin "pass:${SERVER_KEY_PASSWORD}" -out "${TEMP_KEY}" 2> /dev/null


RESULT=$(is_fingerprint_accepted -i "${TEMP_KEY}" -p "${SERVER_PORT}" "${SERVER_USER}@${SERVER_IP}")
RESULT_4CHARACTERS="${RESULT:0:4}"

if [[ "FAIL-FINGERPRINT" == "${RESULT}" ]] ; then
  echo "[${red}fail${normal}] You need to accept the fingerprint"
  exit 10
elif [[ "FAIL" == "${RESULT_4CHARACTERS}" ]] ; then
  echo "[${red}fail${normal}] There is a connection problem."
  exit 11
elif [[ "PASS" == "${RESULT_4CHARACTERS}" ]] ; then
  vecho "You accepted the fingerprint."
  :;
else
  echo "[${red}fail${normal}] This logical error should not occur."
  exit 12
fi

# -----------------------------------------------------------------------------
# Performing special tasks

if [[ "true" == "$_login" ]] ; then
  vecho "Log into server."
  ssh -i "${TEMP_KEY}" -p "${SERVER_PORT}" "${SERVER_USER}@${SERVER_IP}"
  exit 0
fi


# -----------------------------------------------------------------------------
#   Backup
# -----------------------------------------------------------------------------

# Remote commands section
REMOTE_COMMANDS=$(cat << END_REMOTE_COMMANDS

#!/bin/bash
function echo() { builtin echo -e "\$@"; }
function vecho() { if [[ "true" == "$_v" ]] ; then echo "[${yellow}info${normal}] \$(date '+%H:%M:%S') \$@"; fi ; }
function lecho() { echo "\$(date '+%H:%M:%S') \$@"; }

lecho "Time: \$(date '+y%Ym%md%d %H:%M:%S')" > "${LOG_SERVER}"

lecho "Create dir" >> "${LOG_SERVER}"

mkdir -p "${BACKUP_SERVER_DESTINATIONFOLDER}"

# Set to name or ID of the container to be watched.
CONTAINER=\$(docker ps --all | grep "${DOCKER_NAME}" | cut -f1 -d' ')

# Define backup name
[[ -z \${CONTAINER} ]] && CONTAINER="000000000000"

lecho "Look for \${CONTAINER}" >> "${LOG_SERVER}"

# Stop script if backup name is used
if [[ "\${CONTAINER}" = "000000000000" ]] ; then
  vecho "Container not found, must be stopped"
  lecho "Container not found, must be stopped" >> "${LOG_SERVER}"
  exit 101;
else

  # Set timeout to the number of seconds you are willing to wait.
  timeout=500
  # Timeout counter
  counter=0

  # Stop the container
  if [[ "\$( docker container inspect -f '{{.State.Running}}' \${CONTAINER} )" == "true" ]] ; then 
    vecho "docker stop \${CONTAINER}"
    lecho "docker stop \${CONTAINER}" >> "${LOG_SERVER}"
    docker stop \${CONTAINER}
  fi

  # This first echo is important for keeping the output clean and not overwriting the previous line of output.
  vecho "Waiting for \${CONTAINER} to be ready (\${counter}/\${timeout})"
  lecho "Waiting for \${CONTAINER} to be ready (\${counter}/\${timeout})" >> "${LOG_SERVER}"

  #This says that until docker inspect reports the container is in a running state, keep looping.
  until [[ "\$( docker container inspect -f '{{json .State.Running}}' \${CONTAINER} )" == "false" ]] ; do

    # If we have reached the timeout period, report that and exit to prevent running an infinite loop.
    if [[ \${timeout} -lt \${counter} ]]; then
      echo "ERROR: Timed out waiting for \${CONTAINER} to come up."
      exit 102
    fi

    if (( \$counter % 5 == 0 )); then
      vecho "\e[1A\e[KWaiting for \${CONTAINER} to be ready (\${counter}/\${timeout})"
    fi

    sleep 1s
    ((counter++))

  done
fi

vecho "tar to: ${BACKUP_SERVER_NAME} from: ${BACKUP_SERVER_SOURCEFOLDER}"
lecho "tar to: ${BACKUP_SERVER_NAME} from: ${BACKUP_SERVER_SOURCEFOLDER}" >> "${LOG_SERVER}"
tar -czf "${BACKUP_SERVER_NAME}" "${BACKUP_SERVER_SOURCEFOLDER[@]}"

vecho "Start docker \${CONTAINER}"
lecho "Start docker \${CONTAINER}" >> "${LOG_SERVER}"
docker start \${CONTAINER}

exit 0

END_REMOTE_COMMANDS
)


# -----------------------------------------------------------------------------

vecho "Run remote commands section"
MSG01="Run remote commands section"
ssh -i "${TEMP_KEY}" -p "${SERVER_PORT}" "${SERVER_USER}@${SERVER_IP}" "${REMOTE_COMMANDS}"
RETURN_VALUE="$?"

if [[ "0" != "${RETURN_VALUE}" ]] ; then
  exit ${RETURN_VALUE}
fi


# -----------------------------------------------------------------------------

vecho "Create folder '${BACKUP_LOCAL_DESTINATIONFOLDER}'"
MSG02="Create folder '${BACKUP_LOCAL_DESTINATIONFOLDER}'"
mkdir -p "${BACKUP_LOCAL_DESTINATIONFOLDER}"

vecho "Download archive file"
MSG03="Download archive file"
rsync -chavzP --partial --progress --stats -e "ssh -i \"${TEMP_KEY}\" -p \"${SERVER_PORT}\"" "${SERVER_USER}@${SERVER_IP}:${BACKUP_SERVER_NAME}" "${BACKUP_LOCAL_NAME}"


vecho "Download log file"
MSG04="Download log file"
rsync -chavzP --partial --progress --stats -e "ssh -i \"${TEMP_KEY}\" -p \"${SERVER_PORT}\"" "${SERVER_USER}@${SERVER_IP}:${LOG_SERVER}" "${LOG_LOCAL}"


lecho "${MSG01}" >> "${LOG_LOCAL}"
lecho "${MSG02}" >> "${LOG_LOCAL}"
lecho "${MSG03}" >> "${LOG_LOCAL}"
lecho "${MSG04}" >> "${LOG_LOCAL}"

vecho "Data are copied"
lecho "Data are copied" >> "${LOG_LOCAL}"


vecho "Determine server sha256 checksum of ${BACKUP_SERVER_NAME}"
lecho "Determine server sha256 checksum of ${BACKUP_SERVER_NAME}" >> "${LOG_LOCAL}"
SHA256_SERVER=($(ssh -i "${TEMP_KEY}" -p "${SERVER_PORT}" "${SERVER_USER}@${SERVER_IP}" "sha256sum \"${BACKUP_SERVER_NAME}\""))
lecho "Server sha256 : ${SHA256_SERVER[0]}" >> "${LOG_LOCAL}"


vecho "Determine local sha256 checksum of ${BACKUP_LOCAL_NAME}"
lecho "Determine local sha256 checksum of ${BACKUP_LOCAL_NAME}" >> "${LOG_LOCAL}"
SHA256_LOCAL=($(sha256sum "${BACKUP_LOCAL_NAME}"))
lecho "Local  sha256 : ${SHA256_LOCAL[0]}" >> "${LOG_LOCAL}"


if [[ "${SHA256_SERVER[0]}" == "${SHA256_LOCAL[0]}" ]] ; then
  vecho "Data are valid"
  lecho "Data are valid" >> "${LOG_LOCAL}"
  mv "${BACKUP_LOCAL_NAME}" "${BACKUP_LOCAL_NAME_VALID}"
  ssh -i "${TEMP_KEY}" -p "${SERVER_PORT}" "${SERVER_USER}@${SERVER_IP}" "rm ${BACKUP_SERVER_NAME} ; rm ${LOG_SERVER}"
  exit 0;
else
  vecho "Data damaged"
  lecho "Data damaged" >> "${LOG_LOCAL}"
  mv "${BACKUP_LOCAL_NAME}" "${BACKUP_LOCAL_NAME_DAMAGED}"
  exit 13;
fi


# -----------------------------------------------------------------------------
