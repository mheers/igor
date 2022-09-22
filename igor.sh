#! /bin/bash

# This is igor.

# Original project: https://github.com/mheers/igor

# Install / update:
#   sudo curl https://raw.githubusercontent.com/mheers/igor/master/igor.sh -o /usr/local/bin/igor
#   sudo chmod +x /usr/local/bin/igor

set -e
shopt -s extglob;

# set up default values
IGOR_DOCKER_IMAGE=busybox         # select docker image
IGOR_DOCKER_COMMAND=sh            # run this command inside the docker container
IGOR_DOCKER_PULL=0                # force pulling the image before starting the container (0/1)
IGOR_DOCKER_RM=1                  # remove container on exit (0/1)
IGOR_DOCKER_LOGIN=0               # logging into repository before start
IGOR_DOCKER_REPOSITORY_USERNAME=  # username used to log into repository
IGOR_DOCKER_REPOSITORY_PASSWORD=  # password used to log into repository (leave empty for stdin)
IGOR_DOCKER_TTY=1                 # open an interactive tty (0/1)
IGOR_DOCKER_USER=$(id -u)         # run commands inside the container with this user
IGOR_DOCKER_GROUP=$(id -g)        # run commands inside the container with this group
IGOR_DOCKER_NETWORK='bridge'      # docker network (bridge, container, host or none)
IGOR_DOCKER_ARGS=''               # default arguments to docker run
IGOR_PORTS=''                     # space separated list of ports to expose
IGOR_MOUNT_PASSWD=0               # mount /etc/passwd inside the container (0/1)
IGOR_MOUNT_GROUP=0                # mount /etc/group inside the container (0/1)
IGOR_MOUNTS_RO=''                 # space separated list of volumes to mount read only
IGOR_MOUNTS_RW=''                 # space separated list of volumes to mount read write
IGOR_WORKDIR=${PWD}               # use this workdir inside the container
IGOR_WORKDIR_MODE=rw              # mount the workdir with this mode (ro/rw)
IGOR_ENV=''                       # space separated list of environment variables set inside the container

igor_config=.igor.sh

function usage() {
    echo "$0 [-v|--verbose] [-c|--config path-to-igor-config] [-i|--init] [-h|--help]"
    echo ''
    echo 'Opens a shell in your favorite docker container mounting your current workspace into the container'
    echo ''
    echo '  -c --config  specify igor config directory'
    echo '  -i --init    create empty igor config in current working directory'
    echo '  -v --verbose prints debug messages'
    echo '  -h --help    prints this message'
    echo ''
    echo 'configuration files:'
    echo ''
    echo '~/.igor.sh'
    echo './.igor.sh or file specified with -c option'
    echo ''
    echo 'default config:'
    echo ''
    grep '^IGOR_' $0
    echo ''
    exit 1
}

function init() {
  echo '# This is igors config' > .igor.sh
  echo '# Original project: https://github.com/mheers/igor' >> .igor.sh
  echo '# Install / update:' >> .igor.sh
  echo '#   sudo curl https://raw.githubusercontent.com/mheers/igor/master/igor.sh -o /usr/local/bin/igor' >> .igor.sh
  echo '#   sudo chmod +x /usr/local/bin/igor' >> .igor.sh
  echo '' >> .igor.sh
  grep '^IGOR_' $0 >> .igor.sh
  echo 'default igor config saved to .igor.sh'
  exit 0
}

function login() {
    IMAGE="${1}"
    USERNAME="${2}"
    PASSWORD="${3}"

    # extract repository
    if [[ "${IMAGE}" =~ ^([a-z0-9\.\-]+\/){1}([a-z0-9\.\-]+\/)*([a-z0-9\.\-]+)(:[a-z0-9\.\-]+)?$ ]]; then
        REPOSITORY="${BASH_REMATCH[1]}"

        if [[ -n "${PASSWORD}" ]]; then
            echo "${PASSWORD}" \
                | docker login \
                -u "${USERNAME}" \
                --password-stdin \
                "${REPOSITORY}"
        else
            docker login \
                -u "${USERNAME}" \
                "${REPOSITORY}"
        fi
    else
        echo "IGOR_DOCKER_IMAGE doesn't seem to have repository in it."
        echo "Login not possible! Aborting."
        exit 1
    fi
}

