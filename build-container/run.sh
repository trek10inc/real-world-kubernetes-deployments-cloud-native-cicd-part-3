#!/bin/bash

# Required environment variables
# - DEPLOYMENT_MANIFEST_DIR
# - NON_DEPLOYMENT_MANIFEST_DIR

SLEEP="5"

# keep a few temp files on hand
SUCCESSFUL_DEPLOYMENTS="/tmp/tmp.1.$$.txt"
> ${SUCCESSFUL_DEPLOYMENTS}

ATTEMPTED_DEPLOYMENTS="/tmp/tmp.2.$$.txt"
> ${ATTEMPTED_DEPLOYMENTS}

SUCCESSFUL_MANIFESTS="/tmp/tmp.3.$$.txt"
> ${SUCCESSFUL_MANIFESTS}

#-------------------------------------------------------------------
# create some functions

function backup_current_objects () {
    MANIFEST=$1

    # get name and type for each object in the manifest
    cat ${MANIFEST} | yq -cM '.' 2>/dev/null | while read -r LINE; do
        NAME=$(echo $LINE | jq -rMc '.metadata.name')
        NAMESPACE=$(echo $LINE | jq -rMc '.metadata.namespace' 2>/dev/null)
        TYPE=$(echo $LINE | jq -rMc '.kind' | tr '[:upper:]' '[:lower:]')

        # save the current configuration for the object
        if [[ $NAMESPACE == "null" ]]; then
            kubectl get ${TYPE} ${NAME} -o json | jq -rMc '.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration"' | yq -y '.' 2>/dev/null > /tmp/${TYPE}-${NAME}-backup.yaml
        else
            kubectl get ${TYPE} ${NAME} -n ${NAMESPACE} -o json | jq -rMc '.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration"' | yq -y '.' 2>/dev/null > /tmp/${TYPE}-${NAME}-${NAMESPACE}-backup.yaml
        fi
    done
}

function separate_manifest_objects () {
    MANIFEST=$1

    # get name and type for each object in the manifest
    cat ${MANIFEST} | yq -cM '.' 2>/dev/null | while read -r LINE; do
        NAME=$(echo ${LINE} | jq -rMc '.metadata.name')
        NAMESPACE=$(echo ${LINE} | jq -rMc '.metadata.namespace' 2>/dev/null)
        TYPE=$(echo ${LINE} | jq -rMc '.kind' | tr '[:upper:]' '[:lower:]')

        if [[ $NAMESPACE == "null" ]]; then
            FILE_NAME="/tmp/${TYPE}-${NAME}.yaml"
        else
            FILE_NAME="/tmp/${TYPE}-${NAME}-${NAMESPACE}.yaml"
        fi

        echo "${LINE}" | yq -y '.' 2>/dev/null > $FILE_NAME
    done
}

#-------------------------------------------------------------------

# backup and separate all manifests
while read MANIFEST; do
    # backup the configs for objects in the manifest
    backup_current_objects ${MANIFEST}

    # separate objects in the manifest to individual files for granularity
    separate_manifest_objects ${MANIFEST}
