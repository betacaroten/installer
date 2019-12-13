#!/bin/bash
  
GC='\033[0;32m' #green color
RC='\033[0;31m' #red color
OC='\033[0;33m' #orange color
NC='\033[0m' #no color
IC='\033[0;37m' #input text
BC='\033[1m' #bold text
UC='\033[4m' #underline text

function successLog { echo -e "${GC}$1${NC}"; }
function warningLog { echo -e "${OC}$1${NC}"; }
function errorLog { echo -e "${RC}$1${NC}"; }
function inputLog { printf "${IC}$1${NC}"; }
function titleLog { echo -e "${BC}$1${NC}"; }
function sectionLog { echo -e "${UC}$1${NC}"; } 
function log { echo -e "$1"; }

BRANCH=$VERSION

if [ "$VERSION" = 'edge' ]; then
    BRANCH=master
fi

# INFO
logo='
                      ___________
                     / _________ \
                    / /         \ \
                   / /   _____   \ \
                  / /   /\    \   \ \
                 / /   /  \____\   \ \
                 \ \   \  /    /   / /
                  \ \   \/____/   / /
                   \ \           / /
                    \ \_________/ /
                     \___________/

   ___              ______     _  _  _____  __  _______
  /   \ /\  /\   /\ \____ \   / \/ \ \___ \ \/ / _   _ \
  \ /\// /  \ \ /  \  __/ /  / /\/\ \ __/ //\/\\\/ \ / \/
/\/ \  \ \/\/ // /\ \/ _  \__\ \  / //  _/ \  /   / \
\___/   \_/\_/ \/  \/\/ \___//_/  \_\\\_/    \\/    \\_/
'
echo "$logo"
#figlet swarmpit
titleLog "Welcome to Swarmpit"
log "Version: $VERSION"
log "Branch: $BRANCH"

# DEPENDENCIES
sectionLog "\nPreparing dependencies"
CURL_IMAGE="lucashalbert/curl:7.67.0-r0"
docker pull $CURL_IMAGE
if [ $? -eq 0 ]; then
    successLog "DONE."
else
    errorLog "PREPARATION FAILED!"
    exit 1
fi

# INSTALLATION
sectionLog "\nPreparing installation"
git clone https://github.com/swarmpit/swarmpit -b $BRANCH
if [ $? -eq 0 ]; then
    successLog "DONE."
else
    errorLog "PREPARATION FAILED!"
    exit 1
fi

# SETUP
sectionLog "\nApplication setup"

INTERACTIVE=${INTERACTIVE:-1}
DEFAULT_STACK_NAME=${STACK_NAME:-swarmpit}
DEFAULT_ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
DEFAULT_APP_PORT=${APP_PORT:-888}
DEFAULT_DB_VOLUME_DRIVER=${DB_VOLUME_DRIVER:-local}

