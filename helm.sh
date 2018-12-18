#!/bin/bash

SHELL_DIR=$(dirname $0)

. ${SHELL_DIR}/common.sh
. ${SHELL_DIR}/default.sh

################################################################################

title() {
    if [ -z ${TPUT} ]; then
        tput clear
    fi

    echo
    _echo "${THIS_NAME}" 3
    echo
    _echo "${CLUSTER_NAME}" 4
}

prepare() {
    logo

    mkdir -p ~/.ssh
    mkdir -p ~/.aws
    mkdir -p ${SHELL_DIR}/build

    NEED_TOOL=
    command -v jq > /dev/null      || export NEED_TOOL=jq
    command -v git > /dev/null     || export NEED_TOOL=git
    command -v aws > /dev/null     || export NEED_TOOL=awscli
    command -v kubectl > /dev/null || export NEED_TOOL=kubectl
    command -v helm > /dev/null    || export NEED_TOOL=helm

    if [ ! -z ${NEED_TOOL} ]; then
        question "Do you want to install the required tools? (awscli,kubectl,helm...) [Y/n] : "

        if [ "${ANSWER:-Y}" == "Y" ]; then
            ${SHELL_DIR}/tools.sh
        else
            _error "Need install tools."
        fi
    fi

    REGION="$(aws configure get default.region)"
}

run() {
    prepare

    get_cluster

    config_load

    main_menu
}

press_enter() {
    _result "$(date)"
    echo
    _read "Press Enter to continue..." 5
    echo

    case ${1} in
        main)
            main_menu
            ;;
        kube-ingress)
            charts_menu "kube-ingress"
            ;;
        kube-system)
            charts_menu "kube-system"
            ;;
        monitor)
            charts_menu "monitor"
            ;;
        devops)
            charts_menu "devops"
            ;;
        sample)
            sample_menu
            ;;
        istio)
            istio_menu
            ;;
    esac
}

main_menu() {
    title

    echo
    _echo "1. helm init"
    echo
    _echo "2. kube-ingress.."
    _echo "3. kube-system.."
    _echo "4. monitor.."
    _echo "5. devops.."
    _echo "6. sample.."
    _echo "7. istio.."
    echo
    _echo "9. remove"
    # echo
    # _echo "s. security"
    echo
    _echo "u. update self"
    _echo "t. update tools"
    echo
    _echo "x. Exit"

    question

    case ${ANSWER} in
        1)
            helm_init
            press_enter main
            ;;
        2)
            charts_menu "kube-ingress"
            ;;
        3)
            charts_menu "kube-system"
            ;;
        4)
            charts_menu "monitor"
            ;;
        5)
            charts_menu "devops"
            ;;
        6)
            sample_menu
            ;;
        7)
            istio_menu
            ;;
        9)
            helm_delete
            press_enter main
            ;;
        s)
            elb_security
            press_enter main
            ;;
        u)
            update_self
            press_enter cluster
            ;;
        t)
            update_tools
            press_enter cluster
            ;;
        x)
            _success "Good bye!"
            ;;
        *)
            main_menu
            ;;
    esac
}

istio_menu() {
    title

    echo
    _echo "1. install"
    echo
    _echo "2. injection show"
    _echo "3. injection enable"
    _echo "4. injection disable"
    echo
    _echo "9. remove"

    question

    case ${ANSWER} in
        1)
            istio_install
            press_enter istio
            ;;
        2)
            istio_injection
            press_enter istio
            ;;
        3)
            istio_injection "enable"
            press_enter istio
            ;;
        4)
            istio_injection "disable"
            press_enter istio
            ;;
        9)
            istio_delete
            press_enter istio
            ;;
        *)
            main_menu
            ;;
    esac
}

sample_menu() {
    title

    LIST=${SHELL_DIR}/build/${THIS_NAME}-sample-list

    # find sample
    ls ${SHELL_DIR}/charts/sample | grep yaml | sort | sed 's/.yaml//' > ${LIST}

    # select
    select_one

    if [ -z ${SELECTED} ]; then
        main_menu
        return
    fi

    # sample install
    sample_install ${SELECTED} dev

    press_enter sample
}

charts_menu() {
    title

    NAMESPACE=$1

    LIST=${SHELL_DIR}/build/${THIS_NAME}-charts-list

    # find chart
    ls ${SHELL_DIR}/charts/${NAMESPACE} | sort | sed 's/.yaml//' > ${LIST}

    # select
    select_one

    if [ -z ${SELECTED} ]; then
        main_menu
        return
    fi

    # create_cluster_role_binding cluster-admin ${NAMESPACE}

    # helm install
    helm_install ${SELECTED} ${NAMESPACE}

    press_enter ${NAMESPACE}
}

