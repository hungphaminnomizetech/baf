#!/bin/bash
# shellcheck disable=SC2009,SC1090
#
# Run this on your developer box (Linux instance), or a CI/CD server, to install Ansible,
# Terraform, jq, Python 3, etc.
#
#   - the 'CI/CD server' term includes any server that runs Ansible, such as
#     an Ansible control machine / build server
#
# Supports Ubuntu 20.04, typically in a Linux instance or on CI/CD server
#
# - Mac not supported - some Mac specific code remains but would require more work.
#   Better to use Linux VMs on Mac
#
# Prerequisites: On laptops and servers - Ubuntu 20.04 on Vagrant VM, WSL (Win10)
#
# Does require sudo for Linux:
#
#   - on laptops, including VMs, run this script directly from a sudo-allowed user (e.g. vagrant
#     or ubuntu) so sudo can prompt for password (or use a passwordless sudo user)
#   - on servers, must run from an 'opsadmin' user which has passwordless sudo
#
# We use the term 'system level' to mean installs into /usr/local that are
# available across all users.  On servers, we must use sudo from 'opsadmin' user
# for system level installs.  This can be contrasted with 'user level' installs
# within a user's home directory (e.g. npm global installs, or Ruby user-installs).
#
# NOTE: If you upgrade Ansible version and start depending on certain features,
# you can change min_ansible_version in the 'inv/group_vars/all.yml' file and check
# it in playbooks that require this version.
#
# To test, uninstall most tools with ./dev-bootstrap/.uninstall.sh (Ubuntu only)
#
# To skip some parts when developing, set BOOTSTRAP_SKIP='python venv' env var
# (or some subset, space separated) - this should only be required when 'is it
# installed' for idempotent code is too difficult

# Stop on error - mostly can't use '-u' as it breaks various source commands
set -e

# Setup
# NOTE: not supporting CI/CD setup at present, just generic servers that need dev tools
# ci_user=jenkins         # Default

echo "This script installs Ansible, Terraform and other tools."
echo
echo "Significant changes are made to Python setup on this machine - if you"
echo "need to know what, read this script and the Ansible base-client role."
echo

# ========================= Get to top of baf tree ==========================

# Get directory containing this script
function script_dir() {
    local dir
    dir="$( cd "$( dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null)"
    echo -n "$dir"
}

# ========================= Detect OS and hypervisor ==========================

# Detect OS and family (Debian for Ubuntu, or Red Hat for RHEL or CentOS)
os=linux
osfamily=debian
if [[ "$(uname -s)" = 'Darwin' ]]; then
    os=mac
    osfamily=mac
elif [[ -r /etc/centos-release || -r /etc/redhat-release ]]; then
    # CentOS has both centos-release and redhat-release
    os=linux
    osfamily=redhat
fi

# Non-supported platforms
if [[ "$os" = 'redhat' ]] || [[ "$os" = 'mac' ]]; then
    echo >&2 "Error: detected OS '$os' / '$osfamily' - not supported"
    exit 1
fi

# Detect if on WSL or Oracle VirtualBox
variant=$(systemd-detect-virt)

# ========================= Detect CI/CD etc ==================================

# Detect if we are on server by checking that vagrant user does not exist
export on_server=false
if ! id -u "vagrant" >&/dev/null; then
    on_server=true
fi

# ========================= Handle sudo prompt cases ==================================

# Sudo to root only required on Linux, for installs under /usr/local etc
sudo='sudo -H'          # Must use -H on Ubuntu <= 19.10, doesn't hurt on other distros
if [[ $os == 'mac' ]]; then
    # Using brew with /usr/local owned by current user (see `fix-brew.sh`), so no sudo required
    sudo=''
fi

# Cloud platform
cloud=aws
: $cloud

# Python version from Ubuntu
py_major_version=3.8
py_major_2digit=38

# Ansible version to be installed
ansible_version=2.9.23           # Release - ignored if installing release candidate
jinja2_version=2.11.2

pypi_install=true                # Set this to true for release, or false for release candidate
# Only if Ansible RC is required for urgent bug fix
rc_version='v2.8.6.0-0.4.rc2'    # Release candidate - ignored if installing release, should include 'v2.' at front

pipversion=20.2.2                # TODO: Need single version spec for this and Ansible roles
# virtualenv_version=16.7.5      # Not currently installed via pip

# Set reduced PATH (mostly for WSL which has many /mnt/c dirs in PATH, including spaces in names)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:

# ========================= Python and pip install ====================================

# Python versions and virtualenvs:
#
# - For Ansible and Testinfra, we later create a virtualenv using Python 3 on Ubuntu

# Deactivate Python virtualenv if we're in one - normally the case
if [ -s "${VIRTUAL_ENV:-}" ]; then
    # shellcheck disable=SC2001
    PATH=$(echo $PATH | sed "s|${VIRTUAL_ENV}/bin:||")
    unset VIRTUAL_ENV
    unset PYTHONHOME
fi

# Stop pip from warning about version upgrades. This doesn't affect commands run
# with sudo as that wipes the environment
export PIP_DISABLE_PIP_VERSION_CHECK=1

