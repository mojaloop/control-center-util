if [ -n "$1" ]
then
    export IAC_TERRAFORM_MODULES_TAG=$1
else
     echo "Please pass IAC_TERRAFORM_MODULES_TAG  as the first parameter"
     echo "Usage destroy-control-center.sh IAC_TERRAFORM_MODULES_TAG AWS_PROFILE [WORKDIR]"
    exit 1
fi
if [ -n "$2" ]
then
    export AWS_PROFILE=$2
else
   echo "Please pass AWS_PROFILE as the second parameter"
   echo "Usage destroy-control-center-cleanup.sh IAC_TERRAFORM_MODULES_TAG AWS_PROFILE [WORKDIR]"
   exit 1
fi

if [ -n "$3" ]
then
    export WORK_DIR=$3
else
   WORK_DIR=/tmp/data/bootstrap
fi

export IAC_TEMPLATES_TAG=$IAC_TERRAFORM_MODULES_TAG
export CONTROL_CENTER_CLOUD_PROVIDER=aws
cd $WORK_DIR"/control-center-deploy"
terragrunt run-all destroy --terragrunt-non-interactive