helm_install() {
    helm_check

    NAME=${1}
    NAMESPACE=${2}

    create_namespace ${NAMESPACE}

    # helm check FAILED
    COUNT=$(helm ls -a | grep ${NAME} | grep ${NAMESPACE} | grep "FAILED" | wc -l | xargs)
    if [ "x${COUNT}" != "x0" ]; then
        _command "helm delete --purge ${NAME}"
        helm delete --purge ${NAME}
    fi

    # helm chart
    CHART=${SHELL_DIR}/build/${THIS_NAME}-helm-${NAME}.yaml
    get_template charts/${NAMESPACE}/${NAME}.yaml ${CHART}

    # chart repository
    REPO=$(cat ${CHART} | grep chart-repo | awk '{print $3}')
    if [ "${REPO}" == "" ]; then
        REPO="stable/${NAME}"
    else
        PREFIX="$(echo ${REPO} | cut -d'/' -f1)"
        if [ "${PREFIX}" == "custom" ]; then
            REPO="${SHELL_DIR}/${REPO}"
        fi
    fi

    # chart config
    VERSION=$(cat ${CHART} | grep chart-version | awk '{print $3}')
    INGRESS=$(cat ${CHART} | grep chart-ingress | awk '{print $3}')

    # chart version
    if [ "${VERSION}" == "" ] || [ "${VERSION}" == "latest" ]; then
        VERSION=$(helm search stable/${NAME} | grep "stable/${NAME} " | awk '{printf $2}' | head -1 | xargs)

        if [ "${VERSION}" != "" ]; then
            _replace "s/chart-version:.*/chart-version: ${VERSION}/g" ${CHART}
        fi
    fi

    # global
    _replace "s/AWS_REGION/${REGION}/g" ${CHART}
    _replace "s/CLUSTER_NAME/${CLUSTER_NAME}/g" ${CHART}

    # for nginx-ingress
    if [ "${NAME}" == "nginx-ingress" ]; then
        get_base_domain
    fi

    # for efs-provisioner
    if [ "${NAME}" == "efs-provisioner" ]; then
        efs_create
    fi

    # for cluster-autoscaler
    if [ "${NAME}" == "cluster-autoscaler" ]; then
        COUNT=$(kubectl get no | grep Ready | grep master | wc -l | xargs)
        if [ "x${COUNT}" != "x0" ]; then
            _replace "s/#:MASTER://g" ${CHART}
        fi
    fi

    # for jenkins
    if [ "${NAME}" == "jenkins" ]; then
        # admin password
        read_password ${CHART}

        # jenkins jobs
        ${SHELL_DIR}/jenkins/jobs.sh ${CHART}
    fi

    # for sonatype-nexus
    if [ "${NAME}" == "sonatype-nexus" ]; then
        # admin password
        read_password ${CHART}
    fi

    # for grafana
    if [ "${NAME}" == "grafana" ]; then
        # admin password
        read_password ${CHART}

        # ldap
        question "Enter grafana LDAP secret : "
        GRAFANA_LDAP="${ANSWER}"
        _result "secret: ${GRAFANA_LDAP}"

        if [ "${GRAFANA_LDAP}" != "" ]; then
            _replace "s/#:LDAP://g" ${CHART}
            _replace "s/GRAFANA_LDAP/${GRAFANA_LDAP}/g" ${CHART}
        fi
    fi

    # for fluentd-elasticsearch
    if [ "${NAME}" == "fluentd-elasticsearch" ]; then
        # host
        question "Enter elasticsearch host [elasticsearch-client] : "
        CUSTOM_HOST=${ANSWER:-elasticsearch-client}
        _result "host: ${CUSTOM_HOST}"
        _replace "s/CUSTOM_HOST/${CUSTOM_HOST}/g" ${CHART}

        # port
        question "Enter elasticsearch port [9200]: "
        CUSTOM_PORT=${ANSWER:-9200}
        _result "port: ${CUSTOM_PORT}"
        _replace "s/CUSTOM_PORT/${CUSTOM_PORT}/g" ${CHART}
    fi

    # for efs-mount
    if [ ! -z ${EFS_ID} ]; then
        _replace "s/#:EFS://g" ${CHART}
    fi

    # for istio
    if [ "${ISTIO}" == "true" ]; then
        COUNT=$(kubectl get ns ${NAMESPACE} --show-labels | grep 'istio-injection=enabled' | wc -l | xargs)
        if [ "x${COUNT}" != "x0" ]; then
            ISTIO_ENABLED=true
        else
            ISTIO_ENABLED=false
        fi
    else
        ISTIO_ENABLED=false
    fi
    _replace "s/ISTIO_ENABLED/${ISTIO_ENABLED}/g" ${CHART}

    if [ "${INGRESS}" == "true" ]; then
        if [ -z ${BASE_DOMAIN} ]; then
            DOMAIN=

            _replace "s/SERVICE_TYPE/LoadBalancer/g" ${CHART}
            _replace "s/INGRESS_ENABLED/false/g" ${CHART}
        else
            DOMAIN="${NAME}-${NAMESPACE}.${BASE_DOMAIN}"

            _replace "s/SERVICE_TYPE/ClusterIP/g" ${CHART}
            _replace "s/INGRESS_ENABLED/true/g" ${CHART}
            _replace "s/INGRESS_DOMAIN/${DOMAIN}/g" ${CHART}
        fi
    fi

    # check exist persistent volume
    LIST=${SHELL_DIR}/build/${THIS_NAME}-pvc-${NAME}-yaml
    cat ${CHART} | grep chart-pvc | awk '{print $3,$4,$5}' > ${LIST}
    while IFS='' read -r line || [[ -n "$line" ]]; do
        ARR=(${line})
        check_exist_pv ${NAMESPACE} ${ARR[0]} ${ARR[1]} ${ARR[2]}
        RELEASED=$?
        if [ "${RELEASED}" -gt "0" ]; then
            echo "  To use an existing volume, remove the PV's '.claimRef.uid' attribute to make the PV an 'Available' status and try again."
            return;
        fi
    done < "${LIST}"

    # helm install
    _command "helm upgrade --install ${NAME} ${REPO} --namespace ${NAMESPACE} --values ${CHART}"
    helm upgrade --install ${NAME} ${REPO} --namespace ${NAMESPACE} --values ${CHART}

    # nginx-ingress
    if [ "${NAME}" == "nginx-ingress" ]; then
        config_save
    fi

    # waiting 2
    waiting_pod "${NAMESPACE}" "${NAME}"

    _command "helm history ${NAME}"
    helm history ${NAME}

    _command "kubectl get deploy,pod,svc,ing,pvc,pv -n ${NAMESPACE}"
    kubectl get deploy,pod,svc,ing,pvc,pv -n ${NAMESPACE}

    # for nginx-ingress
    if [ "${NAME}" == "nginx-ingress" ]; then
        set_base_domain "${NAME}"
    fi

    # for efs-provisioner
    if [ "${NAME}" == "efs-provisioner" ]; then
        _command "kubectl get sc -n ${NAMESPACE}"
        kubectl get sc -n ${NAMESPACE}
    fi

    # chart ingress = true
    if [ "${INGRESS}" == "true" ]; then
        if [ -z ${BASE_DOMAIN} ]; then
            get_elb_domain ${NAME} ${NAMESPACE}

            _result "${NAME}: http://${ELB_DOMAIN}"
        else
            if [ -z ${ROOT_DOMAIN} ]; then
                _result "${NAME}: http://${DOMAIN}"
            else
                _result "${NAME}: https://${DOMAIN}"
            fi
        fi
    fi

    # for kubernetes-dashboard
    if [ "${NAME}" == "kubernetes-dashboard" ]; then
        create_cluster_role_binding view ${NAMESPACE} ${NAME}-view true
    fi
}

helm_delete() {
    NAME=

    LIST=${SHELL_DIR}/build/${THIS_NAME}-helm-list

    _command "helm ls --all"

    # find sample
    helm ls --all | grep -v "NAME" | sort \
        | awk '{printf "%-30s %-20s %-5s %-12s %s\n", $1, $11, $2, $8, $9}' > ${LIST}

    # select
    select_one

    if [ "${SELECTED}" == "" ]; then
        return
    fi

    NAME="$(echo ${SELECTED} | awk '{print $1}')"

    if [ "${NAME}" == "" ]; then
        return
    fi

    # for efs-provisioner
    if [ "${NAME}" == "efs-provisioner" ]; then
        efs_delete
    fi

    _command "helm delete --purge ${NAME}"
    helm delete --purge ${NAME}
}

