# Deploy OpenShift and the required Operators

1. Deploy an OpenShift or OKD Cluster. For this demo we used OpenShift Container Platform v4.4.11
2. Deploy Argo CD

    ~~~sh
    oc create namespace argocd
    oc apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v1.6.1/manifests/install.yaml
    ~~~
3. Get the Argo CD admin user password

    ~~~sh
    ARGOCD_PASSWORD=$(oc -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | awk -F "/" '{print $2}')
    echo $ARGOCD_PASSWORD > /tmp/argocd-password
    ~~~
4. Create a passthrough route for Argo CD

    ~~~sh
    oc -n argocd create route passthrough argocd --service=argocd-server --port=https --insecure-policy=Redirect
    ~~~
5. Patch Health Status for Ingress objects on OpenShift

    ~~~sh
    oc -n argocd patch configmap argocd-cm -p '{"data":{"resource.customizations":"extensions/Ingress:\n  health.lua: |\n    hs = {}\n    hs.status = \"Healthy\"\n    return hs\n"}}'
    ~~~
6.  Deploy OpenShift Pipelines Operator

    ~~~sh
    cat <<EOF | oc -n openshift-operators create -f -
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: openshift-pipelines-operator-rh
    spec:
      channel: ocp-4.4
      installPlanApproval: Automatic
      name: openshift-pipelines-operator-rh
      source: redhat-operators
      sourceNamespace: openshift-marketplace
    EOF
    ~~~

# Create the required Tekton manifests

1. Clone the Git repositories (you will need the ssh keys already in place)

    > **NOTE**: You need to fork these repositories and use your fork (so you have full-access)

    ~~~sh
    git clone git@github.com:mvazquezc/reverse-words.git ~/reverse-words
    git clone git@github.com:mvazquezc/reverse-words-cicd.git ~/reverse-words-cicd
    ~~~
2. Go to the reverse-words-cicd repo and checkout the CI branch which contains our Tekton manifests

    ~~~sh
    cd ~/reverse-words-cicd
    git checkout ci
    ~~~
3. Create a namespace for storing the configuration for our reversewords app pipeline

    ~~~sh
    oc create namespace reversewords-ci
    ~~~
4. Add the quay credentials to the credentials file

    ~~~sh
    QUAY_USER=<your_user>
    read -s QUAY_PASSWORD
    sed -i "s/<username>/$QUAY_USER/" quay-credentials.yaml
    sed -i "s/<password>/$QUAY_PASSWORD/" quay-credentials.yaml
    ~~~
5. Create a Secret containing the credentials to access our Git repository

    > **NOTE**: You need to provide a token with push access to the cicd repository
    
    ~~~sh
    read -s GIT_AUTH_TOKEN
    oc -n reversewords-ci create secret generic image-updater-secret --from-literal=token=${GIT_AUTH_TOKEN}
    ~~~
6. Import credentials into the cluster

    ~~~sh
    oc -n reversewords-ci create -f quay-credentials.yaml
    ~~~
7. Create a ServiceAccount with access to the credentials created in the previous step

    ~~~sh
    oc -n reversewords-ci create -f pipeline-sa.yaml
    ~~~
8. Create the Linter Task which will lint our code

    ~~~sh
    oc -n reversewords-ci create -f lint-task.yaml
    ~~~
9. Create the Tester Task which will run the tests in our app

    ~~~sh
    oc -n reversewords-ci create -f test-task.yaml
    ~~~
10. Create the Builder Task which will build a container image for our app

    ~~~sh
    oc -n reversewords-ci create -f build-task.yaml
    ~~~
11. Create the Image Update Task which will update the Deployment on a given branch after a successful image build

    ~~~sh
    oc -n reversewords-ci create -f image-updater-task.yaml
    ~~~
12. Edit some parameters from our Build Pipeline definition
    
    > **NOTE**: You need to use your forks address in the substitutions below

    ~~~sh
    sed -i "s|<reversewords_git_repo>|https://github.com/mvazquezc/reverse-words|" build-pipeline.yaml
    sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" build-pipeline.yaml
    sed -i "s|<golang_package>|github.com/mvazquezc/reverse-words|" build-pipeline.yaml
    sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" build-pipeline.yaml
    ~~~
13. Create the Build Pipeline definition which will be used to execute the previous tasks in an specific order with specific parameters

    ~~~sh
    oc -n reversewords-ci create -f build-pipeline.yaml
    ~~~
14. Create the curl task which will be used to query our apps on the promoter pipeline

    ~~~sh
    oc -n reversewords-ci create -f curl-task.yaml
    ~~~
15. Create the task that gets the stage release from the git cicd repository

    ~~~sh
    oc -n reversewords-ci create -f get-stage-release-task.yaml
    ~~~
16. Edit some parameters from our Promoter Pipeline definition

    > **NOTE**: You need to use your forks address/quay account in the substitutions below

    ~~~sh
    sed -i "s|<reversewords_cicd_git_repo>|https://github.com/mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
    sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" promote-to-prod-pipeline.yaml
    sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
    sed -i "s|<stage_deployment_file_path>|./deployment.yaml|" promote-to-prod-pipeline.yaml
    ~~~
17. Create the Promoter Pipeline definition which will be used to execute the previous tasks in an specific order with specific parameters

    ~~~sh
    oc -n reversewords-ci create -f promote-to-prod-pipeline.yaml
    ~~~
18. Create the required Roles and RoleBindings for working with Webhooks

    ~~~sh
    oc -n reversewords-ci create -f webhook-roles.yaml
    ~~~
19. Create the TriggerBinding for reading data received by a webhook and pass it to the Pipeline

    ~~~sh
    oc -n reversewords-ci create -f github-triggerbinding.yaml
    ~~~
20. Create the TriggerTemplate and Event Listener to run the Pipeline when new commits hit the main branch of our app repository

    ~~~sh
    WEBHOOK_SECRET="v3r1s3cur3"
    oc -n reversewords-ci create secret generic webhook-secret --from-literal=secret=${WEBHOOK_SECRET}
    sed -i "s/<git-triggerbinding>/github-triggerbinding/" webhook.yaml
    sed -i "/ref: github-triggerbinding/d" webhook.yaml
    sed -i "s/- name: pipeline-binding/- name: github-triggerbinding/" webhook.yaml
    oc -n reversewords-ci create -f webhook.yaml
    ~~~
21. We need to provide an ingress point for our EventListener, we want it to be TLS, we will create a edge route

    ~~~sh
    oc -n reversewords-ci create route edge reversewords-webhook --service=el-reversewords-webhook --port=8080 --insecure-policy=Redirect
    ~~~

# Configure Argo CD

1. Install the Argo CD Cli to make things easier

    ~~~sh
    # Get the Argo CD Cli and place it in /usr/bin/
    sudo curl -L https://github.com/argoproj/argo-cd/releases/download/v1.6.1/argocd-linux-amd64 -o /usr/bin/argocd
    sudo chmod +x /usr/bin/argocd
    ~~~
2. Login into Argo CD from the Cli
  
    ~~~sh
    ARGOCD_ROUTE=$(oc -n argocd get route argocd -o jsonpath='{.spec.host}')
    argocd login $ARGOCD_ROUTE --insecure --username admin --password $(cat /tmp/argocd-password)
    ~~~
3. Update Argo CD password

    ~~~sh
    argocd account update-password --account admin --current-password $(cat /tmp/argocd-password) --new-password 'r3dh4t1!'
    ~~~