interactiveSetup() {
  ## Enter stack name
  while true
  do
    inputLog "Enter stack name [$DEFAULT_STACK_NAME]: "
    read stack_name
    STACK=${stack_name:=$DEFAULT_STACK_NAME}
    docker stack ps $STACK &> /dev/null
    if [ $? -eq 0 ]; then
      warningLog "Stack name [$STACK] is already taken!"
    else
      break
    fi
  done

  ## Enter application port
  inputLog "Enter application port [$DEFAULT_APP_PORT]: "
  read app_port
  PORT=${app_port:=$DEFAULT_APP_PORT}

  ## Enter database volume driver type
  inputLog "Enter database volume driver [$DEFAULT_DB_VOLUME_DRIVER]: "
  read db_driver
  VOLUME_DRIVER=${db_driver:=$DEFAULT_DB_VOLUME_DRIVER}

  ## Enter admin user
  inputLog "Enter admin username [$DEFAULT_ADMIN_USERNAME]: "
  read admin_username
  ADMIN_USER=${admin_username:=$DEFAULT_ADMIN_USERNAME}

  ## Enter admin passwd
  while [[ ${#admin_password} -lt 8 ]]; do
    inputLog "Enter admin password (min 8 characters long): "
    read admin_password
  done
  ADMIN_PASS=${admin_password}
}

nonInteractiveSetup() {
  ## Stack name
  inputLog "Stack name: $DEFAULT_STACK_NAME"
  STACK=$DEFAULT_STACK_NAME
  docker stack ps $STACK &> /dev/null
  if [ $? -eq 0 ]; then
    warningLog "\nStack name [$STACK] is already taken!"
    errorLog "SETUP FAILED!"
    exit 1
  fi

  ## Application port
  inputLog "\nApplication port: $DEFAULT_APP_PORT "
  PORT=$DEFAULT_APP_PORT

  ## Database volume driver type
  inputLog "\nDatabase volume driver: $DEFAULT_DB_VOLUME_DRIVER"
  VOLUME_DRIVER=$DEFAULT_DB_VOLUME_DRIVER

  ## Admin user
  inputLog "\nAdmin username: $DEFAULT_ADMIN_USERNAME"
  ADMIN_USER=$DEFAULT_ADMIN_USERNAME
  
  ## Admin password
  inputLog "\nAdmin password: $ADMIN_PASSWORD\n"
  ADMIN_PASS=$ADMIN_PASSWORD
  if [ ${#ADMIN_PASS} -lt 8 ]; then
    warningLog "Admin password is less than 8 character long"
    errorLog "SETUP FAILED!"
    exit 1
  fi
}

if [ $INTERACTIVE -eq 1 ]; then
  interactiveSetup
else
  nonInteractiveSetup
fi

ARM=0
case $(uname -m) in
    arm*)    ARM=1 ;;
    aarch64) ARM=1 ;;
esac

if [ $ARM -eq 1 ]; then
    COMPOSE_FILE="swarmpit/docker-compose.arm.yml"
    max_attempts=60
else
    COMPOSE_FILE="swarmpit/docker-compose.yml"
    max_attempts=20
fi

sed -i 's/888/'"$PORT"'/' $COMPOSE_FILE
sed -i 's/driver: local/'"driver: $VOLUME_DRIVER"'/' $COMPOSE_FILE

successLog "DONE."

# DEPLOYMENT
sectionLog "\nApplication deployment"
docker stack deploy -c $COMPOSE_FILE $STACK
if [ $? -eq 0 ]; then
  successLog "DONE."
else
  errorLog "DEPLOYMENT FAILED!"
  exit 1
fi

# START
printf "\nStarting swarmpit..."
SWARMPIT_NETWORK="${STACK}_net"
SWARMPIT_VERSION_URL="http://${STACK}_app:8080/version"
CURL_CMD="docker run --rm --network $SWARMPIT_NETWORK $CURL_IMAGE"
while true
do
  STATUS=$($CURL_CMD -s -o /dev/null -w '%{http_code}' $SWARMPIT_VERSION_URL)
  if [ $STATUS -eq 200 ]; then
    successLog "DONE."
    break
  else
    printf "."
    attempt_counter=$(($attempt_counter+1))
  fi
  if [ ${attempt_counter} -eq ${max_attempts} ]; then
      errorLog "FAILED!"
      warningLog "Swarmpit is not responding for a long time. Aborting installation...:(\nPlease check logs and cluster status for details."
      exit 1
  fi
  sleep 5
done

# INITIALIZATION
printf "Initializing swarmpit..."
SWARMPIT_INITIALIZE_URL="http://${STACK}_app:8080/initialize"
STATUS=$($CURL_CMD -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' $SWARMPIT_INITIALIZE_URL -d '{"username": "'"$ADMIN_USER"'", "password": "'"$ADMIN_PASS"'"}')
if [ $STATUS -eq 201 ]; then
  successLog "DONE."
  sectionLog "\nSummary"
  log "Username: $ADMIN_USER"
  log "Password: $ADMIN_PASS"
else
  warningLog "SKIPPED.\nInitialization was already done in previous installation.\nPlease use your old admin credentials to login or drop swarmpit database volume for clean installation."
  sectionLog "\nSummary"
fi

log "Swarmpit is running on port :$PORT"
titleLog "\nEnjoy :)"
