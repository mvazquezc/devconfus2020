#!/bin/bash
rm -rf /var/tmp/devconfus20/reverse-words/
rm -rf /var/tmp/devconfus20/reverse-words-cicd/
oc delete ns argocd
oc delete ns reversewords-ci
oc delete ns reverse-words-stage
oc delete ns reverse-words-production
oc -n openshift-operators delete subscription openshift-pipelines-operator-rh
oc -n openshift-operators get csv -o name | grep openshift-pipelines-operator | xargs oc -n openshift-operators delete
