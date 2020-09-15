#!/bin/bash
#******************************************************************************
# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2019. All Rights Reserved.
#
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.
#******************************************************************************

# PREREQUISITES:
#   - Logged into cluster on the OC CLI (https://docs.openshift.com/container-platform/4.4/cli_reference/openshift_cli/getting-started-cli.html)
#
# PARAMETERS:
#   -n : <namespace> (string), Defaults to 'cp4i'
#   -r : <REPO> (string), Defaults to 'https://github.com/IBM/cp4i-deployment-samples.git'
#   -b : <BRANCH> (string), Defaults to 'main'
#   -t : <TKN-path> (string), Default to 'tkn'
#
#   With defaults values
#     ./build.sh
#
#   With overridden values
#     ./build.sh -n <namespace> -r <REPO> -b <BRANCH>

function usage() {
  echo "Usage: $0 -n <namespace> -r <REPO> -b <BRANCH> -t <TKN-path>"
  exit 1
}

namespace="cp4i"
tick="\xE2\x9C\x85"
cross="\xE2\x9D\x8C"
all_done="\xF0\x9F\x92\xAF"
SUFFIX="eei"
POSTGRES_NAMESPACE="postgres"
ACE_CONFIGURATION_NAME="ace-policyproject-$SUFFIX"
REPO="https://github.com/IBM/cp4i-deployment-samples.git"
BRANCH="main"
TKN=tkn

while getopts "n:r:b:t:" opt; do
  case ${opt} in
  n)
    namespace="$OPTARG"
    ;;
  r)
    REPO="$OPTARG"
    ;;
  b)
    BRANCH="$OPTARG"
    ;;
  t)
    TKN="$OPTARG"
    ;;
  \?)
    usage
    ;;
  esac
done

if [[ -z "${namespace// }" || -z "${REPO// }" || -z "${BRANCH// }" || -z "${TKN// }" ]]; then
  echo -e "$cross ERROR: Mandatory parameters are empty"
  usage
fi

CURRENT_DIR=$(dirname $0)
echo "INFO: Current directory: '$CURRENT_DIR'"
echo "INFO: Namespace: '$namespace'"
echo "INFO: Suffix for the postgres is: '$SUFFIX'"
echo "INFO: Repo: '$REPO'"
echo "INFO: Branch: '$BRANCH'"
echo "INFO: TKN: '$TKN'"

echo -e "\n----------------------------------------------------------------------------------------------------------------------------------------------------------\n"

echo "INFO: Creating pvc for EEI apps in the '$namespace' namespace"
if oc apply -n $namespace -f $CURRENT_DIR/pvc.yaml; then
  echo -e "\n$tick INFO: Successfully created the pvc in the '$namespace' namespace"
else
  echo -e "\n$cross ERROR: Failed to create the pvc in the '$namespace' namespace"
fi

echo -e "\n----------------------------------------------------------------------------------------------------------------------------------------------------------\n"

echo "INFO: Creating the pipeline to build and deploy the EEI apps in '$namespace' namespace"
if cat $CURRENT_DIR/pipeline.yaml |
  sed "s#{{NAMESPACE}}#$namespace#g;" |
  sed "s#{{FORKED_REPO}}#$REPO#g;" |
  sed "s#{{BRANCH}}#$BRANCH#g;" |
  oc apply -n ${namespace} -f -; then
    echo -e "\n$tick INFO: Successfully applied the pipeline to build and deploy the EEI apps in '$namespace' namespace"
else
  echo -e "\n$cross ERROR: Failed to apply the pipeline to build and deploy the EEI apps in '$namespace' namespace"
  exit 1
fi #pipeline.yaml

echo -e "\n----------------------------------------------------------------------------------------------------------------------------------------------------------\n"

PIPELINERUN_UID=$(
  LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 5
  echo
)
PIPELINE_RUN_NAME="eei-build-pipelinerun-${PIPELINERUN_UID}"

echo "INFO: Creating the pipelinerun for the EEI apps in the '$namespace' namespace with name '$PIPELINE_RUN_NAME'"
if cat $CURRENT_DIR/pipelinerun.yaml |
  sed "s#{{PIPELINE_RUN_NAME}}#$PIPELINE_RUN_NAME#g;" |
  oc apply -f -; then
  echo -e "\n$tick INFO: Successfully applied the pipelinerun for the EEI apps in the '$namespace' namespace"
else
  echo -e "\n$cross ERROR: Failed to apply the pipelinerun for the EEI apps in the '$namespace' namespace"
  exit 1
fi #pipelinerun.yaml

echo -e "\n----------------------------------------------------------------------------------------------------------------------------------------------------------\n"

echo -e "INFO: Displaying the pipelinerun logs: \n"
if ! $TKN pipelinerun logs -f $PIPELINE_RUN_NAME; then
  echo -e "\n$cross ERROR: Failed to get the pipelinerun logs successfully"
  exit 1
fi

echo -e "\n----------------------------------------------------------------------------------------------------------------------------------------------------------\n"

# Wait for up to 5 minutes for the pipelinerun for the simluator app to complete
time=0
while [ "$(oc get pipelinerun -n $namespace ${PIPELINE_RUN_NAME} -o json | jq -r '.status.conditions[0].status')" != "True" ]; do
  if [ $time -gt 5 ]; then
    echo -e "$cross ERROR: Timed out waiting for the pipelinerun to succeed"
    exit 1
  fi

  if [ "$(oc get pipelinerun -n $namespace ${PIPELINE_RUN_NAME} -o json | jq -r '.status.conditions[0].status')" == "False" ]; then
    echo -e "$cross ERROR: The pipelinerun has failed\n"
    oc get pipelinerun $PIPELINE_RUN_NAME
    exit 1
  fi

  echo -e "\nINFO: Waiting up to 5 minutes for the pipelinerun to finish. Waited ${time} minute(s)."
  time=$((time + 1))
  sleep 60
done

echo -e "\n$tick INFO: The pipelinerun has completed successfully, going ahead to delete the pipelinerun for it to delete the pods and the pvc\n"
oc get pipelinerun -n $namespace $PIPELINE_RUN_NAME

echo -e "\n----------------------------------------------------------------------------------------------------------------------------------------------------------\n"

if oc delete pipelinerun -n $namespace $(oc get pipelinerun -n $namespace | grep $PIPELINERUN_UID | awk '{print $1}'); then
  echo -e "$tick INFO: Deleted the pipelinerun with the uid '$PIPELINERUN_UID'"
else
  echo -e "$cross ERROR: Failed to delete the pipelinerun with the uid '$PIPELINERUN_UID'"
fi

echo -e "\n----------------------------------------------------------------------------------------------------------------------------------------------------------\n"

if oc delete pvc git-workspace-eei -n $namespace; then
  echo -e "$tick INFO: Deleted the pvc 'git-workspace-eei'"
else
  echo -e "$cross ERROR: Failed to delete the pvc 'git-workspace-eei'"
fi

echo -e "\n----------------------------------------------------------------------------------------------------------------------------------------------------------\n"

echo -e "\n$tick INFO: The applications have been deployed, but with zero replicas.\n"
oc get deployment -n $namespace -l demo=eei

echo ""
echo "To start the quote simulator app run the command 'oc scale deployment/quote-simulator-eei --replicas=1'"
echo "To start the projection claims app run the command 'oc scale deployment/projection-claims-eei --replicas=1'"