helm_check() {
    _command "kubectl get pod -n kube-system | grep tiller-deploy"
    COUNT=$(kubectl get pod -n kube-system | grep tiller-deploy | wc -l | xargs)

    if [ "x${COUNT}" == "x0" ] || [ ! -d ~/.helm ]; then
        helm_init
    fi
}

helm_init() {
    NAMESPACE="kube-system"
    ACCOUNT="tiller"

    create_cluster_role_binding cluster-admin ${NAMESPACE} ${ACCOUNT}

    _command "helm init --upgrade --service-account=${ACCOUNT}"
    helm init --upgrade --service-account=${ACCOUNT}

    # waiting 5
    waiting_pod "${NAMESPACE}" "tiller"

    _command "kubectl get pod,svc -n ${NAMESPACE}"
    kubectl get pod,svc -n ${NAMESPACE}

    _command "helm repo update"
    helm repo update

    _command "helm ls"
    helm ls
}

create_namespace() {
    NAMESPACE=$1

    CHECK=

    _command "kubectl get ns ${NAMESPACE}"
    kubectl get ns ${NAMESPACE} > /dev/null 2>&1 || export CHECK=CREATE

    if [ "${CHECK}" == "CREATE" ]; then
        _result "${NAMESPACE}"

        _command "kubectl create ns ${NAMESPACE}"
        kubectl create ns ${NAMESPACE}
    fi
}

create_service_account() {
    NAMESPACE=$1
    ACCOUNT=$2

    create_namespace ${NAMESPACE}

    CHECK=

    _command "kubectl get sa ${ACCOUNT} -n ${NAMESPACE}"
    kubectl get sa ${ACCOUNT} -n ${NAMESPACE} > /dev/null 2>&1 || export CHECK=CREATE

    if [ "${CHECK}" == "CREATE" ]; then
        _result "${NAMESPACE}:${ACCOUNT}"

        _command "kubectl create sa ${ACCOUNT} -n ${NAMESPACE}"
        kubectl create sa ${ACCOUNT} -n ${NAMESPACE}
    fi
}

create_cluster_role_binding() {
    ROLL=$1
    NAMESPACE=$2
    ACCOUNT=${3:-default}
    TOKEN=${4:-false}

    create_service_account ${NAMESPACE} ${ACCOUNT}

    CHECK=

    _command "kubectl get clusterrolebinding ${ROLL}:${NAMESPACE}:${ACCOUNT}"
    kubectl get clusterrolebinding ${ROLL}:${NAMESPACE}:${ACCOUNT} > /dev/null 2>&1 || export CHECK=CREATE

    if [ "${CHECK}" == "CREATE" ]; then
        _result "${ROLL}:${NAMESPACE}:${ACCOUNT}"

        _command "kubectl create clusterrolebinding ${ROLL}:${NAMESPACE}:${ACCOUNT} --clusterrole=${ROLL} --serviceaccount=${NAMESPACE}:${ACCOUNT}"
        kubectl create clusterrolebinding ${ROLL}:${NAMESPACE}:${ACCOUNT} --clusterrole=${ROLL} --serviceaccount=${NAMESPACE}:${ACCOUNT}
    fi

    if [ "${TOKEN}" == "true" ]; then
        SECRET=$(kubectl get secret -n ${NAMESPACE} | grep ${ACCOUNT}-token | awk '{print $1}')
        kubectl describe secret ${SECRET} -n ${NAMESPACE} | grep 'token:'
    fi
}

elb_security() {
    LIST=${SHELL_DIR}/build/${THIS_NAME}-elb-list

    # elb list
    _command "kubectl get svc --all-namespaces | grep LoadBalancer"
    kubectl get svc --all-namespaces | grep LoadBalancer | awk '{printf "%-20s %-30s %s\n", $1, $2, $5}' > ${LIST}

    # select
    select_one

    if [ "${SELECTED}" == "" ]; then
        return
    fi

    ELB_NAME=$(echo "${SELECTED}" | awk '{print $3}' | cut -d'-' -f1 | xargs)

    if [ "${ELB_NAME}" == "" ]; then
        return
    fi

    # security groups
    _command "aws elb describe-load-balancers --load-balancer-name ${ELB_NAME}"
    aws elb describe-load-balancers --load-balancer-name ${ELB_NAME} \
        | jq -r '.LoadBalancerDescriptions[].SecurityGroups[]' > ${LIST}

    # select
    select_one

    if [ "${SELECTED}" == "" ]; then
        return
    fi

    # ingress rules
    _command "aws ec2 describe-security-groups --group-ids ${SELECTED}"
    aws ec2 describe-security-groups --group-ids ${SELECTED} \
        | jq -r '.SecurityGroups[].IpPermissions[] | "\(.IpProtocol) \(.FromPort) \(.IpRanges[].CidrIp)"' > ${LIST}

    # select
    select_one

    if [ "${SELECTED}" == "" ]; then
        return
    fi

    # aws ec2 describe-security-groups --group-ids ${SELECTED} | jq '.SecurityGroups[].IpPermissions'

    # aws ec2 authorize-security-group-ingress --group-id ${SELECTED} --protocol tcp --port 8080 --cidr 203.0.113.0/24

    # aws ec2 revoke-security-group-ingress --group-id ${SELECTED} --protocol tcp --port 8080 --cidr 203.0.113.0/24

}

check_exist_pv() {
    NAMESPACE=${1}
    PVC_NAME=${2}
    PVC_ACCESS_MODE=${3}
    PVC_SIZE=${4}
    PV_NAME=

    PV_NAMES=$(kubectl get pv | grep ${PVC_NAME} | awk '{print $1}')
    for PvName in ${PV_NAMES}; do
        if [ "$(kubectl get pv ${PvName} -o json | jq -r '.spec.claimRef.name')" == "${PVC_NAME}" ]; then
            PV_NAME=${PvName}
        fi
    done

    if [ -z ${PV_NAME} ]; then
        echo "No PersistentVolume."
        # Create a new pvc
        create_pvc ${NAMESPACE} ${PVC_NAME} ${PVC_ACCESS_MODE} ${PVC_SIZE}
    else
        PV_JSON=${SHELL_DIR}/build/${THIS_NAME}-pv-${PVC_NAME}.json

        _command "kubectl get pv -o json ${PV_NAME}"
        kubectl get pv -o json ${PV_NAME} > ${PV_JSON}

        PV_STATUS=$(cat ${PV_JSON} | jq -r '.status.phase')
        echo "PV is in '${PV_STATUS}' status."

        if [ "${PV_STATUS}" == "Available" ]; then
            # If PVC for PV is not present, create PVC
            PVC_TMP=$(kubectl get pvc -n ${NAMESPACE} ${PVC_NAME} | grep ${PVC_NAME} | awk '{print $1}')
            if [ "${PVC_NAME}" != "${PVC_TMP}" ]; then
                # create a static PVC
                create_pvc ${NAMESPACE} ${PVC_NAME} ${PVC_ACCESS_MODE} ${PVC_SIZE} ${PV_NAME}
            fi
        elif [ "${PV_STATUS}" == "Released" ]; then
            return 1
        fi
    fi
}