if [[ ${BOOTSTRAP_SKIP:-} != *python* ]]; then
    dir=/tmp    # Downloads

    if [[ $osfamily == 'debian' ]]; then

        # Use python3 on Ubuntu or Mac
        echo -e "Installing build tools\n"
        sudo apt-get update

        # Install dev tools for Python/Ruby builds, etc - we include 'python' and 'zip' for unusual Ubuntu variants
        # that may not have this
        sudo apt-get install -y build-essential python3-dev libffi-dev libssl-dev zip unzip

        # No need for 'python3' symlink - it's already there in Ubuntu 20.04
        # sudo ln -sf /usr/bin/python${py_major_version} /usr/local/bin/python3

        python3 -m pip --version || true      # pip3 command may be broken at this point

    else

        # Mac makes Python setup painful if /usr/local permissions are wrong - fix permissions if you have problems
        (
            # Install Python 3

            # To avoid updating all brew packages on every run, set brew to auto-update only once every day
            export HOMEBREW_AUTO_UPDATE_SECS=86400

            # Python 3 inc symlinks
            echo 'Installing latest Python 3'
            brew install python3
            brew upgrade python3
            brew unlink python3
            brew link --overwrite python3

            # Get rid of 'pip' command
            rm -f /usr/local/bin/pip      # This is often broken in brew setup

            # All scripts should use python3 / pip3, or preferably 'python3 -m pip'
            python3 -m pip --version      # pip3 command is often broken at this point
        )

    fi

    # Install recent version of pip at system level, for use outside virtualenvs
    if [[ "$osfamily" == 'debian' || "$os" == 'mac' ]]; then

        # >>>>>>> pip for Python 3

        # Ubuntu or Mac pip3 - always uninstall and re-install
        echo "Upgrading pip3 to version $pipversion"
        if [[ "$os" == 'linux' ]]; then
            # On Ubuntu, first uninstall then reinstall pip3 - sometimes the distro pip3 is broken
            sudo apt-get remove --yes python3-pip
            sudo apt-get install --yes python3-pip
        fi
        # Mac and Linux - Install right version of pip into /usr/local/bin/pip3
        # - this may upgrade dependencies such as setuptools
        $sudo rm -f /usr/local/bin/pip3 /usr/local/bin/pip3.[1-9]*             # Remove any symlinks from brew or non-OS pip installs
        set -e
        # Using 'python3 -m pip' avoids any issues with broken 'pip3' command, and ensures right Python version
        $sudo python3 -m pip uninstall --yes pip || true   # pip module may not exist

        # Note this may upgrade dependencies such as setuptools
        $sudo python3 -m pip install --upgrade --force "pip==$pipversion"
        set +e

        python3 -m pip --version
        py_prefix=/usr/local/bin

    fi

    echo 'Python and pip path summary'
    ls -ld $py_prefix/{pip,python}*

    # We should now have a good version of Python 3 and pip3
fi

# Since previous section can be skipped, point to Python we are using in venv-main for rest of script
if [[ "$osfamily" == 'debian' || "$os" == 'mac' ]]; then
    python=python3
elif [[ "$osfamily" == 'redhat' ]]; then
    # Note we can also use python3 outside venv-main for code not using yum, e.g. for testinfra tests
    python=python2
fi

# ========================= Environment setup ==================================

# For laptop and server, we install under home dir for current user
export target_home=$HOME                    # Laptop and server

# ========================= Python virtualenv usage ==================================

set -e

# Activate virtualenv - avoids activate script breaking when 'set -u' is enabled
enter_venv() {
    OLD_PATH=$PATH
    OLD_PYTHONHOME=${PYTHONHOME:-}
    export VIRTUAL_ENV="$HOME/venv-main"
    export PATH="$VIRTUAL_ENV/bin:$PATH"
    unset PYTHONHOME
}

# Deactivate virtualenv
exit_venv() {
    unset VIRTUAL_ENV
    # Only revert vars if backup var exists
    PATH="${OLD_PATH:-$PATH}"
    if [[ "${OLD_PYTHONHOME:-}" != "" ]]; then
        export PYTHONHOME="$OLD_PYTHONHOME"
    fi
}

# Deactivate Python virtualenv if we're in one - normally the case
if [ -s "${VIRTUAL_ENV:-}" ]; then
    # shellcheck disable=SC2001
    PATH=$(echo $PATH | sed "s|${VIRTUAL_ENV}/bin:||")
    unset VIRTUAL_ENV
    unset PYTHONHOME
fi

/usr/bin/python3 -m pip install --upgrade pip

# ========================= Python virtualenv creation ==================================

# Allow venv creation to be skipped on Ubuntu only
install_venv=true
if [[ "$osfamily" == 'debian' && ${BOOTSTRAP_SKIP:-} == *venv* ]]; then
    install_venv=false
