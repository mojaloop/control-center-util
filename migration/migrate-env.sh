#!/bin/bash


check_dns() {
    local dns_name=$1

    # Perform nslookup and check the exit code
    if ! nslookup "$dns_name" > /dev/null 2>&1; then
        echo "Error: DNS name '$dns_name' could not be resolved."
        exit 1
    fi

    echo "DNS name '$dns_name' resolved successfully."
}


check_path() {
    local path=$1

    if [[ -e "$path" ]]; then
        echo "Path '$path' exists."
        return 0
    else
        echo "Path '$path' does not exist."
        exit 1
    fi
}

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

get_k8s_secret_value() {
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

    if [[ $? -eq 0 ]]; then
        echo "Repository cloned successfully."
        return 0
    else
        echo "Error: Failed to clone repository."
        exit 1
    fi    
}

download_env_bucket_data() {
    echo "Copying object storage bucket contents==================================================="
    rm -rf $working_dir/source_path/buckets
    rm -rf $working_dir/dest_path/buckets
    mkdir -p $working_dir/source_path/buckets
    mkdir -p $working_dir/dest_path/buckets
    bucket_names=$(kubectl get obc --no-headers -o custom-columns=":metadata.name"  -n gitlab --kubeconfig=$source_kubeconfig | grep $env_name)

    if [[ -z "$bucket_names" ]]; then
        echo "No object storage buckets found matching '$env_name'."
        exit 1
    fi

    for bucket_name in $bucket_names; do
        echo "Copying bucket: $bucket_name"
        # Get the bucket auth credentials
        aws_access_key_id=$(get_k8s_secret_value "gitlab" "$bucket_name" "AWS_ACCESS_KEY_ID" $source_kubeconfig)
        aws_secret_access_key=$(get_k8s_secret_value "gitlab" "$bucket_name" "AWS_SECRET_ACCESS_KEY" $source_kubeconfig)
        # Copy the bucket contents
        mc alias set $bucket_name https://rook-ceph-bucket.int.$source_cc_domain $aws_access_key_id $aws_secret_access_key
        mkdir -p $working_dir/source_path/buckets/$bucket_name
        mc cp --recursive $bucket_name $working_dir/source_path/buckets/$bucket_name
        mc alias remove $bucket_name
    done

    echo "Copied object storage bucket contents to local============================================"    
}

upload_env_bucket_data() {
    #Copy bucket contents to destination
    echo "Copying object storage bucket contents to destination====================================="
    for bucket_name in $bucket_names; do
        echo "Copying bucket: $bucket_name"
        # Get the bucket auth credentials
        aws_access_key_id=$(get_k8s_secret_value "gitlab" "$bucket_name" "AWS_ACCESS_KEY_ID" $dest_kubeconfig)
        aws_secret_access_key=$(get_k8s_secret_value "gitlab" "$bucket_name" "AWS_SECRET_ACCESS_KEY" $dest_kubeconfig)
        # Copy the bucket contents
        mc alias set $bucket_name https://rook-ceph-bucket.int.$dest_cc_domain $aws_access_key_id $aws_secret_access_key
        mc cp --recursive $working_dir/source_path/buckets/$bucket_name $bucket_name
        mc alias remove $bucket_name
    done    
}


# Define the search pattern
env_name="$1"
source_kubeconfig="$2"
dest_kubeconfig="$3"
source_cc_domain="$4"
dest_cc_domain="$5"
gitlab_group="iac"
working_dir="$6"
source_pipeline_job_id="$7"

# Initial checks and validations
check_dns $source_cc_domain
check_dns $dest_cc_domain
check_path $source_kubeconfig
check_path $dest_kubeconfig
check_path $working_dir

# Clear the working directory

rm -rf $working_dir/

# Define the output file
output_file="$1_secrets.yaml"

# Initialize the output file
echo "" > $output_file

# Connect to source netbird vpn
netbird_connect $source_cc_domain

# Get the gitlab token from the source cluster
source_gitlab_token=$(get_k8s_secret_value "gitlab" "root-token-secret" "token" $source_kubeconfig)
echo "Exported source gitlab token"

# Get all secret names in the current namespace
secret_names=$(kubectl get secrets -n kube-system --kubeconfig=$source_kubeconfig | grep -E "^tfstate.*${env_name}" | grep -vE 'k8s-store-config|gitops-build' | awk '{print $1}' )

if [[ -z "$secret_names" ]]; then
    echo "No terraform state secrets found matching '$env_name'."
    exit 1
fi

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

download_env_bucket_data

# Connect to source netbird vpn
netbird_connect $dest_cc_domain
# Create the secrets in the destination cluster
kubectl apply -f "$output_file" --kubeconfig=$dest_kubeconfig
echo "Secrets have been imported to the destination cluster====================================="

#Get the gitlab token from the destination cluster
dest_gitlab_token=$(get_k8s_secret_value "gitlab" "root-token-secret" "token" $dest_kubeconfig)

upload_env_bucket_data

#create gitlab project CICD variables
echo "creation of gitlab project CICD variables================================================="
source_gitlab_project_id=$(get_gitlab_project_id $source_gitlab_token $source_cc_domain $env_name)

if [[ -z "$source_gitlab_project_id" ]]; then
    echo "Project '$env_name' does not exist in source gitlab.$source_cc_domain or cannot be accessed."
    exit 1    
else
    echo "Project '$env_name' exists on source GitLab.$source_cc_domain"
fi

dest_gitlab_project_id=$(get_gitlab_project_id $dest_gitlab_token $dest_cc_domain $env_name)

if [[ -z "$dest_gitlab_project_id" ]]; then
    echo "Project '$env_name' does not exist in destination gitlab.$dest_cc_domain or cannot be accessed."
    exit 1    
else
    echo "Project '$env_name' exists on GitLab.$dest_cc_domain"
fi

#Clone the source gitlab repo
clone_gitlabrepo $source_gitlab_token $source_cc_domain $gitlab_group $env_name $working_dir/source_path/$env_name
#Clone the destination gitlab repo
clone_gitlabrepo $dest_gitlab_token $dest_cc_domain $gitlab_group $env_name $working_dir/dest_path/$env_name

#update the gitlab project variables
update_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIGRATE" "true"
create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_SOURCE_GITLAB" "https://gitlab.$source_cc_domain"
create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_SOURCE_PROJECT_ID" $source_gitlab_project_id
create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_SOURCE_JOB_ID" $source_pipeline_job_id


#migrate the repo contents from source to destination
echo "migrate the repo contents from source to destination======================================="
cp -r $working_dir/source_path/$env_name/* $working_dir/dest_path/$env_name/
cp -r $working_dir/source_path/$env_name/.gitlab $working_dir/dest_path/$env_name/
cp -r $working_dir/source_path/$env_name/.gitlab-ci.yml $working_dir/dest_path/$env_name/

git config --global http.postBuffer 524288000 #increase the buffer size for the whole set of files in the repo
git -C $working_dir/dest_path/$env_name/ add .
git -C $working_dir/dest_path/$env_name/ commit -m "Automated commit - the migrated repo contents"
git -C $working_dir/dest_path/$env_name/ push