create_pvc() {
    NAMESPACE=${1}
    PVC_NAME=${2}
    PVC_ACCESS_MODE=${3}
    PVC_SIZE=${4}
    PV_NAME=${5}

    PVC=${SHELL_DIR}/build/${THIS_NAME}-pvc-${PVC_NAME}.yaml
    get_template templates/pvc.yaml ${PVC}

    _replace "s/PVC_NAME/${PVC_NAME}/g" ${PVC}
    _replace "s/PVC_ACCESS_MODE/${PVC_ACCESS_MODE}/g" ${PVC}
    _replace "s/PVC_SIZE/${PVC_SIZE}/g" ${PVC}

    # for efs-provisioner
    if [ ! -z ${EFS_ID} ]; then
        _replace "s/#:EFS://g" ${PVC}
    fi

    # for static pvc
    if [ ! -z ${PV_NAME} ]; then
        _replace "s/#:PV://g" ${PVC}
        _replace "s/PV_NAME/${PV_NAME}/g" ${PVC}
    fi

    echo ${PVC}

    _command "kubectl create -n ${NAMESPACE} -f ${PVC}"
    kubectl create -n ${NAMESPACE} -f ${PVC}

    waiting_for isBound ${NAMESPACE} ${PVC_NAME}

    _command "kubectl get pvc,pv -n ${NAMESPACE}"
    kubectl get pvc,pv -n ${NAMESPACE}
}

isBound() {
    NAMESPACE=${1}
    PVC_NAME=${2}

    PVC_STATUS=$(kubectl get pvc -n ${NAMESPACE} ${PVC_NAME} -o json | jq -r '.status.phase')
    if [ "${PVC_STATUS}" != "Bound" ]; then
        return 1;
    fi
}

isEFSAvailable() {
    FILE_SYSTEMS=$(aws efs describe-file-systems --creation-token ${CLUSTER_NAME} --region ${REGION})
    FILE_SYSTEM_LENGH=$(echo ${FILE_SYSTEMS} | jq -r '.FileSystems | length')
    if [ ${FILE_SYSTEM_LENGH} -gt 0 ]; then
        STATES=$(echo ${FILE_SYSTEMS} | jq -r '.FileSystems[].LifeCycleState')

        COUNT=0
        for state in ${STATES}; do
            if [ "${state}" == "available" ]; then
                COUNT=$(( ${COUNT} + 1 ))
            fi
        done

        # echo ${COUNT}/${FILE_SYSTEM_LENGH}

        if [ ${COUNT} -eq ${FILE_SYSTEM_LENGH} ]; then
            return 0;
        fi
    fi

    return 1;
}

isMountTargetAvailable() {
    MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id ${EFS_ID} --region ${REGION})
    MOUNT_TARGET_LENGH=$(echo ${MOUNT_TARGETS} | jq -r '.MountTargets | length')
    if [ ${MOUNT_TARGET_LENGH} -gt 0 ]; then
        STATES=$(echo ${MOUNT_TARGETS} | jq -r '.MountTargets[].LifeCycleState')

        COUNT=0
        for state in ${STATES}; do
            if [ "${state}" == "available" ]; then
                COUNT=$(( ${COUNT} + 1 ))
            fi
        done

        # echo ${COUNT}/${MOUNT_TARGET_LENGH}

        if [ ${COUNT} -eq ${MOUNT_TARGET_LENGH} ]; then
            return 0;
        fi
    fi

    return 1;
}

isMountTargetDeleted() {
    MOUNT_TARGET_LENGTH=$(aws efs describe-mount-targets --file-system-id ${EFS_ID} --region ${REGION} | jq -r '.MountTargets | length')
    if [ ${MOUNT_TARGET_LENGTH} == 0 ]; then
        return 0
    else
        return 1
    fi
}