fi
if $install_venv; then
    # Create an isolated Python 'virtualenv' - best practice to isolate Ansible related packages
    # from packages installed under system Python

    # Install vex for easier virtualenv activation and deactivation from scripts
    $sudo $python -m pip install vex

    # Install virtualenv for Python globally
    # $sudo $python -m pip install --upgrade --force "virtualenv==$virtualenv_version"

    # Create virtualenv 'venv-main' - remove any existing virtualenv first
    $sudo rm -rf ~/venv-main
    python_path=$(command -v $python)
    echo ">>>>> Copying $python_path into virtualenv - $($python_path -V 2>&1)"
    $python -m virtualenv -p $python_path ~/venv-main      # Installs python binary into the virtualenv

    # Activate virtualenv
    enter_venv
    echo ">>>>> Virtualenv Python is $(command -v python) - $(python -V 2>&1)"

    # Install extra packages inside virtualenv
    if [[ $osfamily == 'debian' ]]; then

        # For Ubuntu, we install the APT package python3-apt (required by the Ansible 'apt' modules) into this virtualenv.

        # Install python3-apt package into virtualenv, based on https://github.com/ansible/ansible/issues/14468#issuecomment-459630445
        # TBC: This package must be installed with extra steps so it works inside virtualenv with Python 3.8
        #
        # Download and extract python3-apt files into /tmp/python3-apt
        pushd /tmp
        # Remove any older python3-apt packages then get latest one
        sudo rm -f python3-apt_*.deb
        sudo apt-get update
        sudo apt-get download python3-apt
        pkg_path=$(ls -t /tmp/python3-apt*.deb)
        dpkg -x $pkg_path python3-apt
        popd

        # Install python3-apt files into virtualenv
        cp -r /tmp/python3-apt/usr/lib/python3/dist-packages/* ~/venv-main/lib/python${py_major_version}/site-packages/
        #
        # Rename shared libs inside the virtualenv packages dir
        pushd ~/venv-main/lib/python${py_major_version}/site-packages/
        mv apt_pkg.cpython-${py_major_2digit}-x86_64-linux-gnu.so apt_pkg.so
        mv apt_inst.cpython-${py_major_2digit}-x86_64-linux-gnu.so apt_inst.so
        popd

    fi

    # ========================= Ansible install ==================================

    # Warn about non-virtualenv Ansible and dependencies
    exit_venv  || true
    if pip freeze | grep --silent '^ansible'; then
        echo WARNING: Ansible is installed outside virtualenv - please uninstall with:
        echo
        echo "   $sudo $python -m pip uninstall --yes ansible urllib3"
        echo
        exit 1
    fi

    # Install Ansible using pip inside main venv - also installs any required Python dependencies
    echo Installing Ansible using Python in virtualenv ~/venv-main

    # Activate virtualenv
    enter_venv

    # Install Jinja2 separately
    $python -m pip install --upgrade Jinja2==$jinja2_version

    # Install Ansible release from PyPI or a release candidate from tarball
    if $pypi_install; then
        # Check Ansible version inside virtualenv and install Ansible
        ansiblecurrent=''
        if command -v ansible >&/dev/null; then
            ansiblecurrent="$(ansible --version 2>/dev/null | sed -n '1s/^ansible //p')"
        fi

        if [ "$ansiblecurrent" != "$ansible_version" ]; then
            $python -m pip install --upgrade "ansible==${ansible_version}"
        else
            # Do nothing by default - faster to not uninstall in normal case when no RCs used
            :
            # If previous release might have been a release candidate, must uninstall first
            # (no obvious way to detect RC version).  If you install an RC, be sure to uncomment this
            # code before the next release.
            # $sudo python3 -m pip uninstall --yes ansible
        fi
    else
        # For release candidates, install from tarball
        enter_venv
        tarfile=$dir/ansible-${rc_version}.tar.gz
        if [ ! -r $tarfile ]; then
            $sudo curl --location --output $tarfile https://github.com/ansible/ansible/archive/${rc_version}.tar.gz
        fi
        $python -m pip install --upgrade $tarfile
    fi
fi

# Check Ansible is installed
enter_venv
ansible=$(command -v ansible || true)
if [ "$ansible" != "$HOME/venv-main/bin/ansible" ]; then
    echo Ansible install did not work - once fixed, please re-run this script.
    exit 1
fi

# Ansible fact cache setup
sudo mkdir -p /opt/ansible_cache
sudo chown $USER: /opt/ansible_cache
# Check permissions
touch /opt/ansible_cache/testfile && rm /opt/ansible_cache/testfile

# AWS and ssh dirs
mkdir -p ~/.aws ~/.ssh/regn
chmod 755 ~/.aws ~/.ssh ~/.ssh/regn

# Simplified ansible.cfg for bootstrap
export ANSIBLE_CONFIG=/vagrant/dev-bootstrap/ansible.cfg

set +e



echo -e "\nAnsible installed inside virtualenv - path: $(type ansible)"

echo "Test Ansible including inventory"
# Fails if inventory missing or inventory var not set correctly
invfile=/vagrant/dev-bootstrap/inv-bootstrap.yml
pushd ansible
if [ ! -r $invfile ]; then
    echo "No Ansible inventory found, exiting"
    exit 1
elif ! ansible -i $invfile -m assert -a "that='{{ inventory_ok == \"true\" }}'" all; then
    echo "Ansible test failed, exiting"
    exit 1
fi
popd

echo -e "\n>>>> Ansible passed test\n"
