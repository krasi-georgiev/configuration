#!/usr/bin/env bash

# This script uses arg $1 (name of *.jsonnet file to use) to generate the manifests/*.yaml files.

set -e
set -x
# only exit with zero if all commands of the pipeline exit successfully
set -o pipefail

# Make sure to start with a clean 'manifests' dir
rm -rf environments/kubernetes/manifests
mkdir environments/kubernetes/manifests

jsonnet -J vendor -m environments/kubernetes/manifests environments/kubernetes/main.jsonnet | xargs -I{} sh -c 'cat {} | gojsontoyaml > {}.yaml' -- {}
find environments/kubernetes/manifests -type f ! -name '*.yaml' -delete

# Make sure to start with a clean 'manifests' dir
rm -rf environments/openshift/manifests
mkdir environments/openshift/manifests

jsonnet -J vendor environments/openshift/main.jsonnet | gojsontoyaml >environments/openshift/manifests/observatorium-template.yaml
jsonnet -J vendor environments/openshift/telemeter-prometheus-ams.jsonnet | gojsontoyaml >environments/openshift/manifests/telemeter-prometheus-ams-template.yaml
jsonnet -J vendor environments/openshift/telemeter.jsonnet | gojsontoyaml >environments/openshift/manifests/telemeter-template.yaml
jsonnet -J vendor environments/openshift/thanos.jsonnet | gojsontoyaml >environments/openshift/manifests/thanos-template.yaml
jsonnet -J vendor environments/openshift/jaeger.jsonnet | gojsontoyaml >environments/openshift/manifests/jaeger-template.yaml
jsonnet -J vendor environments/openshift/observatorium-api.jsonnet | gojsontoyaml >environments/openshift/manifests/observatorium-api-template.yaml
find environments/openshift/manifests -type f ! -name '*.yaml' -delete
