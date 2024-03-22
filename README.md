docker run -it -v ~/.aws:/root/.aws ghcr.io/mojaloop/control-center-util:5.0.0 /bin/bash

to get started, run the follwing from commandline:
~~~
cd /iac-run-dir
~~~
modify environment variables in setenv as appropriate, then run:
~~~
source setenv
./init.sh
cd /iac-run-dir/iac-modules/terraform/control-center/init
~~~
modify environment.yaml file as appropriate, then run:
~~~
source setlocalenv.sh
./runall.sh
./movestatetogitlab.sh
~~~
Then, go to gitlab instance, use root password found by running: 
~~~
yq eval '.gitlab.vars.server_password'  $ANSIBLE_BASE_OUTPUT_DIR/control-center-deploy/inventory
~~~
You then need to setup 2FA, then you can navigate to the bootstrap proyect and view pipelines in cicd section.

First pipeline will be waiting at Deploy job.  Executing this will run through the steps already run in the docker container, but will also run the control-center-post-config module which needs to run from within the internal network as it accesses the tenancy vault.

From now on, make changes to the files inside gitlab and execute the jobs as necessary to make changes to the control center components

Netmaker gui is available at dashboard.NM_SUBDOMAIN where NM_SUBDOMAIN is: 
~~~
yq eval '.netmaker.vars.netmaker_base_domain'  /iac-run-dir/output/control-center-post-config/inventory
~~~

Admin user defaults to nmaker-admin, password is: 
~~~
yq eval '.netmaker.vars.netmaker_admin_password'  /iac-run-dir/output/control-center-post-config/inventory
~~~

OIDC integration is preconfigured for netmaker using gitlab as a provider.  A gitlab user can use the OIDC option to login, however, before they can see anything, an admin needs to change their account to be an admin and select the networks that they can see (or all)

After connecting to netmaker as an admin, you can select the only node that is in the ctrl-center network and enable both the ingress gateway and egress gateway options on the node.  The network for the egress gateway should be the control center network (where gitlab, runner, nexus, and seaweed run): default is 10.25.0.0/22

Now you can create a external client (wireguard profile) using the node as a gateway.  Download the profile and add it to your wireguard client.

Enable the wireguard profile and now you can access the 10.25.0.0/22 network

Next steps is to configure the kubernetes cluster configurations in the different env repos.