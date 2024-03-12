function set_tf_variables {
    export TF_HTTP_USERNAME=root
    export TF_STATE_BASE_ADDRESS=$GITLAB_URL"/api/v4/projects/"$BOOTSTRAP_PROJECT_ID"/terraform/state"
    export TF_HTTP_LOCK_METHOD=POST
    export TF_HTTP_UNLOCK_METHOD=DELETE
    export TF_HTTP_RETRY_WAIT_MIN=5
    export TF_HTTP_PASSWORD=${GITLAB_ROOT_TOKEN}

    export CONTROL_CENTER_CLOUD_PROVIDER="aws"
    export ANSIBLE_BASE_OUTPUT_DIR="./"
    export PRIVATE_REPO_USER=nullvalue
    export PRIVATE_REPO_TOKEN=nullvalue
    export PRIVATE_REPO=example.com
    export IAC_TEMPLATES_TAG=$IAC_TERRAFORM_MODULES_TAG

    set

}

function overwrite_terragrunt_file {

cat <<'EOT' >terragrunt.hcl
skip = true
remote_state {
  backend = "local"
  config = {
    path = "${get_parent_terragrunt_dir()}/${path_relative_to_include()}/terraform.tfstate"
  }

  generate = {
    path = "backend.tf"
    if_exists = "overwrite"
  }
}

generate "required_providers" {
  path = "required_providers.tf"

  if_exists = "overwrite_terragrunt"

  contents = <<EOF
terraform {
  required_version = "${local.common_vars.tf_version}"

  required_providers {
    local = {
      source = "hashicorp/local"
      version = "${local.common_vars.local_provider_version}"
    }
  }
}
EOF
}

locals {
  common_vars = yamldecode(file("common-vars.yaml"))
  env_vars = yamldecode(file("environment.yaml"))
}
EOT

}

if [ -n "$1" ]
then
    export INVENTORY_FILE_PATH=$1
else
    echo "Please pass INVENTORY_FILE_PATH  as the first parameter"
     echo "Usage move-state-from-gitlab.sh INVENTORY_FILE_PATH AWS_PROFILE IAC_TERRAFORM_MODULES_TAG [WORK_DIR] [BOOTSTRAP_PROJECT_ID]"
    exit 1
fi


if [ -n "$2" ]
then
    export AWS_PROFILE=$2
else
   echo "Please pass AWS_PROFILE as the second parameter"
   echo "Usage move-state-from-gitlab.sh INVENTORY_FILE_PATH AWS_PROFILE IAC_TERRAFORM_MODULES_TAG [WORK_DIR] [BOOTSTRAP_PROJECT_ID]"
   exit 1
fi

if [ -n "$3" ]
then
    export IAC_TERRAFORM_MODULES_TAG=$3
else
   echo "Please pass AWS_PROFILE as the second parameter"
   echo "Usage move-state-from-gitlab.sh INVENTORY_FILE_PATH AWS_PROFILE IAC_TERRAFORM_MODULES_TAG [WORK_DIR] [BOOTSTRAP_PROJECT_ID]"
   exit 1
fi

if [ -n "$4" ]
then
    export WORK_DIR=$4
else
   WORK_DIR=/tmp/data/bootstrap
fi

if [ -n "$5" ]
then
    export BOOTSTRAP_PROJECT_ID=$5
else
   BOOTSTRAP_PROJECT_ID=1
fi


if [ -f $INVENTORY_FILE_PATH ]
then
    GITLAB_HOST=$(yq eval ".gitlab.vars.server_hostname" $INVENTORY_FILE_PATH)
    ROOT_TOKEN=$(yq eval ".gitlab.vars.server_token" $INVENTORY_FILE_PATH)
    echo $GITLAB_HOST" is GITLAB HOST"
    if [ "${GITLAB_HOST}" == "null" ] || [ "${ROOT_TOKEN}" == "null" ]
    then
       echo "Could not get the GITLAB credentials value, may be wrong inventory file provided"
       exit 1
    fi
    GITLAB_URL="https://"$GITLAB_HOST
    GITLAB_ROOT_TOKEN=$ROOT_TOKEN
    GITLAB_CLONE_URL="https://oauth2:"$GITLAB_ROOT_TOKEN"@"$GITLAB_HOST"/iac/bootstrap.git"
else
    echo "$INVENTORY_FILE_PATH does not exist"
    exit 1
fi

rm -rf $WORK_DIR
mkdir -p $WORK_DIR

BOOTSTRAP_PROJECT=$GITLAB_URL"/iac/bootstrap.git"
git clone $GITLAB_CLONE_URL $WORK_DIR

set_tf_variables
cd $WORK_DIR
# init upgrade
terragrunt run-all init -upgrade
overwrite_terragrunt_file
#migrate state
terragrunt run-all init -migrate-state -force-copy