#!/bin/bash
set -e

echo "Starting build process..."

echo "Adding env variables..."
export PATH=/root/bin:$PATH

#Path to k8s config file
KUBECONFIG=~/devel/blockchain-automation-framework/build/kubeconfig.yaml


echo "Running the playbook..."
exec ansible-playbook -vv ~/devel/blockchain-automation-framework/platforms/shared/configuration/site.yaml --inventory-file=~/devel/blockchain-automation-framework/platforms/shared/inventory/ -e "@~/devel/blockchain-automation-framework/build/networks/initial-network.yaml" -e 'ansible_python_interpreter=/usr/bin/python3'