efs_create() {
    # get the security group id
    K8S_NODE_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=nodes.${CLUSTER_NAME}" | jq -r '.SecurityGroups[0].GroupId')
    if [ -z ${K8S_NODE_SG_ID} ] || [ "${K8S_NODE_SG_ID}" == "null" ]; then
        _error "Not found the security group for the nodes."
    fi

    # get vpc id & subent ids
    VPC_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=nodes.${CLUSTER_NAME}" | jq -r '.SecurityGroups[0].VpcId')
    VPC_PRIVATE_SUBNETS_LENGTH=$(aws ec2 describe-subnets --filters "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" "Name=tag:SubnetType,Values=Private" | jq '.Subnets | length')
    if [ ${VPC_PRIVATE_SUBNETS_LENGTH} -eq 2 ]; then
        VPC_SUBNETS=$(aws ec2 describe-subnets --filters "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" "Name=tag:SubnetType,Values=Private" | jq -r '(.Subnets[].SubnetId)')
    else
        VPC_SUBNETS=$(aws ec2 describe-subnets --filters "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" | jq -r '(.Subnets[].SubnetId)')
    fi

    if [ -z ${VPC_ID} ]; then
        _error "Not found the VPC."
    fi

    _result "K8S_NODE_SG_ID=${K8S_NODE_SG_ID}"
    _result "VPC_ID=${VPC_ID}"
    _result "VPC_SUBNETS="
    echo "${VPC_SUBNETS}"
    echo

    # create a security group for efs mount targets
    EFS_SG_LENGTH=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=efs-sg.${CLUSTER_NAME}" | jq '.SecurityGroups | length')
    if [ ${EFS_SG_LENGTH} -eq 0 ]; then
        echo "Creating a security group for mount targets"

        EFS_SG_ID=$(aws ec2 create-security-group \
            --region ${REGION} \
            --group-name efs-sg.${CLUSTER_NAME} \
            --description "Security group for EFS mount targets" \
            --vpc-id ${VPC_ID} | jq -r '.GroupId')

        aws ec2 authorize-security-group-ingress \
            --group-id ${EFS_SG_ID} \
            --protocol tcp \
            --port 2049 \
            --source-group ${K8S_NODE_SG_ID} \
            --region ${REGION}
    else
        EFS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=efs-sg.${CLUSTER_NAME}" | jq -r '.SecurityGroups[].GroupId')
    fi

    # echo "Security group for mount targets:"
    _result "EFS_SG_ID=${EFS_SG_ID}"

    # create an efs
    EFS_LENGTH=$(aws efs describe-file-systems --creation-token ${CLUSTER_NAME} | jq '.FileSystems | length')
    if [ ${EFS_LENGTH} -eq 0 ]; then
        echo "Creating a elastic file system"

        EFS_ID=$(aws efs create-file-system --creation-token ${CLUSTER_NAME} --region ${REGION} | jq -r '.FileSystemId')
        aws efs create-tags \
            --file-system-id ${EFS_ID} \
            --tags Key=Name,Value=efs.${CLUSTER_NAME} \
            --region ap-northeast-2
    else
        EFS_ID=$(aws efs describe-file-systems --creation-token ${CLUSTER_NAME} --region ${REGION} | jq -r '.FileSystems[].FileSystemId')
    fi

    _result "EFS_ID=[${EFS_ID}]"

    # replace EFS_ID
    _replace "s/EFS_ID/${EFS_ID}/g" ${CHART}

    # save config (EFS_ID)
    config_save

    echo "Waiting for the state of the EFS to be available."
    waiting_for isEFSAvailable

    # create mount targets
    EFS_MOUNT_TARGET_LENGTH=$(aws efs describe-mount-targets --file-system-id ${EFS_ID} --region ${REGION} | jq -r '.MountTargets | length')
    if [ ${EFS_MOUNT_TARGET_LENGTH} -eq 0 ]; then
        echo "Creating mount targets"

        for SubnetId in ${VPC_SUBNETS}; do
            EFS_MOUNT_TARGET_ID=$(aws efs create-mount-target \
                --file-system-id ${EFS_ID} \
                --subnet-id ${SubnetId} \
                --security-group ${EFS_SG_ID} \
                --region ${REGION} | jq -r '.MountTargetId')
            EFS_MOUNT_TARGET_IDS=(${EFS_MOUNT_TARGET_IDS[@]} ${EFS_MOUNT_TARGET_ID})
        done
    else
        EFS_MOUNT_TARGET_IDS=$(aws efs describe-mount-targets --file-system-id ${EFS_ID} --region ${REGION} | jq -r '.MountTargets[].MountTargetId')
    fi

    _result "EFS_MOUNT_TARGET_IDS="
    echo "${EFS_MOUNT_TARGET_IDS[@]}"
    echo

    echo "Waiting for the state of the EFS mount targets to be available."
    waiting_for isMountTargetAvailable
}

efs_delete() {
    if [ -z ${EFS_ID} ]; then
        return
    fi

    # delete mount targets
    EFS_MOUNT_TARGET_IDS=$(aws efs describe-mount-targets --file-system-id ${EFS_ID} --region ${REGION} | jq -r '.MountTargets[].MountTargetId')
    for MountTargetId in ${EFS_MOUNT_TARGET_IDS}; do
        echo "Deleting the mount targets"
        aws efs delete-mount-target --mount-target-id ${MountTargetId}
    done

    echo "Waiting for the EFS mount targets to be deleted."
    waiting_for isMountTargetDeleted

    # delete security group for efs mount targets
    EFS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=efs-sg.${CLUSTER_NAME}" | jq -r '.SecurityGroups[0].GroupId')
    if [ -n ${EFS_SG_ID} ]; then
        echo "Deleting the security group for mount targets"
        aws ec2 delete-security-group --group-id ${EFS_SG_ID}
    fi

    # delete efs
    if [ -n ${EFS_ID} ]; then
        echo "Deleting the elastic file system"
        aws efs delete-file-system --file-system-id ${EFS_ID} --region ${REGION}
    fi

    # save config (EFS_ID)
    EFS_ID=
    config_save
}

