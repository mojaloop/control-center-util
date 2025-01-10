#!/bin/bash


netbird_connect() {
  local cc_domain="$1"

  echo "Connecting to netbird.$cc_domain ============================="
  netbird down
  sleep 5
  netbird up --management-url "https://netbird.$cc_domain"
  sleep 15
  netbird status
  netbird routes list
}

get_gitlab_token() {
    local namespace="$1"
    local secret_name="$2"
    local field_name="$3"
    local kube_config="$4"
    kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.$field_name}"  --kubeconfig=$kube_config | base64 --decode
}

get_gitlab_project_id() {
    local gitlab_token="$1"
    local cc_domain="$2"
    local name="$3"
    curl -s -XGET -H "Content-Type: application/json" --header "Authorization: Bearer $gitlab_token" https://gitlab.$cc_domain/api/v4/projects/ | jq -r --arg name "$name" '.[] | select(.path==$name) | .id'
}

update_gitlab_project_variable() {
    local gitlab_token="$1"
    local cc_domain="$2"
    local project_id="$3"
    local key="$4"
    local value="$5"
    curl -XPUT --header "Authorization: Bearer $gitlab_token"  "https://gitlab.$cc_domain/api/v4/projects/$project_id/variables/$key" --form "value=$value"
}

create_gitlab_project_variable() {
    local gitlab_token="$1"
    local cc_domain="$2"
    local project_id="$3"
    local key="$4"
    local value="$5"
    curl -XPOST --header "Authorization: Bearer $gitlab_token"  "https://gitlab.$cc_domain/api/v4/projects/$project_id/variables/" --form "key=$key" --form "value=$value"
}

clone_gitlabrepo() {
    local gitlab_token="$1"
    local cc_domain="$2"
    local group="$3"
    local project="$4"
    local path="$5"
    rm -rf $path
    mkdir -p $path
    git clone https://token:$gitlab_token@gitlab.$cc_domain/$group/$project.git $path
}


# Define the search pattern
env_name="$1"
source_kubeconfig="$2"
dest_kubeconfig="$3"
source_cc_domain="$4"
dest_cc_domain="$5"
gitlab_group="iac"
working_dir="$6"

# Define the output file
output_file="$1_secrets.yaml"

# Initialize the output file
echo "" > $output_file

# Connect to source netbird vpn
netbird_connect $source_cc_domain

# Get the gitlab token from the source cluster
source_gitlab_token=$(get_gitlab_token "gitlab" "root-token-secret" "token" $source_kubeconfig)
echo "Exported source gitlab token"

# Get all secret names in the current namespace
secret_names=$(kubectl get secrets -n kube-system --kubeconfig=$source_kubeconfig | grep -E "^tfstate.*${env_name}" | grep -vE 'k8s-store-config|gitops-build' | awk '{print $1}' )

# Loop through each secret name
for secret_name in $secret_names; do
    echo "Exporting secret: $secret_name"
    # Get the secret YAML, remove unwanted metadata, and append to the output file
    kubectl get secret "$secret_name" -o yaml -n kube-system --kubeconfig=$source_kubeconfig| \
    yq eval 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations, .metadata.managedFields)' - >> "$output_file"
    # Add a separator
    echo "---" >> "$output_file"
done

echo "Secrets containing '$env_name' have been exported to $output_file========================"

# Connect to source netbird vpn
netbird_connect $dest_cc_domain
# Create the secrets in the destination cluster
kubectl apply -f "$output_file" --kubeconfig=$dest_kubeconfig
echo "Secrets have been imported to the destination cluster====================================="

#Get the gitlab token from the destination cluster
dest_gitlab_token=$(get_gitlab_token "gitlab" "root-token-secret" "token" $dest_kubeconfig)


#Clone the source gitlab repo
clone_gitlabrepo $source_gitlab_token $source_cc_domain $gitlab_group $env_name $working_dir/source_path/$env_name
#Clone the destination gitlab repo
clone_gitlabrepo $dest_gitlab_token $dest_cc_domain $gitlab_group $env_name $working_dir/dest_path/$env_name

#create gitlab project CICD variables
echo "creation of gitlab project CICD variables================================================="
source_gitlab_project_id=$(get_gitlab_project_id $source_gitlab_token $source_cc_domain $env_name)
dest_gitlab_project_id=$(get_gitlab_project_id $dest_gitlab_token $dest_cc_domain $env_name)


update_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIGRATE" "true"
create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_SOURCE_GITLAB" "https://gitlab.$source_cc_domain"
create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_SOURCE_PROJECT_ID" $source_gitlab_project_id
create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_SOURCE_JOB_ID" ''


#migrate the repo contents from source to destination
echo "migrate the repo contents from source to destination======================================="
cp -r $working_dir/source_path/$env_name/* $working_dir/dest_path/$env_name/
cp -r $working_dir/source_path/$env_name/.gitlab $working_dir/dest_path/$env_name/
cp -r $working_dir/source_path/$env_name/.gitlab-ci.yml $working_dir/dest_path/$env_name/

git -C $working_dir/dest_path/$env_name/ add .
git -C $working_dir/dest_path/$env_name/ commit -m "Automated commit - the migrated repo contents"
git -C $working_dir/dest_path/$env_name/ push 
