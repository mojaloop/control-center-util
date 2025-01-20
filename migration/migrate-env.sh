
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

get_gitlab_cicd_var() {
    local gitlab_token="$1"
    local cc_domain="$2"
    local project_id="$3"
    local key="$4"
    response=$(curl -s -XGET -H "Content-Type: application/json" --header "Authorization: Bearer $gitlab_token" "https://gitlab.$cc_domain/api/v4/projects/$project_id/variables/$key" )
    
    if [[ $(echo "$response" | jq -r '.key') == "$key" ]]; then
        echo "$response" | jq -r '.value'
        return 0
    else
        echo ""
        return 1
    fi

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
    git clone --recurse-submodules https://token:$gitlab_token@gitlab.$cc_domain/$group/$project.git $path

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
    bucket_names=$(kubectl get obc --no-headers -o custom-columns=":metadata.name"  -n gitlab --kubeconfig=$source_kubeconfig | grep $env_name)

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
    bucket_names=""
    bucket_names=$(kubectl get obc --no-headers -o custom-columns=":metadata.name"  -n gitlab --kubeconfig=$dest_kubeconfig | grep $env_name)

    if [[ -z "$bucket_names" ]]; then
        echo "No object storage buckets found matching '$env_name' in destination."
        exit 1
    fi    

    for bucket_name in $bucket_names; do
        echo "Copying bucket: $bucket_name"
        #object_name=$(echo $bucket_name | sed 's/-bucket//')
        # Get the bucket auth credentials
        aws_access_key_id=$(get_k8s_secret_value "gitlab" "$bucket_name" "AWS_ACCESS_KEY_ID" $dest_kubeconfig)
        aws_secret_access_key=$(get_k8s_secret_value "gitlab" "$bucket_name" "AWS_SECRET_ACCESS_KEY" $dest_kubeconfig)
        # Copy the bucket contents
        mc alias set $bucket_name https://rook-ceph-bucket.int.$dest_cc_domain $aws_access_key_id $aws_secret_access_key
        mc cp --recursive $working_dir/source_path/buckets/$bucket_name/ $bucket_name/
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
env_domain="$8"
mode=$9

# Initial checks and validations
check_dns $source_cc_domain
check_dns $dest_cc_domain
check_path $source_kubeconfig
check_path $dest_kubeconfig
check_path $working_dir

if [[ "$mode" == "migrate-env" ]]; then

        # Define the output file
        output_file="${env_name}_secrets.yaml"

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

        # Connect to source netbird vpn
        netbird_connect $dest_cc_domain
        # Create the secrets in the destination cluster
        kubectl apply -f "$output_file" --kubeconfig=$dest_kubeconfig
        echo "Secrets have been imported to the destination cluster====================================="

        #Get the gitlab token from the destination cluster
        dest_gitlab_token=$(get_k8s_secret_value "gitlab" "root-token-secret" "token" $dest_kubeconfig)

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
        #update_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIGRATE" "true"
        create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_SOURCE_GITLAB" "https://gitlab.$source_cc_domain"
        create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_SOURCE_PROJECT_ID" $source_gitlab_project_id
        create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_SOURCE_JOB_ID" $source_pipeline_job_id
        #update_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "MIG_TRANSIT_VAULT_UNSEAL_KEY_NAME" "unseal-key-$env_name-migrated"


        #migrate the repo contents from source to destination
        echo "migrate the repo contents from source to destination======================================="
        cp -r $working_dir/source_path/$env_name/* $working_dir/dest_path/$env_name/
        cp -r $working_dir/source_path/$env_name/.gitlab $working_dir/dest_path/$env_name/
        cp -r $working_dir/source_path/$env_name/.gitlab-ci.yml $working_dir/dest_path/$env_name/
        yq eval '.migrate = true' -i $working_dir/dest_path/$env_name/custom-config/cluster-config.yaml


        #configure the buffer size and other params for the whole set of files in the repo
        git config --global http.postBuffer 2147483648 
        git config --global http.lowSpeedTime 600
        git config --global pack.window 1
        git config --global core.compression 0
        git -C $working_dir/dest_path/$env_name/ add .
        git -C $working_dir/dest_path/$env_name/ commit -m "Automated commit - the migrated repo contents"
        GIT_TRACE=1 GIT_CURL_VERBOSE=1 GIT_TRACE_PACKET=1 git -C $working_dir/dest_path/$env_name/ push
elif  [[ "$mode" == "migrate-buckets"  ]]; then 

        # Connect to source netbird vpn
        netbird_connect $source_cc_domain
        # Download the bucket data        
        download_env_bucket_data
        #Connect to destination netbird vpn
        netbird_connect $dest_cc_domain
        # Upload the bucket data
        upload_env_bucket_data 

elif  [[ "$mode" == "migrate-vault"  ]]; then 

        echo "" > payload
        # Connect to source netbird vpn
        netbird_connect $source_cc_domain
        source_gitlab_token=$(get_k8s_secret_value "gitlab" "root-token-secret" "token" $source_kubeconfig)
        # Download the vault unseal key       
        VAULT_TOKEN=$(get_k8s_secret_value "vault" "vault-keys" "root_token" $source_kubeconfig)
        VAULT_ADDR="https://vault.int.$source_cc_domain"
        vault write -f transit/keys/unseal-key-$env_name/config allow_plaintext_backup=true exportable=true
        vault read transit/backup/unseal-key-$env_name -format="json" | jq -r ".data.backup" > payload
        vault write -f transit/keys/unseal-key-$env_name/config allow_plaintext_backup=false exportable=false
        #Connect to destination netbird vpn
        netbird_connect $dest_cc_domain
        # Upload the vault unseal key
        VAULT_TOKEN=$(get_k8s_secret_value "vault" "vault-keys" "root_token" $dest_kubeconfig)
        VAULT_ADDR="https://vault.int.$dest_cc_domain"
        vault delete transit/keys/unseal-key-$env_name-migrated
        vault write transit/restore/unseal-key-$env_name-migrated backup=@payload
        #Get the gitlab token from the destination cluster
        dest_gitlab_token=$(get_k8s_secret_value "gitlab" "root-token-secret" "token" $dest_kubeconfig)

        source_gitlab_project_id=$(get_gitlab_project_id $source_gitlab_token $source_cc_domain $env_name)
        dest_gitlab_project_id=$(get_gitlab_project_id $dest_gitlab_token $dest_cc_domain $env_name)
        env_vault_root_token=$(get_gitlab_cicd_var $source_gitlab_token $source_cc_domain $source_gitlab_project_id "VAULT_ROOT_TOKEN")
        create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "VAULT_ROOT_TOKEN" $env_vault_root_token
        NUM_KEYS=5
        for ((i=0; i<NUM_KEYS; i++))
        do 
            recovery_key=$(get_gitlab_cicd_var $source_gitlab_token $source_cc_domain $source_gitlab_project_id "RECOVERY_KEY_${i}")
            create_gitlab_project_variable $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "RECOVERY_KEY_${i}" $recovery_key
        done;

elif  [[ "$mode" == "post-migration"  ]]; then         

        # Connect to destination netbird vpn
        #netbird_connect $dest_cc_domain        
        # Verify the destination argocd-oidc secret synced and has the latest oidc config

        VAULT_TOKEN=$(get_k8s_secret_value "vault" "vault-keys" "root_token" $dest_kubeconfig)
        VAULT_ADDR="https://vault.int.$dest_cc_domain"
        argocd_oidc_client_id_desired=$(vault read secret/data/$env_name/argocd_oidc_client_id --format=json | jq -r ".data.data.value")

        argocd_oidc_client_id_actual=$(get_k8s_secret_value "argocd" "argo-oidc" "clientid" $dest_kubeconfig)
        echo $argocd_oidc_client_id_actual

        if [[ "$argocd_oidc_client_id_desired" != "$argocd_oidc_client_id_actual" ]]; then
            echo "Error: argocd-oidc secret not synced or has the latest oidc config, retry after sometime."
            exit 1
        else:
            echo "argocd-oidc secret synced and has the latest oidc config"
            #restart argocd server
            kubectl rollout restart deployment argocd-server -n argocd --kubeconfig=$dest_kubeconfig   
        fi

        #Rewrite the vault oidc configuration directly
        vault_oidc_client_id_desired=$(vault read secret/data/$env_name/vault_oidc_client_id --format=json | jq -r ".data.data.value")
        vault_oidc_client_secret_desired=$(vault read secret/data/$env_name/vault_oidc_client_secret --format=json | jq -r ".data.data.value")
    
        zitadel_project_id_desired=$(get_gitlab_cicd_var $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "zitadel_project_id")
        vault_admin_rbac_group_desired=$(get_gitlab_cicd_var $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "vault_admin_rbac_group")
        vault_readonly_rbac_group_desired=$(get_gitlab_cicd_var $dest_gitlab_token $dest_cc_domain $dest_gitlab_project_id "vault_readonly_rbac_group")
        vault write auth/oidc/config \
          bound_issuer="https://zitadel.${dest_cc_domain}" \
          oidc_discovery_url="https://zitadel.${dest_cc_domain}" \
          oidc_client_id="${vault_oidc_client_id_desired}" \
          oidc_client_secret="${vault_oidc_client_secret_desired}" \
          default_role="techops-admin"

        vault write auth/oidc/role/techops-admin -<<EOF
          {
            "user_claim": "sub",
            "bound_audiences": "${vault_oidc_client_id_desired}",
            "allowed_redirect_uris": ["https://vault.int.${env_name}.${env_domain}/ui/vault/auth/oidc/oidc/callback"],
            "role_type": "oidc",
            "token_policies": "vault-admin",
            "ttl": "1h",
            "oidc_scopes": ["openid"], 
            "bound_claims": { "zitadel:grants": ["${zitadel_project_id_desired}:${vault_admin_rbac_group_desired}"] }
          }
EOF          
        vault write auth/oidc/role/techops-readonly -<<EOF
          {
            "user_claim": "sub",
            "bound_audiences": "${vault_oidc_client_id_desired}",
            "allowed_redirect_uris": ["https://vault.int.${env_name}.${env_domain}/ui/vault/auth/oidc/oidc/callback"],
            "role_type": "oidc",
            "token_policies": "read-secrets",
            "ttl": "1h",
            "oidc_scopes": ["openid"],
            "bound_claims": { "zitadel:grants": ["${zitadel_project_id}:${vault_readonly_rbac_group_desired}"] }
          }
EOF
fi