istio_init() {
    helm_check

    NAME="istio"
    NAMESPACE="istio-system"

    ISTIO_TMP=${SHELL_DIR}/build/istio
    mkdir -p ${ISTIO_TMP}

    CHART=${SHELL_DIR}/charts/istio/istio.yaml
    VERSION=$(cat ${CHART} | grep chart-version | awk '{print $3}')

    if [ "${VERSION}" == "" ] || [ "${VERSION}" == "latest" ]; then
        VERSION=$(curl -s https://api.github.com/repos/istio/istio/releases/latest | jq -r '.tag_name')
    fi

    _result "${NAME} ${VERSION}"

    # istio download
    if [ ! -d ${ISTIO_TMP}/${NAME}-${VERSION} ]; then
        if [ "${OS_NAME}" == "darwin" ]; then
            OSEXT="osx"
        else
            OSEXT="linux"
        fi

        URL="https://github.com/istio/istio/releases/download/${VERSION}/istio-${VERSION}-${OSEXT}.tar.gz"

        pushd ${ISTIO_TMP}
        curl -sL "${URL}" | tar xz
        popd
    fi

    ISTIO_DIR=${ISTIO_TMP}/${NAME}-${VERSION}/install/kubernetes/helm/istio
}

istio_install() {
    istio_init

    create_namespace ${NAMESPACE}

    CHART=${SHELL_DIR}/build/${THIS_NAME}-istio-${NAME}.yaml
    get_template charts/istio/${NAME}.yaml ${CHART}

    # ingress
    if [ -z ${BASE_DOMAIN} ]; then
        _replace "s/SERVICE_TYPE/LoadBalancer/g" ${CHART}
        _replace "s/INGRESS_ENABLED/false/g" ${CHART}
    else
        _replace "s/SERVICE_TYPE/ClusterIP/g" ${CHART}
        _replace "s/INGRESS_ENABLED/true/g" ${CHART}
        _replace "s/BASE_DOMAIN/${BASE_DOMAIN}/g" ${CHART}
    fi

    # admin password
    read_password ${CHART}

    # helm install
    _command "helm upgrade --install ${NAME} ${ISTIO_DIR} --namespace ${NAMESPACE} --values ${CHART}"
    helm upgrade --install ${NAME} ${ISTIO_DIR} --namespace ${NAMESPACE} --values ${CHART}

    # for kiali
    create_cluster_role_binding view ${NAMESPACE} kiali-service-account

    # save config (ISTIO)
    ISTIO=true
    config_save

    # waiting 2
    waiting_pod "${NAMESPACE}" "${NAME}"

    _command "helm history ${NAME}"
    helm history ${NAME}

    _command "kubectl get deploy,pod,svc -n ${NAMESPACE}"
    kubectl get deploy,pod,svc -n ${NAMESPACE}

    # set_base_domain "istio-ingressgateway"

    _command "kubectl get ing -n ${NAMESPACE}"
    kubectl get ing -n ${NAMESPACE}
}

istio_injection() {
    CMD=$1

    if [ -z ${CMD} ]; then
        _command "kubectl get ns --show-labels"
        kubectl get ns --show-labels
        return
    fi

    LIST=${SHELL_DIR}/build/${THIS_NAME}-istio-ns-list

    # find sample
    kubectl get ns | grep -v "NAME" | awk '{print $1}' > ${LIST}

    # select
    select_one

    if [ -z ${SELECTED} ]; then
        istio_menu
        return
    fi

    # istio-injection
    if [ "${CMD}" == "enable" ]; then
        kubectl label namespace ${SELECTED} istio-injection=enabled
    else
        kubectl label namespace ${SELECTED} istio-injection-
    fi

    press_enter istio
}

istio_delete() {
    istio_init

    # helm delete
    _command "helm delete --purge ${NAME}"
    helm delete --purge ${NAME}

    # _command "kubectl delete -f ${ISTIO_DIR}/templates/crds.yaml"
    # kubectl delete -f ${ISTIO_DIR}/templates/crds.yaml

    LIST="$(kubectl get crds | grep istio.io | awk '{print $1}')"
    if [ "${LIST}" != "" ]; then
        _command "kubectl delete crds *.istio.io"
        kubectl delete crds ${LIST}
    fi

    _command "kubectl delete namespace ${NAMESPACE}"
    kubectl delete namespace ${NAMESPACE}

    # save config (ISTIO)
    ISTIO=
    config_save
}

sample_install() {
    helm_check

    NAME=${1}
    NAMESPACE=${2}

    CHART=${SHELL_DIR}/build/${THIS_NAME}-${NAME}.yaml
    get_template charts/sample/${NAME}.yaml ${CHART}

    # profile
    _replace "s/profile:.*/profile: ${NAMESPACE}/g" ${CHART}

    # ingress
    INGRESS=$(cat ${CHART} | grep chart-ingress | awk '{print $3}')

    if [ "${INGRESS}" == "true" ]; then
        if [ -z ${BASE_DOMAIN} ]; then
            get_ingress_nip_io

            _replace "s/SERVICE_TYPE/LoadBalancer/g" ${CHART}
            _replace "s/INGRESS_ENABLED/false/g" ${CHART}
        else
            _replace "s/SERVICE_TYPE/ClusterIP/g" ${CHART}
            _replace "s/INGRESS_ENABLED/true/g" ${CHART}
            _replace "s/BASE_DOMAIN/${BASE_DOMAIN}/g" ${CHART}
        fi
    fi

    # has configmap
    COUNT=$(kubectl get configmap -n ${NAMESPACE} 2>&1 | grep ${NAME}-${NAMESPACE} | wc -l | xargs)
    if [ "x${COUNT}" != "x0" ]; then
        _replace "s/CONFIGMAP_ENABLED/true/g" ${CHART}
    else
        _replace "s/CONFIGMAP_ENABLED/false/g" ${CHART}
    fi

    # has secret
    COUNT=$(kubectl get secret -n ${NAMESPACE} 2>&1 | grep ${NAME}-${NAMESPACE} | wc -l | xargs)
    if [ "x${COUNT}" != "x0" ]; then
        _replace "s/SECRET_ENABLED/true/g" ${CHART}
    else
        _replace "s/SECRET_ENABLED/false/g" ${CHART}
    fi

    # for istio
    if [ "${ISTIO}" == "true" ]; then
        COUNT=$(kubectl get ns ${NAMESPACE} --show-labels | grep 'istio-injection=enabled' | wc -l | xargs)
        if [ "x${COUNT}" != "x0" ]; then
            ISTIO_ENABLED=true
        else
            ISTIO_ENABLED=false
        fi
    else
        ISTIO_ENABLED=false
    fi
    _replace "s/ISTIO_ENABLED/${ISTIO_ENABLED}/g" ${CHART}

    SAMPLE_DIR=${SHELL_DIR}/charts/sample/${NAME}

    # helm install
    _command "helm upgrade --install ${NAME}-${NAMESPACE} ${SAMPLE_DIR} --namespace ${NAMESPACE} --values ${CHART}"
    helm upgrade --install ${NAME}-${NAMESPACE} ${SAMPLE_DIR} --namespace ${NAMESPACE} --values ${CHART}

    # waiting 2
    waiting_pod "${NAMESPACE}" "${NAME}-${NAMESPACE}"

    _command "helm history ${NAME}-${NAMESPACE}"
    helm history ${NAME}-${NAMESPACE}

    _command "kubectl get deploy,pod,svc,ing -n ${NAMESPACE}"
    kubectl get deploy,pod,svc,ing -n ${NAMESPACE}

    if [ "${INGRESS}" == "true" ]; then
        if [ -z ${BASE_DOMAIN} ]; then
            get_elb_domain ${NAME}-${NAMESPACE} ${NAMESPACE}

            _result "${NAME}: http://${ELB_DOMAIN}"
        else
            DOMAIN="${NAME}-${NAMESPACE}.${BASE_DOMAIN}"

            if [ -z ${ROOT_DOMAIN} ]; then
                _result "${NAME}: http://${DOMAIN}"
            else
                _result "${NAME}: https://${DOMAIN}"
            fi
        fi
    fi
}

get_cluster() {
    # config list
    LIST=${SHELL_DIR}/build/${THIS_NAME}-config-list
    kubectl config view -o json | jq -r '.clusters[].name' | sort > ${LIST}

    # select
    select_one

    CLUSTER_NAME="${SELECTED}"

    if [ "${CLUSTER_NAME}" == "" ]; then
        _error
    fi

    _command "kubectl config use-context ${CLUSTER_NAME}"
    kubectl config use-context ${CLUSTER_NAME}
}

get_elb_domain() {
    ELB_DOMAIN=

    if [ -z $2 ]; then
        _command "kubectl get svc --all-namespaces -o wide | grep LoadBalancer | grep $1 | head -1 | awk '{print \$5}'"
    else
        _command "kubectl get svc -n $2 -o wide | grep LoadBalancer | grep $1 | head -1 | awk '{print \$4}'"
    fi

    progress start

    IDX=0
    while true; do
        # ELB Domain 을 획득
        if [ -z $2 ]; then
            ELB_DOMAIN=$(kubectl get svc --all-namespaces -o wide | grep LoadBalancer | grep $1 | head -1 | awk '{print $5}')
        else
            ELB_DOMAIN=$(kubectl get svc -n $2 -o wide | grep LoadBalancer | grep $1 | head -1 | awk '{print $4}')
        fi

        if [ ! -z ${ELB_DOMAIN} ] && [ "${ELB_DOMAIN}" != "<pending>" ]; then
            break
        fi

        IDX=$(( ${IDX} + 1 ))

        if [ "${IDX}" == "200" ]; then
            ELB_DOMAIN=
            break
        fi

        progress
    done

    progress end

    _result ${ELB_DOMAIN}
}

get_ingress_elb_name() {
    POD="${1:-nginx-ingress}"

    ELB_NAME=

    get_elb_domain "${POD}"

    if [ -z ${ELB_DOMAIN} ]; then
        return
    fi

    _command "echo ${ELB_DOMAIN} | cut -d'-' -f1"
    ELB_NAME=$(echo ${ELB_DOMAIN} | cut -d'-' -f1)

    _result ${ELB_NAME}
}

get_ingress_nip_io() {
    POD="${1:-nginx-ingress}"

    ELB_IP=

    get_elb_domain "${POD}"

    if [ -z ${ELB_DOMAIN} ]; then
        return
    fi

    _command "dig +short ${ELB_DOMAIN} | head -n 1"

    progress start

    IDX=0
    while true; do
        ELB_IP=$(dig +short ${ELB_DOMAIN} | head -n 1)

        if [ ! -z ${ELB_IP} ]; then
            BASE_DOMAIN="${ELB_IP}.nip.io"
            break
        fi

        IDX=$(( ${IDX} + 1 ))

        if [ "${IDX}" == "100" ]; then
            BASE_DOMAIN=
            break
        fi

        progress
    done

    progress end

    _result ${BASE_DOMAIN}
}

read_root_domain() {
    # domain list
    LIST=${SHELL_DIR}/build/${THIS_NAME}-hosted-zones

    _command "aws route53 list-hosted-zones | jq -r '.HostedZones[] | .Name' | sed 's/.$//'"
    aws route53 list-hosted-zones | jq -r '.HostedZones[] | .Name' | sed 's/.$//' > ${LIST}

    # select
    select_one

    ROOT_DOMAIN=${SELECTED}
}

get_ssl_cert_arn() {
    if [ -z ${BASE_DOMAIN} ]; then
        return
    fi

    # get certificate arn
    _command "aws acm list-certificates | DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}" jq -r '.CertificateSummaryList[] | select(.DomainName==env.DOMAIN) | .CertificateArn'"
    SSL_CERT_ARN=$(aws acm list-certificates | DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}" jq -r '.CertificateSummaryList[] | select(.DomainName==env.DOMAIN) | .CertificateArn')
}

req_ssl_cert_arn() {
    if [ -z ${ROOT_DOMAIN} ] || [ -z ${BASE_DOMAIN} ]; then
        return
    fi

    # request certificate
    _command "aws acm request-certificate --domain-name "${SUB_DOMAIN}.${BASE_DOMAIN}" --validation-method DNS | jq -r '.CertificateArn'"
    SSL_CERT_ARN=$(aws acm request-certificate --domain-name "${SUB_DOMAIN}.${BASE_DOMAIN}" --validation-method DNS | jq -r '.CertificateArn')

    _result "Request Certificate..."

    waiting 2

    # Route53 에서 해당 도메인의 Hosted Zone ID 를 획득
    _command "aws route53 list-hosted-zones | ROOT_DOMAIN="${ROOT_DOMAIN}." jq -r '.HostedZones[] | select(.Name==env.ROOT_DOMAIN) | .Id' | cut -d'/' -f3"
    ZONE_ID=$(aws route53 list-hosted-zones | ROOT_DOMAIN="${ROOT_DOMAIN}." jq -r '.HostedZones[] | select(.Name==env.ROOT_DOMAIN) | .Id' | cut -d'/' -f3)

    if [ -z ${ZONE_ID} ]; then
        return
    fi

    # domain validate name
    _command "aws acm describe-certificate --certificate-arn ${SSL_CERT_ARN} | jq -r '.Certificate.DomainValidationOptions[].ResourceRecord | .Name'"
    CERT_DNS_NAME=$(aws acm describe-certificate --certificate-arn ${SSL_CERT_ARN} | jq -r '.Certificate.DomainValidationOptions[].ResourceRecord | .Name')

    if [ -z ${CERT_DNS_NAME} ]; then
        return
    fi

    # domain validate value
    _command "aws acm describe-certificate --certificate-arn ${SSL_CERT_ARN} | jq -r '.Certificate.DomainValidationOptions[].ResourceRecord | .Value'"
    CERT_DNS_VALUE=$(aws acm describe-certificate --certificate-arn ${SSL_CERT_ARN} | jq -r '.Certificate.DomainValidationOptions[].ResourceRecord | .Value')

    if [ -z ${CERT_DNS_VALUE} ]; then
        return
    fi

    # record sets
    RECORD=${SHELL_DIR}/build/${THIS_NAME}-record-sets-cname.json
    get_template templates/record-sets-cname.json ${RECORD}

    # replace
    _replace "s/DOMAIN/${CERT_DNS_NAME}/g" ${RECORD}
    _replace "s/DNS_NAME/${CERT_DNS_VALUE}/g" ${RECORD}

    cat ${RECORD}

    # update route53 record
    _command "aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} --change-batch file://${RECORD}"
    aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} --change-batch file://${RECORD}
}

