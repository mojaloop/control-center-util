echo "https://${PRIVATE_REPO_USER}:${PRIVATE_REPO_TOKEN}@${PRIVATE_REPO}" > ~/.gitcredentials.store
git config --global credential.helper 'store --file ~/.gitcredentials.store'
git config --global advice.detachedHead false
git clone https://github.com/mojaloop/iac-modules.git
cd iac-modules
git checkout $IAC_TERRAFORM_MODULES_TAG