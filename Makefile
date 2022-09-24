GITPOD_NAMESPACE ?= gitpod
GITPOD_URL ?= demo.gitpod-self-hosted.com
KOTS_PASSWORD ?= q1w2e3r4
LICENCE_PATH ?= ${PWD}/gitpod-licence.yaml
REG_PORT ?= 5000
MIRRORED_IMAGES = gitpod/workspace-base gitpod/workspace-full

GCP_PROJECT_ID ?=
GCP_SERVICE_ACCOUNT_KEY ?=

REGISTRY_USER ?= username
REGISTRY_PASSWORD ?= password

SERVER_IP ?=
SERVER_USER ?=

CA_CRT_PATH ?= ${PWD}/ca.crt

DEPENDENCIES_NAME = dependencies

NODE_EXTRA_ARGS = "--node-label=gitpod.io/workload_meta=true --node-label=gitpod.io/workload_ide=true --node-label=gitpod.io/workload_workspace_services=true --node-label=gitpod.io/workload_workspace_regular=true --node-label=gitpod.io/workload_workspace_headless=true"

all: k3s gitpod dependencies registry load_ca_cert

add_node:
	@echo "Adding a node to the cluster"

	@command -v k3sup 2>&1 /dev/null || (curl -sLS https://get.k3sup.dev | sh && sudo install k3sup /usr/local/bin/ && rm ./k3sup)

	@k3sup join \
		--ip="127.0.0.1" \
        --k3s-channel="stable" \
        --k3s-extra-args="${NODE_EXTRA_ARGS}" \
        --server-ip "${SERVER_IP}" \
        --server-user "${SERVER_USER}"
.PHONY: add_node

dependencies:
	$(shell docker run --entrypoint htpasswd registry:2.7.0 -Bbn ${REGISTRY_USER} ${REGISTRY_PASSWORD} > /tmp/htpasswd)

	@helm dependencies update ./gitpod
	@helm upgrade \
		--atomic \
		--cleanup-on-fail \
		--create-namespace \
		--install \
		--namespace="${GITPOD_NAMESPACE}" \
		--reset-values \
		--set="registry.secrets.htpasswd=$$(cat /tmp/htpasswd)" \
		--wait \
		${DEPENDENCIES_NAME} \
		./gitpod

	@sleep 10
.PHONY: dependencies

get_cert:
	@kubectl wait -n ${GITPOD_NAMESPACE} --for=condition=Ready certificate/ca-issuer-ca > /dev/null 2>&1
	@kubectl get secrets -n ${GITPOD_NAMESPACE} ca-issuer-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > ${CA_CRT_PATH}

	@echo "CA cert downloaded to ${CA_CRT_PATH}"
.PHONY: get_cert

gitpod:
	@echo "Installing KOTS"

	@kubectl kots get apps --namespace ${GITPOD_NAMESPACE} | grep gitpod || kubectl kots install \
		--namespace ${GITPOD_NAMESPACE} \
		--license-file ${LICENCE_PATH} \
		--no-port-forward \
		--shared-password ${KOTS_PASSWORD} \
		gitpod

	@echo "Installing Gitpod"
	@kubectl kots set config gitpod \
		--deploy \
		--namespace ${GITPOD_NAMESPACE} \
		domain=${GITPOD_URL} \
		reg_incluster=1 \
		store_provider=s3 \
		store_region=local \
		store_s3_endpoint=${DEPENDENCIES_NAME}-minio.${GITPOD_NAMESPACE}.svc.cluster.local:9000 \
		store_s3_access_key_id=root \
		store_s3_secret_access_key=password \
		advanced_mode_enabled=1 \
		config_patch="$$(echo '{ \
			"objectStorage": { \
				"s3": { \
					"allowInsecureConnection": true \
				} \
			} \
		}' | base64 -w0)"

	@echo "Waiting for Gitpod to be deployed"
	@sleep 30

	$(MAKE) wait_for_gitpod
.PHONY: gitpod

k3s:
	@echo "Installing k3s to local machine"

	@rm -Rf ${HOME}/.kube
	@curl https://raw.githubusercontent.com/MrSimonEmms/gitpod-k3s-guide/main/setup.sh | \
		IP_LIST="127.0.0.1" \
		SERVER_USER="" \
		DOMAIN="${GITPOD_URL}" \
		MANAGED_DNS_PROVIDER=gcp \
		GCP_PROJECT_ID="${GCP_PROJECT_ID}" \
        GCP_SERVICE_ACCOUNT_KEY="${GCP_SERVICE_ACCOUNT_KEY}" \
		CMD=install \
		bash
.PHONY: k3s

kill_registry:
	@for reg in $$(ps -ef | awk '/kubectl/{print $$2}'); do \
		kill $$reg || true; \
	done
.PHONY: kill_registry

load_ca_cert:
	@echo "Loading CA certificate to the system"
	$(MAKE) get_cert

	@echo "Copying Gitpod CA certificate to CA directory"
	@sudo cp ${CA_CRT_PATH} /usr/local/share/ca-certificates/gitpod.crt

	@echo "Updating CA certificates"
	@sudo update-ca-certificates

	@echo "Restarting k3s"
	@sudo systemctl restart k3s

	@echo "Restarting all Gitpod pods"
	@kubectl delete pods -n ${GITPOD_NAMESPACE} -l app=gitpod

	$(MAKE) wait_for_gitpod
.PHONY: load_ca_cert

registry:
	$(MAKE) kill_registry || true

	@kubectl port-forward -n ${GITPOD_NAMESPACE} deployment/${DEPENDENCIES_NAME}-registry ${REG_PORT}:${REG_PORT} > /dev/null &

	@sleep 5

	@docker login \
		localhost:${REG_PORT} \
		-u ${REGISTRY_USER} \
		-p ${REGISTRY_PASSWORD}

	@for reg in ${MIRRORED_IMAGES}; do \
		echo "Mirroring $$reg to localhost:${REG_PORT}/$$reg"; \
		docker pull $$reg; \
		docker tag $$reg localhost:${REG_PORT}/$$reg; \
		docker push localhost:${REG_PORT}/$$reg; \
	done

	$(MAKE) kill_registry || true
.PHONY: registry

wait_for_gitpod:
	@echo "Waiting for Gitpod to be ready"
	@kubectl wait \
		deployment \
		-n ${GITPOD_NAMESPACE} \
		--for condition=Available=True \
		-l component=gitpod-installer-status \
		--timeout 10m
.PHONY: wait_for_gitpod