set_record_alias() {
    if [ -z ${ROOT_DOMAIN} ] || [ -z ${BASE_DOMAIN} ] || [ -z ${ELB_NAME} ]; then
        return
    fi

    # Route53 에서 해당 도메인의 Hosted Zone ID 를 획득
    _command "aws route53 list-hosted-zones | ROOT_DOMAIN="${ROOT_DOMAIN}." jq -r '.HostedZones[] | select(.Name==env.ROOT_DOMAIN) | .Id' | cut -d'/' -f3"
    ZONE_ID=$(aws route53 list-hosted-zones | ROOT_DOMAIN="${ROOT_DOMAIN}." jq -r '.HostedZones[] | select(.Name==env.ROOT_DOMAIN) | .Id' | cut -d'/' -f3)

    if [ -z ${ZONE_ID} ]; then
        return
    fi

    # ELB 에서 Hosted Zone ID 를 획득
    _command "aws elb describe-load-balancers --load-balancer-name ${ELB_NAME} | jq -r '.LoadBalancerDescriptions[] | .CanonicalHostedZoneNameID'"
    ELB_ZONE_ID=$(aws elb describe-load-balancers --load-balancer-name ${ELB_NAME} | jq -r '.LoadBalancerDescriptions[] | .CanonicalHostedZoneNameID')

    if [ -z ${ELB_ZONE_ID} ]; then
        return
    fi

    # ELB 에서 DNS Name 을 획득
    _command "aws elb describe-load-balancers --load-balancer-name ${ELB_NAME} | jq -r '.LoadBalancerDescriptions[] | .DNSName'"
    ELB_DNS_NAME=$(aws elb describe-load-balancers --load-balancer-name ${ELB_NAME} | jq -r '.LoadBalancerDescriptions[] | .DNSName')

    if [ -z ${ELB_DNS_NAME} ]; then
        return
    fi

    # record sets
    RECORD=${SHELL_DIR}/build/${THIS_NAME}-record-sets-alias.json
    get_template templates/record-sets-alias.json ${RECORD}

    # replace
    _replace "s/DOMAIN/${SUB_DOMAIN}.${BASE_DOMAIN}/g" ${RECORD}
    _replace "s/ZONE_ID/${ELB_ZONE_ID}/g" ${RECORD}
    _replace "s/DNS_NAME/${ELB_DNS_NAME}/g" ${RECORD}

    cat ${RECORD}

    # update route53 record
    _command "aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} --change-batch file://${RECORD}"
    aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} --change-batch file://${RECORD}
}

