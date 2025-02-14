## About this repository

This repository includes the Dockerfile and GitHub workflow for building the container image used during the initial setup of a control center. The GitHub workflow is triggered whenever a new tag is pushed to the repository.

The built container image, hosted in GHCR, includes all the necessary utilities and dependencies to initiate the control center setup, namely:

- terraform
- terragrunt
- vault client
- kapp and ytt
- kubectl
- aws cli
- necessary pip modules and ansible collections

The `cc-util` directory is copied into the container, with `/iac-run-dir` as the destination in the image build workflow.

### Dependencies

A Linux, macOS or Windows host operating system with [Docker Engine](https://docs.docker.com/engine/install/) installed and working. This can be your workstation, or a virtual machine in a cloud platform.

Validate docker is working by running:

```bash
docker version
#OR
docker info
```

If you’re not running docker commands as the root user, consider adding your standard user account to the docker group:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

The docker host should also have internet connectivity.

### Getting started

Start a new container instance from `control-center-util` image. You can check available official versions from [Releases](https://github.com/mojaloop/control-center-util/releases) page.

Set the name of the container (optional), and version obtained from the releases page.

```bash
CNAME="ccv2-build"
VERSION="6.1.2"
```

Create a new container:

```bash
docker run -t -d --name ${CNAME} --hostname ${CNAME} --cap-add SYS_ADMIN \
--cap-add NET_ADMIN ghcr.io/mojaloop/control-center-util:${VERSION}
```

Confirm if the container is started, and in `running` state:

```bash
$ docker ps
CONTAINER ID   IMAGE                                        COMMAND       CREATED         STATUS         PORTS     NAMES
175aa03deb7e   ghcr.io/mojaloop/control-center-util:6.1.2   "/bin/bash"   3 seconds ago   Up 2 seconds             ccv2-build
```

Launch a new shell into the container:

```bash
docker exec -ti $CNAME bash
```

### Provision control center cluster

For an AWS cloud environment, configure credentials by running:

```bash
$ aws configure
AWS Access Key ID [None]: <YOUR_ACCESS_KEY_ID>
AWS Secret Access Key [None]: <YOUR_SECRET_ACCESS_KEY>
Default region name [None]:
Default output format [None]:
```

Refer to AWS documentation on how to [create access keys for an IAM user](https://docs.aws.amazon.com/keyspaces/latest/devguide/create.keypair.html).

Credentials will be written to the file `~/.aws/credentials`. Open the file and convert it to a profile named `oss`

```bash
$ vim ~/.aws/credentials
[oss]
aws_access_key_id = YOUR_ACCESS_KEY_ID
aws_secret_access_key = YOUR_SECRET_ACCESS_KEY
```

Change your working directory to `/iac-run-dir`

```bash
cd /iac-run-dir
```

Before we can clone the [iac-modules] repository which has all the IAC for installing control center. We need to set release tag in the `setenv` file.

```bash
$ vim setenv
export IAC_TERRAFORM_MODULES_TAG=vx.y.z
```

Replace the `vx.y.z` with the value obtained from [Mojaloop IAC releases](https://github.com/mojaloop/iac-modules/releases) github page.

Once the value is changed, source and and run the `init.sh` which will clone and do git checkout to provided release.

```bash
source setenv
./init.sh
```

#### Create custom cluster configuration file

Next change your working directory to:

```bash
cd iac-modules/terraform/ccnew
```

The sane default configuration parameters for creating a control center cluster are in `default-config/cluster-config.yaml`. But the default values can be overriden by creating a new file in `custom-config/cluster-config.yaml`.

Here is a sample custom cluster configuration file.

```yaml
cluster_name: ccv2
domain: k8s.example.com
cloud_platform: aws
k8s_cluster_module: eks #base-k8s
k8s_cluster_type: eks #microk8s
cloud_region: eu-west-1
ansible_collection_tag: v5.5.0
iac_terraform_modules_tag: v5.8.0
vpc_cidr: 10.121.0.0/20
enable_object_storage_backend: false
microk8s_dev_skip: false
nodes:
  master-generic:
    master: true
    instance_type: "m5.4xlarge"
    node_count: 3
```

The same can be done for argocd application configurations by creating `custom-config/common-vars.yaml`

```yaml
netbird_rdbms_provider: "percona" #rds
gitlab_postgres_rdbms_provider: "percona" #rds
zitadel_rdbms_provider: "percona" #rds
```

If creating an EKS cluster, there is one extra step of exporting AWS credentials in your active shell before deployment.

```bash
export AWS_SECRET_ACCESS_KEY=accesskey 
export AWS_ACCESS_KEY_ID=secretaccesskey
```

Finally, create infrastructure resources and cluster resources by running the following script.

```bash
./wrapper.sh
```

### Access Zitadel dashboard

Go to zitadel and login as admin to create your own user. The URL will be `https://zitadel.cluster_name.domain`. Login as:

- Username: `rootauto@zitadel.zitadel.cluster_name.domain`
- Initial password: `#Password1!`

You will be asked to change the password on first initial successful login.

#### Creating a user

While logged in as admin user, create new users  on **Users** --> **+New**. Then input required user details.

If no smtp configurations done, click on **Email Verified** and set a **Set Initial Password**. A user will be required to change this password on first login.

#### Assigning user authorizations

This is done on "Authorizations" > "New" > "Select Project" > "Select Privilege". And this can be repeted for all other applications.

### Access Gitlab

Provided the user has Gitlab privileges assigned in Zitadel, they can login on `https://gitlab.cluster_name.domain`. On the login page, use **Zitadel** for SSO and signing your credentials.

### Connecting to netbird VPN mesh

Install netbird client:

- Linux / macOS

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sh
```

- Windows: [Download package](https://pkgs.netbird.io/windows/x64)

Run netbird and login in your browser:

```bash
netbird up --management-url https://netbird.cluster_name.domain:443 --admin-url https://netbird-dashboard.cluster_name.domain
```

The same can be initiated from Desktop UI of Netbird application. Go to Netbird Client > Settings > Advanced Settings. The change management url and click connect.

Client configuration information can also be obtained from -  `https://netbird-dashboard.cluster_name.domain`

### Accessing internal applications

To get a list of services only accessible internally, run:

```bash
kubectl get virtualservices -A
```

Example of these are:
- ArgoCD: `https://argocd.int.cluster_name.domain`
- Vault: `https://vault.int.cluster_name.domain`
- Grafana: `https://grafana.int.cluster_name.domain`

And login is via OIDC - SSO, but make sure the user is granted necessary permissions to access the resources.

### Moving kubernetes to k8s

Terraform state file can be stored as a secret in kubernetes `kube-system` namespace by runnning the following command inside the build container:

```bash
./movestatetok8s.sh
```