done < <(ls ${DEPLOYMENT_MANIFEST_DIR}/*.yaml ${DEPLOYMENT_MANIFEST_DIR}/*.yml ${NON_DEPLOYMENT_MANIFEST_DIR}/*.yaml ${NON_DEPLOYMENT_MANIFEST_DIR}/*.yml 2>/dev/null)

# test all manifests for correctness
while read MANIFEST; do
    # lint the manifest first as a bad yaml file will not stop the loop
    echo "Linting ${MANIFEST}"
    cat ${MANIFEST} | yq -crM '.' >/dev/null 2>&1

    if [[ $? -gt 0 ]]; then
        echo "Error: Problem with ${MANIFEST} file syntax. Abandoning entire rollout"
        exit 1
    fi

    while read -r LINE; do
        NAME=$(echo $LINE | jq -rMc '.metadata.name')
        NAMESPACE=$(echo ${LINE} | jq -rMc '.metadata.namespace' 2>/dev/null)
        TYPE=$(echo $LINE | jq -rMc '.kind' | tr '[:upper:]' '[:lower:]')

        if [[ $NAMESPACE == "null" ]]; then
            OBJECT="${TYPE}-${NAME}"
        else
            OBJECT="${TYPE}-${NAME}-${NAMESPACE}"
        fi

        # test the non-deployment manifest
        kubectl apply -f /tmp/${OBJECT}.yaml --dry-run=client

        # check the return code for non-zero value
        if [[ $? -gt 0 ]]; then
            echo "Error: Problem with $OBJECT object file syntax. Abandoning entire rollout"
            exit 1
        fi
    done < <(cat ${MANIFEST} | yq -cM '.' 2>/dev/null)
done < <(ls ${NON_DEPLOYMENT_MANIFEST_DIR}/*.yaml ${NON_DEPLOYMENT_MANIFEST_DIR}/*.yml ${DEPLOYMENT_MANIFEST_DIR}/*.yaml ${DEPLOYMENT_MANIFEST_DIR}/*.yml 2>/dev/null)

# to keep track of failed deployments
FAILED_DEPLOYMENT=0

# loop through and apply non-deployment manifests (order of files may be important with regards to dependencies)
while read MANIFEST; do
    echo "Applying ${MANIFEST}"
    while read -r LINE; do
        NAME=$(echo $LINE | jq -rMc '.metadata.name')
        NAMESPACE=$(echo ${LINE} | jq -rMc '.metadata.namespace' 2>/dev/null)
        TYPE=$(echo $LINE | jq -rMc '.kind' | tr '[:upper:]' '[:lower:]')

        if [[ $NAMESPACE == "null" ]]; then
            OBJECT="${TYPE}-${NAME}"
        else
            OBJECT="${TYPE}-${NAME}-${NAMESPACE}"
        fi

        # apply the manifest
        kubectl apply -f /tmp/${OBJECT}.yaml

        # check the return code for non-zero value
        if [[ $? -gt 0 ]]; then
            # mark the entire deployment process as failed
            FAILED_DEPLOYMENT=1

            echo "Error: Problem with non-deployment object ${OBJECT}. Reverting rollout"
    
            # break out of loop
            break
        fi

        echo "${OBJECT}" >> ${SUCCESSFUL_MANIFESTS}
    done < <(cat ${MANIFEST} | yq -cM '.' 2>/dev/null)

    # no need to continue if the deployment has failed
    [[ ${FAILED_DEPLOYMENT} -gt 0 ]] && break

done < <(ls ${NON_DEPLOYMENT_MANIFEST_DIR}/*.yaml ${NON_DEPLOYMENT_MANIFEST_DIR}/*.yml 2>/dev/null)

# roll back all non-deployment manifests and exit (if needed)
if [[ ${FAILED_DEPLOYMENT} -gt 0 ]]; then
    cat ${SUCCESSFUL_MANIFESTS} | while read MANIFEST_TOKEN; do
        kubectl apply -f /tmp/${MANIFEST_TOKEN}-backup.yaml
    done

    exit 3
fi

# loop through and apply deployment manifests (order of files may be important with regards to dependencies)
while read MANIFEST; do
    while read -r LINE; do
        NAME=$(echo $LINE | jq -rMc '.metadata.name')
        NAMESPACE=$(echo ${LINE} | jq -rMc '.metadata.namespace' 2>/dev/null)
        TYPE=$(echo $LINE | jq -rMc '.kind' | tr '[:upper:]' '[:lower:]')

        if [[ $NAMESPACE == "null" ]]; then
            OBJECT="${TYPE}-${NAME}"
        else
            OBJECT="${TYPE}-${NAME}-${NAMESPACE}"
        fi

        # what is the current deployment name?
        CURRENT_DEPLOYMENT=$(echo ${LINE} | jq -crM '.metadata.name')

        # apply the manifest
        kubectl apply -f /tmp/${OBJECT}.yaml

        # check the return code for non-zero value
        if [[ $? -gt 0 ]]; then
            # mark the entire deployment process as failed
            FAILED_DEPLOYMENT=1

            echo "Error: Problem with deployment object ${OBJECT}. Reverting rollout"

            # break out of loop
            break
        fi

        # save for later
        echo "${CURRENT_DEPLOYMENT}:${NAMESPACE}" >> ${ATTEMPTED_DEPLOYMENTS}
    done < <(cat ${MANIFEST} | yq -cM '.' 2>/dev/null)

    # no need to continue if the deployment has failed
    [[ ${FAILED_DEPLOYMENT} -gt 0 ]] && break

done < <(ls ${DEPLOYMENT_MANIFEST_DIR}/*.yaml ${DEPLOYMENT_MANIFEST_DIR}/*.yml 2>/dev/null)

# roll back all deployment manifests and exit (if needed)
if [[ ${FAILED_DEPLOYMENT} -gt 0 ]]; then
    cat ${SUCCESSFUL_MANIFESTS} | while read MANIFEST_TOKEN; do
        kubectl apply -f /tmp/${MANIFEST_TOKEN}-backup.yaml
    done

    # roll back all attempted deployments
    cat ${ATTEMPTED_DEPLOYMENTS} | while read -r LINE; do
        DEPLOYMENT_NAME=$(echo $LINE | cut -d':' -f1)
        NAMESPACE=$(echo $LINE | cut -d':' -f2)

        if [[ $NAMESPACE == "null" ]]; then
            kubectl rollout undo deploy ${DEPLOYMENT_NAME}
        else
            kubectl -n ${NAMESPACE} rollout undo deploy ${DEPLOYMENT_NAME}
        fi
    done

    exit 4
fi

# monitor and manage deployment status
while true; do
    # sleep for a bit
    sleep $SLEEP

    # loop over the deployments in the manifest
    while read -r LINE; do
        CURRENT_DEPLOYMENT_NAME=$(echo $LINE | cut -d':' -f1)
        NAMESPACE=$(echo $LINE | cut -d':' -f2)

        # has the current deployment already completed?
        if [[ ! $(grep ${CURRENT_DEPLOYMENT_NAME} ${SUCCESSFUL_DEPLOYMENTS}) ]]; then
            # grab the deployment status
            echo "Checking status of ${CURRENT_DEPLOYMENT_NAME} deployment"

            if [[ $NAMESPACE == "null" ]]; then
                STATUS=$(kubectl get deploy ${CURRENT_DEPLOYMENT_NAME} -o json | jq -rM 'select(.status.conditions[].type == "Progressing") | .status.conditions | .[] | select(.reason == "NewReplicaSetAvailable" or .reason == "ProgressDeadlineExceeded") | .reason')
            else
                STATUS=$(kubectl get deploy ${CURRENT_DEPLOYMENT_NAME} -n ${NAMESPACE} -o json | jq -rM 'select(.status.conditions[].type == "Progressing") | .status.conditions | .[] | select(.reason == "NewReplicaSetAvailable" or .reason == "ProgressDeadlineExceeded") | .reason')
            fi

            # problem with rollout so bail on entire deployment
            if [[ $STATUS == "ProgressDeadlineExceeded" ]]; then
                echo "Error: Problem with ${CURRENT_DEPLOYMENT_NAME} deployment. Rolling back all updates"

                # roll back all non-deployment manifests
                cat ${SUCCESSFUL_MANIFESTS} | while read MANIFEST_TOKEN; do
                    kubectl apply -f /tmp/${MANIFEST_TOKEN}-backup.yaml
                done

                # undo all attempted rollouts
                cat ${ATTEMPTED_DEPLOYMENTS} | while read DEPLOYMENT_NAME; do
                    if [[ $NAMESPACE == "null" ]]; then
                        kubectl rollout undo deploy ${DEPLOYMENT_NAME}
                    else
                        kubectl -n ${NAMESPACE} rollout undo deploy ${DEPLOYMENT_NAME}
                    fi
                done
                
                exit 5
            fi

            if [[ $STATUS == "NewReplicaSetAvailable" ]]; then
                echo "Deployment ${CURRENT_DEPLOYMENT_NAME} Successful"
                echo "${CURRENT_DEPLOYMENT_NAME}" >> ${SUCCESSFUL_DEPLOYMENTS}
            fi
        fi
    done < <(cat ${ATTEMPTED_DEPLOYMENTS})

    # to keep track of deployments
    MANIFESTS_DEPLOYED=1

    # have we completed all attempted deployments?
    while read DEPLOYMENT_NAME; do
        [[ ! $(grep ${DEPLOYMENT_NAME} ${SUCCESSFUL_DEPLOYMENTS}) ]] && MANIFESTS_DEPLOYED=0
    done < <(cut -d':' -f1 ${ATTEMPTED_DEPLOYMENTS})

    # break out of while loop if current deployments have completed 
    [[ ${MANIFESTS_DEPLOYED} -gt 0 ]] && break
done