set_record_delete() {
    if [ -z ${ROOT_DOMAIN} ] || [ -z ${BASE_DOMAIN} ]; then
        return
    fi

    # Route53 에서 해당 도메인의 Hosted Zone ID 를 획득
    _command "aws route53 list-hosted-zones | ROOT_DOMAIN="${ROOT_DOMAIN}." jq -r '.HostedZones[] | select(.Name==env.ROOT_DOMAIN) | .Id' | cut -d'/' -f3"
    ZONE_ID=$(aws route53 list-hosted-zones | ROOT_DOMAIN="${ROOT_DOMAIN}." jq -r '.HostedZones[] | select(.Name==env.ROOT_DOMAIN) | .Id' | cut -d'/' -f3)

    if [ -z ${ZONE_ID} ]; then
        return
    fi

    # record sets
    RECORD=${SHELL_DIR}/build/${THIS_NAME}-record-sets-delete.json
    get_template templates/record-sets-delete.json ${RECORD}

    # replace
    _replace "s/DOMAIN/${SUB_DOMAIN}.${BASE_DOMAIN}/g" ${RECORD}

    cat ${RECORD}

    # update route53 record
    _command "aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} --change-batch file://${RECORD}"
    aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} --change-batch file://${RECORD}
}

set_base_domain() {
    POD="${1:-nginx-ingress}"

    SUB_DOMAIN=${2:-"*"}

    _result "Pending ELB..."

    if [ -z ${BASE_DOMAIN} ]; then
        get_ingress_nip_io ${POD}
    else
        get_ingress_elb_name ${POD}

        set_record_alias
    fi
}

get_base_domain() {
    SUB_DOMAIN=${1:-"*"}

    ROOT_DOMAIN=
    BASE_DOMAIN=

    read_root_domain

    # base domain
    if [ ! -z ${ROOT_DOMAIN} ]; then
        WORD=$(echo ${CLUSTER_NAME} | cut -d'.' -f1)

        DEFAULT="${WORD}.${ROOT_DOMAIN}"
        question "Enter your ingress domain [${DEFAULT}] : "

        BASE_DOMAIN=${ANSWER:-${DEFAULT}}
    fi

    # certificate
    if [ ! -z ${BASE_DOMAIN} ]; then
        get_ssl_cert_arn

        if [ -z ${SSL_CERT_ARN} ]; then
            req_ssl_cert_arn
        fi
        if [ -z ${SSL_CERT_ARN} ]; then
            _error "Certificate ARN does not exists. [${ROOT_DOMAIN}][${SUB_DOMAIN}.${BASE_DOMAIN}][${REGION}]"
        fi

        _result "CertificateArn: ${SSL_CERT_ARN}"

        _replace "s@aws-load-balancer-ssl-cert:.*@aws-load-balancer-ssl-cert: ${SSL_CERT_ARN}@" ${CHART}
    fi
}

read_password() {
    CHART=${1}

    # admin password
    DEFAULT="password"
    password "Enter admin password [${DEFAULT}] : "
    echo

    _replace "s/PASSWORD/${PASSWORD:-${DEFAULT}}/g" ${CHART}
}

waiting_for() {
    echo
    progress start

    IDX=0
    while true; do
        if $@ ${IDX}; then
            break
        fi
        IDX=$(( ${IDX} + 1 ))
        progress ${IDX}
    done

    progress end
    echo
}

waiting_deploy() {
    _NS=${1}
    _NM=${2}
    SEC=${3:-10}

    _command "kubectl get deploy -n ${_NS} | grep ${_NM}"
    kubectl get deploy -n ${_NS} | head -1

    DEPLOY=${SHELL_DIR}/build/${THIS_NAME}-waiting-pod

    IDX=0
    while true; do
        kubectl get deploy -n ${_NS} | grep ${_NM} | head -1 > ${DEPLOY}
        cat ${DEPLOY}

        CURRENT=$(cat ${DEPLOY} | awk '{print $5}' | cut -d'/' -f1)

        if [ "x${CURRENT}" != "x0" ]; then
            break
        elif [ "x${IDX}" == "x${SEC}" ]; then
            _result "Timeout"
            break
        fi

        IDX=$(( ${IDX} + 1 ))
        sleep 2
    done
}

waiting_pod() {
    _NS=${1}
    _NM=${2}
    SEC=${3:-10}

    _command "kubectl get pod -n ${_NS} | grep ${_NM}"
    kubectl get pod -n ${_NS} | head -1

    POD=${SHELL_DIR}/build/${THIS_NAME}-waiting-pod

    IDX=0
    while true; do
        kubectl get pod -n ${_NS} | grep ${_NM} | head -1 > ${POD}
        cat ${POD}

        READY=$(cat ${POD} | awk '{print $2}' | cut -d'/' -f1)
        STATUS=$(cat ${POD} | awk '{print $3}')

        if [ "${STATUS}" == "Running" ] && [ "x${READY}" != "x0" ]; then
            break
        elif [ "${STATUS}" == "Error" ]; then
            _result "${STATUS}"
            break
        elif [ "${STATUS}" == "CrashLoopBackOff" ]; then
            _result "${STATUS}"
            break
        elif [ "x${IDX}" == "x${SEC}" ]; then
            _result "Timeout"
            break
        fi

        IDX=$(( ${IDX} + 1 ))
        sleep 2
    done
}

run