# ugly command line parsing
while [[ $# -gt 0 ]]; do
  if [ "${1}" == '-v' ] || [[ "${1}" == '--verbose' ]]; then
      shift
      set -x
  elif [[ "${1}" == '-c' ]] || [[ "${1}" == '--config' ]]; then
      if [ -z "${2}" ] || ! [ -e "${2}" ]; then
          usage
      fi
      igor_config="${2}"
      shift
      shift
  elif [[ "${1}" == '-i' ]] || [[ "${1}" == '--init' ]]; then
      init
  elif [[ "${1}" == '-h' ]] || [[ "${1}" == '--help' ]]; then
      usage
  elif [[ "${1}" == '--' ]]; then
      shift
      break
  else
      break
  fi
done

# check installed container-cli
cli_cmd=''
if [ -x "$(command -v podman)" ]; then
    cli_cmd="podman"
elif [ -x "$(command -v docker)" ]; then
    cli_cmd="docker"
else
    echo "No container cli tool found! Aborting."
fi

# load config from home
if [ -e "${HOME}/.igor.sh" ]; then
    . "${HOME}/.igor.sh"
fi

# load config from current working dir
if [ -e "${igor_config}" ]; then
    . "${igor_config}"
fi

# docker login
if [ "${IGOR_DOCKER_LOGIN}" == "1" ] && [ -n "${IGOR_DOCKER_REPOSITORY_USERNAME}" ]; then
    login "${IGOR_DOCKER_IMAGE}" "${IGOR_DOCKER_REPOSITORY_USERNAME}" "${IGOR_DOCKER_REPOSITORY_PASSWORD}"
fi

# assamble command line
if [ ${IGOR_DOCKER_PULL} -gt 0 ]; then
    docker pull "${IGOR_DOCKER_IMAGE}"
fi

args=''
if [ ${IGOR_DOCKER_RM} -gt 0 ]; then
    args="${args} --rm"
fi
if [ ${IGOR_DOCKER_TTY} -gt 0 ]; then
    args="${args} -ti"
fi
for p in ${IGOR_PORTS}; do
    args="${args} -p ${p}:${p}"
done
if [ ${IGOR_MOUNT_PASSWD} -gt 0 ]; then
    args="${args} -v /etc/passwd:/etc/passwd:ro"
fi
if [ ${IGOR_MOUNT_GROUP} -gt 0 ]; then
    args="${args} -v /etc/group:/etc/group:ro"
fi
for v in ${IGOR_MOUNTS_RO}; do
    args="${args} -v ${v}:${v}:ro"
    # make sure file or directory exists
    # otherwise docker will create it with root:root permissions
    if [ ! -e "${v}" ]; then
        mkdir -p "${v}"
    fi
done
for v in ${IGOR_MOUNTS_RW}; do
    args="${args} -v ${v}:${v}:rw"
    # make sure file or directory exists
    # otherwise docker will create it with root:root permissions
    if [ ! -e "${v}" ]; then
        mkdir -p "${v}"
    fi
done
for e in ${IGOR_ENV}; do
    args="${args} -e ${e}=${!e}"
done

# disable the uid/gid setting in podman
uid_gid=''
if [ ${cli_cmd} == 'docker' ]; then
    uid_gid="-u "${IGOR_DOCKER_USER}:${IGOR_DOCKER_GROUP}""
fi

# execute!
exec ${cli_cmd} run \
    ${args} \
    ${uid_gid} \
    --network ${IGOR_DOCKER_NETWORK} \
    -v "${PWD}:${IGOR_WORKDIR}:${IGOR_WORKDIR_MODE}" \
    -w "${IGOR_WORKDIR}" \
    ${IGOR_DOCKER_ARGS} \
    "${IGOR_DOCKER_IMAGE}" \
    ${IGOR_DOCKER_COMMAND} \
    "${@}"
